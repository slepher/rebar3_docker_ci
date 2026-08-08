-module(rebar3_docker_ci_events).

%% Observation event protocol between the container runner and the host
%% OTP worker. Events are one-way notifications carried on the container
%% stdout; the host never sends control commands back into the container.
%%
%% The host assigns each target a nonce and only accepts events carrying
%% that nonce (`@@R3DCI/1/<nonce>`). This separates concurrent targets and
%% prevents accidental prefix collisions; it is not a security boundary,
%% because the tested project inherits the container environment.

-export([stages/0, parse_line/1, parse_line/2, new/0, new/1, apply_event/2,
         finalize/2, status/2, statuses/1, summary_value/1, ct_run/1]).

-define(PROTOCOL_PREFIX, <<"@@R3DCI/1">>).
-define(ALL_STAGES, [compile, xref, dialyzer, common_test, eunit]).

stages() ->
    ?ALL_STAGES.

%% Parse one output line against the nonce-less prefix. Returns:
%%   {event, Event}  - a valid v1 observation event
%%   unknown_event   - reserved prefix but malformed or unknown version
%%   none            - ordinary project output
parse_line(Line) when is_binary(Line) ->
    parse_line(Line, undefined);
parse_line(_Line) ->
    none.

%% Same, but only lines carrying the expected nonce are events. Lines with
%% the reserved prefix and any other nonce are reported as unknown_event.
parse_line(Line, Nonce) when is_binary(Line) ->
    case binary:split(Line, <<"\t">>, [global]) of
        [Prefix | Fields] ->
            case valid_prefix(Prefix, Nonce) of
                true -> parse_fields(Fields);
                false ->
                    case reserved_prefix(Prefix) of
                        true -> unknown_event;
                        false -> none
                    end
            end;
        _ ->
            none
    end;
parse_line(_Line, _Nonce) ->
    none.

parse_fields([<<"stage_started">>, StageBin]) ->
    case stage(StageBin) of
        {ok, Stage} -> {event, {stage_started, Stage}};
        error -> unknown_event
    end;
parse_fields([<<"stage_finished">>, StageBin, CodeBin]) ->
    case {stage(StageBin), code(CodeBin)} of
        {{ok, Stage}, {ok, Code}} -> {event, {stage_finished, Stage, Code}};
        _ -> unknown_event
    end;
parse_fields([<<"stage_skipped">>, StageBin]) ->
    case stage(StageBin) of
        {ok, Stage} -> {event, {stage_skipped, Stage}};
        error -> unknown_event
    end;
parse_fields([<<"ct_run">>, NameBin]) ->
    Name = binary_to_list(NameBin),
    case valid_ct_run_name(Name) of
        true -> {event, {ct_run, Name}};
        false -> unknown_event
    end;
parse_fields(_) ->
    unknown_event.

valid_prefix(Prefix, undefined) ->
    Prefix =:= ?PROTOCOL_PREFIX;
valid_prefix(Prefix, Nonce) ->
    Prefix =:= <<?PROTOCOL_PREFIX/binary, "/", (list_to_binary(Nonce))/binary>>.

reserved_prefix(<<>>) ->
    false;
reserved_prefix(<<"@@R3DCI", _/binary>>) ->
    true;
reserved_prefix(_) ->
    false.

new() ->
    new(undefined).

