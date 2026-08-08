-module(rebar3_docker_ci_prv_run).

-behaviour(provider).

-export([init/1, do/1, format_error/1, opts/0, validate_selection/2,
         validate_selection/3, matrix_results/2, effective_jobs/2,
         prepare_otp_dir/1, summary_content/5,
         acquire_run_lock/1, release_run_lock/1]).
init(State) ->
    Provider = providers:create(
                 [{name, run},
                  {module, ?MODULE},
                  {namespace, docker_ci},
                  {bare, true},
                  {deps, []},
                  {example, "rebar3 docker_ci run --otp 28 --suite sample_SUITE"},
                  {short_desc, "Run Rebar3 checks in Docker."},
                  {desc, "Run compile, xref, optional Dialyzer, and Common Test. "
                         "--suite may be used alone; --case requires --suite. "
                         "Results are written under _build/docker_ci/results."},
                  {opts, opts()}]),
    {ok, rebar_state:add_provider(State, Provider)}.

opts() ->
    [{otp, $o, "otp", string,
      "Run only this Erlang/OTP version instead of the configured matrix."},
     {suite, $s, "suite", string,
      "Run one Common Test suite; may be used without --case."},
     {'case', $c, "case", string,
      "Run one Common Test case; requires --suite."},
     {dialyzer, $d, "dialyzer", boolean,
      "Enable Dialyzer for this run."},
      {skip_xref, undefined, "skip-xref", boolean,
       "Disable xref for this run."},
      {jobs, $j, "jobs", string,
       "Run up to this many targets concurrently; 'max' runs all at once. "
       "Overrides the jobs config."},
      {no_checkouts, undefined, "no-checkouts", boolean,
       "Ignore the project's _checkouts directory for this run."},
     {view, undefined, "view", boolean,
      "Start the log viewer after the checks instead of returning."}].

do(State) ->
    Options = parsed_options(State),
    Suite = option_string(suite, Options),
    TestCase = option_string('case', Options),
    case rebar3_docker_ci_config:load(State) of
        {ok, Config} ->
            RunCt = rebar3_docker_ci_config:get(run_ct, Config),
            case validate_selection(Suite, TestCase, RunCt) of
                {ok, Selection} -> load_and_run(State, Options, Selection);
                {error, Reason} -> {error, {?MODULE, Reason}}
            end;
        {error, Reason} -> {error, {?MODULE, Reason}}
    end.

validate_selection(Suite, TestCase) ->
    validate_selection(Suite, TestCase, true).

validate_selection("", "", _RunCt) -> {ok, {"", ""}};
validate_selection("", _TestCase, _RunCt) -> {error, case_requires_suite};
validate_selection(Suite, TestCase, RunCt) ->
    case RunCt of
        true -> {ok, {Suite, TestCase}};
        false -> {error, {selection_requires_ct, Suite}}
    end.

format_error(Reason) ->
    rebar3_docker_ci:format_error(Reason).

load_and_run(State, Options, Selection) ->
    case rebar3_docker_ci_config:load(State) of
        {ok, Config} ->
            Root = rebar3_docker_ci_project:root(),
            ProjectName = rebar3_docker_ci_project:name(State),
            CheckoutMode = case maps:get(no_checkouts, Options, false) of
                               true -> false;
                               false ->
                                   rebar3_docker_ci_config:get(use_checkouts, Config)
                           end,
            case rebar3_docker_ci_project:resolve_checkouts(Root, CheckoutMode) of
                {ok, Checkouts} ->
                    {Suite, TestCase} = Selection,
                    run_with_project(State, Options, Suite, TestCase, Config,
                                     Root, ProjectName, Checkouts);
                {error, Reason} -> {error, {?MODULE, Reason}}
            end;
        {error, Reason} -> {error, {?MODULE, Reason}}
    end.

run_with_project(State, Options, Suite, TestCase, Config,
                 Root, ProjectName, Checkouts) ->
    Images = rebar3_docker_ci_config:get(target_images, Config),
    ResultsDir = rebar3_docker_ci_project:results_dir(Root),
    case rebar3_docker_ci_targets:resolve(Images) of
        {ok, ResolvedTargets} ->
            case rebar3_docker_ci_targets:select(
                   ResolvedTargets, maps:get(otp, Options, undefined)) of
                {ok, Targets} ->
                    run_targets(State, Options, Suite, TestCase, Config,
                                Root, ProjectName, ResultsDir, Targets, Checkouts);
                {error, Reason} -> {error, {?MODULE, Reason}}
            end;
        {error, Reason} -> {error, {?MODULE, Reason}}
    end.

