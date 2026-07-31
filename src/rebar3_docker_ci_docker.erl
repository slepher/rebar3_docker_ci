-module(rebar3_docker_ci_docker).

-export([build_args/4, inspect_image_args/2, inspect_volume_args/1,
         create_volume_args/1, run_args/2, viewer_args/2, volume_file_args/2,
         execute/1, execute/2, execute_quiet/1, run_matrix/2]).

build_args(Image, Version, Dockerfile, Context) ->
    ["build", "--tag", Image ++ ":" ++ Version,
     "--build-arg", "ERLANG_VER=" ++ Version,
     "--file", Dockerfile, Context].

inspect_image_args(Image, Version) ->
    ["image", "inspect", Image ++ ":" ++ Version].

inspect_volume_args(Volume) ->
    ["volume", "inspect", Volume].

create_volume_args(Volume) ->
    ["volume", "create", Volume].

run_args(Context, Version) ->
    ProjectRoot = value(project_root, Context),
    ScriptsDir = value(scripts_dir, Context),
    Image = value(image_name, Context) ++ ":" ++ Version,
    Base = ["run", "--rm"] ++
        env("ERLANG_VER", Version) ++
        env("PROJECT_NAME", value(project_name, Context)) ++
        env("TEST_SUITE", value(test_suite, Context)) ++
        env("TEST_CASE", value(test_case, Context)) ++
        env("RUN_XREF", bool_string(value(run_xref, Context))) ++
        env("RUN_DIALYZER", bool_string(value(run_dialyzer, Context))) ++
        env("USE_CHECKOUTS", bool_string(value(use_checkouts, Context))) ++
        env("OUTPUT_LANG", atom_to_list(value(output_lang, Context))) ++
        ["--volume", ProjectRoot ++ ":/mnt/source:ro",
         "--volume", ScriptsDir ++ ":/mnt/scripts:ro",
         "--volume", value(log_volume, Context) ++ ":/mnt/logs"],
    Base ++ checkout_args(value(checkouts, Context)) ++
        [Image, "bash", "/mnt/scripts/inner_test.sh"].

viewer_args(Volume, Port) ->
    ["run", "--rm",
     "--publish", integer_to_list(Port) ++ ":80",
     "--volume", Volume ++ ":/usr/share/nginx/html:ro",
     "nginx:alpine", "/bin/sh", "-c", "nginx -g 'daemon off;'"].

volume_file_args(Volume, RelativePath) ->
    ["run", "--rm", "--volume", Volume ++ ":/data:ro",
     "nginx:alpine", "/bin/sh", "-c", "test -f /data/" ++ RelativePath].

execute(Args) ->
    case os:find_executable("docker") of
        false -> {error, docker_not_found};
        Executable -> execute(Executable, Args)
    end.

execute(Executable, Args) ->
    try open_port({spawn_executable, Executable},
                  [binary, exit_status, use_stdio, stderr_to_stdout,
                   {args, Args}]) of
        Port -> collect(Port, true)
    catch
        error:Reason -> {error, {docker_start_failed, Reason}}
    end.

execute_quiet(Args) ->
    case os:find_executable("docker") of
        false -> {error, docker_not_found};
        Executable ->
            try open_port({spawn_executable, Executable},
                          [binary, exit_status, use_stdio, stderr_to_stdout,
                           {args, Args}]) of
                Port -> collect(Port, false)
            catch
                error:Reason -> {error, {docker_start_failed, Reason}}
            end
    end.

run_matrix(Versions, Fun) ->
    run_matrix(Versions, Fun, []).

run_matrix([], _Fun, []) ->
    ok;
run_matrix([], _Fun, Failures) ->
    {error, {ci_failed, lists:reverse(Failures)}};
run_matrix([Version | Rest], Fun, Failures) ->
    case Fun(Version) of
        ok -> run_matrix(Rest, Fun, Failures);
        {error, Reason} -> run_matrix(Rest, Fun, [{Version, Reason} | Failures])
    end.

collect(Port, Print) ->
    receive
        {Port, {data, Data}} ->
            maybe_print(Print, Data),
            collect(Port, Print);
        {Port, {exit_status, 0}} ->
            ok;
        {Port, {exit_status, Status}} ->
            {error, {command_failed, Status}}
    end.

maybe_print(true, Data) -> io:put_chars(Data);
maybe_print(false, _Data) -> ok.

env(Name, Value) ->
    ["--env", Name ++ "=" ++ Value].

checkout_args(Checkouts) ->
    lists:foldl(
      fun({Name, Path}, Acc) ->
              Acc ++ ["--volume", Path ++ ":/mnt/checkouts/" ++ Name ++ ":ro"]
      end, [], Checkouts).

bool_string(true) -> "true";
bool_string(false) -> "false".

value(Key, Values) ->
    proplists:get_value(Key, Values).
