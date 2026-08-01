#requires -version 5.1
param(
    [ValidateSet(
        'Status',
        'Build',
        'RegisterTask',
        'UnregisterTask',
        'RegisterShell',
        'RestoreShell',
        'DisableSteamIntegration',
        'EnableSteamIntegration',
        'DisableAutostarts',
        'RestoreAutostarts',
        'RestoreDesktop',
        'Protect',
        'Unprotect',
        'Check',
        'Snapshot',
        'Compare'
    )]
    [string]$Action = 'Status',

    [string]$SnapshotPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$scriptRoot = Split-Path -Parent $PSCommandPath
$configPath = Join-Path $scriptRoot 'boot-intro.config.json'
$manifestPath = Join-Path $scriptRoot 'boot-integrity.manifest.json'
$shellBackupPath = Join-Path $scriptRoot 'shell.backup.json'
$autostartBackupPath = Join-Path $scriptRoot 'competing-autostarts.backup.json'
$taskName = 'WallpaperBootIntro'
$userWinlogonKey = 'HKCU:\Software\Microsoft\Windows NT\CurrentVersion\Winlogon'
$machineWinlogonKey = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon'

if ([string]::IsNullOrWhiteSpace($SnapshotPath)) {
    $SnapshotPath = Join-Path $scriptRoot 'security-baseline.json'
}

$protectedRelativePaths = @(
    '.gitignore',
    'boot-intro.config.json',
    'boot-intro.config.example.json',
    'WallpaperBoot.ps1',
    'Start-BootIntro.ps1',
    'Start-BootIntroHidden.vbs',
    'BootShell.cs',
    'BootShell.exe',
    'README.md',
    'media\boot-intro.mp4'
)

function Get-RegistryStringValue {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,
        [Parameter(Mandatory = $true)]
        [string]$Name
    )

    $property = Get-ItemProperty -LiteralPath $Path -Name $Name -ErrorAction SilentlyContinue
    if ($null -eq $property -or $null -eq $property.PSObject.Properties[$Name]) {
        return ''
    }

    return [string]$property.$Name
}

function Resolve-ProjectPath {
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) {
        return $Path
    }

    $expandedPath = [Environment]::ExpandEnvironmentVariables($Path)
    if ([System.IO.Path]::IsPathRooted($expandedPath)) {
        return $expandedPath
    }

    return Join-Path $scriptRoot $expandedPath
}

function Get-BootConfig {
    if (-not (Test-Path -LiteralPath $configPath -PathType Leaf)) {
        throw "Config not found: $configPath"
    }

    return Get-Content -LiteralPath $configPath -Raw -Encoding UTF8 | ConvertFrom-Json
}

function Get-WallpaperEngineExe {
    try {
        $config = Get-BootConfig
        return Resolve-ProjectPath ([string]$config.wallpaperEngineExe)
    } catch {
        return ''
    }
}

function Get-NoSteamFile {
    $wallpaperEngineExe = Get-WallpaperEngineExe
    if ([string]::IsNullOrWhiteSpace($wallpaperEngineExe)) {
        throw 'wallpaperEngineExe is not configured.'
    }

    $installDir = Split-Path -Parent $wallpaperEngineExe
    return Join-Path $installDir 'bin\nosteam.txt'
}

function Set-ReadOnlyFlag {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,
        [Parameter(Mandatory = $true)]
        [bool]$ReadOnly
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return
    }

    $item = Get-Item -LiteralPath $Path -Force
    if ($ReadOnly) {
        $item.Attributes = $item.Attributes -bor [System.IO.FileAttributes]::ReadOnly
    } else {
        $item.Attributes = $item.Attributes -band (-bnot [System.IO.FileAttributes]::ReadOnly)
    }
}

function Get-ManifestProtectedPaths {
    if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
        return $protectedRelativePaths
    }

    try {
        $manifest = Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
        return @($manifest.protectedFiles | ForEach-Object { [string]$_.path })
    } catch {
        return $protectedRelativePaths
    }
}

