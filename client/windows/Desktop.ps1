function Set-DesktopThemeResources {
    param([object]$Window,[object]$Palette)
    $brushes = @{}
    foreach ($property in $Palette.PSObject.Properties) {
        $color = [Windows.Media.ColorConverter]::ConvertFromString([string]$property.Value)
        $value = [Windows.Media.SolidColorBrush]::new($color)
        $value.Freeze()
        $Window.Resources[$property.Name] = $value
        $brushes[$property.Name] = $value
    }
    return $brushes
}

function Show-ModernRelayWindow {
    if ([Threading.Thread]::CurrentThread.GetApartmentState() -ne [Threading.ApartmentState]::STA) {
        throw '请使用 Civ6Relay.exe 启动客户端。'
    }
    if (-not ('Civ6Relay.Desktop.PeerRow' -as [type])) {
        Add-Type -Path (Join-Path $script:PackageRoot 'DesktopModel.cs')
    }
    [Civ6Relay.Desktop.Dpi]::Enable()
    Add-Type -AssemblyName PresentationFramework
    Add-Type -AssemblyName PresentationCore
    Add-Type -AssemblyName WindowsBase
    $xaml = [IO.File]::ReadAllText((Join-Path $script:PackageRoot 'Desktop.xaml'), [Text.Encoding]::UTF8)
    $reader = New-Object Xml.XmlNodeReader ([xml]$xaml)
    try { $window = [Windows.Markup.XamlReader]::Load($reader) } finally { $reader.Close() }
    $c = @{}
    foreach ($name in @('NameInput','ServerInput','PortInput','KeyInput','GenerateKeyButton','CopyKeyButton','KeyInfo','ConnectButton','DisconnectButton',
        'LobbySaveButton','NavLobby','NavLogs','NavSettings','LobbyPage','LogsPage','SettingsPage',
        'PlayerList','EmptyState','StatusText','PlayerCount','ConnectionDot','ConnectionLabel',
        'LogBox','AutoScrollCheck','CopyLogButton','ExportLogButton','ClearLogButton','LogStatus',
        'LogFeedback','DiagnoseButton','ComponentButton','SaveButton','AutoDisconnectCheck',
        'ClientVersionText','ServerVersionText','ServerVersionButton','GithubButton','ReleasesButton',
        'ThemeClassicButton','ThemeCiv6Button','OperationPanel','OperationText','TitleBar','MinimizeButton','MaximizeButton','CloseButton')) {
        $c[$name] = $window.FindName($name)
    }
    $ui = [pscustomobject]@{
        Busy=$false; Closed=$false; Connected=$false; MonitorStarted=$false; DisconnectedOnClose=$false; LastViewError=''
        PendingTask=$null; PendingKind=''; ReadyAccess=$null; Theme=''
        Rows=(New-Object 'Collections.ObjectModel.ObservableCollection[Civ6Relay.Desktop.PeerRow]')
        RowsByIP=@{}; LogLines=(New-Object 'Collections.Generic.Queue[string]')
    }
    $c.PlayerList.ItemsSource = $ui.Rows
    $brush = @{}
    $themes = [IO.File]::ReadAllText((Join-Path $script:PackageRoot 'Themes.json')) | ConvertFrom-Json
    $preferences = Get-ClientPreferences
    $c.NameInput.Text = [string]$preferences.display_name
    $c.ServerInput.Text = [string]$preferences.endpoint
    $c.PortInput.Text = [string]$preferences.port
    $c.KeyInput.Text = Get-SavedAccessKey ([string]$preferences.endpoint) ([string]$preferences.port)
    $c.ClientVersionText.Text = '客户端版本：' + $script:ClientVersion
    $windowIcon = $null
    try {
        $icon = Join-Path $script:PackageRoot 'Civ6Relay.exe'
        if (Test-Path -LiteralPath $icon -PathType Leaf) {
            Add-Type -AssemblyName System.Drawing
            $windowIcon = [Drawing.Icon]::ExtractAssociatedIcon($icon)
            $source = [Windows.Interop.Imaging]::CreateBitmapSourceFromHIcon($windowIcon.Handle,
                [Windows.Int32Rect]::Empty, [Windows.Media.Imaging.BitmapSizeOptions]::FromEmptyOptions())
            $source.Freeze()
            $window.Icon = $source
        }
    } catch { } finally { if ($null -ne $windowIcon) { $windowIcon.Dispose() } }
    $workArea = [Windows.SystemParameters]::WorkArea
    $window.MinWidth = [Math]::Min(880, $workArea.Width)
    $window.MinHeight = [Math]::Min(620, $workArea.Height)
    $window.Width = [Math]::Min(1060, $workArea.Width)
    $window.Height = [Math]::Min(740, $workArea.Height)
    $window.MaxHeight = $workArea.Height

    $showOperation = {
        param([string]$Text, [bool]$Failed=$false)
        $c.OperationText.Text = $Text
        $c.OperationPanel.Visibility = [Windows.Visibility]::Visible
        $resource = if ($Failed) { 'ErrorTextBrush' } else { 'NoticeTextBrush' }
        $c.OperationText.SetResourceReference([Windows.Controls.Control]::ForegroundProperty, $resource)
    }
    $setControls = {
        $canEdit = !$ui.Busy -and !$ui.Connected
        foreach ($name in @('NameInput','ServerInput','PortInput','KeyInput','GenerateKeyButton')) { $c[$name].IsEnabled = $canEdit }
        $c.CopyKeyButton.IsEnabled = !$ui.Busy -and $c.KeyInput.Text.Trim().Length -gt 0
        $c.ConnectButton.IsEnabled = $canEdit
        $c.DisconnectButton.IsEnabled = !$ui.Busy
        foreach ($name in @('SaveButton','LobbySaveButton','DiagnoseButton','ComponentButton','ServerVersionButton')) {
            $c[$name].IsEnabled = !$ui.Busy
        }
    }
    $refresh = {
        if ($ui.Closed) { return }
        try {
            $snapshot = Get-LiveView
            $text = [string]$snapshot.Text
            $c.StatusText.Text = $text
            $ui.Connected = $text -ne '未连接' -and $text -ne '实时监测尚未启动'
            $c.ConnectButton.Visibility = if ($ui.Connected) { [Windows.Visibility]::Collapsed } else { [Windows.Visibility]::Visible }
            $c.DisconnectButton.Visibility = if ($ui.Connected) { [Windows.Visibility]::Visible } else { [Windows.Visibility]::Collapsed }
            if ($text.StartsWith('已接入服务器')) {
                $c.ConnectionLabel.Text = '已连接'; $c.ConnectionDot.Fill = $brush['StatusActiveBrush']
                $c.ConnectionLabel.Foreground = $brush['StatusActiveBrush']
            } elseif ($ui.Connected) {
                $c.ConnectionLabel.Text = if ($text -match '失败|无法|异常') { '状态异常' } else { '连接中' }
                $c.ConnectionDot.Fill = $brush['StatusPendingBrush']
                $c.ConnectionLabel.Foreground = $c.ConnectionDot.Fill
            } else {
                $c.ConnectionLabel.Text = '尚未连接'; $c.ConnectionDot.Fill = $brush['StatusIdleBrush']
                $c.ConnectionLabel.Foreground = $brush['SidebarMutedBrush']
            }
            $seen = @{}
            foreach ($peer in @($snapshot.Peers)) {
                $key = [string]$peer.VirtualIP
                $seen[$key] = $true
                if (!$ui.RowsByIP.ContainsKey($key)) {
                    $row = New-Object Civ6Relay.Desktop.PeerRow
                    $ui.RowsByIP[$key] = $row
                    $ui.Rows.Add($row)
                }
                $ui.RowsByIP[$key].Update([string]$peer.Player, $key, [string]$peer.Channel,
                    [string]$peer.RTT, [string]$peer.LinkRTT, [string]$peer.SampleTime)
            }
            foreach ($key in @($ui.RowsByIP.Keys)) {
                if (!$seen.ContainsKey($key)) {
                    [void]$ui.Rows.Remove($ui.RowsByIP[$key]); $ui.RowsByIP.Remove($key)
                }
            }
            $c.PlayerCount.Text = [string]$ui.Rows.Count
            $c.EmptyState.Visibility = if ($ui.Rows.Count -eq 0) { [Windows.Visibility]::Visible } else { [Windows.Visibility]::Collapsed }
            & $setControls
            $ui.LastViewError = ''
        } catch {
            $message = '状态更新失败：' + $_.Exception.Message
            $c.StatusText.Text = $message
            if ($ui.LastViewError -ne $message) { Add-LiveLog $message; $ui.LastViewError = $message }
        }
    }
    $drainLog = {
        if ($ui.Closed) { return }
        $batch = Get-LiveLog
        $c.LogStatus.Text = [string]$batch.Status
        if (!$batch.Text) { return }
        foreach ($line in ([string]$batch.Text -split '\r?\n')) { $ui.LogLines.Enqueue($line) }
        $trimmed = $false
        while ($ui.LogLines.Count -gt 1000) { [void]$ui.LogLines.Dequeue(); $trimmed = $true }
        if ($trimmed) { $c.LogBox.Text = $ui.LogLines.ToArray() -join [Environment]::NewLine }
        else {
            $prefix = if ($c.LogBox.Text.Length -gt 0) { [Environment]::NewLine } else { '' }
            $c.LogBox.AppendText($prefix + [string]$batch.Text)
        }
        if ($c.AutoScrollCheck.IsChecked) { $c.LogBox.ScrollToEnd() }
    }
    $save = {
        [void](Save-ClientPreferences $c.NameInput.Text $c.ServerInput.Text $c.PortInput.Text)
        Save-AccessKey $c.ServerInput.Text $c.PortInput.Text $c.KeyInput.Text
    }
    $runAction = {
        param([string]$Caption, [scriptblock]$Action, [bool]$KeepResult=$true)
        if ($ui.Busy -or $ui.Closed) { return }
        $ui.Busy = $true
        & $setControls
        & $showOperation $Caption
        $window.UpdateLayout()
        [void]$window.Dispatcher.Invoke([Action]{}, [Windows.Threading.DispatcherPriority]::Render)
        try {
            $result = @(& $Action)
            $message = if ($result.Count -gt 0) { $result -join [Environment]::NewLine } else { '已完成。' }
            if ($KeepResult) { & $showOperation $message }
            else { $c.OperationPanel.Visibility = [Windows.Visibility]::Collapsed }
            Add-LiveLog $message
        } catch {
            $message = $_.Exception.Message
            & $showOperation $message $true
            Add-LiveLog ('操作失败：' + $message)
        } finally {
            $ui.Busy = $false
            & $refresh
            & $setControls
        }
    }

    $showPage = {
        param([string]$Page)
        foreach ($name in @('Lobby','Logs','Settings')) {
            $c[$name+'Page'].Visibility = if ($name -eq $Page) { [Windows.Visibility]::Visible } else { [Windows.Visibility]::Collapsed }
        }
    }
    $applyTheme = {
        param([string]$Name,[bool]$Persist=$false)
        if ($ui.Theme -eq $Name) { return }
        $resources = Set-DesktopThemeResources $window $themes.$Name
        foreach ($key in $resources.Keys) { $brush[$key] = $resources[$key] }
        $ui.Theme = $Name
        $c.ThemeClassicButton.IsChecked = $Name -eq 'classic'
        $c.ThemeCiv6Button.IsChecked = $Name -eq 'civ6'
        & $refresh
        if ($Persist) { Save-DesktopTheme $Name }
    }
    $c.ThemeClassicButton.Add_Checked(({
        try { & $applyTheme 'classic' $true }
        catch { & $showOperation ('主题保存失败：' + $_.Exception.Message) $true }
    }))
    $c.ThemeCiv6Button.Add_Checked(({
        try { & $applyTheme 'civ6' $true }
        catch { & $showOperation ('主题保存失败：' + $_.Exception.Message) $true }
    }))
    & $applyTheme (Get-DesktopTheme)
    $c.NavLobby.Add_Checked(({ & $showPage 'Lobby' }))
    $c.NavLogs.Add_Checked(({ & $showPage 'Logs'; & $drainLog }))
    $c.NavSettings.Add_Checked(({ & $showPage 'Settings' }))
    $apiTimer = New-Object Windows.Threading.DispatcherTimer
    $apiTimer.Interval = [TimeSpan]::FromMilliseconds(100)
    $apiTimer.Add_Tick(({
        if (!$ui.PendingTask -or !$ui.PendingTask.IsCompleted) { return }
        $apiTimer.Stop()
        try {
            if ($ui.PendingKind -eq 'version') {
                $response = Complete-ServerVersionRequest $ui.PendingTask
                $c.ServerVersionText.Text = '服务端版本：' + [string]$response.server_version
                $message = $c.ServerVersionText.Text + '；接口：v' + [string]$response.api_version + '；组网核心：' + [string]$response.engine_version
                $c.OperationPanel.Visibility = [Windows.Visibility]::Collapsed
                Add-LiveLog $message
                $window.UpdateLayout()
                $c.ServerVersionButton.BringIntoView()
            } elseif ($ui.PendingKind -eq 'generate') {
                $response = Complete-KeyApiRequest $ui.PendingTask
                $c.KeyInput.Text = [string]$response.key
                Save-AccessKey $c.ServerInput.Text $c.PortInput.Text $c.KeyInput.Text
                if ($response.key) {
                    $c.KeyInfo.Text = '联机玩家请填写同一个 Key。'
                    $c.KeyInfo.Visibility = [Windows.Visibility]::Visible
                    $c.OperationPanel.Visibility = [Windows.Visibility]::Collapsed
                } else {
                    $c.KeyInfo.Visibility = [Windows.Visibility]::Collapsed
                    & $showOperation ([string]$response.message)
                }
            } else {
                $response = Complete-KeyApiRequest $ui.PendingTask
                $ui.ReadyAccess = $response
                $ui.Busy = $false
                & $runAction '正在连接网络…' { Connect-Relay -ServerAccess $ui.ReadyAccess } $false
                if ($response.PSObject.Properties['expires_at']) {
                    $c.KeyInfo.Text = '到期时间：' + [DateTimeOffset]::FromUnixTimeSeconds([long]$response.expires_at).ToLocalTime().ToString('MM-dd HH:mm')
                    $c.KeyInfo.Visibility = [Windows.Visibility]::Visible
                } else { $c.KeyInfo.Visibility = [Windows.Visibility]::Collapsed }
            }
        } catch {
            if ($ui.PendingKind -eq 'version') {
                $c.ServerVersionText.Text = '查询失败：' + $_.Exception.Message
                $c.OperationPanel.Visibility = [Windows.Visibility]::Collapsed
                $window.UpdateLayout()
                $c.ServerVersionButton.BringIntoView()
            } else { & $showOperation $_.Exception.Message $true }
            $failureLabel = if ($ui.PendingKind -eq 'version') { '版本查询失败：' } else { '连接操作失败：' }
            Add-LiveLog ($failureLabel + $_.Exception.Message)
            if ($_.Exception.Data['AccessCode'] -eq 'KEY_REQUIRED') { [void]$c.KeyInput.Focus() }
        } finally {
            $ui.PendingTask = $null; $ui.PendingKind = ''; $ui.ReadyAccess = $null
            $ui.Busy = $false
            & $refresh; & $setControls
        }
    }))
    $beginApi = {
        param([string]$Kind)
        if ($ui.Busy -or ($ui.Connected -and $Kind -ne 'version')) { return }
        try {
            $target = New-ClientPreferences $(if ($Kind -eq 'connect') { $c.NameInput.Text } else { '连接' }) $c.ServerInput.Text $c.PortInput.Text
            if ($Kind -eq 'connect') { & $save }
            if ($Kind -eq 'version') {
                $ui.PendingTask = Start-ServerVersionRequest $target.endpoint ([string]$target.port)
            } else {
                $body = @{device_id=(Get-DeviceInstanceId)}
                $path = '/v1/keys'
                if ($Kind -eq 'connect') { $body.key=$c.KeyInput.Text.Trim(); $path='/v1/connect' }
                $ui.PendingTask = Start-KeyApiRequest $target.endpoint ([string]$target.port) $path $body
            }
            $ui.PendingKind = $Kind; $ui.Busy = $true
            & $setControls
            if ($Kind -eq 'version') {
                $c.ServerVersionText.Text = '服务端版本：查询中…'
                $c.OperationPanel.Visibility = [Windows.Visibility]::Collapsed
            } else {
                & $showOperation $(if ($Kind -eq 'generate') { '正在获取 Key…' } else { '正在连接服务器…' })
            }
            $apiTimer.Start()
        } catch {
            if ($Kind -eq 'version') {
                $c.ServerVersionText.Text = '查询失败：' + $_.Exception.Message
                $c.OperationPanel.Visibility = [Windows.Visibility]::Collapsed
            } else { & $showOperation $_.Exception.Message $true }
        }
    }
    $c.GenerateKeyButton.Add_Click(({ & $beginApi 'generate' }))
    $c.ServerVersionButton.Add_Click(({ & $beginApi 'version' }))
    $resetServerVersion = { $c.ServerVersionText.Text = '服务端版本：尚未查询' }
    $c.ServerInput.Add_TextChanged($resetServerVersion)
    $c.PortInput.Add_TextChanged($resetServerVersion)
    $c.GithubButton.Add_Click(({
        try { Open-ProjectPage 'Repository' }
        catch { & $showOperation ('无法打开 GitHub：' + $_.Exception.Message) $true }
    }))
    $c.ReleasesButton.Add_Click(({
        try { Open-ProjectPage 'Releases' }
        catch { & $showOperation ('无法打开下载页面：' + $_.Exception.Message) $true }
    }))
    $c.CopyKeyButton.Add_Click(({
        try { [Windows.Clipboard]::SetText($c.KeyInput.Text.Trim()); & $showOperation '已复制。' }
        catch { & $showOperation '复制失败，请手动复制 Key。' $true }
    }))
    $c.KeyInput.Add_TextChanged(({ & $setControls }))
    $c.ConnectButton.Add_Click(({
        try {
            $target = New-ClientPreferences $c.NameInput.Text $c.ServerInput.Text $c.PortInput.Text
            if (Get-OwnRelayProcess) { & $runAction '正在连接网络…' { & $save; Connect-Relay } $false }
            elseif (Test-UseServerAccess $target $c.KeyInput.Text) { & $beginApi 'connect' }
            else { & $runAction '正在连接网络…' { & $save; Connect-Relay } $false }
        } catch { & $showOperation $_.Exception.Message $true }
    }))
    $c.DisconnectButton.Add_Click(({ & $runAction '正在断开连接…' { Disconnect-Relay } $false }))
    $saveClick = {
        & $runAction '正在保存设置…' ({ & $save; '连接设置已保存。' })
    }
    $c.SaveButton.Add_Click($saveClick)
    $c.LobbySaveButton.Add_Click($saveClick)
    $c.DiagnoseButton.Add_Click(({ & $runAction '正在诊断网络…' { Test-Relay } }))
    $c.ComponentButton.Add_Click(({ & $runAction '正在检查组件…' { Install-Component } }))
    $c.CopyLogButton.Add_Click(({
        try {
            [Windows.Clipboard]::SetText($(if ($c.LogBox.Text) { $c.LogBox.Text } else { '暂无日志。' }))
            $c.LogFeedback.Text = '已复制'
        } catch { $c.LogFeedback.Text = '复制失败：' + $_.Exception.Message; Add-LiveLog $c.LogFeedback.Text }
    }))
    $c.ClearLogButton.Add_Click(({
        $ui.LogLines.Clear(); $c.LogBox.Clear(); $c.LogFeedback.Text = '已清空'
    }))
    $c.ExportLogButton.Add_Click(({
        try {
            $dialog = New-Object Microsoft.Win32.SaveFileDialog
            $dialog.Title = '导出运行日志'; $dialog.Filter = '文本文件 (*.txt)|*.txt'
            $dialog.FileName = '联机日志-' + [DateTime]::Now.ToString('yyyyMMdd-HHmmss') + '.txt'
            if ($dialog.ShowDialog($window)) {
                [IO.File]::WriteAllText($dialog.FileName, $c.LogBox.Text, (New-Object Text.UTF8Encoding($true)))
                $c.LogFeedback.Text = '日志已导出'
            }
        } catch { $c.LogFeedback.Text = '导出失败：' + $_.Exception.Message; Add-LiveLog $c.LogFeedback.Text }
    }))
    $toggleMaximize = {
        $window.WindowState = if ($window.WindowState -eq [Windows.WindowState]::Maximized) {
            [Windows.WindowState]::Normal
        } else { [Windows.WindowState]::Maximized }
    }
    $c.TitleBar.Add_MouseLeftButtonDown(({
        param($sender, $eventArgs)
        if ($eventArgs.ClickCount -eq 2) { & $toggleMaximize }
        else { try { $window.DragMove() } catch [InvalidOperationException] { } }
    }))
    $c.MinimizeButton.Add_Click(({ $window.WindowState = [Windows.WindowState]::Minimized }))
    $c.MaximizeButton.Add_Click($toggleMaximize)
    $c.CloseButton.Add_Click(({ $window.Close() }))
    $statusTimer = New-Object Windows.Threading.DispatcherTimer
    $statusTimer.Interval = [TimeSpan]::FromSeconds(1)
    $statusTimer.Add_Tick(({ if (!$ui.Busy) { & $refresh } }))
    $logTimer = New-Object Windows.Threading.DispatcherTimer
    $logTimer.Interval = [TimeSpan]::FromMilliseconds(250)
    $logTimer.Add_Tick(({
        try { & $drainLog }
        catch { $c.LogFeedback.Text = '日志读取失败：' + $_.Exception.Message }
    }))
    $window.Add_ContentRendered(({
        try {
            Start-LiveMonitor
            $ui.MonitorStarted = $true
            & $refresh; & $drainLog
            $statusTimer.Start(); $logTimer.Start()
        } catch { & $showOperation $_.Exception.Message $true }
    }))
    $window.Add_Closing(({
        param($sender, $eventArgs)
        if ($ui.Busy) { $eventArgs.Cancel = $true; return }
        if ($c.AutoDisconnectCheck.IsChecked -and !$ui.DisconnectedOnClose) {
            try { [void](Disconnect-Relay); $ui.DisconnectedOnClose = $true }
            catch {
                $eventArgs.Cancel = $true
                $message = '断开失败：' + $_.Exception.Message
                & $showOperation $message $true
                Add-LiveLog $message
            }
        }
    }))
    $cleanup = {
        if ($ui.Closed) { return }
        $ui.Closed = $true
        $statusTimer.Stop(); $logTimer.Stop(); $apiTimer.Stop()
        if ($ui.MonitorStarted) {
            try { Stop-LiveMonitor } catch { Add-LiveLog ('停止监测失败：' + $_.Exception.Message) }
            $ui.MonitorStarted = $false
        }
    }
    $window.Add_Closed($cleanup)
    try { [void]$window.ShowDialog() } finally { & $cleanup }
}
