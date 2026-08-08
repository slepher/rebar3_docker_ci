-module(rebar3_docker_ci_files).

%% Minimal recursive file operations used by the plugin. The delete helper is
%% kept here instead of using file:del_dir_r/1, which is unavailable on the
%% oldest supported target releases (OTP 21 and 22).

-include_lib("kernel/include/file.hrl").

-export([del_dir_r/1]).

del_dir_r(Path) ->
    case file:read_link_info(Path) of
        {ok, Info} when Info#file_info.type =:= directory ->
            case file:list_dir(Path) of
                {ok, Names} ->
                    case delete_entries(Path, Names) of
                        ok -> file:del_dir(Path);
                        {error, _Reason} = Error -> Error
                    end;
                {error, Reason} ->
                    {error, Reason}
            end;
        {ok, _Info} ->
            file:delete(Path);
        {error, Reason} ->
            {error, Reason}
    end.

delete_entries(Dir, Names) ->
    lists:foldl(
      fun(Name, ok) -> del_dir_r(filename:join(Dir, Name));
         (_Name, {error, _Reason} = Error) -> Error
      end, ok, Names).
