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
    [ValidateSet('Auto', 'Bash', 'Sh')]
    [string]$Dialect = 'Auto',

    [Parameter()]
    [ValidateSet('Auto', 'GitBash', 'WSL', 'Explicit')]
    [string]$Backend = 'Auto',

    [Parameter()]
    [string]$InterpreterPath,

    [Parameter()]
    [string]$WslDistribution,

    [Parameter()]
    [int]$ExpectedCount,

    [Parameter()]
    [ValidateSet('Text', 'Json')]
    [string]$OutputFormat = 'Text',

    [Parameter()]
    [ValidateSet('Fast', 'Milestone', 'Target')]
    [string]$Mode = 'Fast'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$validExtensions = @('.sh', '.bash')
$skipDirectoryNames = @('.git', '.hg', '.svn', 'node_modules', '.venv', 'venv', '__pycache__', 'bin', 'obj', 'dist', 'build', 'vendor', 'packages', 'coverage')
$expectedCountWasSupplied = $PSBoundParameters.ContainsKey('ExpectedCount')
$expectedForSummary = if ($expectedCountWasSupplied) { $ExpectedCount } else { $null }
$discoveredCount = 0
$validatedCount = 0
$skippedCount = 0
$encodingDiagnostics = @()
$parseDiagnostics = @()
$lintDiagnostics = @()
$dialectRecords = @()
$interpreterRecords = @()
$backendCandidates = @()
$resolvedBackend = 'UNRESOLVED'
$evidenceScope = 'UNRESOLVED'
$shellCheckStatus = 'NOT_RUN'
$shellCheckReason = 'MODE_FAST'
$shellCheckPath = $null
$shellCheckVersion = $null

function Test-ReparsePoint {
    param([Parameter(Mandatory)][System.IO.FileSystemInfo]$Item)
    return [bool]($Item.Attributes -band [IO.FileAttributes]::ReparsePoint)
}

function Complete-Run {
    param(
        [Parameter(Mandatory)][ValidateSet('PASS', 'FAIL')][string]$Result,
        [Parameter(Mandatory)][int]$ExitCode,
        [Parameter()][string]$Message
    )

    $summary = [ordered]@{
        schema_version         = 1
        mode                   = $Mode
        result                 = $Result
        exit_code              = $ExitCode
        expected_count         = $expectedForSummary
        discovered             = $discoveredCount
        validated              = $validatedCount
        skipped                = $skippedCount
        encoding_errors        = @($encodingDiagnostics).Count
        parse_errors           = @($parseDiagnostics).Count
        lint_issues            = @($lintDiagnostics).Count
        backend                = $resolvedBackend
        evidence_scope         = $evidenceScope
        backend_candidates     = @($backendCandidates)
        interpreters           = @($interpreterRecords)
        dialects               = @($dialectRecords)
        shellcheck_status      = $shellCheckStatus
        shellcheck_reason      = $shellCheckReason
        shellcheck_path        = $shellCheckPath
        shellcheck_version     = $shellCheckVersion
        message                = $Message
        encoding_diagnostics   = @($encodingDiagnostics)
        parse_diagnostics      = @($parseDiagnostics)
        shellcheck_diagnostics = @($lintDiagnostics)
    }

    if ($OutputFormat -eq 'Json') {
        Write-Output ($summary | ConvertTo-Json -Depth 7 -Compress)
        exit $ExitCode
    }

    if ($Message) { [Console]::Error.WriteLine($Message) }
    foreach ($item in @($encodingDiagnostics)) { [Console]::Error.WriteLine(('{0}: [{1}] {2}' -f $item.file, $item.type, $item.message)) }
    foreach ($item in @($parseDiagnostics)) { [Console]::Error.WriteLine(('{0}: [{1}/{2}/exit={3}] {4}' -f $item.file, $item.backend, $item.dialect, $item.exit_code, $item.message)) }
    foreach ($item in @($lintDiagnostics)) { Write-Output ('ShellCheck {0}:{1}:{2}: [{3}] {4}' -f $item.file, $item.line, $item.column, $item.code, $item.message) }

    $expectedText = if ($null -eq $expectedForSummary) { 'UNSET' } else { $expectedForSummary }
    $interpreterText = (@($interpreterRecords) | ForEach-Object { "$($_.dialect):$($_.path)@$($_.version)" }) -join ','
    Write-Output "Shell syntax: mode=$Mode result=$Result exit_code=$ExitCode expected_count=$expectedText discovered=$discoveredCount validated=$validatedCount skipped=$skippedCount encoding_errors=$(@($encodingDiagnostics).Count) parse_errors=$(@($parseDiagnostics).Count) lint_issues=$(@($lintDiagnostics).Count) backend=$resolvedBackend evidence_scope=$evidenceScope interpreters=$interpreterText shellcheck_status=$shellCheckStatus shellcheck_reason=$shellCheckReason"
    exit $ExitCode
}

