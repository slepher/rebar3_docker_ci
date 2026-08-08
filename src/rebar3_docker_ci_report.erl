-module(rebar3_docker_ci_report).

-export([content/5, parse_suite_log/1, failure_blocks/1]).

-define(CHECKS, [compile, xref, dialyzer, common_test, eunit]).

content(ProjectName, Targets, Result, ResultsDir, RunId) ->
    Statuses = [{Target, target_status(Target, Result)} || Target <- Targets],
    FailedCount = length([1 || {_Target, Status} <- Statuses, Status =/= passed]),
    Header = [io_lib:format("project=~s~n", [ProjectName]),
              io_lib:format("ran_at=~s~n", [timestamp()]),
              io_lib:format("overall=~s~n", [overall(Result)]),
              io_lib:format("targets=~p~n", [length(Targets)]),
              "---\n"],
    TargetLines = lists:append(
                    [target_lines(Target, Status, ResultsDir, RunId)
                     || {Target, Status} <- Statuses]),
    Footer = ["---\n",
              io_lib:format("overall_result=~s~n",
                            [overall_result(Result, FailedCount,
                                            length(Targets))])],
    [Header, TargetLines, Footer].

target_status(_Target, ok) ->
    passed;
target_status(Target, {error, {ci_failed, Failures}}) ->
    case lists:keyfind(Target, 1, Failures) of
        false -> passed;
        {Target, Reason} -> {failed, Reason}
    end;
target_status(_Target, {error, _Reason}) ->
    {failed, {command_failed, unknown}}.

target_lines(Target, passed, _ResultsDir, _RunId) ->
    [io_lib:format(">>> Erlang/OTP ~s [~s]: PASSED~n",
                   [maps:get(otp, Target), maps:get(image, Target)])];
target_lines(Target, {failed, Failure}, ResultsDir, RunId) ->
    OtpDir = filename:join(ResultsDir, maps:get(otp, Target)),
    case read_summary(OtpDir, RunId) of
        error ->
            [io_lib:format(">>> Erlang/OTP ~s [~s]: ~s~n",
                           [maps:get(otp, Target), maps:get(image, Target),
                            failed_header(undefined, Failure)])];
        {ok, Summary} ->
            FailedCheck = failed_check(Summary),
            Header = io_lib:format(">>> Erlang/OTP ~s [~s]: ~s~n",
                                   [maps:get(otp, Target), maps:get(image, Target),
                                    failed_header(FailedCheck, Failure)]),
            [Header, check_lines(Summary),
             failed_detail_lines(OtpDir, FailedCheck)] ++
                link_lines(OtpDir, Summary)
    end.

failed_header(undefined, {command_failed, Status}) ->
    "FAILED (exit code " ++ integer_to_list(Status) ++ ")";
failed_header(undefined, {infra, docker_not_found}) ->
    "FAILED (docker not found)";
failed_header(undefined, {infra, _Reason}) ->
    "FAILED (docker infrastructure error)";
failed_header(undefined, {protocol_error, _Detail}) ->
    "FAILED (protocol error)";
failed_header(undefined, {aborted, Stage}) ->
    "FAILED (" ++ atom_to_list(Stage) ++ " aborted)";
failed_header(undefined, _Failure) ->
    "FAILED (unknown)";
failed_header(Check, _Failure) ->
    "FAILED (" ++ atom_to_list(Check) ++ ")".

check_lines(Summary) ->
    [io_lib:format("    ~-13s ~s~n", [atom_to_list(Check) ++ ":", status_text(Status)])
     || {Check, Status} <- check_statuses(Summary)].

failed_detail_lines(OtpDir, FailedCheck) ->
    case FailedCheck of
        common_test ->
            [io_lib:format("    Failed cases: ~s~n", [Block])
             || Block <- failure_blocks(OtpDir)];
        _ ->
            []
    end.

link_lines(OtpDir, Summary) ->
    links([{"CI log", filename:join(OtpDir, "ci.log")},
           {"Summary", filename:join(OtpDir, "ci-summary.txt")}], []) ++
        ct_link_lines(OtpDir, Summary) ++
        cover_link_lines(OtpDir).

ct_link_lines(OtpDir, Summary) ->
    case ct_ran_this_round(Summary) of
        true ->
            links([{"CT logs", filename:join([OtpDir, "logs", "index.html"])}],
                  []);
        false ->
            []
    end.