run_targets(State, Options, Suite, TestCase, Config,
            Root, ProjectName, ResultsDir, Targets, Checkouts) ->
    case effective_jobs(Options, Config) of
        {ok, Jobs} ->
            run_with_jobs(State, Options, Suite, TestCase, Config, Root,
                          ProjectName, ResultsDir, Targets, Checkouts, Jobs);
        {error, Reason} -> {error, {?MODULE, Reason}}
    end.

run_with_jobs(State, Options, Suite, TestCase, Config,
              Root, ProjectName, ResultsDir, Targets, Checkouts, Jobs) ->
    case acquire_run_lock(Root) of
        {ok, LockPath} ->
            try run_locked(State, Options, Suite, TestCase, Config, Root,
                           ProjectName, ResultsDir, Targets, Checkouts, Jobs)
            after
                release_run_lock(LockPath)
            end;
        {error, Reason} ->
            {error, {?MODULE, Reason}}
    end.

%% A second `docker_ci run' for the same project would race on the plugin
%% staging directory, ci-results.txt and every per-OTP artifact. The lock
%% file is created exclusively and held for the whole run, so concurrent
%% host processes are refused instead of corrupting each other.
acquire_run_lock(Root) ->
    LockDir = filename:join([Root, "_build", "docker_ci"]),
    LockPath = filename:join(LockDir, "run.lock"),
    case filelib:ensure_dir(filename:join(LockDir, "placeholder")) of
        ok ->
            case file:open(LockPath, [write, exclusive]) of
                {ok, Fd} ->
                    ok = file:close(Fd),
                    {ok, LockPath};
                {error, eexist} ->
                    {error, run_in_progress};
                {error, Reason} ->
                    {error, {run_lock_failed, LockPath, Reason}}
            end;
        {error, Reason} ->
            {error, {run_lock_failed, LockDir, Reason}}
    end.

release_run_lock(LockPath) ->
    _ = file:delete(LockPath),
    ok.

run_locked(State, Options, Suite, TestCase, Config,
           Root, ProjectName, ResultsDir, Targets, Checkouts, Jobs) ->
    case ensure_results_dir(ResultsDir) of
        ok ->
            case rebar3_docker_ci_project:priv_dir() of
                {ok, PrivDir} ->
                    ok = cleanup_legacy_artifacts(Root, ResultsDir),
                    RunId = make_run_id(),
                    Context = #{project_root => Root,
                                scripts_dir => PrivDir,
                                project_name => ProjectName,
                                results_dir => ResultsDir,
                                test_suite => Suite,
                                test_case => TestCase,
                                run_xref => effective_xref(Options, Config),
                                run_dialyzer => effective_dialyzer(Options, Config),
                                run_ct =>
                                    rebar3_docker_ci_config:get(run_ct, Config),
                                run_eunit =>
                                    rebar3_docker_ci_config:get(run_eunit, Config),
                                use_checkouts => Checkouts =/= [],
                                output_lang => output_language(Config),
                                checkouts => Checkouts,
                                run_id => RunId},
                    maybe_logs_start(ProjectName, Targets, Jobs),
                    Result = rebar3_docker_ci_docker:run_matrix(
                               Targets, Jobs, run_fun(Context)),
                    case report_run(ProjectName, Targets, ResultsDir,
                                    Result, RunId) of
                        ok ->
                            maybe_logs_finish(ProjectName, Targets, Result),
                            maybe_logs_hint(ResultsDir),
                            finish_run(State, Options, ProjectName, Targets,
                                       ResultsDir, Config, Result);
                        {error, Reason} -> {error, {?MODULE, Reason}}
                    end;
                {error, Reason} -> {error, {?MODULE, Reason}}
            end;
        {error, Reason} -> {error, {?MODULE, Reason}}
    end.

%% Each selected OTP gets a clean single-run boundary before its container
%% starts. The Common Test log collection (<otp>/logs) is native history and
%% is preserved; everything else from a previous round is removed. The first
%% cleanup error aborts the target: stale cover, summary or legacy artifacts
%% must never be re-referenced by the new report.
prepare_otp_dir(OtpDir) ->
    case filelib:ensure_dir(filename:join(OtpDir, "placeholder")) of
        ok -> cleanup_round_artifacts(OtpDir);
        {error, Reason} ->
            {error, {results_dir_failed, OtpDir, Reason}}
    end.

cleanup_round_artifacts(OtpDir) ->
    lists:foldl(
      fun(Path, ok) -> remove_round_artifact(Path);
         (_Path, {error, _} = Error) -> Error
      end, ok, round_artifacts(OtpDir)).

round_artifacts(OtpDir) ->
    [filename:join(OtpDir, Name) || Name <- ["ci.log", "ci-summary.txt",
                                             "ci-summary.txt.tmp", "cover",
                                             "failures.txt", "compile.log",
                                             "xref.log", "dialyzer.log",
                                             "common_test.log", "eunit.log"]].

remove_round_artifact(Path) ->
    case filelib:is_dir(Path) of
        true ->
            case rebar3_docker_ci_files:del_dir_r(Path) of
                ok -> ok;
                {error, enoent} -> ok;
                {error, Reason} ->
                    {error, {artifact_cleanup_failed, Path, Reason}}
            end;
        false ->
            case file:delete(Path) of
                ok -> ok;
                {error, enoent} -> ok;
                {error, Reason} ->
                    {error, {artifact_cleanup_failed, Path, Reason}}
            end
    end.

%% Remove artifacts of the pre-streaming layout once per run: the legacy
%% _build/docker_ci/logs tree (run.log files) and the previous ci-results.txt.
cleanup_legacy_artifacts(Root, ResultsDir) ->
    _ = rebar3_docker_ci_files:del_dir_r(
          rebar3_docker_ci_project:logs_dir(Root)),
    _ = file:delete(filename:join(ResultsDir, "ci-results.txt")),
    _ = file:delete(filename:join(ResultsDir, "ci-results.txt.tmp")),
    ok.

run_fun(Context) ->
    fun(Target) ->
            Otp = maps:get(otp, Target),
            rebar_api:info("[~s] Running Docker CI on OTP ~s [~s]",
                           [timestamp(), Otp, maps:get(image, Target)]),
            Result = run_target(Context, Target),
            target_end_line(Otp, Result),
            Result
    end.

run_target(Context, Target) ->
    Otp = maps:get(otp, Target),
    ResultsDir = maps:get(results_dir, Context),
    OtpDir = filename:join(ResultsDir, Otp),
    case prepare_otp_dir(OtpDir) of
        ok ->
            %% One nonce per target: the container's events must carry it,
            %% separating concurrent streams and accidental prefix collisions.
            TargetContext = Context#{nonce => make_nonce(Otp)},
            CiLog = filename:join(OtpDir, "ci.log"),
            Result = case open_ci_log(CiLog, Target) of
                         {ok, Fd} ->
                             {RunResult, Statuses, Events} =
                                 run_docker_stream(TargetContext, Target,
                                                   OtpDir, Fd),
                             ok = file:close(Fd),
                             {RunResult, Statuses, Events};
                         {error, OpenReason} ->
                             {{error, {ci_log_failed, CiLog, OpenReason}},
                              all_skipped(),
                              rebar3_docker_ci_events:new(maps:get(nonce,
                                                                   TargetContext))}
                     end,
            case publish_summary(TargetContext, Target, OtpDir, Result) of
                ok -> element(1, Result);
                {error, SummaryReason} -> {error, {summary_failed, SummaryReason}}
            end;
        {error, Reason} ->
            {error, Reason}
    end.

make_nonce(Otp) ->
    Stamp = integer_to_list(erlang:unique_integer([positive, monotonic])),
    Otp ++ "-" ++ Stamp.

make_run_id() ->
    integer_to_list(os:system_time(microsecond)) ++ "-" ++
        integer_to_list(erlang:unique_integer([positive, monotonic])).

all_skipped() ->
    [{Stage, skipped} || Stage <- rebar3_docker_ci_events:stages()].

open_ci_log(CiLog, Target) ->
    case file:open(CiLog, [write, raw, binary]) of
        {ok, Fd} ->
            Header = io_lib:format("Erlang/OTP ~s (image: ~s)~n",
                                   [maps:get(otp, Target),
                                    maps:get(image, Target)]),
            case file:write(Fd, Header) of
                ok -> {ok, Fd};
                {error, Reason} ->
                    ok = file:close(Fd),
                    {error, Reason}
            end;
        {error, Reason} ->
            {error, Reason}
    end.

run_docker_stream(Context, Target, OtpDir, Fd) ->
    Otp = maps:get(otp, Target),
    Nonce = maps:get(nonce, Context),
    Events0 = rebar3_docker_ci_events:new(Nonce),
    OnChunk = fun(Chunk, State) ->
                      case file:write(Fd, Chunk) of
                          ok -> {ok, State};
                          {error, Reason} ->
                              {error, {ci_log_failed,
                                       filename:join(OtpDir, "ci.log"), Reason}}
                      end
              end,
    OnLine = fun(Line, State) -> handle_line(Line, Otp, Fd, Nonce, State) end,
    {DockerResult, Events} = rebar3_docker_ci_docker:execute_stream(
                               rebar3_docker_ci_docker:run_args(Context, Target),
                               OnChunk, OnLine, Events0),
    finalize_run(DockerResult, Otp, Events).

handle_line(Line, Otp, Fd, Nonce, State) ->
    case rebar3_docker_ci_events:parse_line(Line, Nonce) of
        {event, {ct_run, _Name} = Event} ->
            case rebar3_docker_ci_events:apply_event(Event, State) of
                {ok, State1} ->
                    {ok, State1};
                {error, Invalid} ->
                    note(Fd, io_lib:format("protocol error: ~p", [Invalid])),
                    {error, {protocol_error, Invalid}}
            end;
        {event, Event} ->
            case rebar3_docker_ci_events:apply_event(Event, State) of
                {ok, State1} ->
                    print_event(Otp, Event),
                    {ok, State1};
                {error, Invalid} ->
                    note(Fd, io_lib:format("protocol error: ~p", [Invalid])),
                    {error, {protocol_error, Invalid}}
            end;
        unknown_event ->
            note(Fd, io_lib:format("unknown event line: ~s", [Line])),
            {error, {protocol_error, unknown_event}};
        none ->
            {ok, State}
    end.

print_event(Otp, {stage_started, Stage}) ->
    rebar_api:info("[~s] OTP ~s: ~s started",
                   [timestamp(), Otp, stage_name(Stage)]);
print_event(Otp, {stage_finished, Stage, 0}) ->
    rebar_api:info("[~s] OTP ~s: ~s passed",
                   [timestamp(), Otp, stage_name(Stage)]);
print_event(Otp, {stage_finished, Stage, _Code}) ->
    rebar_api:info("[~s] OTP ~s: ~s failed",
                   [timestamp(), Otp, stage_name(Stage)]);
print_event(Otp, {stage_skipped, Stage}) ->
    rebar_api:info("[~s] OTP ~s: ~s skipped",
                   [timestamp(), Otp, stage_name(Stage)]).

stage_name(common_test) -> "common_test";
stage_name(Stage) -> atom_to_list(Stage).

note(Fd, Text) ->
    _ = file:write(Fd, io_lib:format("R3DCI note: ~s~n", [Text])),
    ok.

finalize_run(ok, _Otp, Events) ->
    case rebar3_docker_ci_events:finalize(Events, ok) of
        {ok, Final} ->
            {ok, rebar3_docker_ci_events:statuses(Final), Final};
        {error, {incomplete, Missing}} ->
            {{error, {protocol_error, {incomplete, Missing}}},
             rebar3_docker_ci_events:statuses(Events), Events}
    end;
finalize_run({error, {command_failed, Status}}, Otp, Events) ->
    {ok, Final} = rebar3_docker_ci_events:finalize(Events, {error, exit}),
    Statuses = rebar3_docker_ci_events:statuses(Final),
    print_aborted(Otp, Statuses),
    {{error, classify_failure(Statuses, {command_failed, Status})}, Statuses,
     Final};
finalize_run({error, Reason}, _Otp, Events) ->
    {ok, Final} = rebar3_docker_ci_events:finalize(Events, {error, Reason}),
    Statuses = rebar3_docker_ci_events:statuses(Final),
    TargetReason = case Reason of
                       {ci_log_failed, _, _} -> Reason;
                       {protocol_error, _} -> Reason;
                       _ -> {infra, Reason}
                   end,
    {{error, TargetReason}, Statuses, Final}.

print_aborted(Otp, Statuses) ->
    lists:foreach(
      fun({Stage, aborted}) ->
              rebar_api:info("[~s] OTP ~s: ~s aborted",
                             [timestamp(), Otp, stage_name(Stage)]);
         ({_Stage, _Status}) -> ok
      end, Statuses).

classify_failure(Statuses, Fallback) ->
    case first_status(Statuses, failed) of
        undefined ->
            case first_status(Statuses, aborted) of
                undefined -> Fallback;
                Stage -> {aborted, Stage}
            end;
        Stage -> {stage_failed, Stage}
    end.

first_status(Statuses, Wanted) ->
    case [{Stage, Status} || {Stage, Status} <- Statuses, Status =:= Wanted] of
        [{Stage, _} | _] -> Stage;
        [] -> undefined
    end.

publish_summary(Context, Target, OtpDir, {Result, Statuses, Events}) ->
    CtRun = rebar3_docker_ci_events:ct_run(Events),
    Content = summary_content(Context, Target, Statuses, Result, CtRun),
    write_atomic(filename:join(OtpDir, "ci-summary.txt"), Content).

summary_content(Context, Target, Statuses, Result, CtRun) ->
    Suite = case maps:get(test_suite, Context) of
                "" -> "ALL";
                SuiteValue -> SuiteValue
            end,
    Case = case maps:get(test_case, Context) of
               "" -> "ALL";
               CaseValue -> CaseValue
           end,
    CtRunLine = case CtRun of
                    none -> [];
                    Name -> io_lib:format("ct_run=~s~n", [Name])
                end,
    RunIdLine = case maps:get(run_id, Context, undefined) of
                    undefined -> [];
                    RunId -> io_lib:format("run_id=~s~n", [RunId])
                end,
    [io_lib:format("project=~s~n", [maps:get(project_name, Context)]),
     RunIdLine,
     io_lib:format("erlang_otp=~s~n", [maps:get(otp, Target)]),
     io_lib:format("image=~s~n", [maps:get(image, Target)]),
     io_lib:format("test_suite=~s~n", [Suite]),
     io_lib:format("test_case=~s~n", [Case]),
     [io_lib:format("~s=~s~n",
                    [atom_to_list(Stage),
                     rebar3_docker_ci_events:summary_value(Status)])
      || {Stage, Status} <- Statuses],
     CtRunLine,
     io_lib:format("result=~s~n", [result_value(Result)])].

result_value(ok) -> "0";
result_value({error, _Reason}) -> "1".

write_atomic(Path, Content) ->
    Tmp = Path ++ ".tmp",
    case file:write_file(Tmp, Content) of
        ok ->
            case file:rename(Tmp, Path) of
                ok -> ok;
                {error, Reason} -> {error, {Path, Reason}}
            end;
        {error, Reason} ->
            {error, {Path, Reason}}
    end.

target_end_line(Otp, ok) ->
    rebar_api:info("[~s] OTP ~s: PASSED", [timestamp(), Otp]);
target_end_line(Otp, {error, _Reason}) ->
    rebar_api:info("[~s] OTP ~s: FAILED", [timestamp(), Otp]).

timestamp() ->
    Ms = os:system_time(millisecond),
    {{_, _, _}, {H, Mi, S}} = calendar:system_time_to_local_time(Ms, millisecond),
    io_lib:format("~2..0b:~2..0b:~2..0b.~3..0b", [H, Mi, S, Ms rem 1000]).

finish_run(State, Options, ProjectName, Targets, ResultsDir, Config, Result) ->
    case maps:get(view, Options, false) of
        true ->
            Port = rebar3_docker_ci_config:get(log_port, Config),
            Versions = [maps:get(otp, Target) || Target <- Targets],
            rebar3_docker_ci_prv_logs:print_links(
              ProjectName, Versions, ResultsDir, Port),
            case rebar3_docker_ci_docker:execute(
                   rebar3_docker_ci_docker:viewer_args(ResultsDir, Port)) of
                ok -> provider_result(State, Result);
                {error, Reason} -> {error, {?MODULE, Reason}}
            end;
        false ->
            provider_result(State, Result)
    end.

report_run(ProjectName, Targets, ResultsDir, Result, RunId) ->
    Content = rebar3_docker_ci_report:content(
                ProjectName, Targets, Result, ResultsDir, RunId),
    ResultsFile = filename:join(ResultsDir, "ci-results.txt"),
    case write_atomic(ResultsFile, Content) of
        ok ->
            rebar_api:info("~s", [Content]),
            ok;
        {error, Reason} ->
            {error, {results_write_failed, ResultsFile, Reason}}
    end.

matrix_results(Targets, ok) ->
    [{Target, passed} || Target <- Targets];
matrix_results(Targets, {error, {ci_failed, Failures}}) ->
    [matrix_target_result(Target, Failures) || Target <- Targets];
matrix_results(Targets, {error, Reason}) ->
    [{Target, {failed, Reason}} || Target <- Targets].

matrix_target_result(Target, Failures) ->
    case lists:keyfind(Target, 1, Failures) of
        false -> {Target, passed};
        {Target, Reason} -> {Target, {failed, Reason}}
    end.

provider_result(State, ok) -> {ok, State};
provider_result(_State, {error, Reason}) -> {error, {?MODULE, Reason}}.

ensure_results_dir(ResultsDir) ->
    case filelib:ensure_dir(filename:join(ResultsDir, "placeholder")) of
        ok -> check_results_dir_writable(ResultsDir);
        {error, Reason} -> {error, {results_dir_failed, ResultsDir, Reason}}
    end.

%% On Linux hosts the test container runs as the host user; a results
%% directory left behind by older root-run versions is not writable and
%% would silently swallow all results.  Fail loudly before running.
check_results_dir_writable(ResultsDir) ->
    Probe = filename:join(ResultsDir, ".write_probe"),
    case file:write_file(Probe, <<>>) of
        ok ->
            ok = file:delete(Probe),
            ok;
        {error, Reason} ->
            {error, {results_dir_not_writable, ResultsDir, Reason}}
    end.

effective_xref(Options, Config) ->
    case maps:get(skip_xref, Options, false) of
        true -> false;
        false -> rebar3_docker_ci_config:get(run_xref, Config)
    end.

effective_dialyzer(Options, Config) ->
    maps:get(dialyzer, Options, false) orelse
        rebar3_docker_ci_config:get(run_dialyzer, Config).

output_language(Config) ->
    case rebar3_docker_ci_config:get(output_lang, Config) of
        auto ->
            case os:getenv("LANG") of
                false -> en;
                Lang ->
                    case string:prefix(string:lowercase(Lang), "zh") of
                        nomatch -> en;
                        _Suffix -> cn
                    end
            end;
        Language -> Language
    end.

effective_jobs(Options, Config) ->
    case maps:get(jobs, Options, undefined) of
        undefined -> {ok, rebar3_docker_ci_config:get(jobs, Config)};
        Value -> parse_jobs(Value)
    end.

parse_jobs("max") ->
    {ok, max};
parse_jobs(Value) ->
    case string:to_integer(Value) of
        {Jobs, ""} when Jobs >= 1 -> {ok, Jobs};
        _ -> {error, {invalid_jobs, Value}}
    end.

maybe_logs_hint(ResultsDir) ->
    rebar_api:info("[~s] Target docker output saved under ~s",
                   [timestamp(), ResultsDir]).

maybe_logs_start(ProjectName, Targets, Jobs) ->
    rebar_api:info("[~s] Docker CI started for ~s: OTP ~s, jobs=~p",
                   [timestamp(), ProjectName, otp_list(Targets), Jobs]).

maybe_logs_finish(ProjectName, Targets, ok) ->
    rebar_api:info("[~s] Docker CI finished for ~s: all ~p target(s) passed (OTP ~s)",
                   [timestamp(), ProjectName, length(Targets), otp_list(Targets)]);
maybe_logs_finish(ProjectName, Targets, {error, {ci_failed, Failures}}) ->
    FailedTargets = [Target || {Target, _Reason} <- Failures],
    rebar_api:info("[~s] Docker CI finished for ~s: ~p of ~p target(s) failed (OTP ~s)",
                   [timestamp(), ProjectName, length(Failures), length(Targets),
                    otp_list(FailedTargets)]).

otp_list(Targets) ->
    string:join([maps:get(otp, Target) || Target <- Targets], ", ").

option_string(Key, Options) ->
    case maps:get(Key, Options, undefined) of
        undefined -> "";
        Value -> Value
    end.

parsed_options(State) ->
    case rebar_state:command_parsed_args(State) of
        {Options, _Arguments} -> maps:from_list(Options);
        Options when is_list(Options) -> maps:from_list(Options)
    end.
