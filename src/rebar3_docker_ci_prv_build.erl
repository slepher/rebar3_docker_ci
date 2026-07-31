-module(rebar3_docker_ci_prv_build).

-behaviour(provider).

-export([init/1, do/1, format_error/1, opts/0]).

init(State) ->
    Provider = providers:create(
                 [{name, build},
                  {module, ?MODULE},
                  {namespace, docker_ci},
                  {bare, true},
                  {deps, []},
                  {example, "rebar3 docker_ci build --otp 28"},
                  {short_desc, "Build Erlang/OTP Docker CI images."},
                  {desc, "Build the configured Erlang/OTP Docker CI image matrix. "
                         "Use --otp to override erlang_versions for this command."},
                  {opts, opts()}]),
    {ok, rebar_state:add_provider(State, Provider)}.

opts() ->
    [{otp, $o, "otp", string,
      "Build only this Erlang/OTP version instead of the configured matrix."}].

do(State) ->
    maybe
        {ok, Config} ?= rebar3_docker_ci_config:load(State),
        {ok, PrivDir} ?= rebar3_docker_ci_project:priv_dir(),
        Options = parsed_options(State),
        Versions = selected_versions(Options, Config),
        Image = rebar3_docker_ci_config:get(image_name, Config),
        Dockerfile = filename:join(PrivDir, "Dockerfile"),
        Root = rebar3_docker_ci_project:root(),
        ok ?= build_versions(Versions, Image, Dockerfile, Root),
        {ok, State}
    else
        {error, Reason} -> {error, {?MODULE, Reason}}
    end.

format_error(Reason) ->
    rebar3_docker_ci:format_error(Reason).

build_versions([], _Image, _Dockerfile, _Root) ->
    ok;
build_versions([Version | Rest], Image, Dockerfile, Root) ->
    rebar_api:info("Building Docker CI image ~s:~s", [Image, Version]),
    Args = rebar3_docker_ci_docker:build_args(Image, Version, Dockerfile, Root),
    case rebar3_docker_ci_docker:execute(Args) of
        ok -> build_versions(Rest, Image, Dockerfile, Root);
        {error, Reason} -> {error, Reason}
    end.

selected_versions(Options, Config) ->
    case maps:get(otp, Options, undefined) of
        undefined -> rebar3_docker_ci_config:get(erlang_versions, Config);
        Version -> [Version]
    end.

parsed_options(State) ->
    case rebar_state:command_parsed_args(State) of
        {Options, _Arguments} -> maps:from_list(Options);
        Options when is_list(Options) -> maps:from_list(Options)
    end.
