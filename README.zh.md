# rebar3_docker_ci

[English](README.md)

`rebar3_docker_ci` 是运行在开发机上的 Rebar3 插件。它使用相互隔离的
Docker 容器，在多个 Erlang/OTP 版本中编译并测试项目，用标准 Rebar3 命令
替代复制或同步 `ci_scripts`：

```text
rebar3 docker_ci config
rebar3 docker_ci pull
rebar3 docker_ci run
rebar3 docker_ci logs
```

## 兼容性模型

插件宿主版本和被测项目版本彼此独立：

- `0.3.1` 要求开发机使用 Erlang/OTP 21 或更高版本运行插件。
- `otp-19-0.3.1` 保留可在 OTP 19 开发机上运行的插件版本。
- 测试目标可以使用 Docker 镜像提供的更旧或更新 OTP 版本。

插件必须安装在开发机的 Rebar3 全局配置中，不能加入被测项目的
`project_plugins`。项目插件会在测试容器内再次加载，使目标 OTP 错误地依赖
宿主插件所要求的 OTP 版本。

## 环境要求

- 开发机 Erlang/OTP 21 或更高版本
- 与其兼容的 Rebar3
- `PATH` 中可用的 Docker Desktop 或 Docker Engine
- 项目使用 Git 工作树时需要 Git

开发机本身必须使用 OTP 19 时，请安装 `otp-19-0.3.1`。

## 安装

在开发机全局配置 `~/.config/rebar3/rebar.config` 中添加：

```erlang
{plugins, [
    {rebar3_docker_ci,
     {git, "https://github.com/slepher/rebar3_docker_ci.git",
      {tag, "0.3.1"}}}
]}.
```

确认 Rebar3 已加载全部 provider，并查看详细参数：

```text
rebar3 help docker_ci
rebar3 help docker_ci config
rebar3 help docker_ci pull
rebar3 help docker_ci run
rebar3 help docker_ci logs
```

被测项目的 `rebar.config` 只保存 `docker_ci` 配置。

## 项目配置

必须配置且只能配置一种目标来源。使用 Docker Hub 官方 Erlang 镜像时：

```erlang
{docker_ci, [
    {erlang_versions, ["19", "21", "23", "28", "29"]},
    {run_xref, true},
    {run_dialyzer, false},
    {use_checkouts, auto},
    {output_lang, auto},
    {run_ct, true},
    {run_eunit, false},
    {log_port, 8081}
]}.
```

每个版本会转换为 `erlang:<version>`。需要任意可拉取镜像时改用：

```erlang
{docker_ci, [
    {docker_images, [
        "erlang:27",
        "registry.example.com/team/erlang-ci:28"
    ]}
]}.
```

`erlang_versions` 与 `docker_images` 互斥。插件不提供默认测试版本；目标配置
缺失、为空或同时存在都会报错。运行 `rebar3 docker_ci config` 可查看配置示例、
默认值、当前配置的校验结果及规范化后的镜像名称。

| 配置项 | 默认值 | 说明 |
| --- | --- | --- |
| `erlang_versions` | 必选项之一 | 非空 OTP 标签列表，转换为 `erlang:<version>`。 |
| `docker_images` | 必选项之一 | 非空完整 Docker 镜像引用列表。 |
| `run_xref` | `true` | 编译后运行 `rebar3 xref`。 |
| `run_dialyzer` | `false` | Common Test 前运行 `rebar3 dialyzer`。 |
| `use_checkouts` | `auto` | 是否包含 `_checkouts`：`auto`、`true` 或 `false`。 |
| `output_lang` | `auto` | runner 输出语言：`auto`、`en` 或 `cn`。 |
| `run_ct` | `true` | 运行 `rebar3 ct`。 |
| `run_eunit` | `false` | 运行 `rebar3 eunit`；与 `run_ct` 相互独立，可同时启用。 |
| `log_port` | `8081` | 日志查看器使用的宿主端口。 |

Common Test 的 suite 和 case 只通过命令行传入。`--suite` 可以单独使用，
`--case` 必须和 `--suite` 一起使用；两者都要求 `run_ct=true`。

## 拉取镜像

首次运行或修改目标后，拉取配置中的全部镜像：

```text
rebar3 docker_ci pull
```

