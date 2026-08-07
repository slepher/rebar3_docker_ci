-module(rebar3_docker_ci_prv_config).

-behaviour(provider).

-export([init/1, do/1, format_error/1, opts/0, example/0]).

init(State) ->
    Provider = providers:create(
                 [{name, config},
                  {module, ?MODULE},
                  {namespace, docker_ci},
                  {bare, true},
                  {deps, []},
                  {example, "rebar3 docker_ci config"},
                  {short_desc, "Show Docker CI configuration."},
                  {desc, description()},
                  {opts, opts()}]),
    {ok, rebar_state:add_provider(State, Provider)}.

opts() ->
    [].

do(State) ->
    rebar_api:info("~s", [example()]),
    case rebar3_docker_ci_config:load(State) of
        {ok, Config} ->
            Images = rebar3_docker_ci_config:get(target_images, Config),
            rebar_api:info("Normalized target images: ~p", [Images]);
        {error, Reason} ->
            Message = lists:flatten(rebar3_docker_ci:format_error(Reason)),
            rebar_api:info("Current configuration is invalid: ~s", [Message])
    end,
    {ok, State}.

format_error(Reason) ->
    rebar3_docker_ci:format_error(Reason).

description() ->
    "Show the docker_ci rebar.config format. Configure exactly one of "
    "erlang_versions or docker_images; all other options are optional.".

example() ->
    "Configure exactly one target source in rebar.config:\n\n"
    "{docker_ci, [\n"
    "    {erlang_versions, [\"27\", \"28\"]}\n"
    "]}.\n\n"
    "or:\n\n"
    "{docker_ci, [\n"
    "    {docker_images, [\"erlang:27\", \"erlang:28\"]}\n"
    "]}.\n\n"
    "Optional fields and defaults:\n"
    "  run_xref=true, run_dialyzer=false, use_checkouts=auto,\n"
    "  output_lang=auto, test_framework=common_test, log_port=8081".
