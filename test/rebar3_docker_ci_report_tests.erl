-module(rebar3_docker_ci_report_tests).

-include_lib("eunit/include/eunit.hrl").

content_all_passed_test() ->
    Targets = [#{image => "erlang:28", otp => "28"}],
    Content = iolist_to_binary(
                rebar3_docker_ci_report:content("sample", Targets, ok,
                                                "/x/results", "run-1")),
    ?assertMatch({_, _}, binary:match(Content, <<"project=sample\n">>)),
    ?assertMatch({_, _}, binary:match(Content, <<"overall_result=PASSED\n">>)),
    ?assertMatch({_, _},
                 binary:match(Content, <<"Erlang/OTP 28 [erlang:28]: PASSED">>)).

content_failed_counts_targets_test() ->
    Targets = [#{image => "erlang:27", otp => "27"},
               #{image => "erlang:28", otp => "28"}],
    Failure = {error, {ci_failed, [{lists:nth(2, Targets), {command_failed, 9}}]}},
    Content = iolist_to_binary(
                rebar3_docker_ci_report:content("sample", Targets, Failure,
                                                "/x/results", "run-1")),
    ?assertMatch({_, _},
                 binary:match(Content, <<"overall_result=FAILED (1 of 2 targets failed)">>)),
    ?assertMatch({_, _},
                 binary:match(Content, <<"FAILED (exit code 9)">>)).

parse_suite_log_failure_block_test() ->
    Lines = ["=case      sample_SUITE:badmatch_case",
             "=logfile   sample_SUITE.badmatch_case.html",
             "=result    failed: {{badmatch,false},{sample_SUITE,badmatch_case,1,"
             "[{file,\"test/sample_SUITE.erl\"},{line,42}]}}",
             "{sample_SUITE,badmatch_case,1,"
             "[{file,\"test/sample_SUITE.erl\"},{line,42}]}",
             "=case      sample_SUITE:ok_case",
             "=result    ok, 0.01s"],
    [Block] = rebar3_docker_ci_report:parse_suite_log(Lines),
    Flat = lists:flatten(Block),
    ?assertNotEqual(nomatch,
                    string:find(Flat, "sample_SUITE:badmatch_case -> {badmatch,false}")),
    ?assertNotEqual(nomatch, string:find(Flat, "at sample_SUITE:42")),
    ?assertEqual(nomatch, string:find(Flat, "ok_case")).

parse_suite_log_no_failure_test() ->
    Lines = ["=case      sample_SUITE:ok_case",
             "=result    ok, 0.01s"],
    ?assertEqual([], rebar3_docker_ci_report:parse_suite_log(Lines)).

failure_blocks_without_summary_test() ->
    ?assertEqual([], rebar3_docker_ci_report:failure_blocks("/nonexistent/dir")).

failure_blocks_without_ct_run_test() ->
    Base = temp_dir(),
    try
        OtpDir = filename:join(Base, "28"),
        ok = filelib:ensure_dir(filename:join(OtpDir, "placeholder")),
        ok = file:write_file(filename:join(OtpDir, "ci-summary.txt"),
                             <<"run_id=run-1\ncompile=1\n">>),
        ?assertEqual([], rebar3_docker_ci_report:failure_blocks(OtpDir))
    after
        rebar3_docker_ci_test_utils:del_dir_r(Base)
    end.

temp_dir() ->
    Dir = "/tmp/rebar3_docker_ci_report_tests_" ++
        integer_to_list(erlang:unique_integer([positive])),
    ok = file:make_dir(Dir),
    Dir.