cover_link_lines(OtpDir) ->
    links([{"Cover", filename:join([OtpDir, "cover", "index.html"])}], []).

%% CT logs may only be presented as this round's artifacts when the runner
%% recorded the exact ct_run directory of this round in the summary. A
%% skipped stage, or a CT run that failed before creating its log
%% directory, leaves history untouched and unlinked here; the report never
%% falls back to the newest historical run.
ct_ran_this_round(Summary) ->
    maps:is_key("ct_run", Summary).

links([], Acc) ->
    lists:reverse(Acc);
links([{Label, Path} | Rest], Acc) ->
    case filelib:is_regular(Path) of
        true ->
            links(Rest, [io_lib:format("    ~-13s ~s~n", [Label ++ ":", Path]) | Acc]);
        false ->
            links(Rest, Acc)
    end.

check_statuses(Summary) ->
    [{Check, check_status(Summary, Check)} || Check <- ?CHECKS].

check_status(Summary, Check) ->
    case maps:get(atom_to_list(Check), Summary, "skipped") of
        "0" -> ok;
        "skipped" -> skipped;
        "aborted" -> aborted;
        _ -> failed
    end.

status_text(ok) -> "ok";
status_text(skipped) -> "skipped";
status_text(aborted) -> "aborted";
status_text(failed) -> "failed".

failed_check(Summary) ->
    case [Check || Check <- ?CHECKS,
                   check_status(Summary, Check) =:= failed] of
        [Check | _] -> Check;
        [] -> undefined
    end.

%% Host-side parsing of Common Test's native suite.log, run after the
%% container finished. It only ever parses the exact ct_run directory that
%% the runner recorded for this round (ci-summary.txt ct_run=...); when no
%% such identity exists the historical collection is never misattributed.
failure_blocks(OtpDir) ->
    case read_summary(OtpDir) of
        error ->
            [];
        {ok, Summary} ->
            case maps:get("ct_run", Summary, undefined) of
                undefined ->
                    [];
                RunName ->
                    RunDir = filename:join([OtpDir, "logs", RunName]),
                    case filelib:is_dir(RunDir) of
                        false ->
                            [];
                        true ->
                            SuiteLogs = filelib:fold_files(
                                          RunDir, "suite\\.log$", true,
                                          fun(File, Acc) -> [File | Acc] end, []),
                            lists:append([blocks_from_suite_log(File)
                                          || File <- lists:sort(SuiteLogs)])
                    end
            end
    end.

blocks_from_suite_log(Path) ->
    case read_file(Path) of
        error -> [];
        {ok, Content} -> parse_suite_log(string:tokens(Content, "\n"))
    end.

