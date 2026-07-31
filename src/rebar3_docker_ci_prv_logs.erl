-module(rebar3_docker_ci_prv_logs).

-behaviour(provider).

-export([init/1, do/1, format_error/1, opts/0, validate_port/1]).

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
        Volume = rebar3_docker_ci_project:volume_name(
                   rebar3_docker_ci_config:get(log_volume, Config), ProjectName),
        Options = parsed_options(State),
        Port = maps:get(port, Options,
                        rebar3_docker_ci_config:get(log_port, Config)),
        {ok, ValidPort} ?= validate_port(Port),
        ok ?= ensure_volume_exists(Volume),
        print_links(ProjectName, Config, Volume, ValidPort),
        ok ?= rebar3_docker_ci_docker:execute(
                 rebar3_docker_ci_docker:viewer_args(Volume, ValidPort)),
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

ensure_volume_exists(Volume) ->
    case rebar3_docker_ci_docker:execute_quiet(
           rebar3_docker_ci_docker:inspect_volume_args(Volume)) of
        ok -> ok;
        {error, _Reason} ->
            {error, {log_volume_missing, Volume}}
    end.

print_links(ProjectName, Config, Volume, Port) ->
    Versions = rebar3_docker_ci_config:get(erlang_versions, Config),
    rebar_api:info("~n=== ~s local CI logs ===", [ProjectName]),
    rebar_api:info("--------------------------------------------------------", []),
    lists:foreach(fun(Version) -> print_version_links(Version, Port, Volume) end,
                  Versions),
    rebar_api:info("--------------------------------------------------------", []),
    rebar_api:info("Press Ctrl+C to stop the viewer.", []).

print_version_links(Version, Port, Volume) ->
    Base = "http://localhost:" ++ integer_to_list(Port) ++ "/" ++ Version,
    rebar_api:info(">>> Erlang/OTP ~s", [Version]),
    print_if_present(Volume, Version ++ "/ci-summary.txt",
                     "  Summary: ~s/ci-summary.txt", [Base]),
    case present(Volume, Version ++ "/logs/index.html") of
        true -> rebar_api:info("  Logs:    ~s/logs/index.html", [Base]);
        false -> rebar_api:info("  No Common Test logs found.", [])
    end,
    print_if_present(Volume, Version ++ "/cover/index.html",
                     "  Cover:   ~s/cover/index.html", [Base]),
    rebar_api:info("", []).

print_if_present(Volume, Path, Format, Args) ->
    case present(Volume, Path) of
        true -> rebar_api:info(Format, Args);
        false -> ok
    end.

present(Volume, Path) ->
    rebar3_docker_ci_docker:execute_quiet(
      rebar3_docker_ci_docker:volume_file_args(Volume, Path)) =:= ok.

parsed_options(State) ->
    case rebar_state:command_parsed_args(State) of
        {Options, _Arguments} -> maps:from_list(Options);
        Options when is_list(Options) -> maps:from_list(Options)
    end.