function Test-Integrity {
    if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
        return @("Integrity manifest not found: $manifestPath")
    }

    $manifest = Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $failures = New-Object System.Collections.Generic.List[string]

    foreach ($entry in $manifest.protectedFiles) {
        $relativePath = [string]$entry.path
        $fullPath = Join-Path $scriptRoot $relativePath

        if (-not (Test-Path -LiteralPath $fullPath -PathType Leaf)) {
            $failures.Add("Missing: $relativePath")
            continue
        }

        $item = Get-Item -LiteralPath $fullPath -Force
        $hash = Get-FileHash -LiteralPath $fullPath -Algorithm SHA256

        if ($hash.Hash -ne [string]$entry.sha256) {
            $failures.Add("Hash changed: $relativePath")
        }

        if ($item.Length -ne [int64]$entry.length) {
            $failures.Add("Size changed: $relativePath")
        }

        if ([bool]$entry.readOnly -and -not (($item.Attributes -band [System.IO.FileAttributes]::ReadOnly) -eq [System.IO.FileAttributes]::ReadOnly)) {
            $failures.Add("ReadOnly removed: $relativePath")
        }
    }

    return @($failures)
}

function Invoke-Protect {
    if (Test-Path -LiteralPath $manifestPath) {
        Set-ReadOnlyFlag -Path $manifestPath -ReadOnly $false
    }

    $manifestFiles = New-Object System.Collections.Generic.List[object]

    foreach ($relativePath in $protectedRelativePaths) {
        $fullPath = Join-Path $scriptRoot $relativePath
        if (-not (Test-Path -LiteralPath $fullPath -PathType Leaf)) {
            throw "Protected file not found: $fullPath"
        }

        Set-ReadOnlyFlag -Path $fullPath -ReadOnly $false
        $item = Get-Item -LiteralPath $fullPath -Force
        $hash = Get-FileHash -LiteralPath $fullPath -Algorithm SHA256

        $manifestFiles.Add([PSCustomObject]@{
            path = $relativePath
            sha256 = $hash.Hash
            length = $item.Length
            lastWriteTimeUtc = $item.LastWriteTimeUtc.ToString('o')
            readOnly = $true
        })
    }

    $manifest = [PSCustomObject]@{
        schema = 'WallpaperBootIntegrity.v1'
        generatedAt = (Get-Date).ToUniversalTime().ToString('o')
        root = $scriptRoot
        protectedFiles = $manifestFiles
        writableRuntimeFiles = @(
            'boot-shell.log',
            'boot-intro.state.json',
            'shell.backup.json',
            'competing-autostarts.backup.json',
            'security-baseline.json'
        )
    }

    $manifest | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $manifestPath -Encoding UTF8

    foreach ($relativePath in $protectedRelativePaths) {
        Set-ReadOnlyFlag -Path (Join-Path $scriptRoot $relativePath) -ReadOnly $true
    }

    Set-ReadOnlyFlag -Path $manifestPath -ReadOnly $true

    Write-Host 'WallpaperBoot protection enabled.'
    Write-Host "Manifest: $manifestPath"
    Write-Host "Protected files: $($protectedRelativePaths.Count)"
}

function Invoke-Unprotect {
    if (Test-Path -LiteralPath $manifestPath) {
        Set-ReadOnlyFlag -Path $manifestPath -ReadOnly $false
    }

    foreach ($relativePath in (Get-ManifestProtectedPaths)) {
        Set-ReadOnlyFlag -Path (Join-Path $scriptRoot $relativePath) -ReadOnly $false
    }

    Write-Host 'WallpaperBoot protection disabled.'
    Write-Host 'Core files are editable again.'
}

function Invoke-Check {
    $failures = @(Test-Integrity)
    if ($failures.Count -gt 0) {
        Write-Host 'WallpaperBoot integrity check FAILED.'
        foreach ($failure in $failures) {
            Write-Host "  $failure"
        }

        exit 1
    }

    Write-Host 'WallpaperBoot integrity check OK.'
    Write-Host "Manifest: $manifestPath"
}

