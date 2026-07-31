-module(rebar3_docker_ci_targets).

-export([resolve/1, resolve/3, select/2]).

resolve(Images) ->
    resolve(Images, fun inspect/1, fun detect/1).

resolve(Images, Inspect, Detect) ->
    resolve(Images, Inspect, Detect, []).

resolve([], _Inspect, _Detect, Acc) ->
    {ok, lists:reverse(Acc)};
resolve([Image | Rest], Inspect, Detect, Acc) ->
    case Inspect(Image) of
        ok -> resolve_detected(Image, Rest, Inspect, Detect, Acc);
        {error, _Reason} -> {error, {image_missing, Image}}
    end.

resolve_detected(Image, Rest, Inspect, Detect, Acc) ->
    case Detect(Image) of
        {ok, Otp} ->
            case duplicate_image(Otp, Acc) of
                false ->
                    Target = #{image => Image, otp => Otp},
                    resolve(Rest, Inspect, Detect, [Target | Acc]);
                ExistingImage ->
                    {error, {duplicate_otp_release, Otp,
                             [ExistingImage, Image]}}
            end;
        {error, Reason} ->
            {error, {otp_detection_failed, Image, Reason}}
    end.

select(Targets, undefined) ->
    {ok, Targets};
select(Targets, Otp) ->
    Selected = [Target || Target <- Targets,
                          maps:get(otp, Target) =:= Otp],
    case Selected of
        [] -> {error, {otp_not_configured, Otp}};
        _ -> {ok, Selected}
    end.

inspect(Image) ->
    rebar3_docker_ci_docker:execute_quiet(
      rebar3_docker_ci_docker:inspect_image_args(Image)).

detect(Image) ->
    case rebar3_docker_ci_docker:execute_capture(
           rebar3_docker_ci_docker:detect_otp_args(Image)) of
        {ok, Output} -> rebar3_docker_ci_docker:parse_otp_release(Output);
        {error, Reason} -> {error, Reason}
    end.

duplicate_image(Otp, Targets) ->
    case [maps:get(image, Target) || Target <- Targets,
                                    maps:get(otp, Target) =:= Otp] of
        [] -> false;
        [Image | _] -> Image
    end.
