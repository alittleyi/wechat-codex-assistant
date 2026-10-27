param(
    [Parameter(Mandatory = $true)]
    [string]$SourcePath
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'runtime-resolver.ps1')
$python = Resolve-AgentRuntime python
$probe = Resolve-AgentSkillResource -SkillName 'ffmpeg-skill' -RelativePath 'scripts\probe.py'
$packageRoot = Join-Path $env:LOCALAPPDATA 'Microsoft\WinGet\Packages\Gyan.FFmpeg_Microsoft.Winget.Source_8wekyb3d8bbwe'
$ffmpegPath=$null
$command=Get-Command ffmpeg.exe -ErrorAction SilentlyContinue|Select-Object -First 1
if($command){$ffmpegPath=$command.Source}
if(-not $ffmpegPath -and (Test-Path -LiteralPath $packageRoot -PathType Container)){
    foreach($directory in Get-ChildItem -LiteralPath $packageRoot -Directory -ErrorAction SilentlyContinue){
        $candidate=Join-Path $directory.FullName 'bin\ffmpeg.exe'
        if(Test-Path -LiteralPath $candidate -PathType Leaf -ErrorAction SilentlyContinue){$ffmpegPath=$candidate;break}
    }
}

if (-not $ffmpegPath) { throw 'FFmpeg was not found in PATH or the known WinGet package directory.' }
if (-not (Test-Path -LiteralPath $python -PathType Leaf)) { throw 'The Codex Python runtime was not found.' }
if (-not (Test-Path -LiteralPath $probe -PathType Leaf)) { throw 'ffmpeg-skill probe.py was not found.' }

$env:Path = "$(Split-Path -Parent $ffmpegPath);$env:Path"
& $python $probe $SourcePath --json
if ($LASTEXITCODE -ne 0) { throw "Media probe failed with exit code $LASTEXITCODE." }
