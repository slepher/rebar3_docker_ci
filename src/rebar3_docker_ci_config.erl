-module(rebar3_docker_ci_config).

-export([load/1, from_list/1, get/2]).

-define(DEFAULTS,
        #{run_xref => true,
          run_dialyzer => false,
          use_checkouts => auto,
          output_lang => auto,
          log_port => 8081,
          log_volume => auto}).

load(State) ->
    from_list(rebar_state:get(State, docker_ci, [])).

from_list(Options) when is_list(Options) ->
    maybe
        ok ?= validate_keys(Options),
        OptionMap = maps:from_list(Options),
        {ok, Targets} ?= normalize_targets(OptionMap),
        normalize(maps:to_list(?DEFAULTS), OptionMap, Targets)
    else
        {error, _Reason} = Error -> Error
    end;
from_list(Value) ->
    {error, {invalid_config, docker_ci, Value}}.

get(Key, Config) ->
    maps:get(Key, Config).

validate_keys([]) ->
    ok;
validate_keys([{image_name, _Value} | _Rest]) ->
    {error, {removed_config, image_name}};
validate_keys([{Key, _Value} | Rest]) ->
    case allowed_key(Key) of
        true -> validate_keys(Rest);
        false -> {error, {unknown_config, Key}}
    end;
validate_keys([Value | _Rest]) ->
    {error, {invalid_config, docker_ci, Value}}.

allowed_key(erlang_versions) -> true;
allowed_key(docker_images) -> true;
allowed_key(Key) -> maps:is_key(Key, ?DEFAULTS).

normalize_targets(Options) ->
    case {maps:is_key(erlang_versions, Options),
          maps:is_key(docker_images, Options)} of
        {false, false} ->
            {error, {missing_target_config,
                     [erlang_versions, docker_images]}};
        {true, true} ->
            {error, {conflicting_target_config,
                     erlang_versions, docker_images}};
        {true, false} ->
            Versions = maps:get(erlang_versions, Options),
            case normalize_value(erlang_versions, Versions) of
                {ok, Normalized} ->
                    {ok, #{target_source => erlang_versions,
                           target_images => ["erlang:" ++ Version ||
                                             Version <- Normalized]}};
                error -> {error, {invalid_config, erlang_versions, Versions}}
            end;
        {false, true} ->
            Images = maps:get(docker_images, Options),
            case normalize_value(docker_images, Images) of
                {ok, Normalized} ->
                    {ok, #{target_source => docker_images,
                           target_images => Normalized}};
                error -> {error, {invalid_config, docker_images, Images}}
            end
    end.

normalize([], _Options, Acc) ->
    {ok, Acc};
normalize([{Key, Default} | Rest], Options, Acc) ->
    Value = maps:get(Key, Options, Default),
    case normalize_value(Key, Value) of
        {ok, Normalized} -> normalize(Rest, Options, Acc#{Key => Normalized});
        error -> {error, {invalid_config, Key, Value}}
    end.

normalize_value(erlang_versions, Versions) when is_list(Versions), Versions =/= [] ->
    normalize_versions(Versions, []);
normalize_value(docker_images, Images) when is_list(Images), Images =/= [] ->
    normalize_images(Images, []);
normalize_value(run_xref, Value) -> normalize_boolean(Value);
normalize_value(run_dialyzer, Value) -> normalize_boolean(Value);
normalize_value(use_checkouts, Value)
  when Value =:= auto; Value =:= true; Value =:= false ->
    {ok, Value};
normalize_value(output_lang, Value)
  when Value =:= auto; Value =:= en; Value =:= cn ->
    {ok, Value};
normalize_value(log_port, Value) when is_integer(Value), Value > 0, Value < 65536 ->
    {ok, Value};
normalize_value(log_volume, auto) -> {ok, auto};
normalize_value(log_volume, Value) -> normalize_string(Value);
normalize_value(_Key, _Value) -> error.

normalize_boolean(true) -> {ok, true};
normalize_boolean(false) -> {ok, false};
normalize_boolean(_Value) -> error.

normalize_versions([], Acc) ->
    {ok, lists:reverse(Acc)};
normalize_versions([Version | Rest], Acc) ->
    case normalize_version(Version) of
        {ok, Normalized} -> normalize_versions(Rest, [Normalized | Acc]);
        error -> error
    end.

normalize_version(Version) when is_binary(Version), byte_size(Version) > 0 ->
    normalize_version(binary_to_list(Version));
normalize_version(Version) when is_list(Version), Version =/= [] ->
    case safe_version(Version) of
        true -> {ok, Version};
        false -> error
    end;
normalize_version(_Version) ->
    error.

normalize_images([], Acc) ->
    {ok, lists:reverse(Acc)};
normalize_images([Image | Rest], Acc) when is_binary(Image), byte_size(Image) > 0 ->
    normalize_images([binary_to_list(Image) | Rest], Acc);
normalize_images([Image | Rest], Acc) when is_list(Image), Image =/= [] ->
    case lists:all(fun safe_image_char/1, Image) of
        true -> normalize_images(Rest, [Image | Acc]);
        false -> error
    end;
normalize_images(_Images, _Acc) ->
    error.

normalize_string(Value) when is_binary(Value), byte_size(Value) > 0 ->
    {ok, binary_to_list(Value)};
normalize_string(Value) when is_list(Value), Value =/= [] ->
    case lists:all(fun is_integer/1, Value) of
        true -> {ok, Value};
        false -> error
    end;
normalize_string(_Value) ->
    error.

safe_version([First | Rest]) ->
    safe_version_first(First) andalso lists:all(fun safe_version_char/1, Rest);
safe_version([]) ->
    false.

safe_version_first(Char) when Char >= $a, Char =< $z -> true;
safe_version_first(Char) when Char >= $A, Char =< $Z -> true;
safe_version_first(Char) when Char >= $0, Char =< $9 -> true;
safe_version_first($_) -> true;
safe_version_first(_Char) -> false.

safe_version_char(Char) ->
    safe_version_first(Char) orelse Char =:= $. orelse Char =:= $-.

safe_image_char(Char) ->
    is_integer(Char) andalso Char > 32 andalso Char < 127.
