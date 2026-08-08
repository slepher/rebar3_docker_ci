-module(rebar3_docker_ci_runner_erlando_tests).

%% End-to-end fixture: run the external runner (priv/inner_test.sh) against
%% the local erlando checkout with symlinked sibling checkouts, exactly like
%% the container does. Skipped when rebar3 or the sibling repos are missing.
%%
%% The after/1 cleanup is the regression guard for the wipe bug: fixture
%% cleanup must never follow the checkout symlinks into the host repos.

-include_lib("eunit/include/eunit.hrl").

runner_erlando_test_() ->
    {timeout, 900, fun runner_erlando_run/0}.

runner_erlando_run() ->
    case runner_available() of
        false ->
            ok;
        {true, Rebar3, Erlando} ->
            Siblings = [{"astranaut", project_sibling("astranaut")},
                        {"rebar3_erlando", project_sibling("rebar3_erlando")},
                        {"rebar3_docker_ci", project_sibling("rebar3_docker_ci")}],
            case [ok || {_Name, Path} <- Siblings,
                        filelib:is_dir(filename:join([Path, "src"]))] of
                Siblings ->
                    Fixture = temp_dir("erlando_fixture"),
                    try
                        run_erlando_fixture(Rebar3, Erlando, Fixture, Siblings)
                    after
                        rebar3_docker_ci_test_utils:del_dir_r(Fixture),
                        assert_siblings_intact(Siblings)
                    end;
                _ ->
                    ok
            end
    end.

run_erlando_fixture(Rebar3, Erlando, Fixture, Siblings) ->
    Results = filename:join(Fixture, "results"),
    Work = filename:join(Fixture, "work"),
    Checkouts = filename:join(Fixture, "checkouts"),
    ok = filelib:ensure_dir(filename:join(Results, "placeholder")),
    ok = filelib:ensure_dir(filename:join(Work, "placeholder")),
    ok = filelib:ensure_dir(filename:join(Checkouts, "placeholder")),
    lists:foreach(fun({Name, Path}) ->
                          ok = file:make_symlink(Path,
                                                 filename:join(Checkouts, Name))
                  end, Siblings),
    Script = filename:join(code:priv_dir(rebar3_docker_ci), "inner_test.sh"),
    EnvArgs = env_args(Results, Work, Checkouts, Erlando, Rebar3),
    {Status, Output} = run_capture("env", EnvArgs ++ ["bash", Script]),
    ?assertEqual(0, Status),
    ?assertNotEqual(nomatch, string:find(Output, "stage_finished")).

env_args(Results, Work, Checkouts, Erlando, Rebar3) ->
    Base = filename:dirname(filename:dirname(filename:dirname(Rebar3))),
    lists:append(
      [[Key ++ "=" ++ Value]
       || {Key, Value} <- [{"PATH", os:getenv("PATH")},
                           {"HOME", filename:join(Work, "home")},
                           {"SRC_MOUNT", Erlando},
                           {"RESULTS_DIR", Results},
                           {"CHECKOUTS_DIR", Checkouts},
                           {"WORK_DIR", Work},
                           {"PROJECT_NAME", "erlando"},
                           {"ERLANG_VER", otp_release()},
                           {"RUN_XREF", "false"},
                           {"RUN_DIALYZER", "false"},
                           {"RUN_CT", "false"},
                           {"RUN_EUNIT", "false"},
                           {"USE_CHECKOUTS", "true"},
                           {"OUTPUT_LANG", "en"},
                           {"BASE_DIR", Base}]]).

project_sibling(Name) ->
    filename:join([project_root(), Name]).

project_root() ->
    filename:dirname(filename:dirname(code:priv_dir(rebar3_docker_ci))).

runner_available() ->
    case {os:find_executable("rebar3"), erlando_root()} of
        {false, _} -> false;
        {_, undefined} -> false;
        {Rebar3, Erlando} -> {true, Rebar3, Erlando}
    end.

erlando_root() ->
    Candidate = filename:join([project_root(), "erlando"]),
    case filelib:is_dir(filename:join([Candidate, "src"])) of
        true -> Candidate;
        false -> undefined
    end.

otp_release() ->
    {ok, Output} = run_capture("erl",
                               ["-noshell", "-eval",
                                "io:format(\"~s\", [erlang:system_info(otp_release)]), "
                                "halt()."]),
    string:trim(Output).

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
    after 600000 ->
            {124, lists:reverse(Acc)}
    end.

assert_siblings_intact(Siblings) ->
    lists:foreach(
      fun({Name, Path}) ->
              ?assert(filelib:is_dir(filename:join([Path, "src"])),
                      Name ++ " src missing after fixture cleanup"),
              ?assert(filelib:is_dir(filename:join([Path, ".git"])),
                      Name ++ " .git missing after fixture cleanup")
      end, Siblings).

temp_dir(Name) ->
    Dir = filename:join(["/tmp", "rebar3_docker_ci_" ++ Name ++ "_" ++
                         integer_to_list(erlang:unique_integer([positive]))]),
    case file:make_dir(Dir) of
        ok -> Dir;
        {error, eexist} -> temp_dir(Name);
        {error, Reason} -> error({temp_dir_failed, Dir, Reason})
    end.
