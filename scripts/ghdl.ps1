<#
ghdl.ps1 — GitHub 资产下载 + 完整性校验 + 交付改名（PowerShell 版，替代 download-assets.md 里的 bash 流程）

固定流程一次做完：HEAD 拿期望字节数 → 按链路顺序下载到 .part → 校验（字节数一致 且 魔数类型正确）→ 通过才改名交付。
任一校验不过：删除半成品、换下一条链路，最多试 Chains 条；全部失败则报错退出，绝不交付不完整文件、绝不谎报成功。

用法:
  powershell -File ghdl.ps1 -Url <GitHub直链> -Out <交付文件名|完整路径> [-Expect 字节数] [-Chains '链1','链2'] [-MaxTimeSec 300]

说明:
  -Expect 优先用 API 返回的 asset.size（最可靠）；不给则自动 HEAD 获取。拿不到期望字节数 = 校验不通过。
  -Chains 为前缀拼接式代理链，%URL% 会被替换为直链；默认使用本脚本顶部实测顺序。
  -Out 只给文件名时落在 -OutDir（默认当前目录）。交付文件名建议中文，扩展名保留原样。
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Url,
    [Parameter(Mandatory)][string]$Out,
    [long]$Expect = 0,
    [string[]]$Chains = @(
        'direct:%URL%',
        'gh-proxy:https://gh-proxy.com/%URL%'
    ),
    [string]$OutDir = '',
    [int]$MaxTimeSec = 300
)

$ErrorActionPreference = 'Stop'

function Say($m) { [Console]::Error.WriteLine("ghdl: $m") }

if (-not $OutDir) { $OutDir = (Get-Location).Path }
if ($Out -match '[\\/]' -or [IO.Path]::IsPathRooted($Out)) { $Dest = $Out } else { $Dest = Join-Path $OutDir $Out }
$DestDir = Split-Path -Parent $Dest
if ($DestDir -and -not (Test-Path -LiteralPath $DestDir)) { New-Item -ItemType Directory -Path $DestDir -Force | Out-Null }

# ---- 期望字节数 ----
if ($Expect -le 0) {
    $h = & curl.exe -sI -L --ssl-no-revoke --connect-timeout 10 --max-time 30 $Url 2>$null
    $cl = @($h | Select-String -Pattern 'ontent-[Ll]ength:\s*(\d+)')
    if ($cl.Count -gt 0) {
        $v = $cl[-1].Line -replace '^.*ontent-[Ll]ength:\s*', '' -replace '\D', ''
        if ($v -match '^\d+$') { $Expect = [long]$v }
    }
}
if ($Expect -le 0) { Say '拿不到期望字节数（HEAD 失败），按红线规则不下载不交付。请先用 API 的 asset.size 传入 -Expect。'; exit 1 }
Say ("期望字节数: {0}" -f $Expect)

# ---- 魔数类型校验（本机无 file 命令，用 Python 读文件头）----
$sigPy = @'
import sys
p = sys.argv[1]
with open(p, 'rb') as f:
    head = f.read(8)
    f.seek(0, 2); size = f.tell()

def kind(h, size, p):
    if h.startswith(b'%PDF'):
        return 'PDF'
    if h[:4] in (b'PK\x03\x04', b'PK\x05\x06', b'PK\x07\x08'):
        return 'Zip/EPUB'
    if h.startswith(b'\x1f\x8b'):
        return 'gzip(tar.gz)'
    if h.startswith(b'\xfd7zXZ'):
        return 'XZ'
    if h.startswith(b'BZh'):
        return 'bzip2'
    if h.startswith(b'7z\xbc\xaf'):
        return '7z'
    try:
        with open(p, 'rb') as g:
            g.seek(257)
            if g.read(5) == b'ustar':
                return 'tar'
    except Exception:
        pass
    if size < 200 * 1024:
        return 'SMALL-TEXT?'
    return 'UNKNOWN'

