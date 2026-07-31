-module(rebar3_docker_ci_targets_tests).

-include_lib("eunit/include/eunit.hrl").

resolve_targets_test() ->
    Images = ["erlang:27", "example/ci:latest"],
    Inspect = fun(_Image) -> ok end,
    Detect = fun("erlang:27") -> {ok, "27"};
                ("example/ci:latest") -> {ok, "29"}
             end,
    ?assertEqual({ok, [#{image => "erlang:27", otp => "27"},
                       #{image => "example/ci:latest", otp => "29"}]},
                 rebar3_docker_ci_targets:resolve(Images, Inspect, Detect)).

resolve_errors_test_() ->
    OkInspect = fun(_Image) -> ok end,
    MissingInspect = fun(_Image) -> {error, missing} end,
    Detect27 = fun(_Image) -> {ok, "27"} end,
    DetectError = fun(_Image) -> {error, invalid_otp_release} end,
    [{"missing image",
      ?_assertEqual({error, {image_missing, "erlang:27"}},
                    rebar3_docker_ci_targets:resolve(
                      ["erlang:27"], MissingInspect, Detect27))},
     {"detection failure",
      ?_assertEqual({error, {otp_detection_failed, "erlang:27",
                             invalid_otp_release}},
                    rebar3_docker_ci_targets:resolve(
                      ["erlang:27"], OkInspect, DetectError))},
     {"duplicate release",
      ?_assertEqual({error, {duplicate_otp_release, "27",
                             ["erlang:27", "example/ci:27"]}},
                    rebar3_docker_ci_targets:resolve(
                      ["erlang:27", "example/ci:27"],
                      OkInspect, Detect27))}].

select_test() ->
    Targets = [#{image => "erlang:27", otp => "27"},
               #{image => "example/ci:latest", otp => "29"}],
    ?assertEqual({ok, Targets},
                 rebar3_docker_ci_targets:select(Targets, undefined)),
    ?assertEqual({ok, [#{image => "example/ci:latest", otp => "29"}]},
                 rebar3_docker_ci_targets:select(Targets, "29")),
    ?assertEqual({error, {otp_not_configured, "28"}},
                 rebar3_docker_ci_targets:select(Targets, "28")).
