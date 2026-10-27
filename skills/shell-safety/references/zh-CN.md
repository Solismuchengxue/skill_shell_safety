# PowerShell 与 Shell 高效验证参考

本文件记录两个薄适配器、一次性 sudo 输入及 Windows 双击启动的操作合同。PowerShell/PSScriptAnalyzer/Pester/ShellCheck/shfmt/WSL 的第三方手册不复制到 package。

## 1. 模式选择

| 模式 | 默认范围 | PowerShell | Bash/sh | 证据边界 |
| --- | --- | --- | --- | --- |
| `Fast` | 本次受影响文件 | 官方 AST | 已识别本地 backend 的 `-n` | 本地 parser compatibility |
| `Milestone` | 相关模块/里程碑 | AST + 可用 PSScriptAnalyzer；相关时 Pester | `-n` + 可用 ShellCheck | parser + 可选 lint |
| `Target` | 明确目标环境 | 由目标任务另行绑定 | WSL/目标 container/主机真实 interpreter | 指定目标 compatibility |

Gate 是内部条件式层级。Fast 不是“少做安全检查”，而是把必要的 bytes、count、dialect 和 identity 合并到一次 adapter 运行；Milestone 与 Target 只在风险触发时升级。

## 2. PowerShell adapter

`scripts/Test-PowerShellSyntax.ps1` 只收集 `.ps1/.psm1/.psd1`，验证 UTF-8 无 BOM、LF、无 NUL、样本数和固定 PowerShell 7 identity，再调用官方 `System.Management.Automation.Language.Parser.ParseFile`。它不执行目标脚本，也不依赖用户级 `.codex\tools` 副本。

```powershell
$adapter = Join-Path $SkillRoot 'scripts\Test-PowerShellSyntax.ps1'
& 'C:\Program Files\PowerShell\7\pwsh.exe' -NoLogo -NoProfile `
    -ExecutionPolicy Bypass -File $adapter `
    -LiteralPath $ChangedFile -Mode Fast
$adapterExit = $LASTEXITCODE
```

目录或多根 path list 必须提供正数 `ExpectedCount`；多根使用 `-LiteralPathList`，每行一个 literal path。`-OutputFormat Json` 提供与 Text 相同的结构化字段。

`Milestone` 才探测 PSScriptAnalyzer。已存在则通过 `ScriptDefinition` 静态检查；缺失为 `NOT_RUN/TOOL_UNAVAILABLE`，Fast 为 `NOT_RUN/MODE_FAST`。Pester 只在相关 adapter/逻辑有测试时由项目 runner 调用，不替代 AST。

## 3. Shell adapter

`scripts/Test-ShellSyntax.ps1` 收集 `.bash/.sh` 与有 shell shebang 的无扩展名文件，验证 UTF-8 无 BOM、LF、无 NUL、样本数，再按文件调用 `bash -n` 或 `sh -n`。它不会执行目标脚本。

本地 Fast：

```powershell
$adapter = Join-Path $SkillRoot 'scripts\Test-ShellSyntax.ps1'
& 'C:\Program Files\PowerShell\7\pwsh.exe' -NoLogo -NoProfile `
    -ExecutionPolicy Bypass -File $adapter `
    -LiteralPath $ChangedShellFile `
    -Dialect Auto -Backend Auto -Mode Fast
