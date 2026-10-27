[CmdletBinding()]
param()

$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'runtime-resolver.ps1')
$checks=[Collections.Generic.List[object]]::new()
function Add-Check([string]$Name,[string]$State,[string]$Detail){$checks.Add([pscustomobject]@{name=$Name;state=$State;detail=$Detail})}

$openclaw=Get-Command openclaw.cmd,openclaw -CommandType Application -ErrorAction SilentlyContinue|Select-Object -First 1
if(-not$openclaw){Add-Check 'openclaw' 'missing' 'Install OpenClaw first.'}
else{
    $version=(& $openclaw.Source --version 2>$null|Select-Object -First 1)
    Add-Check 'openclaw' 'ready' ([string]$version)
    try{
        $plugins=(& $openclaw.Source plugins list --json)|ConvertFrom-Json
        foreach($id in @('codex','openclaw-weixin')){
            $plugin=@($plugins.plugins|Where-Object { $_.id -eq $id }|Select-Object -First 1)
            $ready=$plugin.Count -eq 1 -and $plugin[0].status -eq 'loaded'
            Add-Check "plugin-$id" $(if($ready){'ready'}else{'missing'}) $(if($plugin.Count){[string]$plugin[0].status}else{'not installed'})
        }
    }catch{Add-Check 'plugins' 'unknown' 'Unable to read plugin status.'}
    try{
        $channels=(& $openclaw.Source channels status --json)|ConvertFrom-Json
        $wechat=$channels.channels.'openclaw-weixin'
        $wechatReady=$null-ne$wechat-and[bool]$wechat.configured
        Add-Check 'wechat-channel' $(if($wechatReady){'ready'}else{'needs-configuration'}) $(if($wechatReady){'configured'}else{'Run openclaw channels add.'})
    }catch{Add-Check 'wechat-channel' 'unknown' 'Unable to read channel status.'}
}

foreach($runtime in @('python','node')){
    try{$detail=Resolve-AgentRuntime $runtime -Detailed;Add-Check $runtime 'ready' $detail.source}catch{Add-Check $runtime 'missing' $_.Exception.Message}
}
try{
    $python=Resolve-AgentRuntime python -Detailed
    $requiredModules=@('lxml','openpyxl','PIL','pypdf','docx','pptx','reportlab')
    $missingModules=@()
    foreach($module in $requiredModules){
        & $python.path -c "import importlib.util,sys;sys.exit(0 if importlib.util.find_spec(sys.argv[1]) else 1)" $module
        if($LASTEXITCODE-ne 0){$missingModules+=$module}
    }
    Add-Check 'python-packages' $(if($missingModules.Count){'missing'}else{'ready'}) $(if($missingModules.Count){'Missing modules: '+($missingModules-join', ')}else{'requirements satisfied'})
}catch{Add-Check 'python-packages' 'missing' $_.Exception.Message}
try{
    $null=Resolve-AgentSkillResource -SkillName 'ffmpeg-skill' -RelativePath 'scripts\probe.py'
    Add-Check 'ffmpeg-skill' 'ready' 'probe resource found'
}catch{Add-Check 'ffmpeg-skill' 'missing' 'Install ffmpeg-skill and FFmpeg.'}
try{
    $snapshot=(& (Join-Path $PSScriptRoot 'system-snapshot.ps1'))|ConvertFrom-Json
    Add-Check 'gateway-runtime' $(if($snapshot.gateway.runtimeHealthy){'ready'}else{'missing'}) "listening=$($snapshot.gateway.listeningLocal)"
    Add-Check 'gateway-persistence' $(if($snapshot.gateway.startupPersistence-eq'scheduled-task-running'){'ready'}else{'unknown'}) $snapshot.gateway.startupPersistence
}catch{Add-Check 'gateway' 'unknown' $_.Exception.Message}

$blocking=@($checks|Where-Object { $_.state -ne 'ready' })
[ordered]@{status=if($blocking.Count){'needs-action'}else{'ready'};blocking=$blocking.Count;checks=$checks;secretsPrinted=$false}|ConvertTo-Json -Depth 5
if($blocking.Count){exit 1}
