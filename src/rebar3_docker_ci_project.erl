-module(rebar3_docker_ci_project).

-export([root/0, name/1, safe_name/1, volume_name/2,
         resolve_checkouts/2, priv_dir/0]).

root() ->
    rebar_dir:get_cwd().

name(State) ->
    case rebar_state:project_apps(State) of
        [App | _] -> to_list(rebar_app_info:name(App));
        [] -> filename:basename(root())
    end.

safe_name(Value) ->
    Chars = lowercase(to_list(Value)),
    Sanitized = sanitize(Chars, [], false),
    case trim_hyphens(lists:reverse(Sanitized)) of
        [] -> "project";
        Name -> Name
    end.

volume_name(auto, ProjectName) ->
    "rebar3-docker-ci-" ++ safe_name(ProjectName);
volume_name(Value, _ProjectName) ->
    to_list(Value).

resolve_checkouts(_Root, false) ->
    {ok, []};
resolve_checkouts(Root, Mode) when Mode =:= auto; Mode =:= true ->
    Directory = filename:join(Root, "_checkouts"),
    Entries = checkout_entries(Directory),
    case {Mode, Entries} of
        {true, []} -> {error, {checkouts_missing, Directory}};
        _ -> {ok, Entries}
    end.

priv_dir() ->
    case code:priv_dir(rebar3_docker_ci) of
        {error, bad_name} ->
            {error, plugin_priv_not_found};
        Directory ->
            {ok, Directory}
    end.

checkout_entries(Directory) ->
    case file:list_dir(Directory) of
        {ok, Names} ->
            lists:foldl(
              fun(Name, Acc) ->
                      Path = filename:join(Directory, Name),
                      case filelib:is_dir(Path) of
                          true -> [{Name, canonical_path(Path)} | Acc];
                          false -> Acc
                      end
              end, [], lists:sort(Names));
        {error, _Reason} ->
            []
    end.

canonical_path(Path) ->
    Absolute = filename:absname(Path),
    case file:read_link(Absolute) of
        {ok, Target} ->
            Resolved = case filename:pathtype(Target) of
                           absolute -> Target;
                           _ -> filename:join(filename:dirname(Absolute), Target)
                       end,
            canonical_path(Resolved);
        {error, _Reason} ->
            Absolute
    end.

sanitize([], Acc, _Separator) ->
    Acc;
sanitize([Char | Rest], Acc, _Separator)
  when Char >= $a, Char =< $z; Char >= $0, Char =< $9 ->
    sanitize(Rest, [Char | Acc], false);
sanitize([_Char | Rest], Acc, true) ->
    sanitize(Rest, Acc, true);
sanitize([_Char | Rest], Acc, false) ->
    sanitize(Rest, [$- | Acc], true).

trim_hyphens(Value) ->
    trim_right_hyphens(trim_left_hyphens(Value)).

trim_left_hyphens([$- | Rest]) -> trim_left_hyphens(Rest);
trim_left_hyphens(Value) -> Value.

trim_right_hyphens(Value) ->
    lists:reverse(trim_left_hyphens(lists:reverse(Value))).

lowercase(Value) ->
    [lowercase_char(Char) || Char <- Value].

lowercase_char(Char) when Char >= $A, Char =< $Z -> Char + 32;
lowercase_char(Char) -> Char.

to_list(Value) when is_binary(Value) -> binary_to_list(Value);
to_list(Value) when is_atom(Value) -> atom_to_list(Value);
to_list(Value) when is_list(Value) -> Value.
