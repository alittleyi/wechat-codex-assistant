[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
$root=Join-Path $env:TEMP ('runtime-resolver-test-'+[guid]::NewGuid().ToString('N'))
$previousSkills=$env:WECHAT_AGENT_SKILLS_ROOT
New-Item -ItemType Directory -Path (Join-Path $root 'ffmpeg-skill\scripts') -Force|Out-Null
[IO.File]::WriteAllText((Join-Path $root 'ffmpeg-skill\scripts\probe.py'),'# synthetic probe',[Text.UTF8Encoding]::new($false))
try{
    $env:WECHAT_AGENT_SKILLS_ROOT=$root
    . (Join-Path $PSScriptRoot 'runtime-resolver.ps1')
    $node=Resolve-AgentRuntime node -Detailed;$python=Resolve-AgentRuntime python -Detailed
    if(-not(Test-Path -LiteralPath $node.path)-or$node.source-notin@('explicit-environment','managed-runtime','system-path')){throw 'node resolution failed'}
    if(-not(Test-Path -LiteralPath $python.path)-or$python.source-notin@('explicit-environment','managed-runtime','system-path')){throw 'python resolution failed'}
    $probe=Resolve-AgentSkillResource -SkillName ffmpeg-skill -RelativePath 'scripts\probe.py'
    if($probe-ne(Join-Path $root 'ffmpeg-skill\scripts\probe.py')){throw 'skill resource resolution failed'}
    $media=Get-Content -LiteralPath (Join-Path $PSScriptRoot 'media-probe.ps1') -Raw
    if($media-match'C:\\Users\\hi'-or$media-notmatch'Resolve-AgentSkillResource'){throw 'media probe still has a fixed user path'}
    $traversalBlocked=$false;try{Resolve-AgentSkillResource -SkillName ffmpeg-skill -RelativePath '..\outside.py'|Out-Null}catch{$traversalBlocked=$true}
    if(-not$traversalBlocked){throw 'resource traversal was not blocked'}
    [ordered]@{ok=$true;tests=5;sources=@($node.source,$python.source)}|ConvertTo-Json -Depth 4
}finally{
    $env:WECHAT_AGENT_SKILLS_ROOT=$previousSkills
    if(Test-Path -LiteralPath $root){Remove-Item -LiteralPath $root -Recurse -Force}
}
