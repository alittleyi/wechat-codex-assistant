[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$workspace = Split-Path -Parent $PSScriptRoot
$results = [System.Collections.Generic.List[object]]::new()

function Add-Result([string]$Name,[bool]$Passed,[string]$Detail) {
    $results.Add([pscustomobject]@{ name=$Name; passed=$Passed; detail=$Detail })
}

try {
    $snapshot = (& (Join-Path $PSScriptRoot 'system-snapshot.ps1')) | ConvertFrom-Json
    Add-Result 'gateway-runtime' ([bool]$snapshot.gateway.runtimeHealthy) "listening=$($snapshot.gateway.listeningLocal), process=$($snapshot.gateway.processName), pid=$($snapshot.gateway.processId)"
    Add-Result 'gateway-startup-persistence' ($snapshot.gateway.startupPersistence -eq 'scheduled-task-running') "task=$($snapshot.gateway.taskState), persistence=$($snapshot.gateway.startupPersistence)"
} catch {
    Add-Result 'gateway-runtime' $false $_.Exception.Message
    Add-Result 'gateway-startup-persistence' $false $_.Exception.Message
}

try {
    $doc = (& (Join-Path $PSScriptRoot 'inspect-document.ps1') -Path (Join-Path $workspace 'RUNBOOK.md')) | ConvertFrom-Json
    Add-Result 'document-inspection' ($doc.extension -eq '.md' -and $doc.characters_extracted -gt 100) "chars=$($doc.characters_extracted)"
} catch { Add-Result 'document-inspection' $false $_.Exception.Message }

try {
    $fixture = Join-Path $workspace 'media-fixtures\synthetic-sensitive-fixture.md'
    $privacy = (& (Join-Path $PSScriptRoot 'inspect-document.ps1') -Path $fixture) | ConvertFrom-Json
    $hidden = -not [string]::IsNullOrWhiteSpace([string]$privacy.preview_redacted) -and $privacy.preview_redacted -notmatch '13800138000|110101199001011234|6222020000000000000'
    Add-Result 'document-sensitive-redaction' ($privacy.sensitive_patterns_detected.Count -eq 4 -and $hidden) "patterns=$($privacy.sensitive_patterns_detected.Count), previewHidden=$hidden"
} catch { Add-Result 'document-sensitive-redaction' $false $_.Exception.Message }

try {
    $fixture = Join-Path $workspace 'media-fixtures\synthetic-financial-fixture.md'
    $privacy = (& (Join-Path $PSScriptRoot 'inspect-document.ps1') -Path $fixture) | ConvertFrom-Json
    $labels = @($privacy.sensitive_patterns_detected)
    $expected = @('长交易识别号','微信号','中文姓名字段','财务凭证字段')
    $allDetected = @($expected | Where-Object { $_ -notin $labels }).Count -eq 0
    $hidden = [string]$privacy.preview_redacted -eq '检测到敏感字段，预览已整体隐藏；仅供本机授权处理。'
    Add-Result 'document-financial-redaction' ($allDetected -and $hidden) "patterns=$($labels.Count), previewHidden=$hidden"
} catch { Add-Result 'document-financial-redaction' $false $_.Exception.Message }

try {
    $fixture = Join-Path $workspace 'media-fixtures\invalid-document.pdf'
    $rejected = $false
    try { & (Join-Path $PSScriptRoot 'inspect-document.ps1') -Path $fixture *> $null } catch { $rejected = $true }
    Add-Result 'document-corruption-guard' ($rejected -and (Test-Path -LiteralPath $fixture)) $(if ($rejected) {'rejected; source preserved'} else {'unexpectedly accepted'})
} catch { Add-Result 'document-corruption-guard' $false $_.Exception.Message }

try {
    $fixture = Join-Path $workspace 'media-fixtures\boundary-test.mp4'
    $media = (& (Join-Path $PSScriptRoot 'media-probe.ps1') -SourcePath $fixture) | ConvertFrom-Json
    Add-Result 'media-probe' ($media.duration -eq 2 -and $media.video.codec -eq 'h264') "duration=$($media.duration), codec=$($media.video.codec)"
} catch { Add-Result 'media-probe' $false $_.Exception.Message }

try {
    $index = (& (Join-Path $PSScriptRoot 'list-recent-codex-chats.ps1') -Limit 3 -ScanLimit 100) | ConvertFrom-Json
    Add-Result 'codex-desktop-chat-index' ($index.status -eq 'ok' -and $index.count -gt 0) "desktopChats=$($index.count)"
} catch { Add-Result 'codex-desktop-chat-index' $false $_.Exception.Message }

try {
    $files = (& (Join-Path $PSScriptRoot 'safe-file-index.ps1') -Query '*' -Roots @($workspace) -MaxResults 3) | ConvertFrom-Json
    Add-Result 'file-index-bounded-results' ($files.resultCount -eq 3 -and $files.truncated) "count=$($files.resultCount), truncated=$($files.truncated)"
} catch { Add-Result 'file-index-bounded-results' $false $_.Exception.Message }

try {
    $receiptId = 'wechat-agent-self-test-idempotency-v1'
    $first = (& (Join-Path $PSScriptRoot 'job-receipt.ps1') -Action start -RequestId $receiptId -Description 'self-test') | ConvertFrom-Json
    if ($first.status -eq 'running') {
        & (Join-Path $PSScriptRoot 'job-receipt.ps1') -Action complete -RequestId $receiptId -Description 'self-test complete' | Out-Null
    }
    $second = (& (Join-Path $PSScriptRoot 'job-receipt.ps1') -Action start -RequestId $receiptId -Description 'self-test duplicate') | ConvertFrom-Json
    Add-Result 'job-receipt-idempotency' ($second.status -eq 'duplicate_completed') "secondStart=$($second.status)"
} catch { Add-Result 'job-receipt-idempotency' $false $_.Exception.Message }

try {
    $sensitive = Join-Path $env:USERPROFILE '.openclaw\openclaw.json'
    $rejected = $false
    try { & (Join-Path $PSScriptRoot 'prepare-outbound.ps1') -SourcePath $sensitive | Out-Null } catch { $rejected = $true }
    Add-Result 'outbound-secret-guard' $rejected $(if ($rejected) {'rejected'} else {'unexpectedly accepted'})
} catch { Add-Result 'outbound-secret-guard' $false $_.Exception.Message }

try {
    $dangerous = Join-Path $env:TEMP ("openclaw-self-test-{0}.cmd" -f [guid]::NewGuid().ToString('N'))
    [System.IO.File]::WriteAllText($dangerous,'echo harmless self-test',[System.Text.Encoding]::ASCII)
    $rejected = $false
    try { & (Join-Path $PSScriptRoot 'ingest-inbound.ps1') -SourcePath $dangerous | Out-Null } catch { $rejected = $true }
    Add-Result 'inbound-dangerous-type-guard' $rejected $(if ($rejected) {'rejected'} else {'unexpectedly accepted'})
} catch { Add-Result 'inbound-dangerous-type-guard' $false $_.Exception.Message }
finally { if ($dangerous -and [System.IO.File]::Exists($dangerous)) { [System.IO.File]::Delete($dangerous) } }

try {
    $oversize = Join-Path $env:TEMP ("openclaw-self-test-{0}.bin" -f [guid]::NewGuid().ToString('N'))
    $stream = [System.IO.File]::Open($oversize,[System.IO.FileMode]::CreateNew)
    try { $stream.SetLength(26MB) } finally { $stream.Dispose() }
    $rejected = $false
    try { & (Join-Path $PSScriptRoot 'prepare-outbound.ps1') -SourcePath $oversize | Out-Null } catch { $rejected = $true }
    Add-Result 'outbound-size-guard' $rejected $(if ($rejected) {'rejected'} else {'unexpectedly accepted'})
} catch { Add-Result 'outbound-size-guard' $false $_.Exception.Message }
finally { if ($oversize -and [System.IO.File]::Exists($oversize)) { [System.IO.File]::Delete($oversize) } }

try {
    $linkSource = Join-Path $env:TEMP ("openclaw-self-test-{0}.txt" -f [guid]::NewGuid().ToString('N'))
    $linkPath = Join-Path $workspace ("media-fixtures\hardlink-{0}.txt" -f [guid]::NewGuid().ToString('N'))
    [System.IO.File]::WriteAllText($linkSource,'harmless hardlink fixture',[System.Text.Encoding]::ASCII)
    New-Item -ItemType HardLink -Path $linkPath -Target $linkSource | Out-Null
    $outboundRejected = $false
    $bundleRejected = $false
    $inboundRejected = $false
    try { & (Join-Path $PSScriptRoot 'prepare-outbound.ps1') -SourcePath $linkPath | Out-Null } catch { $outboundRejected = $true }
    try { & (Join-Path $PSScriptRoot 'prepare-bundle.ps1') -SourcePaths @($linkPath) -BundleName 'hardlink-guard.zip' | Out-Null } catch { $bundleRejected = $true }
    try { & (Join-Path $PSScriptRoot 'ingest-inbound.ps1') -SourcePath $linkPath | Out-Null } catch { $inboundRejected = $true }
    Add-Result 'linked-file-guards' ($outboundRejected -and $bundleRejected -and $inboundRejected) "outbound=$outboundRejected, bundle=$bundleRejected, inbound=$inboundRejected"
} catch { Add-Result 'linked-file-guards' $false $_.Exception.Message }
finally {
    if ($linkPath -and [System.IO.File]::Exists($linkPath)) { [System.IO.File]::Delete($linkPath) }
    if ($linkSource -and [System.IO.File]::Exists($linkSource)) { [System.IO.File]::Delete($linkSource) }
}

try {
    $junctionTarget = Join-Path $env:TEMP ("openclaw-self-test-{0}" -f [guid]::NewGuid().ToString('N'))
    $junctionPath = Join-Path $workspace ("media-fixtures\junction-{0}" -f [guid]::NewGuid().ToString('N'))
    [System.IO.Directory]::CreateDirectory($junctionTarget) | Out-Null
    $junctionTargetFile = Join-Path $junctionTarget 'fixture.txt'
    [System.IO.File]::WriteAllText($junctionTargetFile,'harmless junction fixture',[System.Text.Encoding]::ASCII)
    New-Item -ItemType Junction -Path $junctionPath -Target $junctionTarget | Out-Null
    $junctionFile = Join-Path $junctionPath 'fixture.txt'
    $outboundRejected = $false
    $bundleRejected = $false
    $inboundRejected = $false
    try { & (Join-Path $PSScriptRoot 'prepare-outbound.ps1') -SourcePath $junctionFile | Out-Null } catch { $outboundRejected = $true }
    try { & (Join-Path $PSScriptRoot 'prepare-bundle.ps1') -SourcePaths @($junctionFile) -BundleName 'junction-guard.zip' | Out-Null } catch { $bundleRejected = $true }
    try { & (Join-Path $PSScriptRoot 'ingest-inbound.ps1') -SourcePath $junctionFile | Out-Null } catch { $inboundRejected = $true }
    Add-Result 'linked-directory-guards' ($outboundRejected -and $bundleRejected -and $inboundRejected) "outbound=$outboundRejected, bundle=$bundleRejected, inbound=$inboundRejected"
} catch { Add-Result 'linked-directory-guards' $false $_.Exception.Message }
finally {
    if ($junctionPath -and [System.IO.Directory]::Exists($junctionPath)) { [System.IO.Directory]::Delete($junctionPath) }
    if ($junctionTargetFile -and [System.IO.File]::Exists($junctionTargetFile)) { [System.IO.File]::Delete($junctionTargetFile) }
    if ($junctionTarget -and [System.IO.Directory]::Exists($junctionTarget)) { [System.IO.Directory]::Delete($junctionTarget) }
}

try {
    $rejected = $false
    try { & (Join-Path $PSScriptRoot 'ingest-browser-export.ps1') -SourcePath (Join-Path $workspace 'RUNBOOK.md') | Out-Null } catch { $rejected = $true }
    Add-Result 'browser-export-source-guard' $rejected $(if ($rejected) {'rejected'} else {'unexpectedly accepted'})
} catch { Add-Result 'browser-export-source-guard' $false $_.Exception.Message }

try {
    $integritySource = Join-Path $workspace ("media-fixtures\integrity-{0}.txt" -f [guid]::NewGuid().ToString('N'))
    [System.IO.File]::WriteAllText($integritySource,'copy integrity fixture',[System.Text.Encoding]::ASCII)
    $expected = (Get-FileHash -LiteralPath $integritySource -Algorithm SHA256).Hash
    $outbound = (& (Join-Path $PSScriptRoot 'prepare-outbound.ps1') -SourcePath $integritySource) | ConvertFrom-Json
    $inbound = (& (Join-Path $PSScriptRoot 'ingest-inbound.ps1') -SourcePath $integritySource) | ConvertFrom-Json
    $bundle = (& (Join-Path $PSScriptRoot 'prepare-bundle.ps1') -SourcePaths @($integritySource) -BundleName ("integrity-{0}.zip" -f [guid]::NewGuid().ToString('N'))) | ConvertFrom-Json
    $passed = $outbound.integrityVerified -and $inbound.integrityVerified -and $bundle.integrityVerified -and $outbound.sha256 -eq $expected -and $inbound.sha256 -eq $expected
    Add-Result 'copy-and-bundle-integrity' $passed "outbound=$($outbound.integrityVerified), inbound=$($inbound.integrityVerified), bundle=$($bundle.integrityVerified)"
} catch { Add-Result 'copy-and-bundle-integrity' $false $_.Exception.Message }
finally {
    foreach ($candidate in @($integritySource,$outbound.outboundPath,$inbound.savedPath,$bundle.bundlePath)) {
        if ($candidate -and [System.IO.File]::Exists([string]$candidate)) { [System.IO.File]::Delete([string]$candidate) }
    }
}

try {
    $mission = (& (Join-Path $PSScriptRoot 'mission-capsule.ps1') -Action start -Name 'self-test' -Goal 'validate durable phone-to-computer mission state' -Mode relay -SuccessCriteria @('no write during dry run') -RequestId 'wechat-agent-mission-dry-run-v1' -DryRun) | ConvertFrom-Json
    $gates = @($mission.mission.safetyGates)
    $passedMission = $mission.status -eq 'dry-run' -and $mission.mission.state -eq 'active' -and $gates.Count -eq 4
    Add-Result 'mission-capsule-dry-run' $passedMission "state=$($mission.mission.state), safetyGates=$($gates.Count), no files created"
} catch { Add-Result 'mission-capsule-dry-run' $false $_.Exception.Message }

try {
    $missionModes = @('relay','field','review','watch','deliver','decision')
    $observedModes = @(
        foreach ($missionMode in $missionModes) {
            $modeResult = (& (Join-Path $PSScriptRoot 'mission-capsule.ps1') -Action start -Name "self-test-$missionMode" -Goal 'validate mission mode routing without creating state' -Mode $missionMode -SuccessCriteria @('requested mode is preserved') -DryRun) | ConvertFrom-Json
            if ($modeResult.status -ne 'dry-run' -or $modeResult.mission.state -ne 'active') {
                throw "Mission mode '$missionMode' did not return an active dry-run mission."
            }
            [string]$modeResult.mission.mode
        }
    )
    $passedModes = $observedModes.Count -eq $missionModes.Count -and
        (@($observedModes | Sort-Object) -join ',') -eq (@($missionModes | Sort-Object) -join ',')
    Add-Result 'mission-capsule-all-modes' $passedModes "modes=$($observedModes -join ','), no files created"
} catch { Add-Result 'mission-capsule-all-modes' $false $_.Exception.Message }

try {
    $relay = (& (Join-Path $PSScriptRoot 'work-relay-card.ps1') -Goal 'self-test relay context' -MaxRecentFiles 3 -MaxChats 1 -DryRun) | ConvertFrom-Json
    $passedRelay = $relay.status -eq 'dry-run' -and $relay.recentFileCount -gt 0 -and $relay.gatewayHealthy
    Add-Result 'work-relay-card-dry-run' $passedRelay "files=$($relay.recentFileCount), chats=$($relay.recentChatCount), gateway=$($relay.gatewayHealthy), no card created"
} catch { Add-Result 'work-relay-card-dry-run' $false $_.Exception.Message }

try {
    $releaseTools=@('release-audit.ps1','build-release.ps1','release-self-test.ps1')
    $releaseReady=@($releaseTools|Where-Object{Test-Path -LiteralPath (Join-Path $PSScriptRoot $_) -PathType Leaf}).Count -eq $releaseTools.Count
    Add-Result 'release-safety-tooling' $releaseReady "tools=$($releaseTools.Count)"
} catch { Add-Result 'release-safety-tooling' $false $_.Exception.Message }

Add-Result 'unsafe-proactive-script-absent' (-not (Test-Path -LiteralPath (Join-Path $PSScriptRoot 'send-wechat-self.ps1'))) 'openclaw message send wrapper disabled'

try {
    $fixture = Join-Path $workspace 'media-fixtures\boundary-test.mp4'
    $reminder = (& (Join-Path $PSScriptRoot 'schedule-wechat-reminder.ps1') -Message 'self-test' -At '10m' -Name 'self-test-dry-run' -AttachmentPath $fixture -DryRun) | ConvertFrom-Json
    Add-Result 'reminder-target-resolution' ($reminder.status -eq 'validated' -and $reminder.targetCount -eq 1 -and $reminder.hasAttachment) 'case-preserved target + attachment validated; no job created'
} catch { Add-Result 'reminder-target-resolution' $false $_.Exception.Message }

foreach ($workflowTest in @(
    @{ Name='task-state-lifecycle'; Script='test-task-state.ps1'; Expected=10 },
    @{ Name='review-acceptance-lifecycle'; Script='test-review-acceptance.ps1'; Expected=3 },
    @{ Name='mobile-task-overview'; Script='test-task-overview.ps1'; Expected=3 },
    @{ Name='relay-path-safety'; Script='test-relay-path-safety.ps1'; Expected=3 }
)) {
    try {
        $workflow = (& (Join-Path $PSScriptRoot $workflowTest.Script)) | ConvertFrom-Json
        Add-Result $workflowTest.Name ($workflow.ok -and $workflow.tests -eq $workflowTest.Expected) "checks=$($workflow.tests)"
    } catch { Add-Result $workflowTest.Name $false $_.Exception.Message }
}

$passed = @($results | Where-Object passed).Count
[pscustomobject]@{
    status = if ($passed -eq $results.Count) { 'passed' } else { 'failed' }
    passed = $passed
    total = $results.Count
    timestamp = (Get-Date).ToString('o')
    tests = $results
} | ConvertTo-Json -Depth 6

if ($passed -ne $results.Count) { exit 1 }
