function Assert-UnlinkedFilePath {
    param(
        [Parameter(Mandatory = $true)]
        [string]$LiteralPath,

        [Parameter(Mandatory = $false)]
        [string]$Purpose = 'operation'
    )

    $item = Get-Item -LiteralPath $LiteralPath -Force -ErrorAction Stop
    if ($item.PSIsContainer) { throw "$Purpose requires a file." }

    $current = $item
    while ($current) {
        if ($current.LinkType -or (($current.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0)) {
            throw "Linked paths are not allowed for $Purpose."
        }
        $parentPath = Split-Path -Parent $current.FullName
        if ([string]::IsNullOrWhiteSpace($parentPath) -or $parentPath -eq $current.FullName) { break }
        $current = Get-Item -LiteralPath $parentPath -Force -ErrorAction Stop
    }

    return $item
}
