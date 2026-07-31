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
                  {desc, "Build the configured Erlang/OTP Docker CI image matrix."},
                  {opts, opts()}]),
    {ok, rebar_state:add_provider(State, Provider)}.

opts() ->
    [{otp, $o, "otp", string, "Build only this Erlang/OTP version."}].

do(State) ->
    case rebar3_docker_ci_config:load(State) of
        {ok, Config} -> do_build(State, Config);
        {error, Reason} -> {error, {?MODULE, Reason}}
    end.

format_error(Reason) ->
    rebar3_docker_ci:format_error(Reason).

do_build(State, Config) ->
    Options = parsed_options(State),
    Versions = selected_versions(Options, Config),
    Image = rebar3_docker_ci_config:get(image_name, Config),
    case rebar3_docker_ci_project:priv_dir() of
        {ok, PrivDir} ->
            Dockerfile = filename:join(PrivDir, "Dockerfile"),
            Root = rebar3_docker_ci_project:root(),
            case build_versions(Versions, Image, Dockerfile, Root) of
                ok -> {ok, State};
                {error, Reason} -> {error, {?MODULE, Reason}}
            end;
        {error, Reason} ->
            {error, {?MODULE, Reason}}
    end.

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
    case proplists:get_value(otp, Options) of
        undefined -> rebar3_docker_ci_config:get(erlang_versions, Config);
        Version -> [Version]
    end.

parsed_options(State) ->
    case rebar_state:command_parsed_args(State) of
        {Options, _Arguments} -> Options;
        Options when is_list(Options) -> Options
    end.
