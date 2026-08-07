-module(rebar3_docker_ci_report_SUITE).

-export([all/0, init_per_testcase/2, end_per_testcase/2]).
-export([all_passed/1, ct_failure_reported/1, compile_failure_inlines_error/1,
         no_summary_falls_back_to_exit_code/1, eunit_failure_reported/1]).

-include_lib("common_test/include/ct.hrl").

all() ->
    [all_passed, ct_failure_reported, compile_failure_inlines_error,
     no_summary_falls_back_to_exit_code, eunit_failure_reported].

init_per_testcase(Name, Config) ->
    Base = filename:join(?config(priv_dir, Config), atom_to_list(Name)),
    _ = file:del_dir_r(Base),
    ok = filelib:ensure_dir(filename:join(Base, "placeholder")),
    Results = filename:join(Base, "results"),
    OtpDir = filename:join(Results, "28"),
    ok = filelib:ensure_dir(filename:join(OtpDir, "placeholder")),
    ok = write_file(filename:join(OtpDir, "ci-summary.txt"),
                    "project=sample\nerlang_otp=28\n"
                    "compile=0\nxref=0\ndialyzer=skipped\ncommon_test=1\nresult=1\n"),
    ok = write_file(filename:join(OtpDir, "failures.txt"),
                    "failure_count=1\n"
                    "suite=my_SUITE\n"
                    "case=my_case\n"
                    "reason={badmatch,false} at my_SUITE:38\n"
                    "logfile=my_suite.my_case.html\n"
                    "---\n"),
    ok = write_file(filename:join(OtpDir, "compile.log"), "===> Compiling sample\n"),
    ok = write_file(filename:join(OtpDir, "common_test.log"), "===> ct output\n"),
    ok = write_file(filename:join([OtpDir, "logs", "index.html"]), "logs"),
    ok = write_file(filename:join([OtpDir, "cover", "index.html"]), "cover"),
    [{results, Results}, {otp_dir, OtpDir} | Config].

end_per_testcase(_Name, Config) ->
    file:del_dir_r(?config(priv_dir, Config)).

all_passed(Config) ->
    Targets = [#{image => "erlang:27", otp => "27"}],
    Text = report_text("sample", Targets, ok, Config),
    true = contains(Text, "overall=passed\n"),
    true = contains(Text, ">>> Erlang/OTP 27 [erlang:27]: PASSED\n"),
    true = contains(Text, "overall_result=PASSED\n"),
    ok.

ct_failure_reported(Config) ->
    Targets = [#{image => "erlang:27", otp => "27"},
               #{image => "erlang:28", otp => "28"}],
    Result = {error, {ci_failed, [{lists:nth(2, Targets), {command_failed, 1}}]}},
    Text = report_text("sample", Targets, Result, Config),
    true = contains(Text, "project=sample\n"),
    true = contains(Text, "overall=failed\n"),
    true = contains(Text, "targets=2\n"),
    true = contains(Text, ">>> Erlang/OTP 27 [erlang:27]: PASSED\n"),
    true = contains(Text, ">>> Erlang/OTP 28 [erlang:28]: FAILED (common_test)\n"),
    true = contains(Text, "    compile:      ok\n"),
    true = contains(Text, "    common_test:  failed\n"),
    true = contains(Text,
                    "    Failed cases: my_SUITE:my_case -> "
                    "{badmatch,false} at my_SUITE:38\n"),
    Results = ?config(results, Config),
    true = contains(Text, "    Failures:     " ++ filename:join(
                            Results, "28/failures.txt") ++ "\n"),
    true = contains(Text, "    CT logs:      " ++ filename:join(
                            Results, "28/logs/index.html") ++ "\n"),
    true = contains(Text, "    Cover:        " ++ filename:join(
                            Results, "28/cover/index.html") ++ "\n"),
    true = contains(Text, "overall_result=FAILED (1 of 2 targets failed)\n"),
    ok.

compile_failure_inlines_error(Config) ->
    OtpDir = ?config(otp_dir, Config),
    ok = write_file(filename:join(OtpDir, "ci-summary.txt"),
                    "project=sample\nerlang_otp=28\ncompile=9\n"
                    "xref=skipped\ndialyzer=skipped\ncommon_test=skipped\nresult=9\n"),
    ok = write_file(filename:join(OtpDir, "compile.log"),
                    "===> Compiling sample\n"
                    "src/sample.erl:12:5: Error: undefined function foo/0\n"
                    "  second error line\n"
                    "===> Compiling failed\n"),
    Targets = [#{image => "erlang:28", otp => "28"}],
    Result = {error, {ci_failed, [{lists:nth(1, Targets), {command_failed, 9}}]}},
    Text = report_text("sample", Targets, Result, Config),
    true = contains(Text, "FAILED (compile)\n"),
    true = contains(Text, "    compile:      failed\n"),
    true = contains(Text, "    src/sample.erl:12:5: Error: undefined function foo/0\n"),
    true = contains(Text, "    second error line\n"),
    false = contains(Text, "===> Compiling sample"),
    Results = ?config(results, Config),
    true = contains(Text, "    Compile log:  " ++ filename:join(
                            Results, "28/compile.log") ++ "\n"),
    ok.

no_summary_falls_back_to_exit_code(Config) ->
    OtpDir = ?config(otp_dir, Config),
    ok = file:delete(filename:join(OtpDir, "ci-summary.txt")),
    Targets = [#{image => "erlang:28", otp => "28"}],
    Result = {error, {ci_failed, [{lists:nth(1, Targets), {command_failed, 7}}]}},
    Text = report_text("sample", Targets, Result, Config),
    true = contains(Text, "FAILED (exit code 7)\n"),
    ok.

eunit_failure_reported(Config) ->
    OtpDir = ?config(otp_dir, Config),
    ok = write_file(filename:join(OtpDir, "ci-summary.txt"),
                    "project=sample\nerlang_otp=28\ncompile=0\n"
                    "xref=0\ndialyzer=skipped\neunit=1\nresult=1\n"),
    ok = write_file(filename:join(OtpDir, "eunit.log"),
                    "===> Running eunit\n"
                    "my_tests:foo_test...*failed*\n"
                    "::error:{badmatch,false}\n"
                    "===> 1 test failed\n"),
    ok = file:delete(filename:join(OtpDir, "common_test.log")),
    Targets = [#{image => "erlang:28", otp => "28"}],
    Result = {error, {ci_failed, [{lists:nth(1, Targets), {command_failed, 1}}]}},
    Text = report_text("sample", Targets, Result, Config),
    true = contains(Text, "FAILED (eunit)\n"),
    true = contains(Text, "    compile:      ok\n"),
    true = contains(Text, "    eunit:        failed\n"),
    false = contains(Text, "common_test"),
    Results = ?config(results, Config),
    true = contains(Text, "    EUnit log:    " ++ filename:join(
                            Results, "28/eunit.log") ++ "\n"),
    ok.

report_text(ProjectName, Targets, Result, Config) ->
    Content = rebar3_docker_ci_report:content(
                ProjectName, Targets, Result, ?config(results, Config)),
    binary_to_list(iolist_to_binary(Content)).

write_file(Path, Data) ->
    ok = filelib:ensure_dir(Path),
    file:write_file(Path, Data).

contains(Haystack, Needle) ->
    string:find(Haystack, Needle) =/= nomatch.