$adapterExit = $LASTEXITCODE
```

关键选择：

- `Dialect Auto` 只接受明确的 `bash`/`sh` shebang，或把 `.bash` 唯一判为 Bash；无 shebang 的 `.sh` 保持歧义并 fail closed。
- `Backend Auto` 只选择从实际 `git.exe` root 证明且唯一的 Git Bash；不取 PATH 中第一个 `bash.exe`。
- Git Bash 使用同一 root 的 `cygpath.exe` 转换 Windows/MSYS path domain，并报告 bash/sh 绝对路径与版本。
- System32/WindowsApps `bash.exe` 是 WSL launcher，不是 shell interpreter；MSYS2 不是 Git Bash，Auto 发现时要求 `Backend Explicit`。
- `Backend WSL` 只允许 `Mode Target`，并要求显式 `WslDistribution`；调用会启动目标环境，因此仍需 action-time 授权。
- `Backend Explicit` 需要绝对 `InterpreterPath` 和显式 Bash/Sh dialect。

`Milestone` 才探测 ShellCheck。缺失为 `NOT_RUN/TOOL_UNAVAILABLE`；issues 与 parser errors 使已启用里程碑 gate FAIL。shfmt 不自动运行，也不是默认 gate。

## 4. 统一输出

两个 adapter 的 Text 是默认人类摘要，Json 用于机器消费。共同字段包括：

- `discovered/validated/skipped`；
- `encoding_errors/parse_errors`；
- mode、result、exit code、expected count；
- 实际 interpreter/backend identity 和可选 lint status。

exit `0` 表示当前已启用 gate 通过；exit `1` 表示 parser 或已启用 lint 发现问题；exit `2` 表示输入、字节、count、identity、读取或工具执行前置失败。空集合不能 PASS。

PowerShell adapter 报告 `psscriptanalyzer_status/reason`；Shell adapter额外报告 `backend/evidence_scope/dialects/interpreters/shellcheck_status/reason`。Fast 的 Git Bash 结果必须保留 `WINDOWS_LOCAL_COMPAT`，不能重标为目标 Linux PASS。

## 5. 与运行层的边界

Parser 与 lint 不证明 parameter binding、archive bytes、transport、container entrypoint、remote identity 或 runtime health。只有实际任务触发这些风险时才增加对应检查；WSL/Docker/远程连接、安装、部署、rollback、凭据和服务中断仍分别请求执行时授权。

## 6. 一次性 sudo 遮蔽输入

只在具体 action 已获授权、用户明确选择 GUI 输入且 Windows interactive desktop 可用时调用。先从固定 PowerShell 7 启动 STA session；密码只在随后出现的 WPF 窗口中输入两次，不在 terminal、chat 或 history 中输入：

```powershell
& 'C:\Program Files\PowerShell\7\pwsh.exe' -NoLogo -NoProfile -Sta
```

在该 STA session 中，用同一组 non-secret action parameters 先生成 digest，取得该 digest 对应的 action-time authorization 后再执行：

```powershell
$modulePath = Join-Path $SkillRoot 'scripts\Invoke-MaskedSudoOverSsh.psm1'
Import-Module -Name $modulePath -Force

