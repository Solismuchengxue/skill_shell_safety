#requires -Version 7.0

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Resolve-HostKeyAlias {
    param(
        [Parameter()][AllowNull()][AllowEmptyString()][string]$Value,
        [Parameter(Mandatory)][bool]$Specified
    )

    if (-not $Specified) {
        return ''
    }
    # Deliberately narrow ASCII token contract; no trim/case folding or config parsing.
    # Absolute anchors reject trailing LF as well as option/argument delimiters.
    if ($Value -cnotmatch '\A[A-Za-z0-9][A-Za-z0-9._-]{0,252}\z') {
        throw 'SSH_HOST_KEY_ALIAS_INVALID'
    }
    return $Value
}

function Assert-ActionDisplayText {
    param(
        [AllowNull()][AllowEmptyString()][string]$Value,
        [int]$MaxLength,
        [string]$FailureCode,
        [switch]$AllowEmpty
    )
    $text = if ($null -eq $Value) { '' } else { $Value }
    if (($text.Length -eq 0 -and -not $AllowEmpty) -or
        ($text.Length -gt 0 -and [string]::IsNullOrWhiteSpace($text)) -or
        $text.Length -gt $MaxLength -or $text.IndexOfAny([char[]]@(0, 10, 13)) -ge 0) {
        throw $FailureCode
    }
}

function Assert-ActionInput {
    param(
        [Parameter(Mandatory)][string]$AuthorizationId,
        [Parameter(Mandatory)][string]$HostName,
        [Parameter(Mandatory)][string]$UserName,
        [Parameter(Mandatory)][int]$Port,
        [Parameter(Mandatory)][string]$TargetCommand,
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$TargetArgument,
        [Parameter(Mandatory)][string]$KnownHostsFile,
        [Parameter()][AllowEmptyString()][string]$IdentityFile
    )

    if ($AuthorizationId -notmatch '^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$') {
        throw 'AUTHORIZATION_ID_INVALID'
    }
    if ($HostName -notmatch '^[A-Za-z0-9][A-Za-z0-9.-]{0,252}$') {
        throw 'SSH_HOST_INVALID'
    }
    if ($UserName -notmatch '^[A-Za-z_][A-Za-z0-9_.-]{0,63}$') {
        throw 'SSH_USER_INVALID'
    }
    if ($Port -lt 1 -or $Port -gt 65535) {
        throw 'SSH_PORT_INVALID'
    }
    if (-not $TargetCommand.StartsWith('/', [StringComparison]::Ordinal)) {
        throw 'TARGET_COMMAND_NOT_ABSOLUTE'
    }
    if ($TargetCommand.IndexOfAny([char[]]@(0, 10, 13)) -ge 0) {
        throw 'TARGET_COMMAND_CONTROL_CHARACTER'
    }
    foreach ($argument in @($TargetArgument)) {
        if ($null -eq $argument -or $argument.IndexOfAny([char[]]@(0, 10, 13)) -ge 0) {
            throw 'TARGET_ARGUMENT_CONTROL_CHARACTER'
        }
    }
    if (-not [IO.Path]::IsPathFullyQualified($KnownHostsFile)) {
        throw 'KNOWN_HOSTS_PATH_NOT_ABSOLUTE'
    }
    if ($IdentityFile -and -not [IO.Path]::IsPathFullyQualified($IdentityFile)) {
        throw 'IDENTITY_PATH_NOT_ABSOLUTE'
    }
}

function Get-PortableHelperPath {
    return Join-Path $PSScriptRoot 'Invoke-MaskedSudoOverSsh.Remote.sh'
}

function Get-FileSha256Text {
    param([Parameter(Mandatory)][string]$LiteralPath)

    $item = Get-Item -LiteralPath $LiteralPath -Force -ErrorAction SilentlyContinue
    if ($null -eq $item -or $item.PSIsContainer) {
        return 'missing'
    }
    if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) {
        return 'reparse-point'
    }
    $bytes = [IO.File]::ReadAllBytes($LiteralPath)
    try {
        return [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes)).ToLowerInvariant()
    }
    finally {
        if ($bytes.Length -gt 0) {
            [Array]::Clear($bytes, 0, $bytes.Length)
        }
    }
}

function Get-FileMetadataIdentity {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$LiteralPath)

    if (-not $LiteralPath) {
        return [ordered]@{ state = 'not-specified'; length = -1; last_write_utc_ticks = -1 }
    }
    $item = Get-Item -LiteralPath $LiteralPath -Force -ErrorAction SilentlyContinue
    if ($null -eq $item -or $item.PSIsContainer) {
        return [ordered]@{ state = 'missing'; length = -1; last_write_utc_ticks = -1 }
    }
    if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) {
        return [ordered]@{ state = 'reparse-point'; length = -1; last_write_utc_ticks = -1 }
    }
    return [ordered]@{
        state = 'file'
        length = [long]$item.Length
        last_write_utc_ticks = [long]$item.LastWriteTimeUtc.Ticks
    }
}

