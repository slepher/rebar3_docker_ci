-module(rebar3_docker_ci_docker).

-export([inspect_image_args/1, pull_args/1, detect_otp_args/1, parse_otp_release/1,
         run_args/2, viewer_args/2,
         execute/1, execute/2, execute_capture/1, execute_stream/4,
         execute_stream/5,
         execute_quiet/1, run_matrix/2, run_matrix/3]).

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
        env("RUN_CT", bool_string(maps:get(run_ct, Context))) ++
        env("RUN_EUNIT", bool_string(maps:get(run_eunit, Context))) ++
        env("OUTPUT_LANG", atom_to_list(maps:get(output_lang, Context))) ++
        env("R3DCI_NONCE", maps:get(nonce, Context)) ++
        env("RESULTS_DIR", "/mnt/results") ++
        host_user_args() ++
        ["--volume", ProjectRoot ++ ":/mnt/source:ro",
         "--volume", ScriptsDir ++ ":/mnt/scripts:ro",
         "--volume", maps:get(results_dir, Context) ++ ":/mnt/results"],
    Base ++ checkout_args(maps:get(checkouts, Context)) ++
        ["--entrypoint", "bash", Image, "/mnt/scripts/inner_test.sh"].

viewer_args(ResultsDir, Port) ->
    ["run", "--rm", "--interactive",
     "--publish", integer_to_list(Port) ++ ":80",
     "--volume", ResultsDir ++ ":/usr/share/nginx/html:ro",
     "nginx:alpine", "/bin/sh", "-c", viewer_command()].

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
                Port ->
                    case collect_capture(Port, []) of
                        {ok, _Output} = Ok -> Ok;
                        {error, Reason, _Output} -> {error, Reason}
                    end
            catch
                error:Reason -> {error, {docker_start_failed, Reason}}
            end
    end.

%% Execute a command while streaming its output. Raw data chunks are passed
%% to OnChunk in arrival order; complete lines are passed to OnLine after the
%% chunk that completed them. Both callbacks take a state and return
%% {ok, NewState} or {error, Reason}; a callback error aborts the command and
%% is returned as the result. The trailing partial line is flushed to OnLine
%% when the command exits. Returns {Result, FinalState}.
%%
%% The docker variant (execute_stream/4) additionally records the spawned
%% process id through the priv/docker-run.sh wrapper and terminates it with
%% SIGTERM when a callback fails, so a leftover docker CLI cannot keep a
%% container running after the worker moved on.
execute_stream(Args, OnChunk, OnLine, State0) ->
    case os:find_executable("docker") of
        false -> {{error, docker_not_found}, State0};
        Executable ->
            case wrapper_script() of
                undefined ->
                    execute_stream(Executable, Args, OnChunk, OnLine, State0);
                Wrapper ->
                    execute_stream_wrapped(Wrapper, Args, OnChunk, OnLine,
                                           State0)
            end
    end.

execute_stream_wrapped(Wrapper, Args, OnChunk, OnLine, State0) ->
    PidFile = pidfile_path(),
    try open_port({spawn_executable, Wrapper},
                  [binary, exit_status, use_stdio, stderr_to_stdout,
                   {args, Args}, {env, [{"DOCKER_CI_PIDFILE", PidFile}]}]) of
        Port ->
            try stream_collect(Port, <<>>, OnChunk, OnLine, State0,
                               pidfile_kill(PidFile)) of
                Result -> Result
            after
                cleanup_pidfile(PidFile)
            end
    catch
        error:Reason ->
            cleanup_pidfile(PidFile),
            {{error, {docker_start_failed, Reason}}, State0}
    end.

execute_stream(Executable, Args, OnChunk, OnLine, State0) ->
    try open_port({spawn_executable, Executable},
                  [binary, exit_status, use_stdio, stderr_to_stdout,
                   {args, Args}]) of
        Port ->
            stream_collect(Port, <<>>, OnChunk, OnLine, State0, fun() -> ok end)
    catch
        error:Reason -> {{error, {docker_start_failed, Reason}}, State0}
    end.

stream_collect(Port, Buffer, OnChunk, OnLine, State, Kill) ->
    receive
        {Port, {data, Data}} ->
            case OnChunk(Data, State) of
                {ok, State1} ->
                    {NewBuffer, Lines} = split_stream(Buffer, Data),
                    collect_lines(Port, NewBuffer, OnChunk, OnLine, Lines,
                                  State1, Kill);
                {error, Reason} ->
                    abort_stream(Port, Kill, Reason, State)
            end;
        {Port, {exit_status, Status}} ->
            case flush_partial(Buffer, OnLine, State) of
                {ok, State1} ->
                    case Status of
                        0 -> {ok, State1};
                        _ -> {{error, {command_failed, Status}}, State1}
                    end;
                {error, Reason} ->
                    abort_stream(Port, Kill, Reason, State)
            end
    end.

close_port(Port) ->
    try port_close(Port)
    catch
        error:badarg -> ok
    end,
    ok.

%% Every callback error converges on this single path: terminate the
%% spawned command, close the port and return the error.
abort_stream(Port, Kill, Reason, State) ->
    Kill(),
    close_port(Port),
    {{error, Reason}, State}.

collect_lines(Port, _Buffer, _OnChunk, _OnLine, [], State, Kill) ->
    stream_collect(Port, _Buffer, _OnChunk, _OnLine, State, Kill);
