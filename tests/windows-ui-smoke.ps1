[CmdletBinding()]
param(
    [string]$OutputDirectory = ''
)
# Execute the actual production WPF window in Windows PowerShell 5.1 / STA.
# Only backend responses are synthetic. The fixture never opens a network,
# loads a driver, reads a profile, or writes machine preferences.
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if ($env:OS -ne 'Windows_NT' -or $PSVersionTable.PSVersion.Major -ne 5 -or $PSVersionTable.PSVersion.Minor -ne 1) {
    throw 'Run this UI smoke test in Windows PowerShell 5.1.'
}
if ([Threading.Thread]::CurrentThread.ApartmentState -ne [Threading.ApartmentState]::STA) {
    throw 'Run powershell.exe with -STA for the UI smoke test.'
}
Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase
Add-Type -AssemblyName UIAutomationProvider
Add-Type -AssemblyName UIAutomationTypes
# RenderTargetBitmap remains an actual WPF render on headless Windows runners.
[Windows.Media.RenderOptions]::ProcessRenderMode=[Windows.Interop.RenderMode]::SoftwareOnly
$repoRoot = Split-Path $PSScriptRoot -Parent
if ([string]::IsNullOrWhiteSpace($OutputDirectory)) {
    $OutputDirectory = Join-Path $repoRoot '.build/windows-ui-smoke'
}
. (Join-Path $repoRoot 'client/windows/Civ6Relay.ps1') -LibraryOnly
$OutputDirectory = [IO.Path]::GetFullPath($OutputDirectory)
$null = New-Item -ItemType Directory -Path $OutputDirectory -Force
$script:UiSmoke = @{
    Step=0; Window=$null; Connected=$false; SaveCalls=0; ConnectCalls=0
    DisconnectCalls=0; StartCalls=0; StopCalls=0; DiagnoseCalls=0; ComponentCalls=0
    Preferences=$null
    Errors=(New-Object 'Collections.Generic.List[string]')
    Screenshots=(New-Object 'Collections.Generic.List[object]')
    Clock=[Diagnostics.Stopwatch]::StartNew()
}

function Get-ClientPreferences {
    return [pscustomobject]@{display_name='';endpoint='';port=''}
}
function Save-ClientPreferences {
    param([string]$DisplayName,[string]$Endpoint,[string]$Port)
    $value=New-ClientPreferences $DisplayName $Endpoint $Port
    $script:UiSmoke.SaveCalls++
    $script:UiSmoke.Preferences=$value
    return $value
}
function Connect-Relay {
    $script:UiSmoke.ConnectCalls++
    $script:UiSmoke.Connected=$true
    return '已加入虚拟局域网。'
}
function Disconnect-Relay {
    $script:UiSmoke.DisconnectCalls++
    $script:UiSmoke.Connected=$false
    return '已断开连接。'
}
function Test-Relay {
    $script:UiSmoke.DiagnoseCalls++
    return '组网运行正常，已发现 2 位玩家。'
}
function Install-Component {
    $script:UiSmoke.ComponentCalls++
    return '组件已就绪。'
}
function Start-LiveMonitor {
    $script:UiSmoke.StartCalls++
    if ($script:UiSmoke.StartCalls -eq 1) { Add-LiveLog '延迟监测已启动。' }
}
function Stop-LiveMonitor { $script:UiSmoke.StopCalls++ }
function Get-LiveView {
    if (-not $script:UiSmoke.Connected) { return [pscustomobject]@{Text='未连接';Peers=@()} }
    return [pscustomobject]@{
        Text='已接入服务器；虚拟 IP：10.77.77.2；直连1，中继1'
        Peers=@(
            [pscustomobject]@{Player='小麦';VirtualIP='10.77.77.3';Channel='P2P 直连';RTT='8 ms';LinkRTT='7 ms';SampleTime='12:30:00'},
            [pscustomobject]@{Player='晚风';VirtualIP='10.77.77.4';Channel='服务器中继';RTT='27 ms';LinkRTT='5 ms';SampleTime='12:30:00'}
        )
    }
}
function Invoke-MeshCli { throw 'UI smoke blocked a real mesh CLI call.' }
function Initialize-RelayNative { throw 'UI smoke blocked real native component initialization.' }

