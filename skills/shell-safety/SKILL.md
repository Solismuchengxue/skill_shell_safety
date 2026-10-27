---
name: shell-safety
description: Use when PowerShell, SSH, Bash, or POSIX sh chains risk parameter, quoting, interpreter, byte, transport, exit-code, or authorized interactive sudo-input failures across platforms.
---

# Shell Safety / Shell 安全

## 三级模式

Gate 是条件式层级，不是每次全部执行，也不是拆成多张用户审批卡。选择满足当前风险的最小模式，并只检查本次受影响范围。

### 日常快速模式（默认）

- PowerShell 使用固定 PowerShell 7 与官方 AST Parser；Bash/sh 使用身份明确的本地 interpreter 执行 `-n`。
- 同一个薄适配器顺手完成 UTF-8、LF、BOM、NUL、样本数、dialect 和 interpreter identity 检查；不执行目标脚本。
- 用户只接收一次 PASS/FAIL 摘要。

### 里程碑模式

- 仍只检查相关范围。PowerShell 增加已可用的 PSScriptAnalyzer；仅有相关逻辑测试时运行 Pester。
- Bash/sh 增加已可用的 ShellCheck；shfmt 只是可选格式工具，不是默认硬门。
- 工具缺失写 `NOT_RUN`/`NOT_VERIFIED`，验证过程不自动安装。

### 目标环境模式

- 只在部署、发布、真实运行前，或明确要求 Linux/FNOS/container 兼容性时，用目标 WSL distribution、container 或主机的真实 interpreter 复核。
- Git Bash PASS 只证明 Windows 本地兼容层解析通过，不能冒充目标 Linux 证据。
- WSL、Docker、远程主机、部署和真实运行分别受 action-time 授权；本 Skill 不自动扩大权限。

## 一次性 sudo 遮蔽输入

仅当用户已选择该方式，且具体 Windows → SSH → Linux/FNOS sudo 动作已经取得 action-time authorization 时，才使用 [Invoke-MaskedSudoOverSsh.psm1](scripts/Invoke-MaskedSudoOverSsh.psm1)。先用 `New-SolisSudoActionDigest` 冻结 authorization ID、destination、absolute target argv、`known_hosts`、可选 identity metadata、SSH/helper identity、timeout 与 `MaxOutputBytes`；执行时必须把同一 digest 传给 `Invoke-SolisMaskedSudoOverSsh`。

- 只接受固定 PowerShell 7、STA、Windows interactive desktop 与 WPF `PasswordBox.SecurePassword`；每次动作显示独立 topmost GUI。queued/未聚焦 PTY、普通终端、`Read-Host` 或 `open_in_codex` 都不是密码输入面。
- 密码不进入 argv、environment、stdout、stderr、日志、PSReadLine 或文件。实现不构造完整 plaintext managed string；从 BSTR 填充可清理 `char[]`/UTF-8 `byte[]`，直接向 SSH stdin `BaseStream` 写入 payload 与单独 LF，并在各路径清理 buffers、BSTR 与 `SecureString`。
- SSH 使用结构化 `ArgumentList`、禁用 PTY 与 SSH interactive password fallback；remote helper 通过 `sudo -S` 读取这一行，target stdin 固定为 `/dev/null`，并用内存/FIFO protocol 分层返回 SSH、sudo 与 target 的 exit code/stdout/stderr。non-secret target status 在 sudo 前由 outer SSH user 创建，不依赖 root 新建 regular file。
- 若已核对的 SSH 配置要求 `HostKeyAlias`，调用方须向两个公开入口显式传入同一值；模块不解析配置。安全 token 原样绑定到 digest、GUI 确认和单独 `-o HostKeyAlias=...`，因此 `-F NUL` 不会丢弃它。未传入保留原 digest/argv；非法值或 alias 漂移在 GUI/SSH 启动前失败，完整值域见中文操作参考。
- 可选 `ActionTitle`、`ActionDescription` 是 non-secret 纯文本，须在生成 digest 前加入同一 action，并原样传给执行入口；不从标题构造代码，也不由消费方 AST 改写窗口。原版采用 680×600 固定布局、默认折叠技术详情（180 高滚动区）及外层滚动；第一框通过 Tab 到第二框，仅第二框 Enter 复用点击确认路径，Esc 取消。初始不报错；输入变化时以 SecurePassword 临时比较，非空且一致才允许确认，空值/不一致留窗修正；最终仍走原安全校验。按用户决定不提供眼睛显示，不改变无完整明文字符串合同。
- `MaxOutputBytes` 默认 `1048576`、允许 `1..16777216`，对四个 remote streams 分别形成硬上限；Windows SSH transport 另以派生的 stdout 上限和同值 stderr 上限并发读取。任一层超限都 fail closed 为 `OUTPUT_LIMIT_EXCEEDED`，不得无界缓冲。
- cancel、empty、mismatch、GUI/session 不可用、前置文件/ReparsePoint、action drift、SSH start/timeout、输出超限或 remote protocol 不完整时 fail closed；不回退到 echo pipe、argv/env、plaintext temp file、DPAPI、SecretStore 或普通终端，也不自动 retry。
- 该方式只减少屏幕回显与意外历史记录；值仍短暂存在当前用户进程内存并经 SSH 加密通道传输。真实 SSH、sudo policy、目标命令和 GUI 可见性仍需在获授权的 Target 里分别验证。

## Windows 双击交互启动

用户希望双击 `.ps1` 或以 `.ps1` 为入口的交互工具时，优先推荐 `.lnk` 直接启动经核验的 PowerShell 7；保留原 PS1、签名与 Verifier 身份，不经过 cmd/bat。普通消费项目遵守其明确的解释器绑定；未绑定时有界发现可用入口，不把本仓维护路径泛化为唯一合法位置。

入口选择、`TargetPath`/`Arguments`/`WorkingDirectory`/`WindowStyle`、覆盖前恢复副本及配置/启动分层验收，见 [Windows 双击交互启动合同](references/zh-CN.md#7-windows-双击交互启动)。本规则不强套普通命令行、计划任务或原生 exe，也不改变下面的固定安全链。

## 选择与边界

- 本 Skill 维护验证器与一次性 sudo 安全链在 Windows 固定使用 `C:\Program Files\PowerShell\7\pwsh.exe`；缺失时读取 [Windows 一次性引导](references/windows-bootstrap.md)并停止，不回退到 `powershell.exe`。普通消费项目的双击入口按上节合同处理。
- PowerShell 使用 [Test-PowerShellSyntax.ps1](scripts/Test-PowerShellSyntax.ps1)，Shell 使用 [Test-ShellSyntax.ps1](scripts/Test-ShellSyntax.ps1)。两者都只是官方/成熟 parser 的安全编排器，不自研分析算法。
- parser、lint、target compatibility 与 runtime 是不同结论。前一层 PASS 不替代后一层；真实变更、安装、凭据、服务中断和生产执行均需独立授权。

命令、输入输出、dialect/backend、一次性 sudo 调用合同与工具状态见 [中文操作参考](references/zh-CN.md)。
