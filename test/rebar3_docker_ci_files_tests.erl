-module(rebar3_docker_ci_files_tests).

-include_lib("eunit/include/eunit.hrl").

base_dir() ->
    "/tmp/rebar3_docker_ci_files_tests_" ++
        integer_to_list(erlang:unique_integer([positive])).

del_dir_r_removes_tree_test() ->
    Base = base_dir(),
    ok = filelib:ensure_dir(filename:join([Base, "a", "b", "placeholder"])),
    ok = file:write_file(filename:join([Base, "a", "b", "x.erl"]), <<"x">>),
    ok = file:write_file(filename:join([Base, "a", "top.txt"]), <<"t">>),
    ?assertEqual(ok, rebar3_docker_ci_files:del_dir_r(Base)),
    ?assertEqual(false, filelib:is_dir(Base)).

del_dir_r_removes_file_test() ->
    File = base_dir() ++ ".txt",
    ok = file:write_file(File, <<"data">>),
    ?assertEqual(ok, rebar3_docker_ci_files:del_dir_r(File)),
    ?assertEqual(false, filelib:is_regular(File)).

del_dir_r_missing_returns_error_test() ->
    ?assertMatch({error, enoent},
                 rebar3_docker_ci_files:del_dir_r(base_dir() ++ "_missing")).

%% Regression: del_dir_r must not follow directory symlinks. The fixture
%% cleanup used to delete the host sibling repos because checkouts are
%% symlinks into /home/slepher/project; the same mistake here would wipe
%% an unrelated directory tree.
symlink_target_survives_test() ->
    Base = base_dir(),
    Victim = Base ++ "_victim",
    ok = filelib:ensure_dir(filename:join([Victim, "src", "placeholder"])),
    ok = file:write_file(filename:join([Victim, "src", "a.erl"]), <<"a">>),
    ok = file:write_file(filename:join(Victim, "keep.txt"), <<"k">>),
    ok = filelib:ensure_dir(filename:join([Base, "checkouts", "placeholder"])),
    ok = file:make_symlink(Victim, filename:join([Base, "checkouts", "astranaut"])),
    ?assertEqual(ok, rebar3_docker_ci_files:del_dir_r(Base)),
    ?assertEqual(true, filelib:is_regular(filename:join([Victim, "src", "a.erl"]))),
    ?assertEqual(true, filelib:is_regular(filename:join(Victim, "keep.txt"))),
    ?assertEqual(ok, rebar3_docker_ci_files:del_dir_r(Victim)).

nested_symlink_inside_deleted_tree_test() ->
    Base = base_dir(),
    Victim = Base ++ "_victim",
    ok = filelib:ensure_dir(filename:join([Victim, "src", "placeholder"])),
    ok = file:write_file(filename:join([Victim, "src", "a.erl"]), <<"a">>),
    ok = filelib:ensure_dir(filename:join([Base, "sub", "placeholder"])),
    ok = file:write_file(filename:join([Base, "sub", "placeholder"]), <<>>),
    ok = file:make_symlink(Victim, filename:join([Base, "sub", "link"])),
    ?assertEqual(ok, rebar3_docker_ci_files:del_dir_r(Base)),
    ?assertEqual(true, filelib:is_regular(filename:join([Victim, "src", "a.erl"]))),
    ?assertEqual(ok, rebar3_docker_ci_files:del_dir_r(Victim)).
