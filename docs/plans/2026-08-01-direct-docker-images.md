# Direct Docker Images Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Release `0.2.0` with required, mutually exclusive `erlang_versions` or `docker_images` targets, direct image pulls, and direct CI execution without wrapper image builds.

**Architecture:** Normalize both configuration forms into image references, then resolve each local image to an actual OTP release before filtering or running the matrix. Replace the build provider with pull and config providers, preserve release-based report directories, and implement equivalent behavior with branch-appropriate syntax on `master` and `otp-19`.

**Tech Stack:** Erlang/Rebar3 providers, Docker CLI, Bash container runner, EUnit, Common Test.

---

### Task 1: Required Target Configuration

**Files:**
- Modify: `src/rebar3_docker_ci_config.erl`
- Modify: `src/rebar3_docker_ci.erl`
- Test: `test/rebar3_docker_ci_config_tests.erl`

**Step 1: Write failing configuration tests**

Add cases for missing targets, mutually exclusive targets, version shorthand,
full image references, empty lists, unsafe entries, and removed `image_name`.
Expected normalized values:

```erlang
#{target_images => ["erlang:27", "erlang:28"],
  target_source => erlang_versions}
```

and:

```erlang
#{target_images => ["erlang:27", "example/ci:29"],
  target_source => docker_images}
```

**Step 2: Run tests and verify red**

Run:

```bash
rebar3 eunit --module=rebar3_docker_ci_config_tests
```

Expected: missing configuration still receives default versions and
`docker_images` is rejected as unknown.

**Step 3: Implement the contract**

Remove `erlang_versions` and `image_name` from defaults. Keep a separate allowed
key set containing both target keys and optional settings. Require exactly one
target key and normalize it to `target_images` plus `target_source`.

Return explicit errors:

```erlang
{error, {missing_target_config, [erlang_versions, docker_images]}}
{error, {conflicting_target_config, erlang_versions, docker_images}}
{error, {removed_config, image_name}}
```

Add actionable `format_error/1` clauses containing both minimal `rebar.config`
examples and `rebar3 help docker_ci config`.

**Step 4: Run tests and verify green**

Run the targeted EUnit module and `rebar3 compile`.

**Step 5: Commit**

```bash
git add src/rebar3_docker_ci_config.erl src/rebar3_docker_ci.erl test/rebar3_docker_ci_config_tests.erl
git commit -m "feat: require explicit Docker CI targets"
```

### Task 2: Docker Pull And Target Detection

**Files:**
- Modify: `src/rebar3_docker_ci_docker.erl`
- Test: `test/rebar3_docker_ci_docker_tests.erl`

**Step 1: Write failing argument and parser tests**

Cover:

```erlang
pull_args("erlang:27") -> ["pull", "erlang:27"].
inspect_image_args("erlang:27") -> ["image", "inspect", "erlang:27"].
detect_otp_args("erlang:27") ->
    ["run", "--rm", "--entrypoint", "erl", "erlang:27", ...].
```

Add captured execution support returning `{ok, Output}` and a pure OTP output
parser accepting `"27\n"` while rejecting empty or unsafe releases.

Update run argument expectations so the target contains both `image` and
detected `otp`, uses `--entrypoint bash`, and no longer constructs
`<image_name>:<version>`.

**Step 2: Run tests and verify red**

Run:

```bash
rebar3 eunit --module=rebar3_docker_ci_docker_tests
```

**Step 3: Implement minimal Docker APIs**

Replace build-specific argument builders with pull, direct image inspection,
captured execution, OTP detection, and direct run arguments. Keep arguments as
lists passed to `open_port`; do not introduce a host shell.

**Step 4: Run targeted and full tests**

Run the Docker EUnit module, then `rebar3 do compile, eunit`.

**Step 5: Commit**

```bash
git add src/rebar3_docker_ci_docker.erl test/rebar3_docker_ci_docker_tests.erl
git commit -m "feat: pull and run direct Docker images"
```

### Task 3: Pull And Config Providers

**Files:**
- Delete: `src/rebar3_docker_ci_prv_build.erl`
- Create: `src/rebar3_docker_ci_prv_pull.erl`
- Create: `src/rebar3_docker_ci_prv_config.erl`
- Modify: `src/rebar3_docker_ci.erl`
- Test: `test/rebar3_docker_ci_provider_tests.erl`

**Step 1: Write failing provider tests**

Expect provider modules in this order:

```erlang
[rebar3_docker_ci_prv_config,
 rebar3_docker_ci_prv_pull,
 rebar3_docker_ci_prv_run,
 rebar3_docker_ci_prv_logs]
```

Test pull continuation and aggregated failures with an injected pull function.
Test configuration example text independently from Rebar3 console output.

**Step 2: Verify tests fail**

Run provider EUnit tests and confirm missing modules/functions.

**Step 3: Implement providers**

`pull` loads normalized `target_images` and executes `docker pull` for each,
continuing through the list and returning all failures.

`config` does not require valid target configuration to print the full example.
When configuration is valid, it additionally prints normalized target images.
Its provider description supplies detailed output for:

