-module(rebar3_docker_ci_events_tests).

-include_lib("eunit/include/eunit.hrl").

parse_plain_output_test() ->
    ?assertEqual(none, rebar3_docker_ci_events:parse_line(<<"make: Error 2">>)),
    ?assertEqual(none, rebar3_docker_ci_events:parse_line(<<>>)),
    ?assertEqual(none, rebar3_docker_ci_events:parse_line("not binary")).

parse_reserved_prefix_test() ->
    ?assertEqual(unknown_event,
                 rebar3_docker_ci_events:parse_line(<<"@@R3DCI/2\tstage_started\tcompile">>)),
    ?assertEqual(unknown_event,
                 rebar3_docker_ci_events:parse_line(<<"@@R3DCI/1\tbogus">>)),
    ?assertEqual(unknown_event,
                 rebar3_docker_ci_events:parse_line(<<"@@R3DCI/1\tstage_started\tnope">>)),
    ?assertEqual(unknown_event,
                 rebar3_docker_ci_events:parse_line(<<"@@R3DCI/1\tstage_finished\txref\tx">>)).

parse_with_nonce_test() ->
    Line = <<"@@R3DCI/1/abc123\tstage_started\tcompile">>,
    ?assertEqual({event, {stage_started, compile}},
                 rebar3_docker_ci_events:parse_line(Line, "abc123")),
    ?assertEqual(unknown_event,
                 rebar3_docker_ci_events:parse_line(Line, "other")),
    ?assertEqual(none,
                 rebar3_docker_ci_events:parse_line(<<"plain output">>, "abc123")),
    ?assertEqual(unknown_event,
                 rebar3_docker_ci_events:parse_line(<<"@@R3DCI/1\tstage_started\tcompile">>,
                                                    "abc123")).

parse_stage_events_test() ->
    ?assertEqual({event, {stage_started, compile}},
                 rebar3_docker_ci_events:parse_line(<<"@@R3DCI/1\tstage_started\tcompile">>)),
    ?assertEqual({event, {stage_finished, xref, 0}},
                 rebar3_docker_ci_events:parse_line(<<"@@R3DCI/1\tstage_finished\txref\t0">>)),
    ?assertEqual({event, {stage_finished, dialyzer, 3}},
                 rebar3_docker_ci_events:parse_line(<<"@@R3DCI/1\tstage_finished\tdialyzer\t3">>)),
    ?assertEqual({event, {stage_skipped, eunit}},
                 rebar3_docker_ci_events:parse_line(<<"@@R3DCI/1\tstage_skipped\teunit">>)).

parse_ct_run_test() ->
    Name = "ct_run.nonode@nohost.2026-08-09_01.32.43",
    ?assertEqual({event, {ct_run, Name}},
                 rebar3_docker_ci_events:parse_line(
                   iolist_to_binary([<<"@@R3DCI/1\tct_run\t">>, Name]))),
    ?assertEqual(unknown_event,
                 rebar3_docker_ci_events:parse_line(<<"@@R3DCI/1\tct_run\t../escape">>)),
    ?assertEqual(unknown_event,
                 rebar3_docker_ci_events:parse_line(<<"@@R3DCI/1\tct_run\tnotactrun">>)),
    ?assertEqual(unknown_event,
                 rebar3_docker_ci_events:parse_line(<<"@@R3DCI/1\tct_run\tct_run.x\textra">>)).

happy_path_test() ->
    S0 = rebar3_docker_ci_events:new(),
    S1 = ok_state(rebar3_docker_ci_events:apply_event({stage_started, compile}, S0)),
    S2 = ok_state(rebar3_docker_ci_events:apply_event({stage_finished, compile, 0}, S1)),
    S3 = ok_state(rebar3_docker_ci_events:apply_event({stage_started, xref}, S2)),
    S4 = ok_state(rebar3_docker_ci_events:apply_event({stage_finished, xref, 0}, S3)),
    S5 = ok_state(rebar3_docker_ci_events:apply_event({stage_started, dialyzer}, S4)),
    S6 = ok_state(rebar3_docker_ci_events:apply_event({stage_finished, dialyzer, 0}, S5)),
    S7 = ok_state(rebar3_docker_ci_events:apply_event({stage_started, common_test}, S6)),
    S8 = ok_state(rebar3_docker_ci_events:apply_event({ct_run, "ct_run.x"}, S7)),
    S9 = ok_state(rebar3_docker_ci_events:apply_event({stage_finished, common_test, 0}, S8)),
    S10 = ok_state(rebar3_docker_ci_events:apply_event({stage_started, eunit}, S9)),
    S11 = ok_state(rebar3_docker_ci_events:apply_event({stage_finished, eunit, 0}, S10)),
    ?assertEqual({ok, S11}, rebar3_docker_ci_events:finalize(S11, ok)),
    ?assertEqual("ct_run.x", rebar3_docker_ci_events:ct_run(S11)),
    ?assertEqual([{compile, passed}, {xref, passed}, {dialyzer, passed},
                  {common_test, passed}, {eunit, passed}],
                 rebar3_docker_ci_events:statuses(S11)).

