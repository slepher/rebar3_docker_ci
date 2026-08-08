-module(rebar3_docker_ci_prv_clean).

-behaviour(provider).

-export([init/1, do/1, format_error/1, opts/0]).

init(State) ->
    Provider = providers:create(
                 [{name, clean},
                  {module, ?MODULE},
                  {namespace, docker_ci},
                  {bare, true},
                  {deps, []},
                  {example, "rebar3 docker_ci clean"},
                  {short_desc, "Clean local Docker CI results."},
                  {desc, "Remove the local _build/docker_ci directory with "
                         "the logs, coverage and summaries produced by "
                         "`rebar3 docker_ci run`."},
                  {opts, opts()}]),
    {ok, rebar_state:add_provider(State, Provider)}.

opts() ->
    [].

do(State) ->
    Root = rebar3_docker_ci_project:root(),
    ResultsDir = rebar3_docker_ci_project:results_dir(Root),
    BaseDir = filename:dirname(ResultsDir),
    case rebar3_docker_ci_files:del_dir_r(BaseDir) of
        ok ->
            rebar_api:info("Removed ~s", [BaseDir]),
            {ok, State};
        {error, enoent} ->
            rebar_api:info("Nothing to clean (~s)", [BaseDir]),
            {ok, State};
        {error, Reason} ->
            {error, {?MODULE, {clean_failed, BaseDir, Reason}}}
    end.

format_error({clean_failed, Dir, Reason}) ->
    io_lib:format("failed to clean ~s: ~p", [Dir, Reason]).
