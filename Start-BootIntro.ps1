#requires -version 5.1
param(
    [switch]$Force,
    [switch]$ShellMode
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$scriptRoot = Split-Path -Parent $PSCommandPath
$configPath = Join-Path $scriptRoot 'boot-intro.config.json'

function Start-ExplorerShellIfNeeded {
    try {
        if (Get-Process -Name 'explorer' -ErrorAction SilentlyContinue) {
            return
        }

        $explorerExe = Join-Path $env:WINDIR 'explorer.exe'
        if (-not (Test-Path -LiteralPath $explorerExe)) {
            $explorerExe = Join-Path $env:SystemRoot 'explorer.exe'
        }

        if (Test-Path -LiteralPath $explorerExe) {
            Start-Process -FilePath $explorerExe -WorkingDirectory (Split-Path -Parent $explorerExe) | Out-Null
        }
    } catch {
        # BootShell.exe also has an explorer fallback if this script exits unexpectedly.
    }
}

trap {
    if ($ShellMode) {
        Start-ExplorerShellIfNeeded
    }

    throw
}

if (-not (Test-Path -LiteralPath $configPath)) {
    throw "Config not found: $configPath"
}

$config = Get-Content -LiteralPath $configPath -Raw -Encoding UTF8 | ConvertFrom-Json

function Resolve-ConfigPath {
    param(
        [string]$Path
    )

    if ([string]::IsNullOrWhiteSpace($Path)) {
        return $Path
    }

    $expandedPath = [Environment]::ExpandEnvironmentVariables($Path)
    if ([System.IO.Path]::IsPathRooted($expandedPath)) {
        return $expandedPath
    }

    return Join-Path $scriptRoot $expandedPath
}

$introVideo = Resolve-ConfigPath ([string]$config.introVideo)
$wallpaperEngineExe = Resolve-ConfigPath ([string]$config.wallpaperEngineExe)
$statePath = Join-Path $scriptRoot 'boot-intro.state.json'

function Get-EarlyConfigBool {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name,
        [bool]$Default = $false
    )

    if ($null -eq $config.PSObject.Properties[$Name]) {
        return $Default
    }

    return [bool]$config.$Name
}

function Get-SystemBootStamp {
    try {
        $bootTime = (Get-CimInstance -ClassName Win32_OperatingSystem).LastBootUpTime
        return $bootTime.ToUniversalTime().ToString('o')
    } catch {
        return ''
    }
}

function Test-PlayedThisBoot {
    param(
        [Parameter(Mandatory = $true)]
        [string]$BootStamp,
        [Parameter(Mandatory = $true)]
        [string]$LogonSessionKey
    )

    if ([string]::IsNullOrWhiteSpace($BootStamp) -or [string]::IsNullOrWhiteSpace($LogonSessionKey)) {
        return $false
    }

    if (-not (Test-Path -LiteralPath $statePath)) {
        return $false
    }

    try {
        $state = Get-Content -LiteralPath $statePath -Raw -Encoding UTF8 | ConvertFrom-Json
        return (
            [string]$state.bootStamp -eq $BootStamp -and
            [string]$state.logonSessionKey -eq $LogonSessionKey -and
            [bool]$state.played
        )
    } catch {
        return $false
    }
}

function Set-PlayedThisBoot {
    param(
        [Parameter(Mandatory = $true)]
        [string]$BootStamp,
        [Parameter(Mandatory = $true)]
        [string]$LogonSessionKey
    )

    if ([string]::IsNullOrWhiteSpace($BootStamp) -or [string]::IsNullOrWhiteSpace($LogonSessionKey)) {
        return
    }

    $state = [PSCustomObject]@{
        bootStamp = $BootStamp
        logonSessionKey = $LogonSessionKey
        played = $true
        playedAt = (Get-Date).ToUniversalTime().ToString('o')
    }

    $state | ConvertTo-Json | Set-Content -LiteralPath $statePath -Encoding UTF8
}

if (-not (Test-Path -LiteralPath $introVideo)) {
    throw "Intro video not found: $introVideo"
}

Add-Type -AssemblyName PresentationCore, PresentationFramework, WindowsBase

