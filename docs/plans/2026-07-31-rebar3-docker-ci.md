# Rebar3 Docker CI Plugin Implementation Plan

> **For Codex:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Implement an OTP 19-compatible baseline, preserved on `otp-19`, that replaces Astranaut's synchronized Docker CI scripts with `rebar3 docker_ci` providers; the main branch subsequently raises the host plugin baseline to OTP 27.

**Architecture:** Rebar3 providers perform all host-side configuration and Docker orchestration. Packaged `priv` resources perform only the isolated Linux-container test flow. Pure argument-building functions and an injectable command runner keep ordinary tests independent from Docker.

**Tech Stack:** Erlang/OTP 27+ on the main branch, OTP 19+ on the `otp-19` branch, Rebar3 provider API, EUnit, Common Test, Bash inside official Erlang Docker images.

---

### Task 1: Scaffold the plugin and provider registration

**Files:**
- Create: `rebar.config`
- Create: `src/rebar3_docker_ci.app.src`
- Test: `test/rebar3_docker_ci_tests.erl`
- Create: `src/rebar3_docker_ci.erl`

1. Add an EUnit test asserting `init/1` registers `build`, `run`, and `logs` under the `docker_ci` namespace.
2. Run `rebar3 eunit` and confirm the missing module failure.
3. Add the application metadata and entry module using `providers:create/1`, following `rebar3_erlando`'s provider style.
4. Run `rebar3 eunit` and commit.

### Task 2: Parse and validate project configuration

**Files:**
- Test: `test/rebar3_docker_ci_config_tests.erl`
- Create: `src/rebar3_docker_ci_config.erl`

1. Test defaults, complete overrides, invalid version lists, invalid booleans, invalid checkout mode, invalid ports, and unknown options.
2. Confirm tests fail because the configuration API is missing.
3. Implement `load/1`, `from_list/1`, and accessors using only OTP 19 APIs.
4. Confirm focused and full EUnit suites pass, then commit.

### Task 3: Resolve generic project identity and checkouts

**Files:**
- Test: `test/rebar3_docker_ci_project_tests.erl`
- Create: `src/rebar3_docker_ci_project.erl`

1. Test Docker-safe project/volume names, empty names, checkout auto/true/false modes, and symlink resolution.
2. Confirm the tests fail for the missing API.
3. Implement project discovery from Rebar3 state with path-oriented pure helpers for tests.
4. Run the tests and commit.

### Task 4: Execute Docker without a host shell

**Files:**
- Test: `test/rebar3_docker_ci_docker_tests.erl`
- Create: `src/rebar3_docker_ci_docker.erl`
- Create: `test/rebar3_docker_ci_fake_runner.erl`

1. Test exact argument lists for image build/inspect, volume inspect/create, CI container mounts/env, and Nginx viewer startup.
2. Test that the matrix continues after one CI failure and returns the aggregate failure.
3. Confirm missing-function failures.
4. Implement pure argument builders plus an `open_port({spawn_executable, ...})` runner that streams output and reports exit status.
5. Run the tests and commit.

### Task 5: Add namespaced providers and CLI validation

**Files:**
- Test: `test/rebar3_docker_ci_provider_tests.erl`
- Create: `src/rebar3_docker_ci_prv_build.erl`
- Create: `src/rebar3_docker_ci_prv_run.erl`
- Create: `src/rebar3_docker_ci_prv_logs.erl`
- Modify: `src/rebar3_docker_ci.erl`

1. Test provider option definitions and selection rules: no selector, suite only, suite with case, and rejected case-only input.
2. Test CLI overrides for OTP, dialyzer, xref, checkouts, view, and port.
3. Confirm the tests fail before provider modules exist.
4. Implement provider registration, orchestration, structured failures, and `format_error/1`.
5. Run EUnit and commit.

### Task 6: Port and generalize the container runner

**Files:**
- Create: `priv/Dockerfile`
- Test: `test/inner_test_SUITE.erl`
- Create: `priv/inner_test.sh`

1. Add Common Test cases using temporary Git projects and fake `rebar3` executables for full CT, suite-only, suite/case, checkout copying, failure short-circuiting, summaries, and exported logs.
2. Confirm cases fail because `priv/inner_test.sh` is absent.
3. Port the Astranaut runner, replacing all fixed project paths/names with environment values and retaining the Git-aware isolated copy.
4. Run Common Test, `bash -n priv/inner_test.sh`, and commit.

### Task 7: Document installation and migration

**Files:**
- Create: `README.md`
- Create: `LICENSE`
- Create: `.gitignore`

1. Document plugin installation, configuration, all commands/options, output locations, checkout behavior, OTP 19 compatibility, and migration away from `ci_scripts`.
2. Check every documented command against provider option definitions.
3. Commit documentation.

### Task 8: Full verification

1. Run `rebar3 format --verify` if a formatter is available; otherwise record that it is unavailable.
2. Run `rebar3 compile`.
3. Run `rebar3 eunit`.
4. Run `rebar3 ct`.
5. Compile and test the plugin in `erlang:19` to prove the minimum OTP claim.
6. During initialization only, use a temporary Astranaut copy for one real Docker smoke test; do not commit the fixture.
7. Review `rg -n -i astranaut src priv README.md rebar.config` and confirm production code has no Astranaut dependency.
8. Review `git diff --check`, `git status`, and the requirements checklist before reporting completion.
