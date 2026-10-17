#requires -Version 7.0

[CmdletBinding(DefaultParameterSetName = 'LiteralPath')]
param(
    [Parameter(Mandatory, Position = 0, ParameterSetName = 'LiteralPath')]
    [Alias('Path')]
    [ValidateNotNullOrEmpty()]
    [string[]]$LiteralPath,

    [Parameter(Mandatory, ParameterSetName = 'LiteralPathList')]
    [ValidateNotNullOrEmpty()]
    [string]$LiteralPathList,

    [Parameter()]
    [int]$ExpectedCount,

    [Parameter()]
    [ValidateSet('Text', 'Json')]
    [string]$OutputFormat = 'Text',

    [Parameter()]
    [ValidateSet('Fast', 'Milestone')]
    [string]$Mode = 'Fast'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$validExtensions = @('.ps1', '.psm1', '.psd1')
$skipDirectoryNames = @('.git', '.hg', '.svn', 'node_modules', '.venv', 'venv', '__pycache__', 'bin', 'obj', 'dist', 'build', 'vendor', 'packages', 'coverage')
$expectedCountWasSupplied = $PSBoundParameters.ContainsKey('ExpectedCount')
$expectedForSummary = if ($expectedCountWasSupplied) { $ExpectedCount } else { $null }
$discoveredCount = 0
$validatedCount = 0
$skippedCount = 0
$parseDiagnostics = @()
$encodingDiagnostics = @()
$analyzerStatus = 'NOT_RUN'
$analyzerReason = 'MODE_FAST'
$analyzerDiagnostics = @()
$interpreterPath = $null
$interpreterVersion = $null

function Test-ReparsePoint {
    param([Parameter(Mandatory)][System.IO.FileSystemInfo]$Item)
    return [bool]($Item.Attributes -band [System.IO.FileAttributes]::ReparsePoint)
}

function Complete-Run {
    param(
        [Parameter(Mandatory)][ValidateSet('PASS', 'FAIL')][string]$Result,
        [Parameter(Mandatory)][int]$ExitCode,
        [Parameter()][string]$Message
    )

    $summary = [ordered]@{
        schema_version               = 1
        mode                         = $Mode
        result                       = $Result
        exit_code                    = $ExitCode
        expected_count               = $expectedForSummary
        discovered                   = $discoveredCount
        validated                    = $validatedCount
        skipped                      = $skippedCount
        encoding_errors              = @($encodingDiagnostics).Count
        parse_errors                 = @($parseDiagnostics).Count
        interpreter_path             = $interpreterPath
        interpreter_version          = $interpreterVersion
        psscriptanalyzer_status      = $analyzerStatus
        psscriptanalyzer_reason      = $analyzerReason
        psscriptanalyzer_issue_count = @($analyzerDiagnostics).Count
        message                      = $Message
        encoding_diagnostics         = @($encodingDiagnostics)
        parse_diagnostics            = @($parseDiagnostics)
        psscriptanalyzer_diagnostics = @($analyzerDiagnostics)
    }

    if ($OutputFormat -eq 'Json') {
        Write-Output ($summary | ConvertTo-Json -Depth 6 -Compress)
        exit $ExitCode
    }

    if ($Message) {
        [Console]::Error.WriteLine($Message)
    }

    foreach ($diagnostic in @($parseDiagnostics)) {
        [Console]::Error.WriteLine(('{0}:{1}:{2}: [{3}] {4}' -f $diagnostic.file, $diagnostic.line, $diagnostic.column, $diagnostic.error_id, $diagnostic.message))
    }

    foreach ($diagnostic in @($encodingDiagnostics)) {
        [Console]::Error.WriteLine(('{0}: [{1}] {2}' -f $diagnostic.file, $diagnostic.type, $diagnostic.message))
    }

    foreach ($diagnostic in @($analyzerDiagnostics)) {
        Write-Output ('PSScriptAnalyzer {0}:{1}:{2}: [{3}/{4}] {5}' -f $diagnostic.file, $diagnostic.line, $diagnostic.column, $diagnostic.severity, $diagnostic.rule, $diagnostic.message)
    }

    $expectedText = if ($null -eq $expectedForSummary) { 'UNSET' } else { $expectedForSummary }
    Write-Output "PowerShell syntax: mode=$Mode result=$Result exit_code=$ExitCode expected_count=$expectedText discovered=$discoveredCount validated=$validatedCount skipped=$skippedCount encoding_errors=$(@($encodingDiagnostics).Count) parse_errors=$(@($parseDiagnostics).Count) interpreter_path=$interpreterPath interpreter_version=$interpreterVersion psscriptanalyzer_status=$analyzerStatus psscriptanalyzer_reason=$analyzerReason psscriptanalyzer_issues=$(@($analyzerDiagnostics).Count)"
    exit $ExitCode
}

function Get-PowerShellFilesFromDirectory {
    param([Parameter(Mandatory)][System.IO.DirectoryInfo]$Directory)

    $pending = [System.Collections.Generic.Stack[System.IO.DirectoryInfo]]::new()
    $pending.Push($Directory)

    while ($pending.Count -gt 0) {
        $current = $pending.Pop()
        $children = @(Get-ChildItem -LiteralPath $current.FullName -Force -ErrorAction Stop | Sort-Object -Property FullName)

        foreach ($child in $children) {
            if (Test-ReparsePoint -Item $child) {
                $script:skippedCount++
                continue
            }

            if ($child.PSIsContainer) {
                if ($skipDirectoryNames -contains $child.Name) {
                    $script:skippedCount++
                    continue
                }

                $pending.Push([System.IO.DirectoryInfo]$child)
                continue
            }

            if ($validExtensions -contains $child.Extension) {
                Write-Output $child
            }
        }
    }
}

try {
    $interpreterPath = [Environment]::ProcessPath
    $interpreterVersion = $PSVersionTable.PSVersion.ToString()
    if ($IsWindows) {
        $requiredPwsh = 'C:\Program Files\PowerShell\7\pwsh.exe'
        if (-not $interpreterPath.Equals($requiredPwsh, [StringComparison]::OrdinalIgnoreCase)) {
            throw "Windows validation requires interpreter $requiredPwsh; actual=$interpreterPath"
        }
    }

    $inputEntries = if ($PSCmdlet.ParameterSetName -eq 'LiteralPathList') {
        $listItem = Get-Item -LiteralPath $LiteralPathList -Force -ErrorAction Stop
        if ($listItem.PSIsContainer -or (Test-ReparsePoint -Item $listItem)) {
            throw "LiteralPathList must be a regular file: $($listItem.FullName)"
        }

        $listBase = $listItem.DirectoryName
        $entries = @(
            foreach ($line in [IO.File]::ReadAllLines($listItem.FullName)) {
                if ([string]::IsNullOrWhiteSpace($line)) { continue }
                if ([IO.Path]::IsPathRooted($line)) { $line } else { Join-Path -Path $listBase -ChildPath $line }
            }
        )
        if ($entries.Count -eq 0) { throw 'LiteralPathList contains no non-empty path entries.' }
        $entries
    }
    else {
        $LiteralPath
    }

    $resolvedItems = @(
        foreach ($entry in $inputEntries) {
            $item = Get-Item -LiteralPath $entry -Force -ErrorAction Stop
            if (Test-ReparsePoint -Item $item) {
                throw "ReparsePoint validation target is not allowed: $($item.FullName)"
            }
            $item
        }
    )

    $isSingleFile = $PSCmdlet.ParameterSetName -eq 'LiteralPath' -and $resolvedItems.Count -eq 1 -and -not $resolvedItems[0].PSIsContainer
    if ($isSingleFile) {
        if ($expectedCountWasSupplied -and $ExpectedCount -ne 1) { throw 'A single-file target requires ExpectedCount=1.' }
        $expectedForSummary = 1
    }
    else {
        if (-not $expectedCountWasSupplied -or $ExpectedCount -le 0) {
            throw 'Directory or path-list validation requires a positive -ExpectedCount.'
        }
    }

    $collectedFiles = foreach ($item in $resolvedItems) {
        if ($item.PSIsContainer) {
            Get-PowerShellFilesFromDirectory -Directory $item
            continue
        }
        if ($validExtensions -notcontains $item.Extension) {
            throw "Unsupported PowerShell validation target: $($item.FullName)"
        }
        $item
    }

    $filesByPath = [System.Collections.Generic.Dictionary[string, System.IO.FileInfo]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($file in @($collectedFiles)) {
        if ($filesByPath.ContainsKey($file.FullName)) {
            $skippedCount++
            continue
        }
        $filesByPath.Add($file.FullName, $file)
    }

    $sortedPaths = [string[]]@($filesByPath.Keys)
    [Array]::Sort($sortedPaths, [System.StringComparer]::OrdinalIgnoreCase)
    $files = @($sortedPaths | ForEach-Object { $filesByPath[$_] })
    $discoveredCount = $files.Count

    if ($discoveredCount -eq 0) { throw 'No supported PowerShell files were discovered; an empty sample set cannot PASS.' }
    if ($discoveredCount -ne [int]$expectedForSummary) {
        throw "Expected count mismatch: expected=$expectedForSummary discovered=$discoveredCount."
    }

    $utf8Strict = [Text.UTF8Encoding]::new($false, $true)
    $encodingDiagnostics = @(
        foreach ($file in $files) {
            $bytes = [IO.File]::ReadAllBytes($file.FullName)
            if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) {
                [ordered]@{ file = $file.FullName; type = 'UTF8_BOM'; message = 'UTF-8 BOM is not allowed.' }
            }
            if ([Array]::IndexOf[byte]($bytes, 0) -ge 0) {
                [ordered]@{ file = $file.FullName; type = 'NUL'; message = 'NUL byte is not allowed.' }
            }
            if ([Array]::IndexOf[byte]($bytes, 13) -ge 0) {
                [ordered]@{ file = $file.FullName; type = 'NON_LF_EOL'; message = 'CR byte is not allowed; use LF line endings.' }
            }
            try { [void]$utf8Strict.GetString($bytes) }
            catch { [ordered]@{ file = $file.FullName; type = 'INVALID_UTF8'; message = $_.Exception.Message } }
        }
    )
    if ($encodingDiagnostics.Count -gt 0) {
        Complete-Run -Result FAIL -ExitCode 2 -Message 'Source byte validation failed.'
    }

    $parseDiagnostics = @(
        foreach ($file in $files) {
            $tokens = $null
            $parseErrors = $null
            [void][System.Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$tokens, [ref]$parseErrors)
            $validatedCount++

            foreach ($parseError in @($parseErrors)) {
                [ordered]@{
                    file     = $file.FullName
                    line     = $parseError.Extent.StartLineNumber
                    column   = $parseError.Extent.StartColumnNumber
                    error_id = $parseError.ErrorId
                    message  = $parseError.Message
                }
            }
        }
    )

    if ($Mode -eq 'Milestone' -and $parseDiagnostics.Count -eq 0) {
        $analyzerReason = 'TOOL_UNAVAILABLE'
        $analyzerModule = @(Get-Module -ListAvailable -Name PSScriptAnalyzer | Sort-Object -Property Version -Descending | Select-Object -First 1)
        if ($analyzerModule.Count -gt 0) {
            Import-Module -Name $analyzerModule[0].Path -Force -ErrorAction Stop
            $analyzerCommand = Get-Command -Name Invoke-ScriptAnalyzer -ErrorAction Stop
            if (-not $analyzerCommand.Parameters.ContainsKey('ScriptDefinition')) {
                throw 'Available PSScriptAnalyzer does not expose the required ScriptDefinition parameter.'
            }

            $analyzerDiagnostics = @(
                foreach ($file in $files) {
                    $sourceText = [IO.File]::ReadAllText($file.FullName)
                    foreach ($issue in @(Invoke-ScriptAnalyzer -ScriptDefinition $sourceText -ErrorAction Stop)) {
                        [ordered]@{
                            file     = $file.FullName
                            line     = $issue.Line
                            column   = $issue.Column
                            rule     = $issue.RuleName
                            severity = [string]$issue.Severity
                            message  = $issue.Message
                        }
                    }
                }
            )
            $analyzerStatus = if ($analyzerDiagnostics.Count -eq 0) { 'PASS' } else { 'ISSUES' }
            $analyzerReason = $null
        }
    }

    if ($parseDiagnostics.Count -gt 0) {
        Complete-Run -Result FAIL -ExitCode 1
    }
    Complete-Run -Result PASS -ExitCode 0
}
catch {
    Complete-Run -Result FAIL -ExitCode 2 -Message "Validation gate failed: $($_.Exception.Message)"
}
