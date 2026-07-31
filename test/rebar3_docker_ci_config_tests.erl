-module(rebar3_docker_ci_config_tests).

-include_lib("eunit/include/eunit.hrl").

defaults_test() ->
    {ok, Config} = rebar3_docker_ci_config:from_list([]),
    ?assert(is_map(Config)),
    ?assertEqual(["19", "28"], value(erlang_versions, Config)),
    ?assertEqual(true, value(run_xref, Config)),
    ?assertEqual(false, value(run_dialyzer, Config)),
    ?assertEqual(auto, value(use_checkouts, Config)),
    ?assertEqual(auto, value(output_lang, Config)),
    ?assertEqual(8081, value(log_port, Config)),
    ?assertEqual("rebar3-docker-ci", value(image_name, Config)),
    ?assertEqual(auto, value(log_volume, Config)).

overrides_test() ->
    Input = [{erlang_versions, ["21", <<"27">>]},
             {run_xref, false},
             {run_dialyzer, true},
             {use_checkouts, true},
             {output_lang, cn},
             {log_port, 9090},
             {image_name, "custom-ci"},
             {log_volume, "custom-volume"}],
    {ok, Config} = rebar3_docker_ci_config:from_list(Input),
    ?assertEqual(["21", "27"], value(erlang_versions, Config)),
    ?assertEqual(false, value(run_xref, Config)),
    ?assertEqual(true, value(run_dialyzer, Config)),
    ?assertEqual(true, value(use_checkouts, Config)),
    ?assertEqual(cn, value(output_lang, Config)),
    ?assertEqual(9090, value(log_port, Config)),
    ?assertEqual("custom-ci", value(image_name, Config)),
    ?assertEqual("custom-volume", value(log_volume, Config)).

invalid_values_test_() ->
    [{"empty versions", ?_assertMatch({error, {invalid_config, erlang_versions, _}},
                                       rebar3_docker_ci_config:from_list(
                                         [{erlang_versions, []}]))},
     {"flat version string", ?_assertMatch({error, {invalid_config, erlang_versions, _}},
                                            rebar3_docker_ci_config:from_list(
                                              [{erlang_versions, "19"}]))},
     {"unsafe version", ?_assertMatch({error, {invalid_config, erlang_versions, _}},
                                       rebar3_docker_ci_config:from_list(
                                         [{erlang_versions, ["19;false"]}]))},
     {"bad boolean", ?_assertMatch({error, {invalid_config, run_xref, _}},
                                    rebar3_docker_ci_config:from_list(
                                      [{run_xref, yes}]))},
     {"bad checkout mode", ?_assertMatch({error, {invalid_config, use_checkouts, _}},
                                          rebar3_docker_ci_config:from_list(
                                            [{use_checkouts, sometimes}]))},
     {"bad language", ?_assertMatch({error, {invalid_config, output_lang, _}},
                                     rebar3_docker_ci_config:from_list(
                                       [{output_lang, fr}]))},
     {"bad port", ?_assertMatch({error, {invalid_config, log_port, _}},
                                 rebar3_docker_ci_config:from_list(
                                   [{log_port, 0}]))},
     {"unknown option", ?_assertMatch({error, {unknown_config, mystery}},
                                       rebar3_docker_ci_config:from_list(
                                         [{mystery, true}]))}].

value(Key, Config) ->
    rebar3_docker_ci_config:get(Key, Config).
