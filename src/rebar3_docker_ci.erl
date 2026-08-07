-module(rebar3_docker_ci).

-moduledoc "Docker-backed CI providers for Rebar3 projects.

The plugin runs on the developer host. Target projects are compiled and tested
inside independently versioned Erlang/OTP containers.".

-export([init/1, provider_modules/0, format_error/1]).

init(State) ->
    lists:foldl(fun init_provider/2, {ok, State}, provider_modules()).

provider_modules() ->
    [rebar3_docker_ci_prv_config,
     rebar3_docker_ci_prv_pull,
     rebar3_docker_ci_prv_run,
     rebar3_docker_ci_prv_logs].

format_error({invalid_config, Key, Value}) ->
    io_lib:format("invalid docker_ci configuration ~p=~p", [Key, Value]);
format_error({missing_target_config, _Keys}) ->
    "missing required Docker CI targets; configure exactly one of:\n\n"
    "{docker_ci, [{erlang_versions, [\"27\", \"28\"]}]}.\n\n"
    "or:\n\n"
    "{docker_ci, [{docker_images, [\"erlang:27\", \"erlang:28\"]}]}.\n\n"
    "Run `rebar3 help docker_ci config` for details.";
format_error({conflicting_target_config, erlang_versions, docker_images}) ->
    "docker_ci options erlang_versions and docker_images are mutually exclusive";
format_error({removed_config, image_name}) ->
    "docker_ci option image_name was removed in 0.2.0; configure "
    "erlang_versions or docker_images instead";
format_error({removed_config, log_volume}) ->
    "docker_ci option log_volume was removed in 0.3.0; results are "
    "written to _build/docker_ci/results instead";
format_error({pull_failed, Failures}) ->
    io_lib:format("failed to pull Docker CI images: ~p", [Failures]);
format_error({unknown_config, Key}) ->
    io_lib:format("unknown docker_ci configuration option: ~p", [Key]);
format_error(case_requires_suite) ->
    "--case requires --suite";
format_error({selection_requires_ct, Suite}) ->
    io_lib:format("--suite/--case require run_ct=true, but it is disabled "
                  "(suite ~s)", [Suite]);
format_error(docker_not_found) ->
    "Docker was not found in PATH";
format_error(plugin_priv_not_found) ->
    "rebar3_docker_ci priv directory was not found";
format_error({checkouts_missing, Directory}) ->
    io_lib:format("checkouts are enabled but ~s is missing or empty", [Directory]);
format_error({image_missing, Image}) ->
    io_lib:format("Docker image ~s does not exist; run rebar3 docker_ci pull first", [Image]);
format_error({otp_detection_failed, Image, Reason}) ->
    io_lib:format("could not detect the Erlang/OTP release in Docker image ~s: ~p",
                  [Image, Reason]);
format_error({duplicate_otp_release, Otp, Images}) ->
    io_lib:format("Docker images ~p both provide Erlang/OTP ~s; "
                  "report directories would overlap", [Images, Otp]);
format_error({otp_not_configured, Otp}) ->
    io_lib:format("no configured Docker image provides Erlang/OTP ~s", [Otp]);
format_error({results_missing, ResultsDir}) ->
    io_lib:format("Docker CI results directory ~s does not exist; "
                  "run rebar3 docker_ci run first", [ResultsDir]);
format_error({results_dir_failed, ResultsDir, Reason}) ->
    io_lib:format("could not create Docker CI results directory ~s: ~p",
                  [ResultsDir, Reason]);
format_error({results_write_failed, File, Reason}) ->
    io_lib:format("could not write Docker CI results file ~s: ~p",
                  [File, Reason]);
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
