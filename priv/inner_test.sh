#!/usr/bin/env bash
# External runner executed as the container PID 1. It prepares the isolated
# work tree and then runs each CI stage as a separate standard `rebar3'
# process, emitting versioned observation events on stdout between stages.
# The host OTP worker is the only consumer of the output stream; it writes
# ci.log, validates the events and produces ci-summary.txt.
#
# Stage enablement and test selection arrive as host-normalized environment
# variables; the runner never injects the docker_ci plugin into the project,
# so every stage keeps the plugin lifecycle of a normal `rebar3 <command>'.
set -uo pipefail

SRC_MOUNT="${SRC_MOUNT:-/mnt/source}"
RESULTS_DIR="${RESULTS_DIR:-/mnt/results}"
CHECKOUTS_DIR="${CHECKOUTS_DIR:-/mnt/checkouts}"
PROJECT_NAME="${PROJECT_NAME:-project}"
WORK_DIR="${WORK_DIR:-/tmp/build/$PROJECT_NAME}"

# The container runs as a non-root host user on Linux hosts; give it a
# writable HOME for rebar3 caches, git config and ssh.  The directory is
# created during preparation together with the work directory.
export HOME="${HOME:-$WORK_DIR/home}"
export WORK_DIR

ERLANG_VER="${ERLANG_VER:-$(erl -noshell -eval \
    'io:format("~s", [erlang:system_info(otp_release)]), halt().')}"
TEST_SUITE="${TEST_SUITE:-}"
TEST_CASE="${TEST_CASE:-}"
RUN_XREF="${RUN_XREF:-true}"
RUN_DIALYZER="${RUN_DIALYZER:-false}"
RUN_CT="${RUN_CT:-true}"
RUN_EUNIT="${RUN_EUNIT:-false}"
USE_CHECKOUTS="${USE_CHECKOUTS:-auto}"
OUTPUT_LANG="${OUTPUT_LANG:-en}"

VER_RESULTS="$RESULTS_DIR/$ERLANG_VER"
CT_LOGS="$VER_RESULTS/logs"

if [[ "$OUTPUT_LANG" == "cn" ]]; then
    MSG_PREPARE="准备隔离工作目录"
    MSG_COMPILE="编译项目"
    MSG_XREF="运行交叉引用检查"
    MSG_DIALYZER="运行 Dialyzer"
    MSG_CT="运行 Common Test"
    MSG_EUNIT="运行 EUnit"
else
    MSG_PREPARE="Preparing isolated work directory"
    MSG_COMPILE="Compiling project"
    MSG_XREF="Running cross-reference checks"
    MSG_DIALYZER="Running Dialyzer"
    MSG_CT="Running Common Test"
    MSG_EUNIT="Running EUnit"
fi

bool_enabled() {
    [[ "${1,,}" == "true" || "$1" == "1" || "${1,,}" == "yes" ]]
}

# Expose the runner's own pid when requested (used by tests to verify
# signal forwarding; unset in production).
if [[ -n "${RUNNER_PIDFILE:-}" ]]; then
    echo "$$" > "$RUNNER_PIDFILE"
fi

# ---------------------------------------------------------------- events --

# Emit one protocol line in a single write. The nonce comes from the host
# (R3DCI_NONCE); without it the plain @@R3DCI/1 prefix is used.
emit() {
    local event="$1"
    shift
    local prefix="@@R3DCI/1"
    if [[ -n "${R3DCI_NONCE:-}" ]]; then
        prefix="$prefix/$R3DCI_NONCE"
    fi
    local line="$prefix"$'\t'"$event"
    local arg
    for arg in "$@"; do
        line="$line"$'\t'"$arg"
    done
    printf '%s\n' "$line"
}

step() {
    echo
    echo "================================================================"
    echo ">>> $1"
    echo "================================================================"
}

# ------------------------------------------------------------ work tree --

