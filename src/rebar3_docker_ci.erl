-module(rebar3_docker_ci).

-export([init/1, provider_modules/0, format_error/1]).

init(State) ->
    lists:foldl(fun init_provider/2, {ok, State}, provider_modules()).

provider_modules() ->
    [rebar3_docker_ci_prv_build,
     rebar3_docker_ci_prv_run,
     rebar3_docker_ci_prv_logs].

format_error({invalid_config, Key, Value}) ->
    io_lib:format("invalid docker_ci configuration ~p=~p", [Key, Value]);
format_error({unknown_config, Key}) ->
    io_lib:format("unknown docker_ci configuration option: ~p", [Key]);
format_error(case_requires_suite) ->
    "--case requires --suite";
format_error(docker_not_found) ->
    "Docker was not found in PATH";
format_error(plugin_priv_not_found) ->
    "rebar3_docker_ci priv directory was not found";
format_error({checkouts_missing, Directory}) ->
    io_lib:format("checkouts are enabled but ~s is missing or empty", [Directory]);
format_error({image_missing, Image}) ->
    io_lib:format("Docker image ~s does not exist; run rebar3 docker_ci build first", [Image]);
format_error({log_volume_missing, Volume}) ->
    io_lib:format("Docker log volume ~s does not exist; run rebar3 docker_ci run first", [Volume]);
format_error({invalid_port, Port}) ->
    io_lib:format("invalid log viewer port: ~p", [Port]);
format_error({ci_failed, Failures}) ->
    io_lib:format("Docker CI failed: ~p", [Failures]);
format_error({command_failed, Status}) ->
    io_lib:format("Docker exited with status ~p", [Status]);
format_error(Reason) ->
    io_lib:format("~p", [Reason]).

init_provider(Module, {ok, State}) ->
    Module:init(State);
init_provider(_Module, Error) ->
    Error.
