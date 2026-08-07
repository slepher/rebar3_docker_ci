# Agent 友好结果设计

## 目标

让 `rebar3 docker_ci run` 的失败结果可以直接被运行在开发机上的 agent 消费,
无需通过 Docker CLI 访问日志卷。发布为 `0.3.0`:

- 每个目标的结果以纯文件形式写入宿主项目目录
  (`_build/docker_ci/results/<otp>/`),而不仅仅写入 Docker 卷。
- `run` 结束后不再默认启动日志查看器;查看器改为 opt-in 的 `--view` 参数。
  `rebar3 docker_ci logs` 仍是显式的查看器命令。
- 失败时,`run` 默认打印结构化摘要,包含失败的检查
  (compile | xref | dialyzer | common_test)、失败的 suite 和 case、
  异常原因,以及编译/测试日志和 cover 报告的路径。

## 问题

当前所有产物都存放在 Docker 卷中,agent 不借助 `docker` 命令无法读取;
失败只报告为 `Docker CI failed: [{Target,{command_failed,1}}]`;
且 `run` 默认启动 nginx 查看器导致命令阻塞。agent 调试失败时,
必须逆向推断卷内路径,而且看不到是哪个 suite、case 或异常导致的失败。

## 结果目录

`run` 将宿主的可写目录挂载进每个测试容器:

```text
<project_root>/_build/docker_ci/results/<otp>/
```

`_build` 已被 Git 忽略,也会被工作树拷贝排除,因此挂载不会干扰隔离快照。
每个目标运行结束后,该目录包含:

| 路径 | 内容 |
| --- | --- |
| `ci-results.txt` | 当次运行的主结果文件(位于 `results/` 根,见下文) |
| `<otp>/ci-summary.txt` | key=value 摘要:project、otp、各检查退出码、跳过的检查、`result=0|1` |
| `<otp>/failures.txt` | 结构化 Common Test 失败信息(CT 通过或被跳过时不存在) |
| `<otp>/compile.log` | 该目标 `rebar3 compile` 的完整输出 |
| `<otp>/xref.log` | `rebar3 xref` 完整输出(启用时) |
| `<otp>/dialyzer.log` | `rebar3 dialyzer` 完整输出(启用时) |
| `<otp>/common_test.log` | `rebar3 ct` 完整输出(测试框架为 `eunit` 时为 `eunit.log`) |
| `<otp>/logs/` | 导出的 `_build/test/logs`(CT HTML 与文本日志) |
| `<otp>/cover/` | 导出的 `_build/test/cover`(存在时) |

Docker 卷与 `log_volume` 配置被移除;查看器改为直接服务结果目录,
下一次运行时从结果目录拷贝上一轮的 CT 日志历史。

## 主结果文件

`run` 在矩阵结束后,由宿主插件读取各目标的 `ci-summary.txt` 与
`failures.txt`,生成当次运行的主结果文件:

```text
<project_root>/_build/docker_ci/results/ci-results.txt
```

该文件包含当次运行的全部目标结果,是 agent 首先阅读的单一入口。
通过的目标只输出一行;失败的目标输出概要,并以绝对路径链接失败日志:

```text
project=foo
ran_at=2026-08-07T22:00:00+08:00
overall=failed
targets=2
---
>>> Erlang/OTP 27 [erlang:27]: PASSED
>>> Erlang/OTP 28 [erlang:28]: FAILED (common_test)
    compile:      ok
    xref:         ok
    common_test:  failed
    Failed cases: my_SUITE:my_case -> {badmatch,false} at my_SUITE:38
    Failures:     /path/to/project/_build/docker_ci/results/28/failures.txt
    Compile log:  /path/to/project/_build/docker_ci/results/28/compile.log
    CT logs:      /path/to/project/_build/docker_ci/results/28/logs/index.html
    Cover:        /path/to/project/_build/docker_ci/results/28/cover/index.html
---
overall_result=FAILED (1 of 2 targets failed)
```

规则:

- 成功目标恒为一行:`>>> Erlang/OTP <otp> [<image>]: PASSED`。
- 失败目标分多行:`FAILED (<检查名>)`、各检查状态、
  `Failed cases`(suite:case -> 异常原因)、以及失败日志的绝对路径链接。
- compile/xref/dialyzer 失败时,在 `Failed cases` 位置内联第一个错误块
  (最多八行),并列出对应检查日志路径。
- 全部通过时,文件同样生成(所有目标均为单行),`overall=passed`。
- 每次运行覆盖该文件;重跑后 agent 读到的总是最新一轮结果。

## Run 流程变更

`rebar3_docker_ci_prv_run`:

- 创建结果目录,并在 `run_args/2` 中增加
  `--volume <root>/_build/docker_ci/results:/mnt/results`。
- 移除 `--no-view`。新增 `--view` 布尔参数,在矩阵结束后启动查看器
  (即此前的默认行为,现在改为显式开启)。不带该参数时,`run`
  打印摘要后立即返回。
- 出现任何失败时,默认打印结构化失败摘要(见下文),
  仅从结果目录读取纯文件。
- 矩阵结束后生成主结果文件 `ci-results.txt`(见上文),
  打印的摘要与该文件内容一致。

`rebar3_docker_ci_project` 新增 `results_dir/1` 辅助函数,
返回项目根目录对应的绝对结果路径,并确保目录存在。

## 内部运行脚本变更

`priv/inner_test.sh`:

1. `RESULTS_DIR="${RESULTS_DIR:-/mnt/results}"`,
   按版本区分 `VER_RESULTS="$RESULTS_DIR/$ERLANG_VER"`。
2. 每个检查同时流向 stdout 并写入各自的日志文件:
   `"$@" 2>&1 | tee "$VER_RESULTS/$CHECK.log"`,
   以 `PIPESTATUS[0]` 作为写入摘要的状态码。
