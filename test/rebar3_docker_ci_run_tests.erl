-module(rebar3_docker_ci_run_tests).

-include_lib("eunit/include/eunit.hrl").

opts_cover_selection_and_runner_flags_test() ->
    Opts = rebar3_docker_ci_prv_run:opts(),
    Names = [element(1, Opt) || Opt <- Opts],
    ?assert(lists:member(otp, Names)),
    ?assert(lists:member(suite, Names)),
    ?assert(lists:member('case', Names)),
    ?assert(lists:member(dialyzer, Names)),
    ?assert(lists:member(skip_xref, Names)),
    ?assert(lists:member(no_checkouts, Names)),
    ?assert(lists:member(jobs, Names)).

format_error_delegates_test() ->
    ?assertEqual("Docker CI stage common_test failed",
                 lists:flatten(rebar3_docker_ci_prv_run:format_error(
                                 {stage_failed, common_test}))),
    Message = lists:flatten(rebar3_docker_ci_prv_run:format_error(
                              {protocol_error, {bad_prefix, 42}})),
    ?assertNotEqual(nomatch,
                    string:find(Message, "Docker CI protocol error: {bad_prefix,42}")),
    ?assertEqual("another docker_ci run is already in progress for this project; "
                 "remove _build/docker_ci/run.lock if the previous run crashed",
                 lists:flatten(rebar3_docker_ci_prv_run:format_error(
                                 run_in_progress))),
    ?assertEqual("Docker exited with status 9",
                 lists:flatten(rebar3_docker_ci_prv_run:format_error(
                                 {command_failed, 9}))).

matrix_results_maps_each_target_test() ->
    Targets = [#{image => "erlang:27", otp => "27"},
               #{image => "erlang:28", otp => "28"},
               #{image => "erlang:29", otp => "29"}],
    Failure = {error, {ci_failed, [{lists:nth(1, Targets), {stage_failed, xref}},
                                   {lists:nth(3, Targets), {aborted, compile}}]}},
    Results = rebar3_docker_ci_prv_run:matrix_results(Targets, Failure),
    ?assertEqual({lists:nth(1, Targets), {failed, {stage_failed, xref}}},
                 lists:nth(1, Results)),
    ?assertEqual({lists:nth(2, Targets), passed}, lists:nth(2, Results)),
    ?assertEqual({lists:nth(3, Targets), {failed, {aborted, compile}}},
                 lists:nth(3, Results)).
