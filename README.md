# rebar3_docker_ci

`rebar3_docker_ci` runs Rebar3 checks against an Erlang/OTP version matrix in
isolated Docker worktrees. Host-side operation is implemented as Rebar3
providers, so consumer projects do not copy or synchronize CI scripts.

The plugin source supports Erlang/OTP 19 and newer.

## Installation

Add the plugin to the project `rebar.config`:

```erlang
{project_plugins, [
    {rebar3_docker_ci, "0.1.0"}
]}.
```

During local plugin development, a Rebar3 checkout can be used instead:

```text
_checkouts/rebar3_docker_ci -> /path/to/rebar3_docker_ci
```

```erlang
{project_plugins, [rebar3_docker_ci]}.
```

Docker Desktop or Docker Engine must be available in `PATH`.

## Configuration

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

`use_checkouts` accepts `auto`, `true`, or `false`. Auto mode includes a
non-empty `_checkouts` directory. Explicit `true` reports an error when no
checkout exists.

`output_lang` accepts `auto`, `en`, or `cn`. An automatic log volume is named
`rebar3-docker-ci-<project>` so projects do not overwrite one another's logs.

Common Test suite and case selection are intentionally not configuration
values. They are per-run command-line options.

## Build images

Build every configured Erlang/OTP image:

```text
rebar3 docker_ci build
```

Build one version:

```text
rebar3 docker_ci build --otp 28
```

Images are tagged `<image_name>:<otp>`. They contain the Erlang environment,
not a source snapshot, so source changes do not require rebuilding them.

## Run checks

Run the configured matrix:

```text
rebar3 docker_ci run --no-view
```

Run one OTP version and one suite:

```text
rebar3 docker_ci run --otp 28 --suite sample_SUITE --no-view
```

Run one case:

```text
rebar3 docker_ci run --otp 28 \
    --suite sample_SUITE --case sample_case --no-view
```

`--case` requires `--suite`. Other run overrides are:

- `--dialyzer`: enable Dialyzer for this run.
- `--skip-xref`: disable xref for this run.
- `--no-checkouts`: ignore `_checkouts` for this run.
- `--no-view`: return after checks without starting the log viewer.

For each OTP version, the container runs `rebar3 compile`, optional
`rebar3 xref`, optional `rebar3 dialyzer`, and `rebar3 ct`. A failed check
skips later checks for that version, but the remaining OTP matrix still runs.

Tracked modifications and unignored new files are copied using `git ls-files`.
The host project and checkout directories are mounted read-only, and host
`_build` data is never reused.

## View logs

```text
rebar3 docker_ci logs
rebar3 docker_ci logs --port 8082
```

The foreground Nginx viewer serves these paths for each OTP version:

```text
/<otp>/ci-summary.txt
/<otp>/logs/index.html
/<otp>/cover/index.html
```

Press Ctrl+C to stop the viewer.

## Migration from synchronized scripts

1. Remove the project's synchronized `ci_scripts` directory.
2. Add `rebar3_docker_ci` to `project_plugins`.
3. Convert `ci-env.conf` values to the `docker_ci` term above.
4. Replace script invocations with `rebar3 docker_ci build`, `run`, and
   `logs`.

No Astranaut dependency or synchronization launcher is required.

## Tests

```text
rebar3 eunit
rebar3 ct
```
