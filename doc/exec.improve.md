# rebar3 docker_ci — 0.3.x → 0.4.0 改进记录

## 动机

0.3.x 的"inner-run"模型在宿主单 VM 内重放整个 CI 流水线：宿主
`rebar3` 进程加载插件后，以同一 rebar_state 依次执行各阶段。该模型
存在根本缺陷：

- **插件生命周期无法跨阶段存活**：`rebar_app_discover:maybe_reset_hooks_plugins`
  在重新应用 profile 时会清除 provider_hooks，导致依赖插件注入的
  构建步骤（如 rebar3_erlando 的 compile hook）在后续阶段失效；
  `install_deps` 还会过滤已安装插件。
- **进程内重放**与真实的独立 `rebar3 <command>` 语义不一致，修复
  手段是绕过标准调度（直接调 provider 模块），产生行为漂移。

实测案例：erlando 项目在 inner-run 下 `compile,ct` 报
`{unregisted_module, {async_m_v5, monad}}`——test profile 重新应用时
typeclass.beam 未重建。这不可能在每个阶段都是全新标准 rebar3 进程的
外部 runner 模型下发生。

## 方案：外部 runner

- 容器内运行 `priv/inner_test.sh`（PID 1），每个阶段调用一次独立的
  标准 `rebar3 <command>` 进程：compile、xref、dialyzer、common_test、
  eunit。
- runner 不向项目注入插件、不 tee、不写 summary、不解析失败；只负责
  准备隔离 worktree、按固定顺序跑阶段、在 stdout 上发出观察事件。
- 宿主 OTP 进程是输出流的唯一消费者：写 ci.log、校验事件、写
  ci-summary.txt 与 ci-results.txt。

## 关键改进

1. **标准 provider 调度**：`rebar_core:do/2` 正常分发，无绕过。
2. **持久 CT logdir**：CT 直接以 `--logdir` 写入本轮持久目录，不再
   复制 `_build/test/logs`，避免多轮产物混淆。
3. **精确 ct_run 身份**：runner 报告本轮新创建的 ct_run 目录名
   （`ct_run=` 记录在 summary）；宿主只引用该轮产物，不回退历史。
4. **nonce 事件协议**：宿主为每个目标分配 nonce，runner 输出
   `@@R3DCI/1/<nonce>` 前缀事件；协议严格按固定阶段顺序推进，失败
   阻止后续阶段，终态缺失视为协议错误。
5. **run 锁**：`_build/docker_ci/run.lock` 排他创建，拒绝并发宿主进程。
6. **原子发布**：每 OTP 目录先写临时名，全部完成后改名发布；
   失败目标不留下误导性"最新"产物。
7. **每阶段独立进程**：插件生命周期、erlando hook 注入等行为与开发
   机本地 `rebar3` 完全一致（已验证：全矩阵 9-OTP 各阶段 hook 恰好
   执行一次）。
8. **cover 同目录暂存改名**：cover 报告以 `to.tmp` 暂存后 rename，
   半拷贝目录永远不会被链接。
9. **信号转发**：runner 记录子进程 pid，INT/TERM 转发给当前阶段。

## 发布文件（宿主唯一写入）

- `ci.log`：容器输出流原文。
- `ci-summary.txt`：状态机终态（每阶段 passed/failed/skipped/aborted）、
  run_id、ct_run 身份。
- `ci-results.txt`：矩阵汇总，全部目标结束后一次写入。

## 清空事件与修复（2026-08-09）

测试 fixture 清理 `del_dir_r` 曾使用 `filelib:is_dir` 判断条目类型，
该函数跟随符号链接：fixture 的 `checkouts/` 以 symlink 指向宿主兄弟
仓库时，递归清理删除了链接目标（宿主仓库全部内容）。修复为
`file:read_link_info`（不跟随），并加入回归测试
（`files_tests:symlink_target_survives_test`、
`runner_erlando_tests` 的 after 完整性断言）。