function Invoke-Build {
    $sourcePath = Join-Path $scriptRoot 'BootShell.cs'
    $outputPath = Join-Path $scriptRoot 'BootShell.exe'

    if (-not (Test-Path -LiteralPath $sourcePath)) {
        throw "Source not found: $sourcePath"
    }

    $cscCandidates = @(
        (Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'),
        (Join-Path $env:WINDIR 'Microsoft.NET\Framework\v4.0.30319\csc.exe')
    )

    $cscExe = $cscCandidates | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
    if ([string]::IsNullOrWhiteSpace($cscExe)) {
        throw 'C# compiler not found. Expected .NET Framework csc.exe.'
    }

    Set-ReadOnlyFlag -Path $outputPath -ReadOnly $false
    & $cscExe /nologo /target:winexe /optimize+ /out:$outputPath $sourcePath
    if ($LASTEXITCODE -ne 0) {
        throw "Build failed with exit code $LASTEXITCODE"
    }

    Write-Host "Built: $outputPath"
}

function Invoke-RegisterTask {
    $bootScript = Join-Path $scriptRoot 'Start-BootIntro.ps1'
    $launcherScript = Join-Path $scriptRoot 'Start-BootIntroHidden.vbs'
    $wscriptExe = Join-Path $env:SystemRoot 'System32\wscript.exe'
    $identity = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name

    if (-not (Test-Path -LiteralPath $bootScript)) {
        throw "Boot script not found: $bootScript"
    }

    if (-not (Test-Path -LiteralPath $launcherScript)) {
        throw "Hidden launcher not found: $launcherScript"
    }

    $arguments = "//B //Nologo `"$launcherScript`""
    $action = New-ScheduledTaskAction -Execute $wscriptExe -Argument $arguments
    $trigger = New-ScheduledTaskTrigger -AtLogOn -User $identity
    $principal = New-ScheduledTaskPrincipal -UserId $identity -LogonType Interactive -RunLevel Limited
    $settings = New-ScheduledTaskSettingsSet -Compatibility Win8 -AllowStartIfOnBatteries -StartWhenAvailable -MultipleInstances IgnoreNew

    Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Description 'Play a fullscreen login intro video before revealing the desktop.' -Force | Out-Null

    Write-Host "Registered scheduled task: $taskName"
    Write-Host "User: $identity"
}

function Invoke-UnregisterTask {
    if (Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue) {
        Unregister-ScheduledTask -TaskName $taskName -Confirm:$false
        Write-Host "Unregistered scheduled task: $taskName"
    } else {
        Write-Host "Scheduled task not found: $taskName"
    }
}

function Invoke-RegisterShell {
    $bootShellExe = Join-Path $scriptRoot 'BootShell.exe'
    if (-not (Test-Path -LiteralPath $bootShellExe)) {
        throw "BootShell.exe not found: $bootShellExe"
    }

    New-Item -Path $userWinlogonKey -Force | Out-Null

    $userShellProperty = Get-ItemProperty -LiteralPath $userWinlogonKey -Name Shell -ErrorAction SilentlyContinue
    $hadUserShell = $false
    $userShell = $null
    if ($null -ne $userShellProperty -and $null -ne $userShellProperty.PSObject.Properties['Shell']) {
        $hadUserShell = $true
        $userShell = [string]$userShellProperty.Shell
    }

    $machineShell = Get-RegistryStringValue -Path $machineWinlogonKey -Name Shell
    $task = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue

    if (-not (Test-Path -LiteralPath $shellBackupPath)) {
        $backup = [PSCustomObject]@{
            savedAt = (Get-Date).ToUniversalTime().ToString('o')
            userWinlogonKey = 'HKCU\Software\Microsoft\Windows NT\CurrentVersion\Winlogon'
            hadUserShell = $hadUserShell
            userShell = $userShell
            machineShell = $machineShell
            taskName = $taskName
            taskExisted = ($null -ne $task)
            taskState = if ($null -ne $task) { [string]$task.State } else { '' }
        }

        $backup | ConvertTo-Json | Set-Content -LiteralPath $shellBackupPath -Encoding UTF8
        Write-Host "Saved shell backup: $shellBackupPath"
    } else {
        Write-Host "Shell backup already exists: $shellBackupPath"
    }

    New-ItemProperty -LiteralPath $userWinlogonKey -Name Shell -Value $bootShellExe -PropertyType String -Force | Out-Null

    if ($null -ne $task -and [string]$task.State -ne 'Disabled') {
        Disable-ScheduledTask -TaskName $taskName | Out-Null
        Write-Host "Disabled scheduled task to avoid double intro: $taskName"
    }

    Write-Host "Registered current-user Shell:"
    Write-Host "  $bootShellExe"
    Write-Host ''
    Write-Host 'Recovery command:'
    Write-Host "  powershell.exe -NoProfile -ExecutionPolicy Bypass -File `"$scriptRoot\WallpaperBoot.ps1`" -Action RestoreShell"
}

function Invoke-RestoreShell {
    New-Item -Path $userWinlogonKey -Force | Out-Null

    $backup = $null
    if (Test-Path -LiteralPath $shellBackupPath) {
        $backup = Get-Content -LiteralPath $shellBackupPath -Raw -Encoding UTF8 | ConvertFrom-Json
    }

    if ($null -ne $backup -and [bool]$backup.hadUserShell) {
        New-ItemProperty -LiteralPath $userWinlogonKey -Name Shell -Value ([string]$backup.userShell) -PropertyType String -Force | Out-Null
        Write-Host "Restored previous current-user Shell:"
        Write-Host "  $($backup.userShell)"
    } else {
        $currentShell = Get-ItemProperty -LiteralPath $userWinlogonKey -Name Shell -ErrorAction SilentlyContinue
        if ($null -ne $currentShell -and $null -ne $currentShell.PSObject.Properties['Shell']) {
            Remove-ItemProperty -LiteralPath $userWinlogonKey -Name Shell -ErrorAction SilentlyContinue
        }

        Write-Host 'Removed current-user Shell override. Windows will use the normal machine Shell, usually explorer.exe.'
    }

    if ($null -ne $backup -and [bool]$backup.taskExisted -and [string]$backup.taskState -ne 'Disabled') {
        $task = Get-ScheduledTask -TaskName ([string]$backup.taskName) -ErrorAction SilentlyContinue
        if ($null -ne $task) {
            Enable-ScheduledTask -TaskName ([string]$backup.taskName) | Out-Null
            Write-Host "Re-enabled scheduled task: $($backup.taskName)"
        }
    }

    if (-not (Get-Process -Name 'explorer' -ErrorAction SilentlyContinue)) {
        $explorerExe = Join-Path $env:WINDIR 'explorer.exe'
        if (Test-Path -LiteralPath $explorerExe) {
            Start-Process -FilePath $explorerExe -WorkingDirectory (Split-Path -Parent $explorerExe) | Out-Null
            Write-Host 'Started explorer.exe'
        }
    }

    Write-Host 'Normal Shell restore complete.'
}

function Invoke-DisableSteamIntegration {
    $noSteamFile = Get-NoSteamFile
    $noSteamDir = Split-Path -Parent $noSteamFile

    if (-not (Test-Path -LiteralPath $noSteamDir)) {
        throw "Wallpaper Engine bin directory not found: $noSteamDir"
    }

    New-Item -ItemType File -Path $noSteamFile -Force | Out-Null
    Write-Host "Steam integration disabled: $noSteamFile"
}

function Invoke-EnableSteamIntegration {
    $noSteamFile = Get-NoSteamFile
    if (Test-Path -LiteralPath $noSteamFile) {
        Remove-Item -LiteralPath $noSteamFile -Force
        Write-Host "Steam integration restored. Removed: $noSteamFile"
    } else {
        Write-Host "Steam integration is already enabled. File not found: $noSteamFile"
    }
}

function Invoke-DisableAutostarts {
    $runKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
    $names = @('Steam', 'WallpaperEngine')
    $backup = @{}

    foreach ($name in $names) {
        $property = Get-ItemProperty -Path $runKey -Name $name -ErrorAction SilentlyContinue
        if ($null -ne $property) {
            $backup[$name] = [string]$property.$name
        }
    }

    if ($backup.Count -gt 0) {
        [PSCustomObject]$backup | ConvertTo-Json | Set-Content -LiteralPath $autostartBackupPath -Encoding UTF8
    }

    foreach ($name in $names) {
        Remove-ItemProperty -Path $runKey -Name $name -ErrorAction SilentlyContinue
    }

    Write-Host 'Disabled competing startup entries: Steam, WallpaperEngine'
    if (Test-Path -LiteralPath $autostartBackupPath) {
        Write-Host "Backup: $autostartBackupPath"
    }
}

function Invoke-RestoreAutostarts {
    $runKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'

    if (-not (Test-Path -LiteralPath $autostartBackupPath)) {
        throw "Backup not found: $autostartBackupPath"
    }

    $backup = Get-Content -LiteralPath $autostartBackupPath -Raw -Encoding UTF8 | ConvertFrom-Json

    foreach ($property in $backup.PSObject.Properties) {
        New-ItemProperty -Path $runKey -Name $property.Name -Value ([string]$property.Value) -PropertyType String -Force | Out-Null
    }

    Write-Host 'Restored competing startup entries from backup.'
}

function Invoke-RestoreDesktop {
    $wallpaperEngineExe = Get-WallpaperEngineExe

    if (-not ('BootIntro.NativeMethods' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

namespace BootIntro {
    public static class NativeMethods {
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

    function Show-WindowClass {
        param([Parameter(Mandatory = $true)][string]$ClassName)

        $current = [IntPtr]::Zero
        do {
            $current = [BootIntro.NativeMethods]::FindWindowEx([IntPtr]::Zero, $current, $ClassName, $null)
            if ($current -ne [IntPtr]::Zero) {
                [BootIntro.NativeMethods]::ShowWindow($current, 5) | Out-Null
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

    $mainTaskbar = [BootIntro.NativeMethods]::FindWindow('Shell_TrayWnd', $null)
    if ($mainTaskbar -ne [IntPtr]::Zero) {
        [BootIntro.NativeMethods]::ShowWindow($mainTaskbar, 5) | Out-Null
    }

    Show-WindowClass -ClassName 'Shell_SecondaryTrayWnd'

    $desktopIcons = Get-DesktopIconWindow
    if ($desktopIcons -ne [IntPtr]::Zero) {
        [BootIntro.NativeMethods]::ShowWindow($desktopIcons, 5) | Out-Null
    }

    if (-not [string]::IsNullOrWhiteSpace($wallpaperEngineExe) -and (Test-Path -LiteralPath $wallpaperEngineExe)) {
        Start-Process -FilePath $wallpaperEngineExe -ArgumentList @('-control', 'showIcons') -WindowStyle Hidden | Out-Null
    }

    Write-Host 'Desktop icons and taskbar restore command sent.'
}

function Get-RegistryValues {
    param([string]$Path)

    $result = @()
    $item = Get-ItemProperty -LiteralPath $Path -ErrorAction SilentlyContinue
    if ($null -eq $item) {
        return @()
    }

    foreach ($property in $item.PSObject.Properties) {
        if ($property.Name -like 'PS*') {
            continue
        }

        $result += [PSCustomObject]@{
            key = $Path
            name = $property.Name
            value = [string]$property.Value
        }
    }

    return $result
}

function Get-DefenderSnapshot {
    try {
        $pref = Get-MpPreference
        return [PSCustomObject]@{
            available = $true
            disableRealtimeMonitoring = [bool]$pref.DisableRealtimeMonitoring
            exclusionPath = @($pref.ExclusionPath | Sort-Object)
            exclusionProcess = @($pref.ExclusionProcess | Sort-Object)
            exclusionExtension = @($pref.ExclusionExtension | Sort-Object)
            exclusionIpAddress = @($pref.ExclusionIpAddress | Sort-Object)
        }
    } catch {
        return [PSCustomObject]@{
            available = $false
            error = $_.Exception.Message
        }
    }
}

function Convert-TaskActionToString {
    param([object]$Action)

    $execute = $Action.PSObject.Properties['Execute']
    if ($null -ne $execute) {
        $arguments = $Action.PSObject.Properties['Arguments']
        $argumentText = if ($null -ne $arguments) { [string]$arguments.Value } else { '' }
        return (([string]$execute.Value + ' ' + $argumentText).Trim())
    }

    $parts = @()
    foreach ($property in $Action.PSObject.Properties) {
        if ($property.Name -like 'PS*') {
            continue
        }

        $parts += ($property.Name + '=' + [string]$property.Value)
    }

    return ($parts -join '; ')
}

function Get-SystemSnapshot {
    $hostsPath = Join-Path $env:WINDIR 'System32\drivers\etc\hosts'
    $noSteamFile = ''
    try {
        $noSteamFile = Get-NoSteamFile
    } catch {
        $noSteamFile = ''
    }

    $userShell = Get-RegistryStringValue -Path $userWinlogonKey -Name Shell
    $machineShell = Get-RegistryStringValue -Path $machineWinlogonKey -Name Shell

    $runValues = @(
        Get-RegistryValues 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
        Get-RegistryValues 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run'
        Get-RegistryValues 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Run'
    ) | Sort-Object key, name

    $scheduledTasks = @(Get-ScheduledTask -ErrorAction SilentlyContinue | ForEach-Object {
        [PSCustomObject]@{
            path = $_.TaskPath
            name = $_.TaskName
            actions = @(($_.Actions | ForEach-Object { Convert-TaskActionToString $_ }) | Sort-Object)
        }
    }) | Sort-Object path, name

    $services = @(Get-CimInstance Win32_Service | ForEach-Object {
        [PSCustomObject]@{
            name = $_.Name
            displayName = $_.DisplayName
            startMode = $_.StartMode
            pathName = $_.PathName
        }
    }) | Sort-Object name

    return [PSCustomObject]@{
        schema = 'WallpaperBootSecuritySnapshot.v1'
        capturedAt = (Get-Date).ToUniversalTime().ToString('o')
        computerName = $env:COMPUTERNAME
        userName = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
        userShell = [string]$userShell
        machineShell = [string]$machineShell
        wallpaperBootIntegrityFailures = @(Test-Integrity)
        nosteamExists = (-not [string]::IsNullOrWhiteSpace($noSteamFile) -and (Test-Path -LiteralPath $noSteamFile))
        hostsSha256 = if (Test-Path -LiteralPath $hostsPath) { (Get-FileHash -LiteralPath $hostsPath -Algorithm SHA256).Hash } else { '' }
        defender = Get-DefenderSnapshot
        runValues = @($runValues)
        scheduledTasks = @($scheduledTasks)
        services = @($services)
    }
}

function ConvertTo-StableJson {
    param([Parameter(Mandatory = $true)]$Value)
    return ($Value | ConvertTo-Json -Depth 20 -Compress)
}

function Add-Change {
    param(
        [System.Collections.Generic.List[string]]$Changes,
        [string]$Message
    )

    $Changes.Add($Message)
}

function Compare-ObjectMap {
    param(
        [System.Collections.Generic.List[string]]$Changes,
        [string]$Label,
        [object[]]$Before,
        [object[]]$After,
        [scriptblock]$Key
    )

    $beforeMap = @{}
    foreach ($item in @($Before)) {
        $beforeMap[(& $Key $item)] = ConvertTo-StableJson $item
    }

    $afterMap = @{}
    foreach ($item in @($After)) {
        $afterMap[(& $Key $item)] = ConvertTo-StableJson $item
    }

    foreach ($name in ($beforeMap.Keys | Sort-Object)) {
        if (-not $afterMap.ContainsKey($name)) {
            Add-Change $Changes "$Label removed: $name"
        } elseif ($beforeMap[$name] -ne $afterMap[$name]) {
            Add-Change $Changes "$Label changed: $name"
        }
    }

    foreach ($name in ($afterMap.Keys | Sort-Object)) {
        if (-not $beforeMap.ContainsKey($name)) {
            Add-Change $Changes "$Label added: $name"
        }
    }
}

function Invoke-Snapshot {
    $snapshot = Get-SystemSnapshot
    $snapshot | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $SnapshotPath -Encoding UTF8
    Write-Host "Security snapshot saved: $SnapshotPath"
    Write-Host "WallpaperBoot integrity failures: $(@($snapshot.wallpaperBootIntegrityFailures).Count)"
}

function Invoke-Compare {
    if (-not (Test-Path -LiteralPath $SnapshotPath -PathType Leaf)) {
        throw "Snapshot not found: $SnapshotPath"
    }

    $before = Get-Content -LiteralPath $SnapshotPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $after = Get-SystemSnapshot
    $changes = New-Object System.Collections.Generic.List[string]

    if ([string]$before.userShell -ne [string]$after.userShell) {
        Add-Change $changes "User Shell changed: '$($before.userShell)' -> '$($after.userShell)'"
    }

    if ([string]$before.machineShell -ne [string]$after.machineShell) {
        Add-Change $changes "Machine Shell changed: '$($before.machineShell)' -> '$($after.machineShell)'"
    }

    if ([bool]$before.nosteamExists -ne [bool]$after.nosteamExists) {
        Add-Change $changes "nosteam.txt presence changed: '$($before.nosteamExists)' -> '$($after.nosteamExists)'"
    }

    if ([string]$before.hostsSha256 -ne [string]$after.hostsSha256) {
        Add-Change $changes 'hosts file hash changed.'
    }

    if ((ConvertTo-StableJson $before.defender) -ne (ConvertTo-StableJson $after.defender)) {
        Add-Change $changes 'Windows Defender preference/exclusion changed.'
    }

    foreach ($failure in @($after.wallpaperBootIntegrityFailures)) {
        Add-Change $changes "WallpaperBoot integrity failure: $failure"
    }

    Compare-ObjectMap $changes 'Run entry' @($before.runValues) @($after.runValues) { param($x) "$($x.key)\$($x.name)" }
    Compare-ObjectMap $changes 'Scheduled task' @($before.scheduledTasks) @($after.scheduledTasks) { param($x) "$($x.path)$($x.name)" }
    Compare-ObjectMap $changes 'Service' @($before.services) @($after.services) { param($x) "$($x.name)" }

    if ($changes.Count -gt 0) {
        Write-Host 'Security compare FOUND CHANGES.'
        foreach ($change in $changes) {
            Write-Host "  $change"
        }

        exit 1
    }

    Write-Host 'Security compare OK. No watched changes found.'
}

function Invoke-Status {
    $userShell = Get-RegistryStringValue -Path $userWinlogonKey -Name Shell
    $machineShell = Get-RegistryStringValue -Path $machineWinlogonKey -Name Shell
    $task = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
    $wallpaperEngineExe = Get-WallpaperEngineExe
    $noSteamFile = ''
    try {
        $noSteamFile = Get-NoSteamFile
    } catch {
        $noSteamFile = ''
    }

    [PSCustomObject]@{
        UserShell = [string]$userShell
        MachineShell = [string]$machineShell
        LoginTaskState = if ($null -ne $task) { [string]$task.State } else { 'NotRegistered' }
        WallpaperEngineExe = $wallpaperEngineExe
        NoSteamFile = $noSteamFile
        NoSteamExists = (-not [string]::IsNullOrWhiteSpace($noSteamFile) -and (Test-Path -LiteralPath $noSteamFile))
        WallpaperEngineRunning = [bool](Get-Process -Name 'wallpaper64', 'wallpaper32' -ErrorAction SilentlyContinue)
    } | Format-List
}

switch ($Action) {
    'Status' { Invoke-Status }
    'Build' { Invoke-Build }
    'RegisterTask' { Invoke-RegisterTask }
    'UnregisterTask' { Invoke-UnregisterTask }
    'RegisterShell' { Invoke-RegisterShell }
    'RestoreShell' { Invoke-RestoreShell }
    'DisableSteamIntegration' { Invoke-DisableSteamIntegration }
    'EnableSteamIntegration' { Invoke-EnableSteamIntegration }
    'DisableAutostarts' { Invoke-DisableAutostarts }
    'RestoreAutostarts' { Invoke-RestoreAutostarts }
    'RestoreDesktop' { Invoke-RestoreDesktop }
    'Protect' { Invoke-Protect }
    'Unprotect' { Invoke-Unprotect }
    'Check' { Invoke-Check }
    'Snapshot' { Invoke-Snapshot }
    'Compare' { Invoke-Compare }
}
