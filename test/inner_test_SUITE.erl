-module(inner_test_SUITE).

-export([all/0, init_per_testcase/2, end_per_testcase/2]).
-export([suite_and_case/1, failed_check_stops_later_checks/1]).

-include_lib("common_test/include/ct.hrl").

all() ->
    [suite_and_case, failed_check_stops_later_checks].

init_per_testcase(Name, Config) ->
    Base = filename:join(?config(priv_dir, Config), atom_to_list(Name)),
    ok = ensure_clean_dir(Base),
    Source = filename:join(Base, "source"),
    Logs = filename:join(Base, "logs"),
    Bin = filename:join(Base, "bin"),
    Work = filename:join(Base, "work"),
    ok = file:make_dir(Source),
    ok = file:make_dir(Logs),
    ok = file:make_dir(Bin),
    ok = write_file(filename:join(Source, "rebar.config"), <<"{deps, []}.\n">>),
    ok = run_ok(os:find_executable("git"), ["init", Source]),
    ok = run_ok(os:find_executable("git"), ["-C", Source, "add", "rebar.config"]),
    FakeRebar = filename:join(Bin, "rebar3"),
    ok = write_file(FakeRebar, fake_rebar_script()),
    ok = file:change_mode(FakeRebar, 8#755),
    [{base, Base}, {source, Source}, {logs, Logs}, {bin, Bin},
     {work, Work}, {calls, filename:join(Base, "calls.txt")} | Config].

end_per_testcase(_Name, Config) ->
    file:del_dir_r(?config(base, Config)).

suite_and_case(Config) ->
    Environment = base_environment(Config) ++
        [{"TEST_SUITE", "astranaut_design_SUITE"},
         {"TEST_CASE", "lib_form_source_contracts"}],
    0 = run_script(Config, Environment),
    Calls = read_file(?config(calls, Config)),
    true = contains(Calls, "compile\n"),
    true = contains(Calls, "xref\n"),
    true = contains(Calls,
                    "ct --suite astranaut_design_SUITE --case lib_form_source_contracts\n"),
    Summary = read_file(filename:join([?config(logs, Config), "29", "ci-summary.txt"])),
    true = contains(Summary, "project=fixture"),
    true = contains(Summary, "test_suite=astranaut_design_SUITE"),
    true = contains(Summary, "result=0"),
    true = filelib:is_file(filename:join(
                            [?config(logs, Config), "29", "logs", "index.html"])),
    ok.

failed_check_stops_later_checks(Config) ->
    Environment = base_environment(Config) ++ [{"FAIL_COMMAND", "xref"}],
    9 = run_script(Config, Environment),
    Calls = read_file(?config(calls, Config)),
    true = contains(Calls, "compile\n"),
    true = contains(Calls, "xref\n"),
    false = contains(Calls, "ct"),
    Summary = read_file(filename:join([?config(logs, Config), "29", "ci-summary.txt"])),
    true = contains(Summary, "xref=9"),
    true = contains(Summary, "common_test=skipped"),
    true = contains(Summary, "result=9"),
    ok.

base_environment(Config) ->
    ExistingPath = case os:getenv("PATH") of false -> ""; Path -> Path end,
    [{"PATH", ?config(bin, Config) ++ ":" ++ ExistingPath},
     {"SRC_MOUNT", ?config(source, Config)},
     {"LOG_VOLUME", ?config(logs, Config)},
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
    run(os:find_executable("env"), EnvArgs ++ ["bash", Script]).

run_ok(Executable, Args) ->
    case run(Executable, Args) of
        0 -> ok;
        Status -> {error, {command_failed, Status}}
    end.

run(false, _Args) ->
    127;
run(Executable, Args) ->
    Port = open_port({spawn_executable, Executable},
                     [binary, exit_status, use_stdio, stderr_to_stdout,
                      {args, Args}]),
    collect(Port).

collect(Port) ->
    receive
        {Port, {data, _Data}} -> collect(Port);
        {Port, {exit_status, Status}} -> Status
    end.

fake_rebar_script() ->
    <<"#!/usr/bin/env bash\n"
      "printf '%s\\n' \"$*\" >> \"$CALL_LOG\"\n"
      "if [[ \"${FAIL_COMMAND:-}\" == \"${1:-}\" ]]; then exit 9; fi\n"
      "if [[ \"${1:-}\" == ct ]]; then\n"
      "  mkdir -p _build/test/logs _build/test/cover\n"
      "  printf logs > _build/test/logs/index.html\n"
      "  printf cover > _build/test/cover/index.html\n"
      "fi\n">>.

ensure_clean_dir(Path) ->
    _ = file:del_dir_r(Path),
    filelib:ensure_dir(filename:join(Path, "placeholder")).

write_file(Path, Data) ->
    ok = filelib:ensure_dir(Path),
    file:write_file(Path, Data).

read_file(Path) ->
    {ok, Data} = file:read_file(Path),
    binary_to_list(Data).

contains(Haystack, Needle) ->
    string:find(Haystack, Needle) =/= nomatch.
