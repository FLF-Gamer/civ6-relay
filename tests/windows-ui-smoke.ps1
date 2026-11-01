[CmdletBinding()]
param(
    [string]$OutputDirectory = (Join-Path $PSScriptRoot '../.build/windows-ui-smoke')
)
# Run in Windows PowerShell 5.1 with -STA. All network and machine-state actions
# below are fixtures. PNG files render the production WinForms UI with test data.
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if ($env:OS -ne 'Windows_NT' -or $PSVersionTable.PSVersion.Major -ne 5 -or $PSVersionTable.PSVersion.Minor -ne 1) {
    throw 'Run this UI smoke test in Windows PowerShell 5.1.'
}
if ([Threading.Thread]::CurrentThread.ApartmentState -ne [Threading.ApartmentState]::STA) {
    throw 'Run powershell.exe with -STA for the UI smoke test.'
}
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[Windows.Forms.Application]::SetUnhandledExceptionMode([Windows.Forms.UnhandledExceptionMode]::ThrowException)
$repoRoot = Split-Path $PSScriptRoot -Parent
. (Join-Path $repoRoot 'client/windows/Civ6Relay.ps1') -LibraryOnly
$OutputDirectory = [IO.Path]::GetFullPath($OutputDirectory)
$null = New-Item -ItemType Directory -Path $OutputDirectory -Force
$script:UiSmoke = @{
    Step = 0
    Form = $null
    Connected = $false
    SaveCalls = 0
    ConnectCalls = 0
    DisconnectCalls = 0
    StartCalls = 0
    StopCalls = 0
    Preferences = $null
    Errors = (New-Object 'Collections.Generic.List[string]')
    Screenshots = (New-Object 'Collections.Generic.List[object]')
    Clock = [Diagnostics.Stopwatch]::StartNew()
}

# No profile, stored preferences, drivers, ICMP worker, CLI, or server is used.
function Get-ClientPreferences {
    return [pscustomobject]@{display_name='';endpoint='';port=9527}
}
function Save-ClientPreferences {
    param([string]$DisplayName,[string]$Endpoint,[string]$Port)
    $value = New-ClientPreferences $DisplayName $Endpoint $Port
    $script:UiSmoke.SaveCalls++
    $script:UiSmoke.Preferences = $value
    return $value
}
function Connect-Relay {
    $script:UiSmoke.ConnectCalls++
    $script:UiSmoke.Connected = $true
    return '界面测试：已连接，以下玩家和延迟均为模拟数据。'
}
function Disconnect-Relay {
    $script:UiSmoke.DisconnectCalls++
    $script:UiSmoke.Connected = $false
    return '界面测试：已断开。'
}
function Test-Relay { return '界面测试：模拟诊断结果。' }
function Install-Component { return '界面测试：模拟组件检查结果。' }
function Start-LiveMonitor {
    $script:UiSmoke.StartCalls++
    if ($script:UiSmoke.StartCalls -eq 1) { Add-LiveLog '界面测试：日志和延迟使用模拟数据。' }
}
function Stop-LiveMonitor { $script:UiSmoke.StopCalls++ }
function Get-LiveView {
    if (-not $script:UiSmoke.Connected) { return [pscustomobject]@{Text='未连接';Peers=@()} }
    return [pscustomobject]@{
        Text='界面测试 · 虚拟 IP：10.77.77.2 · 直连 1 · 中继 1'
        Peers=@(
            [pscustomobject]@{Player='测试玩家甲';VirtualIP='10.77.77.3';Channel='P2P 直连';RTT='8 ms';LinkRTT='7 ms';SampleTime='12:30:00'},
            [pscustomobject]@{Player='测试玩家乙';VirtualIP='10.77.77.4';Channel='服务器中继';RTT='27 ms';LinkRTT='5 ms';SampleTime='12:30:00'}
        )
    }
}
function Invoke-MeshCli { throw 'UI smoke blocked a real mesh CLI call.' }
function Initialize-RelayNative { throw 'UI smoke blocked real native component initialization.' }