if (-not ('BootIntro.NativeMethods' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

namespace BootIntro {
    public static class NativeMethods {
        [StructLayout(LayoutKind.Sequential)]
        public struct Luid {
            public uint LowPart;
            public int HighPart;
        }

        [StructLayout(LayoutKind.Sequential)]
        public struct TokenStatistics {
            public Luid TokenId;
            public Luid AuthenticationId;
            public long ExpirationTime;
            public uint TokenType;
            public uint ImpersonationLevel;
            public uint DynamicCharged;
            public uint DynamicAvailable;
            public uint GroupCount;
            public uint PrivilegeCount;
            public Luid ModifiedId;
        }

        [DllImport("advapi32.dll", SetLastError = true)]
        public static extern bool OpenProcessToken(IntPtr processHandle, uint desiredAccess, out IntPtr tokenHandle);

        [DllImport("advapi32.dll", SetLastError = true)]
        public static extern bool GetTokenInformation(
            IntPtr tokenHandle,
            int tokenInformationClass,
            IntPtr tokenInformation,
            int tokenInformationLength,
            out int returnLength);

        [DllImport("kernel32.dll")]
        public static extern bool CloseHandle(IntPtr handle);

        [DllImport("user32.dll")]
        public static extern IntPtr GetForegroundWindow();

        [DllImport("user32.dll", SetLastError = true)]
        public static extern IntPtr FindWindow(string lpClassName, string lpWindowName);

        [DllImport("user32.dll", SetLastError = true)]
        public static extern IntPtr FindWindowEx(IntPtr hwndParent, IntPtr hwndChildAfter, string lpszClass, string lpszWindow);

        [DllImport("user32.dll")]
        public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
    }
}
'@
}

function Get-CurrentLogonSessionKey {
    # AuthenticationId belongs to the current Windows user logon session. It is
    # renewed after a Fast Startup login even when LastBootUpTime is preserved.
    $tokenHandle = [IntPtr]::Zero
    $statisticsBuffer = [IntPtr]::Zero

    try {
        $tokenQuery = 0x0008
        $tokenStatistics = 10
        if (-not [BootIntro.NativeMethods]::OpenProcessToken(
                [System.Diagnostics.Process]::GetCurrentProcess().Handle,
                $tokenQuery,
                [ref]$tokenHandle)) {
            return ''
        }

        $size = [System.Runtime.InteropServices.Marshal]::SizeOf([type][BootIntro.NativeMethods+TokenStatistics])
        $statisticsBuffer = [System.Runtime.InteropServices.Marshal]::AllocHGlobal($size)
        $returnLength = 0
        if (-not [BootIntro.NativeMethods]::GetTokenInformation(
                $tokenHandle,
                $tokenStatistics,
                $statisticsBuffer,
                $size,
                [ref]$returnLength)) {
            return ''
        }

        $statistics = [System.Runtime.InteropServices.Marshal]::PtrToStructure(
            $statisticsBuffer,
            [type][BootIntro.NativeMethods+TokenStatistics])
        return ('{0:X8}:{1:X8}' -f [uint32]$statistics.AuthenticationId.HighPart, $statistics.AuthenticationId.LowPart)
    } catch {
        return ''
    } finally {
        if ($statisticsBuffer -ne [IntPtr]::Zero) {
            [System.Runtime.InteropServices.Marshal]::FreeHGlobal($statisticsBuffer)
        }

        if ($tokenHandle -ne [IntPtr]::Zero) {
            [BootIntro.NativeMethods]::CloseHandle($tokenHandle) | Out-Null
        }
    }
}

$script:pendingPlayedBootStamp = ''
$script:pendingPlayedLogonSessionKey = ''
if ((Get-EarlyConfigBool -Name 'playOncePerBoot' -Default $true) -and -not $Force) {
    $currentBootStamp = Get-SystemBootStamp
    $currentLogonSessionKey = Get-CurrentLogonSessionKey
    if (Test-PlayedThisBoot -BootStamp $currentBootStamp -LogonSessionKey $currentLogonSessionKey) {
        if ($ShellMode) {
            Start-ExplorerShellIfNeeded
        }

        return
    }

    $script:pendingPlayedBootStamp = $currentBootStamp
    $script:pendingPlayedLogonSessionKey = $currentLogonSessionKey
}

function Get-ConfigBool {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name,
        [bool]$Default = $false
    )

    if ($null -eq $config.PSObject.Properties[$Name]) {
        return $Default
    }

    return [bool]$config.$Name
}

