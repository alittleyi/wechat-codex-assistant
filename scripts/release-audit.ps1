[CmdletBinding()]
param([Parameter(Mandatory=$true)][string]$CandidatePath)

$ErrorActionPreference='Stop'
$root=Get-Item -LiteralPath $CandidatePath -Force
if(-not$root.PSIsContainer-or$root.LinkType-or(($root.Attributes-band[IO.FileAttributes]::ReparsePoint)-ne0)){throw 'CandidatePath must be a regular directory.'}
$forbiddenSegments=@('inbox','outbox','media','memory','missions','tasks','receipts','reviews','work-permits','browser-exports','outputs','tmp','work','.openclaw','.codex','.agents','pending-requests')
$forbiddenExtensions=@('.sqlite','.sqlite3','.db','.log','.jsonl','.key','.pem','.pfx','.p12','.cookie','.pyc','.pyo')
$textExtensions=@('.md','.txt','.ps1','.py','.mjs','.js','.vbs','.json','.html','.css','.yml','.yaml','.toml')
$findings=[Collections.Generic.List[object]]::new()

foreach($item in Get-ChildItem -LiteralPath $root.FullName -Force -Recurse){
    $relative=$item.FullName.Substring($root.FullName.TrimEnd('\').Length+1)
    if($item.LinkType-or(($item.Attributes-band[IO.FileAttributes]::ReparsePoint)-ne0)){$findings.Add([pscustomobject]@{path=$relative;reason='reparse-point'});continue}
    $segments=$relative-split'[\\/]'
    if($segments|Where-Object{$_-in$forbiddenSegments}){$findings.Add([pscustomobject]@{path=$relative;reason='runtime-or-private-directory'});continue}
    if($item.PSIsContainer){continue}
    if($item.Extension.ToLowerInvariant()-in$forbiddenExtensions-or$item.Name-eq'__pycache__'){$findings.Add([pscustomobject]@{path=$relative;reason='forbidden-extension-or-cache'});continue}
    if($item.Length-gt25MB){$findings.Add([pscustomobject]@{path=$relative;reason='file-too-large'});continue}
    if($item.Extension.ToLowerInvariant()-in$textExtensions){
        $text=Get-Content -LiteralPath $item.FullName -Raw -Encoding UTF8 -ErrorAction SilentlyContinue
        foreach($rule in @(
            @{name='personal-absolute-path';pattern='(?i)C:\\Users\\hi(?:\\|/)'},
            @{name='wechat-internal-id';pattern='openclaw-weixin:[A-Za-z0-9_@.\-]+'},
            @{name='credential-assignment';pattern='(?im)(access[_-]?token|refresh[_-]?token|cookie|password)\s*[:=]\s*["''][^"'']{8,}["'']'}
        )){if($text-match$rule.pattern){$findings.Add([pscustomobject]@{path=$relative;reason=$rule.name})}}
    }
}

if($findings.Count-gt0){[ordered]@{status='failed';findingCount=$findings.Count;findings=$findings}|ConvertTo-Json -Depth 5;exit 1}
$files=@(Get-ChildItem -LiteralPath $root.FullName -File -Recurse)
[ordered]@{status='passed';files=$files.Count;bytes=($files|Measure-Object Length -Sum).Sum}|ConvertTo-Json
