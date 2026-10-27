[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [ValidateRange(1, 50)]
    [int]$Limit = 20,

    [Parameter(Mandatory = $false)]
    [ValidateRange(1, 1000)]
    [int]$ScanLimit = 300
)

$ErrorActionPreference = 'Stop'
$sessionsRoot = Join-Path $env:USERPROFILE '.codex\sessions'
if (-not (Test-Path -LiteralPath $sessionsRoot -PathType Container)) {
    throw 'Codex session directory was not found.'
}

$rows = [System.Collections.Generic.List[object]]::new()
$files = Get-ChildItem -LiteralPath $sessionsRoot -File -Recurse -Filter '*.jsonl' |
    Sort-Object LastWriteTime -Descending |
    Select-Object -First $ScanLimit

foreach ($file in $files) {
    if ($rows.Count -ge $Limit) { break }
    $stream = [System.IO.FileStream]::new(
        $file.FullName,
        [System.IO.FileMode]::Open,
        [System.IO.FileAccess]::Read,
        [System.IO.FileShare]::ReadWrite
    )
    $reader = [System.IO.StreamReader]::new($stream,[System.Text.UTF8Encoding]::new($false),$true)
    try {
        $meta = $null
        $prompt = $null
        $lineCount = 0
        while (-not $reader.EndOfStream -and $lineCount -lt 2000) {
            $lineCount++
            $line = $reader.ReadLine()
            try { $item = $line | ConvertFrom-Json } catch { continue }
            if (-not $meta -and $item.type -eq 'session_meta') {
                $meta = $item.payload
                if ([string]$meta.originator -eq 'openclaw') { break }
            }
            if ($meta -and $item.type -eq 'response_item' -and $item.payload.role -eq 'user') {
                foreach ($part in @($item.payload.content)) {
                    $text = [string]$part.text
                    if ($part.type -eq 'input_text' -and -not [string]::IsNullOrWhiteSpace($text) -and -not $text.TrimStart().StartsWith('<')) {
                        $prompt = ($text -replace '\s+',' ').Trim()
                        break
                    }
                }
            }
            if ($prompt) { break }
        }
        if ($meta -and [string]$meta.originator -ne 'openclaw') {
            if ($prompt -and $prompt.Length -gt 100) { $prompt = $prompt.Substring(0,100) + '...' }
            $rows.Add([pscustomobject]@{
                modified = $file.LastWriteTime.ToString('yyyy-MM-dd HH:mm:ss')
                projectPath = [string]$meta.cwd
                source = [string]$meta.originator
                prompt = $prompt
            })
        }
    } finally {
        $reader.Dispose()
    }
}

[pscustomobject]@{
    status = 'ok'
    count = $rows.Count
    chats = $rows
} | ConvertTo-Json -Depth 5
