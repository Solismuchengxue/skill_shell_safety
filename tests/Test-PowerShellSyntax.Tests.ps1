#requires -Version 7.0

$pwshPath = 'C:\Program Files\PowerShell\7\pwsh.exe'
$validatorPath = (Resolve-Path -LiteralPath (Join-Path -Path $PSScriptRoot -ChildPath '..\skills\shell-safety\scripts\Test-PowerShellSyntax.ps1')).Path
$testRoot = Join-Path -Path ([IO.Path]::GetTempPath()) -ChildPath ("powershell-syntax-pester-{0}" -f [guid]::NewGuid().ToString('N'))
$utf8NoBom = [Text.UTF8Encoding]::new($false)

function Write-Fixture {
    param([string]$LiteralPath, [string]$Content)
    [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($LiteralPath))
    [IO.File]::WriteAllText($LiteralPath, $Content, $utf8NoBom)
}

function Invoke-Adapter {
    param([object[]]$Arguments)
    $output = @(& $pwshPath -NoLogo -NoProfile -ExecutionPolicy Bypass -File $validatorPath @Arguments 2>&1 | ForEach-Object { $_.ToString() })
    $exitCode = $LASTEXITCODE
    [pscustomobject]@{ ExitCode = $exitCode; Output = ($output -join "`n") }
}