function Test-ShellCandidate {
    param([Parameter(Mandatory)][System.IO.FileInfo]$File)
    if ($validExtensions -contains $File.Extension) { return $true }
    $stream = [IO.File]::Open($File.FullName, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
    try {
        if ($stream.Length -lt 2) { return $false }
        return $stream.ReadByte() -eq 35 -and $stream.ReadByte() -eq 33
    }
    finally { $stream.Dispose() }
}

function Get-ShellFilesFromDirectory {
    param([Parameter(Mandatory)][System.IO.DirectoryInfo]$Directory)
    $pending = [System.Collections.Generic.Stack[System.IO.DirectoryInfo]]::new()
    $pending.Push($Directory)
    while ($pending.Count -gt 0) {
        $current = $pending.Pop()
        foreach ($child in @(Get-ChildItem -LiteralPath $current.FullName -Force -ErrorAction Stop | Sort-Object FullName)) {
            if (Test-ReparsePoint -Item $child) { $script:skippedCount++; continue }
            if ($child.PSIsContainer) {
                if ($skipDirectoryNames -contains $child.Name) { $script:skippedCount++; continue }
                $pending.Push([System.IO.DirectoryInfo]$child)
                continue
            }
            if (Test-ShellCandidate -File $child) { Write-Output $child }
        }
    }
}

function Resolve-FileDialect {
    param([System.IO.FileInfo]$File, [string]$Text)
    if ($Dialect -ne 'Auto') { return $Dialect }
    $firstLine = ($Text -split "`n", 2)[0]
    if ($firstLine -match '^#!\s*(?:(?:/usr/bin/env)(?:\s+-S)?\s+|\S*/)(bash)(?:\s|$)') { return 'Bash' }
    if ($firstLine -match '^#!\s*(?:(?:/usr/bin/env)(?:\s+-S)?\s+|\S*/)(sh)(?:\s|$)') { return 'Sh' }
    if ($File.Extension.Equals('.bash', [StringComparison]::OrdinalIgnoreCase)) { return 'Bash' }
    throw "Dialect cannot be uniquely determined for $($File.FullName); add a bash/sh shebang or pass -Dialect."
}

function Get-GitBashCandidates {
    $roots = [System.Collections.Generic.Dictionary[string, object]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($command in @(Get-Command git.exe -All -ErrorAction SilentlyContinue | Where-Object CommandType -EQ Application)) {
        $cmdDirectory = [IO.Path]::GetDirectoryName($command.Source)
        if (-not [IO.Path]::GetFileName($cmdDirectory).Equals('cmd', [StringComparison]::OrdinalIgnoreCase)) { continue }
        $root = [IO.Path]::GetDirectoryName($cmdDirectory)
        $bash = Join-Path $root 'bin\bash.exe'
        $sh = Join-Path $root 'bin\sh.exe'
        $cygpath = Join-Path $root 'usr\bin\cygpath.exe'
        if ((Test-Path -LiteralPath $bash -PathType Leaf) -and (Test-Path -LiteralPath $sh -PathType Leaf) -and (Test-Path -LiteralPath $cygpath -PathType Leaf)) {
            $roots[$root] = [pscustomobject]@{ root = $root; bash = $bash; sh = $sh; cygpath = $cygpath }
        }
    }
    return @($roots.Values | Sort-Object root)
}

function Get-NativeVersion {
    param([string]$Executable)
    $output = @(& $Executable --version 2>&1 | ForEach-Object { $_.ToString() })
    $exitCode = $LASTEXITCODE
    if ($exitCode -ne 0 -or $output.Count -eq 0) { throw "Interpreter version check failed: path=$Executable exit=$exitCode" }
    return $output[0]
}

function Convert-ToMsysPath {
    param([string]$Cygpath, [string]$WindowsPath)
    $output = @(& $Cygpath -u -- $WindowsPath 2>&1 | ForEach-Object { $_.ToString() })
    $exitCode = $LASTEXITCODE
    if ($exitCode -ne 0 -or $output.Count -ne 1) { throw "MSYS path conversion failed: path=$WindowsPath exit=$exitCode" }
    return $output[0]
}

try {
    $inputEntries = if ($PSCmdlet.ParameterSetName -eq 'LiteralPathList') {
        $listItem = Get-Item -LiteralPath $LiteralPathList -Force -ErrorAction Stop
        if ($listItem.PSIsContainer -or (Test-ReparsePoint -Item $listItem)) { throw "LiteralPathList must be a regular file: $($listItem.FullName)" }
        $listBase = $listItem.DirectoryName
        $entries = @(foreach ($line in [IO.File]::ReadAllLines($listItem.FullName)) {
            if ([string]::IsNullOrWhiteSpace($line)) { continue }
            if ([IO.Path]::IsPathRooted($line)) { $line } else { Join-Path $listBase $line }
        })
        if ($entries.Count -eq 0) { throw 'LiteralPathList contains no non-empty path entries.' }
        $entries
    }
    else { $LiteralPath }

    $resolvedItems = @(foreach ($entry in $inputEntries) {
        $item = Get-Item -LiteralPath $entry -Force -ErrorAction Stop
        if (Test-ReparsePoint -Item $item) { throw "ReparsePoint validation target is not allowed: $($item.FullName)" }
        $item
    })

    $isSingleFile = $PSCmdlet.ParameterSetName -eq 'LiteralPath' -and $resolvedItems.Count -eq 1 -and -not $resolvedItems[0].PSIsContainer
    if ($isSingleFile) {
        if ($expectedCountWasSupplied -and $ExpectedCount -ne 1) { throw 'A single-file target requires ExpectedCount=1.' }
        $expectedForSummary = 1
    }
    elseif (-not $expectedCountWasSupplied -or $ExpectedCount -le 0) { throw 'Directory or path-list validation requires a positive -ExpectedCount.' }

    $collectedFiles = foreach ($item in $resolvedItems) {
        if ($item.PSIsContainer) { Get-ShellFilesFromDirectory -Directory $item; continue }
        if (-not (Test-ShellCandidate -File $item)) { throw "Unsupported shell validation target: $($item.FullName)" }
        $item
    }

    $filesByPath = [System.Collections.Generic.Dictionary[string, System.IO.FileInfo]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($file in @($collectedFiles)) {
        if ($filesByPath.ContainsKey($file.FullName)) { $skippedCount++; continue }
        $filesByPath.Add($file.FullName, $file)
    }
    $sortedPaths = [string[]]@($filesByPath.Keys)
    [Array]::Sort($sortedPaths, [StringComparer]::OrdinalIgnoreCase)
    $files = @($sortedPaths | ForEach-Object { $filesByPath[$_] })
    $discoveredCount = $files.Count
    if ($discoveredCount -eq 0) { throw 'No supported shell files were discovered; an empty sample set cannot PASS.' }
    if ($discoveredCount -ne [int]$expectedForSummary) { throw "Expected count mismatch: expected=$expectedForSummary discovered=$discoveredCount." }

    $sourceByPath = [System.Collections.Generic.Dictionary[string, string]]::new([StringComparer]::OrdinalIgnoreCase)
    $utf8Strict = [Text.UTF8Encoding]::new($false, $true)
    $encodingDiagnostics = @(foreach ($file in $files) {
        $bytes = [IO.File]::ReadAllBytes($file.FullName)
        if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) { [ordered]@{ file=$file.FullName; type='UTF8_BOM'; message='UTF-8 BOM is not allowed.' } }
        if ([Array]::IndexOf[byte]($bytes, 0) -ge 0) { [ordered]@{ file=$file.FullName; type='NUL'; message='NUL byte is not allowed.' } }
        if ([Array]::IndexOf[byte]($bytes, 13) -ge 0) { [ordered]@{ file=$file.FullName; type='NON_LF_EOL'; message='CR byte is not allowed; use LF line endings.' } }
        try { $sourceByPath[$file.FullName] = $utf8Strict.GetString($bytes) }
        catch { [ordered]@{ file=$file.FullName; type='INVALID_UTF8'; message=$_.Exception.Message } }
    })
    if ($encodingDiagnostics.Count -gt 0) { Complete-Run -Result FAIL -ExitCode 2 -Message 'Source byte validation failed.' }

    $dialectByPath = [System.Collections.Generic.Dictionary[string, string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($file in $files) {
        $resolvedDialect = Resolve-FileDialect -File $file -Text $sourceByPath[$file.FullName]
        $dialectByPath[$file.FullName] = $resolvedDialect
        $dialectRecords += [ordered]@{ file=$file.FullName; dialect=$resolvedDialect }
    }

    $backendInfo = $null
    if ($Backend -in @('Auto', 'GitBash')) {
        $msysCandidates = @(Get-Command bash.exe -All -ErrorAction SilentlyContinue | Where-Object { $_.CommandType -eq 'Application' -and $_.Source -match '\\msys(?:32|64)\\usr\\bin\\bash\.exe$' })
        if ($Backend -eq 'Auto' -and $msysCandidates.Count -gt 0) { throw 'MSYS2 interpreter detected in Auto mode; use -Backend Explicit with an exact interpreter path.' }
        $candidates = @(Get-GitBashCandidates)
        $backendCandidates = @($candidates | ForEach-Object { [ordered]@{ backend='GitBash'; root=$_.root } })
        if ($candidates.Count -ne 1) { throw "Git Bash identity is ambiguous: expected=1 actual=$($candidates.Count). Use -Backend Explicit." }
        $backendInfo = $candidates[0]
        $resolvedBackend = 'GitBash'
        $evidenceScope = 'WINDOWS_LOCAL_COMPAT'
    }
    elseif ($Backend -eq 'Explicit') {
        if ([string]::IsNullOrWhiteSpace($InterpreterPath) -or -not [IO.Path]::IsPathRooted($InterpreterPath)) { throw 'Explicit backend requires an absolute -InterpreterPath.' }
        if ($Dialect -eq 'Auto') { throw 'Explicit backend requires -Dialect Bash or Sh.' }
        $item = Get-Item -LiteralPath $InterpreterPath -Force -ErrorAction Stop
        if ($item.PSIsContainer -or (Test-ReparsePoint -Item $item)) { throw "Explicit interpreter must be a regular file: $($item.FullName)" }
        if ($item.FullName -match '\\Windows\\(?:System32|SystemApps)\\bash\.exe$' -or $item.FullName -match '\\WindowsApps\\bash\.exe$') { throw 'A Windows WSL launcher is not a shell interpreter; use -Backend WSL in Target mode.' }
        $root = [IO.Path]::GetDirectoryName([IO.Path]::GetDirectoryName($item.FullName))
        $cygpath = Join-Path $root 'usr\bin\cygpath.exe'
        $backendInfo = [pscustomobject]@{ root=$root; bash=$item.FullName; sh=$item.FullName; cygpath=$(if(Test-Path -LiteralPath $cygpath -PathType Leaf){$cygpath}else{$null}) }
        $resolvedBackend = if (Test-Path -LiteralPath (Join-Path $root 'cmd\git.exe') -PathType Leaf) { 'GitBashExplicit' } elseif (Test-Path -LiteralPath (Join-Path $root 'usr\bin\msys-2.0.dll') -PathType Leaf) { 'MSYS2Explicit' } else { 'Explicit' }
        $evidenceScope = 'WINDOWS_LOCAL_COMPAT'
    }
    else {
        if ($Mode -ne 'Target') { throw 'WSL backend is allowed only in Target mode.' }
        if ([string]::IsNullOrWhiteSpace($WslDistribution)) { throw 'WSL backend requires an explicit -WslDistribution.' }
        $wsl = @(Get-Command wsl.exe -All -ErrorAction Stop | Where-Object CommandType -EQ Application | Select-Object -Unique Source)
        if ($wsl.Count -ne 1) { throw "WSL launcher identity is ambiguous: expected=1 actual=$($wsl.Count)." }
        $backendInfo = [pscustomobject]@{ wsl=$wsl[0].Source; distribution=$WslDistribution }
        $resolvedBackend = "WSL:$WslDistribution"
        $evidenceScope = 'TARGET_ENVIRONMENT'
    }

    $usedDialects = @($dialectByPath.Values | Sort-Object -Unique)
    foreach ($usedDialect in $usedDialects) {
        if ($Backend -eq 'WSL') {
            $path = if ($usedDialect -eq 'Bash') { '/usr/bin/bash' } else { '/bin/sh' }
            $versionOutput = @(& $backendInfo.wsl -d $backendInfo.distribution --exec $path --version 2>&1 | ForEach-Object { $_.ToString() })
            $versionExit = $LASTEXITCODE
            if ($versionExit -ne 0 -or $versionOutput.Count -eq 0) { throw "WSL interpreter version check failed: path=$path exit=$versionExit" }
            $interpreterRecords += [ordered]@{ dialect=$usedDialect; path=$path; version=$versionOutput[0]; backend=$resolvedBackend }
        }
        else {
            $path = if ($usedDialect -eq 'Bash') { $backendInfo.bash } else { $backendInfo.sh }
            $interpreterRecords += [ordered]@{ dialect=$usedDialect; path=$path; version=(Get-NativeVersion -Executable $path); backend=$resolvedBackend }
        }
    }

    foreach ($file in $files) {
        $fileDialect = $dialectByPath[$file.FullName]
        if ($Backend -eq 'WSL') {
            $interpreter = if ($fileDialect -eq 'Bash') { '/usr/bin/bash' } else { '/bin/sh' }
            $converted = @(& $backendInfo.wsl -d $backendInfo.distribution --exec wslpath -a -u $file.FullName 2>&1 | ForEach-Object { $_.ToString() })
            $convertExit = $LASTEXITCODE
            if ($convertExit -ne 0 -or $converted.Count -ne 1) { throw "WSL path conversion failed: path=$($file.FullName) exit=$convertExit" }
            $parserOutput = @(& $backendInfo.wsl -d $backendInfo.distribution --exec $interpreter -n -- $converted[0] 2>&1 | ForEach-Object { $_.ToString() })
        }
        else {
            $interpreter = if ($fileDialect -eq 'Bash') { $backendInfo.bash } else { $backendInfo.sh }
            $parserPath = if ($backendInfo.cygpath) { Convert-ToMsysPath -Cygpath $backendInfo.cygpath -WindowsPath $file.FullName } else { $file.FullName }
            $parserOutput = @(& $interpreter -n -- $parserPath 2>&1 | ForEach-Object { $_.ToString() })
        }
        $parserExit = $LASTEXITCODE
        $validatedCount++
        if ($parserExit -ne 0) { $parseDiagnostics += [ordered]@{ file=$file.FullName; dialect=$fileDialect; backend=$resolvedBackend; exit_code=$parserExit; message=($parserOutput -join "`n") } }
    }

    if ($Mode -eq 'Milestone' -and $parseDiagnostics.Count -eq 0) {
        $shellCheckReason = 'TOOL_UNAVAILABLE'
        $commands = @(Get-Command shellcheck.exe,shellcheck -All -ErrorAction SilentlyContinue | Where-Object CommandType -EQ Application | Sort-Object Source -Unique)
        if ($commands.Count -gt 1) { throw "ShellCheck identity is ambiguous: expected<=1 actual=$($commands.Count)." }
        if ($commands.Count -eq 1) {
            $shellCheckPath = $commands[0].Source
            $shellCheckVersion = Get-NativeVersion -Executable $shellCheckPath
            foreach ($file in $files) {
                $shellName = if ($dialectByPath[$file.FullName] -eq 'Bash') { 'bash' } else { 'sh' }
                $lintOutput = @(& $shellCheckPath "--shell=$shellName" '--format=json' '--' $file.FullName 2>&1 | ForEach-Object { $_.ToString() })
                $lintExit = $LASTEXITCODE
                if ($lintExit -gt 1) { throw "ShellCheck execution failed: file=$($file.FullName) exit=$lintExit" }
                if ($lintOutput.Count -gt 0 -and ($lintOutput -join '').Trim() -ne '[]') {
                    foreach ($issue in @(($lintOutput -join "`n") | ConvertFrom-Json -ErrorAction Stop)) {
                        $lintDiagnostics += [ordered]@{ file=$file.FullName; line=$issue.line; column=$issue.column; code=$issue.code; message=$issue.message }
                    }
                }
            }
            $shellCheckStatus = if ($lintDiagnostics.Count -eq 0) { 'PASS' } else { 'ISSUES' }
            $shellCheckReason = $null
        }
    }
    elseif ($Mode -eq 'Target') { $shellCheckReason = 'MODE_TARGET' }

    if ($parseDiagnostics.Count -gt 0 -or $lintDiagnostics.Count -gt 0) { Complete-Run -Result FAIL -ExitCode 1 }
    Complete-Run -Result PASS -ExitCode 0
}
catch { Complete-Run -Result FAIL -ExitCode 2 -Message "Validation gate failed: $($_.Exception.Message)" }
