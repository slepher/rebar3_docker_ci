-module(rebar3_docker_ci_provider_tests).

-include_lib("eunit/include/eunit.hrl").

provider_modules_test() ->
    ?assertEqual([rebar3_docker_ci_prv_config,
                  rebar3_docker_ci_prv_pull,
                  rebar3_docker_ci_prv_run,
                  rebar3_docker_ci_prv_logs],
                 rebar3_docker_ci:provider_modules()).

pull_continues_after_failure_test() ->
    put(pulled_images, []),
    Pull = fun(Image) ->
                   put(pulled_images, get(pulled_images) ++ [Image]),
                   case Image of
                       "erlang:28" -> {error, denied};
                       _ -> ok
                   end
           end,
    ?assertEqual({error, {pull_failed, [{"erlang:28", denied}]}},
                 rebar3_docker_ci_prv_pull:pull_images(
                   ["erlang:27", "erlang:28", "erlang:29"], Pull)),
    ?assertEqual(["erlang:27", "erlang:28", "erlang:29"],
                 get(pulled_images)).

config_example_test() ->
    Example = rebar3_docker_ci_prv_config:example(),
    ?assertNotEqual(nomatch, string:find(Example, "erlang_versions")),
    ?assertNotEqual(nomatch, string:find(Example, "docker_images")),
    ?assertNotEqual(nomatch, string:find(Example, "exactly one")),
    ?assertEqual(nomatch, string:find(Example, "image_name")).

matrix_results_test() ->
    Targets = [#{image => "erlang:27", otp => "27"},
               #{image => "example/ci:latest", otp => "29"}],
    ?assertEqual([{lists:nth(1, Targets), passed},
                  {lists:nth(2, Targets), passed}],
                 rebar3_docker_ci_prv_run:matrix_results(Targets, ok)),
    Failure = {error, {ci_failed,
                       [{lists:nth(2, Targets), {command_failed, 9}}]}},
    ?assertEqual([{lists:nth(1, Targets), passed},
                  {lists:nth(2, Targets), {failed, {command_failed, 9}}}],
                 rebar3_docker_ci_prv_run:matrix_results(Targets, Failure)).

common_test_selection_test_() ->
    [{"all", ?_assertEqual({ok, {"", ""}},
                            rebar3_docker_ci_prv_run:validate_selection("", ""))},
     {"suite", ?_assertEqual({ok, {"a_SUITE", ""}},
                              rebar3_docker_ci_prv_run:validate_selection("a_SUITE", ""))},
     {"case", ?_assertEqual({ok, {"a_SUITE", "works"}},
                             rebar3_docker_ci_prv_run:validate_selection("a_SUITE", "works"))},
     {"case without suite", ?_assertMatch({error, case_requires_suite},
                                           rebar3_docker_ci_prv_run:validate_selection("", "works"))}].

provider_option_names_test() ->
    ?assertEqual([], option_names(rebar3_docker_ci_prv_config:opts())),
    ?assertEqual([], option_names(rebar3_docker_ci_prv_pull:opts())),
    ?assertEqual([otp, suite, 'case', dialyzer, skip_xref, no_checkouts, no_view],
                 option_names(rebar3_docker_ci_prv_run:opts())),
    ?assertEqual([port], option_names(rebar3_docker_ci_prv_logs:opts())).

log_port_validation_test_() ->
    [{"valid", ?_assertEqual({ok, 8082},
                              rebar3_docker_ci_prv_logs:validate_port(8082))},
     {"zero", ?_assertMatch({error, {invalid_port, 0}},
                             rebar3_docker_ci_prv_logs:validate_port(0))},
     {"too large", ?_assertMatch({error, {invalid_port, 65536}},
                                  rebar3_docker_ci_prv_logs:validate_port(65536))}].

option_names(Options) ->
    [Name || {Name, _Short, _Long, _Type, _Description} <- Options].
