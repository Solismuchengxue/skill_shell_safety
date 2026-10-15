#requires -Version 7.0

$projectRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path
$portableRoot = Join-Path $projectRoot 'skills\powershell-bash-safety'
$modulePath = Join-Path $portableRoot 'scripts\Invoke-MaskedSudoOverSsh.psm1'
$remoteHelperPath = Join-Path $portableRoot 'scripts\Invoke-MaskedSudoOverSsh.Remote.sh'
$fixturePath = Join-Path $PSScriptRoot 'fixtures\SyntheticSshTransport.ps1'
$floodFixturePath = Join-Path $PSScriptRoot 'fixtures\SyntheticFloodTransport.ps1'
$syntheticSudoFixture = Join-Path $PSScriptRoot 'fixtures\synthetic-sudo.sh'
$syntheticTargetFixture = Join-Path $PSScriptRoot 'fixtures\synthetic-target.sh'
$syntheticLargeTargetFixture = Join-Path $PSScriptRoot 'fixtures\synthetic-large-output.sh'
$pwshPath = 'C:\Program Files\PowerShell\7\pwsh.exe'
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ("masked-sudo-pester-{0}" -f [guid]::NewGuid().ToString('N'))
$utf8NoBom = [Text.UTF8Encoding]::new($false)

function New-SyntheticSecureString {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Value)

    $secure = [Security.SecureString]::new()
    foreach ($character in $Value.ToCharArray()) {
        $secure.AppendChar($character)
    }
    $secure.MakeReadOnly()
    return $secure
}

function Get-SyntheticHash {
    param([Parameter(Mandatory)][string]$Value)

    $bytes = [Text.Encoding]::UTF8.GetBytes($Value)
    try {
        return [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes)).ToLowerInvariant()
    }
    finally {
        [Array]::Clear($bytes, 0, $bytes.Length)
    }
}

function Invoke-SyntheticProcess {
    param([Parameter(Mandatory)][Diagnostics.ProcessStartInfo]$StartInfo)

    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $StartInfo
    try {
        [void]$process.Start()
        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()
        $process.WaitForExit()
        [pscustomobject]@{
            ExitCode = $process.ExitCode
            StdOut = $stdoutTask.GetAwaiter().GetResult()
            StdErr = $stderrTask.GetAwaiter().GetResult()
        }
    }
    finally {
        $process.Dispose()
    }
}

