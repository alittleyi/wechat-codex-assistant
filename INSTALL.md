# 安装与验证

## 前置条件

- Windows 10/11 与 PowerShell 5.1+
- OpenClaw 2026.10.2 或兼容版本
- 官方 Codex 插件与可用的 Codex 登录
- 腾讯微信 OpenClaw 频道插件
- Python、Node.js 与 FFmpeg；脚本也支持由 Codex 托管运行时解析
- Python 文件工作流依赖见 `requirements.txt`
- 已安装的 `ffmpeg-skill`（视频探测使用其受控脚本，不直接拼接 FFmpeg 命令）

## 配置顺序

1. 安装 OpenClaw，并用官方流程安装 Codex 与微信频道插件。
2. 运行 `openclaw channels add` 完成微信账号绑定；不要把令牌或二维码写进仓库。
3. 克隆仓库后运行 `scripts/initialize-workspace.ps1`，生成本地 `AGENTS.md` 和运行目录；已有文件不会被覆盖。
4. 为 `scripts/preflight.ps1` 解析到的 Python 安装依赖：`python -m pip install -r requirements.txt`。若使用 Codex 托管 Python，请对该解释器执行同一命令。
5. 运行 `scripts/preflight.ps1` 查看缺失前置；按官方流程补齐后再继续。
6. 运行 `openclaw gateway install`，再运行 `openclaw gateway status`。
7. 在工作区运行：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\release-self-test.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\self-test.ps1
```

`release-self-test.ps1` 验证发布包本身不含运行数据、执行合成回归，并在临时空目录连续初始化两次，核对目录白名单、幂等性和无凭据写入；`self-test.ps1` 验证已经配置好的真实实例，所以会检查 Gateway、Codex 聊天索引、FFmpeg 与本机回滚基线。

## 验收门槛

- 基础自测全部通过
- 高层工作流回归全部通过
- Gateway 本机监听且登录触发任务为 Running
- 微信真实完成：文字问答、图片入站、PDF 入站、小文件出站、停止与继续

如果系统策略阻止读取计划任务，使用有权限的 PowerShell 重新运行健康检查；不要把“unverified”解释成“已通过”。