%% suite.log records look like:
%%   =case          suite:case
%%   =logfile       suite.case.html
%%   =result        failed: {badmatch,false}, ...
%% with the failure detail (stack frames) on the following plain lines.
%% A failure block spans its =result failed: line up to the next record.
parse_suite_log(Lines) ->
    {_Context, Current, Blocks} =
        lists:foldl(fun parse_suite_line/2,
                    {#{}, none, []}, Lines),
    lists:reverse(flush(Current, Blocks)).

parse_suite_line("=case " ++ Rest, {Context, Current, Blocks}) ->
    NewContext = update_case(Rest, Context),
    {NewContext, none, flush(Current, Blocks)};
parse_suite_line("=logfile " ++ Rest, {Context, Current, Blocks}) ->
    {Context#{logfile => trim(Rest)}, Current, Blocks};
parse_suite_line("=result" ++ Rest, {Context, Current, Blocks}) ->
    case failed_reason(Rest) of
        none ->
            {Context, none, flush(Current, Blocks)};
        Reason ->
            {Context, #{suite => maps:get(suite, Context, "?"),
                        case_name => maps:get(case_name, Context, "?"),
                        reason => Reason,
                        logfile => maps:get(logfile, Context, ""),
                        detail => []}, Blocks}
    end;
parse_suite_line(Line, {Context, Current, Blocks}) ->
    case prefix_record(Line) of
        true ->
            {Context, Current, Blocks};
        false ->
            case Current of
                none ->
                    {Context, none, Blocks};
                Block ->
                    Detail = maps:get(detail, Block) ++ [Line],
                    {Context, Block#{detail => Detail}, Blocks}
            end
    end.

prefix_record("=" ++ _Rest) -> true;
prefix_record(_) -> false.

update_case(Rest, Context) ->
    Clean = trim(Rest),
    case string:split(Clean, ":") of
        [Suite, CaseName] ->
            Context#{suite => Suite, case_name => CaseName};
        _ ->
            Context#{suite => Clean, case_name => Clean}
    end.

failed_reason(Rest) ->
    case string:trim(Rest, leading) of
        "failed:" ++ Reason0 ->
            Reason = trim(Reason0),
            case Reason of
                "" -> none;
                _ ->
                    Stripped = strip_braces(Reason),
                    string:trim(Stripped, trailing, ",")
            end;
        _ ->
            none
    end.

%% The reason keeps one leading brace (matching the historical awk parser):
%% `{{badmatch,false}, ...' displays as `{badmatch,false}'.
strip_braces("{{" ++ Rest) ->
    "{" ++ Rest;
strip_braces(Other) ->
    Other.

flush(none, Blocks) ->
    Blocks;
flush(Block, Blocks) ->
    [format_failure_block(Block) | Blocks].

format_failure_block(Block) ->
    Reason = maps:get(reason, Block) ++ location_suffix(maps:get(detail, Block)),
    io_lib:format("~s:~s -> ~s",
                  [maps:get(suite, Block), maps:get(case_name, Block), Reason]).

location_suffix(Detail) ->
    case {module_of(Detail), line_of(Detail)} of
        {nomatch, _} -> "";
        {_Module, nomatch} -> "";
        {Module, Line} -> " at " ++ Module ++ ":" ++ Line
    end.

module_of(Detail) ->
    module_of(Detail, nomatch).

module_of([], Acc) ->
    Acc;
module_of([Line | Rest], nomatch) ->
    case re:run(Line, "\\{[A-Za-z0-9_]+,[A-Za-z0-9_]+,[0-9]+,", [{capture, first, list}]) of
        {match, [Frame]} -> module_of(Rest, hd(string:split(string:trim(Frame, leading, "{"), ",")));
        nomatch -> module_of(Rest, nomatch)
    end;
module_of([_ | Rest], Acc) ->
    module_of(Rest, Acc).

line_of(Detail) ->
    line_of(Detail, nomatch).

line_of([], Acc) ->
    Acc;
line_of([Line | Rest], nomatch) ->
    case re:run(Line, "\\{line,[0-9]+\\}", [{capture, first, list}]) of
        {match, [Frame]} ->
            line_of(Rest, string:trim(Frame, both, "{line,}"));
        nomatch ->
            line_of(Rest, nomatch)
    end;
line_of([_ | Rest], Acc) ->
    line_of(Rest, Acc).

%% A summary from another run (different run_id) or from before the run_id
%% era is not accepted as this round's state.
read_summary(OtpDir, RunId) ->
    case read_summary(OtpDir) of
        {ok, Summary} ->
            case maps:get("run_id", Summary, undefined) of
                RunId -> {ok, Summary};
                _ -> error
            end;
        error ->
            error
    end.

read_summary(OtpDir) ->
    case read_file(filename:join(OtpDir, "ci-summary.txt")) of
        {ok, Content} ->
            {ok, lists:foldl(
                   fun(Line, Acc) ->
                           case string:split(Line, "=") of
                               [Key, Value] -> Acc#{Key => Value};
                               _ -> Acc
                           end
                   end, #{}, string:tokens(Content, "\n"))};
        error -> error
    end.

read_file(Path) ->
    case file:read_file(Path) of
        {ok, Data} -> {ok, binary_to_list(Data)};
        {error, _Reason} -> error
    end.

trim(String) ->
    string:trim(String).

overall(ok) -> "passed";
overall({error, _Reason}) -> "failed".

overall_result(ok, _FailedCount, _Total) -> "PASSED";
overall_result({error, _Reason}, FailedCount, Total) ->
    io_lib:format("FAILED (~p of ~p targets failed)", [FailedCount, Total]).

timestamp() ->
    {{Year, Month, Day}, {Hour, Minute, Second}} = calendar:universal_time(),
    io_lib:format("~4..0b-~2..0b-~2..0bT~2..0b:~2..0b:~2..0bZ",
                  [Year, Month, Day, Hour, Minute, Second]).
