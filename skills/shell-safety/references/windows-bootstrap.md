# Windows PowerShell 7 一次性引导

仅在 Windows 缺少预期 PowerShell 7，或用户明确要求初始化 Windows shell 体验时读取本文件。这里定义检查与授权边界，不自动安装或修改机器。

## 固定运行入口

正常 Windows 流程使用：

```text
C:\Program Files\PowerShell\7\pwsh.exe
```

先只读确认该路径是文件，再用它执行 `-NoLogo -NoProfile -Command '$PSVersionTable.PSVersion.ToString()'` 并立即检查退出码。不要把 `powershell.exe`、PATH 中的同名命令或 Windows PowerShell 5.1 当成等价入口。

目标文件缺失或版本小于 7 时，停止后续 Skill 执行并形成一次性 bootstrap 方案。PowerShell 当前发布渠道、安装包类型、MSI/Wix 行为和未来格式都属于 action-time 事实；实际执行前必须从当时的权威来源重新确认，不能把某个版本、URL、包格式或 installer 参数永久写死在 Skill 中。

## 独立 action-time milestones

以下各项分别需要执行时授权、当前事实检查、回滚点和验收结果。前一项获批不自动授权后一项：

1. 获取并安装 PowerShell 7，使固定目标路径可用；
2. 可选安装 Starship；
3. 可选配置 Pastel Powerline 外观；
4. 可选安装 JetBrainsMono Nerd Font Mono（NFM）；
5. 可选初始化 PowerShell 7 Profile；
6. 可选设置终端默认 Profile 或对单次命令使用局部 PATH。

这些外观与交互配置不是 Shell 安全检查的前置条件，也不得成为每次 Skill 调用的自动副作用。

`Test-PowerShellSyntax.ps1` 不负责安装或管理这些组件、PATH、Profile、字体或终端设置；syntax adapter 与 Windows Shell Bootstrap 是独立模式。

## 保留系统边界

- 不永久删除、替换或破坏 Windows PowerShell 5.1 系统组件。
- 不为强制 PowerShell 7 而永久重写系统 PATH；正常流程直接调用固定绝对路径。
- 若某一工具只能通过 PATH 发现，优先使用命令局部 PATH；永久用户或系统 PATH 仍需独立授权。
- 修改终端默认 Profile、PowerShell Profile、字体或主题前，先定位精确文件/setting、保存可恢复副本并确认当前 owner。
- Profile 初始化必须幂等，不输出 secret，不把下载、安装或环境修改隐藏在普通 shell 启动中。

## 引导完成验收

至少分别记录：目标路径、可执行文件 identity、版本命令退出码和版本结果。可选组件只报告实际完成的项目；未安装或未验证的 Starship、Pastel Powerline、NFM、Profile、PATH 与终端配置保持 `NOT_VERIFIED`。

引导完成只证明本机 PowerShell 入口可用，不证明任何被检查脚本的 parser、parameter binding、runtime 或远程执行安全。
