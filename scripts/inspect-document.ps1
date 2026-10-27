[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$Path
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'runtime-resolver.ps1')
$python = Resolve-AgentRuntime python
$script = Join-Path $PSScriptRoot 'inspect_document.py'

if (-not (Test-Path -LiteralPath $python -PathType Leaf)) {
    throw 'Codex built-in Python runtime was not found.'
}

& $python $script $Path
if ($LASTEXITCODE -ne 0) {
    throw "Document inspection failed with exit code: $LASTEXITCODE"
}