function Assert-UiSmoke {
    param([bool]$Condition,[string]$Message)
    if (-not $Condition) { throw $Message }
}
function Get-UiSmokeWindow {
    $windows=New-Object 'Collections.Generic.List[Windows.Window]'
    if ($null -ne [Windows.Application]::Current) {
        foreach ($candidate in [Windows.Application]::Current.Windows) {
            if ($candidate -is [Windows.Window] -and $null -ne $candidate.FindName('NameInput') -and -not $windows.Contains($candidate)) { $windows.Add($candidate) }
        }
    }
    # A modal WPF window also works without creating an Application object.
    foreach ($source in [Windows.PresentationSource]::CurrentSources) {
        $candidate=$source.RootVisual
        if ($candidate -is [Windows.Window] -and $null -ne $candidate.FindName('NameInput') -and -not $windows.Contains($candidate)) { $windows.Add($candidate) }
    }
    Assert-UiSmoke ($windows.Count -le 1) 'Expected one production WPF window.'
    if ($windows.Count -eq 1) { return $windows[0] }
    return $null
}
function Get-UiSmokeElement {
    param([Windows.Window]$Window,[string]$Name)
    $element=$Window.FindName($Name)
    Assert-UiSmoke ($null -ne $element) ('Production element is missing: '+$Name)
    return $element
}
function Invoke-UiSmokeClick {
    param([Windows.Window]$Window,[string]$Name)
    $button=Get-UiSmokeElement $Window $Name
    Assert-UiSmoke ($button -is [Windows.Controls.Primitives.ButtonBase]) ('Expected a button: '+$Name)
    Assert-UiSmoke ($button.IsVisible -and $button.IsEnabled) ('Button is inaccessible: '+$Name)
    if ($button -is [Windows.Controls.RadioButton]) {
        # SelectionItem invokes the real RadioButton selection / Checked event.
        $peer=New-Object Windows.Automation.Peers.RadioButtonAutomationPeer($button)
        $provider=$peer.GetPattern([Windows.Automation.Peers.PatternInterface]::SelectionItem)
        ([Windows.Automation.Provider.ISelectionItemProvider]$provider).Select()
    } else {
        $button.RaiseEvent((New-Object Windows.RoutedEventArgs([Windows.Controls.Primitives.ButtonBase]::ClickEvent)))
    }
    $Window.UpdateLayout()
}
function Get-UiSmokeBounds {
    param([Windows.FrameworkElement]$Element,[Windows.Media.Visual]$Root)
    $rect=New-Object Windows.Rect(0,0,$Element.ActualWidth,$Element.ActualHeight)
    return $Element.TransformToAncestor($Root).TransformBounds($rect)
}
function Assert-UiSmokeVisible {
    param([Windows.Window]$Window,[string]$Name,[double]$MinWidth=24,[double]$MinHeight=20,[switch]$AllowDisabled)
    $element=Get-UiSmokeElement $Window $Name
    Assert-UiSmoke ($element -is [Windows.FrameworkElement]) ('Expected a visual: '+$Name)
    # A settings or lobby card may use a vertical ScrollViewer at minimum size.
    $element.BringIntoView()
    $Window.UpdateLayout()
    Assert-UiSmoke ($element.IsVisible -and ($element.IsEnabled -or $AllowDisabled)) ('Element is inaccessible: '+$Name)
    Assert-UiSmoke ($element.ActualWidth -ge $MinWidth -and $element.ActualHeight -ge $MinHeight) ('Element is too small: '+$Name)
    $root=$Window.Content
    $bounds=Get-UiSmokeBounds $element $root
    $area=New-Object Windows.Rect(-1,-1,($root.ActualWidth+2),($root.ActualHeight+2))
    Assert-UiSmoke ($area.Contains($bounds)) ('Element is clipped by the window: '+$Name)
}
function Assert-UiSmokeLayout {
    param([Windows.Window]$Window,[ValidateSet('Lobby','Logs','Settings')][string]$Page)
    $Window.UpdateLayout()
    foreach ($name in @('NavLobby','NavLogs','NavSettings','MinimizeButton','MaximizeButton','CloseButton')) {
        Assert-UiSmokeVisible $Window $name
    }
    if ($Page -eq 'Lobby') {
        $bounds=New-Object 'Collections.Generic.List[Windows.Rect]'
        foreach ($name in @('NameInput','ServerInput','PortInput')) {
            Assert-UiSmokeVisible $Window $name 64 32 -AllowDisabled:$script:UiSmoke.Connected
            $input=Get-UiSmokeElement $Window $name
            Assert-UiSmoke ($input -is [Windows.Controls.TextBox] -and -not $input.IsReadOnly -and $input.Focusable) ('Input is not editable: '+$name)
            $rect=Get-UiSmokeBounds $input $Window.Content
            foreach ($other in $bounds) { Assert-UiSmoke (-not $rect.IntersectsWith($other)) 'Editable inputs overlap.' }
            $bounds.Add($rect)
        }
        if ($script:UiSmoke.Connected) {
            Assert-UiSmokeVisible $Window 'DisconnectButton' 72 32
        } else {
            Assert-UiSmokeVisible $Window 'ConnectButton' 72 32
        }
        $list=Get-UiSmokeElement $Window 'PlayerList'
        if ($list.Items.Count -gt 0) {
            Assert-UiSmokeVisible $Window 'PlayerList' 300 96
            foreach ($item in $list.Items) {
                $container=$list.ItemContainerGenerator.ContainerFromItem($item)
                if ($null -ne $container) {
                    $rowBounds=Get-UiSmokeBounds $container $Window.Content
                    $listBounds=Get-UiSmokeBounds $list $Window.Content
                    Assert-UiSmoke ($listBounds.Contains($rowBounds)) 'A fixture player row is clipped.'
                }
            }
        }
    } elseif ($Page -eq 'Logs') {
        foreach ($name in @('CopyLogButton','ExportLogButton','ClearLogButton','AutoScrollCheck')) { Assert-UiSmokeVisible $Window $name }
        Assert-UiSmokeVisible $Window 'LogBox' 300 120
        Assert-UiSmoke ((Get-UiSmokeElement $Window 'LogBox').IsReadOnly) 'Production log must be read-only.'
    } else {
        foreach ($name in @('AutoDisconnectCheck','SaveButton','DiagnoseButton','ComponentButton')) { Assert-UiSmokeVisible $Window $name }
    }
}
function Save-UiSmokeScreenshot {
    param([Windows.Window]$Window,[string]$Name)
    $Window.UpdateLayout()
    $root=$Window.Content
    $source=[Windows.PresentationSource]::FromVisual($root)
    $scaleX=$source.CompositionTarget.TransformToDevice.M11
    $scaleY=$source.CompositionTarget.TransformToDevice.M22
    $pixelWidth=[int][Math]::Ceiling($root.ActualWidth*$scaleX)
    $pixelHeight=[int][Math]::Ceiling($root.ActualHeight*$scaleY)
    Assert-UiSmoke ($pixelWidth -gt 0 -and $pixelHeight -gt 0) 'Cannot render an empty WPF window.'
    $bitmap=New-Object Windows.Media.Imaging.RenderTargetBitmap($pixelWidth,$pixelHeight,(96*$scaleX),(96*$scaleY),[Windows.Media.PixelFormats]::Pbgra32)
    $bitmap.Render($root)
    $encoder=New-Object Windows.Media.Imaging.PngBitmapEncoder
    $encoder.Frames.Add([Windows.Media.Imaging.BitmapFrame]::Create($bitmap))
    $path=Join-Path $OutputDirectory ($Name+'.png')
    $stream=[IO.File]::Open($path,[IO.FileMode]::Create)
    try { $encoder.Save($stream) } finally { $stream.Dispose() }
    $script:UiSmoke.Screenshots.Add([pscustomobject]@{
        File=($Name+'.png');Width=$pixelWidth;Height=$pixelHeight
        LogicalWidth=$root.ActualWidth;LogicalHeight=$root.ActualHeight
        DpiX=(96*$scaleX);DpiY=(96*$scaleY);Fixture=$true;Renderer='WPF RenderTargetBitmap'
    })
}
function Stop-UiSmokeFailure {
    param([string]$Message)
    $safe=[regex]::Replace($Message,'(?<![A-Za-z0-9+/])[A-Za-z0-9+/]{43}=(?![A-Za-z0-9+/=])','[hidden]')
    $script:UiSmoke.Errors.Add($safe)
    $script:UiSmokeTimer.Stop()
    $window=$script:UiSmoke.Window
    if ($null -ne $window -and $window.IsVisible) {
        try { Save-UiSmokeScreenshot $window 'ui-failure' } catch { }
        $script:Busy=$false
        $window.Close()
    } else {
        # A malformed or undiscoverable window must not leave CI in its modal loop.
        [Windows.Threading.Dispatcher]::ExitAllFrames()
    }
}

