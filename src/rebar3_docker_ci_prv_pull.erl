-module(rebar3_docker_ci_prv_pull).

-behaviour(provider).

-export([init/1, do/1, format_error/1, opts/0, pull_images/2]).

init(State) ->
    Provider = providers:create(
                 [{name, pull},
                  {module, ?MODULE},
                  {namespace, docker_ci},
                  {bare, true},
                  {deps, []},
                  {example, "rebar3 docker_ci pull"},
                  {short_desc, "Pull Docker CI target images."},
                  {desc, "Pull every image configured by erlang_versions or "
                         "docker_images."},
                  {opts, opts()}]),
    {ok, rebar_state:add_provider(State, Provider)}.

opts() ->
    [].

do(State) ->
    case rebar3_docker_ci_config:load(State) of
        {ok, Config} ->
            Images = rebar3_docker_ci_config:get(target_images, Config),
            case pull_images(Images, fun pull_image/1) of
                ok -> {ok, State};
                {error, Reason} -> {error, {?MODULE, Reason}}
            end;
        {error, Reason} ->
            {error, {?MODULE, Reason}}
    end.

format_error(Reason) ->
    rebar3_docker_ci:format_error(Reason).

pull_images(Images, Pull) ->
    pull_images(Images, Pull, []).

pull_images([], _Pull, []) ->
    ok;
pull_images([], _Pull, Failures) ->
    {error, {pull_failed, lists:reverse(Failures)}};
pull_images([Image | Rest], Pull, Failures) ->
    case Pull(Image) of
        ok -> pull_images(Rest, Pull, Failures);
        {error, Reason} ->
            pull_images(Rest, Pull, [{Image, Reason} | Failures])
    end.

pull_image(Image) ->
    rebar_api:info("Pulling Docker CI image ~s", [Image]),
    rebar3_docker_ci_docker:execute(
      rebar3_docker_ci_docker:pull_args(Image)).
