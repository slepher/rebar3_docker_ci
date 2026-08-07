#!/usr/bin/env bash
set -uo pipefail

SRC_MOUNT="${SRC_MOUNT:-/mnt/source}"
RESULTS_DIR="${RESULTS_DIR:-/mnt/results}"
PROJECT_NAME="${PROJECT_NAME:-project}"
WORK_DIR="${WORK_DIR:-/tmp/build/$PROJECT_NAME}"

ERLANG_VER="${ERLANG_VER:-$(erl -noshell -eval \
    'io:format("~s", [erlang:system_info(otp_release)]), halt().')}"
TEST_SUITE="${TEST_SUITE:-}"
TEST_CASE="${TEST_CASE:-}"
RUN_XREF="${RUN_XREF:-true}"
RUN_DIALYZER="${RUN_DIALYZER:-false}"
USE_CHECKOUTS="${USE_CHECKOUTS:-auto}"
TEST_FRAMEWORK="${TEST_FRAMEWORK:-common_test}"
OUTPUT_LANG="${OUTPUT_LANG:-en}"

VER_RESULTS="$RESULTS_DIR/$ERLANG_VER"
SUMMARY_FILE="$VER_RESULTS/ci-summary.txt"

if [[ "$OUTPUT_LANG" == "cn" ]]; then
    MSG_PREPARE="准备隔离工作目录"
    MSG_COMPILE="编译项目"
    MSG_XREF="运行交叉引用检查"
    MSG_DIALYZER="运行 Dialyzer"
    MSG_TEST="运行 Common Test"
    MSG_EXPORT="导出测试日志与覆盖率"
else
    MSG_PREPARE="Preparing isolated work directory"
    MSG_COMPILE="Compiling project"
    MSG_XREF="Running cross-reference checks"
    MSG_DIALYZER="Running Dialyzer"
    MSG_TEST="Running Common Test"
    MSG_EXPORT="Exporting test logs and coverage"
fi

step() {
    echo
    echo "================================================================"
    echo ">>> $1"
    echo "================================================================"
}

run_check() {
    local name="$1"
    shift

    echo "CMD: $*"
    "$@" 2>&1 | tee "$VER_RESULTS/$name.log"
    local status="${PIPESTATUS[0]}"
    printf '%s=%s\n' "$name" "$status" >> "$SUMMARY_FILE"
    return "$status"
}

bool_enabled() {
    [[ "${1,,}" == "true" || "$1" == "1" || "${1,,}" == "yes" ]]
}

