# AGENTS.md

本仓库维护一个独立的跨平台 Shell 安全执行 Skill。权威 package 位于 `skills/shell-safety/`。

## 项目边界

- 项目根使用下划线命名；标准 Skill identifier 与 package 目录保持 `shell-safety`。
- `skills/shell-safety/` 是权威源码；用户级安装目录只是独立 deployment mirror。
- 源码变更不自动授权覆盖、重装、重连或删除安装镜像。
- 本项目已通过 `$swift-cycle` v1.3.0 完成首次采用；持久绑定只作用于本项目，不修改或复制 Swift Cycle，也不修改相邻仓库及其工作树。
- 本 Skill 只提供 PowerShell、SSH、Bash、POSIX sh、archive、transport 与 container 执行链的防错和验证方法，不扩大远程写入、部署、服务中断或凭据权限。

## 项目任务治理

- 当前项目只保留一个负责人 L1；旧固定审查者已退役。
- 后续独立审查不作为固定项目角色，仅在用户、部长或项目规则明确要求时按需建立。
- 该角色调整不自动授予 Git push、发布、部署、运行态、凭据、费用或删除权限；这些动作继续遵守各自的 action-time authorization。

## 修改规则

- 修改前阅读 `docs/blueprint.md`、`README.md`、`DESIGN.md`、`docs/architecture.md`、当前 `SKILL.md` 及本文件。
- 保留用户已有改动，只修改当前请求需要的文件。
- 中文为主要说明语言；命令、API、status、interpreter、parameter set 等专用词保留 English。
- 已确认且可复用的失败经验先写入本地 `DEVLOG.md`；当前行动与 blocker 写入本地 `TODO.md`。
- 不把密码、Credential、业务正文、完整敏感日志或未确认推测写入文档。
- 架构、authority、source/deployment 边界变化时同步更新 `DESIGN.md` 与 `docs/architecture.md`。

## Swift Cycle

- 本项目已采用 `$swift-cycle`。处理后续项目任务时必须加载该 Skill，由 Agent 在后台判断阶段、选择最小文档档位并维护受影响的唯一权威，不向用户展示模式菜单。
- `docs/blueprint.md` 是项目意图权威；README、DESIGN、AGENTS、已有长期 docs 与 ignored TODO/DEVLOG 按各自职责复用，不机械生成完整文档树。
- 普通文档同步、Mermaid、表格、TODO 和 DEVLOG 维护属于已批准任务包内的后台步骤；里程碑关闭时自动收敛受影响共享文档和本地记录。
- 只有出现新的实质授权、目标或架构实质改变、唯一权威无法安全判断，或证据否定当前计划时，才请求决定。
- Swift Cycle adoption 与文档维护不传递删除、Git 后续动作、安装、联网、发布、部署、凭据、服务中断、真实消费者切换或 WSL/FNOS/container/远程运行权限；这些动作仍分别需要 action-time authorization。

## PowerShell 维护硬门禁

- Windows 上统一使用 `C:\Program Files\PowerShell\7\pwsh.exe`；固定路径缺失时停止并走独立 bootstrap gate，不使用 `powershell.exe` 替代。
- 多行或非简单 PowerShell 逻辑先写入 `.ps1`、`.psm1` 或 `.psd1`，再由固定 `pwsh.exe -File` 调用。
- 创建或修改上述文件后，使用 `skills/shell-safety/scripts/Test-PowerShellSyntax.ps1` 验证实际受影响文件；不得依赖用户级 `.codex\tools` 副本。
- 日常默认只检查本次受影响文件；不因普通修改自动扫描全仓或执行全部 parser/lint/target/runtime gate。
- 单文件断言一个样本；目录或 path list 批量验证必须传入权威 `ExpectedCount`，并核对 expected、actual 和 failures。
- canonical script 只编排官方 `Parser.ParseFile`；PSScriptAnalyzer 缺失时保持 `NOT_RUN`，不得自动安装。Pester 只验证 adapter 行为，不替代 AST gate。
- 完成报告必须给出实际验证目标、命令退出码和 PASS/FAIL；没有 exit `0` 的实际结果，不得声称 PowerShell 修改完成。
- 语法验证不得通过执行目标脚本完成；parser PASS 不等于 parameter binding、runtime 或环境变更 PASS。

## 验证

- 对 `skills/shell-safety/` 运行 OpenAI `quick_validate.py`。
- PowerShell 示例使用 AST parser；Bash 与 POSIX sh 示例分别由绑定的目标 interpreter 执行 `-n` 检查。
- adapter 行为测试使用已可用的 Pester；检查 Text/Json、稳定退出码、ReparsePoint、空集合和 count mismatch，并断言非空 test count。
- Shell 使用 `Test-ShellSyntax.ps1`；Fast 只运行已绑定 backend 的 `bash -n`/`sh -n`，Milestone 才探测 ShellCheck，Target 才进入经授权的 WSL/container/主机解释器。
- 所有批量检查同时验证 expected sample count、actual count 和 failure count；空集合不能算 PASS。
- 检查 `SKILL.md` 引用、UTF-8、BOM、尾空白和最终 diff。
- 安装同步时比较 source 与 mirror 的 relative file set、bytes 和 SHA-256；不得使用语义等价替代 byte-exact。
- 未实际执行的检查保持 `NOT_VERIFIED`。

## Git 与发布

- Git init、add、commit、push、tag、Release、安装和镜像覆盖均为独立动作，不由普通源码修改授权自动包含。
- 暂存必须使用精确 literal paths；禁止 `git add .`、`git add -A`、目录暂存或宽 glob。