```text
rebar3 help docker_ci config
```

**Step 4: Verify provider help and tests**

Run:

```bash
rebar3 do compile, eunit
rebar3 help docker_ci
rebar3 help docker_ci config
```

Use an isolated global plugin cache for the final help verification after a
commit exists.

**Step 5: Commit**

```bash
git add src test
git commit -m "feat: replace build with pull and config providers"
```

### Task 4: Resolve And Run Image Targets

**Files:**
- Modify: `src/rebar3_docker_ci_prv_run.erl`
- Modify: `src/rebar3_docker_ci_prv_logs.erl`
- Modify: `src/rebar3_docker_ci.erl`
- Test: `test/rebar3_docker_ci_provider_tests.erl`

**Step 1: Write failing target resolution tests**

Use an injected detector to cover successful resolution, missing images,
detection failures, duplicate actual OTP releases, and `--otp` selection by
actual release. The resolved structure is:

```erlang
#{image => "erlang:27", otp => "27"}
```

**Step 2: Verify red**

Run provider EUnit tests.

**Step 3: Implement target resolution**

Inspect each configured image, direct missing-image errors to `docker_ci pull`,
detect the actual release, reject duplicate releases, then apply `--otp`.
Pass resolved targets into Docker run arguments and matrix summaries. Include
the source image beside each OTP release in summaries.

Update `logs` to print release-based links from resolved targets. If images are
not local, enumerate existing top-level log directories from the Docker volume
instead of inventing releases from image tags.

**Step 4: Verify tests**

Run full EUnit and Common Test suites.

**Step 5: Commit**

```bash
git add src test
git commit -m "feat: resolve actual OTP releases from images"
```

### Task 5: Documentation And Version 0.2.0

**Files:**
- Modify: `README.md`
- Modify: `README.zh.md`
- Modify: `src/rebar3_docker_ci.app.src`
- Delete: `priv/Dockerfile`

**Step 1: Update documentation**

Document both mutually exclusive forms, `pull`, `config`, direct execution,
image requirements, actual-release selection, errors, and migration from
`build`/`image_name`.

**Step 2: Remove obsolete Dockerfile and bump version**

Set application version to `0.2.0` and remove the unused wrapper Dockerfile.

**Step 3: Verify references**

Run:

```bash
rg -n "docker_ci build|prv_build|image_name|priv/Dockerfile|0\.1\.3" README.md README.zh.md src test priv
```

Expected: only intentional migration/error references remain.

**Step 4: Run all tests**

```bash
rebar3 do clean, compile, eunit, ct
```

Expected: all tests pass with warnings treated as errors.

**Step 5: Commit**

```bash
git add README.md README.zh.md src priv
git commit -m "docs: prepare direct-image 0.2.0 release"
```

### Task 6: Real Astranaut Verification

**Files:**
- Modify temporarily, do not commit: `intergration/astranaut/rebar.config`

**Step 1: Configure shorthand targets**

Use Astranaut's existing versions:

```erlang
{erlang_versions, ["19", "21", "23", "28", "29"]}
```

**Step 2: Pull images**

Run `rebar3 docker_ci pull` from an isolated global plugin cache and verify all
five `erlang:<version>` images are available.

**Step 3: Run the matrix**

Run `rebar3 docker_ci run`, verify five actual OTP releases, 386 Common Tests
per release, matrix summary image labels, HTTP report URLs, and Ctrl+C cleanup.

**Step 4: Verify custom image form**

Temporarily use `docker_images` for at least one official image and verify the
same direct execution path without a local wrapper tag.

### Task 7: OTP 19 Backport

**Files:**
- Apply the same behavior to all corresponding `otp-19` source and test files.

**Step 1: Switch to `otp-19` and port tests first**

Use proplists, nested `case`, `string:str/2`, and other OTP 19-compatible APIs.

**Step 2: Verify failing tests, then port implementation**

Preserve semantics from master without copying OTP 27 syntax.

**Step 3: Run OTP 19 verification**

```bash
docker run --rm \
  --env REBAR_BASE_DIR=/tmp/rebar3_docker_ci_build \
  --volume /home/slepher/project/rebar3_docker_ci:/project:ro \
  --workdir /project local-ci:19 \
  rebar3 do clean, compile, eunit, ct
```

**Step 4: Commit**

```bash
git commit -m "feat: support direct Docker images on OTP 19"
```

### Task 8: Release And Remote Verification

**Files:** none

**Step 1: Create annotated tags**

```bash
git tag -a 0.2.0 master -m "rebar3_docker_ci 0.2.0"
git tag -a otp-19-0.2.0 otp-19 -m "rebar3_docker_ci OTP 19 0.2.0"
```

**Step 2: Push branches and tags**

```bash
git push origin master otp-19 0.2.0 otp-19-0.2.0
```

**Step 3: Verify remote refs and clean workspace**

Use `git ls-remote --heads --tags origin` and confirm the ignored integration
fixture remains absent from source commits.
