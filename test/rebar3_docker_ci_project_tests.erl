-module(rebar3_docker_ci_project_tests).

-include_lib("eunit/include/eunit.hrl").

safe_name_test_() ->
    [{"binary", ?_assertEqual("my-app", rebar3_docker_ci_project:safe_name(<<"My_App">>))},
     {"punctuation", ?_assertEqual("app-name", rebar3_docker_ci_project:safe_name(" App @ Name "))},
     {"repeated separators", ?_assertEqual("one-two", rebar3_docker_ci_project:safe_name("one___two"))},
     {"empty", ?_assertEqual("project", rebar3_docker_ci_project:safe_name("***"))}].

volume_name_test() ->
    ?assertEqual("rebar3-docker-ci-my-app",
                 rebar3_docker_ci_project:volume_name(auto, "My_App")),
    ?assertEqual("chosen", rebar3_docker_ci_project:volume_name("chosen", "ignored")).

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
        remove_tree(Root)
    end.

temp_dir(Name) ->
    Base = case os:getenv("TMPDIR") of false -> "/tmp"; Value -> Value end,
    Dir = filename:join(Base, "rebar3_docker_ci_" ++ Name ++ "_" ++
                              integer_to_list(erlang:unique_integer([positive]))),
    ok = file:make_dir(Dir),
    Dir.

remove_tree(Path) ->
    case file:list_dir(Path) of
        {ok, Entries} ->
            lists:foreach(fun(Entry) -> remove_tree(filename:join(Path, Entry)) end,
                          Entries),
            ok = file:del_dir(Path);
        {error, enotdir} -> ok = file:delete(Path);
        {error, enoent} -> ok
    end.
