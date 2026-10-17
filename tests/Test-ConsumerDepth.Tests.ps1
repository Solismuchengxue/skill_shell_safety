#requires -Version 7.0

$projectRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path
$planPath = Join-Path $projectRoot 'docs\consumer-forward-test-plan.md'
$portableRoot = Join-Path $projectRoot 'skills\shell-safety'
$powerShellAdapter = Join-Path $portableRoot 'scripts\Test-PowerShellSyntax.ps1'
$shellAdapter = Join-Path $portableRoot 'scripts\Test-ShellSyntax.ps1'
$planText = [IO.File]::ReadAllText($planPath)

function Get-ValidateSetValues {
    param(
        [Parameter(Mandatory)]
        [string]$LiteralPath,

        [Parameter(Mandatory)]
        [string]$ParameterName
    )

    $tokens = $null
    $parseErrors = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile($LiteralPath, [ref]$tokens, [ref]$parseErrors)
    $null = @($parseErrors).Count | Should Be 0

    $parameter = @($ast.ParamBlock.Parameters | Where-Object { $_.Name.VariablePath.UserPath -eq $ParameterName })
    $null = $parameter.Count | Should Be 1
    $validateSet = @($parameter[0].Attributes | Where-Object { $_.TypeName.Name -eq 'ValidateSet' })
    $null = $validateSet.Count | Should Be 1
    @($validateSet[0].PositionalArguments | ForEach-Object { $_.SafeGetValue().ToString() })
}

Describe 'Consumer role and authorization depth contract' {
    It 'records exactly the three designated generic consumer identifiers' {
        $identifiers = @(
            'runtime-implementer',
            'studio-os-implementer',
            'studio-os-read-only-reviewer'
        )
        foreach ($identifier in $identifiers) {
            $wrappedIdentifier = [char]96 + $identifier + [char]96
            ([regex]::Matches($planText, [regex]::Escape($wrappedIdentifier))).Count | Should Be 1
        }
    }

    It 'keeps internal task identities out of the portable package and public tracked payload' {
        $internalThreadPrefix = 'codex' + '://threads/'
        $clientThreadKey = 'client' + 'ThreadId'
        $personalUserPathPattern = '[A-Za-z]:' + '\\Users\\' + '[^\\\r\n]+'
        $departmentPathPattern = '[A-Za-z]:' + '\\[0-9]{2}_' + '[^\r\n]+'
        $portableText = @(Get-ChildItem -LiteralPath $portableRoot -Recurse -File | ForEach-Object {
            [IO.File]::ReadAllText($_.FullName)
        }) -join "`n"
        ($portableText -match [regex]::Escape($internalThreadPrefix)) | Should Be $false
        ($portableText -match [regex]::Escape($clientThreadKey)) | Should Be $false

        $trackedRelativePaths = @(& git -C $projectRoot ls-files)
        $gitExit = $LASTEXITCODE
        $gitExit | Should Be 0
        ($trackedRelativePaths.Count -gt 0) | Should Be $true
        $publicText = @($trackedRelativePaths | ForEach-Object {
            [IO.File]::ReadAllText((Join-Path $projectRoot $_))
        }) -join "`n"
        ($publicText -match [regex]::Escape($internalThreadPrefix)) | Should Be $false
        ($publicText -match [regex]::Escape($clientThreadKey)) | Should Be $false
        ($publicText -match $personalUserPathPattern) | Should Be $false
        ($publicText -match $departmentPathPattern) | Should Be $false
    }

    It 'maps the Runtime implementer to Fast by default and gates Target on project authority' {
        $planText | Should Match 'Runtime 实施者.*受影响脚本使用 Fast'
        $planText | Should Match '只有项目权威方对具体运行环境另行授权后'
    }

    It 'does not let the Studio OS implementer enter a target backend by invoking the Skill' {
        $planText | Should Match '不因调用 Skill 自动进入 WSL、FNOS、container 或远程运行'
        $planText | Should Match 'Git Bash `WINDOWS_LOCAL_COMPAT` 不得升级为目标 Linux PASS'
    }

    It 'keeps the reviewer read-only and excludes fixture tests and operational execution' {
        $planText | Should Match '当前 fixture-based Pester 不属于只读 reviewer 默认权限'
        $planText | Should Match '禁止：修改文件、安装工具、执行 fixture-based Pester、运维脚本或 Target backend'
    }

    It 'exposes only Fast and Milestone on the PowerShell syntax adapter' {
        $values = @(Get-ValidateSetValues -LiteralPath $powerShellAdapter -ParameterName 'Mode')
        ($values -join ',') | Should Be 'Fast,Milestone'
    }

    It 'exposes Target only through the Shell adapter with explicit WSL gates' {
        $modeValues = @(Get-ValidateSetValues -LiteralPath $shellAdapter -ParameterName 'Mode')
        ($modeValues -join ',') | Should Be 'Fast,Milestone,Target'
        $backendValues = @(Get-ValidateSetValues -LiteralPath $shellAdapter -ParameterName 'Backend')
        ($backendValues -join ',') | Should Be 'Auto,GitBash,WSL,Explicit'

        $shellText = [IO.File]::ReadAllText($shellAdapter)
        $shellText | Should Match "Mode -ne 'Target'"
        $shellText | Should Match 'WSL backend requires an explicit -WslDistribution'
    }

    It 'keeps MCP delivery and wakeup behavior outside the Shell safety claim' {
        $planText | Should Match 'MCP 消息审批、空回传和任务唤醒问题保持 `UNKNOWN`/外部边界'
    }
}
