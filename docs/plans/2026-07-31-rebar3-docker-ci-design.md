# Rebar3 Docker CI Plugin Design

## Goal

Build a standalone `rebar3_docker_ci` plugin that provides the local Docker CI
capabilities currently stored in `astranaut/ci_scripts`. Consumer projects must
not depend on Astranaut or synchronize host scripts.

The plugin itself must compile on Erlang/OTP 19 and newer.

## User Interface

The plugin registers three providers in the `docker_ci` namespace:

```text
rebar3 docker_ci build
rebar3 docker_ci run
rebar3 docker_ci logs
```

The providers accept these command-line overrides:

```text
rebar3 docker_ci build --otp 28
rebar3 docker_ci run --otp 28 --suite my_SUITE --case my_case
rebar3 docker_ci run --dialyzer --skip-xref --no-checkouts --no-view
rebar3 docker_ci logs --port 8082
```

Common Test selection is command-line only. With no selection, `run` executes
all Common Test suites. `--suite` alone executes all cases in one suite.
`--case` is valid only together with `--suite`.

## Configuration

Projects configure the plugin in `rebar.config`:

```erlang
{docker_ci, [
    {erlang_versions, ["19", "28"]},
    {run_xref, true},
    {run_dialyzer, false},
    {use_checkouts, auto},
    {output_lang, auto},
    {log_port, 8081},
    {image_name, "rebar3-docker-ci"},
    {log_volume, auto}
]}.
```

Command-line values override configuration. `log_volume` set to `auto` derives
a stable, Docker-safe name from the project application name so independent
projects do not overwrite one another's logs.

`use_checkouts` accepts `auto`, `true`, or `false`. Auto mode includes a
non-empty project `_checkouts` directory. Explicit true fails when no checkout
is available.

## Architecture

Host-side orchestration is implemented in Erlang. It reads Rebar3 state and
options, validates input, resolves project and checkout paths, invokes the
Docker executable without a host shell, and streams Docker output. This removes
the Bash and PowerShell host entry points.

The Linux-only work performed inside the Erlang Docker image remains a small
shell runner in the plugin's `priv` directory. The runner creates a clean
snapshot, invokes Rebar3 checks, and exports logs. A Dockerfile in `priv` builds
the reusable images. Both resources are shipped with the plugin and mounted
read-only; they are never copied into consumer projects.

The source layout is:

```text
src/rebar3_docker_ci.app.src
src/rebar3_docker_ci.erl
src/rebar3_docker_ci_prv_build.erl
src/rebar3_docker_ci_prv_run.erl
src/rebar3_docker_ci_prv_logs.erl
src/rebar3_docker_ci_config.erl
src/rebar3_docker_ci_docker.erl
src/rebar3_docker_ci_project.erl
priv/Dockerfile
priv/inner_test.sh
```

The entry module registers three providers using the same established Rebar3
provider API style as `rebar3_erlando`. Provider modules translate parsed CLI
options into calls to configuration, project, and Docker modules. Domain
modules return structured errors, and providers expose them through
`format_error/1`.

All Erlang code avoids syntax and library calls introduced after OTP 19.

## Build Flow

`build` selects either `--otp` or the configured matrix. For every selected
version, it runs a Docker build using the packaged Dockerfile and tags the
result as `<image_name>:<otp>`. A failure stops the build and returns a provider
error.

Images contain only the Erlang/OTP environment. Source changes do not require
an image rebuild.

## Run Flow

Before starting containers, `run` validates Docker availability, CLI selection,
configuration, image existence, and checkout state. It creates the configured
log volume if needed.

Each project and checkout path is mounted read-only. The container runner uses
`git ls-files --cached --others --exclude-standard` to copy tracked changes and
unignored new files into a temporary work directory. Non-Git input falls back
to a tar copy that excludes `.git`, `_build`, and `_checkouts`.

For each OTP version, checks run in this order:

1. `rebar3 compile`
2. `rebar3 xref`, when enabled
3. `rebar3 dialyzer`, when enabled
4. `rebar3 ct`, with optional suite and case arguments

A failed step skips later checks for that OTP version. The remaining matrix
versions still run. Any failed version makes the provider fail after the matrix
finishes.

The runner always writes a per-version `ci-summary.txt` and exports available
Common Test and coverage output. The summary uses the real project name rather
than an Astranaut constant.

## Logs Flow

`logs` verifies that the project volume exists, reports available summary, CT,
and coverage URLs for the configured versions, and starts a foreground
`nginx:alpine` container. `--port` overrides the configured port. Ctrl+C stops
the viewer.

## Error Handling

Configuration errors are rejected before Docker work starts. Error messages
distinguish missing Docker, missing images, invalid OTP matrices, invalid
suite/case combinations, invalid checkout paths, Docker command failures, and
CI check failures. Docker is executed with an argument list rather than a shell
command so user paths and Common Test names cannot alter command structure.

## Testing

EUnit tests cover configuration defaults and overrides, CLI validation, Docker
argument construction, project and volume name normalization, and matrix result
aggregation. Docker execution is replaceable in tests with a fake runner so
ordinary tests do not require Docker.

Shell-runner tests use temporary Git repositories and a fake `rebar3` command
to verify snapshot selection, suite/case construction, check short-circuiting,
summary output, and log export.

Initial development uses a temporary copy of the sibling Astranaut repository
to verify provider loading and the real Docker flow. That initialization
fixture is not part of this plugin's source or release artifacts. OTP 19
compatibility is also verified directly against the plugin.

## Migration

Consumer repositories remove their synchronized `ci_scripts`, add the plugin
and `docker_ci` term to `rebar.config`, then use the namespaced Rebar3 commands.
There is no `sync_ci` replacement because plugin installation supplies the
implementation directly. Production code, defaults, documentation, and
runtime output contain no Astranaut dependency.
