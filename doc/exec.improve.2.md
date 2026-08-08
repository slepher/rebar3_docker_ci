# 外部 runner 架构决策（exec.improve.2.md）

状态：已实施（0.4.0）。本文记录决策依据，供后续维护参考。

## 问题

inner-run 模型（宿主单 VM 内重放 CI）无法满足依赖插件的项目：

- 各阶段间 rebar_state 被 `maybe_reset_hooks_plugins` 重置，provider_hooks
  丢失（rebar3_erlando 注入的 `{post, [{compile, {erlando, compile}}]}`
  在 test profile 重新应用后消失）。
- 结果：`rebar3 do compile, ct` 与 `rebar3 ct` 行为不一致，出现
  `{unregisted_module, {async_m_v5, monad}}` 类编译期失败；而
  `rebar3 docker_ci run`（每阶段独立进程）全部通过。

## 决策

放弃进程内重放，改为**容器内外部 runner**：

1. **每阶段 = 独立标准 rebar3 进程**。项目在容器内与开发机本地运行
   完全同构，插件生命周期、hook 注入均正常。
2. **runner 职责最小化**：准备隔离 worktree、按固定顺序执行阶段、
   转发信号、在 stdout 发布观察事件。不注入插件、不解析失败、
   不写结果文件。
3. **宿主是唯一消费者**：宿主进程消费容器输出流，负责 ci.log、
   ci-summary.txt、ci-results.txt 的写入与校验。
4. **观察事件协议 v1**（`@@R3DCI/1[/<nonce>]`）：

   ```
   stage_started <stage>
   stage_finished <stage> <exit_code>
   stage_skipped <stage>
   ct_run <ct_run_dir_name>
   ```

   固定阶段顺序 compile → xref → dialyzer → common_test → eunit；
   仅当该阶段是下一预期阶段时事件才有效；失败阶段阻止后续启动；
   容器成功退出时所有阶段必须 passed/skipped，缺失事件 = 协议错误。

5. **发布物身份**：每轮 run_id（宿主生成）写入 summary；CT 用
   `ct_run=` 记录本轮精确 ct_run 目录。宿主绝不回退历史轮次产物。
6. **原子性**：每 OTP 目录 staging 后 rename 发布；cover 同目录
   暂存改名。

## 放弃的方案

| 方案 | 放弃原因 |
| --- | --- |
| 进程内重放（inner-run） | 插件生命周期跨阶段丢失；行为漂移 |
| 宿主多进程串行跑阶段 | 无法获得隔离的 OTP 版本环境 |
| runner 直接写结果文件 | 发布物一致性难以保证；身份校验放宿主 |

## 附带约束

- 容器挂载全部只读（`/mnt/source`、`/mnt/checkouts`、`/mnt/scripts`），
  唯一可写挂载是结果目录 `/mnt/results`；即使 runner 出错也无法
  破坏宿主源码。
- 测试 fixture 清理不得跟随符号链接（参见 exec.improve.md 清空事件）。
