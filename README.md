# rebar3_docker_ci

[中文说明](README.zh.md)

`rebar3_docker_ci` is a host-side Rebar3 plugin that runs a project against an
Erlang/OTP matrix in isolated Docker containers. It replaces copied or
synchronized CI scripts with standard Rebar3 commands:

```text
rebar3 docker_ci config
rebar3 docker_ci pull
rebar3 docker_ci run
rebar3 docker_ci logs
```

## Compatibility model

The plugin host and the project under test have independent OTP requirements:

- Release `0.2.0` runs the plugin on Erlang/OTP 27 or newer.
- Tag `otp-19-0.2.0` preserves a host plugin compatible with OTP 19.
- Test targets may use older or newer OTP releases provided by Docker images.

Install the plugin globally on the developer machine. Do not list it in the
target project's `project_plugins`: project plugins are loaded inside the test
container and would couple the target OTP to the host plugin requirement.

## Requirements

- Erlang/OTP 27 or newer on the developer machine
- A compatible Rebar3 installation
- Docker Desktop or Docker Engine available in `PATH`
- Git when the project is a Git worktree

Use `otp-19-0.2.0` when the developer machine itself must run OTP 19.

## Installation

Add the plugin to `~/.config/rebar3/rebar.config`:

```erlang
{plugins, [
    {rebar3_docker_ci,
     {git, "https://github.com/slepher/rebar3_docker_ci.git",
      {tag, "0.2.0"}}}
]}.
```

Confirm that Rebar3 can see every provider and its options:

```text
rebar3 help docker_ci
rebar3 help docker_ci config
rebar3 help docker_ci pull
rebar3 help docker_ci run
rebar3 help docker_ci logs
```

The target project's `rebar.config` contains only the `docker_ci` settings.

## Project configuration

Exactly one target source is required. For official Erlang Docker Hub images:

```erlang
{docker_ci, [
    {erlang_versions, ["19", "21", "23", "28", "29"]},
    {run_xref, true},
    {run_dialyzer, false},
    {use_checkouts, auto},
    {output_lang, auto},
    {log_port, 8081},
    {log_volume, auto}
]}.
```

Each entry becomes `erlang:<version>`. To use arbitrary pullable images instead:

```erlang
{docker_ci, [
    {docker_images, [
        "erlang:27",
        "registry.example.com/team/erlang-ci:28"
    ]}
]}.
```

`erlang_versions` and `docker_images` are mutually exclusive. There is no
default target matrix; missing, empty, or conflicting target configuration is
an error. Run `rebar3 docker_ci config` to print examples, defaults, the current
validation result, and normalized image names.

| Option | Default | Description |
| --- | --- | --- |
| `erlang_versions` | required alternative | Non-empty OTP tags expanded to `erlang:<version>`. |
| `docker_images` | required alternative | Non-empty full Docker image references. |
| `run_xref` | `true` | Run `rebar3 xref` after compilation. |
| `run_dialyzer` | `false` | Run `rebar3 dialyzer` before Common Test. |
| `use_checkouts` | `auto` | Include `_checkouts`: `auto`, `true`, or `false`. |
| `output_lang` | `auto` | Runner output language: `auto`, `en`, or `cn`. |
| `log_port` | `8081` | Host port used by the log viewer. |
| `log_volume` | `auto` | Docker volume name; `auto` isolates projects by name. |

Common Test suite and case selection are command-line-only. `--suite` may be
used alone; `--case` requires `--suite`.

## Pull images

Pull every configured image before the first run or after changing targets:

```text
rebar3 docker_ci pull
```

The plugin runs these images directly. It does not build a wrapper image. Each
image must contain Erlang, Rebar3, Bash, and the standard tools required by the
project. The actual OTP release is detected by running `erl` in each image;
`--otp` selection and log paths use that detected release rather than its tag.
Two configured images must not report the same OTP release.

## Run checks

```text
# Entire configured matrix, without starting the log viewer
rebar3 docker_ci run --no-view

# One detected OTP release
rebar3 docker_ci run --otp 23 --no-view

# One Common Test suite
rebar3 docker_ci run --otp 28 --suite sample_SUITE --no-view

# One case from a suite
rebar3 docker_ci run --otp 29 --suite sample_SUITE --case sample_case --no-view
```

Run overrides:

- `--dialyzer` enables Dialyzer for this run.
- `--skip-xref` disables xref for this run.
- `--no-checkouts` ignores the project's `_checkouts` directory.
- `--no-view` returns after testing instead of starting Nginx.

For each target the runner executes compile, optional xref, optional Dialyzer,
and Common Test in that order. A failed step skips later steps for that target,
while the remaining matrix continues. The final summary lists every selected
OTP release and source image, followed by the overall result and HTTP log links
when the viewer is enabled.

## Source isolation and checkouts

The host project is mounted read-only. The container copies files reported by:

```text
git ls-files --cached --others --exclude-standard
```

Tracked modifications and unignored new files are tested without reusing host
`_build` data. Enabled checkouts are mounted read-only and copied into the
isolated worktree. Explicit `true` reports missing or empty `_checkouts`; `auto`
silently disables checkout handling in that case.

## Logs and coverage

Start the foreground viewer after a test run:

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

Press Ctrl+C to stop the viewer and its container. Only configured images are
reported, using their detected OTP releases. `ci-summary.txt` records each
step's status even when a later step is skipped.

## Migrating synchronized CI scripts

1. Install the plugin in the developer machine's global Rebar3 configuration.
2. Add exactly one of `erlang_versions` or `docker_images` to `rebar.config`.
3. Convert the remaining CI environment values into optional `docker_ci` fields.
4. Move suite and case selection to `--suite` and `--case`.
5. Replace script calls with the `pull`, `run`, and `logs` providers.
6. Remove copied `ci_scripts` after the new commands pass.

The project then has no runtime dependency on Astranaut or another repository
for CI implementation files.

## Development checks

```text
rebar3 do compile, eunit, ct
```

The plugin is integration-tested against Astranaut on OTP 19, 21, 23, 28, and
29, including xref, Common Test, suite/case selection, log export, and coverage.
