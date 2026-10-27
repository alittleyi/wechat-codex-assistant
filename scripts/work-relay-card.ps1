[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$Goal,

    [Parameter(Mandatory = $false)]
    [string]$ProjectPath,

    [Parameter(Mandatory = $false)]
    [ValidateRange(3, 20)]
    [int]$MaxRecentFiles = 10,

    [Parameter(Mandatory = $false)]
    [ValidateRange(1, 8)]
    [int]$MaxChats = 3,

    [Parameter(Mandatory = $false)]
    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'
$agentRoot = Split-Path -Parent $PSScriptRoot
$defaultProjectRoot = Split-Path -Parent (Split-Path -Parent $agentRoot)
$project = if ([string]::IsNullOrWhiteSpace($ProjectPath)) { $defaultProjectRoot } else { $ProjectPath }
$projectItem = Get-Item -LiteralPath $project -Force -ErrorAction Stop
if (-not $projectItem.PSIsContainer) { throw 'ProjectPath must be a directory.' }

$projectFull = [System.IO.Path]::GetFullPath($projectItem.FullName).TrimEnd('\')
$allowedRoot = [System.IO.Path]::GetFullPath((Join-Path $env:USERPROFILE 'Documents\Codex')).TrimEnd('\')
$comparison=[System.StringComparison]::OrdinalIgnoreCase
$driveRoot=[System.IO.Path]::GetPathRoot($projectFull).TrimEnd('\')
$broadRoots=@(
    $driveRoot,
    [System.IO.Path]::GetFullPath($env:USERPROFILE).TrimEnd('\'),
    [System.IO.Path]::GetFullPath((Join-Path $env:USERPROFILE 'Desktop')).TrimEnd('\'),
    [System.IO.Path]::GetFullPath((Join-Path $env:USERPROFILE 'Documents')).TrimEnd('\'),
    [System.IO.Path]::GetFullPath((Join-Path $env:USERPROFILE 'Downloads')).TrimEnd('\')
)
if(@($broadRoots|Where-Object {$projectFull.Equals($_,$comparison)}).Count -gt 0){
    throw 'ProjectPath must identify a concrete project folder, not a drive or broad user folder.'
}
$forbiddenRoots=@(
    $env:WINDIR,$env:ProgramFiles,${env:ProgramFiles(x86)},$env:ProgramData,
    $env:APPDATA,$env:LOCALAPPDATA,
    (Join-Path $env:USERPROFILE '.openclaw'),(Join-Path $env:USERPROFILE '.codex')
)|Where-Object {-not[string]::IsNullOrWhiteSpace($_)}|ForEach-Object {[IO.Path]::GetFullPath($_).TrimEnd('\')}
if(@($forbiddenRoots|Where-Object {$projectFull.Equals($_,$comparison)-or$projectFull.StartsWith($_+'\',$comparison)}).Count -gt 0){
    throw 'ProjectPath cannot point to a system, application-data, or authentication directory.'
}

$current = $projectItem
while ($current) {
    if ($current.LinkType -or (($current.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0)) {
        throw 'Linked project directories are not allowed.'
    }
    if ($current.FullName.TrimEnd('\').Equals($driveRoot,$comparison)) { break }
    $parent = Split-Path -Parent $current.FullName
    if ([string]::IsNullOrWhiteSpace($parent) -or $parent -eq $current.FullName) { break }
    $current = Get-Item -LiteralPath $parent -Force -ErrorAction Stop
}

function Protect-Text {
    param([string]$Text,[int]$Limit = 140)
    if ([string]::IsNullOrWhiteSpace($Text)) { return '' }
    $value = ($Text -replace '\s+',' ').Trim()
    $value = $value -replace '(?i)(password|passwd|secret|token|cookie|api[_-]?key)\s*[:=]\s*\S+','$1=[已隐藏]'
    $value = $value -replace '(?<!\d)1[3-9]\d{9}(?!\d)','[手机号已隐藏]'
    $value = $value -replace '(?<!\d)\d{17}[\dXx](?!\d)','[身份证号已隐藏]'
    $value = $value -replace '[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}','[邮箱已隐藏]'
    if ($value.Length -gt $Limit) { $value = $value.Substring(0,$Limit) + '…' }
    return $value
}

$excluded = '(?i)\\(\.git|\.openclaw|\.codex|node_modules|backups|inbox|outbox|tmp|media|missions)(\\|$)'
$recentFiles = @(Get-ChildItem -LiteralPath $projectFull -File -Recurse -Depth 5 -Force -ErrorAction SilentlyContinue |
    Where-Object { $_.FullName -notmatch $excluded } |
    Select-Object -First 5000 |
    Sort-Object LastWriteTime -Descending |
    Select-Object -First $MaxRecentFiles)

$chatRows = @()
try {
    $chatIndex = (& (Join-Path $PSScriptRoot 'list-recent-codex-chats.ps1') -Limit 20 -ScanLimit 300) | ConvertFrom-Json
    $chatRows = @($chatIndex.chats |
        Where-Object {
            $chatProject = [System.IO.Path]::GetFullPath([string]$_.projectPath).TrimEnd('\')
            $chatProject.Equals($projectFull,[System.StringComparison]::OrdinalIgnoreCase) -or
            $chatProject.StartsWith($projectFull + '\',[System.StringComparison]::OrdinalIgnoreCase)
        } |
        Select-Object -First $MaxChats)
} catch {
    $chatRows = @()
}

$missionRows = @()
$missionsRoot = Join-Path $agentRoot 'missions'
if (Test-Path -LiteralPath $missionsRoot) {
    foreach ($manifestFile in Get-ChildItem -LiteralPath $missionsRoot -File -Recurse -Filter 'mission.json' -ErrorAction SilentlyContinue) {
        try {
            $mission = Get-Content -LiteralPath $manifestFile.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
            if ($mission.state -in @('active','paused')) {
                $missionRows += [pscustomobject]@{
                    name = Protect-Text -Text ([string]$mission.name) -Limit 80
                    state = [string]$mission.state
                    updatedAt = [string]$mission.updatedAt
                    checkpoint = Protect-Text -Text ([string]$mission.lastCheckpoint) -Limit 140
                }
            }
        } catch { continue }
    }
}

$snapshot = (& (Join-Path $PSScriptRoot 'system-snapshot.ps1')) | ConvertFrom-Json
$lines = [System.Collections.Generic.List[string]]::new()
$lines.Add('# 工作接力卡')
$lines.Add('')
$lines.Add('生成时间：' + (Get-Date).ToString('yyyy-MM-dd HH:mm:ss'))
$lines.Add('')
$lines.Add('## 现在要继续的目标')
$lines.Add('')
$lines.Add((Protect-Text -Text $Goal -Limit 1000))
$lines.Add('')
$lines.Add('## 电脑是否适合继续工作')
$lines.Add('')
$lines.Add(('- Gateway：{0}；启动持久化：{1}' -f $(if($snapshot.gateway.runtimeHealthy){'在线'}else{'异常'}),$snapshot.gateway.startupPersistence))
$lines.Add(('- 内存可用：{0} GiB；系统盘可用：{1} GiB' -f $snapshot.memory.freeGiB,$snapshot.systemDisk.freeGiB))
$lines.Add('')
$lines.Add('## 最近工作文件')
$lines.Add('')
if ($recentFiles.Count -eq 0) {
    $lines.Add('- 未发现可列出的最近文件。')
} else {
    $rank = 0
    foreach ($file in $recentFiles) {
        $rank++
        $relative = $file.FullName.Substring($projectFull.Length).TrimStart('\')
        $lines.Add(('- {0}. `{1}` — {2}，{3} KiB' -f $rank,(Protect-Text -Text $relative -Limit 180),$file.LastWriteTime.ToString('MM-dd HH:mm'),[math]::Round($file.Length/1KB,1)))
    }
}
$lines.Add('')
$lines.Add('## 最近电脑端工作线索')
$lines.Add('')
if ($chatRows.Count -eq 0) {
    $lines.Add('- 没有匹配到该项目的最近 Codex Desktop 会话。')
} else {
    foreach ($chat in $chatRows) {
        $prompt = Protect-Text -Text ([string]$chat.prompt) -Limit 180
        $lines.Add(('- {0}：{1}' -f $chat.modified,$(if($prompt){$prompt}else{'[无可显示摘要]'})))
    }
}
$lines.Add('')
$lines.Add('## 未完成的任务胶囊')
$lines.Add('')
if ($missionRows.Count -eq 0) {
    $lines.Add('- 当前没有进行中或暂停中的任务。')
} else {
    foreach ($mission in $missionRows) {
        $detail = if ($mission.checkpoint) { '；最近里程碑：' + $mission.checkpoint } else { '' }
        $lines.Add(('- {0}（{1}）{2}' -f $mission.name,$mission.state,$detail))
    }
}
$lines.Add('')
$lines.Add('## 手机上下一步可以直接说')
$lines.Add('')
$lines.Add('- `继续这个目标，做到可预览版本再通知我。`')
$lines.Add('- `先告诉我最大的卡点和两个选择。`')
$lines.Add('- `把最近工作文件中的第 N 个发给我。`')
$lines.Add('- `暂停当前任务，保留进度。`')

$card = $lines -join [Environment]::NewLine
if ($DryRun) {
    [ordered]@{
        status = 'dry-run'
        recentFileCount = $recentFiles.Count
        recentChatCount = $chatRows.Count
        openMissionCount = $missionRows.Count
        gatewayHealthy = [bool]$snapshot.gateway.runtimeHealthy
        preview = Protect-Text -Text $card -Limit 500
    } | ConvertTo-Json -Depth 5
    return
}

$internalOutput = Join-Path $agentRoot 'outputs'
New-Item -ItemType Directory -Path $internalOutput -Force | Out-Null
$sourcePath = Join-Path $internalOutput ('工作接力卡-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.md')
[System.IO.File]::WriteAllText($sourcePath,$card,[System.Text.UTF8Encoding]::new($false))
$prepared = (& (Join-Path $PSScriptRoot 'prepare-outbound.ps1') -SourcePath $sourcePath) | ConvertFrom-Json

[ordered]@{
    status = 'prepared'
    recentFileCount = $recentFiles.Count
    recentChatCount = $chatRows.Count
    openMissionCount = $missionRows.Count
    gatewayHealthy = [bool]$snapshot.gateway.runtimeHealthy
    sourcePath = $sourcePath
    outboundPath = $prepared.outboundPath
    sha256 = $prepared.sha256
    integrityVerified = $prepared.integrityVerified
} | ConvertTo-Json -Depth 5
