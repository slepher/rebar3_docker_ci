-module(rebar3_docker_ci_report).

-export([content/4]).

-define(CHECKS, [compile, xref, dialyzer, common_test, eunit]).
-define(STATIC_CHECKS, [compile, xref, dialyzer]).
-define(MAX_ERROR_LINES, 8).

content(ProjectName, Targets, Result, ResultsDir) ->
    Statuses = [{Target, target_status(Target, Result)} || Target <- Targets],
    FailedCount = length([1 || {_Target, Status} <- Statuses, Status =/= passed]),
    Header = [io_lib:format("project=~s~n", [ProjectName]),
              io_lib:format("ran_at=~s~n", [timestamp()]),
              io_lib:format("overall=~s~n", [overall(Result)]),
              io_lib:format("targets=~p~n", [length(Targets)]),
              "---\n"],
    TargetLines = lists:append(
                    [target_lines(Target, Status, ResultsDir)
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

target_lines(Target, passed, _ResultsDir) ->
    [io_lib:format(">>> Erlang/OTP ~s [~s]: PASSED~n",
                   [maps:get(otp, Target), maps:get(image, Target)])];
target_lines(Target, {failed, Failure}, ResultsDir) ->
    OtpDir = filename:join(ResultsDir, maps:get(otp, Target)),
    Summary = read_summary(OtpDir),
    FailedCheck = failed_check(Summary),
    Header = io_lib:format(">>> Erlang/OTP ~s [~s]: ~s~n",
                           [maps:get(otp, Target), maps:get(image, Target),
                            failed_header(FailedCheck, Failure)]),
    [Header, check_lines(Summary),
     failed_detail_lines(OtpDir, FailedCheck)] ++ link_lines(OtpDir).

failed_header(undefined, {command_failed, Status}) ->
    "FAILED (exit code " ++ integer_to_list(Status) ++ ")";
failed_header(undefined, _Failure) ->
    "FAILED (unknown)";
failed_header(Check, _Failure) ->
    "FAILED (" ++ atom_to_list(Check) ++ ")".

check_lines(Summary) ->
    [io_lib:format("    ~-13s ~s~n", [atom_to_list(Check) ++ ":", status_text(Status)])
     || {Check, Status} <- check_statuses(Summary)].

failed_detail_lines(OtpDir, FailedCheck) ->
    ErrorLines = case lists:member(FailedCheck, ?STATIC_CHECKS) of
                     true -> error_block_lines(OtpDir, FailedCheck);
                     false -> []
                 end,
    CaseLines = [io_lib:format("    Failed cases: ~s~n", [Block])
                 || Block <- failure_blocks(OtpDir)],
    ErrorLines ++ CaseLines.

link_lines(OtpDir) ->
links([{"Failures", filename:join(OtpDir, "failures.txt")},
       {"Compile log", filename:join(OtpDir, "compile.log")},
       {"Xref log", filename:join(OtpDir, "xref.log")},
       {"Dialyzer log", filename:join(OtpDir, "dialyzer.log")},
       {"EUnit log", filename:join(OtpDir, "eunit.log")},
       {"CT log", filename:join(OtpDir, "common_test.log")},
       {"CT logs", filename:join([OtpDir, "logs", "index.html"])},
       {"Cover", filename:join([OtpDir, "cover", "index.html"])}], []).

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
        _ -> failed
    end.

status_text(ok) -> "ok";
status_text(skipped) -> "skipped";
status_text(failed) -> "failed".

failed_check(Summary) ->
    case [Check || Check <- ?CHECKS,
                   check_status(Summary, Check) =:= failed] of
        [Check | _] -> Check;
        [] -> undefined
    end.

failure_blocks(OtpDir) ->
    case read_file(filename:join(OtpDir, "failures.txt")) of
        {ok, Content} ->
            Blocks = split_blocks(string:tokens(Content, "\n"), [], []),
            [format_block(Block) || Block <- Blocks, Block =/= []];
        error -> []
    end.

split_blocks([], Current, Acc) ->
    lists:reverse([lists:reverse(Current) | Acc]);
split_blocks(["---" | Rest], Current, Acc) ->
    split_blocks(Rest, [], [lists:reverse(Current) | Acc]);
split_blocks([Line | Rest], Current, Acc) ->
    split_blocks(Rest, [Line | Current], Acc).

format_block(Block) ->
    Map = lists:foldl(
            fun(Line, Acc) ->
                    case string:split(Line, "=") of
                        [Key, Value] when Key =:= "suite"; Key =:= "case";
                                          Key =:= "reason"; Key =:= "logfile" ->
                            Acc#{Key => Value};
                        _ -> Acc
                    end
            end, #{}, Block),
    io_lib:format("~s:~s -> ~s",
                  [maps:get("suite", Map, "?"),
                   maps:get("case", Map, "?"),
                   maps:get("reason", Map, "")]).

error_block_lines(OtpDir, Check) ->
    Path = filename:join(OtpDir, atom_to_list(Check) ++ ".log"),
    case read_file(Path) of
        error -> [];
        {ok, Content} ->
            Lines = string:tokens(Content, "\n"),
            case first_error_index(Lines, 1) of
                undefined ->
                    [io_lib:format("    ~s~n", [Line])
                     || Line <- lists:sublist(nonempty(Lines), ?MAX_ERROR_LINES)];
                Index ->
                    [io_lib:format("    ~s~n", [Line])
                     || Line <- lists:sublist(Lines, Index, ?MAX_ERROR_LINES)]
            end
    end.

first_error_index([], _Index) ->
    undefined;
first_error_index([Line | Rest], Index) ->
    case string:find(string:lowercase(Line), "error") of
        nomatch -> first_error_index(Rest, Index + 1);
        _ -> Index
    end.

nonempty(Lines) ->
    [Line || Line <- Lines, string:trim(Line) =/= []].

read_summary(OtpDir) ->
    case read_file(filename:join(OtpDir, "ci-summary.txt")) of
        {ok, Content} ->
            lists:foldl(
              fun(Line, Acc) ->
                      case string:split(Line, "=") of
                          [Key, Value] -> Acc#{Key => Value};
                          _ -> Acc
                      end
              end, #{}, string:tokens(Content, "\n"));
        error -> #{}
    end.

read_file(Path) ->
    case file:read_file(Path) of
        {ok, Data} -> {ok, binary_to_list(Data)};
        {error, _Reason} -> error
    end.

overall(ok) -> "passed";
overall({error, _Reason}) -> "failed".

overall_result(ok, _FailedCount, _Total) -> "PASSED";
overall_result({error, _Reason}, FailedCount, Total) ->
    io_lib:format("FAILED (~p of ~p targets failed)", [FailedCount, Total]).

timestamp() ->
    {{Year, Month, Day}, {Hour, Minute, Second}} = calendar:universal_time(),
    io_lib:format("~4..0b-~2..0b-~2..0bT~2..0b:~2..0b:~2..0bZ",
                  [Year, Month, Day, Hour, Minute, Second]).
