-module(rebar3_docker_ci_report_SUITE).

%% Host report generation for the 0.4.0 result layout: run_id-verified
%% summaries, exact ct_run failure blocks, and CI log/Summary/CT logs/Cover
%% links. The report never falls back to historical runs.

-export([all/0, init_per_testcase/2, end_per_testcase/2]).
-export([all_passed/1, ct_failure_reported/1, compile_failure_inlines_error/1,
         no_summary_falls_back_to_exit_code/1, stale_run_id_ignored/1]).

-include_lib("common_test/include/ct.hrl").

-define(RUN_ID, "run-2026-0809-01").
-define(CT_RUN, "ct_run.nonode@nohost.2026-08-09_01.32.43").

all() ->
    [all_passed, ct_failure_reported, compile_failure_inlines_error,
     no_summary_falls_back_to_exit_code, stale_run_id_ignored].

init_per_testcase(Name, Config) ->
    Base = filename:join(?config(priv_dir, Config), atom_to_list(Name)),
    _ = rebar3_docker_ci_test_utils:del_dir_r(Base),
    ok = filelib:ensure_dir(filename:join(Base, "placeholder")),
    Results = filename:join(Base, "results"),
    OtpDir = filename:join(Results, "28"),
    ok = filelib:ensure_dir(filename:join(OtpDir, "placeholder")),
    ok = write_file(filename:join(OtpDir, "ci.log"), "===> output\n"),
    ok = write_file(filename:join(OtpDir, "ci-summary.txt"),
                    "project=sample\nerlang_otp=28\nrun_id=" ?RUN_ID "\n"
                    "compile=0\nxref=0\ndialyzer=skipped\ncommon_test=1\n"
                    "eunit=skipped\nct_run=" ?CT_RUN "\n"),
    RunDir = filename:join([OtpDir, "logs", ?CT_RUN,
                            "lib.sample.astranaut_design_SUITE.logs",
                            "run.2026-08-09_01.32.43"]),
    ok = write_file(filename:join(RunDir, "suite.log"),
                    "=case          astranaut_design_SUITE:lib_form_source_contracts\n"
                    "=logfile       astranaut_design_suite.lib_form_source_contracts.html\n"
                    "=result        failed: {{badmatch,false},\n"
                    "                        [{astranaut_design_SUITE,"
                    "lib_form_source_contracts,1,\n"
                    "                              [{file,\n"
                    "                                   "
                    "\"/x/test/astranaut_design_SUITE.erl\"},\n"
                    "                               {line,42}]},\n"
                    "                         {test_server,ts_tc,3,\n"
                    "                              [{file,\"test_server.erl\"},"
                    "{line,1799}]}]}\n"
                    "=== TEST COMPLETE, 0 ok, 1 failed of 1 test cases\n"),
    ok = write_file(filename:join([OtpDir, "logs", "index.html"]), "logs"),
    ok = write_file(filename:join([OtpDir, "cover", "index.html"]), "cover"),
    [{results, Results}, {otp_dir, OtpDir} | Config].

end_per_testcase(_Name, Config) ->
    rebar3_docker_ci_test_utils:del_dir_r(?config(priv_dir, Config)).