print('%s|%s|%d' % (kind(head, size, p), head[:5].hex(), size))
'@
$sigFile = [IO.Path]::ChangeExtension([IO.Path]::GetTempFileName(), '.py')
[IO.File]::WriteAllText($sigFile, $sigPy, (New-Object Text.UTF8Encoding($false)))

# 允许的类型按交付扩展名区分：文本类放行文本，二进制类必须命中魔数
$ext = [IO.Path]::GetExtension($Dest).ToLower()
$textExts = @('.txt', '.md', '.json', '.yaml', '.yml', '.sh', '.ps1', '.patch', '.diff', '.csv', '.xml', '.asc', '.sig')
if ($textExts -contains $ext) {
    $allowedTypes = '^PDF$|^Zip/EPUB$|^gzip\(tar\.gz\)$|^XZ$|^bzip2$|^7z$|^tar$|^SMALL-TEXT\?$|^UNKNOWN$'
} else {
    $allowedTypes = '^PDF$|^Zip/EPUB$|^gzip\(tar\.gz\)$|^XZ$|^bzip2$|^7z$|^tar$'
}
$tried = @(); $lastFail = ''
foreach ($chainRaw in $Chains) {
    if ($chainRaw -eq 'direct:%URL%') { $DlUrl = $Url; $Name = '直连' }
    else { $DlUrl = $chainRaw.Replace('%URL%', $Url); $Name = ($chainRaw -split ':')[0] }

    $Part = "$Dest.part"
    if (Test-Path -LiteralPath $Part) { Remove-Item -LiteralPath $Part -Force }
    Say ("链路[{0}] 开始下载" -f $Name)
    $r = & curl.exe -sL --ssl-no-revoke --connect-timeout 10 --max-time $MaxTimeSec -o $Part -w '%{http_code}|%{size_download}|%{speed_download}' $DlUrl 2>$null
    $tried += $Name
    if ([string]::IsNullOrWhiteSpace($r)) { $r = '000|0|0' }
    $parts = $r -split '\|'
    $code = $parts[0]; $speed = 0
    if ($parts.Count -ge 3) { $speed = [double]$parts[2] }
    $sizeNow = 0
    if (Test-Path -LiteralPath $Part) { $sizeNow = (Get-Item -LiteralPath $Part).Length }
    Say ("链路[{0}] HTTP {1} | 实际 {2}B | 均速 {3:N0}B/s" -f $Name, $code, $sizeNow, $speed)

    $ok = $true
    if ($code -ne '200') { $ok = $false; $lastFail = "HTTP $code 非 200" }
    if ($ok -and $sizeNow -ne $Expect) { $ok = $false; $lastFail = "字节数 $sizeNow != 期望 $Expect" }

    $type = ''
    if ($ok) {
        $sig = (& python $sigFile $Part) -split '\|'
        $type = $sig[0]
        Say ("类型校验: {0} (魔数 {1})" -f $type, $sig[1])
        if ($type -notmatch $allowedTypes) { $ok = $false; $lastFail = "类型 $type 不像二进制资产（可能拿到错误页/文本）" }
    }

    if ($ok) {
        if (Test-Path -LiteralPath $Dest) { Remove-Item -LiteralPath $Dest -Force }
        Move-Item -LiteralPath $Part -Destination $Dest -Force
        $elapsed = [math]::Round(([double]$sizeNow / [math]::Max($speed, 1)))
        Write-Output "DELIVERED|$Dest|$sizeNow|$Expect|$Name|${elapsed}s|$type"
        exit 0
    }
    Say ("链路[{0}] 校验失败：{1}，删除半成品换链路" -f $Name, $lastFail)
    if (Test-Path -LiteralPath $Part) { Remove-Item -LiteralPath $Part -Force }
}

Remove-Item -LiteralPath $sigFile -Force -ErrorAction SilentlyContinue
Say ("全部链路失败（已试: {0}）。把直链给用户自行下载，不谎报成功。直链: {1}" -f ($tried -join ','), $Url)
exit 1
