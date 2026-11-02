$repoRoot = Split-Path $PSScriptRoot -Parent
$env:ProgramData = [IO.Path]::GetTempPath()
. (Join-Path $repoRoot 'client/windows/Civ6Relay.ps1') -LibraryOnly
function Assert($Condition,[string]$Message) { if (!$Condition) { throw $Message } }
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('civ6-themes-'+[Guid]::NewGuid())
$script:ManagedRoot = $testRoot
function Protect-ManagedDirectory { $null = New-Item -ItemType Directory $script:ManagedRoot -Force }
function Get-ClientPreferences { throw 'Theme selection must work before entering connection settings' }
try {
    Assert ((Get-DesktopTheme) -eq 'classic') 'First launch must retain the original theme'
    Save-DesktopTheme 'civ6'
    Assert ((Get-DesktopTheme) -eq 'civ6') 'Theme selection did not survive a preferences reload'
    $preferences = Join-Path $testRoot 'preferences.json'
    [IO.File]::WriteAllText($preferences,'{"display_name":"朋友","endpoint":"relay.example.com","port":443}')
    $saved = [IO.File]::ReadAllText($preferences)
    Save-DesktopTheme 'classic'
    Assert ((Get-DesktopTheme) -eq 'classic') 'Returning to the original theme failed'
    Assert ([IO.File]::ReadAllText($preferences) -ceq $saved) 'Theme selection rewrote connection preferences'
    $appearance = Join-Path $testRoot 'appearance.json'
    [IO.File]::WriteAllText($appearance,'{"theme":"future-theme"}')
    Assert ((Get-DesktopTheme) -eq 'classic') 'Unsupported saved theme broke startup'
    [IO.File]::WriteAllText($appearance,'{truncated')
    Assert ((Get-DesktopTheme) -eq 'classic') 'Damaged appearance preferences broke startup'
    $palettes = Get-Content (Join-Path $repoRoot 'client/windows/Themes.json') -Raw | ConvertFrom-Json
    [xml]$xaml = Get-Content (Join-Path $repoRoot 'client/windows/Desktop.xaml') -Raw
    $ns = New-Object Xml.XmlNamespaceManager($xaml.NameTable)
    $ns.AddNamespace('w','http://schemas.microsoft.com/winfx/2006/xaml/presentation')
    $defaults = @{}
    foreach ($brush in $xaml.SelectNodes('/w:Window/w:Window.Resources/w:SolidColorBrush',$ns)) {
        $key = $brush.GetAttribute('Key','http://schemas.microsoft.com/winfx/2006/xaml')
        $defaults[$key] = $brush.Color
    }
    foreach ($property in $palettes.classic.PSObject.Properties) {
        Assert ($defaults[$property.Name] -eq $property.Value) ('XAML default differs from the original theme: '+$property.Name)
        Assert ($palettes.civ6.PSObject.Properties[$property.Name]) ('Civ6 theme is missing a resource: '+$property.Name)
    }
    foreach ($match in [regex]::Matches($xaml.OuterXml,'\{DynamicResource ([^}]+)\}')) {
        Assert ($defaults.ContainsKey($match.Groups[1].Value)) ('Unresolved theme resource: '+$match.Groups[1].Value)
    }
    Assert ($palettes.civ6.SidebarBrush -ne $palettes.classic.SidebarBrush) 'Sidebar is not themed'
    Assert ($palettes.civ6.LogBrush -ne $palettes.classic.LogBrush) 'Log page is not themed'
    Assert ($palettes.civ6.PrimaryBrush -ne $palettes.classic.PrimaryBrush) 'Primary controls are not themed'
    'PASS theme persistence before connection setup, independent settings, startup recovery and complete dynamic resource palettes'
} finally { if (Test-Path $testRoot) { Remove-Item $testRoot -Recurse -Force } }
