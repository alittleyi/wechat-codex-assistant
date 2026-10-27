[CmdletBinding()]
param()

$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'runtime-resolver.ps1')
$python=Resolve-AgentRuntime python
$temporary=Join-Path $env:TEMP ('wechat-workflow-regression-'+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $temporary|Out-Null

function Invoke-JsonCheck([string]$Name,[scriptblock]$Command){
    $raw=& $Command
    $parsed=$raw|ConvertFrom-Json
    if(-not $parsed.ok){throw "$Name failed."}
    [pscustomobject]@{name=$Name;tests=[int]$parsed.tests;passed=$true}
}

try{
    $results=@()
    $results+=Invoke-JsonCheck 'task-state' { & (Join-Path $PSScriptRoot 'test-task-state.ps1') }
    $results+=Invoke-JsonCheck 'review-acceptance' { & (Join-Path $PSScriptRoot 'test-review-acceptance.ps1') }
    $results+=Invoke-JsonCheck 'task-overview' { & (Join-Path $PSScriptRoot 'test-task-overview.ps1') }
    $results+=Invoke-JsonCheck 'task-chat-registry' { & (Join-Path $PSScriptRoot 'test-task-chat-registry.ps1') }
    $results+=Invoke-JsonCheck 'relay-path-safety' { & (Join-Path $PSScriptRoot 'test-relay-path-safety.ps1') }
    $results+=Invoke-JsonCheck 'dispatch-bridge' { & (Join-Path $PSScriptRoot 'test-dispatch-bridge.ps1') }
    $results+=Invoke-JsonCheck 'runtime-resolver' { & (Join-Path $PSScriptRoot 'test-runtime-resolver.ps1') }

    Add-Type -AssemblyName System.Drawing
    $firstImage=Join-Path $temporary 'first.png'
    $secondImage=Join-Path $temporary 'second.png'
    foreach($item in @(@($firstImage,[Drawing.Color]::SteelBlue),@($secondImage,[Drawing.Color]::DarkOrange))){
        $bitmap=[Drawing.Bitmap]::new(96,64)
        try{
            $graphics=[Drawing.Graphics]::FromImage($bitmap)
            try{$graphics.Clear($item[1])}finally{$graphics.Dispose()}
            $bitmap.Save($item[0],[Drawing.Imaging.ImageFormat]::Png)
        }finally{$bitmap.Dispose()}
    }
    if(-not(Test-Path -LiteralPath $python -PathType Leaf)){throw 'Bundled Python runtime is unavailable.'}
    $fieldRaw=& $python (Join-Path $PSScriptRoot 'test_field_report.py') --image $firstImage --second-image $secondImage --output-root (Join-Path $temporary 'field-output')
    if($LASTEXITCODE-ne0){throw 'Field report regression exited with an error.'}
    $field=$fieldRaw|ConvertFrom-Json
    if($field.status-ne'passed'-or$field.livePhoneTest-ne$false){throw 'Field report regression returned an invalid result.'}
    $results+=[pscustomobject]@{name='field-report';tests=@($field.checks).Count;passed=$true}

    $total=($results|Measure-Object -Property tests -Sum).Sum
    [ordered]@{
        status='passed';passed=$total;total=$total;livePhoneTest=$false
        note='Local synthetic regression only; no live mobile field loop was claimed.'
        suites=$results
    }|ConvertTo-Json -Depth 6
}finally{
    if(Test-Path -LiteralPath $temporary){Remove-Item -LiteralPath $temporary -Recurse -Force}
}