%% A fresh state with the optional target nonce. The next stage must be
%% the first stage of the fixed pipeline order; events may only advance
%% the pipeline strictly in that order.
new(Nonce) ->
    maps:merge(maps:from_list([{Stage, pending} || Stage <- ?ALL_STAGES]),
               #{nonce => Nonce, next => hd(?ALL_STAGES), ct_run => none}).

%% Valid transitions:
%%   pending -> running -> passed | failed
%%   pending -> skipped
%%   running -> aborted       (only during finalize)
%% Stage events must follow the fixed order compile -> xref -> dialyzer ->
%% common_test -> eunit: a stage may only start or be skipped when it is
%% the next stage in that order, and a failed stage blocks later starts.
apply_event({stage_started, Stage}, State) ->
    case {Stage =:= maps:get(next, State), maps:get(Stage, State),
          failed_stage(State)} of
        {false, _, _} ->
            {error, {out_of_order_start, Stage, maps:get(next, State)}};
        {true, _, Failed} when Failed =/= undefined ->
            {error, {started_after_failure, Stage, Failed}};
        {true, pending, undefined} ->
            {ok, State#{Stage => running}};
        {true, Status, _} ->
            {error, {invalid_start, Stage, Status}}
    end;
apply_event({stage_finished, Stage, Code}, State) ->
    case maps:get(Stage, State) of
        running when Code =:= 0 -> {ok, finish(State, Stage, passed)};
        running -> {ok, finish(State, Stage, failed)};
        Status -> {error, {invalid_finish, Stage, Status}}
    end;
apply_event({stage_skipped, Stage}, State) ->
    case {Stage =:= maps:get(next, State), maps:get(Stage, State)} of
        {false, _} ->
            {error, {out_of_order_skip, Stage, maps:get(next, State)}};
        {true, pending} ->
            {ok, finish(State, Stage, skipped)};
        {true, Status} ->
            {error, {invalid_skip, Stage, Status}}
    end;
apply_event({ct_run, Name}, State) ->
    case {maps:get(common_test, State), maps:get(ct_run, State),
          valid_ct_run_name(Name)} of
        {running, none, true} ->
            {ok, State#{ct_run => Name}};
        {_Status, _Run, false} ->
            {error, {invalid_ct_run_name, Name}};
        {Status, Run, true} ->
            {error, {invalid_ct_run, Status, Run}}
    end.

%% Validate the protocol against the container exit status.
%% On success every stage must be passed or skipped; a missing event is a
%% protocol error rather than a silent success.
finalize(State, ok) ->
    case [Stage || Stage <- ?ALL_STAGES,
                   not lists:member(maps:get(Stage, State), [passed, skipped])] of
        [] -> {ok, State};
        Missing -> {error, {incomplete, Missing}}
    end;
%% On failure a still-running stage is aborted and never-started stages are
%% cascade-skipped.
finalize(State, {error, _Reason}) ->
    {ok, lists:foldl(
           fun(Stage, Acc) ->
                   Acc#{Stage => finalize_status(maps:get(Stage, State))}
           end, State, ?ALL_STAGES)}.

finalize_status(pending) -> skipped;
finalize_status(running) -> aborted;
finalize_status(Status) -> Status.

finish(State, Stage, Status) ->
    State1 = State#{Stage => Status},
    State1#{next => next_pending(State1)}.

next_pending(State) ->
    case [Stage || Stage <- ?ALL_STAGES, maps:get(Stage, State) =:= pending] of
        [Next | _] -> Next;
        [] -> done
    end.

status(State, Stage) ->
    maps:get(Stage, State).

statuses(State) ->
    [{Stage, maps:get(Stage, State)} || Stage <- ?ALL_STAGES].

ct_run(State) ->
    maps:get(ct_run, State).

summary_value(passed) -> "0";
summary_value(failed) -> "1";
summary_value(aborted) -> "aborted";
summary_value(skipped) -> "skipped";
summary_value(pending) -> "skipped".

failed_stage(State) ->
    case [Stage || Stage <- ?ALL_STAGES, maps:get(Stage, State) =:= failed] of
        [Failed | _] -> Failed;
        [] -> undefined
    end.

stage(<<"compile">>) -> {ok, compile};
stage(<<"xref">>) -> {ok, xref};
stage(<<"dialyzer">>) -> {ok, dialyzer};
stage(<<"common_test">>) -> {ok, common_test};
stage(<<"eunit">>) -> {ok, eunit};
stage(_) -> error.

code(CodeBin) ->
    try {ok, binary_to_integer(CodeBin)}
    catch
        error:badarg -> error
    end.

valid_ct_run_name("ct_run." ++ [_ | _] = Name) ->
    filename:basename(Name) =:= Name andalso
        not lists:member($\\, Name) andalso
        not lists:member(0, Name);
valid_ct_run_name(_) ->
    false.