copy_worktree() {
    local source_dir="$1"
    local target_dir="$2"

    mkdir -p "$target_dir"
    if git -C "$source_dir" rev-parse --is-inside-work-tree \
        >/dev/null 2>&1; then
        (
            cd "$source_dir" || exit 1
            git ls-files --cached --others --exclude-standard -z |
                while IFS= read -r -d '' tracked_path; do
                    if [[ -e "$tracked_path" || -L "$tracked_path" ]]; then
                        printf '%s\0' "$tracked_path"
                    fi
                done |
                tar --null --verbatim-files-from --files-from=- -cf -
        ) |
            tar -C "$target_dir" -xf -
    else
        tar -C "$source_dir" \
            --exclude='.git' \
            --exclude='_build' \
            --exclude='_checkouts' \
            -cf - . |
            tar -C "$target_dir" -xf -
    fi
}

prepare_worktree() {
    echo "Project:         $PROJECT_NAME"
    echo "Erlang/OTP:      $ERLANG_VER"
    echo "Run ct:          $RUN_CT"
    echo "Run eunit:       $RUN_EUNIT"
    echo "Common Test:     ${TEST_SUITE:-ALL}${TEST_CASE:+:$TEST_CASE}"
    echo "Run xref:        $RUN_XREF"
    echo "Run Dialyzer:    $RUN_DIALYZER"
    echo "Use _checkouts:  $USE_CHECKOUTS"

    rm -rf "$WORK_DIR"
    mkdir -p "$WORK_DIR" "$HOME"

    if ! copy_worktree "$SRC_MOUNT" "$WORK_DIR"; then
        echo "Error: failed to copy the project worktree." >&2
        return 1
    fi

    if bool_enabled "$USE_CHECKOUTS"; then
        if [[ ! -d "$CHECKOUTS_DIR" ]]; then
            echo "Error: USE_CHECKOUTS is enabled but $CHECKOUTS_DIR is not mounted." >&2
            return 1
        fi
        mkdir -p "$WORK_DIR/_checkouts"
        local checkout
        for checkout in "$CHECKOUTS_DIR"/*; do
            [[ -d "$checkout" ]] || continue
            local checkout_name
            checkout_name="$(basename "$checkout")"
            if ! copy_worktree "$checkout" \
                "$WORK_DIR/_checkouts/$checkout_name"; then
                echo "Error: failed to copy checkout $checkout_name." >&2
                return 1
            fi
        done
    fi
    return 0
}

# --------------------------------------------------------------- stages --

# Run one stage command as a foreground subprocess, keeping its pid so
# INT/TERM can be forwarded, and emit the stage events around it.  The
# full stdout/stderr of the subprocess flows directly into the Docker
# output stream; no tee, no per-stage log files.
run_stage() {
    local name="$1"
    shift
    step "$(step_text "$name")"
    emit stage_started "$name"
    "$@" &
    local child=$!
    CURRENT_PID=$child
    wait "$child"
    local status=$?
    CURRENT_PID=""
    emit stage_finished "$name" "$status"
    return "$status"
}

ct_runs() {
    local dir="$1"
    [[ -d "$dir" ]] || return 0
    ls -1 "$dir" 2>/dev/null | grep '^ct_run\.' || true
}

# Emit this round's exact ct_run directory. Only directories that did not
# exist before the stage count as this round's; when Common Test failed
# before creating one, nothing is emitted and the host must not fall back
# to a historical run. More than one new directory is a protocol error.
emit_ct_run() {
    local logs="$1"
    local before="$2"
    local name
    local -a new=()
    local count=0
    while IFS= read -r name; do
        case " $before " in
            *" $name "*) ;;
            *) new+=("$name") ;;
        esac
    done < <(ct_runs "$logs")
    count=${#new[@]}
    case "$count" in
        0) return 0 ;;
        1) emit ct_run "${new[0]}" ;;
        *)
            echo "Error: Common Test created $count new ct_run directories; " \
                 "refusing to guess the round identity." >&2
            return 1
            ;;
    esac
}

# Publish this round's cover report with a same-directory staging rename.
# Failure fails the stage: a half-copied directory must never be linked.
publish_cover() {
    local from="$WORK_DIR/_build/test/cover"
    local to="$VER_RESULTS/cover"
    if [[ ! -d "$from" ]] || [[ -z "$(ls -A "$from" 2>/dev/null)" ]]; then
        return 0
    fi
    mkdir -p "$VER_RESULTS"
    local staging="$to.tmp"
    rm -rf "$staging"
    if ! cp -a "$from" "$staging"; then
        rm -rf "$staging"
        echo "Error: failed to stage cover report." >&2
        return 1
    fi
    rm -rf "$to"
    if ! mv "$staging" "$to"; then
        rm -rf "$staging"
        echo "Error: failed to publish cover report." >&2
        return 1
    fi
    return 0
}

run_common_test_stage() {
    mkdir -p "$CT_LOGS"
    local before
    before=$(ct_runs "$CT_LOGS" | tr '\n' ' ')
    step "$(step_text common_test)"
    emit stage_started common_test
    local -a args=(ct --logdir "$CT_LOGS")
    if [[ -n "$TEST_SUITE" ]]; then
        args+=(--suite "$TEST_SUITE")
    fi
    if [[ -n "$TEST_CASE" ]]; then
        args+=(--case "$TEST_CASE")
    fi
    rebar3 "${args[@]}" &
    local child=$!
    CURRENT_PID=$child
    wait "$child"
    local status=$?
    CURRENT_PID=""
    if [[ "$status" -eq 0 ]]; then
        emit_ct_run "$CT_LOGS" "$before" || status=1
    fi
    if [[ "$status" -eq 0 ]]; then
        publish_cover || status=1
    fi
    emit stage_finished common_test "$status"
    return "$status"
}

run_eunit_stage() {
    step "$(step_text eunit)"
    emit stage_started eunit
    rebar3 eunit &
    local child=$!
    CURRENT_PID=$child
    wait "$child"
    local status=$?
    CURRENT_PID=""
    if [[ "$status" -eq 0 ]]; then
        publish_cover || status=1
    fi
    emit stage_finished eunit "$status"
    return "$status"
}

step_text() {
    case "$1" in
        compile) echo "$MSG_COMPILE" ;;
        xref) echo "$MSG_XREF" ;;
        dialyzer) echo "$MSG_DIALYZER" ;;
        common_test) echo "$MSG_CT" ;;
        eunit) echo "$MSG_EUNIT" ;;
        *) echo "$1" ;;
    esac
}

# -------------------------------------------------------------- signals --

# The runner is the container PID 1; forward INT/TERM to the current stage
# subprocess and exit like the interrupted command.
forward_signal() {
    if [[ -n "${CURRENT_PID:-}" ]] && kill -0 "$CURRENT_PID" 2>/dev/null; then
        kill -TERM "$CURRENT_PID" 2>/dev/null
    fi
    exit 130
}
trap forward_signal INT TERM

# --------------------------------------------------------------- main ---

if ! prepare_worktree; then
    exit 1
fi

cd "$WORK_DIR" || exit 1

FIRST_FAILURE_STATUS=0

if run_stage compile rebar3 compile; then
    :
else
    FIRST_FAILURE_STATUS=$?
fi

if [[ "$FIRST_FAILURE_STATUS" -ne 0 ]] || ! bool_enabled "$RUN_XREF"; then
    emit stage_skipped xref
elif run_stage xref rebar3 xref; then
    :
else
    FIRST_FAILURE_STATUS=$?
fi

if [[ "$FIRST_FAILURE_STATUS" -ne 0 ]] || ! bool_enabled "$RUN_DIALYZER"; then
    emit stage_skipped dialyzer
elif run_stage dialyzer rebar3 dialyzer; then
    :
else
    FIRST_FAILURE_STATUS=$?
fi

if [[ "$FIRST_FAILURE_STATUS" -ne 0 ]] || ! bool_enabled "$RUN_CT"; then
    emit stage_skipped common_test
elif run_common_test_stage; then
    :
else
    FIRST_FAILURE_STATUS=$?
fi

if [[ "$FIRST_FAILURE_STATUS" -ne 0 ]] || ! bool_enabled "$RUN_EUNIT"; then
    emit stage_skipped eunit
elif run_eunit_stage; then
    :
else
    FIRST_FAILURE_STATUS=$?
fi

exit "$FIRST_FAILURE_STATUS"