$script:UiSmokeTimer=New-Object Windows.Threading.DispatcherTimer
$script:UiSmokeTimer.Interval=[TimeSpan]::FromMilliseconds(300)
$script:UiSmokeTimer.Add_Tick({
    $script:UiSmokeTimer.Stop()
    try {
        if ($script:UiSmoke.Clock.Elapsed.TotalSeconds -gt 30) { throw 'Timed out waiting for production WPF UI.' }
        $window=$script:UiSmoke.Window
        if ($null -eq $window) {
            $window=Get-UiSmokeWindow
            if ($null -eq $window -or -not $window.IsLoaded) { return }
            $script:UiSmoke.Window=$window
        }
        switch ($script:UiSmoke.Step) {
            0 {
                Assert-UiSmokeLayout $window 'Lobby'
                foreach ($name in @('NameInput','ServerInput','PortInput')) {
                    Assert-UiSmoke ((Get-UiSmokeElement $window $name).Text -eq '') ('First-launch field must be empty: '+$name)
                }
                Save-UiSmokeScreenshot $window 'network-initial'
                $initialWidth=$window.Width;$initialHeight=$window.Height
                Assert-UiSmoke ($window.MinWidth -le 880 -and $window.MinHeight -le 620) 'Production minimum size exceeds the target 880 x 620.'
                $window.Width=880;$window.Height=620
                Assert-UiSmokeLayout $window 'Lobby'
                $window.Width=$initialWidth;$window.Height=$initialHeight
                $window.UpdateLayout()
                (Get-UiSmokeElement $window 'NameInput').Text='方舟'
                # RFC 5737 documentation address; the mocked action never contacts it.
                (Get-UiSmokeElement $window 'ServerInput').Text='203.0.113.10'
                (Get-UiSmokeElement $window 'PortInput').Text='9527'
                Invoke-UiSmokeClick $window 'ConnectButton'
            }
            1 {
                $players=Get-UiSmokeElement $window 'PlayerList'
                if ($players.Items.Count -ne 2) { return }
                Assert-UiSmoke ($script:UiSmoke.ConnectCalls -eq 1 -and $script:UiSmoke.SaveCalls -eq 1) 'Connect did not invoke the fixture actions exactly once.'
                Assert-UiSmokeLayout $window 'Lobby'
                $channels=@($players.Items | ForEach-Object { [string]$_.Channel })
                Assert-UiSmoke (@($channels | Where-Object { $_ -match 'P2P' }).Count -eq 1) 'The direct player path is missing.'
                Assert-UiSmoke (@($channels | Where-Object { $_ -match '中继' }).Count -eq 1) 'The relayed player path is missing.'
                Save-UiSmokeScreenshot $window 'network-connected-fixture'
                Invoke-UiSmokeClick $window 'NavLogs'
            }
            2 {
                Assert-UiSmokeLayout $window 'Logs'
                $log=Get-UiSmokeElement $window 'LogBox'
                if ($log.Text -notmatch '延迟监测已启动') { return }
                Save-UiSmokeScreenshot $window 'logs-fixture'
                Invoke-UiSmokeClick $window 'ClearLogButton'
                Assert-UiSmoke ([string]::IsNullOrEmpty($log.Text)) 'Clear display did not clear the production log.'
                Add-LiveLog '小麦：P2P 直连，8 ms。'
                Add-LiveLog '晚风：服务器中继，27 ms。'
                $window.WindowState=[Windows.WindowState]::Normal
                Assert-UiSmoke ($window.MinWidth -le 880 -and $window.MinHeight -le 620) 'Production minimum size exceeds the target 880 x 620.'
                $window.Width=880;$window.Height=620
            }
            3 {
                Assert-UiSmokeLayout $window 'Logs'
                Save-UiSmokeScreenshot $window 'logs-minimum-size'
                Invoke-UiSmokeClick $window 'NavSettings'
            }
            4 {
                Assert-UiSmokeLayout $window 'Settings'
                Assert-UiSmoke ((Get-UiSmokeElement $window 'AutoDisconnectCheck').IsChecked -eq $true) 'Automatic disconnect on close must be enabled initially.'
                Invoke-UiSmokeClick $window 'DiagnoseButton'
            }
            5 {
                if ($script:UiSmoke.DiagnoseCalls -eq 0) { return }
                Assert-UiSmoke ($script:UiSmoke.DiagnoseCalls -eq 1) 'Network diagnostics did not use the fixture.'
                Assert-UiSmokeVisible $window 'ComponentButton'
                Invoke-UiSmokeClick $window 'ComponentButton'
            }
            6 {
                if ($script:UiSmoke.ComponentCalls -eq 0) { return }
                Assert-UiSmoke ($script:UiSmoke.ComponentCalls -eq 1) 'Component check did not use the fixture.'
                Assert-UiSmokeVisible $window 'SaveButton'
                Invoke-UiSmokeClick $window 'SaveButton'
            }
            7 {
                if ($script:UiSmoke.SaveCalls -lt 2) { return }
                Assert-UiSmoke ($script:UiSmoke.SaveCalls -eq 2) 'Save settings did not use the fixture.'
                Assert-UiSmokeLayout $window 'Settings'
                Save-UiSmokeScreenshot $window 'settings-minimum-size'
                Invoke-UiSmokeClick $window 'NavLobby'
            }
            8 {
                Assert-UiSmokeLayout $window 'Lobby'
                Save-UiSmokeScreenshot $window 'network-minimum-size'
                $script:UiSmoke.Step++
                Invoke-UiSmokeClick $window 'CloseButton'
                return
            }
        }
        $script:UiSmoke.Step++
    } catch { Stop-UiSmokeFailure $_.Exception.Message }
    finally {
        if ($script:UiSmoke.Step -lt 9 -and $script:UiSmoke.Errors.Count -eq 0) { $script:UiSmokeTimer.Start() }
    }
})
$script:UiSmokeUnhandled=[Windows.Threading.DispatcherUnhandledExceptionEventHandler]{
    param($sender,$eventArgs)
    $eventArgs.Handled=$true
    Stop-UiSmokeFailure $eventArgs.Exception.Message
}
$dispatcher=[Windows.Threading.Dispatcher]::CurrentDispatcher
$dispatcher.Add_UnhandledException($script:UiSmokeUnhandled)
$script:UiSmokeTimer.Start()
try { Show-RelayWindow }
catch { $script:UiSmoke.Errors.Add($_.Exception.Message) }
finally {
    $script:UiSmokeTimer.Stop()
    $dispatcher.Remove_UnhandledException($script:UiSmokeUnhandled)
    $script:UiSmoke.Clock.Stop()
}
if ($script:UiSmoke.Errors.Count -eq 0) {
    try {
        Assert-UiSmoke ($script:UiSmoke.Step -eq 9) 'Production window closed before all UI checks completed.'
        Assert-UiSmoke ($script:UiSmoke.DisconnectCalls -eq 1) 'Closing did not disconnect exactly once.'
        Assert-UiSmoke ($script:UiSmoke.StopCalls -eq 1) 'Closing did not stop its live monitor exactly once.'
        Assert-UiSmoke ($script:UiSmoke.Screenshots.Count -eq 6) 'Expected six actual production WPF renderings.'
    } catch { $script:UiSmoke.Errors.Add($_.Exception.Message) }
}
$report=[pscustomobject]@{
    ProductionUi='client/windows/Desktop.xaml + Desktop.ps1 via Civ6Relay.ps1::Show-RelayWindow'
    PowerShell=$PSVersionTable.PSVersion.ToString();Fixture=$true
    Notice='Synthetic player names, addresses and latency. Actual production WPF controls. No game, network, profile, driver or server was used.'
    Passed=($script:UiSmoke.Errors.Count -eq 0)
    Screenshots=@($script:UiSmoke.Screenshots.ToArray())
    Errors=@($script:UiSmoke.Errors.ToArray())
}
$report | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $OutputDirectory 'ui-smoke-results.json') -Encoding UTF8
if ($script:UiSmoke.Errors.Count -gt 0) { throw ('Windows UI smoke failed: '+($script:UiSmoke.Errors -join ' | ')) }
Write-Output ('PASS production WPF layout, fixture connection, navigation, live log, settings and close lifecycle; screenshots: '+$OutputDirectory)