插件直接运行这些镜像，不再构建包装镜像。每个镜像必须包含 Erlang、Rebar3、
Bash 以及项目需要的标准工具。插件通过在镜像内运行 `erl` 检测真实 OTP 版本；
`--otp` 选择和日志路径使用检测结果，而不是镜像标签。两个镜像不能报告相同的
OTP 版本。

## 运行检查

```text
# 运行完整矩阵，不启动日志查看器
rebar3 docker_ci run

# 运行一个检测到的 OTP 版本
rebar3 docker_ci run --otp 23

# 运行单个 Common Test suite
rebar3 docker_ci run --otp 28 --suite sample_SUITE

# 运行 suite 中的单个 case
rebar3 docker_ci run --otp 29 --suite sample_SUITE --case sample_case

# 检查结束后启动日志查看器
rebar3 docker_ci run --view
```

单次运行覆盖参数：

- `--dialyzer`：本次运行启用 Dialyzer。
- `--skip-xref`：本次运行关闭 xref。
- `--no-checkouts`：忽略项目的 `_checkouts`。
- `--view`：检查结束后启动 Nginx 查看器；默认直接返回。

每个目标依次执行 compile、可选 xref、可选 Dialyzer 和启用的测试框架
(`run_ct`、`run_eunit`,相互独立)。某一步失败后，该目标跳过后续步骤，但矩阵中的
其他目标继续运行。每次运行都会把主结果文件和各目标的产物写入
`_build/docker_ci/results/`(见下文)。

## 结果与失败信息

所有结果都以纯文件写入宿主项目目录，无需 Docker 即可读取：

```text
_build/docker_ci/results/ci-results.txt          本次运行的主结果文件
_build/docker_ci/results/<otp>/ci-summary.txt    各检查退出码
_build/docker_ci/results/<otp>/failures.txt      失败的 suite、case 与原因
_build/docker_ci/results/<otp>/compile.log       各检查完整输出(每项一个)
_build/docker_ci/results/<otp>/logs/             Common Test 日志
_build/docker_ci/results/<otp>/cover/            覆盖率报告
```

`ci-results.txt` 是唯一入口：通过的目标只占一行，失败的目标会显示失败的检查、
失败的 suite 和 case 及其异常，以及指向失败日志的绝对路径链接。失败时
stdout 会打印相同内容。退出码不变：目标失败即整个运行失败。

## 源码隔离与 checkout

宿主项目以只读方式挂载。容器复制以下命令报告的文件：

```text
git ls-files --cached --others --exclude-standard
```

已跟踪修改和未忽略的新文件都会参与测试，但不复用宿主 `_build`。启用的
checkout 以只读方式挂载并复制到隔离工作树。显式设置 `true` 时，缺失或为空的
`_checkouts` 会报错；`auto` 此时自动关闭 checkout 处理。

## 日志与覆盖率

测试完成后启动前台日志查看器：

```text
rebar3 docker_ci logs
rebar3 docker_ci logs --port 8082
```

Nginx 从结果目录提供以下路径：

```text
/<otp>/ci-summary.txt
/<otp>/logs/index.html
/<otp>/cover/index.html
```

按 Ctrl+C 会停止查看器及其容器。输出只包含配置的镜像，并使用检测到的 OTP
版本。即使后续步骤被跳过，`ci-summary.txt` 也会记录每一步状态。

## 从同步脚本迁移

1. 在开发机 Rebar3 全局配置中安装插件。
2. 在 `rebar.config` 中添加 `erlang_versions` 或 `docker_images`，只能二选一。
3. 将其余 CI 环境值转换为可选的 `docker_ci` 配置项。
4. 将 suite 和 case 改为通过 `--suite`、`--case` 传入。
5. 使用 `pull`、`run`、`logs` provider 替代旧脚本调用。
6. 新命令验证通过后删除复制的 `ci_scripts`。

迁移完成后，项目运行 CI 时不再依赖 Astranaut 或其他仓库的实现文件。

## 开发验证

```text
rebar3 do compile, eunit, ct
```

插件使用 Astranaut 在 OTP 19、21、23、28、29 上执行真实集成测试，包括 xref、
Common Test、suite/case 选择、日志导出和覆盖率导出。
