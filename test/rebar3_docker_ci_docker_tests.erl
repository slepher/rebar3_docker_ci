-module(rebar3_docker_ci_docker_tests).

-include_lib("eunit/include/eunit.hrl").

build_args_test() ->
    ?assertEqual(["build", "--tag", "ci-image:19", "--build-arg",
                  "ERLANG_VER=19", "--file", "/plugin/priv/Dockerfile", "/project"],
                 rebar3_docker_ci_docker:build_args(
                   "ci-image", "19", "/plugin/priv/Dockerfile", "/project")).

run_args_test() ->
    Context = #{project_root => "/project",
                scripts_dir => "/plugin/priv",
                project_name => "sample",
                image_name => "ci-image",
                log_volume => "ci-logs",
                test_suite => "sample_SUITE",
                test_case => "works",
                run_xref => true,
                run_dialyzer => false,
                use_checkouts => true,
                output_lang => en,
                checkouts => [{"dep", "/checkout/dep"}]},
    Args = rebar3_docker_ci_docker:run_args(Context, "28"),
    ?assertEqual(["run", "--rm"], lists:sublist(Args, 2)),
    ?assert(member_pair("--env", "TEST_SUITE=sample_SUITE", Args)),
    ?assert(member_pair("--env", "TEST_CASE=works", Args)),
    ?assert(member_pair("--volume", "/project:/mnt/source:ro", Args)),
    ?assert(member_pair("--volume", "/checkout/dep:/mnt/checkouts/dep:ro", Args)),
    ?assertEqual(["ci-image:28", "bash", "/mnt/scripts/inner_test.sh"],
                 lists:nthtail(length(Args) - 3, Args)).

viewer_args_test() ->
    Args = rebar3_docker_ci_docker:viewer_args("ci-logs", 8082),
    ?assert(member_pair("--publish", "8082:80", Args)),
    ?assert(member_pair("--volume",
                        "ci-logs:/usr/share/nginx/html:ro", Args)),
    ?assert(lists:member("nginx:alpine", Args)),
    Command = lists:last(Args),
    ?assertNotEqual(nomatch,
                    string:find(Command, "error_log /dev/stderr error;")),
    ?assertNotEqual(nomatch, string:find(Command, "access_log off;")),
    ?assertNotEqual(nomatch,
                    string:find(Command,
                                "exec nginx -c /tmp/nginx-quiet.conf")).

volume_file_args_test() ->
    ?assertEqual(["run", "--rm", "--volume", "ci-logs:/data:ro",
                  "nginx:alpine", "/bin/sh", "-c",
                  "test -f /data/19/logs/index.html"],
                 rebar3_docker_ci_docker:volume_file_args(
                   "ci-logs", "19/logs/index.html")).

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
