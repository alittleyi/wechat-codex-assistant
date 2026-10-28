# 运行手册

## 首次安装

1. 按 `INSTALL.md` 安装外部运行环境和 Python 依赖。
2. 运行 `scripts/initialize-workspace.ps1`，确认它没有覆盖现有 `AGENTS.md`。
3. 运行 `scripts/preflight.ps1`；任何 `missing`、`needs-configuration` 或关键 `unknown` 都要先处理。
4. 在未放入真实用户文件的候选副本中运行 `scripts/release-self-test.ps1`。
5. 配置本人的微信私聊后，按 `docs/TEST-MATRIX.md` 完成真实设备验收。

## 日常运行

- 长任务必须保存当前步骤、下一步和恢复条件。
- 单批结束不等于长期任务完成；必须进入继续、等待许可、等待额度、等待验收或完成之一。
- 删除、覆盖、登录、付款、外发和公开发布需要动作前确认。
- 状态未知时停止扩大动作并保留可恢复检查点。

## 故障处理

- 先运行 `scripts/preflight.ps1` 和调度桥 `health`，保存脱敏摘要。调度桥 `prepare`/`claim` 必须同时提供 ready、canonical-chat 和匹配的主会话引用；busy、写锁、网络失败、恢复失败、临时/协调会话或引用不匹配时返回 blocked，不创建新聊天或继续下游发布。
- 不手工删除锁或篡改运行记录；使用租约超时与受控恢复。
- 不把合成测试、浏览器演示或历史机器记录当成当前手机验收。