collect_lines(Port, Buffer, OnChunk, OnLine, [Line | Rest], State, Kill) ->
    case OnLine(Line, State) of
        {ok, State1} ->
            collect_lines(Port, Buffer, OnChunk, OnLine, Rest, State1, Kill);
        {error, Reason} ->
            abort_stream(Port, Kill, Reason, State)
    end.

flush_partial(<<>>, _OnLine, State) ->
    {ok, State};
flush_partial(Partial, OnLine, State) ->
    OnLine(Partial, State).

split_stream(Buffer, Data) ->
    All = <<Buffer/binary, Data/binary>>,
    Split = binary:split(All, <<"\n">>, [global]),
    case lists:reverse(Split) of
        [] -> {<<>>, []};
        [Partial | Rest] -> {Partial, lists:reverse(Rest)}
    end.

wrapper_script() ->
    case rebar3_docker_ci_project:priv_dir() of
        {ok, PrivDir} ->
            Script = filename:join(PrivDir, "docker-run.sh"),
            case filelib:is_regular(Script) of
                true -> Script;
                false -> undefined
            end;
        {error, _Reason} ->
            undefined
    end.

pidfile_path() ->
    filename:join("/tmp", "r3dci_docker_" ++
                      integer_to_list(erlang:unique_integer([positive])) ++
                      ".pid").

pidfile_kill(PidFile) ->
    fun() ->
            case file:read_file(PidFile) of
                {ok, Bin} ->
                    Pid = string:trim(binary_to_list(Bin)),
                    case Pid of
                        "" -> ok;
                        _ -> _ = os:cmd("kill -TERM " ++ Pid), ok
                    end;
                {error, _Reason} ->
                    ok
            end
    end.

cleanup_pidfile(PidFile) ->
    _ = file:delete(PidFile),
    ok.

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
    run_matrix(Versions, 1, Fun).

%% Run the matrix with up to Concurrency targets at a time.  Concurrency
%% may be 'max' to run all targets at once.  A failed target does not
%% stop the remaining ones; failures are collected per target.
run_matrix(Versions, Concurrency, Fun) ->
    case Concurrency of
        max -> run_matrix(Versions, length(Versions), Fun);
        0 -> ok;
        1 -> run_matrix_seq(Versions, Fun, []);
        N when is_integer(N), N > 1 -> run_matrix_pool(Versions, N, Fun)
    end.

run_matrix_seq([], _Fun, []) ->
    ok;
run_matrix_seq([], _Fun, Failures) ->
    {error, {ci_failed, lists:reverse(Failures)}};
run_matrix_seq([Version | Rest], Fun, Failures) ->
    case Fun(Version) of
        ok -> run_matrix_seq(Rest, Fun, Failures);
        {error, Reason} -> run_matrix_seq(Rest, Fun, [{Version, Reason} | Failures])
    end.

run_matrix_pool(Targets, Concurrency, Fun) ->
    Parent = self(),
    spawn_link(
      fun() ->
              Parent ! {run_matrix_result,
                        dispatch(Targets, Concurrency, Fun)}
      end),
    receive
        {run_matrix_result, Result} -> Result
    end.

dispatch(Targets, Concurrency, Fun) ->
    Dispatcher = self(),
    Workers = [spawn_link(fun() -> worker_loop(Dispatcher, Fun) end)
               || _ <- lists:seq(1, Concurrency)],
    dispatch_loop(Targets, 0, Workers, []).

%% Idle counts the workers that reported ready without receiving work.
%% The run finishes only when no targets remain and every worker is idle.
dispatch_loop([], Idle, Workers, Failures) when Idle =:= length(Workers) ->
    [Worker ! stop || Worker <- Workers],
    case Failures of
        [] -> ok;
        _ -> {error, {ci_failed, lists:reverse(Failures)}}
    end;
dispatch_loop(Targets, Idle, Workers, Failures) ->
    receive
        {ready, Worker} ->
            case Targets of
                [Next | Rest] ->
                    Worker ! {work, Next},
                    dispatch_loop(Rest, Idle, Workers, Failures);
                [] ->
                    dispatch_loop([], Idle + 1, Workers, Failures)
            end;
        {done, Target, Result} ->
            NewFailures = case Result of
                              ok -> Failures;
                              {error, Reason} -> [{Target, Reason} | Failures]
                          end,
            dispatch_loop(Targets, Idle, Workers, NewFailures)
    end.

worker_loop(Dispatcher, Fun) ->
    Dispatcher ! {ready, self()},
    receive
        {work, Target} ->
            Result = Fun(Target),
            Dispatcher ! {done, Target, Result},
            worker_loop(Dispatcher, Fun);
        stop ->
            ok
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
            {error, {command_failed, Status},
             iolist_to_binary(lists:reverse(Acc))}
    end.

env(Name, Value) ->
    ["--env", Name ++ "=" ++ Value].

%% Run the container as the host user instead of root.  All system
%% dependencies are provided by the pulled image, so the container can
%% start as the final user directly: the tests never run with more
%% privileges than the host user and the results written through the
%% mounted volume are owned by the host user.  The results directory is
%% created on the host first, so the mount point is already owned by the
%% host user.  This is only needed on Linux hosts; on macOS and Windows
%% the Docker Desktop file sharing layer maps the mount ownership to the
%% host user automatically.
host_user_args() ->
    case os:type() of
        {unix, linux} ->
            Uid = string:trim(os:cmd("id -u")),
            Gid = string:trim(os:cmd("id -g")),
            ["--user", Uid ++ ":" ++ Gid];
        _ ->
            []
    end.

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
