-module(rebar3_docker_ci_provider_tests).

-include_lib("eunit/include/eunit.hrl").

provider_modules_test() ->
    ?assertEqual([rebar3_docker_ci_prv_build,
                  rebar3_docker_ci_prv_run,
                  rebar3_docker_ci_prv_logs],
                 rebar3_docker_ci:provider_modules()).

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
    ?assertEqual([otp], option_names(rebar3_docker_ci_prv_build:opts())),
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