function Assert-UiSmoke {
    param([bool]$Condition,[string]$Message)
    if (-not $Condition) { throw $Message }
}
function Get-UiSmokeControls {
    param([Windows.Forms.Control]$Root)
    $pending = New-Object 'Collections.Generic.Stack[Windows.Forms.Control]'
    $pending.Push($Root)
    while ($pending.Count -gt 0) {
        $control = $pending.Pop()
        if ($control -ne $Root) { $control }
        # DataGridView manages its own headers and scrolling child windows.
        if ($control -is [Windows.Forms.DataGridView]) { continue }
        foreach ($child in $control.Controls) { $pending.Push($child) }
    }
}
function Get-UiSmokeButton {
    param([Windows.Forms.Form]$Form,[string]$Text)
    $found = @(Get-UiSmokeControls $Form | Where-Object { $_ -is [Windows.Forms.Button] -and $_.Text -eq $Text })
    Assert-UiSmoke ($found.Count -eq 1) ('Expected one button: '+$Text)
    return $found[0]
}
function Get-UiSmokeTabs {
    param([Windows.Forms.Form]$Form)
    $found = @(Get-UiSmokeControls $Form | Where-Object { $_ -is [Windows.Forms.TabControl] })
    Assert-UiSmoke ($found.Count -eq 1) 'Expected one tab control.'
    return $found[0]
}
function Get-UiSmokePage {
    param([Windows.Forms.TabControl]$Tabs,[string]$Text)
    $found = @($Tabs.TabPages | Where-Object { $_.Text -eq $Text })
    Assert-UiSmoke ($found.Count -eq 1) ('Expected one page: '+$Text)
    return $found[0]
}
function Get-UiSmokeRect {
    param([Windows.Forms.Control]$Control,[Windows.Forms.Form]$Form)
    $point = $Form.PointToClient($Control.PointToScreen([Drawing.Point]::Empty))
    return New-Object Drawing.Rectangle($point,$Control.Size)
}
function Assert-UiSmokeLayout {
    param([Windows.Forms.Form]$Form)
    $controls = @(Get-UiSmokeControls $Form)
    foreach ($control in $controls) {
        if (-not $control.Visible -or $control.Width -le 0 -or $control.Height -le 0) { continue }
        $area = $control.Parent.DisplayRectangle
        $area.Inflate(2,2) # Allow one-pixel DPI/layout rounding at adjoining edges.
        Assert-UiSmoke ($area.Contains($control.Bounds)) ('Control exceeds parent display area: '+$control.GetType().Name+' '+$control.Text)
    }
    $inputs = @($controls | Where-Object { $_ -is [Windows.Forms.TextBox] -and -not $_.ReadOnly -and -not $_.Multiline } | Sort-Object TabIndex)
    Assert-UiSmoke ($inputs.Count -eq 3) 'Expected nickname, server and port inputs.'
    for ($index=0;$index -lt $inputs.Count;$index++) {
        Assert-UiSmoke ($inputs[$index].Width -ge 80 -and $inputs[$index].Height -ge 20) 'An editable input is too small.'
        $bounds = Get-UiSmokeRect $inputs[$index] $Form
        for ($other=$index+1;$other -lt $inputs.Count;$other++) {
            Assert-UiSmoke (-not $bounds.IntersectsWith((Get-UiSmokeRect $inputs[$other] $Form))) 'Editable inputs overlap.'
        }
    }
    $port = $inputs[2]
    Assert-UiSmoke ($port.Visible -and $port.Enabled -and $port.CanSelect) 'Port input is not accessible.'
    $portBounds = Get-UiSmokeRect $port $Form
    foreach ($control in $controls) {
        if (-not $control.Visible -or $control -eq $port) { continue }
        if ($control -is [Windows.Forms.Label] -or $control -is [Windows.Forms.Button] -or
            ($control -is [Windows.Forms.TextBox] -and -not $control.ReadOnly -and -not $control.Multiline)) {
            Assert-UiSmoke (-not $portBounds.IntersectsWith((Get-UiSmokeRect $control $Form))) ('Port input is covered by: '+$control.Text)
        }
    }
    foreach ($caption in @('连接','断开','网络诊断','检查组件','保存设置')) {
        $button = Get-UiSmokeButton $Form $caption
        Assert-UiSmoke ($button.Visible -and $button.Enabled -and $button.CanSelect) ('Action is inaccessible: '+$caption)
        Assert-UiSmoke ($button.Width -ge 64 -and $button.Height -ge 28) ('Action is too small: '+$caption)
    }
    $tabs = Get-UiSmokeTabs $Form
    if ($tabs.SelectedTab.Text -eq '运行日志') {
        foreach ($caption in @('复制日志','导出日志','清空显示')) {
            $button = Get-UiSmokeButton $Form $caption
            Assert-UiSmoke ($button.Visible -and $button.Enabled -and $button.CanSelect) ('Log action is inaccessible: '+$caption)
        }
    }
    for ($index=0;$index -lt $tabs.TabCount;$index++) {
        Assert-UiSmoke ($tabs.ClientRectangle.Contains($tabs.GetTabRect($index))) 'A tab header is clipped.'
    }
}
function Save-UiSmokeScreenshot {
    param([Windows.Forms.Form]$Form,[string]$Name)
    $Form.Refresh()
    $bitmap = New-Object Drawing.Bitmap($Form.Width,$Form.Height)
    try {
        $Form.DrawToBitmap($bitmap,(New-Object Drawing.Rectangle(0,0,$Form.Width,$Form.Height)))
        $path = Join-Path $OutputDirectory ($Name+'.png')
        $bitmap.Save($path,[Drawing.Imaging.ImageFormat]::Png)
        $script:UiSmoke.Screenshots.Add([pscustomobject]@{File=($Name+'.png');Width=$bitmap.Width;Height=$bitmap.Height;Fixture=$true})
    } finally { $bitmap.Dispose() }
}
function Stop-UiSmokeFailure {
    param([string]$Message)
    $safe = [regex]::Replace($Message,'(?<![A-Za-z0-9+/])[A-Za-z0-9+/]{43}=(?![A-Za-z0-9+/=])','[hidden]')
    $script:UiSmoke.Errors.Add($safe)
    $script:UiSmokeTimer.Stop()
    $form = $script:UiSmoke.Form
    if ($null -ne $form -and -not $form.IsDisposed) {
        $script:Busy = $false
        foreach ($control in @(Get-UiSmokeControls $form)) {
            if ($control -is [Windows.Forms.CheckBox] -and $control.Text -eq '关闭窗口时自动断开') { $control.Checked=$false }
        }
        $form.Close()
    } else { [Windows.Forms.Application]::ExitThread() }
}

