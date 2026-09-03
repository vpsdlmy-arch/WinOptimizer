<#
.SYNOPSIS
    WinOptimizer Native GUI (WPF / Pure PowerShell)
.DESCRIPTION
    A lightweight, zero-dependency graphical interface for the WinOptimizer state management engine.
    Runs natively on Windows 11 using built-in .NET PresentationFramework.
#>

[CmdletBinding()]
param()

# Verify Administrator permissions
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    [System.Windows.MessageBox]::Show("WinOptimizer requires Administrator privileges.`r`nPlease launch WinOptimizer using Start-GUI.bat.", "Elevation Required", "OK", "Warning")
    exit 1
}

Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase

$ScriptDir = $PSScriptRoot
$RootDir = Split-Path $ScriptDir -Parent
if (Test-Path (Join-Path $ScriptDir "components.json")) { $RootDir = $ScriptDir }
$ConfigPath = Join-Path $RootDir "components.json"
$AnalyzePath = Join-Path $RootDir "scripts\Analyze.ps1"
$ApplyPath = Join-Path $RootDir "scripts\Apply.ps1"
$RestorePath = Join-Path $RootDir "scripts\Restore.ps1"

if (-not (Test-Path $ConfigPath)) {
    [System.Windows.MessageBox]::Show("Configuration file components.json not found in $RootDir!", "Error", "OK", "Error")
    exit 1
}

# 1. Parse components
$jsonRaw = Get-Content $ConfigPath -Raw -Encoding UTF8
$configData = $jsonRaw | ConvertFrom-Json
$components = $configData.components