function Get-ActionRecord {
    param(
        [Parameter(Mandatory)][string]$AuthorizationId,
        [Parameter(Mandatory)][string]$HostName,
        [Parameter(Mandatory)][string]$UserName,
        [Parameter(Mandatory)][int]$Port,
        [Parameter(Mandatory)][string]$TargetCommand,
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$TargetArgument,
        [Parameter(Mandatory)][string]$KnownHostsFile,
        [Parameter()][AllowEmptyString()][string]$IdentityFile,
        [Parameter(Mandatory)][int]$TimeoutSeconds,
        [Parameter(Mandatory)][int]$MaxOutputBytes,
        [Parameter()][AllowNull()][AllowEmptyString()][string]$HostKeyAlias,
        [Parameter()][AllowNull()][AllowEmptyString()][string]$ActionTitle,
        [Parameter()][AllowNull()][AllowEmptyString()][string]$ActionDescription
    )

    $normalizedAlias = Resolve-HostKeyAlias -Value $HostKeyAlias -Specified $PSBoundParameters.ContainsKey('HostKeyAlias')
    if ($PSBoundParameters.ContainsKey('ActionTitle')) {
        Assert-ActionDisplayText -Value $ActionTitle -MaxLength 128 -FailureCode 'ACTION_TITLE_INVALID'
    }
    if ($PSBoundParameters.ContainsKey('ActionDescription')) {
        Assert-ActionDisplayText -Value $ActionDescription -MaxLength 512 -FailureCode 'ACTION_DESCRIPTION_INVALID' -AllowEmpty
    }
    Assert-ActionInput `
        -AuthorizationId $AuthorizationId `
        -HostName $HostName `
        -UserName $UserName `
        -Port $Port `
        -TargetCommand $TargetCommand `
        -TargetArgument $TargetArgument `
        -KnownHostsFile $KnownHostsFile `
        -IdentityFile $IdentityFile
    $sshPath = 'C:\Windows\System32\OpenSSH\ssh.exe'
    $remoteHelperPath = Get-PortableHelperPath
    $identityMetadata = Get-FileMetadataIdentity -LiteralPath $IdentityFile
    $record = [ordered]@{
        schema_version       = 1
        authorization_id     = $AuthorizationId
        host_name            = $HostName
        user_name            = $UserName
        port                 = $Port
        target_command       = $TargetCommand
        target_arguments     = [object[]]@($TargetArgument)
        known_hosts_file     = $KnownHostsFile
        known_hosts_sha256   = Get-FileSha256Text -LiteralPath $KnownHostsFile
        identity_file        = if ($IdentityFile) { $IdentityFile } else { '' }
        identity_file_state  = $identityMetadata.state
        identity_file_length = $identityMetadata.length
        identity_file_mtime  = $identityMetadata.last_write_utc_ticks
        timeout_seconds      = $TimeoutSeconds
        max_output_bytes     = $MaxOutputBytes
        ssh_path             = $sshPath
        ssh_sha256           = Get-FileSha256Text -LiteralPath $sshPath
        remote_helper_sha256 = Get-FileSha256Text -LiteralPath $remoteHelperPath
    }
    # Omission preserves the legacy schema, serialization and digest exactly.
    if ($normalizedAlias) {
        $record['host_key_alias'] = $normalizedAlias
    }
    if ($PSBoundParameters.ContainsKey('ActionTitle')) { $record['action_title'] = $ActionTitle }
    if ($PSBoundParameters.ContainsKey('ActionDescription')) { $record['action_description'] = $ActionDescription }
    return $record
}

function Get-RecordDigest {
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Record)

    $json = $Record | ConvertTo-Json -Depth 5 -Compress
    $bytes = [Text.Encoding]::UTF8.GetBytes($json)
    try {
        return [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes)).ToLowerInvariant()
    }
    finally {
        [Array]::Clear($bytes, 0, $bytes.Length)
        $json = $null
    }
}

function Test-DigestEqual {
    param(
        [Parameter(Mandatory)][string]$Expected,
        [Parameter(Mandatory)][string]$Actual
    )

    $expectedBytes = [Text.Encoding]::ASCII.GetBytes($Expected.ToLowerInvariant())
    $actualBytes = [Text.Encoding]::ASCII.GetBytes($Actual.ToLowerInvariant())
    try {
        return [Security.Cryptography.CryptographicOperations]::FixedTimeEquals($expectedBytes, $actualBytes)
    }
    finally {
        [Array]::Clear($expectedBytes, 0, $expectedBytes.Length)
        [Array]::Clear($actualBytes, 0, $actualBytes.Length)
    }
}

function New-SolisSudoActionDigest {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$AuthorizationId,
        [Parameter(Mandatory)][string]$HostName,
        [Parameter(Mandatory)][string]$UserName,
        [Parameter()][ValidateRange(1, 65535)][int]$Port = 22,
        [Parameter(Mandatory)][string]$TargetCommand,
        [Parameter()][AllowEmptyCollection()][string[]]$TargetArgument = @(),
        [Parameter(Mandatory)][string]$KnownHostsFile,
        [Parameter()][AllowEmptyString()][string]$IdentityFile = '',
        [Parameter()][ValidateRange(1, 3600)][int]$TimeoutSeconds = 120,
        [Parameter()][ValidateRange(1, 16777216)][int]$MaxOutputBytes = 1048576,
        [Parameter()][AllowNull()][AllowEmptyString()][string]$HostKeyAlias,
        [Parameter()][AllowNull()][AllowEmptyString()][string]$ActionTitle,
        [Parameter()][AllowNull()][AllowEmptyString()][string]$ActionDescription
    )

    $aliasParameters = @{}
    if ($PSBoundParameters.ContainsKey('HostKeyAlias')) {
        $aliasParameters.HostKeyAlias = $HostKeyAlias
    }
    foreach ($name in @('ActionTitle', 'ActionDescription')) {
        if ($PSBoundParameters.ContainsKey($name)) { $aliasParameters[$name] = $PSBoundParameters[$name] }
    }
    $record = Get-ActionRecord `
        -AuthorizationId $AuthorizationId `
        -HostName $HostName `
        -UserName $UserName `
        -Port $Port `
        -TargetCommand $TargetCommand `
        -TargetArgument $TargetArgument `
        -KnownHostsFile $KnownHostsFile `
        -IdentityFile $IdentityFile `
        -TimeoutSeconds $TimeoutSeconds `
        -MaxOutputBytes $MaxOutputBytes @aliasParameters
    Get-RecordDigest -Record $record
}

function Test-GuiRuntimeContract {
    param(
        [Parameter(Mandatory)][bool]$Windows,
        [Parameter(Mandatory)][string]$ApartmentState,
        [Parameter(Mandatory)][bool]$WpfAvailable,
        [Parameter()][bool]$UserInteractive = $true,
        [Parameter()][int]$SessionId = 1
    )

    $status = if (-not $Windows) {
        'GUI_UNAVAILABLE_NON_WINDOWS'
    }
    elseif ($ApartmentState -ne 'STA') {
        'GUI_REQUIRES_STA'
    }
    elseif (-not $WpfAvailable) {
        'GUI_WPF_UNAVAILABLE'
    }
    elseif (-not $UserInteractive -or $SessionId -eq 0) {
        'GUI_SESSION_NOT_INTERACTIVE'
    }
    else {
        'PASS'
    }
    [pscustomobject]@{ Status = $status }
}

function Test-WpfAvailable {
    try {
        Add-Type -AssemblyName PresentationFramework -ErrorAction Stop
        Add-Type -AssemblyName PresentationCore -ErrorAction Stop
        Add-Type -AssemblyName WindowsBase -ErrorAction Stop
        [void][Windows.Controls.PasswordBox]
        return $true
    }
    catch {
        return $false
    }
}