$script:UiSmokeTimer = New-Object Windows.Forms.Timer
$script:UiSmokeTimer.Interval = 400
$script:UiSmokeTimer.Add_Tick({
    # A click handler calls DoEvents; prevent this observer from re-entering.
    $script:UiSmokeTimer.Stop()
    try {
        if ($script:UiSmoke.Clock.Elapsed.TotalSeconds -gt 30) { throw 'Timed out waiting for production UI.' }
        $form = $script:UiSmoke.Form
        if ($null -eq $form) {
            $forms = @([Windows.Forms.Application]::OpenForms | Where-Object { $_.Text -like '文明6联机助手*' })
            if ($forms.Count -eq 0) { return }
            Assert-UiSmoke ($forms.Count -eq 1) 'Expected one production window.'
            $form=$forms[0];$script:UiSmoke.Form=$form
        }
        $tabs = Get-UiSmokeTabs $form
        switch ($script:UiSmoke.Step) {
            0 {
                Assert-UiSmokeLayout $form
                $inputs = @(Get-UiSmokeControls $form | Where-Object { $_ -is [Windows.Forms.TextBox] -and -not $_.ReadOnly -and -not $_.Multiline } | Sort-Object TabIndex)
                Assert-UiSmoke ($inputs[1].Text -eq '') 'First-launch server IP must be empty.'
                Assert-UiSmoke ($inputs[2].Text -eq '9527') 'Expected default port 9527.'
                Save-UiSmokeScreenshot $form 'network-initial'
                # TEST-NET address is only entered by this fixture; never contacted.
                $inputs[0].Text='界面测试';$inputs[1].Text='203.0.113.10';$inputs[2].Text='9527'
                (Get-UiSmokeButton $form '连接').PerformClick()
                Assert-UiSmoke ($script:UiSmoke.ConnectCalls -eq 1 -and $script:UiSmoke.SaveCalls -eq 1) 'Connect did not use fixture actions.'
            }
            1 {
                Assert-UiSmokeLayout $form
                $grids = @(Get-UiSmokeControls $form | Where-Object { $_ -is [Windows.Forms.DataGridView] })
                Assert-UiSmoke ($grids.Count -eq 1 -and $grids[0].Rows.Count -eq 2) 'Expected two fixture players in production grid.'
                Assert-UiSmoke ($grids[0].Height -ge 70) 'Player grid is clipped.'
                Save-UiSmokeScreenshot $form 'network-connected-fixture'
                $tabs.SelectedTab = Get-UiSmokePage $tabs '运行日志'
            }
            2 {
                Assert-UiSmokeLayout $form
                foreach ($caption in @('复制日志','导出日志','清空显示')) {
                    $button=Get-UiSmokeButton $form $caption
                    Assert-UiSmoke ($button.Visible -and $button.Enabled -and $button.CanSelect) ('Log action is inaccessible: '+$caption)
                }
                $logs=@(Get-UiSmokeControls $form | Where-Object { $_ -is [Windows.Forms.RichTextBox] })
                Assert-UiSmoke ($logs.Count -eq 1 -and $logs[0].ReadOnly -and $logs[0].Text -match '界面测试') 'Production log did not display fixture events.'
                Save-UiSmokeScreenshot $form 'logs-fixture'
                (Get-UiSmokeButton $form '清空显示').PerformClick()
                Assert-UiSmoke ($logs[0].TextLength -eq 0) 'Clear display did not clear the visible log.'
                $form.Size=$form.MinimumSize
            }
            3 {
                Assert-UiSmokeLayout $form
                Save-UiSmokeScreenshot $form 'logs-minimum-size'
                $tabs.SelectedTab = Get-UiSmokePage $tabs '网络状态'
            }
            4 {
                Assert-UiSmokeLayout $form
                Save-UiSmokeScreenshot $form 'network-minimum-size'
                $script:UiSmokeTimer.Stop()
                $script:UiSmoke.Step++
                $form.Close()
                return
            }
        }
        $script:UiSmoke.Step++
    } catch { Stop-UiSmokeFailure $_.Exception.Message }
    finally {
        if ($script:UiSmoke.Step -lt 5 -and $script:UiSmoke.Errors.Count -eq 0) { $script:UiSmokeTimer.Start() }
    }
})
# Start only after the production form enables its DPI mode and starts its loop.
$script:UiSmokeIdleHandler = [EventHandler]{
    [Windows.Forms.Application]::remove_Idle($script:UiSmokeIdleHandler)
    $script:UiSmokeTimer.Start()
}
[Windows.Forms.Application]::add_Idle($script:UiSmokeIdleHandler)
try {
    Show-RelayWindow
} catch {
    $script:UiSmoke.Errors.Add($_.Exception.Message)
} finally {
    [Windows.Forms.Application]::remove_Idle($script:UiSmokeIdleHandler)
    $script:UiSmokeTimer.Stop();$script:UiSmokeTimer.Dispose()
    $script:UiSmoke.Clock.Stop()
}
if ($script:UiSmoke.Errors.Count -eq 0) {
    try {
        Assert-UiSmoke ($script:UiSmoke.Step -eq 5) 'Production window closed before all UI checks completed.'
        Assert-UiSmoke ($script:UiSmoke.DisconnectCalls -eq 1) 'Closing the production window did not disconnect exactly once.'
        Assert-UiSmoke ($script:UiSmoke.StopCalls -eq 1) 'Closing the production window did not stop its live monitor.'
        Assert-UiSmoke ($script:UiSmoke.Screenshots.Count -eq 5) 'Expected five actual UI renderings.'
    } catch { $script:UiSmoke.Errors.Add($_.Exception.Message) }
}
$report = [pscustomobject]@{
    ProductionUi='client/windows/Civ6Relay.ps1::Show-RelayWindow'
    PowerShell=$PSVersionTable.PSVersion.ToString()
    Fixture=$true
    Notice='Synthetic player names, addresses and latency. No game, network, profile, driver or server was used.'
    Passed=($script:UiSmoke.Errors.Count -eq 0)
    Screenshots=@($script:UiSmoke.Screenshots.ToArray())
    Errors=@($script:UiSmoke.Errors.ToArray())
}
$report | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $OutputDirectory 'ui-smoke-results.json') -Encoding UTF8
if ($script:UiSmoke.Errors.Count -gt 0) { throw ('Windows UI smoke failed: '+($script:UiSmoke.Errors -join ' | ')) }
Write-Output ('PASS production Windows UI layout, fixture connection, tabs, live log and close lifecycle; screenshots: '+$OutputDirectory)
