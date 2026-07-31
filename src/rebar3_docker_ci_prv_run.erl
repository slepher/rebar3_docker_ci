-module(rebar3_docker_ci_prv_run).

-behaviour(provider).

-export([init/1, do/1, format_error/1, opts/0, validate_selection/2]).

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
                         "--suite may be used alone; --case requires --suite."},
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
     {no_view, undefined, "no-view", boolean,
      "Return after the checks instead of starting the log viewer."}].

do(State) ->
    Options = parsed_options(State),
    Suite = option_string(suite, Options),
    TestCase = option_string('case', Options),
    case validate_selection(Suite, TestCase) of
        {ok, Selection} -> load_and_run(State, Options, Selection);
        {error, Reason} -> {error, {?MODULE, Reason}}
    end.

validate_selection("", "") -> {ok, {"", ""}};
validate_selection("", _TestCase) -> {error, case_requires_suite};
validate_selection(Suite, TestCase) -> {ok, {Suite, TestCase}}.

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
    Versions = selected_versions(Options, Config),
    Image = rebar3_docker_ci_config:get(image_name, Config),
    Volume = rebar3_docker_ci_project:volume_name(
               rebar3_docker_ci_config:get(log_volume, Config), ProjectName),
    maybe
        ok ?= ensure_images(Versions, Image),
        ok ?= ensure_volume(Volume),
        {ok, PrivDir} ?= rebar3_docker_ci_project:priv_dir(),
        Context = #{project_root => Root,
                    scripts_dir => PrivDir,
                    project_name => ProjectName,
                    image_name => Image,
                    log_volume => Volume,
                    test_suite => Suite,
                    test_case => TestCase,
                    run_xref => effective_xref(Options, Config),
                    run_dialyzer => effective_dialyzer(Options, Config),
                    use_checkouts => Checkouts =/= [],
                    output_lang => output_language(Config),
                    checkouts => Checkouts},
        Result = rebar3_docker_ci_docker:run_matrix(
                   Versions,
                   fun(Version) ->
                           rebar_api:info("Running Docker CI on OTP ~s", [Version]),
                           rebar3_docker_ci_docker:execute(
                             rebar3_docker_ci_docker:run_args(Context, Version))
                   end),
        finish_run(State, Options, Volume, Config, Result)
    else
        {error, Reason} -> {error, {?MODULE, Reason}}
    end.

finish_run(State, Options, Volume, Config, Result) ->
    case maps:get(no_view, Options, false) of
        true -> provider_result(State, Result);
        false ->
            Port = rebar3_docker_ci_config:get(log_port, Config),
            case rebar3_docker_ci_docker:execute(
                   rebar3_docker_ci_docker:viewer_args(Volume, Port)) of
                ok -> provider_result(State, Result);
                {error, Reason} -> {error, {?MODULE, Reason}}
            end
    end.

provider_result(State, ok) -> {ok, State};
provider_result(_State, {error, Reason}) -> {error, {?MODULE, Reason}}.

ensure_images([], _Image) ->
    ok;
ensure_images([Version | Rest], Image) ->
    case rebar3_docker_ci_docker:execute_quiet(
           rebar3_docker_ci_docker:inspect_image_args(Image, Version)) of
        ok -> ensure_images(Rest, Image);
        {error, _Reason} -> {error, {image_missing, Image ++ ":" ++ Version}}
    end.

ensure_volume(Volume) ->
    case rebar3_docker_ci_docker:execute_quiet(
           rebar3_docker_ci_docker:inspect_volume_args(Volume)) of
        ok -> ok;
        {error, _Reason} ->
            rebar3_docker_ci_docker:execute(
              rebar3_docker_ci_docker:create_volume_args(Volume))
    end.

selected_versions(Options, Config) ->
    case maps:get(otp, Options, undefined) of
        undefined -> rebar3_docker_ci_config:get(erlang_versions, Config);
        Version -> [Version]
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