function Get-ConfigInt {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name,
        [int]$Default = 0
    )

    if ($null -eq $config.PSObject.Properties[$Name]) {
        return $Default
    }

    return [int]$config.$Name
}

function Invoke-WallpaperEngineControl {
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$Arguments
    )

    if ([string]::IsNullOrWhiteSpace($wallpaperEngineExe)) {
        return
    }

    if (-not (Test-Path -LiteralPath $wallpaperEngineExe)) {
        return
    }

    try {
        Start-Process -FilePath $wallpaperEngineExe -ArgumentList $Arguments -WindowStyle Hidden | Out-Null
    } catch {
        # The overlay still works if Wallpaper Engine is not ready yet.
    }
}

function Test-WallpaperEngineRunning {
    return [bool](Get-Process -Name 'wallpaper64', 'wallpaper32' -ErrorAction SilentlyContinue)
}

function Start-WallpaperEngineIfMissing {
    if (-not (Get-ConfigBool -Name 'launchWallpaperEngineIfMissing' -Default $true)) {
        return
    }

    if (Test-WallpaperEngineRunning) {
        return
    }

    if ([string]::IsNullOrWhiteSpace($wallpaperEngineExe)) {
        return
    }

    if (-not (Test-Path -LiteralPath $wallpaperEngineExe)) {
        return
    }

    try {
        Start-Process -FilePath $wallpaperEngineExe -WorkingDirectory (Split-Path -Parent $wallpaperEngineExe) -WindowStyle Hidden | Out-Null
    } catch {
        # Wallpaper Engine autostart may still catch up on its own.
    }
}

function Wait-ForProcessName {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name,
        [int]$TimeoutSeconds = 0
    )

    if ($TimeoutSeconds -le 0) {
        return $false
    }

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        if (Get-Process -Name $Name -ErrorAction SilentlyContinue) {
            return $true
        }

        Start-Sleep -Milliseconds 200
    }

    return $false
}

function Wait-ForWallpaperEngineBeforeReveal {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Reason
    )

    if ($Reason -eq 'skip' -or $Reason -eq 'failed') {
        return
    }

    Start-WallpaperEngineIfMissing

    $waitSeconds = Get-ConfigInt -Name 'waitForWallpaperEngineSeconds' -Default 0
    if ($waitSeconds -gt 0) {
        $deadline = (Get-Date).AddSeconds($waitSeconds)
        while ((Get-Date) -lt $deadline -and -not (Test-WallpaperEngineRunning)) {
            Start-Sleep -Milliseconds 200
        }
    }

    if (Test-WallpaperEngineRunning) {
        $extraRevealDelay = Get-ConfigInt -Name 'extraRevealDelayMilliseconds' -Default 0
        if ($extraRevealDelay -gt 0) {
            Start-Sleep -Milliseconds $extraRevealDelay
        }
    }
}

function Set-WindowClassVisible {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ClassName,
        [Parameter(Mandatory = $true)]
        [bool]$Visible
    )

    $showCommand = if ($Visible) { 5 } else { 0 }
    $current = [IntPtr]::Zero

    do {
        $current = [BootIntro.NativeMethods]::FindWindowEx([IntPtr]::Zero, $current, $ClassName, $null)
        if ($current -ne [IntPtr]::Zero) {
            [BootIntro.NativeMethods]::ShowWindow($current, $showCommand) | Out-Null
        }
    } while ($current -ne [IntPtr]::Zero)
}

function Get-DesktopIconWindow {
    $progman = [BootIntro.NativeMethods]::FindWindow('Progman', $null)
    if ($progman -ne [IntPtr]::Zero) {
        $view = [BootIntro.NativeMethods]::FindWindowEx($progman, [IntPtr]::Zero, 'SHELLDLL_DefView', $null)
        if ($view -ne [IntPtr]::Zero) {
            return $view
        }
    }

    $worker = [IntPtr]::Zero
    do {
        $worker = [BootIntro.NativeMethods]::FindWindowEx([IntPtr]::Zero, $worker, 'WorkerW', $null)
        if ($worker -ne [IntPtr]::Zero) {
            $view = [BootIntro.NativeMethods]::FindWindowEx($worker, [IntPtr]::Zero, 'SHELLDLL_DefView', $null)
            if ($view -ne [IntPtr]::Zero) {
                return $view
            }
        }
    } while ($worker -ne [IntPtr]::Zero)

    return [IntPtr]::Zero
}