# 2. XAML Definition
$xamlString = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="WinOptimizer - Declarative State Manager" Height="730" Width="1100"
        WindowStartupLocation="CenterScreen" Background="#1E1E2E" Foreground="#CDD6F4"
        FontFamily="Segoe UI" FontSize="13">
    <Window.Resources>
        <Style TargetType="Button">
            <Setter Property="Background" Value="#313244"/>
            <Setter Property="Foreground" Value="#CDD6F4"/>
            <Setter Property="BorderBrush" Value="#45475A"/>
            <Setter Property="BorderThickness" Value="1"/>
            <Setter Property="Padding" Value="12,6"/>
            <Setter Property="Cursor" Value="Hand"/>
            <Setter Property="FontWeight" Value="SemiBold"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="Button">
                        <Border Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="1" CornerRadius="5">
                            <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
                        </Border>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
            <Style.Triggers>
                <Trigger Property="IsMouseOver" Value="True">
                    <Setter Property="Background" Value="#45475A"/>
                    <Setter Property="BorderBrush" Value="#89B4FA"/>
                </Trigger>
            </Style.Triggers>
        </Style>
    </Window.Resources>

    <Grid Margin="16">
        <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="*"/>
            <RowDefinition Height="135"/>
            <RowDefinition Height="Auto"/>
        </Grid.RowDefinitions>

        <!-- Top Header -->
        <Border Grid.Row="0" Background="#181825" Padding="14,10" CornerRadius="8" Margin="0,0,0,12" BorderBrush="#313244" BorderThickness="1">
            <DockPanel>
                <StackPanel Orientation="Horizontal" DockPanel.Dock="Left">
                    <TextBlock Text="WinOptimizer" FontSize="18" FontWeight="Bold" Foreground="#89B4FA" VerticalAlignment="Center"/>
                    <TextBlock Text=" | Windows 11 State Engine" FontSize="13" Foreground="#A6ADC8" VerticalAlignment="Center" Margin="6,0,0,0"/>
                </StackPanel>
                <TextBlock Text="~145 KB Pure PowerShell" DockPanel.Dock="Right" HorizontalAlignment="Right" Foreground="#A6E3A1" FontWeight="SemiBold" VerticalAlignment="Center"/>
            </DockPanel>
        </Border>

        <!-- Presets and Filter Bar -->
        <Grid Grid.Row="1" Margin="0,0,0,10">
            <Grid.ColumnDefinitions>
                <ColumnDefinition Width="Auto"/>
                <ColumnDefinition Width="*"/>
                <ColumnDefinition Width="230"/>
            </Grid.ColumnDefinitions>

            <StackPanel Grid.Column="0" Orientation="Horizontal">
                <Button Name="BtnPresetRecommended" Content="Recommended" Margin="0,0,6,0" Background="#1E66F5" Foreground="White"/>
                <Button Name="BtnPresetPrivacy" Content="Privacy Only" Margin="0,0,6,0"/>
                <Button Name="BtnPresetGaming" Content="Gaming Focus" Margin="0,0,6,0"/>
                <Button Name="BtnSelectAll" Content="Select All" Margin="0,0,6,0"/>
                <Button Name="BtnClearAll" Content="Clear All" Margin="0,0,10,0"/>
            </StackPanel>

            <TextBox Name="TxtSearch" Grid.Column="2" Padding="8,4" Background="#181825" Foreground="#CDD6F4" BorderBrush="#45475A" VerticalContentAlignment="Center" Text="Search components..."/>
        </Grid>

        <!-- Main Components Grid -->
        <Border Grid.Row="2" Background="#181825" CornerRadius="8" BorderBrush="#313244" BorderThickness="1" Margin="0,0,0,10">
            <DataGrid Name="GridComponents" AutoGenerateColumns="False" CanUserAddRows="False"
                      Background="Transparent" RowBackground="#181825" AlternatingRowBackground="#1E1E2E"
                      Foreground="#CDD6F4" GridLinesVisibility="Horizontal" HorizontalGridLinesBrush="#313244"
                      BorderThickness="0" HeadersVisibility="Column" SelectionMode="Single">
                <DataGrid.Resources>
                    <Style TargetType="DataGridColumnHeader">
                        <Setter Property="Background" Value="#313244"/>
                        <Setter Property="Foreground" Value="#CDD6F4"/>
                        <Setter Property="FontWeight" Value="SemiBold"/>
                        <Setter Property="Padding" Value="8,6"/>
                        <Setter Property="BorderThickness" Value="0"/>
                    </Style>
                    <Style TargetType="DataGridRow">
                        <Style.Triggers>
                            <Trigger Property="IsSelected" Value="True">
                                <Setter Property="Background" Value="#45475A"/>
                            </Trigger>
                        </Style.Triggers>
                    </Style>
                </DataGrid.Resources>
                <DataGrid.Columns>
                    <DataGridTemplateColumn Header="Optimize" Width="70">
                        <DataGridTemplateColumn.CellTemplate>
                            <DataTemplate>
                                <CheckBox IsChecked="{Binding IsSelected, UpdateSourceTrigger=PropertyChanged}" 
                                          HorizontalAlignment="Center" VerticalAlignment="Center"/>
                            </DataTemplate>
                        </DataGridTemplateColumn.CellTemplate>
                    </DataGridTemplateColumn>
                    <DataGridTextColumn Header="Component Name" Binding="{Binding Name}" Width="250" IsReadOnly="True"/>
                    <DataGridTextColumn Header="Subsystem" Binding="{Binding Automation}" Width="120" IsReadOnly="True"/>
                    <DataGridTextColumn Header="Target Action" Binding="{Binding Action}" Width="110" IsReadOnly="True"/>
                    <DataGridTextColumn Header="Reversible" Binding="{Binding ReversibleText}" Width="90" IsReadOnly="True"/>
                    <DataGridTextColumn Header="Description / Technical Note" Binding="{Binding Note}" Width="*" IsReadOnly="True"/>
                </DataGrid.Columns>
            </DataGrid>
        </Border>

        <!-- Details & Live Log Panel -->
        <Border Grid.Row="3" Background="#181825" CornerRadius="8" BorderBrush="#313244" BorderThickness="1" Padding="10" Margin="0,0,0,12">
            <Grid>
                <Grid.RowDefinitions>
                    <RowDefinition Height="Auto"/>
                    <RowDefinition Height="*"/>
                </Grid.RowDefinitions>
                <TextBlock Text="Execution and Analysis Output Log:" FontWeight="SemiBold" Foreground="#F9E2AF" Margin="0,0,0,6"/>
                <TextBox Name="TxtLog" Grid.Row="1" Background="#11111B" Foreground="#A6ADC8" FontFamily="Consolas" FontSize="11"
                         IsReadOnly="True" VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Auto"
                         TextWrapping="NoWrap" BorderThickness="0" Text="Ready. Click 'Analyze (Dry-Run)' to inspect configuration drift without modifying system."/>
            </Grid>
        </Border>

        <!-- Bottom Actions Bar -->
        <Grid Grid.Row="4">
            <Grid.ColumnDefinitions>
                <ColumnDefinition Width="Auto"/>
                <ColumnDefinition Width="*"/>
                <ColumnDefinition Width="Auto"/>
            </Grid.ColumnDefinitions>

            <TextBlock Name="TxtStatus" Grid.Column="0" Text="Components loaded: 0" Foreground="#A6ADC8" VerticalAlignment="Center"/>

            <StackPanel Grid.Column="2" Orientation="Horizontal">
                <Button Name="BtnAnalyze" Content="Analyze (Dry-Run)" Background="#89B4FA" Foreground="#11111B" Margin="0,0,8,0"/>
                <Button Name="BtnApply" Content="Apply Selected" Background="#A6E3A1" Foreground="#11111B" Margin="0,0,8,0"/>
                <Button Name="BtnRestore" Content="Restore (Rollback)" Background="#F38BA8" Foreground="#11111B"/>
            </StackPanel>
        </Grid>
    </Grid>