$action = @{
    AuthorizationId = 'approved-action-001'
    HostName = 'server.example'
    UserName = 'operator'
    Port = 22
    TargetCommand = '/usr/bin/id'
    TargetArgument = @('-u')
    KnownHostsFile = Join-Path $env:USERPROFILE '.ssh\known_hosts'
    MaxOutputBytes = 1048576
}
$digest = New-SolisSudoActionDigest @action
# 在获得该 digest 对应的 action-time authorization 后：
$result = Invoke-SolisMaskedSudoOverSsh @action -ExpectedActionDigest $digest
```

`TargetCommand` 必须是 absolute POSIX path；target 不得需要 inherited stdin。`MaxOutputBytes` 默认 `1048576`、范围 `1..16777216`，是 action digest 的一部分，并分别限制 sudo/target stdout/stderr；Windows transport 也使用有界并发读取。任何输出超限都返回 `ErrorLayer=OutputLimit`、`FailureCode=OUTPUT_LIMIT_EXCEEDED`。module 在 GUI 前后两次校验 action identity，并固定 `BatchMode=yes`、`StrictHostKeyChecking=yes`、`RequestTTY=no`、`PasswordAuthentication=no`。SSH/sudo/target 结果只保存在返回对象的 `Ssh`、`Sudo`、`Target` 三层中；调用方若另行持久化结果，必须先按目标项目的数据与日志规则脱敏。

GUI cancel、MTA、non-Windows、session 0、WPF 不可用、helper/SSH/known_hosts/identity 前置失败、digest 漂移、输出超限或 protocol 不完整均直接失败。输入前的非空/一致性验证见下文。没有 console、PTY、DPAPI、SecretStore 或 plaintext file fallback，也没有自动 retry。

### 显式 HostKeyAlias

`New-SolisSudoActionDigest` 与 `Invoke-SolisMaskedSudoOverSsh` 均支持可选 `-HostKeyAlias`。只有已核对配置要求此字段时，才把对应精确值加入同一 `$action` 后重新生成并批准 digest。模块保持 `-F NUL`，不读取或修改 SSH 配置，不推导 alias、ProxyJump 或认证方式。

- 值域是 1..253 个 ASCII 字符；首字符为字母/数字，后续仅允许字母、数字、`.`、`_`、`-`（`\A[A-Za-z0-9][A-Za-z0-9._-]{0,252}\z`）。这是保守的 module token 合同，并非 OpenSSH 全部值域。禁止 CR/LF/NUL、空白、引号、路径/option/argument 分隔符、空值和非 ASCII；显式空值或非法值抛出 `SSH_HOST_KEY_ALIAS_INVALID`。
- 不 trim、不改变大小写、不转换或自动填入 host name。显式值追加为 action record 的 `host_key_alias`，进入摘要与 GUI 确认；SSH `ArgumentList` 仅加入一组独立 `'-o', 'HostKeyAlias=<精确值>'`。
- 缺省不增加 record 字段、GUI 字段或 argv option，保持原 schema 与无 alias digest。添加、删除或改变 alias 必须重新冻结授权；沿用旧 digest 抛出 `ACTION_IDENTITY_DRIFT`，在 WPF/采密/启动前停止。GUI 后仍执行既有摘要复核和 SecureString 清理。
- `StrictHostKeyChecking=yes` 与显式 `UserKnownHostsFile` 保持不变。源码支持不代表 installed consumer 已更新，也不证明真实 GUI/SSH/sudo 运行。

### 原版对话框布局与键盘

两个公开入口均接受可选 `ActionTitle`（1..128 字符，不能全为空白）及 `ActionDescription`（0..512 字符，非空时不能全为空白）。二者拒绝 CR/LF/NUL，支持中文和普通引号，按 WPF `Text` 显示，不执行文本或拼接脚本。只放 non-secret 动作说明；真实目标仍从已绑定的 host/user/port 生成并常显。

调用方如需自定义，应先在 `$action` 中加入 `ActionTitle`、`ActionDescription`，再生成和批准 digest；执行时传同一组参数。显式字段原样追加为 `action_title`、`action_description`，修改或删除使旧摘要失效。省略两参数时不增加字段，保持原 digest；默认标题为“仅为下列已授权动作输入本次 sudo 密码”，默认不增加动作说明。不要继续从 AST 提取函数或用字符串替换 UI。

原版沿用已确认的 NVENC 布局：宽 680、高 600（WPF DIP）、`SizeToContent.Manual`、默认折叠技术详情、详情 `MaxHeight=180` 滚动区，以及外层滚动。当前不自动收缩固定高度；后续紧凑化为候选。

- 第一框不绑定 Enter；用原生 Tab 到第二框，没有全局默认确认按钮。
- 第二框 Enter 和按钮点击共用一次 `Resolve-SecureInputPair` 路径；忽略按键重复，并阻止重复确认。Esc 或取消按钮取消。
- 初始反馈为空、确认禁用；两框输入变化时复用 SecurePassword 比较：任一为空显示“请填写两次密码”，不一致显示“两次输入不一致”，一致显示“两次输入一致”并启用确认。临时安全对象及时释放，前台校验不保留 secret 副本。
- 空值/不一致时点击或第二框 Enter 均不关闭、不执行，允许在原窗口改正；改回不一致会重新禁用确认。通过前台校验后仍执行最终 `Resolve-SecureInputPair`；成功后继续既有摘要复核与 secret 清理。Esc、取消和关闭窗口均取消。这是执行前的输入修正，不是 SSH/sudo 失败后自动重试。
- 按用户决定不添加眼睛按钮；继续使用 WPF PasswordBox.SecurePassword，不构造完整明文字符串，也不复制 `.Password` 到 TextBox 或 clipboard。

仅本仓库开发预览可运行下列命令（在项目根执行）：

```powershell
& 'C:\Program Files\PowerShell\7\pwsh.exe' -NoLogo -NoProfile -Sta `
    -File tests/fixtures/Invoke-MaskedDialogPreview.ps1 -Scenario Manual
```

这是只构造 UI 的假口令预览，不走公开执行入口，不调用 SSH/sudo；只输入虚构口令。可在第一框输入 `SYNTHETIC-ONLY`，Tab 到第二框先输入不同值观察禁用和留窗，再改为同值后 Enter；Esc 取消。测试 fixture 不属于 portable package，也不代表已安装版本。自动 `Layout`、`FirstEnter`、`Tab`、`SecondEnter`、`Click`、`Mismatch`、`Empty`、`Escape`、`DoubleConfirm`、`CorrectThenEnter`、`InvalidateAfterMatch`、`CloseCancel` scenarios 使用固定 synthetic 输入并自动关窗。

## 7. Windows 双击交互启动

仅当用户希望双击 `.ps1` 或以 `.ps1` 为入口的交互工具时，优先推荐 `.lnk → PowerShell 7 → PS1`。这是普通消费项目的启动建议，不是新启动器框架；不强套普通命令行、计划任务或原生 exe。本 Skill 自带验证器及一次性 sudo 链继续遵守固定入口合同。