3. CT 日志历史改为从 `$VER_RESULTS/logs` 拷回 `_build/test/logs`
   (替代原来的卷拷贝)。
4. CT 结束后,用一个小型 awk 解析器扫描
   `_build/test/logs/ct_run.*/lib.*/run.*/suite.log` 文件,写入
   `failures.txt`。解析器读取 CT 文本日志块:
   `=case <suite>:<case>`、`=logfile <html>`、
   `=result failed: <reason>`,续行直到下一个 `=` 或 `===` 关键字为止。
   reason 保留开头异常项和第一个栈帧
   (`{Module,Function,Arity,Line}`);完整栈留在 HTML 日志中。
5. 将 `logs/` 与 `cover/` 导出到 `$VER_RESULTS`(替代卷导出)。

`failures.txt` 格式(可解析,每个失败一个块):

```text
failure_count=2
suite=my_SUITE
case=my_case
reason={badmatch,false} at my_SUITE:38
logfile=my_suite.my_case.html
---
```

## 失败输出

矩阵结束后,`run` 生成主结果文件 `ci-results.txt`,并将其内容打印到
stdout(有目标失败时):

```text
=== rebar3_docker_ci run results ===
>>> Erlang/OTP 27 [erlang:27]: PASSED
>>> Erlang/OTP 28 [erlang:28]: FAILED (common_test)
    compile:      ok
    xref:         ok
    common_test:  failed
    Failed cases: my_SUITE:my_case -> {badmatch,false} at my_SUITE:38
    Failures:     /path/to/project/_build/docker_ci/results/28/failures.txt
    Compile log:  /path/to/project/_build/docker_ci/results/28/compile.log
    CT logs:      /path/to/project/_build/docker_ci/results/28/logs/index.html
    Cover:        /path/to/project/_build/docker_ci/results/28/cover/index.html
--------------------------------------------------------
Overall result: FAILED (1 of 2 targets failed)
```

stdout 与 `ci-results.txt` 的目标行与整体结果行由同一生成函数产出,
保证两处内容一致;文件额外带有 `project=`、`ran_at=` 等键值头。
compile/xref/dialyzer 失败时,显示对应检查名作为失败阶段,
并在该目标下方内联第一个错误块(最多八行),完整日志通过绝对路径引用。
同时提示可用 `rebar3 docker_ci logs` 浏览。退出码不变:
矩阵结束后 `run` 仍然以失败返回。

## Logs Provider 变更

`rebar3_docker_ci_prv_logs`:

- 改为服务 `<project_root>/_build/docker_ci/results` 而非 Docker 卷:
  `--volume <root>/_build/docker_ci/results:/usr/share/nginx/html:ro`。
- 文件存在性检查改为本地文件系统检查;
  `print_version_links` 中逐文件的 `docker run ... test -f` 调用
  替换为 `filelib:is_regular/1`;`--port` 与 URL 布局不变。

## 配置变更

- `log_volume` 在 `0.3.0` 移除;配置它时报"已移除选项"并给出指引
  (与 `0.2.0` 移除 `image_name` 的模式一致)。
- 新增 `run_ct`(默认 `true`)与 `run_eunit`(默认 `false`)两个独立布尔参数;
  可同时启用,两个框架互不跳过(`--suite`/`--case` 要求 `run_ct=true`)。
  摘要键与日志文件名分别为 `common_test`/`eunit`。
  兼容旧 OTP 时,runner 内不使用 `[[:space:]]` 等 mawk 不支持的 POSIX 类。
- `log_port` 保留,用于 opt-in 查看器与 `logs` provider。
- `.gitignore` 已覆盖 `_build`,无需修改。

## 兼容性与发布

命令与配置均为破坏性变更,统一使用 `0.3.x`。插件宿主支持 OTP 21 及以上;
目标镜像可任意选择 OTP 版本。目标 OTP 21 之前(如 19)时,插件需安装在
全局 `rebar.config`;目标均为 OTP 21+ 时可直接放在项目的
`project_plugins` 中。

## Agent 使用契约

失败后 agent 应:

1. 先读主结果文件 `_build/docker_ci/results/ci-results.txt`:
   一眼定位失败的目标、失败检查、失败 suite/case 与异常原因,
   并得到指向各失败日志的绝对路径链接。
2. 按链接读取 `<otp>/ci-summary.txt` 核对各检查退出码,
   或直接读 `compile.log`/`xref.log`/`dialyzer.log`/`ct.log` 获取输出。
3. 当 `common_test` 失败时,读取 `failures.txt` 获取全部失败
   suite、case 与异常,再读 `logs/<suite>.<case>.html` 获取完整调用栈。
4. 查看 `cover/index.html` 获取覆盖率;`logs/index.html` 获取运行索引。
5. 用 `--otp <release> --suite <suite> --case <case>` 聚焦重跑;
   该轮运行会覆盖刷新 `ci-results.txt` 与对应目标的检查日志和失败信息。

## 测试

- Shell runner 测试:用包含失败、通过、多行 reason 块的 fixture
  `suite.log` 断言 `failures.txt` 输出,以及各检查 tee 出的日志文件。
- Shell runner 测试断言结果目录布局,以及 CT 历史从 `/mnt/results`
  而非卷中拷贝。
- EUnit 测试覆盖新参数名(`view`、移除的 `no_view`)、已移除的
  `log_volume` 报错、结果目录路径构造,以及由 fixture
  `ci-summary.txt`/`failures.txt` 生成主结果文件 `ci-results.txt` 的格式
  (通过目标单行、失败目标概要加日志链接、整体覆盖)。
- 完整 EUnit 与 Common Test 套件;插件自身在 OTP 21 到 29 的全部镜像内
  编译并测试。