</Window>
'@

$reader = New-Object System.Xml.XmlNodeReader ([xml]$xamlString)
$window = [System.Windows.Markup.XamlReader]::Load($reader)

# 3. Element lookups
$gridComponents = $window.FindName("GridComponents")
$txtSearch = $window.FindName("TxtSearch")
$txtLog = $window.FindName("TxtLog")
$txtStatus = $window.FindName("TxtStatus")
$btnPresetRecommended = $window.FindName("BtnPresetRecommended")
$btnPresetPrivacy = $window.FindName("BtnPresetPrivacy")
$btnPresetGaming = $window.FindName("BtnPresetGaming")
$btnSelectAll = $window.FindName("BtnSelectAll")
$btnClearAll = $window.FindName("BtnClearAll")
$btnAnalyze = $window.FindName("BtnAnalyze")
$btnApply = $window.FindName("BtnApply")
$btnRestore = $window.FindName("BtnRestore")

# 4. Populate observable collection
$compItems = New-Object System.Collections.ObjectModel.ObservableCollection[psobject]

foreach ($c in $components) {
    # Determine the optimization action (what happens if checked)
    $optAction = "DISABLE"
    if ($c.automation -in @("Appx", "Capability", "OptionalFeature")) {
        $optAction = "REMOVE"
    } elseif ($c.automation -eq "Script" -and $c.id -match "temp|cache|clean") {
        $optAction = "CLEAR"
    } else {
        $optAction = "DISABLE"
    }

    # Checked if action is currently REMOVE, DISABLE, or CLEAR
    $isSelected = ($c.action -in @("REMOVE", "DISABLE", "CLEAR"))

    $displayAction = "KEEP"
    if ($isSelected) {
        $displayAction = $optAction
    }

    $revText = "No"
    if ($c.reversible) {
        $revText = "Yes"
    }

    $item = [PSCustomObject]@{
        Id             = $c.id
        Name           = $c.name
        Automation     = $c.automation
        Action         = $displayAction
        OptimizeAction = $optAction
        Reversible     = $c.reversible
        ReversibleText = $revText
        Note           = $c.note
        IsSelected     = [bool]$isSelected
        Raw            = $c
    }
    $compItems.Add($item)
}

$gridComponents.ItemsSource = $compItems
$txtStatus.Text = "Components loaded: $($compItems.Count)"

