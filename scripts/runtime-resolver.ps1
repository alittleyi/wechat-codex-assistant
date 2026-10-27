[CmdletBinding()]
param()

# Dot-source this file, then call Resolve-AgentRuntime.  Resolution is deliberately
# independent of a user name or a Codex installation directory.
function Resolve-AgentRuntime {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)]
        [ValidateSet('node','python')]
        [string]$Name,
        [switch]$Detailed
    )

    $overrideName = if ($Name -eq 'node') { 'WECHAT_AGENT_NODE' } else { 'WECHAT_AGENT_PYTHON' }
    $override = [Environment]::GetEnvironmentVariable($overrideName)
    if (-not [string]::IsNullOrWhiteSpace($override)) {
        $resolved = [IO.Path]::GetFullPath($override)
        if (-not (Test-Path -LiteralPath $resolved -PathType Leaf)) {
            throw "$overrideName does not point to a file."
        }
        if($Detailed){return [pscustomobject]@{path=$resolved;source='explicit-environment'}};return $resolved
    }

    # Codex may provide private runtimes that are intentionally absent from PATH.
    # Search only the bounded runtime root and prefer the current primary runtime,
    # whose dependency set is part of this project's verified execution context.
    $runtimeRoot = if ($env:CODEX_RUNTIME_ROOT) {
        [IO.Path]::GetFullPath($env:CODEX_RUNTIME_ROOT)
    } elseif ($env:USERPROFILE) {
        Join-Path $env:USERPROFILE '.cache\codex-runtimes'
    }
    if ($runtimeRoot -and (Test-Path -LiteralPath $runtimeRoot -PathType Container)) {
        $relative = if ($Name -eq 'node') { 'dependencies\node\bin\node.exe' } else { 'dependencies\python\python.exe' }
        $directories = @(Get-ChildItem -LiteralPath $runtimeRoot -Directory -ErrorAction SilentlyContinue |
            Sort-Object @{Expression={ if ($_.Name -eq 'codex-primary-runtime') { 0 } else { 1 } }}, LastWriteTime -Descending |
            Select-Object -First 20)
        foreach ($directory in $directories) {
            $candidate = Join-Path $directory.FullName $relative
            if (Test-Path -LiteralPath $candidate -PathType Leaf) {if($Detailed){return [pscustomobject]@{path=$candidate;source='managed-runtime'}};return $candidate}
        }
    }

    $commandNames = if ($Name -eq 'node') { @('node.exe','node') } else { @('python.exe','python3.exe','python') }
    foreach ($commandName in $commandNames) {
        $command = Get-Command $commandName -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($command -and (Test-Path -LiteralPath $command.Source -PathType Leaf)) {if($Detailed){return [pscustomobject]@{path=$command.Source;source='system-path'}};return $command.Source}
    }

    throw "Unable to resolve $Name runtime. Install it, add it to PATH, or set $overrideName."
}

function Resolve-AgentSkillResource {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)][ValidatePattern('^[a-z0-9][a-z0-9-]{1,80}$')][string]$SkillName,
        [Parameter(Mandatory=$true)][ValidatePattern('^[a-zA-Z0-9._\\/-]{1,200}$')][string]$RelativePath
    )
    if($RelativePath-split'[\\/]'|Where-Object{$_-eq'..'}){throw 'Resource path traversal rejected.'}
    $roots=@()
    if($env:WECHAT_AGENT_SKILLS_ROOT){$roots+=@([IO.Path]::GetFullPath($env:WECHAT_AGENT_SKILLS_ROOT))}
    $workspace=Split-Path -Parent $PSScriptRoot
    $roots+=@(Join-Path $workspace '.agents\skills')
    if($env:USERPROFILE){$roots+=@(Join-Path $env:USERPROFILE '.codex\skills');$roots+=@(Join-Path $env:USERPROFILE '.agents\skills')}
    foreach($root in $roots|Select-Object -Unique){
        if(-not(Test-Path -LiteralPath $root -PathType Container)){continue}
        $skillRoot=[IO.Path]::GetFullPath((Join-Path $root $SkillName))
        $candidate=[IO.Path]::GetFullPath((Join-Path $skillRoot $RelativePath))
        if(-not $candidate.StartsWith($skillRoot.TrimEnd('\')+'\',[StringComparison]::OrdinalIgnoreCase)){continue}
        if(Test-Path -LiteralPath $candidate -PathType Leaf){return $candidate}
    }
    throw "Skill resource was not found: $SkillName/$RelativePath"
}
