# Direct Docker Images Design

## Goal

Release `0.2.0` with no default Erlang/OTP targets and no locally built
`rebar3-docker-ci:<otp>` wrapper images. Projects configure exactly one target
source, pull those images, and run CI directly in them.

## Configuration Contract

A project must configure exactly one of these options:

```erlang
{docker_ci, [
    {erlang_versions, ["27", "28"]}
]}.
```

or:

```erlang
{docker_ci, [
    {docker_images, ["erlang:27", "erlang:28"]}
]}.
```

`erlang_versions` is shorthand. Each version becomes the Docker image reference
`erlang:<version>`. `docker_images` accepts complete image references from
Docker Hub or another registry. Both lists must be non-empty and their entries
must be safe non-empty strings. Configuring neither or both is an error.

All other options retain their current defaults. `image_name` is removed in
`0.2.0`; configuring it is reported as an unknown, removed option with guidance
to use `erlang_versions` or `docker_images`.

Missing target configuration reports a minimal example for both modes and
points to `rebar3 help docker_ci config`.

## Providers

The `build` provider is removed and replaced by `pull`:

```text
rebar3 docker_ci pull
```

`pull` converts configured targets to image references and runs `docker pull`
for each image. It does not invoke `docker build` and does not create local
wrapper tags.

A new `config` provider makes the configuration contract discoverable:

```text
rebar3 help docker_ci
rebar3 help docker_ci config
rebar3 docker_ci config
```

The command prints both minimal target forms, the optional fields and their
defaults, and the currently normalized target images when configuration is
valid. It remains usable when target configuration is missing.

`run` resolves all configured entries to a common internal target structure.
It verifies that every image exists locally, then starts short-lived containers
with an overridden `erl` entrypoint to read the actual OTP release. Duplicate
detected releases are rejected because reports use the release as their volume
directory. The test container overrides the entrypoint with `bash`, mounts the
existing runner, source tree, checkouts, and log volume, and sets `ERLANG_VER`
to the detected release.

`--otp <release>` filters targets by the detected OTP release. Images must have
been pulled before `run`; missing images direct the user to `docker_ci pull`.

`logs` uses detected target releases when images are available and otherwise
uses releases already represented in the log volume. Report URLs retain the
existing `/<otp>/...` layout.

## Image Requirements

Runnable images must provide:

- `erl`, for release detection;
- `bash`, for `inner_test.sh`;
- `rebar3`, for checks;
- `git` and `tar`, for isolated worktree copying.

Detection uses explicit Docker entrypoint overrides so an image's configured
entrypoint does not alter plugin commands. Detection and runtime failures name
the offending image and the missing capability where possible.

## Output

Matrix summaries continue to list actual OTP releases. Custom image references
are included for traceability:

```text
>>> Erlang/OTP 27 [erlang:27]: PASSED
>>> Erlang/OTP 28 [example/erlang-ci:latest]: PASSED
```

HTTP Summary, Logs, and Cover URLs continue to use actual OTP releases.

## Compatibility And Release

This is a breaking command and configuration change, so both branches use
version `0.2.0`:

- `master` tag: `0.2.0`, host baseline OTP 27;
- `otp-19` tag: `otp-19-0.2.0`, host baseline OTP 19.

Both implementations provide the same behavior while retaining their existing
branch-specific Erlang syntax.

## Testing

Tests cover required and mutually exclusive target configuration, shorthand
normalization, image reference validation, pull arguments, entrypoint overrides,
OTP release parsing, duplicate release rejection, provider registration and
help, selected target filtering, summary labels, and preservation of machine
summary files. Both branches run their full EUnit and Common Test suites; the
OTP 19 branch is additionally compiled and tested inside the OTP 19 image.