### 选择并核验解释器

- 已有明确路径/版本绑定时遵守绑定，不能因固定位置缺失就换成另一个版本；绑定失效或与请求冲突时报告并澄清。其他可用版本只能作为候选，不能默默替代。合法绑定可以在非 C 盘。
- 未绑定时，依次检查用户指定候选、项目已有候选、PATH 解析出的 Application 入口及标准安装位置。标准位置有界检查当前机器的 Program Files 下 `PowerShell/7/pwsh.exe` 及用户明确给出的安装根，不递归扫描全盘或所有用户目录。优先沿用已验证的 PATH 默认入口，不追逐最高版本或主动改选预览版；多个候选仍无法唯一绑定时一次性澄清。
- 先核对候选是可读取的真实可执行文件，再用不加载 Profile 的只读版本探针核验实际进程绝对路径、PowerShell 7 版本和退出码。可使用固定、简短的 `-Command` 版本/进程路径查询，不能运行目标 PS1 来探测。函数、alias、包装脚本或未解析的 App Execution Alias 不能直接充当最终 TargetPath。
- 一个路径不存在不等于未安装；已检查范围内没有可用版本时，如实列出范围并提示安装 PowerShell 7。权限拒绝、文件身份不明或探针失败为 `NOT_VERIFIED`，不能断言未安装。未经授权不自动安装，也不静默回退到 Windows PowerShell 5.1。

### 快捷方式合同与示例

`TargetPath` 仅放核验后的 exe 绝对路径，不放整条命令或额外包裹引号。`Arguments` 默认 `-NoProfile -File "脚本绝对路径"`；宿主参数（如明确要求的 `-Sta`）在 `-File` 前，脚本参数在 PS1 路径后。路径和值分别按 Windows 命令行及 `pwsh -File` 规则引用，不把用户数据写成 PowerShell 表达式；复杂引号/数组参数不能靠猜测拼接，保留既有参数合同，必要时报告无法直接表达。

以下假设各路径和 STA 要求均已核验，仅示范字段，不表示创建或启动业务：

```text
TargetPath: D:\工具 空间\pwsh.exe
Arguments: -NoProfile -Sta -File "D:\示例 项目\交互工具.ps1" -InputPath "D:\输入 空间\数据.txt"
WorkingDirectory: D:\示例 项目
WindowStyle: 1 (正常可见)
```

WorkingDirectory 沿用已知项目约定；没有约定时采用 PS1 所在目录。交互窗口默认正常可见，不默认隐藏/最小化。若脚本已有明确的 Profile 或宿主要求与默认参数冲突，先报告，不改 PS1 或全局 Profile 来掩盖依赖。不生成或调用 cmd/bat、不使用 cmd 中转、不构造复杂嵌套 `-Command`；不默认添加提权、Bypass、NoExit，不改文件关联、PATH、执行策略或权限。已有且获授权的提权逻辑照常保留，不新增提权入口。

### 保存、恢复与验收

- 优先保留原 PS1，核对其 hash/签名/Verifier 身份不变。同名 `.lnk` 存在但没有覆盖授权时保留旧对象并报告冲突；已有更新授权时不重复逐步请批，覆盖前先保留并核验一份可恢复的旧 `.lnk`，备份失败就停止，不覆盖。
- 保存后重新打开 `.lnk`，逐项比较 TargetPath、Arguments、WorkingDirectory、WindowStyle，不能以 COM Save 未报错代替回读。明确告诉用户双击哪个快捷方式，以及旧快捷方式如何恢复。
- 配置核验通过只证明入口已保存且字段一致。未经授权不启动业务程序；实际启动、参数绑定和业务成功分别报告，未运行保持 `NOT_RUN`/`NOT_VERIFIED`。不增加重复审批，也不扩大既有动作授权。
- 推荐话术：“建议用快捷方式直接启动已核验的 PowerShell 7，保留原 PS1，不经 cmd。入口已保存并回读，请双击指定的 `.lnk`；本次未自动启动，实际运行尚未验证。”只建议而未创建时，不使用“已保存并回读”。

参数语义见 [Microsoft pwsh 文档](https://learn.microsoft.com/en-us/powershell/module/microsoft.powershell.core/about/about_pwsh)，字段示例见 [Windows Script Host 快捷方式文档](https://learn.microsoft.com/en-us/troubleshoot/windows-client/admin-development/create-desktop-shortcut-with-wsh)。
