param([Parameter(Mandatory)][string]$Dir)
Get-ChildItem -LiteralPath $Dir -Filter '*.ps1' | ForEach-Object {
    $bytes = [IO.File]::ReadAllBytes($_.FullName)
    if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) {
        "SKIP (has BOM)  $($_.Name)"
    } else {
        $bom = [byte[]](0xEF, 0xBB, 0xBF)
        [IO.File]::WriteAllBytes($_.FullName, $bom + $bytes)
        "ADD BOM         $($_.Name)"
    }
}