all_passed(Config) ->
    Targets = [#{image => "erlang:27", otp => "27"}],
    Text = report_text("sample", Targets, ok, Config),
    true = contains(Text, "project=sample\n"),
    true = contains(Text, "overall=passed\n"),
    true = contains(Text, ">>> Erlang/OTP 27 [erlang:27]: PASSED\n"),
    true = contains(Text, "overall_result=PASSED\n"),
    ok.

ct_failure_reported(Config) ->
    Targets = [#{image => "erlang:27", otp => "27"},
               #{image => "erlang:28", otp => "28"}],
    Result = {error, {ci_failed, [{lists:nth(2, Targets), {command_failed, 1}}]}},
    Text = report_text("sample", Targets, Result, Config),
    true = contains(Text, ">>> Erlang/OTP 27 [erlang:27]: PASSED\n"),
    true = contains(Text, ">>> Erlang/OTP 28 [erlang:28]: FAILED (common_test)\n"),
    true = contains(Text, "    compile:      ok\n"),
    true = contains(Text, "    common_test:  failed\n"),
    true = contains(Text, "    eunit:        skipped\n"),
    true = contains(Text,
                    "    Failed cases: astranaut_design_SUITE:"
                    "lib_form_source_contracts -> {badmatch,false} at "
                    "astranaut_design_SUITE:42\n"),
    Results = ?config(results, Config),
    true = contains(Text, filename:join(Results, "28/ci.log")),
    true = contains(Text, filename:join(Results, "28/ci-summary.txt")),
    true = contains(Text, filename:join([Results, "28", "logs", "index.html"])),
    true = contains(Text, filename:join([Results, "28", "cover", "index.html"])),
    true = contains(Text, "overall_result=FAILED (1 of 2 targets failed)\n"),
    ok.

compile_failure_inlines_error(Config) ->
    OtpDir = ?config(otp_dir, Config),
    ok = write_file(filename:join(OtpDir, "ci-summary.txt"),
                    "project=sample\nerlang_otp=28\nrun_id=" ?RUN_ID "\n"
                    "compile=9\nxref=skipped\ndialyzer=skipped\n"
                    "common_test=skipped\neunit=skipped\n"),
    ok = write_file(filename:join(OtpDir, "ci.log"),
                    "===> Compiling sample\n"
                    "src/sample.erl:12:5: Error: undefined function foo/0\n"
                    "  second error line\n"
                    "===> Compiling failed\n"),
    Targets = [#{image => "erlang:28", otp => "28"}],
    Result = {error, {ci_failed, [{lists:nth(1, Targets), {command_failed, 9}}]}},
    Text = report_text("sample", Targets, Result, Config),
    true = contains(Text, "FAILED (compile)\n"),
    true = contains(Text, "    compile:      failed\n"),
    true = contains(Text, "    xref:         skipped\n"),
    false = contains(Text, "===> Compiling sample"),
    ok.

no_summary_falls_back_to_exit_code(Config) ->
    OtpDir = ?config(otp_dir, Config),
    ok = file:delete(filename:join(OtpDir, "ci-summary.txt")),
    Targets = [#{image => "erlang:28", otp => "28"}],
    Result = {error, {ci_failed, [{lists:nth(1, Targets), {command_failed, 7}}]}},
    Text = report_text("sample", Targets, Result, Config),
    true = contains(Text, "FAILED (exit code 7)\n"),
    ok.

stale_run_id_ignored(Config) ->
    OtpDir = ?config(otp_dir, Config),
    ok = write_file(filename:join(OtpDir, "ci-summary.txt"),
                    "project=sample\nerlang_otp=28\nrun_id=run-old\n"
                    "compile=0\nxref=0\ndialyzer=skipped\ncommon_test=1\n"
                    "eunit=skipped\nct_run=" ?CT_RUN "\n"),
    Targets = [#{image => "erlang:28", otp => "28"}],
    Result = {error, {ci_failed, [{lists:nth(1, Targets), {command_failed, 1}}]}},
    Text = report_text("sample", Targets, Result, Config),
    true = contains(Text, "FAILED (exit code 1)\n"),
    false = contains(Text, "Failed cases:"),
    false = contains(Text, "CT logs"),
    ok.

report_text(ProjectName, Targets, Result, Config) ->
    Content = rebar3_docker_ci_report:content(
                ProjectName, Targets, Result, ?config(results, Config),
                ?RUN_ID),
    binary_to_list(iolist_to_binary(Content)).

write_file(Path, Data) ->
    ok = filelib:ensure_dir(Path),
    file:write_file(Path, Data).

contains(Haystack, Needle) ->
    string:find(Haystack, Needle) =/= nomatch.
