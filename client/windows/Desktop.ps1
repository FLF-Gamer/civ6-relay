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
    foreach ($name in @('NameInput','ServerInput','PortInput','ConnectButton','DisconnectButton',
        'LobbySaveButton','NavLobby','NavLogs','NavSettings','LobbyPage','LogsPage','SettingsPage',
        'PlayerList','EmptyState','StatusText','PlayerCount','ConnectionDot','ConnectionLabel',
        'LogBox','AutoScrollCheck','CopyLogButton','ExportLogButton','ClearLogButton','LogStatus',
        'LogFeedback','DiagnoseButton','ComponentButton','SaveButton','AutoDisconnectCheck',
        'OperationPanel','OperationText','TitleBar','MinimizeButton','MaximizeButton','CloseButton')) {
        $c[$name] = $window.FindName($name)
    }
    $ui = [pscustomobject]@{
        Busy=$false; Closed=$false; Connected=$false; MonitorStarted=$false; DisconnectedOnClose=$false; LastViewError=''
        Rows=(New-Object 'Collections.ObjectModel.ObservableCollection[Civ6Relay.Desktop.PeerRow]')
        RowsByIP=@{}; LogLines=(New-Object 'Collections.Generic.Queue[string]')
    }
    $c.PlayerList.ItemsSource = $ui.Rows
    $brush = @{}
    foreach ($color in @('#6B7089','#46CDA1','#DDB26F','#A0A4BA','#B9DFC9','#EEECFD','#E4E0FB',
        '#6D649B','#FDEEEF','#F3D7DA','#AA5064')) {
        $brush[$color] = [Windows.Media.BrushConverter]::new().ConvertFromString($color)
    }
    $preferences = Get-ClientPreferences
    $c.NameInput.Text = [string]$preferences.display_name
    $c.ServerInput.Text = [string]$preferences.endpoint
    $c.PortInput.Text = [string]$preferences.port
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
        $c.OperationPanel.Background = if ($Failed) { $brush['#FDEEEF'] } else { $brush['#EEECFD'] }
        $c.OperationPanel.BorderBrush = if ($Failed) { $brush['#F3D7DA'] } else { $brush['#E4E0FB'] }
        $c.OperationText.Foreground = if ($Failed) { $brush['#AA5064'] } else { $brush['#6D649B'] }
    }
    $setControls = {
        $canEdit = !$ui.Busy -and !$ui.Connected
        foreach ($name in @('NameInput','ServerInput','PortInput')) { $c[$name].IsEnabled = $canEdit }
        $c.ConnectButton.IsEnabled = $canEdit
        $c.DisconnectButton.IsEnabled = !$ui.Busy
        foreach ($name in @('SaveButton','LobbySaveButton','DiagnoseButton','ComponentButton')) {
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
            $c.DisconnectButton.Visibility = if ($ui.Connected) { [Windows.Visibility]::Visible } else { [Windows.Visibility]::Collapsed }
            if ($text.StartsWith('已接入服务器')) {
                $c.ConnectionLabel.Text = '已连接'; $c.ConnectionDot.Fill = $brush['#46CDA1']
                $c.ConnectionLabel.Foreground = $brush['#B9DFC9']
            } elseif ($ui.Connected) {
                $c.ConnectionLabel.Text = if ($text -match '失败|无法|异常') { '状态异常' } else { '连接中' }
                $c.ConnectionDot.Fill = $brush['#DDB26F']; $c.ConnectionLabel.Foreground = $brush['#A0A4BA']
            } else {
                $c.ConnectionLabel.Text = '尚未连接'; $c.ConnectionDot.Fill = $brush['#6B7089']
                $c.ConnectionLabel.Foreground = $brush['#A0A4BA']
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
    $c.NavLobby.Add_Checked(({ & $showPage 'Lobby' }))
    $c.NavLogs.Add_Checked(({ & $showPage 'Logs'; & $drainLog }))
    $c.NavSettings.Add_Checked(({ & $showPage 'Settings' }))
    $c.ConnectButton.Add_Click(({
        $action = { & $save; Connect-Relay }
        & $runAction '正在连接网络…' $action $false
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
        $statusTimer.Stop(); $logTimer.Stop()
        if ($ui.MonitorStarted) {
            try { Stop-LiveMonitor } catch { Add-LiveLog ('停止监测失败：' + $_.Exception.Message) }
            $ui.MonitorStarted = $false
        }
    }
    $window.Add_Closed($cleanup)
    try { [void]$window.ShowDialog() } finally { & $cleanup }
}
