# rebar3_docker_ci

[English](README.md)

`rebar3_docker_ci` 是运行在开发机上的 Rebar3 插件。它使用相互隔离的
Docker 容器，在多个 Erlang/OTP 版本中编译并测试项目，用以下 Rebar3 命令
替代复制或同步 `ci_scripts`：

```text
rebar3 docker_ci build
rebar3 docker_ci run
rebar3 docker_ci logs
```

## 兼容性模型

插件运行版本和被测项目版本彼此独立：

- `0.1` 版本要求开发机使用 Erlang/OTP 27 或更高版本运行插件。
- `otp-19-0.1` 保留可在 OTP 19 开发机上运行的插件版本。
- 被测 OTP 版本由项目配置决定，可以是 OTP 19、OTP 21 或其他存在官方
  Erlang Docker 镜像的版本。

插件必须安装在开发机的 Rebar3 全局配置中，不能加入被测项目的
`project_plugins`。项目插件会在容器内再次加载，这会错误地要求旧版目标 OTP
编译运行在宿主机上的插件。

## 环境要求

- 开发机 Erlang/OTP 27 或更高版本
- 与其兼容的 Rebar3
- `PATH` 中可用的 Docker Desktop 或 Docker Engine
- 项目使用 Git 工作树时需要 Git

开发机本身必须使用 OTP 19 时，请使用 `otp-19` 分支和
`otp-19-0.1` 标签。

## 安装

在开发机全局配置 `~/.config/rebar3/rebar.config` 中添加：

```erlang
{plugins, [
    {rebar3_docker_ci,
     {git, "https://github.com/slepher/rebar3_docker_ci.git",
      {tag, "0.1"}}}
]}.
```

确认 provider 已正确加载：

```text
rebar3 help docker_ci
```

被测项目的 `rebar.config` 只需要保存 `docker_ci` 配置，不要将插件添加到
`project_plugins`。

## 项目配置

```erlang
{docker_ci, [
    {erlang_versions, ["19", "21", "23", "28", "29"]},
    {run_xref, true},
    {run_dialyzer, false},
    {use_checkouts, auto},
    {output_lang, auto},
    {log_port, 8081},
    {image_name, "rebar3-docker-ci"},
    {log_volume, auto}
]}.
```

| 配置项 | 默认值 | 说明 |
| --- | --- | --- |
| `erlang_versions` | `["19", "28"]` | 非空的 Docker OTP 镜像标签列表。 |
| `run_xref` | `true` | 编译后运行 `rebar3 xref`。 |
| `run_dialyzer` | `false` | Common Test 前运行 `rebar3 dialyzer`。 |
| `use_checkouts` | `auto` | 是否包含 `_checkouts`：`auto`、`true` 或 `false`。 |
| `output_lang` | `auto` | runner 输出语言：`auto`、`en` 或 `cn`。 |
| `log_port` | `8081` | 日志查看器使用的宿主端口。 |
| `image_name` | `"rebar3-docker-ci"` | Docker 镜像仓库名。 |
| `log_volume` | `auto` | Docker 日志卷；`auto` 按项目名称隔离。 |

Common Test 的 suite 和 case 不写入配置，只通过命令行传入。`--suite` 可以
单独使用，`--case` 必须和 `--suite` 一起使用。

## 构建镜像

构建配置中的完整矩阵：

```text
rebar3 docker_ci build
```

只构建一个目标版本：

```text
rebar3 docker_ci build --otp 29
```

镜像标签格式为 `<image_name>:<otp>`。镜像只包含 Erlang 和 Rebar3，不包含
项目源码，因此修改源码后无需重新构建镜像。

## 运行检查

运行完整矩阵且不启动日志查看器：

```text
rebar3 docker_ci run --no-view
```

只运行一个 OTP 版本：

```text
rebar3 docker_ci run --otp 23 --no-view
```

运行单个 suite：

```text
rebar3 docker_ci run --otp 28 --suite sample_SUITE --no-view
```

运行 suite 中的单个 case：

```text
rebar3 docker_ci run --otp 29 \
    --suite sample_SUITE --case sample_case --no-view
```

可用的单次运行覆盖参数：

- `--dialyzer`：本次运行启用 Dialyzer。
- `--skip-xref`：本次运行关闭 xref。
- `--no-checkouts`：忽略项目的 `_checkouts`。
- `--no-view`：测试结束后直接返回，不启动 Nginx。

每个 OTP 版本依次执行 compile、可选 xref、可选 Dialyzer 和 Common Test。
某一步失败后，该版本跳过后续步骤，但矩阵中的其他版本仍会继续。所有版本完成
后，只要存在失败版本，宿主命令就返回失败。

## 源码隔离与 checkout

宿主项目以只读方式挂载。容器通过以下命令获得要复制到临时工作树的文件：

```text
git ls-files --cached --others --exclude-standard
```

因此已跟踪修改和未忽略的新文件都会参与测试，但不会复用宿主 `_build`。
启用 `use_checkouts` 后，每个 checkout 都会只读挂载并复制进隔离工作树。
显式设置为 `true` 时，缺失或空的 `_checkouts` 会产生错误；`auto` 则自动关闭
checkout 处理。

## 日志与覆盖率

测试完成后启动前台日志查看器：

```text
rebar3 docker_ci logs
rebar3 docker_ci logs --port 8082
```

Nginx 从 Docker 日志卷提供以下路径：

```text
/<otp>/ci-summary.txt
/<otp>/logs/index.html
/<otp>/cover/index.html
```

按 Ctrl+C 停止查看器。即使后续步骤被跳过，`ci-summary.txt` 也会记录每一步
的状态。

## 从同步脚本迁移

1. 在开发机 Rebar3 全局配置中安装插件。
2. 将 `ERLANG_VSNS`、`RUN_XREF`、`RUN_DIALYZER`、`USE_CHECKOUTS`、
   `OUTPUT_LANG` 和 `LOG_PORT` 转换为 `docker_ci` 配置项。
3. 将 suite 和 case 改为通过 `--suite`、`--case` 传入。
4. 使用 `build`、`run`、`logs` provider 替代旧脚本调用。
5. 新命令验证通过后删除复制的 `ci_scripts`。

迁移完成后，项目不再依赖 Astranaut 或其他仓库提供 CI 实现文件。

## 开发验证

```text
rebar3 compile
rebar3 eunit
rebar3 ct
```

插件还使用 Astranaut 在 OTP 19、21、23、28、29 上完成了真实集成测试，包括
xref、每个完整矩阵目标的 386 个 Common Test、单 suite、单 case、日志导出和
覆盖率导出。
