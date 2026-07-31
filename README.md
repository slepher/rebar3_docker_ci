# rebar3_docker_ci

[中文说明](README.zh.md)

`rebar3_docker_ci` is a host-side Rebar3 plugin that runs a project against an
Erlang/OTP matrix in isolated Docker containers. It replaces copied or
synchronized CI scripts with three Rebar3 commands:

```text
rebar3 docker_ci build
rebar3 docker_ci run
rebar3 docker_ci logs
```

## Compatibility model

The plugin and the project under test have independent OTP requirements:

- The `0.1.2` release runs the plugin on Erlang/OTP 27 or newer.
- The `otp-19-0.1.2` release preserves a host plugin compatible with OTP 19.
- Docker targets are selected by project configuration and may use OTP 19,
  OTP 21, or any other available official Erlang image.

The plugin must be installed globally on the developer machine. It must not be
listed in the target project's `project_plugins`, because project plugins are
loaded again inside the container and would couple the target OTP to the
plugin's host requirement.

## Requirements

- Erlang/OTP 27 or newer on the developer machine
- A compatible Rebar3 installation
- Docker Desktop or Docker Engine available in `PATH`
- Git when the project is a Git worktree

Use the `otp-19` branch and `otp-19-0.1.2` tag when the developer machine itself
must run OTP 19.

## Installation

Add the plugin to the developer machine's global Rebar3 configuration at
`~/.config/rebar3/rebar.config`:

```erlang
{plugins, [
    {rebar3_docker_ci,
     {git, "https://github.com/slepher/rebar3_docker_ci.git",
      {tag, "0.1.2"}}}
]}.
```

Confirm that Rebar3 can see the providers:

```text
rebar3 help docker_ci
rebar3 help docker_ci build
rebar3 help docker_ci run
rebar3 help docker_ci logs
```

The first command lists the available tasks. The task-specific forms show every
option, including `--otp`, `--suite`, `--case`, and their constraints.

The target project's `rebar.config` contains only the `docker_ci` settings. Do
not add `rebar3_docker_ci` to its `project_plugins`.

## Project configuration

```erlang
{docker_ci, [
    {erlang_versions, ["19", "21", "23", "28", "29"]},
    {run_xref, true},
    {run_dialyzer, false},
    {use_checkouts, auto},
    {output_lang, auto},
    {log_port, 8081},
    {image_name, "rebar3-docker-ci"},
    {log_volume, auto}
]}.
```

| Option | Default | Description |
| --- | --- | --- |
| `erlang_versions` | `["19", "28"]` | Non-empty Docker image tag matrix. |
| `run_xref` | `true` | Run `rebar3 xref` after compilation. |
| `run_dialyzer` | `false` | Run `rebar3 dialyzer` before Common Test. |
| `use_checkouts` | `auto` | Include `_checkouts`: `auto`, `true`, or `false`. |
| `output_lang` | `auto` | Runner output language: `auto`, `en`, or `cn`. |
| `log_port` | `8081` | Host port used by the log viewer. |
| `image_name` | `"rebar3-docker-ci"` | Docker image repository name. |
| `log_volume` | `auto` | Docker volume name; `auto` isolates projects by name. |

Common Test suite and case selection are intentionally command-line-only.
`--suite` may be used alone. `--case` requires `--suite`.

## Build images

Build the configured matrix:

```text
rebar3 docker_ci build
```

Build one target image:

```text
rebar3 docker_ci build --otp 29
```

Images are tagged `<image_name>:<otp>`. They contain Erlang and Rebar3, not a
project source snapshot, so source changes do not require rebuilding images.

## Run checks

Run every configured OTP target without starting the log viewer:

```text
rebar3 docker_ci run --no-view
```

Run one OTP target:

```text
rebar3 docker_ci run --otp 23 --no-view
```

Run one Common Test suite:

```text
rebar3 docker_ci run --otp 28 --suite sample_SUITE --no-view
```

Run one case from a suite:

```text
rebar3 docker_ci run --otp 29 \
    --suite sample_SUITE --case sample_case --no-view
```

Run overrides:

- `--dialyzer` enables Dialyzer for this run.
- `--skip-xref` disables xref for this run.
- `--no-checkouts` ignores the project's `_checkouts` directory.
- `--no-view` returns after testing instead of starting Nginx.

For each OTP version the runner executes compile, optional xref, optional
Dialyzer, and Common Test in that order. A failed step skips later steps for
that version, while the remaining matrix continues. The command fails after
all selected versions finish if any version failed.

## Source isolation and checkouts

The host project is mounted read-only. The container creates a temporary
worktree using files reported by:

```text
git ls-files --cached --others --exclude-standard
```

Tracked modifications and unignored new files are tested, while host `_build`
data is not reused. When `use_checkouts` is enabled, each checkout is mounted
read-only and copied into the isolated worktree. Explicit `true` reports an
error if `_checkouts` is missing or empty; `auto` simply disables checkout
handling in that case.

## Logs and coverage

Run the foreground viewer after a test run:

```text
rebar3 docker_ci logs
rebar3 docker_ci logs --port 8082
```

Nginx serves the Docker log volume at:

```text
/<otp>/ci-summary.txt
/<otp>/logs/index.html
/<otp>/cover/index.html
```

Press Ctrl+C to stop the viewer. `ci-summary.txt` records each step's status
even when a later step is skipped.

## Migrating synchronized CI scripts

1. Install the plugin in the developer machine's global Rebar3 configuration.
2. Convert `ERLANG_VSNS`, `RUN_XREF`, `RUN_DIALYZER`, `USE_CHECKOUTS`,
   `OUTPUT_LANG`, and `LOG_PORT` into the `docker_ci` term.
3. Move suite and case selection to `--suite` and `--case` command options.
4. Replace script calls with the `build`, `run`, and `logs` providers.
5. Remove copied `ci_scripts` files after the new commands pass.

The resulting project no longer depends on Astranaut or another repository for
CI implementation files.

## Development checks

```text
rebar3 compile
rebar3 eunit
rebar3 ct
```

The plugin has also been integration-tested against Astranaut on OTP 19, 21,
23, 28, and 29, including xref, 386 Common Test cases per full-matrix target,
suite-only selection, case selection, log export, and coverage export.
