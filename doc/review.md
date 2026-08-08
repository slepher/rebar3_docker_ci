# 代码审查清单（review.md）

`rebar3 docker_ci` 维护与审查要点。

## 安全（最高优先级）

- [ ] 宿主路径只读：容器挂载 `/mnt/source`、`/mnt/scripts`、`/mnt/checkouts`
      必须带 `:ro`；唯一可写挂载是结果目录 `/mnt/results`。
- [ ] 删除操作作用域：任何 `rm -rf` 只允许作用于容器内 `$WORK_DIR`、
      `$VER_RESULTS`（staging/发布）等已知路径，且变量必须有默认值。
- [ ] 符号链接安全：宿主侧删除必须用 `file:read_link_info` 判断
      （不跟随链接）；测试 fixture 清理禁止使用 `filelib:is_dir` 递归。
- [ ] runner 脚本 `set -uo pipefail`；`rm -rf "$VAR"` 中 `$VAR` 为空时
      必须拒绝执行（如 `[[ -n "$VAR" && -d "$VAR" ]]` 前置检查）。

## 并发

- [ ] `_build/docker_ci/run.lock` 排他创建（`[write, exclusive]`），
      并发宿主进程被拒绝而不是互相破坏。
- [ ] 每目标独立 nonce，事件协议按 nonce 隔离并发目标输出。

## 协议

- [ ] 事件必须按固定阶段顺序推进；乱序/失败后启动/未知事件 =
      `{error, ...}`，绝不静默接受。
- [ ] 容器成功退出但阶段事件缺失 → `{incomplete, Stages}` 协议错误。
- [ ] ct_run 目录名校验（basename、无路径分隔符）；宿主只引用
      summary 记录的 ct_run 身份，不回退历史轮次。

## 发布物

- [ ] 每 OTP 结果目录 staging → rename 原子发布；失败目标不留下
      误导性"最新"产物。
- [ ] `ci-results.txt` 在所有目标结束后一次写入。
- [ ] cover 报告同目录 `to.tmp` 暂存改名，半拷贝目录永不被链接。

## 兼容性

- [ ] 代码兼容 OTP 21+（不用 `file:del_dir_r/1`、`binary:find` 等
      高版本 API；删除用自实现 `rebar3_docker_ci_files:del_dir_r/1`）。
- [ ] xref ignores 覆盖 rebar3 运行时 API（rebar_api / rebar_state /
      providers 等），插件本身 xref 干净。

## 测试

- [ ] `rebar3 eunit` 全绿（events 状态机、files 删除、report 解析、
      run 选项、provider 校验、fixture 端到端）。
- [ ] fixture 测试后断言兄弟仓库 src/.git 完整（清空回归）。
- [ ] `rebar3 ct`（宿主）通过：inner_test_SUITE（协议/身份/失败停止）
      与 report_SUITE（汇总/失败内联/无 summary 回退）。
- [ ] 全矩阵 9-OTP 各阶段 PASSED；erlando 类插件项目每阶段 hook
      恰好执行一次。
