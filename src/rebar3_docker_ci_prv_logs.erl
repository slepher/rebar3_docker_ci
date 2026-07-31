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
                  {desc, "Serve summaries, Common Test logs, and coverage via Nginx."},
                  {opts, opts()}]),
    {ok, rebar_state:add_provider(State, Provider)}.

opts() ->
    [{port, $p, "port", integer, "Override the log viewer port."}].

do(State) ->
    case rebar3_docker_ci_config:load(State) of
        {ok, Config} -> serve(State, Config);
        {error, Reason} -> {error, {?MODULE, Reason}}
    end.

format_error(Reason) ->
    rebar3_docker_ci:format_error(Reason).

serve(State, Config) ->
    ProjectName = rebar3_docker_ci_project:name(State),
    Volume = rebar3_docker_ci_project:volume_name(
               rebar3_docker_ci_config:get(log_volume, Config), ProjectName),
    Options = parsed_options(State),
    Port = proplists:get_value(
             port, Options, rebar3_docker_ci_config:get(log_port, Config)),
    case validate_port(Port) of
        {ok, ValidPort} -> serve_port(State, Config, Volume, ValidPort);
        {error, Reason} -> {error, {?MODULE, Reason}}
    end.

validate_port(Port) when is_integer(Port), Port > 0, Port < 65536 ->
    {ok, Port};
validate_port(Port) ->
    {error, {invalid_port, Port}}.

serve_port(State, Config, Volume, Port) ->
    Versions = rebar3_docker_ci_config:get(erlang_versions, Config),
    case rebar3_docker_ci_docker:execute_quiet(
           rebar3_docker_ci_docker:inspect_volume_args(Volume)) of
        ok ->
            lists:foreach(fun(Version) -> print_links(Version, Port, Volume) end,
                          Versions),
            case rebar3_docker_ci_docker:execute(
                   rebar3_docker_ci_docker:viewer_args(Volume, Port)) of
                ok -> {ok, State};
                {error, Reason} -> {error, {?MODULE, Reason}}
            end;
        {error, _Reason} ->
            {error, {?MODULE, {log_volume_missing, Volume}}}
    end.

print_links(Version, Port, Volume) ->
    Base = "http://localhost:" ++ integer_to_list(Port) ++ "/" ++ Version,
    print_if_present(Volume, Version ++ "/ci-summary.txt",
                     "OTP ~s summary: ~s/ci-summary.txt", [Version, Base]),
    case present(Volume, Version ++ "/logs/index.html") of
        true -> rebar_api:info("OTP ~s logs: ~s/logs/index.html", [Version, Base]);
        false -> rebar_api:info("OTP ~s: no Common Test logs found", [Version])
    end,
    print_if_present(Volume, Version ++ "/cover/index.html",
                     "OTP ~s coverage: ~s/cover/index.html", [Version, Base]).

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
        {Options, _Arguments} -> Options;
        Options when is_list(Options) -> Options
    end.
