-module(rebar3_docker_ci_docker).

-export([build_args/4, inspect_image_args/2, inspect_image_args/1,
         pull_args/1, detect_otp_args/1, parse_otp_release/1,
         create_volume_args/1, run_args/2, viewer_args/2, volume_file_args/2,
         inspect_volume_args/1, execute/1, execute/2, execute_capture/1,
         execute_quiet/1, run_matrix/2]).

build_args(Image, Version, Dockerfile, Context) ->
    ["build", "--tag", Image ++ ":" ++ Version,
     "--build-arg", "ERLANG_VER=" ++ Version,
     "--file", Dockerfile, Context].

inspect_image_args(Image, Version) ->
    ["image", "inspect", Image ++ ":" ++ Version].

pull_args(Image) ->
    ["pull", Image].

inspect_image_args(Image) ->
    ["image", "inspect", Image].

detect_otp_args(Image) ->
    ["run", "--rm", "--entrypoint", "erl", Image,
     "-noshell", "-eval",
     "io:format(\"~s\", [erlang:system_info(otp_release)]), halt()."].

parse_otp_release(Output) when is_binary(Output) ->
    parse_otp_release(binary_to_list(Output));
parse_otp_release(Output) when is_list(Output) ->
    Release = string:trim(Output),
    case Release =/= [] andalso lists:all(fun otp_release_char/1, Release) of
        true -> {ok, Release};
        false -> {error, invalid_otp_release}
    end;
parse_otp_release(_Output) ->
    {error, invalid_otp_release}.

inspect_volume_args(Volume) ->
    ["volume", "inspect", Volume].

create_volume_args(Volume) ->
    ["volume", "create", Volume].

run_args(Context, Target) ->
    ProjectRoot = maps:get(project_root, Context),
    ScriptsDir = maps:get(scripts_dir, Context),
    Image = maps:get(image, Target),
    Version = maps:get(otp, Target),
    Base = ["run", "--rm"] ++
        env("ERLANG_VER", Version) ++
        env("PROJECT_NAME", maps:get(project_name, Context)) ++
        env("TEST_SUITE", maps:get(test_suite, Context)) ++
        env("TEST_CASE", maps:get(test_case, Context)) ++
        env("RUN_XREF", bool_string(maps:get(run_xref, Context))) ++
        env("RUN_DIALYZER", bool_string(maps:get(run_dialyzer, Context))) ++
        env("USE_CHECKOUTS", bool_string(maps:get(use_checkouts, Context))) ++
        env("OUTPUT_LANG", atom_to_list(maps:get(output_lang, Context))) ++
        ["--volume", ProjectRoot ++ ":/mnt/source:ro",
         "--volume", ScriptsDir ++ ":/mnt/scripts:ro",
         "--volume", maps:get(log_volume, Context) ++ ":/mnt/logs"],
    Base ++ checkout_args(maps:get(checkouts, Context)) ++
        ["--entrypoint", "bash", Image, "/mnt/scripts/inner_test.sh"].

viewer_args(Volume, Port) ->
    ["run", "--rm", "--interactive",
     "--publish", integer_to_list(Port) ++ ":80",
     "--volume", Volume ++ ":/usr/share/nginx/html:ro",
     "nginx:alpine", "/bin/sh", "-c", viewer_command()].

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

execute_capture(Args) ->
    case os:find_executable("docker") of
        false -> {error, docker_not_found};
        Executable ->
            try open_port({spawn_executable, Executable},
                          [binary, exit_status, use_stdio, stderr_to_stdout,
                           {args, Args}]) of
                Port -> collect_capture(Port, [])
            catch
                error:Reason -> {error, {docker_start_failed, Reason}}
            end
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

collect_capture(Port, Acc) ->
    receive
        {Port, {data, Data}} ->
            collect_capture(Port, [Data | Acc]);
        {Port, {exit_status, 0}} ->
            {ok, iolist_to_binary(lists:reverse(Acc))};
        {Port, {exit_status, Status}} ->
            {error, {command_failed, Status}}
    end.

env(Name, Value) ->
    ["--env", Name ++ "=" ++ Value].

checkout_args(Checkouts) ->
    lists:foldl(
      fun({Name, Path}, Acc) ->
              Acc ++ ["--volume", Path ++ ":/mnt/checkouts/" ++ Name ++ ":ro"]
      end, [], Checkouts).

bool_string(true) -> "true";
bool_string(false) -> "false".

otp_release_char(Char) when Char >= $0, Char =< $9 -> true;
otp_release_char($.) -> true;
otp_release_char($-) -> true;
otp_release_char($_) -> true;
otp_release_char(_Char) -> false.

viewer_command() ->
    "printf '%s\\n' "
    "'error_log /dev/stderr error;' "
    "'pid /tmp/nginx.pid;' "
    "'events {}' "
    "'http { access_log off; include /etc/nginx/mime.types; "
    "include /etc/nginx/conf.d/*.conf; }' "
    "> /tmp/nginx-quiet.conf; "
    "exec 3<&0; "
    "nginx -c /tmp/nginx-quiet.conf -g 'daemon off;' & nginx_pid=$!; "
    "(while IFS= read -r line <&3; do :; done; "
    "kill -TERM $nginx_pid 2>/dev/null) & stdin_watcher=$!; "
    "trap 'kill -TERM $nginx_pid 2>/dev/null; "
    "kill $stdin_watcher 2>/dev/null' HUP INT TERM; "
    "wait $nginx_pid; status=$?; "
    "kill $stdin_watcher 2>/dev/null; "
    "wait $stdin_watcher 2>/dev/null; "
    "exit $status".
