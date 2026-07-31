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
                  {desc, "Run compile, xref, optional Dialyzer, and Common Test."},
                  {opts, opts()}]),
    {ok, rebar_state:add_provider(State, Provider)}.

opts() ->
    [{otp, $o, "otp", string, "Run only this Erlang/OTP version."},
     {suite, $s, "suite", string, "Run one Common Test suite."},
     {'case', $c, "case", string, "Run one case from --suite."},
     {dialyzer, $d, "dialyzer", boolean, "Enable Dialyzer."},
     {skip_xref, undefined, "skip-xref", boolean, "Disable xref."},
     {no_checkouts, undefined, "no-checkouts", boolean, "Ignore _checkouts."},
     {no_view, undefined, "no-view", boolean, "Do not start the log viewer."}].

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
    case rebar3_docker_ci_config:load(State) of
        {ok, Config} -> prepare_run(State, Options, Selection, Config);
        {error, Reason} -> {error, {?MODULE, Reason}}
    end.

prepare_run(State, Options, {Suite, TestCase}, Config) ->
    Root = rebar3_docker_ci_project:root(),
    ProjectName = rebar3_docker_ci_project:name(State),
    CheckoutMode = case proplists:get_bool(no_checkouts, Options) of
                       true -> false;
                       false -> rebar3_docker_ci_config:get(use_checkouts, Config)
                   end,
    case rebar3_docker_ci_project:resolve_checkouts(Root, CheckoutMode) of
        {ok, Checkouts} ->
            run_with_project(State, Options, Suite, TestCase, Config,
                             Root, ProjectName, Checkouts);
        {error, Reason} ->
            {error, {?MODULE, Reason}}
    end.

run_with_project(State, Options, Suite, TestCase, Config,
                 Root, ProjectName, Checkouts) ->
    Versions = selected_versions(Options, Config),
    Image = rebar3_docker_ci_config:get(image_name, Config),
    Volume = rebar3_docker_ci_project:volume_name(
               rebar3_docker_ci_config:get(log_volume, Config), ProjectName),
    case ensure_images(Versions, Image) of
        ok ->
            case ensure_volume(Volume) of
                ok -> run_containers(State, Options, Suite, TestCase, Config,
                                     Root, ProjectName, Checkouts,
                                     Versions, Image, Volume);
                {error, Reason} -> {error, {?MODULE, Reason}}
            end;
        {error, Reason} ->
            {error, {?MODULE, Reason}}
    end.

run_containers(State, Options, Suite, TestCase, Config,
               Root, ProjectName, Checkouts, Versions, Image, Volume) ->
    case rebar3_docker_ci_project:priv_dir() of
        {ok, PrivDir} ->
            Context = [{project_root, Root},
                       {scripts_dir, PrivDir},
                       {project_name, ProjectName},
                       {image_name, Image},
                       {log_volume, Volume},
                       {test_suite, Suite},
                       {test_case, TestCase},
                       {run_xref, effective_xref(Options, Config)},
                       {run_dialyzer, effective_dialyzer(Options, Config)},
                       {use_checkouts, Checkouts =/= []},
                       {output_lang, output_language(Config)},
                       {checkouts, Checkouts}],
            Result = rebar3_docker_ci_docker:run_matrix(
                       Versions,
                       fun(Version) ->
                               rebar_api:info("Running Docker CI on OTP ~s", [Version]),
                               rebar3_docker_ci_docker:execute(
                                 rebar3_docker_ci_docker:run_args(Context, Version))
                       end),
            finish_run(State, Options, Volume, Config, Result);
        {error, Reason} ->
            {error, {?MODULE, Reason}}
    end.

finish_run(State, Options, Volume, Config, Result) ->
    case proplists:get_bool(no_view, Options) of
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
    case proplists:get_value(otp, Options) of
        undefined -> rebar3_docker_ci_config:get(erlang_versions, Config);
        Version -> [Version]
    end.

effective_xref(Options, Config) ->
    case proplists:get_bool(skip_xref, Options) of
        true -> false;
        false -> rebar3_docker_ci_config:get(run_xref, Config)
    end.

effective_dialyzer(Options, Config) ->
    proplists:get_bool(dialyzer, Options) orelse
        rebar3_docker_ci_config:get(run_dialyzer, Config).

output_language(Config) ->
    case rebar3_docker_ci_config:get(output_lang, Config) of
        auto ->
            case os:getenv("LANG") of
                "zh" ++ _Rest -> cn;
                _ -> en
            end;
        Language -> Language
    end.

option_string(Key, Options) ->
    case proplists:get_value(Key, Options) of
        undefined -> "";
        Value -> Value
    end.

parsed_options(State) ->
    case rebar_state:command_parsed_args(State) of
        {Options, _Arguments} -> Options;
        Options when is_list(Options) -> Options
    end.
