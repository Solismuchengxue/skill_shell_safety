#requires -Version 7.0

$pwshPath = 'C:\Program Files\PowerShell\7\pwsh.exe'
$adapterPath = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..\skills\shell-safety\scripts\Test-ShellSyntax.ps1')).Path
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ("shell-syntax-pester-{0}" -f [guid]::NewGuid().ToString('N'))
$utf8NoBom = [Text.UTF8Encoding]::new($false)

function Write-ShellFixture {
    param([string]$LiteralPath, [string]$Content)
    [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($LiteralPath))
    [IO.File]::WriteAllText($LiteralPath, $Content, $utf8NoBom)
}

function Invoke-ShellAdapter {
    param([object[]]$Arguments)
    $output = @(& $pwshPath -NoLogo -NoProfile -ExecutionPolicy Bypass -File $adapterPath @Arguments 2>&1 | ForEach-Object { $_.ToString() })
    $exitCode = $LASTEXITCODE
    [pscustomobject]@{ ExitCode=$exitCode; Output=($output -join "`n") }
}

Describe 'Test-ShellSyntax thin adapter' {
    BeforeAll {
        [void][IO.Directory]::CreateDirectory($testRoot)
        $shellCheckAvailable = @(Get-Command shellcheck.exe,shellcheck -All -ErrorAction SilentlyContinue | Where-Object CommandType -EQ Application).Count -gt 0

        $validBash = Join-Path $testRoot 'valid.bash'
        Write-ShellFixture $validBash "#!/usr/bin/env bash`nset -euo pipefail`nvalue=ok`n"
        $validSh = Join-Path $testRoot 'valid.sh'
        Write-ShellFixture $validSh "#!/bin/sh`nset -eu`nvalue=ok`n"
        $invalidBash = Join-Path $testRoot 'invalid.bash'
        Write-ShellFixture $invalidBash "#!/usr/bin/env bash`nif true; then`n"
        $invalidSh = Join-Path $testRoot 'invalid.sh'
        Write-ShellFixture $invalidSh "#!/bin/sh`nif true; then`n"
        $ambiguousSh = Join-Path $testRoot 'ambiguous.sh'
        Write-ShellFixture $ambiguousSh "value=ok`n"
        $emptyDirectory = Join-Path $testRoot 'empty'
        [void][IO.Directory]::CreateDirectory($emptyDirectory)

        $skippedRoot = Join-Path $testRoot 'skipped-root'
        Write-ShellFixture (Join-Path $skippedRoot 'keep.bash') "#!/usr/bin/env bash`nvalue=ok`n"
        Write-ShellFixture (Join-Path $skippedRoot 'node_modules\broken.sh') "#!/bin/sh`nif true; then`n"

        $duplicateList = Join-Path $testRoot 'duplicate.txt'
        Write-ShellFixture $duplicateList "$validBash`n$validBash`n"
        $mismatchList = Join-Path $testRoot 'mismatch.txt'
        Write-ShellFixture $mismatchList "$validBash`n$validSh`n"

        $byteInvalid = Join-Path $testRoot 'byte-invalid.bash'
        $payload = [byte[]](@(0xEF,0xBB,0xBF) + [Text.Encoding]::UTF8.GetBytes("#!/usr/bin/env bash`r`nvalue=ok`n") + @(0))
        [IO.File]::WriteAllBytes($byteInvalid, $payload)
    }

    AfterAll {
        if (Test-Path -LiteralPath $testRoot) {
            $resolved = (Resolve-Path -LiteralPath $testRoot).Path
            $expectedParent = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd([IO.Path]::DirectorySeparatorChar)
            if (-not [IO.Path]::GetDirectoryName($resolved).Equals($expectedParent, [StringComparison]::OrdinalIgnoreCase) -or -not [IO.Path]::GetFileName($resolved).StartsWith('shell-syntax-pester-', [StringComparison]::Ordinal)) { throw "Refuse unverified cleanup: $resolved" }
            Remove-Item -LiteralPath $resolved -Recurse -Force -ErrorAction Stop
        }
    }

    It 'parses Bash in default Fast Text mode with an identified Git Bash backend' {
        $result = Invoke-ShellAdapter @('-LiteralPath', $validBash)
        $result.ExitCode | Should Be 0
        $result.Output | Should Match 'result=PASS.*discovered=1 validated=1.*parse_errors=0'
        $result.Output | Should Match 'backend=GitBash evidence_scope=WINDOWS_LOCAL_COMPAT'
        $result.Output | Should Match 'shellcheck_status=NOT_RUN shellcheck_reason=MODE_FAST'
    }

    It 'parses POSIX sh and emits Json identity evidence' {
        $result = Invoke-ShellAdapter @('-LiteralPath', $validSh, '-OutputFormat', 'Json')
        $result.ExitCode | Should Be 0
        $json = $result.Output | ConvertFrom-Json
        $json.result | Should Be 'PASS'
        $json.backend | Should Be 'GitBash'
        $json.dialects[0].dialect | Should Be 'Sh'
        $json.interpreters[0].path | Should Match '\\sh\.exe$'
    }

    It 'returns exit 1 for invalid Bash syntax' {
        $result = Invoke-ShellAdapter @('-LiteralPath', $invalidBash)
        $result.ExitCode | Should Be 1
        $result.Output | Should Match 'parse_errors=1'
    }

    It 'returns exit 1 for invalid sh syntax' {
        $result = Invoke-ShellAdapter @('-LiteralPath', $invalidSh)
        $result.ExitCode | Should Be 1
        $result.Output | Should Match 'parse_errors=1'
    }

    It 'rejects an empty sample set' {
        $result = Invoke-ShellAdapter @('-LiteralPath', $emptyDirectory, '-ExpectedCount', '1')
        $result.ExitCode | Should Be 2
        $result.Output | Should Match 'empty sample set cannot PASS'
    }

    It 'rejects ExpectedCount mismatch before parsing' {
        $result = Invoke-ShellAdapter @('-LiteralPathList', $mismatchList, '-ExpectedCount', '3')
        $result.ExitCode | Should Be 2
        $result.Output | Should Match 'expected=3 discovered=2'
    }

    It 'deduplicates path-list inputs' {
        $result = Invoke-ShellAdapter @('-LiteralPathList', $duplicateList, '-ExpectedCount', '1')
        $result.ExitCode | Should Be 0
        $result.Output | Should Match 'discovered=1 validated=1 skipped=1'
    }

    It 'skips dependency directories' {
        $result = Invoke-ShellAdapter @('-LiteralPath', $skippedRoot, '-ExpectedCount', '1')
        $result.ExitCode | Should Be 0
        $result.Output | Should Match 'discovered=1 validated=1 skipped=1'
    }

    It 'fails closed when Auto dialect is ambiguous' {
        $result = Invoke-ShellAdapter @('-LiteralPath', $ambiguousSh)
        $result.ExitCode | Should Be 2
        $result.Output | Should Match 'Dialect cannot be uniquely determined'
    }

    It 'does not treat a Windows WSL launcher as an explicit shell interpreter' {
        $launcher = 'C:\Windows\System32\bash.exe'
        $result = Invoke-ShellAdapter @('-LiteralPath', $validBash, '-Backend', 'Explicit', '-Dialect', 'Bash', '-InterpreterPath', $launcher)
        $result.ExitCode | Should Be 2
        $result.Output | Should Match 'WSL launcher is not a shell interpreter'
    }

    It 'reports ShellCheck availability only in Milestone mode' {
        $result = Invoke-ShellAdapter @('-LiteralPath', $validBash, '-Mode', 'Milestone')
        if ($shellCheckAvailable) {
            $result.Output | Should Match 'shellcheck_status=(PASS|ISSUES)'
        }
        else {
            $result.ExitCode | Should Be 0
            $result.Output | Should Match 'shellcheck_status=NOT_RUN shellcheck_reason=TOOL_UNAVAILABLE'
        }
    }

    It 'rejects BOM, CR and NUL before parser invocation' {
        $result = Invoke-ShellAdapter @('-LiteralPath', $byteInvalid)
        $result.ExitCode | Should Be 2
        $result.Output | Should Match 'encoding_errors=3'
        $result.Output | Should Match 'validated=0'
    }

    It 'does not start WSL outside Target mode' {
        $result = Invoke-ShellAdapter @('-LiteralPath', $validBash, '-Backend', 'WSL', '-WslDistribution', 'not-invoked')
        $result.ExitCode | Should Be 2
        $result.Output | Should Match 'WSL backend is allowed only in Target mode'
    }

    It 'converts a missing input to stable Json and exit 2' {
        $missing = Join-Path $testRoot 'missing.bash'
        $result = Invoke-ShellAdapter @('-LiteralPath', $missing, '-OutputFormat', 'Json')
        $result.ExitCode | Should Be 2
        $json = $result.Output | ConvertFrom-Json
        $json.exit_code | Should Be 2
        $json.message | Should Match '^Validation gate failed:'
    }
}
