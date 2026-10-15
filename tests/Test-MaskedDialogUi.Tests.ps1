#requires -Version 7.0
$root = Split-Path -Parent $PSScriptRoot
$modulePath = Join-Path $root 'skills/powershell-bash-safety/scripts/Invoke-MaskedSudoOverSsh.psm1'
Describe 'Masked dialog presentation contract' {
    BeforeAll {
        $module = Import-Module $modulePath -Force -PassThru
        $action = @{ AuthorizationId = 'DIALOG-SYNTHETIC'; HostName = 'synthetic.example'; UserName = 'operator'; TargetCommand = '/usr/bin/id'; KnownHostsFile = 'C:\synthetic\known_hosts' }
    }
    AfterAll { Remove-Module $module.Name -Force }
    It 'binds exact plain title and description in the digest without code interpretation' {
        $title = "NVENC 'quoted' <check>"
        $description = '只读核验 $literal，不执行此说明中的任何代码'
        $record = & $module { param($a, $t, $d) Get-ActionRecord @a -Port 22 -TargetArgument @() -IdentityFile '' -TimeoutSeconds 120 -MaxOutputBytes 1048576 -ActionTitle $t -ActionDescription $d } $action $title $description
        $record.action_title | Should Be $title
        $record.action_description | Should Be $description
        $first = New-SolisSudoActionDigest @action -ActionTitle $title -ActionDescription $description
        (New-SolisSudoActionDigest @action -ActionTitle $title -ActionDescription $description) | Should Be $first
        (New-SolisSudoActionDigest @action -ActionTitle 'different' -ActionDescription $description) | Should Not Be $first
        (New-SolisSudoActionDigest @action -ActionTitle $title -ActionDescription 'different') | Should Not Be $first
    }
    It 'keeps legacy digest fields when both presentation parameters are omitted' {
        $record = & $module { param($a) Get-ActionRecord @a -Port 22 -TargetArgument @() -IdentityFile '' -TimeoutSeconds 120 -MaxOutputBytes 1048576 } $action
        $record.Count | Should Be 18
        $record.Contains('action_title') | Should Be $false
        $record.Contains('action_description') | Should Be $false
    }
    It 'rejects oversized or control-bearing descriptions and empty or invalid titles' {
        foreach ($value in @('', $null, ' ', "bad`n", "bad`r", "bad$([char]0)", ('a' * 129))) {
            { New-SolisSudoActionDigest @action -ActionTitle $value } | Should Throw 'ACTION_TITLE_INVALID'
        }
        foreach ($value in @("bad`n", "bad`r", "bad$([char]0)", ('a' * 513))) {
            { New-SolisSudoActionDigest @action -ActionDescription $value } | Should Throw 'ACTION_DESCRIPTION_INVALID'
        }
    }
    It 'rejects changed display text before WPF GUI and transport work' {
        Mock Test-WpfAvailable { throw 'UNEXPECTED_WPF' } -ModuleName $module.Name
        Mock Show-MaskedCredentialDialog { throw 'UNEXPECTED_GUI' } -ModuleName $module.Name
        Mock Invoke-ProcessWithSecret { throw 'UNEXPECTED_PROCESS' } -ModuleName $module.Name
        $digest = New-SolisSudoActionDigest @action -ActionTitle 'approved' -ActionDescription 'approved description'
        { Invoke-SolisMaskedSudoOverSsh @action -ActionTitle 'changed' -ActionDescription 'approved description' -ExpectedActionDigest $digest } | Should Throw 'ACTION_IDENTITY_DRIFT'
        { Invoke-SolisMaskedSudoOverSsh @action -ActionTitle 'approved' -ActionDescription 'changed' -ExpectedActionDigest $digest } | Should Throw 'ACTION_IDENTITY_DRIFT'
        Assert-MockCalled Test-WpfAvailable -ModuleName $module.Name -Times 0 -Exactly -Scope It
        Assert-MockCalled Show-MaskedCredentialDialog -ModuleName $module.Name -Times 0 -Exactly -Scope It
        Assert-MockCalled Invoke-ProcessWithSecret -ModuleName $module.Name -Times 0 -Exactly -Scope It
    }
    It 'forwards approved display text to the dialog and stops on cancellation' {
        $fixtureAction = $action.Clone()
        $fixtureAction.KnownHostsFile = Join-Path $TestDrive 'synthetic_known_hosts'
        [IO.File]::WriteAllText($fixtureAction.KnownHostsFile, 'SYNTHETIC-ONLY')
        Mock Test-WpfAvailable { $true } -ModuleName $module.Name
        Mock Test-GuiRuntimeContract { [pscustomobject]@{ Status = 'PASS' } } -ModuleName $module.Name
        Mock Show-MaskedCredentialDialog { [pscustomobject]@{ Status = 'CANCELLED'; Secret = $null } } -ModuleName $module.Name
        Mock Invoke-ProcessWithSecret { throw 'UNEXPECTED_PROCESS' } -ModuleName $module.Name
        $digest = New-SolisSudoActionDigest @fixtureAction -ActionTitle 'approved title' -ActionDescription 'approved description'
        { Invoke-SolisMaskedSudoOverSsh @fixtureAction -ActionTitle 'approved title' -ActionDescription 'approved description' -ExpectedActionDigest $digest } | Should Throw 'MASKED_INPUT_CANCELLED'
        Assert-MockCalled Show-MaskedCredentialDialog -ModuleName $module.Name -Times 1 -Exactly -Scope It -ParameterFilter { $ActionTitle -ceq 'approved title' -and $ActionDescription -ceq 'approved description' }
        Assert-MockCalled Invoke-ProcessWithSecret -ModuleName $module.Name -Times 0 -Exactly -Scope It
    }
    It 'validates without retaining a secret and disposes temporary input copies' {
        foreach ($sample in @(@{ A = ''; B = ''; Want = 'EMPTY' }, @{ A = 'a'; B = 'b'; Want = 'MISMATCH' }, @{ A = 'a'; B = 'a'; Want = 'SUCCESS' })) {
            $first = [Security.SecureString]::new()
            $second = [Security.SecureString]::new()
            foreach ($character in $sample.A.ToCharArray()) { $first.AppendChar($character) }
            foreach ($character in $sample.B.ToCharArray()) { $second.AppendChar($character) }
            $pair = & $module { param($a, $b) Resolve-SecureInputPair -First $a -Second $b -ValidateOnly } $first $second
            $pair.Status | Should Be $sample.Want
            $pair.Secret | Should Be $null
            foreach ($temporary in @($first, $second)) {
                $disposed = $false
                try { $temporary.AppendChar('x') } catch { $disposed = $true }
                $disposed | Should Be $true
            }
        }
    }
}

