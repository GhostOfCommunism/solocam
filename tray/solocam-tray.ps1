<#
  solocam-tray.ps1 - tray panel for solocam (WPF), same look as the AW3821DW panel.
  Talks to the running solocam over its local settings API (http://127.0.0.1:8765, ui.py):
  background, framing, cut-out sliders, live preview, re-lock, start/stop.
#>
param([switch]$Show)

$SC_VERSION = '0.5.0'
$Api  = 'http://127.0.0.1:8765'
$Root = Split-Path -Parent $PSScriptRoot

Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Windows.Forms, System.Drawing

[xml]$xaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="solocam" Width="420" Height="720"
        WindowStyle="None" AllowsTransparency="True" Background="Transparent"
        ShowInTaskbar="False" Topmost="True" ResizeMode="NoResize">
  <Window.Resources>
    <SolidColorBrush x:Key="Bg"     Color="#1F1F1F"/>
    <SolidColorBrush x:Key="Card"   Color="#2A2A2A"/>
    <SolidColorBrush x:Key="Txt"    Color="#F2F2F2"/>
    <SolidColorBrush x:Key="Dim"    Color="#9A9A9A"/>
    <SolidColorBrush x:Key="Accent" Color="#4CC2FF"/>
    <SolidColorBrush x:Key="Line"   Color="#3A3A3A"/>

    <Style TargetType="TextBlock">
      <Setter Property="Foreground" Value="{StaticResource Txt}"/>
      <Setter Property="FontFamily" Value="Segoe UI Variable Text, Segoe UI"/>
      <Setter Property="FontSize" Value="13"/>
    </Style>
    <Style x:Key="Head" TargetType="TextBlock">
      <Setter Property="Foreground" Value="{StaticResource Dim}"/>
      <Setter Property="FontFamily" Value="Segoe UI Variable Text, Segoe UI"/>
      <Setter Property="FontSize" Value="11"/>
      <Setter Property="Margin" Value="2,18,0,8"/>
    </Style>
    <Style x:Key="Note" TargetType="TextBlock">
      <Setter Property="Foreground" Value="{StaticResource Dim}"/>
      <Setter Property="FontFamily" Value="Segoe UI Variable Text, Segoe UI"/>
      <Setter Property="FontSize" Value="11"/>
      <Setter Property="TextWrapping" Value="Wrap"/>
    </Style>

    <Style x:Key="Slim" TargetType="Slider">
      <Setter Property="Foreground" Value="{StaticResource Accent}"/>
      <Setter Property="Height" Value="30"/>
      <Setter Property="IsMoveToPointEnabled" Value="True"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Slider">
            <Grid VerticalAlignment="Center" Background="Transparent">
              <Border Height="6" CornerRadius="3" Background="#3D3D3D"/>
              <Track x:Name="PART_Track">
                <Track.Thumb>
                  <Thumb Width="20" Height="20">
                    <Thumb.Template>
                      <ControlTemplate TargetType="Thumb">
                        <Grid>
                          <Ellipse Fill="#F2F2F2"/>
                          <Ellipse Fill="{StaticResource Accent}" Margin="4"/>
                        </Grid>
                      </ControlTemplate>
                    </Thumb.Template>
                  </Thumb>
                </Track.Thumb>
                <Track.DecreaseRepeatButton>
                  <RepeatButton Command="Slider.DecreaseLarge">
                    <RepeatButton.Template>
                      <ControlTemplate TargetType="RepeatButton">
                        <Grid Background="Transparent"><Border Height="6" CornerRadius="3" Background="{StaticResource Accent}"/></Grid>
                      </ControlTemplate>
                    </RepeatButton.Template>
                  </RepeatButton>
                </Track.DecreaseRepeatButton>
                <Track.IncreaseRepeatButton><RepeatButton Opacity="0" Command="Slider.IncreaseLarge"/></Track.IncreaseRepeatButton>
              </Track>
            </Grid>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style TargetType="Button">
      <Setter Property="Foreground" Value="{StaticResource Txt}"/>
      <Setter Property="FontFamily" Value="Segoe UI Variable Text, Segoe UI"/>
      <Setter Property="FontSize" Value="13"/>
      <Setter Property="Height" Value="34"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="B" CornerRadius="6" Background="{StaticResource Card}"
                    BorderBrush="{StaticResource Line}" BorderThickness="1">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="B" Property="Background" Value="#383838"/>
              </Trigger>
              <Trigger Property="Tag" Value="on">
                <Setter TargetName="B" Property="Background" Value="#2B5A73"/>
                <Setter TargetName="B" Property="BorderBrush" Value="{StaticResource Accent}"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style TargetType="CheckBox">
      <Setter Property="Foreground" Value="{StaticResource Txt}"/>
      <Setter Property="FontFamily" Value="Segoe UI Variable Text, Segoe UI"/>
      <Setter Property="FontSize" Value="13"/>
      <Setter Property="Margin" Value="0,4,0,0"/>
    </Style>
  </Window.Resources>

  <Border Background="{StaticResource Bg}" CornerRadius="10" BorderBrush="{StaticResource Line}" BorderThickness="1">
    <Grid Margin="14,12,6,12">
      <Grid.RowDefinitions>
        <RowDefinition Height="Auto"/>
        <RowDefinition Height="*"/>
      </Grid.RowDefinitions>

      <StackPanel Grid.Row="0" Margin="2,0,10,8">
        <DockPanel>
          <TextBlock Text="solocam" FontSize="15" FontWeight="SemiBold"/>
          <TextBlock x:Name="TxtVer" Foreground="{StaticResource Dim}" FontSize="11"
                     VerticalAlignment="Center" HorizontalAlignment="Right"/>
        </DockPanel>
        <TextBlock x:Name="LblStatus" Foreground="{StaticResource Dim}" FontSize="12" Margin="0,2,0,8"/>
        <Border Height="214" CornerRadius="8" Background="#0C0E11">
          <Grid>
            <Image x:Name="ImgPv" Stretch="Uniform"/>
            <TextBlock x:Name="LblPv" Text="Предпросмотр выключен" Foreground="#8B94A1"
                       HorizontalAlignment="Center" VerticalAlignment="Center"/>
          </Grid>
        </Border>
        <Grid Margin="0,8,0,0">
          <Grid.ColumnDefinitions><ColumnDefinition/><ColumnDefinition Width="8"/><ColumnDefinition/></Grid.ColumnDefinitions>
          <Button x:Name="BtnPv" Grid.Column="0" Content="Показать предпросмотр"/>
          <Button x:Name="BtnRelock" Grid.Column="2" Content="Перезахватить меня"
                  ToolTip="Заново выбрать самого крупного человека в кадре"/>
        </Grid>
      </StackPanel>

      <ScrollViewer Grid.Row="1" VerticalScrollBarVisibility="Auto">
        <StackPanel Margin="2,0,10,0">
          <TextBlock Text="ФОН" Style="{StaticResource Head}" Margin="2,6,0,8"/>
          <UniformGrid Columns="2">
            <Button x:Name="BtnModeColor" Content="Цвет" Margin="0,0,4,0"/>
            <Button x:Name="BtnModeImage" Content="Картинка" Margin="4,0,0,0"/>
          </UniformGrid>
          <StackPanel x:Name="PanColor" Orientation="Horizontal" Margin="0,10,0,0">
            <Border x:Name="Swatch" Width="34" Height="34" CornerRadius="6" BorderBrush="{StaticResource Line}" BorderThickness="1"/>
            <Button x:Name="BtnPickColor" Content="Выбрать цвет…" Width="150" Margin="8,0,0,0"/>
          </StackPanel>
          <StackPanel x:Name="PanImage" Margin="0,10,0,0">
            <Button x:Name="BtnPickImage" Content="Загрузить картинку…"/>
            <WrapPanel x:Name="Gallery" Margin="0,8,0,0"/>
            <TextBlock Text="правый клик по картинке — удалить" Style="{StaticResource Note}"/>
          </StackPanel>

          <TextBlock Text="КАДРИРОВАНИЕ" Style="{StaticResource Head}"/>
          <CheckBox x:Name="ChkCut" Content="Кадр по линии отсечки"/>
          <TextBlock Text="низ кадра — по линии отсечки торса, без пустой полосы снизу" Style="{StaticResource Note}" Margin="22,0,0,4"/>
          <CheckBox x:Name="ChkBody" Content="Кадр вокруг фигуры"/>
          <TextBlock Text="приближать и вести камеру за вами" Style="{StaticResource Note}" Margin="22,0,0,4"/>
          <DockPanel Margin="0,8,0,0"><TextBlock Text="Поля вокруг фигуры"/><TextBlock x:Name="Lbl_crop_pad" HorizontalAlignment="Right" Foreground="{StaticResource Dim}"/></DockPanel>
          <Slider x:Name="Sld_crop_pad" Style="{StaticResource Slim}" Minimum="0" Maximum="0.6" SmallChange="0.05" LargeChange="0.05"/>

          <TextBlock Text="ВЫРЕЗАНИЕ" Style="{StaticResource Head}"/>
          <DockPanel><TextBlock Text="Линия отсечки ниже плеч"/><TextBlock x:Name="Lbl_below" HorizontalAlignment="Right" Foreground="{StaticResource Dim}"/></DockPanel>
          <Slider x:Name="Sld_below" Style="{StaticResource Slim}" Minimum="0" Maximum="2" SmallChange="0.05" LargeChange="0.1"/>
          <TextBlock Text="0 — по плечам; больше — виден торс" Style="{StaticResource Note}" Margin="0,0,0,8"/>
          <DockPanel><TextBlock Text="Запасная линия"/><TextBlock x:Name="Lbl_cut" HorizontalAlignment="Right" Foreground="{StaticResource Dim}"/></DockPanel>
          <Slider x:Name="Sld_cut" Style="{StaticResource Slim}" Minimum="0.3" Maximum="1" SmallChange="0.01" LargeChange="0.05"/>
          <TextBlock Text="доля высоты кадра, когда плечи не видны; 1 — не отсекать" Style="{StaticResource Note}" Margin="0,0,0,8"/>
          <DockPanel><TextBlock Text="Запас маски, px"/><TextBlock x:Name="Lbl_grow" HorizontalAlignment="Right" Foreground="{StaticResource Dim}"/></DockPanel>
          <Slider x:Name="Sld_grow" Style="{StaticResource Slim}" Minimum="1" Maximum="41" SmallChange="2" LargeChange="4"/>
          <TextBlock Text="больше — меньше режет волосы, но лезет кресло" Style="{StaticResource Note}" Margin="0,0,0,8"/>
          <DockPanel><TextBlock Text="Мягкость края, px"/><TextBlock x:Name="Lbl_feather" HorizontalAlignment="Right" Foreground="{StaticResource Dim}"/></DockPanel>
          <Slider x:Name="Sld_feather" Style="{StaticResource Slim}" Minimum="1" Maximum="61" SmallChange="2" LargeChange="4"/>
          <DockPanel Margin="0,8,0,0"><TextBlock Text="Держать маску при потере, с"/><TextBlock x:Name="Lbl_hold" HorizontalAlignment="Right" Foreground="{StaticResource Dim}"/></DockPanel>
          <Slider x:Name="Sld_hold" Style="{StaticResource Slim}" Minimum="0" Maximum="5" SmallChange="0.1" LargeChange="0.5"/>

          <Button x:Name="BtnReset" Content="Сбросить к стандартным" Margin="0,16,0,0"/>
          <TextBlock x:Name="LblErr" Style="{StaticResource Note}" Foreground="#FF7A7A" Margin="2,8,0,4"/>
        </StackPanel>
      </ScrollViewer>
    </Grid>
  </Border>
</Window>
"@

$win = [Windows.Markup.XamlReader]::Load((New-Object System.Xml.XmlNodeReader $xaml))
function N($name) { return $win.FindName($name) }
(N 'TxtVer').Text = "v$SC_VERSION"

# --- API ----------------------------------------------------------------------
function New-Client { $wc = New-Object Net.WebClient; $wc.Encoding = [Text.Encoding]::UTF8; return $wc }
function Get-ApiError($e) {
    # a 400 carries {"error": "..."}; anything else means solocam is not there
    $r = $e.Exception.InnerException.Response
    if ($r) {
        try { return ((New-Object IO.StreamReader($r.GetResponseStream())).ReadToEnd() | ConvertFrom-Json).error } catch { }
    }
    return 'solocam не отвечает'
}
function Test-Up {
    # connecting to a closed port costs ~1 s on Windows; ask the TCP table instead (instant)
    return [bool]([Net.NetworkInformation.IPGlobalProperties]::GetIPGlobalProperties().GetActiveTcpListeners() |
        Where-Object { $_.Port -eq 8765 })
}
function Api-State { if (-not (Test-Up)) { return $null }; try { return (New-Client).DownloadString("$Api/state") | ConvertFrom-Json } catch { return $null } }
function Api-Post($path, $obj, [byte[]]$bytes = $null) {
    try {
        $wc = New-Client
        if ($bytes) {
            $wc.Headers['Content-Type'] = 'application/octet-stream'
            [void]$wc.UploadData("$Api$path", 'POST', $bytes)
        } else {
            $wc.Headers['Content-Type'] = 'application/json'
            [void]$wc.UploadString("$Api$path", 'POST', ($obj | ConvertTo-Json -Compress))
        }
        (N 'LblErr').Text = ''
        return $true
    } catch {
        (N 'LblErr').Text = Get-ApiError $_
        return $false
    }
}
function Get-Jpeg([string]$path) {
    if (-not $script:st) { return $null }
    try { $b = (New-Client).DownloadData("$Api$path") } catch { return $null }
    if (-not $b -or $b.Length -eq 0) { return $null }  # 204: no frame yet
    $bi = New-Object Windows.Media.Imaging.BitmapImage
    $bi.BeginInit(); $bi.CacheOption = 'OnLoad'
    $bi.StreamSource = New-Object IO.MemoryStream(, $b)
    $bi.EndInit(); $bi.Freeze()
    return $bi
}

# --- controls -----------------------------------------------------------------
$script:st = $null
$script:loading = $false
$script:mode = 'color'
$Sliders = @{ crop_pad = '0.00'; below = '0.00'; cut = '0.00'; grow = '0'; feather = '0'; hold = '0.0' }
$Defaults = @{ below = 0.8; cut = 0.65; grow = 9; feather = 21; hold = 1.5; crop_pad = 0.15; crop_cut = $false; crop_body = $false }
$Ints = @('grow', 'feather')

$script:pending = @{}
$script:writeTimer = New-Object Windows.Threading.DispatcherTimer
$script:writeTimer.Interval = [TimeSpan]::FromMilliseconds(250)
$script:writeTimer.Add_Tick({
    $script:writeTimer.Stop()
    if ($script:pending.Count -eq 0) { return }
    $body = @{} + $script:pending
    $script:pending.Clear()
    [void](Api-Post '/settings' $body)
})

foreach ($k in $Sliders.Keys) {
    $sld = N "Sld_$k"
    $sld.Add_ValueChanged({
        $k = $this.Name.Substring(4)  # Sld_<setting>
        $v = if ($Ints -contains $k) { [int]([Math]::Round($this.Value)) -bor 1 } else { [Math]::Round($this.Value, 2) }
        (N "Lbl_$k").Text = $v.ToString($Sliders[$k], [Globalization.CultureInfo]::InvariantCulture)
        if ($script:loading) { return }
        $script:pending[$k] = $v
        $script:writeTimer.Stop(); $script:writeTimer.Start()
    })
}
(N 'ChkCut').Add_Click({ [void](Api-Post '/settings' @{ crop_cut = [bool]$this.IsChecked }) })
(N 'ChkBody').Add_Click({ [void](Api-Post '/settings' @{ crop_body = [bool]$this.IsChecked }) })

function Is-Image($bg) { return $bg -and -not $bg.StartsWith('#') }

function Show-Mode {
    foreach ($m in @('Color', 'Image')) { (N "BtnMode$m").Tag = $(if ($script:mode -eq $m.ToLower()) { 'on' } else { $null }) }
    (N 'PanColor').Visibility = $(if ($script:mode -eq 'color') { 'Visible' } else { 'Collapsed' })
    (N 'PanImage').Visibility = $(if ($script:mode -eq 'image') { 'Visible' } else { 'Collapsed' })
}

function Show-Gallery {
    $g = N 'Gallery'; $g.Children.Clear()
    $cur = if (Is-Image $script:st.settings.bg) { Split-Path -Leaf $script:st.settings.bg } else { '' }
    foreach ($name in $script:st.backgrounds) {
        $img = New-Object Windows.Controls.Image
        $img.Source = Get-Jpeg "/bgfile?n=$([Uri]::EscapeDataString($name))"
        $img.Stretch = 'UniformToFill'
        $b = New-Object Windows.Controls.Border
        $b.Width = 88; $b.Height = 50; $b.Margin = '0,0,6,6'; $b.CornerRadius = 5
        $b.BorderThickness = 2; $b.Cursor = 'Hand'; $b.Child = $img; $b.Tag = $name
        $b.BorderBrush = $(if ($name -eq $cur) { $win.FindResource('Accent') } else { [Windows.Media.Brushes]::Transparent })
        $b.Add_MouseLeftButtonUp({ if (Api-Post '/bgpick' @{ name = $this.Tag }) { Sync-All } })
        $menu = New-Object Windows.Controls.ContextMenu
        $mi = New-Object Windows.Controls.MenuItem; $mi.Header = 'Удалить'; $mi.Tag = $name
        $mi.Add_Click({ if (Api-Post '/bgdelete' @{ name = $this.Tag }) { Sync-All } })
        [void]$menu.Items.Add($mi); $b.ContextMenu = $menu
        [void]$g.Children.Add($b)
    }
}

function Sync-All {
    $script:st = Api-State
    Show-Status
    if (-not $script:st) { return }
    $s = $script:st.settings
    $script:loading = $true
    foreach ($k in $Sliders.Keys) { (N "Sld_$k").Value = [double]$s.$k }
    (N 'ChkCut').IsChecked = [bool]$s.crop_cut
    (N 'ChkBody').IsChecked = [bool]$s.crop_body
    $script:loading = $false
    $script:mode = if (Is-Image $s.bg) { 'image' } else { 'color' }
    if ($s.bg.StartsWith('#')) { (N 'Swatch').Background = (New-Object Windows.Media.BrushConverter).ConvertFromString($s.bg) }
    Show-Mode
    Show-Gallery
}

function Show-Status {
    $st = $script:st
    if (-not $st) { $txt = 'solocam не запущен'; $color = 'Red' }
    else {
        switch ($st.status) {
            'active'   { $txt = "работает · $($st.fps) кадров/с · " + $(if ($st.locked) { 'вы в кадре' } else { 'никого не держит' }); $color = 'Green' }
            'starting' { $txt = 'запуск…'; $color = 'Orange' }
            default    { $txt = 'простой: камеру никто не смотрит'; $color = 'Gray' }
        }
    }
    (N 'LblStatus').Text = $txt
    $script:ni.Text = ("solocam — $txt").Substring(0, [Math]::Min(63, ("solocam — $txt").Length))
    if ($script:iconColor -ne $color) { $script:iconColor = $color; $script:ni.Icon = New-TrayIcon $color }
}

(N 'BtnModeColor').Add_Click({ $script:mode = 'color'; Show-Mode; $c = (N 'Swatch').Background; $hex = if ($c) { '#' + $c.Color.ToString().Substring(3) } else { '#232a33' }; [void](Api-Post '/settings' @{ bg = $hex.ToLower() }) })
(N 'BtnModeImage').Add_Click({
    $script:mode = 'image'; Show-Mode
    $list = @($script:st.backgrounds)
    if ($list.Count) { [void](Api-Post '/bgpick' @{ name = $list[-1] }); Sync-All }
})
(N 'BtnPickColor').Add_Click({
    $d = New-Object Windows.Forms.ColorDialog; $d.FullOpen = $true
    $c = (N 'Swatch').Background
    if ($c) { $d.Color = [Drawing.Color]::FromArgb($c.Color.R, $c.Color.G, $c.Color.B) }
    $script:dialog = $true
    try { $ok = $d.ShowDialog() -eq 'OK' } finally { $script:dialog = $false }
    if ($ok) {
        $hex = '#{0:x2}{1:x2}{2:x2}' -f $d.Color.R, $d.Color.G, $d.Color.B
        if (Api-Post '/settings' @{ bg = $hex }) { Sync-All }
    }
    $win.Show(); [void]$win.Activate()
})
(N 'BtnPickImage').Add_Click({
    $d = New-Object Microsoft.Win32.OpenFileDialog
    $d.Filter = 'Картинки|*.jpg;*.jpeg;*.png;*.bmp;*.webp|Все файлы|*.*'
    $script:dialog = $true
    try { $ok = $d.ShowDialog($win) } finally { $script:dialog = $false }
    if ($ok) {
        if (Api-Post '/bg' $null ([IO.File]::ReadAllBytes($d.FileName))) { Sync-All }
    }
    $win.Show(); [void]$win.Activate()
})
(N 'BtnReset').Add_Click({ if (Api-Post '/settings' $Defaults) { Sync-All } })
(N 'BtnRelock').Add_Click({ [void](Api-Post '/relock' @{}) })

# --- preview: poll one frame at a time; each request keeps solocam's pipeline up for 3 s ---
$script:pvTimer = New-Object Windows.Threading.DispatcherTimer
$script:pvTimer.Interval = [TimeSpan]::FromMilliseconds(100)
$script:pvTimer.Add_Tick({
    $bi = Get-Jpeg '/snapshot.jpg'
    if ($bi) { (N 'ImgPv').Source = $bi; (N 'LblPv').Text = '' }
    elseif (-not (N 'ImgPv').Source) { (N 'LblPv').Text = 'включаю камеру…' }
})
function Stop-Preview {
    $script:pvTimer.Stop()
    (N 'ImgPv').Source = $null
    (N 'LblPv').Text = 'Предпросмотр выключен'
    (N 'BtnPv').Content = 'Показать предпросмотр'
}
(N 'BtnPv').Add_Click({
    if ($script:pvTimer.IsEnabled) { Stop-Preview }
    else { $script:pvTimer.Start(); (N 'LblPv').Text = 'включаю камеру…'; (N 'BtnPv').Content = 'Скрыть предпросмотр' }
})

# --- tray -----------------------------------------------------------------------
function New-TrayIcon([string]$color) {
    # a lens in a rounded body, tinted by state; drawn so no .ico file has to ship
    $bmp = New-Object Drawing.Bitmap 32, 32
    $g = [Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode = 'AntiAlias'
    $body = New-Object Drawing.SolidBrush ([Drawing.Color]::FromName($color))
    $g.FillEllipse($body, 1, 1, 30, 30)
    $g.FillEllipse([Drawing.Brushes]::White, 8, 8, 16, 16)
    $g.FillEllipse($body, 12, 12, 8, 8)
    $g.Dispose()
    return [Drawing.Icon]::FromHandle($bmp.GetHicon())
}

$ni = New-Object Windows.Forms.NotifyIcon
$script:ni = $ni
$script:iconColor = ''
$ni.Visible = $true

function Show-Panel {
    # anchor at the cursor (it sits on the tray icon at click time), clamp to the work area
    $pt = [Windows.Forms.Cursor]::Position
    $wa = [Windows.Forms.Screen]::FromPoint($pt).WorkingArea
    $w = $win.Width; $h = $win.Height
    $left = $pt.X - ($w / 2)
    $top  = if ($pt.Y -gt ($wa.Top + $wa.Height / 2)) { $pt.Y - $h - 8 } else { $pt.Y + 8 }
    if ($left + $w -gt $wa.Right - 4) { $left = $wa.Right - $w - 4 }
    if ($left -lt $wa.Left + 4)       { $left = $wa.Left + 4 }
    if ($top + $h -gt $wa.Bottom - 4) { $top  = $wa.Bottom - $h - 4 }
    if ($top -lt $wa.Top + 4)         { $top  = $wa.Top + 4 }
    $win.Left = $left; $win.Top = $top
    $win.Show(); [void]$win.Activate()
    $win.Dispatcher.BeginInvoke([Windows.Threading.DispatcherPriority]::Background, [Action]{ Sync-All }) | Out-Null
}
function Hide-Panel { $script:hiddenAt = Get-Date; Stop-Preview; $win.Hide() }

function Invoke-Autostart([string]$cmd) {
    Start-Process powershell -WindowStyle Hidden -ArgumentList '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$Root\autostart.ps1`"", $cmd
}

$ni.Add_MouseClick({
    if ($_.Button -ne 'Left') { return }
    if ($win.IsVisible) { Hide-Panel; return }
    # clicking the icon deactivates (hides) the panel first; swallow that same click
    if (((Get-Date) - $script:hiddenAt).TotalMilliseconds -lt 350) { return }
    Show-Panel
})
$menu = New-Object Windows.Forms.ContextMenuStrip
[void]$menu.Items.Add('Открыть', $null, { Show-Panel })
[void]$menu.Items.Add('Открыть в браузере', $null, { Start-Process $Api })
[void]$menu.Items.Add('-')
$miStart = $menu.Items.Add('Запустить solocam', $null, { Invoke-Autostart 'start' })
$miStop  = $menu.Items.Add('Остановить solocam', $null, { Invoke-Autostart 'stop' })
[void]$menu.Items.Add('-')
[void]$menu.Items.Add('Выход из панели', $null, { $ni.Visible = $false; $win.Close(); [Windows.Application]::Current.Shutdown() })
$menu.Add_Opening({ $up = [bool]$script:st; $miStart.Enabled = -not $up; $miStop.Enabled = $up })
$ni.ContextMenuStrip = $menu

$script:hiddenAt = [DateTime]::MinValue
$script:dialog = $false
if (-not $Show) {
    $win.Add_Deactivated({ if (-not $script:dialog) { Hide-Panel } })
}
$win.Add_KeyDown({ if ($_.Key -eq 'Escape') { Hide-Panel } })
$win.Add_Closing({ $ni.Visible = $false })

# pre-render off-screen so the first real open is instant
$win.Left = -32000; $win.Top = -32000
$win.Show(); $win.Hide()

# status in the tray tooltip/icon every 2 s; the panel's controls are re-read on open
$stTimer = New-Object Windows.Threading.DispatcherTimer
$stTimer.Interval = [TimeSpan]::FromSeconds(2)
$stTimer.Add_Tick({ $script:st = Api-State; Show-Status })
$stTimer.Start()
$script:st = Api-State; Show-Status

if ($Show) { Show-Panel }

$app = New-Object Windows.Application
$app.ShutdownMode = 'OnExplicitShutdown'
[void]$app.Run()
