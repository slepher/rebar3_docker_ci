-module(rebar3_docker_ci_config_tests).

-include_lib("eunit/include/eunit.hrl").

defaults_test() ->
    {ok, Config} = rebar3_docker_ci_config:from_list(
                     [{erlang_versions, ["27", <<"28">>]}]),
    ?assert(is_map(Config)),
    ?assertEqual(erlang_versions, value(target_source, Config)),
    ?assertEqual(["erlang:27", "erlang:28"], value(target_images, Config)),
    ?assertEqual(true, value(run_xref, Config)),
    ?assertEqual(false, value(run_dialyzer, Config)),
    ?assertEqual(auto, value(use_checkouts, Config)),
    ?assertEqual(auto, value(output_lang, Config)),
    ?assertEqual(8081, value(log_port, Config)),
    ?assertEqual(auto, value(log_volume, Config)).

overrides_test() ->
    Input = [{docker_images, ["erlang:21", <<"example/erlang-ci:27">>]},
             {run_xref, false},
             {run_dialyzer, true},
             {use_checkouts, true},
             {output_lang, cn},
             {log_port, 9090},
             {log_volume, "custom-volume"}],
    {ok, Config} = rebar3_docker_ci_config:from_list(Input),
    ?assertEqual(docker_images, value(target_source, Config)),
    ?assertEqual(["erlang:21", "example/erlang-ci:27"],
                 value(target_images, Config)),
    ?assertEqual(false, value(run_xref, Config)),
    ?assertEqual(true, value(run_dialyzer, Config)),
    ?assertEqual(true, value(use_checkouts, Config)),
    ?assertEqual(cn, value(output_lang, Config)),
    ?assertEqual(9090, value(log_port, Config)),
    ?assertEqual("custom-volume", value(log_volume, Config)).

required_targets_test_() ->
    [{"missing targets",
      ?_assertEqual({error, {missing_target_config,
                             [erlang_versions, docker_images]}},
                    rebar3_docker_ci_config:from_list([]))},
     {"conflicting targets",
      ?_assertEqual({error, {conflicting_target_config,
                             erlang_versions, docker_images}},
                    rebar3_docker_ci_config:from_list(
                      [{erlang_versions, ["27"]},
                       {docker_images, ["erlang:28"]}]))},
     {"removed image_name",
      ?_assertEqual({error, {removed_config, image_name}},
                    rebar3_docker_ci_config:from_list(
                      [{erlang_versions, ["27"]},
                       {image_name, "legacy-ci"}]))}].

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
     {"empty images", ?_assertMatch({error, {invalid_config, docker_images, _}},
                                      rebar3_docker_ci_config:from_list(
                                        [{docker_images, []}]))},
     {"unsafe image", ?_assertMatch({error, {invalid_config, docker_images, _}},
                                      rebar3_docker_ci_config:from_list(
                                        [{docker_images, ["erlang:27 latest"]}]))},
     {"bad boolean", ?_assertMatch({error, {invalid_config, run_xref, _}},
                                    rebar3_docker_ci_config:from_list(
                                      [{erlang_versions, ["27"]},
                                       {run_xref, yes}]))},
     {"bad checkout mode", ?_assertMatch({error, {invalid_config, use_checkouts, _}},
                                          rebar3_docker_ci_config:from_list(
                                            [{erlang_versions, ["27"]},
                                             {use_checkouts, sometimes}]))},
     {"bad language", ?_assertMatch({error, {invalid_config, output_lang, _}},
                                     rebar3_docker_ci_config:from_list(
                                       [{erlang_versions, ["27"]},
                                        {output_lang, fr}]))},
     {"bad port", ?_assertMatch({error, {invalid_config, log_port, _}},
                                 rebar3_docker_ci_config:from_list(
                                   [{erlang_versions, ["27"]},
                                    {log_port, 0}]))},
     {"unknown option", ?_assertMatch({error, {unknown_config, mystery}},
                                       rebar3_docker_ci_config:from_list(
                                         [{erlang_versions, ["27"]},
                                          {mystery, true}]))}].

value(Key, Config) ->
    rebar3_docker_ci_config:get(Key, Config).