Describe 'Masked dialog real WPF synthetic interaction' {
    It 'runs a no-SSH STA window scenario <Scenario>' -TestCases @(
        @{ Scenario = 'Layout' }, @{ Scenario = 'FirstEnter' }, @{ Scenario = 'Tab' },
        @{ Scenario = 'SecondEnter' }, @{ Scenario = 'Click' }, @{ Scenario = 'Mismatch' },
        @{ Scenario = 'Empty' }, @{ Scenario = 'Escape' }, @{ Scenario = 'DoubleConfirm' },
        @{ Scenario = 'CorrectThenEnter' }, @{ Scenario = 'InvalidateAfterMatch' }, @{ Scenario = 'CloseCancel' }
    ) {
        param($Scenario)
        $fixture = Join-Path $PSScriptRoot 'fixtures/Invoke-MaskedDialogPreview.ps1'
        $info = [Diagnostics.ProcessStartInfo]::new()
        $info.FileName = 'C:\Program Files\PowerShell\7\pwsh.exe'
        $info.UseShellExecute = $false
        $info.CreateNoWindow = $true
        $info.RedirectStandardOutput = $true
        $info.RedirectStandardError = $true
        $info.StandardOutputEncoding = [Text.UTF8Encoding]::new($false)
        $info.StandardErrorEncoding = [Text.UTF8Encoding]::new($false)
        foreach ($arg in @('-NoLogo', '-NoProfile', '-Sta', '-File', $fixture, '-Scenario', $Scenario)) { [void]$info.ArgumentList.Add($arg) }
        $process = [Diagnostics.Process]::new()
        $process.StartInfo = $info
        try {
            [void]$process.Start()
            $stdout = $process.StandardOutput.ReadToEndAsync()
            $stderr = $process.StandardError.ReadToEndAsync()
            if (-not $process.WaitForExit(15000)) { $process.Kill($true); throw "UI_SCENARIO_TIMEOUT: $Scenario" }
            $errors = $stderr.GetAwaiter().GetResult()
            if ($process.ExitCode -ne 0) { throw "UI_SCENARIO_FAILED: $Scenario $errors $($stdout.GetAwaiter().GetResult())" }
            $value = $stdout.GetAwaiter().GetResult() | ConvertFrom-Json
            $value.Check | Should Be $true
            $value.Error | Should Be $null
        }
        finally { $process.Dispose() }
    }
}
