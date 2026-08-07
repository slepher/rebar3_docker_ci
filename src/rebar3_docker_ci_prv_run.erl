-module(rebar3_docker_ci_prv_run).

-behaviour(provider).

-export([init/1, do/1, format_error/1, opts/0, validate_selection/2,
         validate_selection/3, matrix_results/2]).

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
     {no_checkouts, undefined, "no-checkouts", boolean,
      "Ignore the project's _checkouts directory for this run."},
     {view, undefined, "view", boolean,
      "Start the log viewer after the checks instead of returning."}].

do(State) ->
    Options = parsed_options(State),
    Suite = option_string(suite, Options),
    TestCase = option_string('case', Options),
    maybe
        {ok, Config} ?= rebar3_docker_ci_config:load(State),
        Framework = rebar3_docker_ci_config:get(test_framework, Config),
        {ok, Selection} ?= validate_selection(Suite, TestCase, Framework),
        load_and_run(State, Options, Selection)
    else
        {error, Reason} -> {error, {?MODULE, Reason}}
    end.

validate_selection(Suite, TestCase) ->
    validate_selection(Suite, TestCase, common_test).

validate_selection("", "", _Framework) -> {ok, {"", ""}};
validate_selection("", _TestCase, _Framework) -> {error, case_requires_suite};
validate_selection(Suite, TestCase, Framework) ->
    case {Suite, Framework} of
        {_Suite, common_test} -> {ok, {Suite, TestCase}};
        {_Suite, _Framework} -> {error, {selection_requires_common_test, Framework}}
    end.

format_error(Reason) ->
    rebar3_docker_ci:format_error(Reason).

load_and_run(State, Options, Selection) ->
    maybe
        {ok, Config} ?= rebar3_docker_ci_config:load(State),
        Root = rebar3_docker_ci_project:root(),
        ProjectName = rebar3_docker_ci_project:name(State),
        CheckoutMode = case maps:get(no_checkouts, Options, false) of
                           true -> false;
                           false -> rebar3_docker_ci_config:get(use_checkouts, Config)
                       end,
        {ok, Checkouts} ?=
            rebar3_docker_ci_project:resolve_checkouts(Root, CheckoutMode),
        {Suite, TestCase} = Selection,
        run_with_project(State, Options, Suite, TestCase, Config,
                         Root, ProjectName, Checkouts)
    else
        {error, Reason} -> {error, {?MODULE, Reason}}
    end.

run_with_project(State, Options, Suite, TestCase, Config,
                 Root, ProjectName, Checkouts) ->
    Images = rebar3_docker_ci_config:get(target_images, Config),
    ResultsDir = rebar3_docker_ci_project:results_dir(Root),
    maybe
        {ok, ResolvedTargets} ?= rebar3_docker_ci_targets:resolve(Images),
        {ok, Targets} ?= rebar3_docker_ci_targets:select(
                           ResolvedTargets, maps:get(otp, Options, undefined)),
        ok ?= ensure_results_dir(ResultsDir),
        {ok, PrivDir} ?= rebar3_docker_ci_project:priv_dir(),
        Context = #{project_root => Root,
                    scripts_dir => PrivDir,
                    project_name => ProjectName,
                    results_dir => ResultsDir,
                    test_suite => Suite,
                    test_case => TestCase,
                    run_xref => effective_xref(Options, Config),
                    run_dialyzer => effective_dialyzer(Options, Config),
                    use_checkouts => Checkouts =/= [],
                    test_framework =>
                        rebar3_docker_ci_config:get(test_framework, Config),
                    output_lang => output_language(Config),
                    checkouts => Checkouts},
        Result = rebar3_docker_ci_docker:run_matrix(
                   Targets,
                   fun(Target) ->
                           rebar_api:info("Running Docker CI on OTP ~s [~s]",
                                          [maps:get(otp, Target),
                                           maps:get(image, Target)]),
                           rebar3_docker_ci_docker:execute(
                             rebar3_docker_ci_docker:run_args(Context, Target))
                   end),
        ok ?= report_run(ProjectName, Targets, ResultsDir, Result),
        finish_run(State, Options, ProjectName, Targets,
                   ResultsDir, Config, Result)
    else
        {error, Reason} -> {error, {?MODULE, Reason}}
    end.

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

report_run(ProjectName, Targets, ResultsDir, Result) ->
    Content = rebar3_docker_ci_report:content(
                ProjectName, Targets, Result, ResultsDir),
    ResultsFile = filename:join(ResultsDir, "ci-results.txt"),
    case file:write_file(ResultsFile, Content) of
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
        ok -> ok;
        {error, Reason} -> {error, {results_dir_failed, ResultsDir, Reason}}
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
