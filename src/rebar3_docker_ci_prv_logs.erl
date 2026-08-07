-module(rebar3_docker_ci_prv_logs).

-behaviour(provider).

-export([init/1, do/1, format_error/1, opts/0, validate_port/1,
         print_links/4]).

init(State) ->
    Provider = providers:create(
                 [{name, logs},
                  {module, ?MODULE},
                  {namespace, docker_ci},
                  {bare, true},
                  {deps, []},
                  {example, "rebar3 docker_ci logs --port 8082"},
                  {short_desc, "Serve Docker CI logs."},
                  {desc, "Serve summaries, Common Test logs, and coverage via Nginx. "
                         "Use --port to override log_port for this command."},
                  {opts, opts()}]),
    {ok, rebar_state:add_provider(State, Provider)}.

opts() ->
    [{port, $p, "port", integer,
      "Override the configured log_port (1-65535)."}].

do(State) ->
    maybe
        {ok, Config} ?= rebar3_docker_ci_config:load(State),
        ProjectName = rebar3_docker_ci_project:name(State),
        Root = rebar3_docker_ci_project:root(),
        ResultsDir = rebar3_docker_ci_project:results_dir(Root),
        ok ?= ensure_results_dir_exists(ResultsDir),
        Options = parsed_options(State),
        Port = maps:get(port, Options,
                        rebar3_docker_ci_config:get(log_port, Config)),
        {ok, ValidPort} ?= validate_port(Port),
        Images = rebar3_docker_ci_config:get(target_images, Config),
        {ok, Targets} ?= rebar3_docker_ci_targets:resolve(Images),
        Versions = [maps:get(otp, Target) || Target <- Targets],
        print_links(ProjectName, Versions, ResultsDir, ValidPort),
        ok ?= rebar3_docker_ci_docker:execute(
                 rebar3_docker_ci_docker:viewer_args(ResultsDir, ValidPort)),
        {ok, State}
    else
        {error, Reason} -> {error, {?MODULE, Reason}}
    end.

format_error(Reason) ->
    rebar3_docker_ci:format_error(Reason).

validate_port(Port) when is_integer(Port), Port > 0, Port < 65536 ->
    {ok, Port};
validate_port(Port) ->
    {error, {invalid_port, Port}}.

ensure_results_dir_exists(ResultsDir) ->
    case filelib:is_dir(ResultsDir) of
        true -> ok;
        false -> {error, {results_missing, ResultsDir}}
    end.

print_links(ProjectName, Versions, ResultsDir, Port) ->
    rebar_api:info("~n=== ~s local CI logs ===", [ProjectName]),
    rebar_api:info("--------------------------------------------------------", []),
    lists:foreach(fun(Version) -> print_version_links(Version, Port, ResultsDir) end,
                  Versions),
    rebar_api:info("--------------------------------------------------------", []),
    rebar_api:info("Press Ctrl+C to stop the viewer.", []).

print_version_links(Version, Port, ResultsDir) ->
    Base = "http://localhost:" ++ integer_to_list(Port) ++ "/" ++ Version,
    rebar_api:info(">>> Erlang/OTP ~s", [Version]),
    print_if_present(ResultsDir, Version ++ "/ci-summary.txt",
                     "  Summary: ~s/ci-summary.txt", [Base]),
    case present(ResultsDir, Version ++ "/logs/index.html") of
        true -> rebar_api:info("  Logs:    ~s/logs/index.html", [Base]);
        false -> rebar_api:info("  No Common Test logs found.", [])
    end,
    print_if_present(ResultsDir, Version ++ "/cover/index.html",
                     "  Cover:   ~s/cover/index.html", [Base]),
    rebar_api:info("", []).

print_if_present(ResultsDir, RelativePath, Format, Args) ->
    case present(ResultsDir, RelativePath) of
        true -> rebar_api:info(Format, Args);
        false -> ok
    end.

present(ResultsDir, RelativePath) ->
    filelib:is_regular(filename:join(ResultsDir, RelativePath)).

parsed_options(State) ->
    case rebar_state:command_parsed_args(State) of
        {Options, _Arguments} -> maps:from_list(Options);
        Options when is_list(Options) -> maps:from_list(Options)
    end.
