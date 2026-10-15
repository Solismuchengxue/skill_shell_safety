# PowerShell 与 Bash 安全执行

`powershell-bash-safety` 是一个 Codex Skill，用于减少 PowerShell、SSH、Bash、POSIX sh、archive、文件传输与 container 启动链中的跨平台执行错误。

它把源码解析、参数绑定、制品字节、远端解释器和真实运行拆成独立 gate，帮助在进入高风险运行前发现 parameter set、quoting、EOL、shebang、checksum、entrypoint 和 exit code 问题。

项目为什么存在、成功结果、范围与非目标见 [项目蓝图](docs/blueprint.md)。

## 使用方式

在适用任务中使用：

```text
$powershell-bash-safety
```

典型场景包括：

- PowerShell 调用 SSH、SCP、Docker、WSL 或 Linux shell；
- Windows 上生成的脚本或 archive 上传后在 Linux 失败；
- `bash` 与 `/bin/sh` dialect 混用；
- native command 的 argv、`$LASTEXITCODE` 或多层 quoting 不可靠；
- Compose、wrapper 与 image entrypoint 的主进程 owner 不唯一。
- 已授权 Windows → SSH → Linux/FNOS sudo 动作需要每次使用独立 WPF 遮蔽输入，且不能让密码进入 queued PTY、terminal history、argv、environment 或文件。

一次性 sudo 路径先生成 exact action digest，取得对应 action-time authorization 后，才在固定 PowerShell 7 STA session 中显示 `PasswordBox.SecurePassword` GUI。GUI 前后都会复核 destination、absolute target argv、SSH/helper、`known_hosts`、可选 identity metadata 与 `MaxOutputBytes`；任何漂移、cancel、mismatch、GUI/SSH 前置失败、输出超限或 protocol 不完整都停止，不回退到普通终端或持久 SecretStore。具体合同与示例见 [中文操作参考](skills/powershell-bash-safety/references/zh-CN.md#6-一次性-sudo-遮蔽输入)。

规范源码支持显式可选 `HostKeyAlias`，将已核对的安全 token 原样绑定到 digest、GUI 确认及 SSH argv，保留 `-F NUL` 下的 host-key 查询身份；未传入保持原合同。值域与停止条件见 [HostKeyAlias 合同](skills/powershell-bash-safety/references/zh-CN.md#显式-hostkeyalias)。

对话框采用 680×600 布局、折叠技术详情和滚动，支持绑定摘要的 `ActionTitle`/`ActionDescription`；第一框 Tab 到第二框，第二框 Enter 确认，Esc 取消。输入时提供非空/一致性反馈，只有两次非空且一致才允许确认；有误时留窗修正。不提供眼睛按钮。假口令交互预览命令见 [对话框说明](skills/powershell-bash-safety/references/zh-CN.md#原版对话框布局与键盘)。

## 项目结构

- `skills/powershell-bash-safety/`：权威 Skill package。
- `skills/powershell-bash-safety/scripts/Test-PowerShellSyntax.ps1`：官方 PowerShell AST Parser 的安全薄适配器，提供精确收集、计数、ReparsePoint、Text/Json 与稳定退出码。
- `skills/powershell-bash-safety/scripts/Test-ShellSyntax.ps1`：Bash/sh parser 的 backend-aware 薄适配器，提供 dialect、identity、path-domain、Text/Json 与条件式 ShellCheck。
- `skills/powershell-bash-safety/scripts/Invoke-MaskedSudoOverSsh.psm1`：action digest、WPF 双输入、结构化 SSH argv、短暂内存传输与三层结果编排。
- `skills/powershell-bash-safety/scripts/Invoke-MaskedSudoOverSsh.Remote.sh`：不保存密码的 remote FIFO protocol helper；把 sudo 与 target 输出、退出码分层，对每个流执行硬上限并精确清理工作根。
- `skills/powershell-bash-safety/references/windows-bootstrap.md`：缺少固定 PowerShell 7 入口时按需读取的一次性引导边界。
- `tests/Test-PowerShellSyntax.Tests.ps1`：使用 Pester 和系统临时目录 fixtures 的离线行为验证。
- `tests/Test-ShellSyntax.Tests.ps1`：覆盖 Bash/sh dialect、backend、identity、工具缺失和输出合同的 Pester fixtures。
- `tests/Test-ConsumerDepth.Tests.ps1`：离线验证消费者角色、授权深度、Target gate 与 portable package 引用边界。
- `tests/Test-MaskedSudoOverSsh.Tests.ps1`：使用 synthetic sentinel、fake sudo 与 target fixture 验证 GUI/identity gate、零泄漏、分层协议、状态文件 ownership、输出上限和 cleanup。
- `tests/Invoke-Pester.ps1`：断言 Pester expected/actual/failure count 的项目级 runner。
- `docs/blueprint.md`：项目意图、成功结果、范围、长期约束与更新触发的共享权威。
- `docs/consumer-forward-test-plan.md`：可提交的项目级测试证据；包含代表性 task reference，但不进入 portable Skill package。
- `DESIGN.md`：设计与 authority 边界。
- `docs/architecture.md`：多层执行模型和验证顺序。
- `DEVLOG.md`：本地踩坑与维护证据，Git ignored。
- `TODO.md`：本地当前行动，Git ignored。

## 当前限制

截至 2026-09-23，本机已按固定 commit `0467a97bc859b9b4e71fffe218ee29f823adc35f` 安装为独立普通目录，并通过新会话发现、加载和 8 文件一致性验收（`INSTALLED_LOAD_VERIFIED`）。它不随源码编辑、切分支或 pull 自动更新；加载验收不代表 SSH/sudo 真实运行通过。

GitHub `main` 已包含该 commit，但当日唯一 tag/Release `v1.0.0` 仍对应旧提交 `4f395835835ac35c8c51a6d52790e4aee7fc8b31`，不能用旧 Release 表示当前安装版本。固定制品身份、导出/验证、显式更新与回退流程见 [架构说明](docs/architecture.md#固定版本交付与更新回退)。

- Skill 只提供防错与验证方法，不授予远程写入、部署、服务中断、凭据读取或生产执行权限。
- parser PASS 不等于 package、transport 或 runtime PASS。
- 用户级已安装副本是独立 mirror；源码变化不会自动安装。
- PSScriptAnalyzer 是可选增强；不可用时明确 `NOT_RUN`，不由 syntax adapter 安装。Pester 与编辑器实时诊断都不替代官方 AST gate。
- Windows 正常流程固定调用 `C:\Program Files\PowerShell\7\pwsh.exe`；PowerShell 7、Starship、Pastel Powerline、NFM、Profile、PATH 与终端设置均是独立 action-time milestone，本 Skill 不自动执行这些变更。
- 默认 Fast 只验证受影响文件；Milestone 条件增加 lint/tests；Target 仅在发布、部署或明确目标兼容性需求时进入。Git Bash PASS 不是 Linux/FNOS/container PASS。
- 消费者角色不会自动扩大验证深度：实施者默认 Fast、按相关变化进入 Milestone；只读审查者不继承 fixture、Target 或运维执行权限。
- 一次性 sudo helper 不授予 action-time authorization，也不证明真实 GUI foreground、SSH authentication、sudo policy 或 target runtime；已有 Windows 本地 synthetic 与安装加载证据不能替代这些 `NOT_VERIFIED` 的 Target 层。
- GUI 只减少屏幕回显与意外 history 记录；值仍短暂存在当前用户进程内存并经 SSH encrypted channel 传输。需要 inherited stdin 的 target command 不受支持。