function Resolve-SecureInputPair {
    [CmdletBinding(DefaultParameterSetName = 'Pair')]
    param(
        [Parameter(Mandatory, ParameterSetName = 'Pair')][Security.SecureString]$First,
        [Parameter(Mandatory, ParameterSetName = 'Pair')][Security.SecureString]$Second,
        [Parameter(ParameterSetName = 'Pair')][switch]$ValidateOnly,
        [Parameter(Mandatory, ParameterSetName = 'Cancelled')][switch]$Cancelled
    )

    if ($Cancelled) {
        return [pscustomobject]@{ Status = 'CANCELLED'; Secret = $null }
    }

    $firstPointer = [IntPtr]::Zero
    $secondPointer = [IntPtr]::Zero
    $copy = $null
    try {
        if ($First.Length -eq 0 -or $Second.Length -eq 0) {
            return [pscustomobject]@{ Status = 'EMPTY'; Secret = $null }
        }
        if ($First.Length -ne $Second.Length) {
            return [pscustomobject]@{ Status = 'MISMATCH'; Secret = $null }
        }

        $firstPointer = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($First)
        $secondPointer = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($Second)
        $equal = $true
        for ($index = 0; $index -lt $First.Length; $index++) {
            $firstCharacter = [Runtime.InteropServices.Marshal]::ReadInt16($firstPointer, $index * 2)
            $secondCharacter = [Runtime.InteropServices.Marshal]::ReadInt16($secondPointer, $index * 2)
            if ($firstCharacter -ne $secondCharacter) {
                $equal = $false
            }
        }
        if (-not $equal) {
            return [pscustomobject]@{ Status = 'MISMATCH'; Secret = $null }
        }

        if ($ValidateOnly) {
            return [pscustomobject]@{ Status = 'SUCCESS'; Secret = $null }
        }
        $copy = $First.Copy()
        $copy.MakeReadOnly()
        return [pscustomobject]@{ Status = 'SUCCESS'; Secret = $copy }
    }
    finally {
        if ($firstPointer -ne [IntPtr]::Zero) {
            [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($firstPointer)
        }
        if ($secondPointer -ne [IntPtr]::Zero) {
            [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($secondPointer)
        }
        $First.Dispose()
        $Second.Dispose()
    }
}

function New-MaskedCredentialDialog {
    param(
        [Parameter(Mandatory)][string]$AuthorizationId,
        [Parameter(Mandatory)][string]$ActionDigest,
        [Parameter(Mandatory)][string]$Destination,
        [Parameter(Mandatory)][string]$CommandSummary,
        [Parameter()][AllowEmptyString()][string]$HostKeyAlias = '',
        [Parameter()][AllowEmptyString()][string]$ActionTitle = '仅为下列已授权动作输入本次 sudo 密码',
        [Parameter()][AllowEmptyString()][string]$ActionDescription = ''
    )

    Assert-ActionDisplayText -Value $ActionTitle -MaxLength 128 -FailureCode 'ACTION_TITLE_INVALID'
    Assert-ActionDisplayText -Value $ActionDescription -MaxLength 512 -FailureCode 'ACTION_DESCRIPTION_INVALID' -AllowEmpty
    $window = [Windows.Window]::new()
    $window.Title = 'Solis 一次性 sudo 授权输入'
    $window.Width = 680
    $window.Height = 600
    $window.SizeToContent = [Windows.SizeToContent]::Manual
    $window.ResizeMode = [Windows.ResizeMode]::NoResize
    $window.WindowStartupLocation = [Windows.WindowStartupLocation]::CenterScreen
    $window.Topmost = $true
    $window.ShowInTaskbar = $true

    $panel = [Windows.Controls.StackPanel]::new()
    $panel.Margin = [Windows.Thickness]::new(24)

    $heading = [Windows.Controls.TextBlock]::new()
    $heading.Text = $ActionTitle
    $heading.TextWrapping = [Windows.TextWrapping]::Wrap
    $heading.FontSize = 18
    $heading.FontWeight = [Windows.FontWeights]::SemiBold
    $heading.Margin = [Windows.Thickness]::new(0, 0, 0, 12)
    [void]$panel.Children.Add($heading)

    if ($ActionDescription) {
        $description = [Windows.Controls.TextBlock]::new()
        $description.Text = $ActionDescription
        $description.TextWrapping = [Windows.TextWrapping]::Wrap
        $description.Margin = [Windows.Thickness]::new(0, 0, 0, 8)
        [void]$panel.Children.Add($description)
    }
    $destinationLabel = [Windows.Controls.TextBlock]::new()
    $destinationLabel.Text = "目标：$Destination"
    $destinationLabel.TextWrapping = [Windows.TextWrapping]::Wrap
    $destinationLabel.Margin = [Windows.Thickness]::new(0, 0, 0, 12)
    [void]$panel.Children.Add($destinationLabel)

    $details = [Windows.Controls.TextBlock]::new()
    $details.Text = "Authorization: $AuthorizationId`nAction digest: $ActionDigest`nDestination: $Destination`nCommand: $CommandSummary"
    if ($HostKeyAlias) {
        $details.Text += "`nHostKeyAlias: $HostKeyAlias"
    }
    $details.TextWrapping = [Windows.TextWrapping]::Wrap
    $details.Margin = [Windows.Thickness]::new(0, 0, 0, 16)
    $detailScroll = [Windows.Controls.ScrollViewer]::new()
    $detailScroll.MaxHeight = 180
    $detailScroll.VerticalScrollBarVisibility = 'Auto'
    $detailScroll.Content = $details
    $expander = [Windows.Controls.Expander]::new()
    $expander.Header = '技术详情（动作摘要与执行入口）'
    $expander.IsExpanded = $false
    $expander.Content = $detailScroll
    $expander.Margin = [Windows.Thickness]::new(0, 0, 0, 16)
    [void]$panel.Children.Add($expander)

    $firstLabel = [Windows.Controls.TextBlock]::new()
    $firstLabel.Text = '输入密码'
    [void]$panel.Children.Add($firstLabel)
    $firstBox = [Windows.Controls.PasswordBox]::new()
    $firstBox.Margin = [Windows.Thickness]::new(0, 4, 0, 12)
    [void]$panel.Children.Add($firstBox)

    $secondLabel = [Windows.Controls.TextBlock]::new()
    $secondLabel.Text = '再次输入'
    [void]$panel.Children.Add($secondLabel)
    $secondBox = [Windows.Controls.PasswordBox]::new()
    $secondBox.Margin = [Windows.Thickness]::new(0, 4, 0, 16)
    [void]$panel.Children.Add($secondBox)

    $feedback = [Windows.Controls.TextBlock]::new()
    $feedback.Text = ''
    $feedback.Margin = [Windows.Thickness]::new(0, 0, 0, 12)
    [void]$panel.Children.Add($feedback)

    $notice = [Windows.Controls.TextBlock]::new()
    $notice.Text = '密码不会写入 argv、environment、日志或文件；仍会短暂存在当前用户进程内存，并经 SSH 加密通道传输。'
    $notice.TextWrapping = [Windows.TextWrapping]::Wrap
    $notice.Margin = [Windows.Thickness]::new(0, 0, 0, 16)
    [void]$panel.Children.Add($notice)

    $buttons = [Windows.Controls.StackPanel]::new()
    $buttons.Orientation = [Windows.Controls.Orientation]::Horizontal
    $buttons.HorizontalAlignment = [Windows.HorizontalAlignment]::Right
    $cancelButton = [Windows.Controls.Button]::new()
    $cancelButton.Content = '取消'
    $cancelButton.IsCancel = $true
    $cancelButton.MinWidth = 90
    $cancelButton.Margin = [Windows.Thickness]::new(0, 0, 8, 0)
    $confirmButton = [Windows.Controls.Button]::new()
    $confirmButton.Content = '确认并执行一次'
    $confirmButton.IsEnabled = $false
    $confirmButton.MinWidth = 130
    [void]$buttons.Children.Add($cancelButton)
    [void]$buttons.Children.Add($confirmButton)
    [void]$panel.Children.Add($buttons)

    $state = @{ Status = 'CANCELLED'; Secret = $null; Completed = $false; Modal = $false; ValidationStatus = 'NOT_VALIDATED' }
    $resolvePair = ${function:Resolve-SecureInputPair}
    $updateValidation = {
        if ($state.Completed) { return }
        $pair = & $resolvePair -First $firstBox.SecurePassword -Second $secondBox.SecurePassword -ValidateOnly
        $state.ValidationStatus = $pair.Status
        $confirmButton.IsEnabled = ($pair.Status -eq 'SUCCESS')
        switch ($pair.Status) {
            'SUCCESS' { $feedback.Text = '两次输入一致'; $feedback.Foreground = [Windows.Media.Brushes]::DarkGreen }
            'MISMATCH' { $feedback.Text = '两次输入不一致'; $feedback.Foreground = [Windows.Media.Brushes]::Firebrick }
            default { $feedback.Text = '请填写两次密码'; $feedback.Foreground = [Windows.Media.Brushes]::DimGray }
        }
    }.GetNewClosure()
    $firstBox.Add_PasswordChanged($updateValidation)
    $secondBox.Add_PasswordChanged($updateValidation)
    $submit = {
        if ($state.Completed) { return }
        & $updateValidation
        if ($state.ValidationStatus -ne 'SUCCESS') { return }
        # 前台状态只用于交互；真正接受仍使用原来的安全校验和只读副本。
        $pair = & $resolvePair -First $firstBox.SecurePassword -Second $secondBox.SecurePassword
        if ($pair.Status -ne 'SUCCESS') {
            if ($null -ne $pair.Secret) { $pair.Secret.Dispose() }
            & $updateValidation
            return
        }
        $state.Completed = $true
        $state.Status = $pair.Status
        $state.Secret = $pair.Secret
        if ($state.Modal) { $window.DialogResult = ($pair.Status -eq 'SUCCESS') }
        else { $window.Close() }
    }.GetNewClosure()
    $cancel = {
        if ($state.Completed) { return }
        $state.Completed = $true
        $state.Status = 'CANCELLED'
        if ($state.Modal) { $window.DialogResult = $false }
        else { $window.Close() }
    }.GetNewClosure()
    $confirmButton.Add_Click($submit)
    $cancelButton.Add_Click($cancel)
    # 第一框无 Enter 绑定，也不设置全局默认确认；Tab 使用原生顺序。
    $secondBox.Add_PreviewKeyDown({
        param($sender, $eventArgs)
        if ($eventArgs.Key -eq [Windows.Input.Key]::Return) {
            $eventArgs.Handled = $true
            if (-not $eventArgs.IsRepeat) { & $submit }
        }
    }.GetNewClosure())
    $window.Add_PreviewKeyDown({
        param($sender, $eventArgs)
        if ($eventArgs.Key -eq [Windows.Input.Key]::Escape) {
            $eventArgs.Handled = $true
            & $cancel
        }
    }.GetNewClosure())
    $window.Add_ContentRendered({
        [void]$window.Activate()
        [void]$firstBox.Focus()
    }.GetNewClosure())
    $window.Add_Closed({ $state.Completed = $true }.GetNewClosure())
    $outer = [Windows.Controls.ScrollViewer]::new()
    $outer.VerticalScrollBarVisibility = 'Auto'
    $outer.Content = $panel
    $window.Content = $outer
    [pscustomobject]@{
        Window = $window; FirstBox = $firstBox; SecondBox = $secondBox
        ConfirmButton = $confirmButton; CancelButton = $cancelButton; State = $state
        Heading = $heading; DetailsExpander = $expander; DetailsScroll = $detailScroll
        Feedback = $feedback
    }
}

function Show-MaskedCredentialDialog {
    param(
        [Parameter(Mandatory)][string]$AuthorizationId,
        [Parameter(Mandatory)][string]$ActionDigest,
        [Parameter(Mandatory)][string]$Destination,
        [Parameter(Mandatory)][string]$CommandSummary,
        [Parameter()][AllowEmptyString()][string]$HostKeyAlias = '',
        [Parameter()][AllowEmptyString()][string]$ActionTitle = '仅为下列已授权动作输入本次 sudo 密码',
        [Parameter()][AllowEmptyString()][string]$ActionDescription = ''
    )

    $dialog = New-MaskedCredentialDialog @PSBoundParameters
    $dialog.State.Modal = $true
    try {
        [void]$dialog.Window.ShowDialog()
    }
    catch {
        if ($null -ne $dialog.State.Secret) { $dialog.State.Secret.Dispose() }
        throw
    }
    finally {
        $dialog.FirstBox.Clear()
        $dialog.SecondBox.Clear()
    }
    [pscustomobject]@{ Status = $dialog.State.Status; Secret = $dialog.State.Secret }
}

function ConvertTo-PosixSingleQuoted {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Value)

    if ($Value.IndexOfAny([char[]]@(0, 10, 13)) -ge 0) {
        throw 'REMOTE_ARGUMENT_CONTROL_CHARACTER'
    }
    $singleQuoteEscape = "'" + '"' + "'" + '"' + "'"
    return "'" + $Value.Replace("'", $singleQuoteEscape) + "'"
}

function New-RemoteCommandText {
    param(
        [Parameter(Mandatory)][string]$RemoteHelperPath,
        [Parameter(Mandatory)][string]$TargetCommand,
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$TargetArgument,
        [Parameter()][ValidateRange(1, 16777216)][int]$MaxOutputBytes = 1048576
    )

    $helperBytes = [IO.File]::ReadAllBytes($RemoteHelperPath)
    try {
        $encodedHelper = [Convert]::ToBase64String($helperBytes)
    }
    finally {
        if ($helperBytes.Length -gt 0) {
            [Array]::Clear($helperBytes, 0, $helperBytes.Length)
        }
    }
    $commandText = '/bin/sh -c "$(printf ''%s'' ' + (ConvertTo-PosixSingleQuoted $encodedHelper) + ' | base64 -d)" sh'
    $commandText += ' ' + $MaxOutputBytes.ToString([Globalization.CultureInfo]::InvariantCulture)
    foreach ($item in @($TargetCommand) + @($TargetArgument)) {
        $commandText += ' ' + (ConvertTo-PosixSingleQuoted $item)
    }
    return $commandText
}

function New-SshProcessStartInfo {
    param(
        [Parameter(Mandatory)][string]$SshPath,
        [Parameter(Mandatory)][string]$HostName,
        [Parameter(Mandatory)][string]$UserName,
        [Parameter(Mandatory)][int]$Port,
        [Parameter(Mandatory)][string]$TargetCommand,
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$TargetArgument,
        [Parameter(Mandatory)][string]$KnownHostsFile,
        [Parameter()][AllowEmptyString()][string]$IdentityFile = '',
        [Parameter(Mandatory)][string]$RemoteHelperPath,
        [Parameter()][ValidateRange(1, 16777216)][int]$MaxOutputBytes = 1048576,
        [Parameter()][AllowNull()][AllowEmptyString()][string]$HostKeyAlias
    )

    $normalizedAlias = Resolve-HostKeyAlias -Value $HostKeyAlias -Specified $PSBoundParameters.ContainsKey('HostKeyAlias')
    $startInfo = [Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = $SshPath
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardInput = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.StandardInputEncoding = [Text.UTF8Encoding]::new($false)
    $startInfo.StandardOutputEncoding = [Text.UTF8Encoding]::new($false, $true)
    $startInfo.StandardErrorEncoding = [Text.UTF8Encoding]::new($false, $true)

    $arguments = @(
        '-F', 'NUL',
        '-T',
        '-p', $Port.ToString([Globalization.CultureInfo]::InvariantCulture),
        '-o', 'BatchMode=yes',
        '-o', 'PasswordAuthentication=no',
        '-o', 'KbdInteractiveAuthentication=no',
        '-o', 'NumberOfPasswordPrompts=0',
        '-o', 'StrictHostKeyChecking=yes',
        '-o', 'RequestTTY=no',
        '-o', "UserKnownHostsFile=$KnownHostsFile",
        '-o', 'LogLevel=ERROR'
    )
    if ($normalizedAlias) {
        $arguments += @('-o', "HostKeyAlias=$normalizedAlias")
    }
    if ($IdentityFile) {
        $arguments += @('-i', $IdentityFile, '-o', 'IdentitiesOnly=yes')
    }
    $arguments += "$UserName@$HostName"
    $arguments += New-RemoteCommandText `
        -RemoteHelperPath $RemoteHelperPath `
        -TargetCommand $TargetCommand `
        -TargetArgument $TargetArgument `
        -MaxOutputBytes $MaxOutputBytes
    foreach ($argument in $arguments) {
        [void]$startInfo.ArgumentList.Add($argument)
    }
    return $startInfo
}

function Invoke-ProcessWithSecret {
    param(
        [Parameter(Mandatory)][Diagnostics.ProcessStartInfo]$StartInfo,
        [Parameter(Mandatory)][Security.SecureString]$Secret,
        [Parameter(Mandatory)][ValidateRange(1, 3600)][int]$TimeoutSeconds,
        [Parameter()][ValidateRange(1, 134217728)][int]$MaxStdOutBytes = 65536,
        [Parameter()][ValidateRange(1, 16777216)][int]$MaxStdErrBytes = 65536
    )

    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $StartInfo
    $pointer = [IntPtr]::Zero
    $characterBuffer = $null
    $byteBuffer = $null
    $started = $false
    try {
        $pointer = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($Secret)
        $characterBuffer = [char[]]::new($Secret.Length)
        for ($index = 0; $index -lt $Secret.Length; $index++) {
            $characterValue = [Runtime.InteropServices.Marshal]::ReadInt16($pointer, $index * 2)
            if ($characterValue -in @(0, 10, 13)) {
                throw 'MASKED_INPUT_CONTROL_CHARACTER'
            }
            $characterBuffer[$index] = [char]($characterValue -band 0xFFFF)
        }
        $utf8 = [Text.UTF8Encoding]::new($false, $true)
        $byteBuffer = [byte[]]::new($utf8.GetMaxByteCount($characterBuffer.Length))
        $byteCount = $utf8.GetBytes($characterBuffer, 0, $characterBuffer.Length, $byteBuffer, 0)

        try {
            $started = $process.Start()
        }
        catch {
            throw [InvalidOperationException]::new('SSH_START_FAILED', $_.Exception)
        }
        if (-not $started) {
            throw 'SSH_START_FAILED'
        }

        $inputStream = $process.StandardInput.BaseStream
        $inputStream.Write($byteBuffer, 0, $byteCount)
        $inputStream.WriteByte(10)
        $inputStream.Flush()
        $process.StandardInput.Close()

        Read-ProcessStreamsBounded `
            -Process $process `
            -TimeoutSeconds $TimeoutSeconds `
            -MaxStdOutBytes $MaxStdOutBytes `
            -MaxStdErrBytes $MaxStdErrBytes
    }
    finally {
        if ($pointer -ne [IntPtr]::Zero) {
            [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($pointer)
        }
        if ($null -ne $characterBuffer -and $characterBuffer.Length -gt 0) {
            [Array]::Clear($characterBuffer, 0, $characterBuffer.Length)
        }
        if ($null -ne $byteBuffer -and $byteBuffer.Length -gt 0) {
            [Array]::Clear($byteBuffer, 0, $byteBuffer.Length)
        }
        try {
            $process.StandardInput.Close()
        }
        catch {
        }
        if ($started -and -not $process.HasExited) {
            try {
                $process.Kill($true)
                [void]$process.WaitForExit(5000)
            }
            catch {
            }
        }
        $Secret.Dispose()
        $process.Dispose()
    }
}

function Read-ProcessStreamsBounded {
    param(
        [Parameter(Mandatory)][Diagnostics.Process]$Process,
        [Parameter(Mandatory)][ValidateRange(1, 3600)][int]$TimeoutSeconds,
        [Parameter(Mandatory)][ValidateRange(1, 134217728)][int]$MaxStdOutBytes,
        [Parameter(Mandatory)][ValidateRange(1, 16777216)][int]$MaxStdErrBytes
    )

    $stdoutBuffer = [byte[]]::new(8192)
    $stderrBuffer = [byte[]]::new(8192)
    $stdoutCapture = [IO.MemoryStream]::new([Math]::Min($MaxStdOutBytes, 65536))
    $stderrCapture = [IO.MemoryStream]::new([Math]::Min($MaxStdErrBytes, 65536))
    $stopwatch = [Diagnostics.Stopwatch]::StartNew()
    $stdoutOpen = $true
    $stderrOpen = $true
    $outputLimitExceeded = $false
    try {
        $stdoutTask = $Process.StandardOutput.BaseStream.ReadAsync($stdoutBuffer, 0, $stdoutBuffer.Length)
        $stderrTask = $Process.StandardError.BaseStream.ReadAsync($stderrBuffer, 0, $stderrBuffer.Length)
        while ($stdoutOpen -or $stderrOpen) {
            $remainingMilliseconds = ($TimeoutSeconds * 1000) - [int]$stopwatch.ElapsedMilliseconds
            if ($remainingMilliseconds -le 0) {
                if (-not $Process.HasExited) {
                    $Process.Kill($true)
                    [void]$Process.WaitForExit(5000)
                }
                throw 'SSH_TIMEOUT'
            }

            $activeTasks = [Collections.Generic.List[Threading.Tasks.Task]]::new()
            if ($stdoutOpen) {
                [void]$activeTasks.Add($stdoutTask)
            }
            if ($stderrOpen) {
                [void]$activeTasks.Add($stderrTask)
            }
            $timeoutTask = [Threading.Tasks.Task]::Delay($remainingMilliseconds)
            [void]$activeTasks.Add($timeoutTask)
            $completedTask = [Threading.Tasks.Task]::WhenAny($activeTasks).GetAwaiter().GetResult()
            if ([object]::ReferenceEquals($completedTask, $timeoutTask)) {
                if (-not $Process.HasExited) {
                    $Process.Kill($true)
                    [void]$Process.WaitForExit(5000)
                }
                throw 'SSH_TIMEOUT'
            }

            if ($stdoutOpen -and [object]::ReferenceEquals($completedTask, $stdoutTask)) {
                $count = $stdoutTask.GetAwaiter().GetResult()
                if ($count -eq 0) {
                    $stdoutOpen = $false
                }
                else {
                    $remainingCapacity = $MaxStdOutBytes - [int]$stdoutCapture.Length
                    $writeCount = [Math]::Min($count, [Math]::Max(0, $remainingCapacity))
                    if ($writeCount -gt 0) {
                        $stdoutCapture.Write($stdoutBuffer, 0, $writeCount)
                    }
                    if ($count -gt $remainingCapacity) {
                        $outputLimitExceeded = $true
                    }
                    else {
                        $stdoutTask = $Process.StandardOutput.BaseStream.ReadAsync($stdoutBuffer, 0, $stdoutBuffer.Length)
                    }
                }
            }

            if ($stderrOpen -and [object]::ReferenceEquals($completedTask, $stderrTask)) {
                $count = $stderrTask.GetAwaiter().GetResult()
                if ($count -eq 0) {
                    $stderrOpen = $false
                }
                else {
                    $remainingCapacity = $MaxStdErrBytes - [int]$stderrCapture.Length
                    $writeCount = [Math]::Min($count, [Math]::Max(0, $remainingCapacity))
                    if ($writeCount -gt 0) {
                        $stderrCapture.Write($stderrBuffer, 0, $writeCount)
                    }
                    if ($count -gt $remainingCapacity) {
                        $outputLimitExceeded = $true
                    }
                    else {
                        $stderrTask = $Process.StandardError.BaseStream.ReadAsync($stderrBuffer, 0, $stderrBuffer.Length)
                    }
                }
            }

            if ($outputLimitExceeded) {
                if (-not $Process.HasExited) {
                    $Process.Kill($true)
                    [void]$Process.WaitForExit(5000)
                }
                break
            }
        }

        if (-not $Process.HasExited) {
            $remainingMilliseconds = ($TimeoutSeconds * 1000) - [int]$stopwatch.ElapsedMilliseconds
            if ($remainingMilliseconds -le 0 -or -not $Process.WaitForExit($remainingMilliseconds)) {
                $Process.Kill($true)
                [void]$Process.WaitForExit(5000)
                throw 'SSH_TIMEOUT'
            }
        }
        $decoder = [Text.UTF8Encoding]::new($false, $false)
        [pscustomobject]@{
            ExitCode           = $Process.ExitCode
            StdOut             = $decoder.GetString($stdoutCapture.ToArray())
            StdErr             = $decoder.GetString($stderrCapture.ToArray())
            OutputLimitExceeded = $outputLimitExceeded
        }
    }
    finally {
        $stopwatch.Stop()
        [Array]::Clear($stdoutBuffer, 0, $stdoutBuffer.Length)
        [Array]::Clear($stderrBuffer, 0, $stderrBuffer.Length)
        $stdoutCapture.Dispose()
        $stderrCapture.Dispose()
    }
}

function ConvertFrom-ProtocolPayload {
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Payload,
        [Parameter()][switch]$ReplaceInvalidUtf8
    )

    if ($Payload.Length -eq 0) {
        return ''
    }
    $bytes = [Convert]::FromBase64String($Payload)
    try {
        return [Text.UTF8Encoding]::new($false, -not $ReplaceInvalidUtf8).GetString($bytes)
    }
    finally {
        [Array]::Clear($bytes, 0, $bytes.Length)
    }
}

function New-ProtocolFailure {
    param(
        [Parameter(Mandatory)][int]$SshExitCode,
        [Parameter(Mandatory)][AllowEmptyString()][string]$SshStdOut,
        [Parameter(Mandatory)][AllowEmptyString()][string]$SshStdErr,
        [Parameter(Mandatory)][string]$Layer,
        [Parameter()][AllowEmptyString()][string]$FailureCode = ''
    )

    [pscustomobject]@{
        Result     = 'FAIL'
        ErrorLayer = $Layer
        FailureCode = if ($FailureCode) { $FailureCode } else { $null }
        Ssh        = [pscustomobject]@{ ExitCode = $SshExitCode; StdOut = $SshStdOut; StdErr = $SshStdErr }
        Sudo       = [pscustomobject]@{ Started = $false; ExitCode = $null; StdOut = ''; StdErr = '' }
        Target     = [pscustomobject]@{ Started = $false; ExitCode = $null; StdOut = ''; StdErr = '' }
    }
}

function ConvertFrom-SudoProtocol {
    param(
        [Parameter(Mandatory)][int]$SshExitCode,
        [Parameter(Mandatory)][AllowEmptyString()][string]$SshStdOut,
        [Parameter(Mandatory)][AllowEmptyString()][string]$SshStdErr
    )

    if ($SshExitCode -ne 0) {
        return New-ProtocolFailure `
            -SshExitCode $SshExitCode `
            -SshStdOut $SshStdOut `
            -SshStdErr $SshStdErr `
            -Layer 'SSH' `
            -FailureCode 'SSH_FAILED'
    }

    $encodedPayloads = @{}
    $sudoExit = $null
    $targetStarted = $null
    $targetExitText = $null
    $limitStreams = @{}
    try {
        foreach ($rawLine in @($SshStdOut -split "`n")) {
            $line = $rawLine.TrimEnd("`r")
            if ($line.Length -eq 0) {
                continue
            }
            if ($line -match '^SOLIS_SUDO_V1 (SUDO_STDOUT|SUDO_STDERR|TARGET_STDOUT|TARGET_STDERR)(?: ([A-Za-z0-9+/=]*))?$') {
                $name = $Matches[1]
                if ($encodedPayloads.ContainsKey($name)) {
                    throw 'DUPLICATE_STREAM'
                }
                $encodedPayloads[$name] = $Matches[2]
                continue
            }
            if ($line -match '^SOLIS_SUDO_V1 LIMIT (SUDO_STDOUT|SUDO_STDERR|TARGET_STDOUT|TARGET_STDERR) max=([0-9]+)$') {
                $name = $Matches[1]
                if ($limitStreams.ContainsKey($name)) {
                    throw 'DUPLICATE_LIMIT'
                }
                $limitStreams[$name] = [int]$Matches[2]
                continue
            }
            if ($line -match '^SOLIS_SUDO_V1 RESULT sudo_exit=([0-9]+) target_started=([01]) target_exit=([0-9]+|NA)$') {
                if ($null -ne $sudoExit) {
                    throw 'DUPLICATE_RESULT'
                }
                $sudoExit = [int]$Matches[1]
                $targetStarted = $Matches[2] -eq '1'
                $targetExitText = $Matches[3]
                continue
            }
            throw 'UNRECOGNIZED_RECORD'
        }
        $requiredStreams = @('SUDO_STDOUT', 'SUDO_STDERR', 'TARGET_STDOUT', 'TARGET_STDERR')
        if (@($requiredStreams | Where-Object { -not $encodedPayloads.ContainsKey($_) }).Count -ne 0 -or $null -eq $sudoExit) {
            throw 'INCOMPLETE_PROTOCOL'
        }
        $targetExit = if ($targetExitText -eq 'NA') { $null } else { [int]$targetExitText }
        if ($targetStarted -and $null -eq $targetExit) {
            throw 'TARGET_EXIT_MISSING'
        }
        if ($targetStarted -and $sudoExit -ne $targetExit) {
            throw 'LAYER_EXIT_MISMATCH'
        }
        $payloads = @{}
        foreach ($streamName in $requiredStreams) {
            $payloads[$streamName] = ConvertFrom-ProtocolPayload `
                -Payload $encodedPayloads[$streamName] `
                -ReplaceInvalidUtf8:$limitStreams.ContainsKey($streamName)
        }
    }
    catch {
        return New-ProtocolFailure `
            -SshExitCode $SshExitCode `
            -SshStdOut $SshStdOut `
            -SshStdErr $SshStdErr `
            -Layer 'RemoteProtocol' `
            -FailureCode 'REMOTE_PROTOCOL_FAILED'
    }

    $result = if ($limitStreams.Count -eq 0 -and $targetStarted -and $targetExit -eq 0 -and $sudoExit -eq 0) { 'PASS' } else { 'FAIL' }
    $errorLayer = if ($limitStreams.Count -gt 0) {
        'OutputLimit'
    }
    elseif ($result -eq 'PASS') {
        $null
    }
    elseif (-not $targetStarted) {
        'Sudo'
    }
    else {
        'Target'
    }
    [pscustomobject]@{
        Result     = $result
        ErrorLayer = $errorLayer
        FailureCode = if ($limitStreams.Count -gt 0) { 'OUTPUT_LIMIT_EXCEEDED' } else { $null }
        Ssh        = [pscustomobject]@{ ExitCode = $SshExitCode; StdOut = $SshStdOut; StdErr = $SshStdErr }
        Sudo       = [pscustomobject]@{ Started = $true; ExitCode = $sudoExit; StdOut = $payloads.SUDO_STDOUT; StdErr = $payloads.SUDO_STDERR }
        Target     = [pscustomobject]@{ Started = $targetStarted; ExitCode = $targetExit; StdOut = $payloads.TARGET_STDOUT; StdErr = $payloads.TARGET_STDERR }
    }
}

function Assert-LeafNotReparsePoint {
    param(
        [Parameter(Mandatory)][string]$LiteralPath,
        [Parameter(Mandatory)][string]$FailureCode
    )

    $item = Get-Item -LiteralPath $LiteralPath -Force -ErrorAction SilentlyContinue
    if ($null -eq $item -or $item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
        throw $FailureCode
    }
}

function Invoke-SolisMaskedSudoOverSsh {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$AuthorizationId,
        [Parameter(Mandatory)][string]$ExpectedActionDigest,
        [Parameter(Mandatory)][string]$HostName,
        [Parameter(Mandatory)][string]$UserName,
        [Parameter()][ValidateRange(1, 65535)][int]$Port = 22,
        [Parameter(Mandatory)][string]$TargetCommand,
        [Parameter()][AllowEmptyCollection()][string[]]$TargetArgument = @(),
        [Parameter(Mandatory)][string]$KnownHostsFile,
        [Parameter()][AllowEmptyString()][string]$IdentityFile = '',
        [Parameter()][ValidateRange(1, 3600)][int]$TimeoutSeconds = 120,
        [Parameter()][ValidateRange(1, 16777216)][int]$MaxOutputBytes = 1048576,
        [Parameter()][AllowNull()][AllowEmptyString()][string]$HostKeyAlias,
        [Parameter()][AllowNull()][AllowEmptyString()][string]$ActionTitle,
        [Parameter()][AllowNull()][AllowEmptyString()][string]$ActionDescription
    )

    if ($ExpectedActionDigest -notmatch '^[A-Fa-f0-9]{64}$') {
        throw 'EXPECTED_ACTION_DIGEST_INVALID'
    }
    $digestParameters = @{
        AuthorizationId = $AuthorizationId
        HostName = $HostName
        UserName = $UserName
        Port = $Port
        TargetCommand = $TargetCommand
        TargetArgument = $TargetArgument
        KnownHostsFile = $KnownHostsFile
        IdentityFile = $IdentityFile
        TimeoutSeconds = $TimeoutSeconds
        MaxOutputBytes = $MaxOutputBytes
    }
    $aliasParameters = @{}
    if ($PSBoundParameters.ContainsKey('HostKeyAlias')) {
        $aliasParameters.HostKeyAlias = $HostKeyAlias
        $digestParameters.HostKeyAlias = $HostKeyAlias
    }
    $presentationParameters = @{}
    foreach ($name in @('ActionTitle', 'ActionDescription')) {
        if ($PSBoundParameters.ContainsKey($name)) {
            $presentationParameters[$name] = $PSBoundParameters[$name]
            $digestParameters[$name] = $PSBoundParameters[$name]
        }
    }
    $actualDigest = New-SolisSudoActionDigest @digestParameters
    if (-not (Test-DigestEqual -Expected $ExpectedActionDigest -Actual $actualDigest)) {
        throw 'ACTION_IDENTITY_DRIFT'
    }

    $sshPath = 'C:\Windows\System32\OpenSSH\ssh.exe'
    $remoteHelperPath = Get-PortableHelperPath
    Assert-LeafNotReparsePoint -LiteralPath $sshPath -FailureCode 'SSH_EXECUTABLE_UNAVAILABLE'
    Assert-LeafNotReparsePoint -LiteralPath $remoteHelperPath -FailureCode 'REMOTE_HELPER_UNAVAILABLE'
    Assert-LeafNotReparsePoint -LiteralPath $KnownHostsFile -FailureCode 'KNOWN_HOSTS_UNAVAILABLE'
    if ($IdentityFile) {
        Assert-LeafNotReparsePoint -LiteralPath $IdentityFile -FailureCode 'IDENTITY_FILE_UNAVAILABLE'
    }

    $runtime = Test-GuiRuntimeContract `
        -Windows $IsWindows `
        -ApartmentState ([Threading.Thread]::CurrentThread.GetApartmentState().ToString()) `
        -WpfAvailable (Test-WpfAvailable) `
        -UserInteractive ([Environment]::UserInteractive) `
        -SessionId ([Diagnostics.Process]::GetCurrentProcess().SessionId)
    if ($runtime.Status -ne 'PASS') {
        throw $runtime.Status
    }

    $startInfo = New-SshProcessStartInfo `
        -SshPath $sshPath `
        -HostName $HostName `
        -UserName $UserName `
        -Port $Port `
        -TargetCommand $TargetCommand `
        -TargetArgument $TargetArgument `
        -KnownHostsFile $KnownHostsFile `
        -IdentityFile $IdentityFile `
        -RemoteHelperPath $remoteHelperPath `
        -MaxOutputBytes $MaxOutputBytes @aliasParameters
    $commandSummary = (@($TargetCommand) + @($TargetArgument)) -join ' '
    $dialog = Show-MaskedCredentialDialog `
        -AuthorizationId $AuthorizationId `
        -ActionDigest $actualDigest `
        -Destination "$UserName@$HostName`:$Port" `
        -CommandSummary $commandSummary @aliasParameters @presentationParameters
    if ($dialog.Status -ne 'SUCCESS') {
        throw "MASKED_INPUT_$($dialog.Status)"
    }

    try {
        $postInputDigest = New-SolisSudoActionDigest @digestParameters
        if (-not (Test-DigestEqual -Expected $actualDigest -Actual $postInputDigest)) {
            throw 'ACTION_IDENTITY_DRIFT_AFTER_INPUT'
        }
        $encodedStreamLimit = 4L * [long][Math]::Ceiling($MaxOutputBytes / 3.0)
        # MaxOutputBytes is range-bound; PowerShell's int conversion rejects overflow.
        $transportStdOutLimit = [int](4L * $encodedStreamLimit + 8192L)
        $transport = Invoke-ProcessWithSecret `
            -StartInfo $startInfo `
            -Secret $dialog.Secret `
            -TimeoutSeconds $TimeoutSeconds `
            -MaxStdOutBytes $transportStdOutLimit `
            -MaxStdErrBytes $MaxOutputBytes
    }
    finally {
        $dialog.Secret.Dispose()
    }
    $parsed = if ($transport.OutputLimitExceeded) {
        New-ProtocolFailure `
            -SshExitCode $transport.ExitCode `
            -SshStdOut $transport.StdOut `
            -SshStdErr $transport.StdErr `
            -Layer 'OutputLimit' `
            -FailureCode 'OUTPUT_LIMIT_EXCEEDED'
    }
    else {
        ConvertFrom-SudoProtocol -SshExitCode $transport.ExitCode -SshStdOut $transport.StdOut -SshStdErr $transport.StdErr
    }
    [pscustomobject]@{
        SchemaVersion   = 1
        AuthorizationId = $AuthorizationId
        ActionDigest    = $actualDigest
        Result          = $parsed.Result
        ErrorLayer      = $parsed.ErrorLayer
        FailureCode     = $parsed.FailureCode
        Ssh             = $parsed.Ssh
        Sudo            = $parsed.Sudo
        Target          = $parsed.Target
    }
}

Export-ModuleMember -Function Invoke-SolisMaskedSudoOverSsh, New-SolisSudoActionDigest
