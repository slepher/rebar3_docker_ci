-module(rebar3_docker_ci_project_tests).

-include_lib("eunit/include/eunit.hrl").

results_dir_test() ->
    ?assertEqual("/project/_build/docker_ci/results",
                 rebar3_docker_ci_project:results_dir("/project")),
    ?assertEqual("/tmp/x/_build/docker_ci/results",
                 rebar3_docker_ci_project:results_dir("/tmp/x")).

checkout_modes_test() ->
    Root = temp_dir("checkout_modes"),
    Checkouts = filename:join(Root, "_checkouts"),
    ok = filelib:ensure_dir(filename:join(Checkouts, "placeholder")),
    try
        ?assertEqual({ok, []},
                     rebar3_docker_ci_project:resolve_checkouts(Root, auto)),
        ?assertMatch({error, {checkouts_missing, _}},
                     rebar3_docker_ci_project:resolve_checkouts(Root, true)),
        App = filename:join(Checkouts, "sample"),
        ok = file:make_dir(App),
        ?assertMatch({ok, [{"sample", _}]},
                     rebar3_docker_ci_project:resolve_checkouts(Root, auto)),
        ?assertEqual({ok, []},
                     rebar3_docker_ci_project:resolve_checkouts(Root, false))
    after
        rebar3_docker_ci_test_utils:del_dir_r(Root)
    end.

temp_dir(Name) ->
    Base = case os:getenv("TMPDIR") of false -> "/tmp"; Value -> Value end,
    Dir = filename:join(Base, "rebar3_docker_ci_" ++ Name ++ "_" ++
                              integer_to_list(erlang:unique_integer([positive]))),
    ok = file:make_dir(Dir),
    Dir.
