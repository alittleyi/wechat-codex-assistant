[CmdletBinding()]
param([string]$WorkspacePath)

$ErrorActionPreference='Stop'
$sourceRoot=Split-Path -Parent $PSScriptRoot
if([string]::IsNullOrWhiteSpace($WorkspacePath)){$WorkspacePath=$sourceRoot}
$workspace=[IO.Path]::GetFullPath($WorkspacePath)
New-Item -ItemType Directory -Path $workspace -Force|Out-Null

$template=Join-Path $sourceRoot 'AGENTS.example.md'
$agents=Join-Path $workspace 'AGENTS.md'
if(-not(Test-Path -LiteralPath $template -PathType Leaf)){throw 'AGENTS.example.md is missing.'}
$createdAgents=$false
if(-not(Test-Path -LiteralPath $agents)){
    Copy-Item -LiteralPath $template -Destination $agents
    $createdAgents=$true
}

$created=@()
foreach($name in @('inbox','outbox','tasks','receipts')){
    $path=Join-Path $workspace $name
    if(-not(Test-Path -LiteralPath $path)){New-Item -ItemType Directory -Path $path|Out-Null;$created+=$name}
}
[ordered]@{status='ok';agentsCreated=$createdAgents;directoriesCreated=$created;credentialsWritten=$false;next='Run scripts/preflight.ps1, then configure channels with the official OpenClaw flow.'}|ConvertTo-Json
