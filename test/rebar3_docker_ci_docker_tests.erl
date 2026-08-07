-module(rebar3_docker_ci_docker_tests).

-include_lib("eunit/include/eunit.hrl").

image_args_test() ->
    ?assertEqual(["pull", "erlang:27"],
                 rebar3_docker_ci_docker:pull_args("erlang:27")),
    ?assertEqual(["image", "inspect", "example/erlang-ci:29"],
                 rebar3_docker_ci_docker:inspect_image_args(
                   "example/erlang-ci:29")),
    ?assertEqual(["run", "--rm", "--entrypoint", "erl", "erlang:27",
                  "-noshell", "-eval",
                  "io:format(\"~s\", [erlang:system_info(otp_release)]), halt()."],
                 rebar3_docker_ci_docker:detect_otp_args("erlang:27")).

parse_otp_release_test() ->
    ?assertEqual({ok, "27"},
                 rebar3_docker_ci_docker:parse_otp_release(<<"27\n">>)),
    ?assertEqual({ok, "29.1"},
                 rebar3_docker_ci_docker:parse_otp_release(" 29.1 \r\n")),
    ?assertEqual({error, invalid_otp_release},
                 rebar3_docker_ci_docker:parse_otp_release(<<>>)),
    ?assertEqual({error, invalid_otp_release},
                 rebar3_docker_ci_docker:parse_otp_release("27 latest")).

run_args_test() ->
    Context = #{project_root => "/project",
                scripts_dir => "/plugin/priv",
                project_name => "sample",
                results_dir => "/project/_build/docker_ci/results",
                test_suite => "sample_SUITE",
                test_case => "works",
                run_xref => true,
                run_dialyzer => false,
                use_checkouts => true,
                test_framework => common_test,
                output_lang => en,
                checkouts => [{"dep", "/checkout/dep"}]},
    Target = #{image => "example/erlang-ci:stable", otp => "28"},
    Args = rebar3_docker_ci_docker:run_args(Context, Target),
    ?assertEqual(["run", "--rm"], lists:sublist(Args, 2)),
    ?assert(member_pair("--env", "TEST_SUITE=sample_SUITE", Args)),
    ?assert(member_pair("--env", "TEST_CASE=works", Args)),
    ?assert(member_pair("--volume", "/project:/mnt/source:ro", Args)),
    ?assert(member_pair("--volume",
                        "/project/_build/docker_ci/results:/mnt/results", Args)),
    ?assert(member_pair("--volume", "/checkout/dep:/mnt/checkouts/dep:ro", Args)),
    ?assert(member_pair("--entrypoint", "bash", Args)),
    ?assertEqual(["example/erlang-ci:stable", "/mnt/scripts/inner_test.sh"],
                 lists:nthtail(length(Args) - 2, Args)).

viewer_args_test() ->
    Args = rebar3_docker_ci_docker:viewer_args("/project/_build/docker_ci/results", 8082),
    ?assert(member_pair("--publish", "8082:80", Args)),
    ?assert(member_pair("--volume",
                        "/project/_build/docker_ci/results:/usr/share/nginx/html:ro",
                        Args)),
    ?assert(lists:member("--interactive", Args)),
    ?assert(lists:member("nginx:alpine", Args)),
    Command = lists:last(Args),
    ?assertNotEqual(nomatch,
                    string:find(Command, "error_log /dev/stderr error;")),
    ?assertNotEqual(nomatch, string:find(Command, "access_log off;")),
    ?assertNotEqual(nomatch,
                    string:find(Command,
                                "nginx -c /tmp/nginx-quiet.conf")),
    ?assertNotEqual(nomatch, string:find(Command, "exec 3<&0")),
    ?assertNotEqual(nomatch,
                    string:find(Command, "kill -TERM $nginx_pid")).

matrix_continues_after_failure_test() ->
    put(matrix_seen, []),
    Fun = fun(Version) ->
                  put(matrix_seen, get(matrix_seen) ++ [Version]),
                  case Version of "20" -> {error, 7}; _ -> ok end
          end,
    ?assertEqual({error, {ci_failed, [{"20", 7}]}},
                 rebar3_docker_ci_docker:run_matrix(["19", "20", "21"], Fun)),
    ?assertEqual(["19", "20", "21"], get(matrix_seen)).

member_pair(Left, Right, [Left, Right | _]) -> true;
member_pair(Left, Right, [_ | Rest]) -> member_pair(Left, Right, Rest);
member_pair(_Left, _Right, []) -> false.