# 5. Routed Click Listener: Instant CheckBox Toggle -> Updates Action column on user click
$window.AddHandler([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent, [System.Windows.RoutedEventHandler]{
    param($sender, $e)
    if ($e.OriginalSource -is [System.Windows.Controls.CheckBox]) {
        $cb = $e.OriginalSource
        $item = $cb.DataContext
        if ($item -and $item.PSObject.Properties['Action']) {
            if ($cb.IsChecked) {
                $item.IsSelected = $true
                $item.Action = $item.OptimizeAction
            } else {
                $item.IsSelected = $false
                $item.Action = "KEEP"
            }
            $gridComponents.Items.Refresh()
        }
    }
})

# Helper function to refresh all actions after preset click
function Apply-PresetState {
    foreach ($it in $compItems) {
        if ($it.IsSelected) {
            $it.Action = $it.OptimizeAction
        } else {
            $it.Action = "KEEP"
        }
    }
    $gridComponents.Items.Refresh()
}

# 6. Search Filter
$txtSearch.Add_GotFocus({
    if ($txtSearch.Text -eq "Search components...") {
        $txtSearch.Text = ""
    }
})

$txtSearch.Add_LostFocus({
    if ([string]::IsNullOrWhiteSpace($txtSearch.Text)) {
        $txtSearch.Text = "Search components..."
    }
})

$txtSearch.Add_TextChanged({
    $term = $txtSearch.Text.Trim()
    if ($term -eq "Search components..." -or [string]::IsNullOrWhiteSpace($term)) {
        $gridComponents.ItemsSource = $compItems
    } else {
        $filtered = New-Object System.Collections.ObjectModel.ObservableCollection[psobject]
        foreach ($it in $compItems) {
            if ($it.Name -match [regex]::Escape($term) -or $it.Automation -match [regex]::Escape($term) -or $it.Note -match [regex]::Escape($term)) {
                $filtered.Add($it)
            }
        }
        $gridComponents.ItemsSource = $filtered
    }
})

# 7. Presets logic
$btnSelectAll.Add_Click({
    foreach ($it in $compItems) {
        $it.IsSelected = $true
    }
    Apply-PresetState
})

$btnClearAll.Add_Click({
    foreach ($it in $compItems) {
        $it.IsSelected = $false
    }
    Apply-PresetState
})

$btnPresetRecommended.Add_Click({
    foreach ($it in $compItems) {
        $id = $it.Id.ToLower()
        $name = $it.Name.ToLower()
        # Keep critical OS apps, gaming stack, DirectPlay, hardware drivers, and core utilities
        if ($id -match "store|xbox|xbl|gaming|gameinput|directx|directplay|runtime|redistributable|netfx|vclibs|bthserv|bluetooth|crypto|plugplay|pnp|defender|camera|spooler|stisvc|terminal|notepad|calculator|paint|photos" -or
            $name -match "store|xbox|gaming|gameinput|directx|directplay|runtime|redistributables|\.net|bluetooth|print spooler|windows camera|calculator|notepad|terminal|paint|photos") {
            $it.IsSelected = $false
        } else {
            $it.IsSelected = $true
        }
    }
    Apply-PresetState
})

$btnPresetPrivacy.Add_Click({
    foreach ($it in $compItems) {
        $id = $it.Id.ToLower()
        $name = $it.Name.ToLower()
        $note = $it.Note.ToLower()
        if ($id -match "telemetry|ceip|feedback|dmclient|appraiser|advertising|recommendation|spotlight|wersvc|nearshare|diagtrack|dmwappush|activityhistory" -or
            $name -match "diagnostic data|telemetry|customer experience|advertising|activity history" -or
            $note -match "telemetry|diagnostic|tracking|relay|advertising|reputation|tailored") {
            $it.IsSelected = $true
        } else {
            $it.IsSelected = $false
        }
    }
    Apply-PresetState
})

$btnPresetGaming.Add_Click({
    foreach ($it in $compItems) {
        $id = $it.Id.ToLower()
        $name = $it.Name.ToLower()
        # Strictly KEEP all gaming, DirectPlay, DirectX, Xbox ecosystem, GameInput, GPU, controller, runtimes
        if ($id -match "store|xbox|xbl|gaming|gameinput|directx|directplay|runtime|redistributable|netfx|vclibs|bthserv|bluetooth|crypto|plugplay|pnp|defender|nvdisplay|amd|geforce" -or
            $name -match "store|xbox|gaming|gameinput|directx|directplay|runtime|redistributables|\.net|bluetooth|plug and play|cryptographic") {
            $it.IsSelected = $false
        } else {
            $it.IsSelected = $true
        }
    }
    Apply-PresetState
})

# 8. Worker actions
$btnAnalyze.Add_Click({
    $txtLog.Text = "[Analyze] Starting pre-flight and drift audit...`r`n"
    $window.Cursor = [System.Windows.Input.Cursors]::Wait
    try {
        $outPath = Join-Path $RootDir "tmp_out.txt"
        $errPath = Join-Path $RootDir "tmp_err.txt"
        $proc = Start-Process -FilePath "powershell.exe" -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$AnalyzePath`"" -Wait -NoNewWindow -PassThru -RedirectStandardOutput $outPath -RedirectStandardError $errPath
        $out = Get-Content $outPath -Raw -ErrorAction SilentlyContinue
        $err = Get-Content $errPath -Raw -ErrorAction SilentlyContinue
        Remove-Item (Join-Path $RootDir "tmp_*.txt") -ErrorAction SilentlyContinue
        
        if ($out) {
            $txtLog.Text = $out
        } else {
            $txtLog.Text = $err
        }
    } catch {
        $txtLog.Text = "[Error] Failed to execute Analyze.ps1: " + $_.Exception.Message
    } finally {
        $window.Cursor = [System.Windows.Input.Cursors]::Arrow
    }
})

$btnApply.Add_Click({
    $selectedCount = ($compItems | Where-Object { $_.IsSelected }).Count
    $resp = [System.Windows.MessageBox]::Show("Apply changes for $selectedCount selected component(s)?`r`nThis will update components.json and record rollback logs to applied_changes.jsonl.", "Confirm Apply", "YesNo", "Question")
    if ($resp -ne "Yes") { return }

    # 1. Sync selections directly to $configData and write to components.json
    foreach ($it in $compItems) {
        $it.Raw.action = $it.Action
    }

    $jsonUpdated = $configData | ConvertTo-Json -Depth 15
    [System.IO.File]::WriteAllText($ConfigPath, $jsonUpdated, [System.Text.Encoding]::UTF8)

    $txtLog.Text = "[Apply] Configuration saved to components.json. Executing state mutations...`r`n"
    $window.Cursor = [System.Windows.Input.Cursors]::Wait
    try {
        $outPath = Join-Path $RootDir "tmp_out.txt"
        $errPath = Join-Path $RootDir "tmp_err.txt"
        $proc = Start-Process -FilePath "powershell.exe" -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$ApplyPath`"" -Wait -NoNewWindow -PassThru -RedirectStandardOutput $outPath -RedirectStandardError $errPath
        $out = Get-Content $outPath -Raw -ErrorAction SilentlyContinue
        $err = Get-Content $errPath -Raw -ErrorAction SilentlyContinue
        Remove-Item (Join-Path $RootDir "tmp_*.txt") -ErrorAction SilentlyContinue

        if ($out) {
            $txtLog.Text = $out
        } else {
            $txtLog.Text = $err
        }
    } catch {
        $txtLog.Text = "[Error] Failed to execute Apply.ps1: " + $_.Exception.Message
    } finally {
        $window.Cursor = [System.Windows.Input.Cursors]::Arrow
    }
})

$btnRestore.Add_Click({
    $resp = [System.Windows.MessageBox]::Show("Revert changes from applied_changes.jsonl in reverse-LIFO order?", "Confirm Restore", "YesNo", "Warning")
    if ($resp -ne "Yes") { return }

    $txtLog.Text = "[Restore] Initiating LIFO rollback...`r`n"
    $window.Cursor = [System.Windows.Input.Cursors]::Wait
    try {
        $outPath = Join-Path $RootDir "tmp_out.txt"
        $errPath = Join-Path $RootDir "tmp_err.txt"
        $proc = Start-Process -FilePath "powershell.exe" -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$RestorePath`"" -Wait -NoNewWindow -PassThru -RedirectStandardOutput $outPath -RedirectStandardError $errPath
        $out = Get-Content $outPath -Raw -ErrorAction SilentlyContinue
        $err = Get-Content $errPath -Raw -ErrorAction SilentlyContinue
        Remove-Item (Join-Path $RootDir "tmp_*.txt") -ErrorAction SilentlyContinue

        if ($out) {
            $txtLog.Text = $out
        } else {
            $txtLog.Text = $err
        }
    } catch {
        $txtLog.Text = "[Error] Failed to execute Restore.ps1: " + $_.Exception.Message
    } finally {
        $window.Cursor = [System.Windows.Input.Cursors]::Arrow
    }
})

# 9. Show Window with error fallback
try {
    $window.ShowDialog() | Out-Null
} catch {
    [System.Windows.MessageBox]::Show("Error displaying WinOptimizer GUI:`r`n`r`n" + $_.Exception.ToString(), "WinOptimizer Fatal Error", "OK", "Error")
}
