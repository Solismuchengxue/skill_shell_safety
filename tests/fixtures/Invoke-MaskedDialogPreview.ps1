#requires -Version 7.0
[CmdletBinding()]
param(
    [ValidateSet('Manual', 'Layout', 'FirstEnter', 'Tab', 'SecondEnter', 'Click', 'Mismatch', 'Empty', 'Escape', 'DoubleConfirm', 'CorrectThenEnter', 'InvalidateAfterMatch', 'CloseCancel')]
    [string]$Scenario = 'Manual',
    [string]$ScreenshotPath = ''
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)
if ([Threading.Thread]::CurrentThread.GetApartmentState() -ne 'STA') { throw 'PREVIEW_REQUIRES_STA' }
Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase
$modulePath = Join-Path $PSScriptRoot '../../skills/powershell-bash-safety/scripts/Invoke-MaskedSudoOverSsh.psm1'
$module = Import-Module $modulePath -Force -PassThru
# 本入口仅构造 UI，没有公开执行入口或任何 process/SSH/sudo 调用。
$dialog = & $module {
    New-MaskedCredentialDialog -AuthorizationId 'SYNTHETIC-PREVIEW-ONLY' -ActionDigest ('0' * 64) `
        -Destination 'operator@synthetic.invalid:22' -CommandSummary '/usr/bin/id -u（仅展示）' `
        -HostKeyAlias 'synthetic-only' -ActionTitle "预览：NVENC 'quoted' <check>" `
        -ActionDescription '仅输入虚构口令。本预览绝不调用 SSH；第一框 Tab，第二框 Enter 确认，Esc 取消。'
}
$dialog.Window.Title = '仅假口令预览 — 不连接 SSH'
$dialog.State.Modal = $true
$result = @{ Scenario = $Scenario; Check = $false; Error = $null }

function New-PreviewKey {
    param($Control, [Windows.Input.Key]$Key)
    $source = [Windows.PresentationSource]::FromVisual($Control)
    $eventArgs = [Windows.Input.KeyEventArgs]::new([Windows.Input.Keyboard]::PrimaryDevice, $source, 0, $Key)
    $eventArgs.RoutedEvent = [Windows.Input.Keyboard]::PreviewKeyDownEvent
    return $eventArgs
}
$newKey = ${function:New-PreviewKey}
$timer = [Windows.Threading.DispatcherTimer]::new()
$timer.Interval = [TimeSpan]::FromMilliseconds(300)
$timer.Add_Tick({
    $timer.Stop()
    try {
        switch ($Scenario) {
            'Layout' {
                $result.Check = ($dialog.Window.Width -eq 680 -and $dialog.Window.Height -eq 600 -and
                    $dialog.Window.SizeToContent -eq [Windows.SizeToContent]::Manual -and
                    -not $dialog.DetailsExpander.IsExpanded -and $dialog.DetailsScroll.MaxHeight -eq 180 -and
                    $dialog.Window.Content -is [Windows.Controls.ScrollViewer] -and
                    $dialog.Heading.Text -ceq "预览：NVENC 'quoted' <check>" -and -not $dialog.ConfirmButton.IsDefault -and
                    -not $dialog.ConfirmButton.IsEnabled -and $dialog.Feedback.Text -ceq '')
                if ($ScreenshotPath) {
                    if (-not [IO.Path]::IsPathFullyQualified($ScreenshotPath)) { throw 'SCREENSHOT_PATH_NOT_ABSOLUTE' }
                    $dialog.FirstBox.Clear(); $dialog.SecondBox.Clear()
                    $dialog.Window.UpdateLayout()
                    $bitmap = [Windows.Media.Imaging.RenderTargetBitmap]::new([int]$dialog.Window.ActualWidth, [int]$dialog.Window.ActualHeight, 96, 96, [Windows.Media.PixelFormats]::Pbgra32)
                    $bitmap.Render($dialog.Window)
                    $encoder = [Windows.Media.Imaging.PngBitmapEncoder]::new()
                    $encoder.Frames.Add([Windows.Media.Imaging.BitmapFrame]::Create($bitmap))
                    $stream = [IO.File]::Create($ScreenshotPath)
                    try { $encoder.Save($stream) } finally { $stream.Dispose() }
                }
                $dialog.Window.Close()
            }
            'FirstEnter' {
                $dialog.FirstBox.Password = 'SYNTHETIC-ONLY'
                $dialog.SecondBox.Password = 'SYNTHETIC-ONLY'
                [void]$dialog.FirstBox.Focus()
                $dialog.FirstBox.RaiseEvent((& $newKey $dialog.FirstBox Return))
                $result.Check = (-not $dialog.State.Completed -and $dialog.Window.IsVisible -and $dialog.FirstBox.IsKeyboardFocused)
                $dialog.Window.Close()
            }
            'Tab' {
                [void]$dialog.FirstBox.Focus()
                [void]$dialog.FirstBox.MoveFocus([Windows.Input.TraversalRequest]::new([Windows.Input.FocusNavigationDirection]::Next))
                $result.Check = $dialog.SecondBox.IsKeyboardFocused
                $dialog.Window.Close()
            }
            'Escape' {
                $dialog.SecondBox.RaiseEvent((& $newKey $dialog.SecondBox Escape))
                $result.Check = ($dialog.State.Completed -and $dialog.State.Status -eq 'CANCELLED')
            }
            'CloseCancel' {
                $dialog.FirstBox.Password = 'SYNTHETIC-ONLY'
                $dialog.SecondBox.Password = 'SYNTHETIC-ONLY'
                $dialog.Window.Close()
                $result.Check = ($dialog.State.Status -eq 'CANCELLED' -and $null -eq $dialog.State.Secret)
            }
            'CorrectThenEnter' {
                $dialog.FirstBox.Password = 'SYNTHETIC-ONLY'
                $dialog.SecondBox.Password = 'SYNTHETIC-OTHER'
                $dialog.SecondBox.RaiseEvent((& $newKey $dialog.SecondBox Return))
                $blocked = (-not $dialog.State.Completed -and $dialog.Window.IsVisible -and -not $dialog.ConfirmButton.IsEnabled -and $null -eq $dialog.State.Secret)
                $dialog.SecondBox.Password = 'SYNTHETIC-ONLY'
                $enabled = ($dialog.ConfirmButton.IsEnabled -and $dialog.Feedback.Text -ceq '两次输入一致')
                $dialog.SecondBox.RaiseEvent((& $newKey $dialog.SecondBox Return))
                $result.Check = ($blocked -and $enabled -and $dialog.State.Completed -and $dialog.State.Status -eq 'SUCCESS' -and $dialog.State.Secret.IsReadOnly())
            }
            'InvalidateAfterMatch' {
                $dialog.FirstBox.Password = 'SYNTHETIC-ONLY'
                $dialog.SecondBox.Password = 'SYNTHETIC-ONLY'
                $enabled = $dialog.ConfirmButton.IsEnabled
                $dialog.FirstBox.Password = 'SYNTHETIC-OTHER'
                $dialog.SecondBox.RaiseEvent((& $newKey $dialog.SecondBox Return))
                $dialog.ConfirmButton.RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Button]::ClickEvent))
                $result.Check = ($enabled -and -not $dialog.ConfirmButton.IsEnabled -and -not $dialog.State.Completed -and
                    $dialog.Window.IsVisible -and $null -eq $dialog.State.Secret -and $dialog.Feedback.Text -ceq '两次输入不一致')
                $dialog.SecondBox.RaiseEvent((& $newKey $dialog.SecondBox Escape))
                $result.Check = ($result.Check -and $dialog.State.Status -eq 'CANCELLED' -and $null -eq $dialog.State.Secret)
            }
            default {
                if ($Scenario -ne 'Empty') {
                    $dialog.FirstBox.Password = 'SYNTHETIC-ONLY'
                    $dialog.SecondBox.Password = if ($Scenario -eq 'Mismatch') { 'SYNTHETIC-OTHER' } else { 'SYNTHETIC-ONLY' }
                }
                if ($Scenario -in @('Click', 'DoubleConfirm')) {
                    $dialog.ConfirmButton.RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Button]::ClickEvent))
                }
                else { $dialog.SecondBox.RaiseEvent((& $newKey $dialog.SecondBox Return)) }
                if ($Scenario -in @('Empty', 'Mismatch')) {
                    $blockedEnter = (-not $dialog.State.Completed -and $dialog.Window.IsVisible -and $null -eq $dialog.State.Secret)
                    $dialog.ConfirmButton.RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Button]::ClickEvent))
                    $expectedText = if ($Scenario -eq 'Empty') { '请填写两次密码' } else { '两次输入不一致' }
                    $result.Check = ($blockedEnter -and -not $dialog.State.Completed -and $dialog.Window.IsVisible -and
                        -not $dialog.ConfirmButton.IsEnabled -and $dialog.Feedback.Text -ceq $expectedText -and $null -eq $dialog.State.Secret)
                    $dialog.Window.Close()
                }
                else { $result.Check = ($dialog.State.Completed -and $dialog.State.Status -eq 'SUCCESS' -and $dialog.State.Secret.IsReadOnly()) }
                if ($Scenario -eq 'DoubleConfirm') {
                    $accepted = $dialog.State.Secret
                    $dialog.SecondBox.Password = 'SYNTHETIC-OTHER'
                    $dialog.ConfirmButton.RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Button]::ClickEvent))
                    $result.Check = $result.Check -and $dialog.State.Status -eq 'SUCCESS' -and [object]::ReferenceEquals($accepted, $dialog.State.Secret)
                }
            }
        }
    }
    catch { $result.Error = $_.Exception.Message; $dialog.Window.Close() }
}.GetNewClosure())
try {
    if ($Scenario -ne 'Manual') { $timer.Start() }
    [void]$dialog.Window.ShowDialog()
    if ($Scenario -eq 'Manual') { $result.Check = $true }
    [pscustomobject]@{ Scenario = $Scenario; Status = $dialog.State.Status; Check = $result.Check; Error = $result.Error } | ConvertTo-Json -Compress
    if (-not $result.Check -or $null -ne $result.Error) { exit 1 }
}
finally {
    $timer.Stop()
    $dialog.FirstBox.Clear(); $dialog.SecondBox.Clear()
    if ($null -ne $dialog.State.Secret) { $dialog.State.Secret.Dispose() }
    Remove-Module $module.Name -Force
}
