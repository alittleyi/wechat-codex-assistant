# 稳定调度桥 V0.1

本桥把 `task-chat-registry.ps1` 生成的完整意图包保存为可追踪调度记录，供受控执行链路领取和回写结果。它不自行发送消息、不绕过时间/额度/许可检查，也不把“已准备”误报为“已送达”。

## 快速检查

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\dispatch-bridge.ps1 -Action health
```

输出 `status: passed` 才可使用；失败时 `checks` 会指出登记表、存储、运行时或互斥环节。输出不读取或显示凭据。

## 生命周期

```powershell
# 1. 由任务登记表生成完整意图包
.\scripts\dispatch-bridge.ps1 -Action prepare -TaskKey <task-key>

# 2. 单一执行者领取；默认租约 5 分钟
.\scripts\dispatch-bridge.ps1 -Action claim -DispatchId <d-id> -Worker <worker-name>

# 3. 同一执行者持领取返回的 claimToken 在租约内回写结果
.\scripts\dispatch-bridge.ps1 -Action complete -DispatchId <d-id> -Worker <worker-name> -ClaimToken <token> -ResultSummary <summary>
# 或 -Action fail
```

- 互斥优先使用 Windows `Global\` 命名 Mutex；进程崩溃后由操作系统自动释放，不生成需要人工删除的锁文件。若宿主不允许全局命名对象则退回 `Local\`，健康检查会显示 `local-session`；此时只能保证同一 Windows 登录会话内互斥，不可把多登录会话并发部署视为受支持配置。
- 执行者崩溃后，领取租约到期即可由后继执行者自动重领，`attempt` 保留重试次数。每次领取生成随机 fencing token；即使 worker 名相同，旧租约 token 也不能结束新领取。
- 同一任务、同一完整意图包的重复 `prepare` 始终返回原记录，包括终态，避免 cron 重试重复执行。只有明确提供新的 `-RerunKey <key>` 才创建新调度；同一个 rerun key 自身仍保持幂等。
- 存储采用临时文件后原子替换；输入有长度和凭据形态检查。
- `health` 校验记录 ID 唯一性、状态、时间顺序、attempt、claimed 租约/token 与终态字段；损坏记录返回 `failed` 和退出码 1。运行时只报告来源类别，不显示用户绝对路径。
- Node 首页回执锁也已改成带进程所有者的目录锁：同机进程已退出时自动回收；旧版无元数据锁超过 10 分钟才自动隔离删除，近期未知锁保持失败关闭。
- `runtime-resolver.ps1` 依次使用显式环境变量、受限的 Codex runtime 根目录、PATH，不含用户名或固定 Codex 安装路径，并优先保留已验证依赖集。

## 配置

- `WECHAT_AGENT_NODE` / `WECHAT_AGENT_PYTHON`：显式运行时文件。
- `CODEX_RUNTIME_ROOT`：可选的 Codex runtime 根目录。
- `-RegistryPath` / `-StorePath`：测试或迁移时覆盖默认文件。

当前边界：桥只负责可靠调度记录、互斥、租约和诊断；真正的跨聊天投递仍须由具有会话工具的总控执行，并在投递后核验目标会话回执。