Describe 'Masked sudo over SSH contract' {
    BeforeAll {
        [void][IO.Directory]::CreateDirectory($testRoot)
        $historyPath = Join-Path $testRoot 'synthetic-history.txt'
        [IO.File]::WriteAllText($historyPath, 'synthetic history baseline', $utf8NoBom)
        $knownHostsPath = Join-Path $testRoot 'known_hosts'
        [IO.File]::WriteAllText($knownHostsPath, 'synthetic.example ssh-ed25519 SYNTHETIC-BASELINE', $utf8NoBom)
        $module = Import-Module -Name $modulePath -Force -PassThru
        $moduleText = [IO.File]::ReadAllText($modulePath)
        $remoteText = [IO.File]::ReadAllText($remoteHelperPath)
        $commonAction = @{
            AuthorizationId = 'D10-SYNTHETIC-001'
            HostName = 'synthetic.example'
            UserName = 'operator'
            Port = 22
            TargetCommand = '/usr/bin/id'
            TargetArgument = @('-u')
            KnownHostsFile = $knownHostsPath
        }
        $gitPath = (Get-Command git.exe -ErrorAction Stop).Source
        $gitRoot = Split-Path -Parent (Split-Path -Parent $gitPath)
        $bashPath = Join-Path $gitRoot 'bin\bash.exe'
        $cygpathPath = Join-Path $gitRoot 'usr\bin\cygpath.exe'
        $gitBashSudoPath = Join-Path $gitRoot 'usr\bin\sudo.exe'
    }

    AfterAll {
        Remove-Module -Name $module.Name -Force -ErrorAction SilentlyContinue
        if (Test-Path -LiteralPath $testRoot) {
            Remove-Item -LiteralPath $testRoot -Recurse -Force
        }
    }

    It 'provides the portable module and deterministic remote helper' {
        (Test-Path -LiteralPath $modulePath -PathType Leaf) | Should Be $true
        (Test-Path -LiteralPath $remoteHelperPath -PathType Leaf) | Should Be $true
    }

    It 'exports only the digest planner and authorized invocation' {
        (@($module.ExportedFunctions.Keys | Sort-Object) -join ',') |
            Should Be 'Invoke-SolisMaskedSudoOverSsh,New-SolisSudoActionDigest'
    }

    It 'produces a stable action digest and changes it when the command changes' {
        $first = New-SolisSudoActionDigest @commonAction
        $second = New-SolisSudoActionDigest @commonAction
        $changedAction = $commonAction.Clone()
        $changedAction.TargetArgument = @('-g')
        $changed = New-SolisSudoActionDigest @changedAction
        $first | Should Match '^[a-f0-9]{64}$'
        $second | Should Be $first
        $changed | Should Not Be $first
    }

    Context 'Explicit HostKeyAlias contract' {
        It 'keeps the legacy record and argv when HostKeyAlias is omitted' {
            $record = & $module { param($action) Get-ActionRecord @action -IdentityFile '' -TimeoutSeconds 120 -MaxOutputBytes 1048576 } $commonAction
            ($record.Keys -join ',') | Should Be 'schema_version,authorization_id,host_name,user_name,port,target_command,target_arguments,known_hosts_file,known_hosts_sha256,identity_file,identity_file_state,identity_file_length,identity_file_mtime,timeout_seconds,max_output_bytes,ssh_path,ssh_sha256,remote_helper_sha256'
            $sshAction = $commonAction.Clone()
            $sshAction.Remove('AuthorizationId')
            $info = & $module { param($action, $helper) New-SshProcessStartInfo @action -SshPath 'C:\synthetic\ssh.exe' -RemoteHelperPath $helper } $sshAction $remoteHelperPath
            @($info.ArgumentList | Where-Object { $_ -like 'HostKeyAlias=*' }).Count | Should Be 0
        }

        It 'binds the exact alias and emits one independent option after disabling config' {
            $record = & $module { param($action) Get-ActionRecord @action -IdentityFile '' -TimeoutSeconds 120 -MaxOutputBytes 1048576 -HostKeyAlias fnos } $commonAction
            $record.host_key_alias | Should Be 'fnos'
            $sshAction = $commonAction.Clone()
            $sshAction.Remove('AuthorizationId')
            $info = & $module { param($action, $helper) New-SshProcessStartInfo @action -SshPath 'C:\synthetic\ssh.exe' -RemoteHelperPath $helper -HostKeyAlias fnos } $sshAction $remoteHelperPath
            $argv = @($info.ArgumentList)
            $argv[0] | Should Be '-F'
            $argv[1] | Should Be 'NUL'
            @($argv | Where-Object { $_ -ceq 'HostKeyAlias=fnos' }).Count | Should Be 1
            $argv[[Array]::IndexOf($argv, 'HostKeyAlias=fnos') - 1] | Should Be '-o'
            ($argv -contains 'StrictHostKeyChecking=yes') | Should Be $true
            ($argv -contains "UserKnownHostsFile=$knownHostsPath") | Should Be $true
        }

        It 'makes different aliases and omission distinct digests without case folding' {
            $legacy = New-SolisSudoActionDigest @commonAction
            $lower = New-SolisSudoActionDigest @commonAction -HostKeyAlias fnos
            $upper = New-SolisSudoActionDigest @commonAction -HostKeyAlias FNOS
            $other = New-SolisSudoActionDigest @commonAction -HostKeyAlias other
            $lower | Should Not Be $legacy
            $upper | Should Not Be $lower
            $other | Should Not Be $lower
            (New-SolisSudoActionDigest @commonAction -HostKeyAlias fnos) | Should Be $lower
        }

        It 'accepts bounded ASCII tokens without changing their bytes' {
            foreach ($alias in @('a', 'Fnos_1.example-2', ('a' * 253))) {
                $record = & $module { param($action, $value) Get-ActionRecord @action -IdentityFile '' -TimeoutSeconds 120 -MaxOutputBytes 1048576 -HostKeyAlias $value } $commonAction $alias
                $record.host_key_alias | Should Be $alias
            }
        }

        It 'rejects empty, controls, whitespace, option and shell injections at every entry' {
            $sshAction = $commonAction.Clone()
            $sshAction.Remove('AuthorizationId')
            $invalidAliases = @('', $null, "fnos`r", "fnos`n", "fnos$([char]0)", "fnos`t", ' fnos', 'fnos ', '-oProxyCommand=evil', 'fnos -o StrictHostKeyChecking=no', 'fnos=evil', 'fnos;evil', 'fnos"', "fnos'", 'fnos/evil', 'fnos\evil', 'fnos*', 'fnos,evil', 'fnos:22', '测试', ('a' * 254))
            $invalidAliases.Count | Should Be 21
            foreach ($alias in $invalidAliases) {
                { New-SolisSudoActionDigest @commonAction -HostKeyAlias $alias } | Should Throw 'SSH_HOST_KEY_ALIAS_INVALID'
                { Invoke-SolisMaskedSudoOverSsh @commonAction -HostKeyAlias $alias -ExpectedActionDigest ('0' * 64) } | Should Throw 'SSH_HOST_KEY_ALIAS_INVALID'
                { & $module { param($action, $helper, $value) New-SshProcessStartInfo @action -SshPath 'C:\synthetic\ssh.exe' -RemoteHelperPath $helper -HostKeyAlias $value } $sshAction $remoteHelperPath $alias } | Should Throw 'SSH_HOST_KEY_ALIAS_INVALID'
            }
        }

        It 'blocks alias addition, removal and drift before GUI or transport' {
            Mock Test-WpfAvailable { throw 'UNEXPECTED_WPF_WORK' } -ModuleName $module.Name
            Mock Show-MaskedCredentialDialog { throw 'UNEXPECTED_GUI' } -ModuleName $module.Name
            Mock Invoke-ProcessWithSecret { throw 'UNEXPECTED_PROCESS' } -ModuleName $module.Name
            $approved = New-SolisSudoActionDigest @commonAction -HostKeyAlias fnos
            $legacy = New-SolisSudoActionDigest @commonAction
            { Invoke-SolisMaskedSudoOverSsh @commonAction -HostKeyAlias other -ExpectedActionDigest $approved } | Should Throw 'ACTION_IDENTITY_DRIFT'
            { Invoke-SolisMaskedSudoOverSsh @commonAction -ExpectedActionDigest $approved } | Should Throw 'ACTION_IDENTITY_DRIFT'
            { Invoke-SolisMaskedSudoOverSsh @commonAction -HostKeyAlias fnos -ExpectedActionDigest $legacy } | Should Throw 'ACTION_IDENTITY_DRIFT'
            Assert-MockCalled Test-WpfAvailable -ModuleName $module.Name -Times 0 -Exactly -Scope It
            Assert-MockCalled Show-MaskedCredentialDialog -ModuleName $module.Name -Times 0 -Exactly -Scope It
            Assert-MockCalled Invoke-ProcessWithSecret -ModuleName $module.Name -Times 0 -Exactly -Scope It
        }

        It 'shows the alias in action confirmation and carries it to the guarded transport' {
            Mock Test-WpfAvailable { $true } -ModuleName $module.Name
            Mock Test-GuiRuntimeContract { [pscustomobject]@{ Status = 'PASS' } } -ModuleName $module.Name
            Mock Show-MaskedCredentialDialog {
                $secret = [Security.SecureString]::new()
                $secret.AppendChar('x')
                $secret.MakeReadOnly()
                [pscustomobject]@{ Status = 'SUCCESS'; Secret = $secret }
            } -ModuleName $module.Name
            Mock Invoke-ProcessWithSecret {
                [pscustomobject]@{ ExitCode = 0; StdOut = "SOLIS_SUDO_V1 SUDO_STDOUT `nSOLIS_SUDO_V1 SUDO_STDERR `nSOLIS_SUDO_V1 TARGET_STDOUT `nSOLIS_SUDO_V1 TARGET_STDERR `nSOLIS_SUDO_V1 RESULT sudo_exit=0 target_started=1 target_exit=0"; StdErr = ''; OutputLimitExceeded = $false }
            } -ModuleName $module.Name
            $approved = New-SolisSudoActionDigest @commonAction -HostKeyAlias fnos
            $result = Invoke-SolisMaskedSudoOverSsh @commonAction -HostKeyAlias fnos -ExpectedActionDigest $approved
            $result.Result | Should Be 'PASS'
            Assert-MockCalled Show-MaskedCredentialDialog -ModuleName $module.Name -Times 1 -Exactly -Scope It -ParameterFilter { $HostKeyAlias -ceq 'fnos' -and $Destination -ceq 'operator@synthetic.example:22' -and $ActionDigest -match '^[a-f0-9]{64}$' }
            Assert-MockCalled Invoke-ProcessWithSecret -ModuleName $module.Name -Times 1 -Exactly -Scope It -ParameterFilter { @($StartInfo.ArgumentList | Where-Object { $_ -ceq 'HostKeyAlias=fnos' }).Count -eq 1 }
        }

        It 'blocks post-input identity drift and disposes synthetic input without transport' {
            $aliasTestState = @{ Secret = [Security.SecureString]::new(); KnownHostsPath = $knownHostsPath }
            $aliasTestState.Secret.AppendChar('x')
            & $module { param($state) $script:AliasTestState = $state } $aliasTestState
            Mock Test-WpfAvailable { $true } -ModuleName $module.Name
            Mock Test-GuiRuntimeContract { [pscustomobject]@{ Status = 'PASS' } } -ModuleName $module.Name
            Mock Show-MaskedCredentialDialog {
                $state = & (Get-Module Invoke-MaskedSudoOverSsh) { $script:AliasTestState }
                [IO.File]::WriteAllText($state.KnownHostsPath, 'synthetic-drift-after-input')
                [pscustomobject]@{ Status = 'SUCCESS'; Secret = $state.Secret }
            } -ModuleName $module.Name
            Mock Invoke-ProcessWithSecret { throw 'UNEXPECTED_PROCESS' } -ModuleName $module.Name
            $approved = New-SolisSudoActionDigest @commonAction -HostKeyAlias fnos
            try {
                { Invoke-SolisMaskedSudoOverSsh @commonAction -HostKeyAlias fnos -ExpectedActionDigest $approved } | Should Throw 'ACTION_IDENTITY_DRIFT_AFTER_INPUT'
                $disposed = $false
                try { $aliasTestState.Secret.AppendChar('y') }
                catch { $disposed = $true }
                $disposed | Should Be $true
                Assert-MockCalled Invoke-ProcessWithSecret -ModuleName $module.Name -Times 0 -Exactly -Scope It
            }
            finally {
                [IO.File]::WriteAllText($knownHostsPath, 'synthetic.example ssh-ed25519 SYNTHETIC-BASELINE', $utf8NoBom)
                $aliasTestState.Secret.Dispose()
                & $module { Remove-Variable -Name AliasTestState -Scope Script -ErrorAction SilentlyContinue }
            }
        }
    }

    It 'changes the action digest when known_hosts content drifts' {
        $baseline = New-SolisSudoActionDigest @commonAction
        try {
            [IO.File]::WriteAllText($knownHostsPath, 'synthetic.example ssh-ed25519 SYNTHETIC-DRIFT', $utf8NoBom)
            $drifted = New-SolisSudoActionDigest @commonAction
        }
        finally {
            [IO.File]::WriteAllText($knownHostsPath, 'synthetic.example ssh-ed25519 SYNTHETIC-BASELINE', $utf8NoBom)
        }
        $drifted | Should Not Be $baseline
    }

    It 'changes the action digest when synthetic identity-file metadata drifts' {
        $identityPath = Join-Path $testRoot 'synthetic-identity'
        [IO.File]::WriteAllText($identityPath, 'synthetic-identity-baseline', $utf8NoBom)
        $identityAction = $commonAction.Clone()
        $identityAction.IdentityFile = $identityPath
        $baseline = New-SolisSudoActionDigest @identityAction
        [IO.File]::WriteAllText($identityPath, 'synthetic-identity-drift-with-different-length', $utf8NoBom)
        $drifted = New-SolisSudoActionDigest @identityAction
        $drifted | Should Not Be $baseline
    }

    It 'changes the action digest when MaxOutputBytes changes' {
        $small = New-SolisSudoActionDigest @commonAction -MaxOutputBytes 128
        $large = New-SolisSudoActionDigest @commonAction -MaxOutputBytes 256
        $large | Should Not Be $small
    }

    It 'rejects a non-absolute target command' {
        $invalidAction = $commonAction.Clone()
        $invalidAction.TargetCommand = 'id'
        { New-SolisSudoActionDigest @invalidAction } |
            Should Throw 'TARGET_COMMAND_NOT_ABSOLUTE'
    }

    It 'rejects control characters in target arguments' {
        $invalidAction = $commonAction.Clone()
        $invalidAction.TargetArgument = @("safe`nunsafe")
        { New-SolisSudoActionDigest @invalidAction } |
            Should Throw 'TARGET_ARGUMENT_CONTROL_CHARACTER'
    }

    It 'rejects action identity drift before any GUI or SSH work' {
        $approved = New-SolisSudoActionDigest @commonAction
        $driftedAction = $commonAction.Clone()
        $driftedAction.TargetArgument = @('-g')
        { Invoke-SolisMaskedSudoOverSsh @driftedAction -ExpectedActionDigest $approved } |
            Should Throw 'ACTION_IDENTITY_DRIFT'
    }

    It 'fails closed outside Windows' {
        $result = & $module { Test-GuiRuntimeContract -Windows $false -ApartmentState STA -WpfAvailable $true }
        $result.Status | Should Be 'GUI_UNAVAILABLE_NON_WINDOWS'
    }

    It 'fails closed when the calling PowerShell thread is not STA' {
        $result = & $module { Test-GuiRuntimeContract -Windows $true -ApartmentState MTA -WpfAvailable $true }
        $result.Status | Should Be 'GUI_REQUIRES_STA'
    }

    It 'fails closed when WPF is unavailable' {
        $result = & $module { Test-GuiRuntimeContract -Windows $true -ApartmentState STA -WpfAvailable $false }
        $result.Status | Should Be 'GUI_WPF_UNAVAILABLE'
    }

    It 'fails closed without an interactive desktop session' {
        $result = & $module {
            Test-GuiRuntimeContract `
                -Windows $true `
                -ApartmentState STA `
                -WpfAvailable $true `
                -UserInteractive $false `
                -SessionId 1
        }
        $result.Status | Should Be 'GUI_SESSION_NOT_INTERACTIVE'
    }

    It 'returns CANCELLED without accepting any secret' {
        $result = & $module { Resolve-SecureInputPair -Cancelled }
        $result.Status | Should Be 'CANCELLED'
        $result.Secret | Should Be $null
    }

    It 'rejects an empty masked input pair' {
        $first = New-SyntheticSecureString ''
        $second = New-SyntheticSecureString ''
        $result = & $module { param($a, $b) Resolve-SecureInputPair -First $a -Second $b } $first $second
        $result.Status | Should Be 'EMPTY'
        $result.Secret | Should Be $null
    }

    It 'rejects two different masked inputs' {
        $first = New-SyntheticSecureString 'synthetic-one'
        $second = New-SyntheticSecureString 'synthetic-two'
        $result = & $module { param($a, $b) Resolve-SecureInputPair -First $a -Second $b } $first $second
        $result.Status | Should Be 'MISMATCH'
        $result.Secret | Should Be $null
    }

    It 'returns a read-only SecureString only for a matching non-empty pair' {
        $first = New-SyntheticSecureString 'synthetic-match'
        $second = New-SyntheticSecureString 'synthetic-match'
        $result = & $module { param($a, $b) Resolve-SecureInputPair -First $a -Second $b } $first $second
        $result.Status | Should Be 'SUCCESS'
        ($result.Secret -is [Security.SecureString]) | Should Be $true
        $result.Secret.IsReadOnly() | Should Be $true
        $result.Secret.Dispose()
    }

    It 'builds SSH with structured argv, no PTY and no interactive SSH fallback' {
        $startInfo = & $module {
            param($helper)
            New-SshProcessStartInfo `
                -SshPath 'C:\synthetic\ssh.exe' `
                -HostName 'synthetic.example' `
                -UserName 'operator' `
                -Port 22 `
                -TargetCommand '/usr/bin/id' `
                -TargetArgument @('-u') `
                -KnownHostsFile 'C:\synthetic\known_hosts' `
                -RemoteHelperPath $helper
        } $remoteHelperPath
        $arguments = @($startInfo.ArgumentList)
        ($arguments -join "`n") | Should Match 'BatchMode=yes'
        ($arguments -join "`n") | Should Match 'PasswordAuthentication=no'
        ($arguments -join "`n") | Should Match 'KbdInteractiveAuthentication=no'
        ($arguments -join "`n") | Should Match 'NumberOfPasswordPrompts=0'
        ($arguments -join "`n") | Should Match 'StrictHostKeyChecking=yes'
        ($arguments -join "`n") | Should Match 'RequestTTY=no'
        ($arguments -contains '-T') | Should Be $true
        $startInfo.UseShellExecute | Should Be $false
        $startInfo.CreateNoWindow | Should Be $true
        $startInfo.RedirectStandardInput | Should Be $true
        $startInfo.RedirectStandardOutput | Should Be $true
        $startInfo.RedirectStandardError | Should Be $true
    }

    It 'uses WPF PasswordBox SecurePassword and has no console or environment secret fallback' {
        $moduleText | Should Match 'Windows\.Controls\.PasswordBox'
        $moduleText | Should Match '\.SecurePassword'
        $moduleText | Should Match '\.ShowDialog\('
        $moduleText | Should Match 'Topmost'
        $moduleText | Should Match 'ShowInTaskbar'
        $moduleText | Should Not Match '\.Password\b'
        $moduleText | Should Not Match 'Read-Host'
        $moduleText | Should Not Match 'Console\]::Read'
        $moduleText | Should Not Match '\.Environment\['
        $moduleText | Should Not Match 'PSReadLine'
    }

    It 'rechecks action identity after the GUI and always disposes the accepted value' {
        $moduleText | Should Match 'ACTION_IDENTITY_DRIFT_AFTER_INPUT'
        $moduleText | Should Match '(?s)try\s*\{.*Invoke-ProcessWithSecret.*\}\s*finally\s*\{\s*\$dialog\.Secret\.Dispose\(\)'
    }

    It 'transmits a pressure sentinel only through stdin and disposes the SecureString' {
        $sentinel = ('SYNTHETIC !''"$ unicode-测试 ' + ('x' * 2048))
        $secure = New-SyntheticSecureString $sentinel
        $startInfo = [Diagnostics.ProcessStartInfo]::new()
        $startInfo.FileName = $pwshPath
        $startInfo.UseShellExecute = $false
        $startInfo.CreateNoWindow = $true
        $startInfo.RedirectStandardInput = $true
        $startInfo.RedirectStandardOutput = $true
        $startInfo.RedirectStandardError = $true
        [void]$startInfo.ArgumentList.Add('-NoLogo')
        [void]$startInfo.ArgumentList.Add('-NoProfile')
        [void]$startInfo.ArgumentList.Add('-ExecutionPolicy')
        [void]$startInfo.ArgumentList.Add('Bypass')
        [void]$startInfo.ArgumentList.Add('-File')
        [void]$startInfo.ArgumentList.Add($fixturePath)

        (@($startInfo.ArgumentList) -join "`n") | Should Not Match ([regex]::Escape($sentinel))
        $execution = & $module {
            param($info, $secret)
            $transport = Invoke-ProcessWithSecret -StartInfo $info -Secret $secret -TimeoutSeconds 15
            $disposed = $false
            try {
                $secret.AppendChar('x')
            }
            catch {
                $disposed = $true
            }
            [pscustomobject]@{ Transport = $transport; SecretDisposed = $disposed }
        } $startInfo $secure
        $raw = $execution.Transport
        $execution.SecretDisposed | Should Be $true
        $raw.StdOut | Should Not Match ([regex]::Escape($sentinel))
        $raw.StdErr | Should Not Match ([regex]::Escape($sentinel))
        $parsed = & $module {
            param($transport)
            ConvertFrom-SudoProtocol -SshExitCode $transport.ExitCode -SshStdOut $transport.StdOut -SshStdErr $transport.StdErr
        } $raw
        $parsed.Target.StdOut | Should Match ("byte_count={0}" -f [Text.Encoding]::UTF8.GetByteCount($sentinel))
        $parsed.Target.StdOut | Should Match ([regex]::Escape((Get-SyntheticHash $sentinel)))
        $parsed.Target.StdOut | Should Match 'line_ending=lf'
        [IO.File]::ReadAllText($historyPath) | Should Be 'synthetic history baseline'
        $filesText = @(Get-ChildItem -LiteralPath $testRoot -Recurse -File | ForEach-Object { [IO.File]::ReadAllText($_.FullName) }) -join "`n"
        $filesText | Should Not Match ([regex]::Escape($sentinel))
        $secure.Dispose()
    }

    It 'fails closed when the SSH executable cannot start' {
        $secure = New-SyntheticSecureString 'synthetic-start-failure'
        $startInfo = [Diagnostics.ProcessStartInfo]::new()
        $startInfo.FileName = Join-Path $testRoot 'missing-ssh.exe'
        $startInfo.UseShellExecute = $false
        $startInfo.RedirectStandardInput = $true
        $startInfo.RedirectStandardOutput = $true
        $startInfo.RedirectStandardError = $true
        { & $module {
                param($info, $secret)
                Invoke-ProcessWithSecret -StartInfo $info -Secret $secret -TimeoutSeconds 2
            } $startInfo $secure } | Should Throw 'SSH_START_FAILED'
    }

    It 'bounds local transport capture without ReadToEndAsync' {
        $moduleText | Should Not Match 'ReadToEndAsync'
        $secure = New-SyntheticSecureString 'synthetic-local-output-limit'
        $startInfo = [Diagnostics.ProcessStartInfo]::new()
        $startInfo.FileName = $pwshPath
        $startInfo.UseShellExecute = $false
        $startInfo.CreateNoWindow = $true
        $startInfo.RedirectStandardInput = $true
        $startInfo.RedirectStandardOutput = $true
        $startInfo.RedirectStandardError = $true
        [void]$startInfo.ArgumentList.Add('-NoLogo')
        [void]$startInfo.ArgumentList.Add('-NoProfile')
        [void]$startInfo.ArgumentList.Add('-ExecutionPolicy')
        [void]$startInfo.ArgumentList.Add('Bypass')
        [void]$startInfo.ArgumentList.Add('-File')
        [void]$startInfo.ArgumentList.Add($floodFixturePath)
        $raw = & $module {
            param($info, $value)
            Invoke-ProcessWithSecret `
                -StartInfo $info `
                -Secret $value `
                -TimeoutSeconds 15 `
                -MaxStdOutBytes 128 `
                -MaxStdErrBytes 128
        } $startInfo $secure
        $raw.OutputLimitExceeded | Should Be $true
        ([Text.Encoding]::UTF8.GetByteCount($raw.StdOut) -le 128) | Should Be $true
        $secure.Dispose()
    }

    It 'parses SSH, sudo and target into separate result layers' {
        $targetOut = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes('target output'))
        $targetErr = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes('target error'))
        $protocol = @(
            'SOLIS_SUDO_V1 SUDO_STDOUT '
            'SOLIS_SUDO_V1 SUDO_STDERR '
            "SOLIS_SUDO_V1 TARGET_STDOUT $targetOut"
            "SOLIS_SUDO_V1 TARGET_STDERR $targetErr"
            'SOLIS_SUDO_V1 RESULT sudo_exit=7 target_started=1 target_exit=7'
        ) -join "`n"
        $result = & $module {
            param($text)
            ConvertFrom-SudoProtocol -SshExitCode 0 -SshStdOut $text -SshStdErr ''
        } $protocol
        $result.Ssh.ExitCode | Should Be 0
        $result.Sudo.ExitCode | Should Be 7
        $result.Target.ExitCode | Should Be 7
        $result.Target.StdOut | Should Be 'target output'
        $result.Target.StdErr | Should Be 'target error'
        $result.Result | Should Be 'FAIL'
        $result.ErrorLayer | Should Be 'Target'
    }

    It 'rejects an incomplete remote protocol even when SSH exits zero' {
        $result = & $module {
            ConvertFrom-SudoProtocol -SshExitCode 0 -SshStdOut 'SOLIS_SUDO_V1 SUDO_STDOUT ' -SshStdErr ''
        }
        $result.Result | Should Be 'FAIL'
        $result.ErrorLayer | Should Be 'RemoteProtocol'
    }

    It 'keeps password off remote disk and defines exact FIFO cleanup and target stdin EOF' {
        $remoteText | Should Match 'umask 077'
        $remoteText | Should Match 'mktemp -d'
        $remoteText | Should Match 'mkfifo'
        $remoteText | Should Match 'trap cleanup 0 1 2 15'
        $remoteText | Should Match "sudo -S -p '' --"
        $remoteText | Should Match '</dev/null'
        $remoteText | Should Match 'base64'
        $remoteText | Should Not Match '\becho\b'
        $remoteText | Should Not Match '(?i)password|credential|secret'
    }

    It 'runs the remote FIFO protocol with synthetic sudo and leaves no work-root residue' {
        (Test-Path -LiteralPath $bashPath -PathType Leaf) | Should Be $true
        (Test-Path -LiteralPath $cygpathPath -PathType Leaf) | Should Be $true
        $fakeBin = Join-Path $testRoot 'fake-bin'
        $remoteTemp = Join-Path $testRoot 'remote-temp'
        [void][IO.Directory]::CreateDirectory($fakeBin)
        [void][IO.Directory]::CreateDirectory($remoteTemp)
        $fakeSudo = Join-Path $fakeBin 'sudo'
        [IO.File]::Copy($syntheticSudoFixture, $fakeSudo, $true)
        $fakeBinMsys = (& $cygpathPath -u $fakeBin).Trim()
        $remoteTempMsys = (& $cygpathPath -u $remoteTemp).Trim()
        $remoteHelperMsys = (& $cygpathPath -u $remoteHelperPath).Trim()
        $targetMsys = (& $cygpathPath -u $syntheticTargetFixture).Trim()

        $startInfo = [Diagnostics.ProcessStartInfo]::new()
        $startInfo.FileName = $bashPath
        $startInfo.UseShellExecute = $false
        $startInfo.CreateNoWindow = $true
        $startInfo.RedirectStandardInput = $true
        $startInfo.RedirectStandardOutput = $true
        $startInfo.RedirectStandardError = $true
        $startInfo.Environment['PATH'] = "$fakeBinMsys`:/usr/bin:/bin"
        $startInfo.Environment['TMPDIR'] = $remoteTempMsys
        [void]$startInfo.ArgumentList.Add($remoteHelperMsys)
        [void]$startInfo.ArgumentList.Add('1048576')
        [void]$startInfo.ArgumentList.Add($targetMsys)
        $sentinel = 'SYNTHETIC-REMOTE-PRESSURE-ONLY'
        $secure = New-SyntheticSecureString $sentinel
        $raw = & $module {
            param($info, $value)
            Invoke-ProcessWithSecret -StartInfo $info -Secret $value -TimeoutSeconds 15
        } $startInfo $secure
        $result = & $module {
            param($transport)
            ConvertFrom-SudoProtocol -SshExitCode $transport.ExitCode -SshStdOut $transport.StdOut -SshStdErr $transport.StdErr
        } $raw
        $result.ErrorLayer | Should Be 'Target'
        $result.Sudo.ExitCode | Should Be 7
        $result.Target.ExitCode | Should Be 7
        $result.Target.StdOut | Should Be 'synthetic target output'
        $result.Target.StdErr | Should Be 'synthetic target error'
        ($raw.StdOut + $raw.StdErr) | Should Not Match ([regex]::Escape($sentinel))
        @(Get-ChildItem -LiteralPath $remoteTemp -Force).Count | Should Be 0
        $secure.Dispose()
    }

    It 'fails remote preflight before creating a work root when sudo is unavailable' {
        if (Test-Path -LiteralPath $gitBashSudoPath) {
            throw 'SYNTHETIC_PREFLIGHT_REQUIRES_GIT_BASH_WITHOUT_SUDO'
        }
        $remoteTemp = Join-Path $testRoot 'remote-preflight-temp'
        [void][IO.Directory]::CreateDirectory($remoteTemp)
        $remoteTempMsys = (& $cygpathPath -u $remoteTemp).Trim()
        $remoteHelperMsys = (& $cygpathPath -u $remoteHelperPath).Trim()
        $startInfo = [Diagnostics.ProcessStartInfo]::new()
        $startInfo.FileName = $bashPath
        $startInfo.UseShellExecute = $false
        $startInfo.CreateNoWindow = $true
        $startInfo.RedirectStandardOutput = $true
        $startInfo.RedirectStandardError = $true
        $startInfo.Environment['PATH'] = '/usr/bin:/bin'
        $startInfo.Environment['TMPDIR'] = $remoteTempMsys
        [void]$startInfo.ArgumentList.Add($remoteHelperMsys)
        [void]$startInfo.ArgumentList.Add('1048576')
        [void]$startInfo.ArgumentList.Add('/usr/bin/true')
        $raw = Invoke-SyntheticProcess -StartInfo $startInfo
        $raw.ExitCode | Should Be 95
        $raw.StdOut | Should Match 'SOLIS_SUDO_V1 ERROR REMOTE_HELPER_PRECONDITION_FAILED'
        @(Get-ChildItem -LiteralPath $remoteTemp -Force).Count | Should Be 0
    }

    It 'fails closed and cleans up when a remote stream exceeds MaxOutputBytes' {
        $fakeBin = Join-Path $testRoot 'limit-fake-bin'
        $remoteTemp = Join-Path $testRoot 'limit-remote-temp'
        [void][IO.Directory]::CreateDirectory($fakeBin)
        [void][IO.Directory]::CreateDirectory($remoteTemp)
        [IO.File]::Copy($syntheticSudoFixture, (Join-Path $fakeBin 'sudo'), $true)
        $fakeBinMsys = (& $cygpathPath -u $fakeBin).Trim()
        $remoteTempMsys = (& $cygpathPath -u $remoteTemp).Trim()
        $remoteHelperMsys = (& $cygpathPath -u $remoteHelperPath).Trim()
        $largeTargetMsys = (& $cygpathPath -u $syntheticLargeTargetFixture).Trim()

        $startInfo = [Diagnostics.ProcessStartInfo]::new()
        $startInfo.FileName = $bashPath
        $startInfo.UseShellExecute = $false
        $startInfo.CreateNoWindow = $true
        $startInfo.RedirectStandardInput = $true
        $startInfo.RedirectStandardOutput = $true
        $startInfo.RedirectStandardError = $true
        $startInfo.Environment['PATH'] = "$fakeBinMsys`:/usr/bin:/bin"
        $startInfo.Environment['TMPDIR'] = $remoteTempMsys
        [void]$startInfo.ArgumentList.Add($remoteHelperMsys)
        [void]$startInfo.ArgumentList.Add('128')
        [void]$startInfo.ArgumentList.Add($largeTargetMsys)
        $secure = New-SyntheticSecureString 'synthetic-remote-output-limit'
        $raw = & $module {
            param($info, $value)
            Invoke-ProcessWithSecret -StartInfo $info -Secret $value -TimeoutSeconds 15
        } $startInfo $secure
        $result = & $module {
            param($transport)
            ConvertFrom-SudoProtocol -SshExitCode $transport.ExitCode -SshStdOut $transport.StdOut -SshStdErr $transport.StdErr
        } $raw
        $result.Result | Should Be 'FAIL'
        $result.ErrorLayer | Should Be 'OutputLimit'
        $result.FailureCode | Should Be 'OUTPUT_LIMIT_EXCEEDED'
        @(Get-ChildItem -LiteralPath $remoteTemp -Force).Count | Should Be 0
        $secure.Dispose()
    }
}
