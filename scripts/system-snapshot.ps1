[CmdletBinding()]
param()

$ErrorActionPreference = 'SilentlyContinue'

$uptimeHours = [math]::Round(
    [System.Diagnostics.Stopwatch]::GetTimestamp() /
    [System.Diagnostics.Stopwatch]::Frequency / 3600,
    1
)

Add-Type -AssemblyName Microsoft.VisualBasic
$computerInfo = [Microsoft.VisualBasic.Devices.ComputerInfo]::new()
$systemDriveName = if ($env:SystemDrive) { "$($env:SystemDrive)\" } else { 'C:\' }
$systemDrive = [System.IO.DriveInfo]::GetDrives() |
    Where-Object { $_.Name -eq $systemDriveName } |
    Select-Object -First 1

$battery = $null
Add-Type -AssemblyName System.Windows.Forms
$power = [System.Windows.Forms.SystemInformation]::PowerStatus
if ($power -and $power.BatteryLifePercent -ge 0 -and $power.BatteryChargeStatus -ne 'NoSystemBattery') {
    $battery = [ordered]@{
        percent = [math]::Round($power.BatteryLifePercent * 100)
        status  = [string]$power.BatteryChargeStatus
    }
}

$gatewayListening = $false
$client = New-Object System.Net.Sockets.TcpClient
try {
    $attempt = $client.BeginConnect('127.0.0.1',18789,$null,$null)
    if ($attempt.AsyncWaitHandle.WaitOne(500)) {
        $client.EndConnect($attempt)
        $gatewayListening = $client.Connected
    }
} finally {
    $client.Close()
}

$gatewayTask = $null
$gatewayTaskState = 'unverified'
try {
    $gatewayTask = Get-ScheduledTask -TaskName 'OpenClaw Gateway' -ErrorAction Stop |
        Select-Object -First 1
    if ($gatewayTask) { $gatewayTaskState = [string]$gatewayTask.State }
} catch {
    # A non-elevated process may be unable to see a task that exists. Do not
    # report it as missing unless an elevated probe has proved absence.
    $gatewayTaskState = 'unverified'
}

$gatewayPid = $null
$gatewayProcess = $null
if ($gatewayListening) {
    $netstatLine = netstat.exe -ano -p tcp 2>$null |
        Select-String -Pattern '^\s*TCP\s+127\.0\.0\.1:18789\s+\S+\s+LISTENING\s+(\d+)\s*$' |
        Select-Object -First 1
    if ($netstatLine -and $netstatLine.Matches.Count -gt 0) {
        $gatewayPid = [int]$netstatLine.Matches[0].Groups[1].Value
        $gatewayProcess = Get-Process -Id $gatewayPid -ErrorAction SilentlyContinue
    }
}

[ordered]@{
    timestamp = (Get-Date).ToString('o')
    uptimeHours = $uptimeHours
    memory = [ordered]@{
        totalGiB = [math]::Round($computerInfo.TotalPhysicalMemory / 1GB, 1)
        freeGiB  = [math]::Round($computerInfo.AvailablePhysicalMemory / 1GB, 1)
    }
    systemDisk = [ordered]@{
        drive    = $systemDriveName.TrimEnd('\')
        totalGiB = if ($systemDrive) { [math]::Round($systemDrive.TotalSize / 1GB, 1) } else { $null }
        freeGiB  = if ($systemDrive) { [math]::Round($systemDrive.AvailableFreeSpace / 1GB, 1) } else { $null }
    }
    battery = $battery
    gateway = [ordered]@{
        listeningLocal = $gatewayListening
        taskState      = $gatewayTaskState
        processId      = $gatewayPid
        processName    = if ($gatewayProcess) { [string]$gatewayProcess.ProcessName } else { $null }
        runtimeHealthy = [bool]$gatewayListening
        startupPersistence = if ($gatewayTaskState -eq 'Running') { 'scheduled-task-running' } else { 'unverified' }
    }
} | ConvertTo-Json -Depth 5