function Set-DesktopIconsVisible {
    param(
        [Parameter(Mandatory = $true)]
        [bool]$Visible
    )

    $view = Get-DesktopIconWindow
    if ($view -eq [IntPtr]::Zero) {
        return
    }

    $showCommand = if ($Visible) { 5 } else { 0 }
    [BootIntro.NativeMethods]::ShowWindow($view, $showCommand) | Out-Null
}

function Set-ShellVisible {
    param(
        [Parameter(Mandatory = $true)]
        [bool]$Visible
    )

    if (Get-ConfigBool -Name 'hideTaskbar' -Default $true) {
        $mainTaskbar = [BootIntro.NativeMethods]::FindWindow('Shell_TrayWnd', $null)
        if ($mainTaskbar -ne [IntPtr]::Zero) {
            $showCommand = if ($Visible) { 5 } else { 0 }
            [BootIntro.NativeMethods]::ShowWindow($mainTaskbar, $showCommand) | Out-Null
        }

        Set-WindowClassVisible -ClassName 'Shell_SecondaryTrayWnd' -Visible $Visible
    }

    if (Get-ConfigBool -Name 'hideDesktopIcons' -Default $true) {
        Set-DesktopIconsVisible -Visible $Visible
    }

    if (Get-ConfigBool -Name 'sendWallpaperEngineHideIcons' -Default $true) {
        if ($Visible) {
            Invoke-WallpaperEngineControl -Arguments @('-control', 'showIcons')
        } elseif (Test-WallpaperEngineRunning) {
            Invoke-WallpaperEngineControl -Arguments @('-control', 'hideIcons')
        }
    }
}

$window = $null
$media = $null
$topmostTimer = $null
$script:timeoutTimer = $null
$script:foregroundTimer = $null
$script:endingTimer = $null
$script:isClosing = $false
$script:shellRestored = $false
$script:mediaStarted = $false

