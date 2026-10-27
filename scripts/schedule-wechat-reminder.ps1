[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateLength(1,500)]
    [string]$Message,

    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[1-9][0-9]*[mhd]$')]
    [string]$At,

    [Parameter(Mandatory = $false)]
    [ValidatePattern('^[A-Za-z0-9_-]{1,48}$')]
    [string]$Name = 'wechat-one-shot-reminder',

    [Parameter(Mandatory = $false)]
    [string]$AttachmentPath,

    [Parameter(Mandatory = $false)]
    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'
$amount = [int]$At.Substring(0,$At.Length - 1)
$unit = $At.Substring($At.Length - 1)
$minutes = switch ($unit) { 'm' {$amount} 'h' {$amount * 60} 'd' {$amount * 1440} }
if ($minutes -lt 1 -or $minutes -gt 43200) { throw 'Reminder must be between 1 minute and 30 days.' }

$weixinRoot = Join-Path $env:USERPROFILE '.openclaw\openclaw-weixin'
$account = [string](Get-Content -LiteralPath (Join-Path $weixinRoot 'accounts.json') -Raw | ConvertFrom-Json)
if ([string]::IsNullOrWhiteSpace($account)) { throw 'No active WeChat account was found.' }

$tokenFiles = @(Get-ChildItem -LiteralPath (Join-Path $weixinRoot 'accounts') -Filter '*.context-tokens.json' -File)
$targets = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
foreach ($file in $tokenFiles) {
    $map = Get-Content -LiteralPath $file.FullName -Raw | ConvertFrom-Json
    foreach ($key in $map.PSObject.Properties.Name) {
        if ($key.EndsWith('@im.wechat',[System.StringComparison]::Ordinal)) { [void]$targets.Add($key) }
    }
}
if ($targets.Count -ne 1) { throw "Expected exactly one active WeChat private target; found $($targets.Count)." }
$target = @($targets)[0]

if ($DryRun) {
    if ($AttachmentPath -and -not (Test-Path -LiteralPath $AttachmentPath -PathType Leaf)) { throw 'Attachment does not exist.' }
    [pscustomobject]@{ status='validated'; schedule=$At; name=$Name; targetCount=1; messageLength=$Message.Length; hasAttachment=[bool]$AttachmentPath } | ConvertTo-Json
    exit 0
}

$preparedPath = $null
if ($AttachmentPath) {
    $prepared = (& (Join-Path $PSScriptRoot 'prepare-outbound.ps1') -SourcePath $AttachmentPath) | ConvertFrom-Json
    $preparedPath = $prepared.outboundPath
    $prompt = "只输出两行，不调用工具。第一行：$Message。第二行：MEDIA:$preparedPath"
} else {
    $prompt = "只回复以下提醒正文，不调用工具，不添加前后缀：$Message"
}

$openclawCmd = Join-Path $env:APPDATA 'npm\openclaw.cmd'
if (-not (Test-Path -LiteralPath $openclawCmd -PathType Leaf)) { throw 'OpenClaw CLI was not found.' }
$raw = & $openclawCmd cron add --name $Name --description 'One-shot reminder created by the local WeChat assistant.' --at $At --agent main --session isolated --message $prompt '--tools=' --thinking off --timeout-seconds 90 --announce --channel openclaw-weixin --to $target --account $account --delete-after-run --json --timeout 20000
if ($LASTEXITCODE -ne 0) { throw "Failed to create reminder, exit code: $LASTEXITCODE" }
$job = $raw | ConvertFrom-Json
[pscustomobject]@{
    status = 'scheduled'
    id = $job.id
    name = $job.name
    schedule = $At
    hasAttachment = [bool]$preparedPath
    deleteAfterSuccessfulRun = $true
} | ConvertTo-Json