extract_failures() {
    local out_file="$1"
    local prev_run_dir="$2"
    local newest_run_dir block_count suite_log

    rm -f "$out_file"
    newest_run_dir=$(ls -dt _build/test/logs/ct_run.* 2>/dev/null | head -1)
    if [[ -z "$newest_run_dir" || "$newest_run_dir" == "$prev_run_dir" ]]; then
        return 0
    fi

    local temp_file="$out_file.blocks"
    : > "$temp_file"
    while IFS= read -r -d '' suite_log; do
        awk '
            function flush_failure(   i, seg, comma, lseg) {
                if (in_failure) {
                    printf "suite=%s\n", suite
                    printf "case=%s\n", case_name
                    printf "reason=%s", reason
                    if (module != "") {
                        printf " at %s:%s", module, frame_line
                    }
                    printf "\n"
                    printf "logfile=%s\n", logfile
                    printf "---\n"
                    in_failure = 0
                }
            }
            function update_case(line,   i) {
                i = index(line, ":")
                if (i > 0) {
                    suite = substr(line, 1, i - 1)
                    case_name = substr(line, i + 1)
                } else {
                    suite = line
                    case_name = line
                }
            }
            /^=case[[:space:]]/ {
                flush_failure()
                line = $0
                sub(/^=case[[:space:]]+/, "", line)
                update_case(line)
            }
            /^=logfile[[:space:]]/ {
                logfile = $0
                sub(/^=logfile[[:space:]]+/, "", logfile)
                gsub(/^[[:space:]]+|[[:space:]]+$/, "", logfile)
            }
            /^=result/ {
                flush_failure()
                line = $0
                sub(/^=result[[:space:]]+failed:[[:space:]]*/, "", line)
                if (line != $0) {
                    in_failure = 1
                    reason = line
                    gsub(/^[[:space:]]+|[[:space:]]+$/, "", reason)
                    if (reason ~ /^\{\{/) { reason = substr(reason, 2) }
                    gsub(/,$/, "", reason)
                    module = ""
                    frame_line = ""
                }
            }
            in_failure && !/^=/ {
                if (module == "" &&
                    match($0, /\{[A-Za-z0-9_]+,[A-Za-z0-9_]+,[0-9]+,/)) {
                    seg = substr($0, RSTART, RLENGTH)
                    comma = index(seg, ",")
                    module = substr(seg, 2, comma - 2)
                }
                if (frame_line == "" && match($0, /\{line,[0-9]+\}/)) {
                    lseg = substr($0, RSTART, RLENGTH)
                    gsub(/[^0-9]/, "", lseg)
                    frame_line = lseg
                }
            }
            END { flush_failure() }
        ' "$suite_log" >> "$temp_file"
    done < <(find "$newest_run_dir" -name suite.log -print0)

    block_count=$(grep -c '^---$' "$temp_file" 2>/dev/null || true)
    if [[ "$block_count" -gt 0 ]]; then
        printf 'failure_count=%s\n' "$block_count" > "$out_file"
        cat "$temp_file" >> "$out_file"
    else
        rm -f "$out_file"
    fi
    rm -f "$temp_file"
}

if [[ "${USE_CHECKOUTS,,}" == "auto" ]]; then
    USE_CHECKOUTS=false
    if [[ -d "/mnt/checkouts" ]]; then
        for checkout_path in /mnt/checkouts/*; do
            if [[ -d "$checkout_path" ]]; then
                USE_CHECKOUTS=true
                break
            fi
        done
    fi
fi

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

echo "Project:         $PROJECT_NAME"
echo "Erlang/OTP:      $ERLANG_VER"
echo "Test framework:  $TEST_FRAMEWORK"
echo "Common Test:     ${TEST_SUITE:-ALL}${TEST_CASE:+:$TEST_CASE}"
echo "Run xref:        $RUN_XREF"
echo "Run Dialyzer:    $RUN_DIALYZER"
echo "Use _checkouts:  $USE_CHECKOUTS"

step "$MSG_PREPARE"
rm -rf "$WORK_DIR"
mkdir -p "$WORK_DIR" "$VER_RESULTS"

if ! copy_worktree "$SRC_MOUNT" "$WORK_DIR"; then
    echo "Error: failed to copy the project worktree." >&2
    exit 1
fi

CHECKOUT_NAMES=()
if bool_enabled "$USE_CHECKOUTS"; then
    if [[ ! -d "/mnt/checkouts" ]]; then
        echo "Error: USE_CHECKOUTS is enabled but /mnt/checkouts is not mounted." >&2
        exit 1
    fi
    mkdir -p "$WORK_DIR/_checkouts"
    for CHECKOUT in /mnt/checkouts/*; do
        [[ -d "$CHECKOUT" ]] || continue
        CHECKOUT_NAME="$(basename "$CHECKOUT")"
        if ! copy_worktree "$CHECKOUT" "$WORK_DIR/_checkouts/$CHECKOUT_NAME"; then
            echo "Error: failed to copy checkout $CHECKOUT_NAME." >&2
            exit 1
        fi
        CHECKOUT_NAMES+=("$CHECKOUT_NAME")
    done
fi

mkdir -p "$WORK_DIR/_build/test/logs"
if [[ -d "$VER_RESULTS/logs" ]] &&
   [[ -n "$(ls -A "$VER_RESULTS/logs" 2>/dev/null)" ]]; then
    cp -r "$VER_RESULTS/logs"/. "$WORK_DIR/_build/test/logs/"
fi

rm -f "$SUMMARY_FILE"
cat > "$SUMMARY_FILE" <<EOF
project=$PROJECT_NAME
erlang_otp=$ERLANG_VER
test_suite=${TEST_SUITE:-ALL}
test_case=${TEST_CASE:-ALL}
test_framework=$TEST_FRAMEWORK
use_checkouts=$USE_CHECKOUTS
checkouts=${CHECKOUT_NAMES[*]:-none}
EOF

cd "$WORK_DIR" || exit 1
CI_EXIT_CODE=0
PREV_LOG_RUN_DIR=$(ls -dt _build/test/logs/ct_run.* 2>/dev/null | head -1)

step "$MSG_COMPILE"
run_check compile rebar3 compile || CI_EXIT_CODE=$?

if [[ $CI_EXIT_CODE -eq 0 ]] && bool_enabled "$RUN_XREF"; then
    step "$MSG_XREF"
    run_check xref rebar3 xref || CI_EXIT_CODE=$?
else
    printf 'xref=skipped\n' >> "$SUMMARY_FILE"
fi

if [[ $CI_EXIT_CODE -eq 0 ]] && bool_enabled "$RUN_DIALYZER"; then
    step "$MSG_DIALYZER"
    run_check dialyzer rebar3 dialyzer || CI_EXIT_CODE=$?
else
    printf 'dialyzer=skipped\n' >> "$SUMMARY_FILE"
fi

if [[ $CI_EXIT_CODE -eq 0 ]]; then
    case "$TEST_FRAMEWORK" in
        eunit)
            step "$MSG_TEST"
            run_check eunit rebar3 eunit || CI_EXIT_CODE=$?
            ;;
        *)
            CT_COMMAND=(rebar3 ct)
            if [[ -n "$TEST_SUITE" ]]; then
                CT_COMMAND+=(--suite "$TEST_SUITE")
            fi
            if [[ -n "$TEST_CASE" ]]; then
                CT_COMMAND+=(--case "$TEST_CASE")
            fi

            step "$MSG_TEST"
            run_check common_test "${CT_COMMAND[@]}" || CI_EXIT_CODE=$?
            ;;
    esac
else
    TEST_KEY="common_test"
    [[ "$TEST_FRAMEWORK" == "eunit" ]] && TEST_KEY="eunit"
    printf '%s=skipped\n' "$TEST_KEY" >> "$SUMMARY_FILE"
fi

if [[ "$TEST_FRAMEWORK" != "eunit" ]]; then
    extract_failures "$VER_RESULTS/failures.txt" "$PREV_LOG_RUN_DIR"
fi

step "$MSG_EXPORT"
mkdir -p "$VER_RESULTS/logs" "$VER_RESULTS/cover"

if [[ -d "_build/test/logs" ]]; then
    rm -rf "$VER_RESULTS/logs"/*
    cp -r _build/test/logs/. "$VER_RESULTS/logs/"
fi

if [[ -d "_build/test/cover" ]]; then
    rm -rf "$VER_RESULTS/cover"/*
    cp -r _build/test/cover/. "$VER_RESULTS/cover/"
fi

printf 'result=%s\n' "$CI_EXIT_CODE" >> "$SUMMARY_FILE"
exit "$CI_EXIT_CODE"