try {
    Set-ShellVisible -Visible $false

    $window = New-Object System.Windows.Window
    $window.WindowStyle = [System.Windows.WindowStyle]::None
    $window.ResizeMode = [System.Windows.ResizeMode]::NoResize
    $window.ShowInTaskbar = $false
    $window.Topmost = $true
    $window.Background = [System.Windows.Media.Brushes]::Black
    $window.Left = [System.Windows.SystemParameters]::VirtualScreenLeft
    $window.Top = [System.Windows.SystemParameters]::VirtualScreenTop
    $window.Width = [System.Windows.SystemParameters]::VirtualScreenWidth
    $window.Height = [System.Windows.SystemParameters]::VirtualScreenHeight
    $window.WindowStartupLocation = [System.Windows.WindowStartupLocation]::Manual

    $grid = New-Object System.Windows.Controls.Grid
    $grid.Background = [System.Windows.Media.Brushes]::Black

    $media = New-Object System.Windows.Controls.MediaElement
    $media.Source = [Uri]::new($introVideo)
    $media.LoadedBehavior = [System.Windows.Controls.MediaState]::Manual
    $media.UnloadedBehavior = [System.Windows.Controls.MediaState]::Manual
    $media.Stretch = [System.Windows.Media.Stretch]::UniformToFill
    $media.Volume = if ($null -ne $config.PSObject.Properties['volume']) { [double]$config.volume } else { 0.0 }
    $media.Opacity = if ((Get-ConfigInt -Name 'fadeInMilliseconds' -Default 0) -gt 0) { 0.0 } else { 1.0 }

    if ($null -ne $config.PSObject.Properties['stretch']) {
        $media.Stretch = [System.Enum]::Parse([System.Windows.Media.Stretch], [string]$config.stretch, $true)
    }

    $grid.Children.Add($media) | Out-Null
    $window.Content = $grid

    $closeOverlay = {
        param(
            [string]$Reason = 'end'
        )

        if ($script:isClosing) {
            return
        }

        $script:isClosing = $true
        if ($topmostTimer -ne $null) {
            $topmostTimer.Stop()
        }

        if ($script:timeoutTimer -ne $null) {
            $script:timeoutTimer.Stop()
        }

        if ($script:foregroundTimer -ne $null) {
            $script:foregroundTimer.Stop()
        }

        if ($script:endingTimer -ne $null) {
            $script:endingTimer.Stop()
        }

        Wait-ForWallpaperEngineBeforeReveal -Reason $Reason

        if (-not $script:shellRestored) {
            Set-ShellVisible -Visible $true
            $script:shellRestored = $true
        }

        $fadeOutMilliseconds = Get-ConfigInt -Name 'fadeOutMilliseconds' -Default 0
        if ($Reason -eq 'skip' -or $Reason -eq 'timeout') {
            $fadeOutMilliseconds = Get-ConfigInt -Name 'skipFadeOutMilliseconds' -Default $fadeOutMilliseconds
        } elseif ($Reason -eq 'failed') {
            $fadeOutMilliseconds = 0
        }

        if ($fadeOutMilliseconds -le 0 -or $window -eq $null -or -not $window.IsVisible) {
            if ($media -ne $null) {
                $media.Stop()
            }

            if ($window -ne $null) {
                $window.Close()
            }

            return
        }

        $animation = New-Object System.Windows.Media.Animation.DoubleAnimation
        $animation.From = $window.Opacity
        $animation.To = 0.0
        $animation.Duration = New-Object System.Windows.Duration -ArgumentList ([TimeSpan]::FromMilliseconds($fadeOutMilliseconds))
        $animation.FillBehavior = [System.Windows.Media.Animation.FillBehavior]::HoldEnd

        $easing = New-Object System.Windows.Media.Animation.CubicEase
        $easing.EasingMode = [System.Windows.Media.Animation.EasingMode]::EaseInOut
        $animation.EasingFunction = $easing

        $animation.Add_Completed({
            if ($media -ne $null) {
                $media.Stop()
            }

            if ($window -ne $null) {
                $window.Close()
            }
        })

        $window.BeginAnimation([System.Windows.UIElement]::OpacityProperty, $animation)
    }

    $skipKeys = @()
    if ($null -ne $config.PSObject.Properties['skipKeys']) {
        $skipKeys = @($config.skipKeys | ForEach-Object { [string]$_ })
    }

    $window.Add_KeyDown({
        param($sender, $eventArgs)

        if ($skipKeys -contains $eventArgs.Key.ToString()) {
            & $closeOverlay 'skip'
        }
    })

    if (Get-ConfigBool -Name 'skipOnMouseClick' -Default $false) {
        $window.Add_MouseDown({
            & $closeOverlay 'skip'
        })
    }

    $startMediaFadeIn = {
        $fadeInMilliseconds = Get-ConfigInt -Name 'fadeInMilliseconds' -Default 0
        if ($fadeInMilliseconds -le 0) {
            $media.Opacity = 1.0
            return
        }

        $animation = New-Object System.Windows.Media.Animation.DoubleAnimation
        $animation.From = 0.0
        $animation.To = 1.0
        $animation.Duration = New-Object System.Windows.Duration -ArgumentList ([TimeSpan]::FromMilliseconds($fadeInMilliseconds))
        $animation.FillBehavior = [System.Windows.Media.Animation.FillBehavior]::HoldEnd

        $easing = New-Object System.Windows.Media.Animation.CubicEase
        $easing.EasingMode = [System.Windows.Media.Animation.EasingMode]::EaseInOut
        $animation.EasingFunction = $easing

        $media.BeginAnimation([System.Windows.UIElement]::OpacityProperty, $animation)
    }

    $media.Add_MediaEnded({
        & $closeOverlay 'end'
    })

    $media.Add_MediaFailed({
        & $closeOverlay 'failed'
    })

    $media.Add_MediaOpened({
        if (-not [string]::IsNullOrWhiteSpace($script:pendingPlayedBootStamp) -and
            -not [string]::IsNullOrWhiteSpace($script:pendingPlayedLogonSessionKey)) {
            Set-PlayedThisBoot `
                -BootStamp $script:pendingPlayedBootStamp `
                -LogonSessionKey $script:pendingPlayedLogonSessionKey
            $script:pendingPlayedBootStamp = ''
            $script:pendingPlayedLogonSessionKey = ''
        }

        & $startMediaFadeIn

        if (-not (Get-ConfigBool -Name 'preEndFadeOut' -Default $true)) {
            return
        }

        if (-not $media.NaturalDuration.HasTimeSpan) {
            return
        }

        $durationMilliseconds = [int]$media.NaturalDuration.TimeSpan.TotalMilliseconds
        $fadeOutMilliseconds = Get-ConfigInt -Name 'fadeOutMilliseconds' -Default 0
        $earlyCloseBufferMilliseconds = 120
        $closeAfterMilliseconds = $durationMilliseconds - $fadeOutMilliseconds - $earlyCloseBufferMilliseconds

        if ($fadeOutMilliseconds -le 0 -or $closeAfterMilliseconds -le 250) {
            return
        }

        $script:endingTimer = New-Object System.Windows.Threading.DispatcherTimer
        $script:endingTimer.Interval = [TimeSpan]::FromMilliseconds($closeAfterMilliseconds)
        $script:endingTimer.Add_Tick({
            & $closeOverlay 'end'
        })
        $script:endingTimer.Start()
    })

    $startIntroMedia = {
        if ($script:isClosing -or $script:mediaStarted -or $window -eq $null) {
            return
        }

        $windowHandle = [System.Windows.Interop.WindowInteropHelper]::new($window).Handle
        if ($windowHandle -eq [IntPtr]::Zero -or [BootIntro.NativeMethods]::GetForegroundWindow() -ne $windowHandle) {
            return
        }

        $script:mediaStarted = $true
        if ($script:foregroundTimer -ne $null) {
            $script:foregroundTimer.Stop()
        }

        $startDelay = Get-ConfigInt -Name 'startDelayMilliseconds' -Default 0
        if ($startDelay -gt 0) {
            Start-Sleep -Milliseconds $startDelay
        }

        $media.Play()
        Start-WallpaperEngineIfMissing

        $maxDurationSeconds = if ($null -ne $config.PSObject.Properties['maxDurationSeconds']) { [int]$config.maxDurationSeconds } else { 0 }
        if ($maxDurationSeconds -gt 0) {
            $script:timeoutTimer = New-Object System.Windows.Threading.DispatcherTimer
            $script:timeoutTimer.Interval = [TimeSpan]::FromSeconds($maxDurationSeconds)
            $script:timeoutTimer.Add_Tick({
                & $closeOverlay 'timeout'
            })
            $script:timeoutTimer.Start()
        }
    }

    $window.Add_ContentRendered({
        $window.Activate() | Out-Null
        if ($ShellMode) {
            Start-ExplorerShellIfNeeded
        }

        $script:foregroundTimer = New-Object System.Windows.Threading.DispatcherTimer
        $script:foregroundTimer.Interval = [TimeSpan]::FromMilliseconds(100)
        $script:foregroundTimer.Add_Tick({
            & $startIntroMedia
        })
        $script:foregroundTimer.Start()
        & $startIntroMedia
    })

    if (Get-ConfigBool -Name 'topmostWatchdog' -Default $true) {
        $topmostTimer = New-Object System.Windows.Threading.DispatcherTimer
        $topmostTimer.Interval = [TimeSpan]::FromMilliseconds(750)
        $topmostTimer.Add_Tick({
            if ($window -ne $null -and -not $script:isClosing) {
                $window.Topmost = $false
                $window.Topmost = $true
                $window.Activate() | Out-Null
            }
        })
        $topmostTimer.Start()
    }

    $window.ShowDialog() | Out-Null
} finally {
    if ($topmostTimer -ne $null) {
        $topmostTimer.Stop()
    }

    if ($script:timeoutTimer -ne $null) {
        $script:timeoutTimer.Stop()
    }

    if ($script:foregroundTimer -ne $null) {
        $script:foregroundTimer.Stop()
    }

    if ($script:endingTimer -ne $null) {
        $script:endingTimer.Stop()
    }

    if ($media -ne $null) {
        $media.Stop()
    }

    if ($ShellMode) {
        Start-ExplorerShellIfNeeded
    }

    if (-not $script:shellRestored) {
        Set-ShellVisible -Visible $true
        $script:shellRestored = $true
    }
}
