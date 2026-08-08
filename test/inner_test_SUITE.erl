-module(inner_test_SUITE).

%% Runs the external runner (priv/inner_test.sh) against a fake rebar3 in a
%% git worktree and asserts the v1 observation protocol: stage events in
%% fixed order, failure stopping later stages, exact ct_run identity, and
%% coverage publication.

-export([all/0, init_per_testcase/2, end_per_testcase/2]).
-export([happy_path/1, failed_check_stops_later_checks/1,
         ct_failures_reported/1, eunit_framework/1, both_frameworks/1]).

-include_lib("common_test/include/ct.hrl").

all() ->
    [happy_path, failed_check_stops_later_checks, ct_failures_reported,
     eunit_framework, both_frameworks].

init_per_testcase(Name, Config) ->
    Base = filename:join(?config(priv_dir, Config), atom_to_list(Name)),
    ok = ensure_clean_dir(Base),
    Source = filename:join(Base, "source"),
    Logs = filename:join(Base, "results"),
    Bin = filename:join(Base, "bin"),
    Work = filename:join(Base, "work"),
    ok = file:make_dir(Source),
    ok = file:make_dir(Logs),
    ok = file:make_dir(Bin),
    ok = write_file(filename:join(Source, "rebar.config"), <<"{deps, []}.\n">>),
    ok = write_file(filename:join([Source, "src", "fixture.erl"]),
                    <<"-module(fixture).\n-export([x/0]).\nx() -> 1.\n">>),
    ok = run_ok(os:find_executable("git"), ["init", Source]),
    ok = run_ok(os:find_executable("git"), ["-C", Source, "add", "-A"]),
    ok = run_ok(os:find_executable("git"),
                ["-C", Source, "-c", "user.email=ci@test",
                 "-c", "user.name=ci", "commit", "-q", "-m", "init"]),
    FakeRebar = filename:join(Bin, "rebar3"),
    ok = write_file(FakeRebar, fake_rebar_script()),
    ok = file:change_mode(FakeRebar, 8#755),
    [{base, Base}, {source, Source}, {logs, Logs}, {bin, Bin},
     {work, Work}, {calls, filename:join(Base, "calls.txt")} | Config].

end_per_testcase(_Name, Config) ->
    rebar3_docker_ci_test_utils:del_dir_r(?config(base, Config)).

happy_path(Config) ->
    Environment = base_environment(Config) ++
        [{"TEST_SUITE", "fixture_SUITE"}, {"TEST_CASE", "works"}],
    {0, Output} = run_script(Config, Environment),
    true = contains(Output, "\tstage_started\tcompile"),
    true = contains(Output, "\tstage_finished\tcompile\t0"),
    true = contains(Output, "\tstage_finished\txref\t0"),
    true = contains(Output, "\tstage_skipped\tdialyzer"),
    true = contains(Output, "\tstage_finished\tcommon_test\t0"),
    false = contains(Output, "\tstage_skipped\tcommon_test"),
    true = contains(Output, "\tstage_skipped\teunit"),
    Calls = read_file(?config(calls, Config)),
    true = contains(Calls, "compile\n"),
    true = contains(Calls,
                    "ct --logdir " ++ ?config(logs, Config) ++
                        "/29/logs --suite fixture_SUITE --case works\n"),
    ResultsDir = ?config(logs, Config),
    true = filelib:is_file(filename:join([ResultsDir, "29", "cover",
                                          "index.html"])),
    true = git_clean(Config),
    ok.

failed_check_stops_later_checks(Config) ->
    Environment = base_environment(Config) ++ [{"FAIL_COMMAND", "xref"}],
    {9, Output} = run_script(Config, Environment),
    true = contains(Output, "\tstage_finished\tcompile\t0"),
    true = contains(Output, "\tstage_finished\txref\t9"),
    true = contains(Output, "\tstage_skipped\tdialyzer"),
    true = contains(Output, "\tstage_skipped\tcommon_test"),
    true = contains(Output, "\tstage_skipped\teunit"),
    Calls = read_file(?config(calls, Config)),
    true = contains(Calls, "compile\n"),
    true = contains(Calls, "xref\n"),
    false = contains(Calls, "ct\n"),
    ok.

ct_failures_reported(Config) ->
    Environment = base_environment(Config) ++ [{"FAIL_CT", "1"}],
    {1, Output} = run_script(Config, Environment),
    %% A failed CT round never emits a ct_run identity; the host must not
    %% misattribute a historical run.
    false = contains(Output, "\tct_run"),
    true = contains(Output, "\tstage_finished\tcommon_test\t1"),
    true = contains(Output, "\tstage_skipped\teunit"),
    ResultsDir = ?config(logs, Config),
    RunDir = filename:join([ResultsDir, "29", "logs",
                            "ct_run.nonode@nohost.2026-08-07_22.39.22"]),
    true = filelib:is_dir(RunDir),
    ok.

eunit_framework(Config) ->
    Environment = base_environment(Config) ++
        [{"RUN_CT", "false"}, {"RUN_EUNIT", "true"}],
    {0, _Output} = run_script(Config, Environment),
    Calls = read_file(?config(calls, Config)),
    true = contains(Calls, "eunit\n"),
    false = contains(Calls, "ct\n"),
    ResultsDir = ?config(logs, Config),
    true = filelib:is_file(filename:join([ResultsDir, "29", "cover",
                                          "index.html"])),
    ok.

both_frameworks(Config) ->
    Environment = base_environment(Config) ++ [{"RUN_EUNIT", "true"}],
    {0, _Output} = run_script(Config, Environment),
    Calls = read_file(?config(calls, Config)),
    true = contains(Calls, "ct --logdir"),
    true = contains(Calls, "eunit\n"),
    ok.

base_environment(Config) ->
    ExistingPath = case os:getenv("PATH") of false -> ""; Path -> Path end,
    [{"PATH", ?config(bin, Config) ++ ":" ++ ExistingPath},
     {"SRC_MOUNT", ?config(source, Config)},
     {"RESULTS_DIR", ?config(logs, Config)},
     {"WORK_DIR", ?config(work, Config)},
     {"PROJECT_NAME", "fixture"},
     {"ERLANG_VER", "29"},
     {"RUN_XREF", "true"},
     {"RUN_DIALYZER", "false"},
     {"USE_CHECKOUTS", "false"},
     {"OUTPUT_LANG", "en"},
     {"CALL_LOG", ?config(calls, Config)}].

run_script(_Config, Environment) ->
    Script = filename:join(code:priv_dir(rebar3_docker_ci), "inner_test.sh"),
    EnvArgs = lists:append([[Key ++ "=" ++ Value] || {Key, Value} <- Environment]),
    run_capture(os:find_executable("env"), EnvArgs ++ ["bash", Script]).

git_clean(Config) ->
    Source = ?config(source, Config),
    {0, Output} = run_capture(os:find_executable("git"),
                              ["-C", Source, "status", "--porcelain"]),
    Output =:= "".

run_ok(Executable, Args) ->
    case run(Executable, Args) of
        0 -> ok;
        Status -> {error, {command_failed, Status}}
    end.

run(false, _Args) ->
    127;
run(Executable, Args) ->
    {Status, _Output} = run_capture(Executable, Args),
    Status.

run_capture(false, _Args) ->
    {127, ""};
run_capture(Executable, Args) ->
    Port = open_port({spawn_executable, Executable},
                     [binary, exit_status, use_stdio, stderr_to_stdout,
                      {args, Args}]),
    collect(Port, []).

collect(Port, Acc) ->
    receive
        {Port, {data, Data}} -> collect(Port, [Data | Acc]);
        {Port, {exit_status, Status}} ->
            {Status, binary_to_list(iolist_to_binary(lists:reverse(Acc)))}
    after 300000 ->
            {124, lists:reverse(Acc)}
    end.

fake_rebar_script() ->
    <<"#!/usr/bin/env bash\n"
      "printf '%s\\n' \"$*\" >> \"$CALL_LOG\"\n"
      "CMD=\"${1:-}\"\n"
      "LOG_DIR=\"\"\n"
      "while [[ $# -gt 0 ]]; do\n"
      "  if [[ \"$1\" == \"--logdir\" ]]; then LOG_DIR=\"$2\"; shift 2;\n"
      "  else shift; fi\n"
      "done\n"
      "if [[ \"${FAIL_COMMAND:-}\" == \"$CMD\" ]]; then exit 9; fi\n"
      "if [[ \"$CMD\" == \"ct\" ]]; then\n"
      "  mkdir -p \"$LOG_DIR\"\n"
      "  if [[ \"${FAIL_CT:-0}\" == \"1\" ]]; then\n"
      "    RUN_DIR=\"$LOG_DIR/ct_run.nonode@nohost.2026-08-07_22.39.22\"\n"
      "    mkdir -p \"$RUN_DIR/lib.fixture.astranaut_design_SUITE.logs/run.2026-08-07_22.39.22\"\n"
      "    cat > \"$RUN_DIR/lib.fixture.astranaut_design_SUITE.logs/run.2026-08-07_22.39.22/suite.log\" <<'EOF'\n"
      "=case          astranaut_design_SUITE:lib_form_source_contracts\n"
      "=logfile       astranaut_design_suite.lib_form_source_contracts.html\n"
      "=result        failed: {{badmatch,false},\n"
      "                        [{astranaut_design_SUITE,lib_form_source_contracts,1,\n"
      "                              [{file,\"/x/test/astranaut_design_SUITE.erl\"},\n"
      "                               {line,42}]},\n"
      "                         {test_server,ts_tc,3,\n"
      "                              [{file,\"test_server.erl\"},{line,1799}]}]}\n"
      "=== TEST COMPLETE, 0 ok, 1 failed of 1 test cases\n"
      "EOF\n"
      "    exit 1\n"
      "  fi\n"
      "fi\n"
      "mkdir -p _build/test/cover\n"
      "printf cover > _build/test/cover/index.html\n"
      "exit 0\n">>.

ensure_clean_dir(Path) ->
    _ = rebar3_docker_ci_test_utils:del_dir_r(Path),
    filelib:ensure_dir(filename:join(Path, "placeholder")).

write_file(Path, Data) ->
    ok = filelib:ensure_dir(Path),
    file:write_file(Path, Data).

read_file(Path) ->
    {ok, Data} = file:read_file(Path),
    binary_to_list(Data).

contains(Haystack, Needle) ->
    string:find(Haystack, Needle) =/= nomatch.