out_of_order_start_test() ->
    S = rebar3_docker_ci_events:new(),
    ?assertMatch({error, {out_of_order_start, xref, compile}},
                 rebar3_docker_ci_events:apply_event({stage_started, xref}, S)),
    ?assertMatch({error, {out_of_order_skip, eunit, compile}},
                 rebar3_docker_ci_events:apply_event({stage_skipped, eunit}, S)).

failure_blocks_later_stages_test() ->
    S0 = rebar3_docker_ci_events:new(),
    S1 = ok_state(rebar3_docker_ci_events:apply_event({stage_started, compile}, S0)),
    S2 = ok_state(rebar3_docker_ci_events:apply_event({stage_finished, compile, 9}, S1)),
    ?assertMatch({error, {started_after_failure, xref, compile}},
                 rebar3_docker_ci_events:apply_event({stage_started, xref}, S2)),
    ?assertMatch({error, {out_of_order_start, compile, xref}},
                 rebar3_docker_ci_events:apply_event({stage_started, compile}, S2)),
    ?assertMatch({error, {invalid_finish, compile, failed}},
                 rebar3_docker_ci_events:apply_event({stage_finished, compile, 0}, S2)).

skip_stage_test() ->
    S0 = rebar3_docker_ci_events:new(),
    S1 = ok_state(rebar3_docker_ci_events:apply_event({stage_skipped, compile}, S0)),
    S2 = ok_state(rebar3_docker_ci_events:apply_event({stage_started, xref}, S1)),
    S3 = ok_state(rebar3_docker_ci_events:apply_event({stage_finished, xref, 0}, S2)),
    S4 = ok_state(rebar3_docker_ci_events:apply_event({stage_skipped, dialyzer}, S3)),
    S5 = ok_state(rebar3_docker_ci_events:apply_event({stage_skipped, common_test}, S4)),
    S6 = ok_state(rebar3_docker_ci_events:apply_event({stage_skipped, eunit}, S5)),
    ?assertEqual({ok, S6}, rebar3_docker_ci_events:finalize(S6, ok)).

ct_run_event_rules_test() ->
    S0 = rebar3_docker_ci_events:new(),
    ?assertMatch({error, {invalid_ct_run, pending, none}},
                 rebar3_docker_ci_events:apply_event({ct_run, "ct_run.x"}, S0)),
    S1 = ok_state(rebar3_docker_ci_events:apply_event({stage_started, compile}, S0)),
    S2 = ok_state(rebar3_docker_ci_events:apply_event({stage_finished, compile, 0}, S1)),
    S3 = ok_state(rebar3_docker_ci_events:apply_event({stage_started, xref}, S2)),
    S4 = ok_state(rebar3_docker_ci_events:apply_event({stage_finished, xref, 0}, S3)),
    S5 = ok_state(rebar3_docker_ci_events:apply_event({stage_started, dialyzer}, S4)),
    S6 = ok_state(rebar3_docker_ci_events:apply_event({stage_finished, dialyzer, 0}, S5)),
    S7 = ok_state(rebar3_docker_ci_events:apply_event({stage_started, common_test}, S6)),
    S8 = ok_state(rebar3_docker_ci_events:apply_event({ct_run, "ct_run.a"}, S7)),
    ?assertMatch({error, {invalid_ct_run, running, "ct_run.a"}},
                 rebar3_docker_ci_events:apply_event({ct_run, "ct_run.b"}, S8)),
    ?assertMatch({error, {invalid_ct_run_name, "../bad"}},
                 rebar3_docker_ci_events:apply_event({ct_run, "../bad"}, S7)).

finalize_failure_cascade_test() ->
    S0 = rebar3_docker_ci_events:new(),
    S1 = ok_state(rebar3_docker_ci_events:apply_event({stage_started, compile}, S0)),
    {ok, S2} = rebar3_docker_ci_events:finalize(S1, {error, container_died}),
    ?assertEqual(aborted, rebar3_docker_ci_events:status(S2, compile)),
    ?assertEqual(skipped, rebar3_docker_ci_events:status(S2, eunit)).

finalize_incomplete_test() ->
    S0 = rebar3_docker_ci_events:new(),
    S1 = ok_state(rebar3_docker_ci_events:apply_event({stage_started, compile}, S0)),
    S2 = ok_state(rebar3_docker_ci_events:apply_event({stage_finished, compile, 0}, S1)),
    ?assertMatch({error, {incomplete, _}},
                 rebar3_docker_ci_events:finalize(S2, ok)).

summary_value_test() ->
    ?assertEqual("0", rebar3_docker_ci_events:summary_value(passed)),
    ?assertEqual("1", rebar3_docker_ci_events:summary_value(failed)),
    ?assertEqual("aborted", rebar3_docker_ci_events:summary_value(aborted)),
    ?assertEqual("skipped", rebar3_docker_ci_events:summary_value(skipped)),
    ?assertEqual("skipped", rebar3_docker_ci_events:summary_value(pending)).

ok_state({ok, State}) -> State.