Describe 'Test-PowerShellSyntax thin adapter' {
    BeforeAll {
        if (-not (Test-Path -LiteralPath $pwshPath -PathType Leaf)) { throw "Missing PowerShell 7: $pwshPath" }
        $analyzerIsAvailable = @(Get-Module -ListAvailable -Name PSScriptAnalyzer).Count -gt 0
        [void][IO.Directory]::CreateDirectory($testRoot)

        $singleValid = Join-Path $testRoot 'single-valid.ps1'
        Write-Fixture $singleValid '$value = 1'

        $validBatch = Join-Path $testRoot 'valid-batch'
        Write-Fixture (Join-Path $validBatch 'module.psm1') "function Get-Value { 'ok' }"
        Write-Fixture (Join-Path $validBatch 'manifest.psd1') "@{ RootModule = 'module.psm1' }"
        Write-Fixture (Join-Path $validBatch 'script.ps1') '$value = 2'

        $invalidFile = Join-Path $testRoot 'invalid.ps1'
        Write-Fixture $invalidFile 'function Broken {'

        $byteInvalidFile = Join-Path $testRoot 'byte-invalid.ps1'
        $bytePayload = [byte[]](@(0xEF, 0xBB, 0xBF) + [Text.Encoding]::UTF8.GetBytes("`$value = 1`r`n") + @(0))
        [IO.File]::WriteAllBytes($byteInvalidFile, $bytePayload)

        $emptyDirectory = Join-Path $testRoot 'empty'
        [void][IO.Directory]::CreateDirectory($emptyDirectory)

        $unsupportedFile = Join-Path $testRoot 'unsupported.txt'
        Write-Fixture $unsupportedFile 'not PowerShell'

        $skippedRoot = Join-Path $testRoot 'skipped-root'
        Write-Fixture (Join-Path $skippedRoot 'keep.ps1') '$kept = $true'
        Write-Fixture (Join-Path $skippedRoot 'node_modules\broken.ps1') 'function Broken {'

        $duplicateList = Join-Path $testRoot 'duplicate-paths.txt'
        Write-Fixture $duplicateList "$singleValid`n$singleValid`n"

        $mismatchList = Join-Path $testRoot 'mismatch-paths.txt'
        Write-Fixture $mismatchList "$singleValid`n$validBatch`n"

        $reparseRoot = Join-Path $testRoot 'reparse-root'
        $reparseTarget = Join-Path $testRoot 'reparse-target'
        $reparseLink = Join-Path $reparseRoot 'linked'
        Write-Fixture (Join-Path $reparseRoot 'keep.ps1') '$kept = $true'
        Write-Fixture (Join-Path $reparseTarget 'broken.ps1') 'function Broken {'
        [void](New-Item -ItemType Junction -Path $reparseLink -Target $reparseTarget -ErrorAction Stop)
    }

    AfterAll {
        if (Test-Path -LiteralPath $reparseLink) {
            $linkItem = Get-Item -LiteralPath $reparseLink -Force -ErrorAction Stop
            if (-not ($linkItem.Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw "Refuse non-reparse cleanup: $reparseLink" }
            Remove-Item -LiteralPath $reparseLink -Force -ErrorAction Stop
        }
        if (Test-Path -LiteralPath $testRoot) {
            $resolved = (Resolve-Path -LiteralPath $testRoot -ErrorAction Stop).Path
            $expectedParent = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd([IO.Path]::DirectorySeparatorChar)
            if (-not [IO.Path]::GetDirectoryName($resolved).Equals($expectedParent, [StringComparison]::OrdinalIgnoreCase) -or -not [IO.Path]::GetFileName($resolved).StartsWith('powershell-syntax-pester-', [StringComparison]::Ordinal)) {
                throw "Refuse unverified test cleanup: $resolved"
            }
            Remove-Item -LiteralPath $resolved -Recurse -Force -ErrorAction Stop
        }
    }

    It 'accepts a valid single file in Text mode' {
        $result = Invoke-Adapter @('-LiteralPath', $singleValid)
        $result.ExitCode | Should Be 0
        $result.Output | Should Match 'result=PASS.*discovered=1 validated=1 skipped=0.*parse_errors=0'
        $result.Output | Should Match 'interpreter_path=C:\\Program Files\\PowerShell\\7\\pwsh\.exe'
        if ($analyzerIsAvailable) {
            $result.Output | Should Match 'psscriptanalyzer_status=(PASS|ISSUES)'
        }
        else {
            $result.Output | Should Match 'psscriptanalyzer_status=NOT_RUN'
        }
    }

    It 'returns parser diagnostics and exit 1 for invalid syntax' {
        $result = Invoke-Adapter @('-LiteralPath', $invalidFile)
        $result.ExitCode | Should Be 1
        $result.Output | Should Match '\[MissingEndCurlyBrace\]'
        $result.Output | Should Match 'discovered=1 validated=1.*parse_errors=1'
    }

    It 'rejects an empty directory' {
        $result = Invoke-Adapter @('-LiteralPath', $emptyDirectory, '-ExpectedCount', '1')
        $result.ExitCode | Should Be 2
        $result.Output | Should Match 'empty sample set cannot PASS'
    }

    It 'rejects an unsupported direct file' {
        $result = Invoke-Adapter @('-LiteralPath', $unsupportedFile)
        $result.ExitCode | Should Be 2
        $result.Output | Should Match 'Unsupported PowerShell validation target'
    }

    It 'deduplicates path-list inputs' {
        $result = Invoke-Adapter @('-LiteralPathList', $duplicateList, '-ExpectedCount', '1')
        $result.ExitCode | Should Be 0
        $result.Output | Should Match 'discovered=1 validated=1 skipped=1.*parse_errors=0'
    }

    It 'skips dependency directories without parsing their files' {
        $result = Invoke-Adapter @('-LiteralPath', $skippedRoot, '-ExpectedCount', '1')
        $result.ExitCode | Should Be 0
        $result.Output | Should Match 'discovered=1 validated=1 skipped=1.*parse_errors=0'
    }

    It 'rejects an ExpectedCount mismatch before parsing' {
        $result = Invoke-Adapter @('-LiteralPathList', $mismatchList, '-ExpectedCount', '5')
        $result.ExitCode | Should Be 2
        $result.Output | Should Match 'Expected count mismatch: expected=5 discovered=4'
        $result.Output | Should Match 'discovered=4 validated=0'
    }

    It 'skips a reparse entry inside a directory' {
        $result = Invoke-Adapter @('-LiteralPath', $reparseRoot, '-ExpectedCount', '1')
        $result.ExitCode | Should Be 0
        $result.Output | Should Match 'discovered=1 validated=1 skipped=1.*parse_errors=0'
    }

    It 'rejects a direct reparse target' {
        $result = Invoke-Adapter @('-LiteralPath', $reparseLink, '-ExpectedCount', '1')
        $result.ExitCode | Should Be 2
        $result.Output | Should Match 'ReparsePoint validation target is not allowed'
    }

    It 'emits stable Json for a passing run' {
        $result = Invoke-Adapter @('-LiteralPath', $singleValid, '-OutputFormat', 'Json')
        $result.ExitCode | Should Be 0
        $json = $result.Output | ConvertFrom-Json
        $json.result | Should Be 'PASS'
        $json.exit_code | Should Be 0
        $json.discovered | Should Be 1
        $json.validated | Should Be 1
        if ($analyzerIsAvailable) {
            $json.psscriptanalyzer_status | Should Match '^(PASS|ISSUES)$'
        }
        else {
            $json.psscriptanalyzer_status | Should Be 'NOT_RUN'
        }
    }

    It 'preserves exit 1 and diagnostics in Json mode' {
        $result = Invoke-Adapter @('-LiteralPath', $invalidFile, '-OutputFormat', 'Json')
        $result.ExitCode | Should Be 1
        $json = $result.Output | ConvertFrom-Json
        $json.result | Should Be 'FAIL'
        $json.exit_code | Should Be 1
        $json.parse_errors | Should Be 1
        $json.parse_diagnostics[0].error_id | Should Be 'MissingEndCurlyBrace'
    }

    It 'converts a top-level input error to stable Json and exit 2' {
        $missingPath = Join-Path $testRoot 'missing.ps1'
        $result = Invoke-Adapter @('-LiteralPath', $missingPath, '-OutputFormat', 'Json')
        $result.ExitCode | Should Be 2
        $json = $result.Output | ConvertFrom-Json
        $json.result | Should Be 'FAIL'
        $json.exit_code | Should Be 2
        $json.message | Should Match '^Validation gate failed:'
    }

    It 'rejects BOM, CR and NUL before AST parsing' {
        $result = Invoke-Adapter @('-LiteralPath', $byteInvalidFile)
        $result.ExitCode | Should Be 2
        $result.Output | Should Match 'encoding_errors=3'
        $result.Output | Should Match 'validated=0'
    }

    It 'enables PSScriptAnalyzer only in Milestone mode when available' {
        $result = Invoke-Adapter @('-LiteralPath', $singleValid, '-Mode', 'Milestone')
        $result.ExitCode | Should Be 0
        if ($analyzerIsAvailable) {
            $result.Output | Should Match 'psscriptanalyzer_status=(PASS|ISSUES)'
        }
        else {
            $result.Output | Should Match 'psscriptanalyzer_status=NOT_RUN'
            $result.Output | Should Match 'psscriptanalyzer_reason=TOOL_UNAVAILABLE'
        }
    }
}
