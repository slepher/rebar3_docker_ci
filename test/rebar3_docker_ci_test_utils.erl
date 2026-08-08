-module(rebar3_docker_ci_test_utils).

-include_lib("kernel/include/file.hrl").

-export([del_dir_r/1]).

del_dir_r(Dir) ->
    case file:list_dir(Dir) of
        {ok, Entries} ->
            lists:foreach(fun(Entry) -> remove_entry(filename:join(Dir, Entry)) end,
                          Entries),
            file:del_dir(Dir);
        {error, enoent} ->
            ok;
        {error, _Reason} = Error ->
            Error
    end.

remove_entry(Path) ->
    case file:read_link_info(Path) of
        {ok, #file_info{type = directory}} ->
            del_dir_r(Path);
        _ ->
            file:delete(Path)
    end.
