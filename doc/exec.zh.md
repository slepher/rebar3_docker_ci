# rebar3 docker_ci — 使用说明（中文）

在 Docker 容器中以多个 Erlang/OTP 版本对项目运行
compile / xref / Dialyzer / Common Test / EUnit。

## 配置

在项目 `rebar.config` 中二选一配置目标镜像：

```erlang
{docker_ci, [{erlang_versions, ["21", "22", "23", "24", "25", "26", "27", "28", "29"]}]}.
```

或直接给镜像名（支持自定义 tag）：

```erlang
{docker_ci, [{docker_images, ["erlang:27", "example/ci:otp28"]}]}.
```

`erlang_versions` 与 `docker_images` 互斥。`image_name`（0.2.0 移除）与
`log_volume`（0.3.0 移除）已废弃，配置会报错。

可选配置项：

```erlang
{docker_ci, [
    {run_ct, true},          % 默认 true
    {run_eunit, false},      % 默认 false
    {run_xref, true},        % 默认 true
    {run_dialyzer, false},   % 默认 false
    {use_checkouts, auto},   % auto | true | false，默认 auto
    {jobs, 4},               % 并发目标数：正整数或 max，默认 4
    {log_port, 8081}         % --view 时的日志查看器端口
]}.
```

## 命令

| 命令 | 说明 |
| --- | --- |
| `rebar3 docker_ci config` | 查看当前生效配置 |
| `rebar3 docker_ci pull` | 拉取全部目标镜像 |
| `rebar3 docker_ci run` | 运行完整矩阵 |
| `rebar3 docker_ci run --otp 28` | 只跑指定 OTP |
| `rebar3 docker_ci run -s a_SUITE` | 只跑指定 CT 套件（需 run_ct） |
| `rebar3 docker_ci run -s a_SUITE -c a_case` | 只跑指定用例 |
| `rebar3 docker_ci run -d` | 本次启用 Dialyzer |
| `rebar3 docker_ci run --skip-xref` | 本次跳过 xref |
| `rebar3 docker_ci run --no-checkouts` | 忽略项目 `_checkouts` |
| `rebar3 docker_ci run -j 4` | 并发目标数（正整数或 `max`） |
| `rebar3 docker_ci clean` | 清理 `_build/docker_ci` 结果目录 |
| `rebar3 docker_ci logs --view` | 启动结果查看器（nginx） |

## 阶段

每个目标按固定顺序执行阶段：

```
compile → xref → dialyzer → common_test → eunit
```

- 每阶段在容器内以独立的标准 `rebar3 <command>` 进程运行，与本地
  开发环境同构；依赖插件的 hook 注入不会被后续阶段重置。
- 某阶段失败后，后续阶段不再启动，报告中标记为 `skipped`。
- `jobs`/`-j` 控制并发目标数，各目标独立运行、互不影响。

## 结果目录

每次运行写入 `_build/docker_ci/results/`：

```
_build/docker_ci/results/
├── ci-results.txt          # 矩阵汇总（终态原子发布）
└── <otp>/
    ├── ci.log              # 该目标完整输出（宿主唯一发布文件）
    ├── ci-summary.txt      # 每阶段状态 + run_id + ct_run 身份
    ├── logs/               # 该轮 CT 日志（仅当本轮运行了 CT）
    └── cover/              # cover 报告（若启用）
```

- 目录先写入临时名，成功后才改名发布；失败目标不会留下"最新一轮"的
  误导性产物。
- `ci-summary.txt` 中的 `run_id` 与 `ct_run=` 标识本轮精确产物；报告中
  的失败用例与 CT 日志链接只引用本轮记录，绝不回退到历史轮次。
- 新一轮运行开始时，每个 OTP 目录会清理上一轮的 ci.log、summary、
  cover 等产物（`logs/` CT 日志历史保留）；pre-0.4 的旧日志目录与旧的
  `ci-results.txt` 也会自动清理。
- 结果目录不可写（如旧版 root 运行遗留）时立即报错，可先
  `rebar3 docker_ci clean` 或手动删除。

## 依赖与 _checkouts

- 项目依赖从 `rebar.config` 按 git tag 拉取（本仓库各版本 tag 已发布）。
- `use_checkouts`（默认 auto）为 true 时，项目 `_checkouts/` 下的本地
  副本会复制进容器构建目录，替代网络依赖；符号链接目标必须是宿主项目
  目录，容器内以只读方式打包复制。

## 运行锁

同一项目同时只允许一个 `docker_ci run`；并发运行会立即报
`run_in_progress`（锁文件 `_build/docker_ci/run.lock`，上次运行崩溃时
可手动删除）。
