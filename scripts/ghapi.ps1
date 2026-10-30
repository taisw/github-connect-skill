<#
ghapi.ps1 — GitHub REST API 轻量封装（PowerShell 版，替代 ghapi.sh）

凭据只从环境变量 GITHUB_TOKEN 读取；未设置时匿名访问（仅限公开数据，core 限流 60 次/小时）。
本脚本不会把 Token 写入任何文件、日志或标准输出，错误信息中也不回显请求头原文。

用法: powershell -File ghapi.ps1 <API路径或完整URL> [选项]
示例:
  powershell -File ghapi.ps1 /repos/octocat/Hello-World -View repo
  powershell -File ghapi.ps1 /rate_limit -View rate
  powershell -File ghapi.ps1 '/search/repositories?q=language:rust&sort=stars&per_page=5' -View search
注意: URL 含 ? & : 时整体用单引号包裹。本机无 jq，-q 改吃 Python 表达式（JSON 根对象记作 d）。
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0)] [string]$Target,
    [Alias('X')] [string]$Method = 'GET',
    [Alias('d')] [string]$Body = '',
    [Alias('f')] [string]$BodyFile = '',
    [Alias('q')] [string]$Expr = '',
    [string]$View = '',
    [switch]$Raw,
    [string]$Accept = 'application/vnd.github+json',
    [int]$TimeoutSec = 60,
    [switch]$Help
)

$ErrorActionPreference = 'Stop'
$env:PYTHONIOENCODING = 'utf-8'
try { [Console]::OutputEncoding = New-Object Text.UTF8Encoding($false) } catch { }

$API_ROOT = 'https://api.github.com'

function Say($m) { [Console]::Error.WriteLine("ghapi: $m") }

if ($Help) {
    Write-Output @'
用法: ghapi.ps1 <API路径或完整URL> [选项]

  -X METHOD       HTTP 方法，默认 GET（写操作用 POST / PATCH / PUT / DELETE）
  -d JSON         请求体 JSON 字符串（简单内容）
  -f FILE         从文件读请求体 JSON（含中文或多行时必须用这个）
  -q EXPR         Python 表达式，JSON 根对象记作 d（本机无 jq 的替代）
  -View NAME      内置中文视图，见下表
  -Raw            原样输出响应体，不做任何处理
  -Accept MIME    覆盖 Accept 头
  -TimeoutSec N   单次请求超时，默认 60

可用视图: rate | user | repo | readme | commits | releases | latest | languages
          contributors | issues | pulls | branches | tree | search | content
'@
    exit 0
}

if (-not $Target) { Say '缺少 API 路径，例如 /repos/owner/name'; exit 2 }

if ($Target -match '^https?://') { $Url = $Target }
elseif ($Target.StartsWith('/')) { $Url = "$API_ROOT$Target" }
else { $Url = "$API_ROOT/$Target" }

$hdrFile = [IO.Path]::GetTempFileName()
$bodyFile = [IO.Path]::GetTempFileName()
$payloadFile = $null
$pyFile = $null
try {
    $curlArgs = @('-sS', '-L', '--ssl-no-revoke', '--connect-timeout', '10', '--max-time', "$TimeoutSec",
        '-X', $Method,
        '-H', "Accept: $Accept",
        '-H', 'X-GitHub-Api-Version: 2022-11-28',
        '-H', 'User-Agent: qwen-github-connect')

    if ($env:GITHUB_TOKEN) { $curlArgs += @('-H', "Authorization: Bearer $($env:GITHUB_TOKEN)") }

    $payload = $null
    if ($BodyFile) {
        if (-not (Test-Path -LiteralPath $BodyFile)) { Say "-f 需要一个可读的文件路径: $BodyFile"; exit 2 }
        $payload = [IO.File]::ReadAllText($BodyFile)
    } elseif ($Body) { $payload = $Body }

    if ($payload) {
        $payloadFile = [IO.Path]::GetTempFileName()
        [IO.File]::WriteAllText($payloadFile, $payload, (New-Object Text.UTF8Encoding($false)))
        $curlArgs += @('-H', 'Content-Type: application/json', '--data-binary', "@$payloadFile")
    }

    $curlArgs += @('-D', $hdrFile, '-o', $bodyFile, '-w', '%{http_code}', $Url)
    $prevEap = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    $Status = (& curl.exe @curlArgs 2>$null)
    $ErrorActionPreference = $prevEap
    if ([string]::IsNullOrWhiteSpace($Status)) { $Status = '000' }

    function GetHdr([string]$name) {
        $lines = Get-Content -LiteralPath $hdrFile -ErrorAction SilentlyContinue
        if (-not $lines) { return '' }
        $hit = @($lines | Where-Object { $_ -match "^\s*$name`:.*" })
        if ($hit.Count -eq 0) { $hit = @($lines | Where-Object { $_ -match "(?i)^\s*$name`:.*" }) }
        if ($hit.Count -eq 0) { return '' }
        return (($hit[-1] -replace '(?i)^[^:]+:\s*', '') -replace "`r", '').Trim()
    }

    $rawBody = ''
    if (Test-Path -LiteralPath $bodyFile) {
        $rawBody = [IO.File]::ReadAllText($bodyFile, (New-Object Text.UTF8Encoding($false)))
    }

    function ShowBody {
        if ($rawBody) {
            $t = $rawBody
            if ($t.Length -gt 1200) { $t = $t.Substring(0, 1200) }
            [Console]::Error.WriteLine($t)
        }
    }
    function ShowScopes {
        $s = GetHdr 'x-oauth-scopes'
        if ($s) { Say "当前 Token 已授予的 scope: $s" }
    }

    function Run-Py([string]$code, [string]$dataFile) {
        $py = [IO.Path]::ChangeExtension([IO.Path]::GetTempFileName(), '.py')
        $pre = @"
import json, sys
raw = open(r'$dataFile', encoding='utf-8-sig').read()
d = json.loads(raw) if raw.strip() else None
"@
        [IO.File]::WriteAllText($py, ($pre + "`n" + $code), (New-Object Text.UTF8Encoding($false)))
        $prev = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        $raw = & python $py 2>&1
        $rc = $LASTEXITCODE
        $ErrorActionPreference = $prev
        $text = (@($raw | ForEach-Object { "$_" })) -join "`n"
        Remove-Item -LiteralPath $py -Force -ErrorAction SilentlyContinue
        return @{ text = $text; rc = $rc }
    }

    switch -regex ($Status) {
        '^2' { }
        '^401$' { Say 'HTTP 401 未授权：GITHUB_TOKEN 无效、已过期，或未提供。'; ShowScopes; ShowBody; exit 1 }
        '^(403|429)$' {
            $remain = GetHdr 'x-ratelimit-remaining'
            if ($remain -eq '0') {
                $reset = GetHdr 'x-ratelimit-reset'
                Say "HTTP $Status API 限流已用尽。"
                if ($reset -match '^\d+$') {
                    $bj = [DateTimeOffset]::FromUnixTimeSeconds([long]$reset).ToOffset([TimeSpan]::FromHours(8))
                    Say "配额重置时间: $($bj.ToString('yyyy-MM-dd HH:mm:ss'))（北京时间）"
                }
                Say '不要循环重试；可改走页面抓取，或等配额恢复。'
            } else {
                Say "HTTP $Status 权限不足或操作被禁止。检查 Token 的权限是否覆盖该操作。"
                ShowScopes
            }
            ShowBody; exit 1
        }
        '^404$' {
            Say 'HTTP 404 资源不存在；若确认路径无误，可能是私有仓库而当前凭据无权访问。'
            Say '注意：/releases/latest 返回 404 通常只是没有正式 release 或最新被标为预发布，不代表仓库私有，改用 /releases?per_page=5 看列表。'
            ShowBody; exit 1
        }
        '^422$' { Say 'HTTP 422 请求参数或请求体校验失败。'; ShowBody; exit 1 }
        '^000$' { Say '网络请求失败（DNS 解析 / 连接超时 / 被拒绝），未收到任何 HTTP 响应。该链路不通，请换下一条，不要用历史数据或猜测冒充结果。'; exit 1 }
        default { Say "HTTP $Status 请求失败。"; ShowBody; exit 1 }
    }

    if ($Raw) { Write-Output $rawBody; exit 0 }

    if ($Expr) {
        # 跨多层 shell 传参时引号易被剥掉：支持 -q @文件；表达式一律落成临时文件，由 Python 侧 eval
        $exprText = $Expr
        if ($Expr.StartsWith('@')) {
            $ef = $Expr.Substring(1)
            if (-not (Test-Path -LiteralPath $ef)) { Say "-q 引用的表达式文件不存在: $ef"; exit 2 }
            $exprText = [IO.File]::ReadAllText($ef)
        }
        $exprFile = [IO.Path]::ChangeExtension([IO.Path]::GetTempFileName(), '.txt')
        [IO.File]::WriteAllText($exprFile, $exprText.Trim(), (New-Object Text.UTF8Encoding($false)))
        $pyCode = @"
_e = open(r'$exprFile', encoding='utf-8-sig').read().strip()
out = eval(_e, {'d': d, 'json': json, 'sorted': sorted, 'len': len, 'str': str, 'sum': sum, 'enumerate': enumerate, 'round': round})
if isinstance(out, (list, tuple)):
    for x in out:
        print(x)
elif isinstance(out, dict):
    print(json.dumps(out, ensure_ascii=False, indent=2))
elif out is None:
    pass
else:
    print(out)
"@
        $r = Run-Py $pyCode $bodyFile
        Remove-Item -LiteralPath $exprFile -Force -ErrorAction SilentlyContinue
        if ($r.rc -ne 0) {
            Say '表达式执行失败或响应不是 JSON，已回退为原样输出。'
            Say ('表达式: ' + $exprText.Trim())
            Say (((($r.text -split "`n") | Select-Object -Last 2)) -join ' ')
            $cap = $rawBody
            if ($cap.Length -gt 3000) { $cap = $cap.Substring(0, 3000) + ' …(已截断)' }
            Write-Output $cap
            exit 1
        }
        Write-Output $r.text
        exit 0
    }

    if (-not $View) {
        $r = Run-Py "print(json.dumps(d, ensure_ascii=False, indent=2))" $bodyFile
        if ($r.rc -ne 0) { Write-Output $rawBody } else { Write-Output $r.text }
        exit 0
    }

    $data = $null
    if (-not [string]::IsNullOrWhiteSpace($rawBody)) {
        try { $data = $rawBody | ConvertFrom-Json } catch { Say '响应不是 JSON，无法套用视图。'; Write-Output $rawBody; exit 1 }
    }
    $now = ([DateTimeOffset]::Now.ToOffset([TimeSpan]::FromHours(8))).ToString('yyyy-MM-dd HH:mm:ss')

    function V([string]$fmt, $map) {
        $sb = New-Object Text.StringBuilder
        foreach ($line in ($fmt -split "`n")) {
            if (-not $line.Trim()) { continue }
            $t = $line
            foreach ($kv in $map.GetEnumerator()) { $t = $t.Replace('{{' + $kv.Key + '}}', [string]$kv.Value) }
            [void]$sb.AppendLine($t)
        }
        Write-Output $sb.ToString().TrimEnd()
    }
    function OrDash($v) { if ($null -ne $v -and "$v" -ne '') { return "$v" } return '-' }
    function B64($s) { return [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String(($s -replace '\s', ''))) }
    function Beiji($unix) {
        if ($unix -match '^\d+$') {
            return ([DateTimeOffset]::FromUnixTimeSeconds([long]$unix)).ToOffset([TimeSpan]::FromHours(8)).ToString('HH:mm:ss')
        }
        return '未知'
    }

    $view = $View.ToLower()
    switch ($view) {
        'rate' {
            $c = $data.resources.core
            $s = $data.resources.search
            V '配额（抓取时刻 {{T}}，匿名凭据按匿名口径计）
core   : 剩余 {{CR}} / {{CL}}，重置 {{CT}}
search : 剩余 {{SR}} / {{SL}}，重置 {{ST}}
提示   : 匿名 core 仅 60 次/小时；剩余为 0 时不要重试。' ([ordered]@{
                T = $now; CR = $c.remaining; CL = $c.limit; CT = Beiji $c.reset
                SR = $s.remaining; SL = $s.limit; ST = Beiji $s.reset
            })
        }
        'user' {
            V '登录名: {{L}}  昵称: {{N}}
公开仓库: {{PR}}  粉丝: {{F}}
主页: {{H}}
（以上来自 API 返回，抓取时刻 {{T}}）' ([ordered]@{
                L = $data.login; N = OrDash $data.name; PR = $data.public_repos
                F = $data.followers; H = $data.html_url; T = $now
            })
        }
        'repo' {
            $desc = if ($data.description) { $data.description } else { '(无描述)' }
            $lic = if ($data.license) { OrDash $data.license.spdx_id } else { '-' }
            V '项目: {{FN}} — {{D}}
⭐ {{STAR}} | fork {{FORK}} | open issues {{ISSUES}}
语言: {{LANG}} | 许可: {{LIC}}
创建: {{CRE}} | 最近 push: {{PUSH}} | 默认分支: {{BR}}
主页: {{HOME}}
链接: https://github.com/{{FN}}
（数字均为 API 返回原值，抓取时刻 {{T}}）' ([ordered]@{
                FN = $data.full_name; D = $desc; STAR = $data.stargazers_count
                FORK = $data.forks_count; ISSUES = $data.open_issues_count
                LANG = OrDash $data.language; LIC = $lic
                CRE = OrDash $data.created_at; PUSH = OrDash $data.pushed_at
                BR = OrDash $data.default_branch; HOME = OrDash $data.homepage; T = $now
            })
        }
        'readme' { Write-Output (B64 $data.content) }
        'content' {
            if ($data.encoding -ne 'base64') { Say '响应不是 base64 内容，无法解码。'; exit 1 }
            Write-Output (B64 $data.content)
        }
        'commits' {
            foreach ($c in $data) {
                $msg = (($c.commit.message -split "`n") -join ' ')
                if ($msg.Length -gt 110) { $msg = $msg.Substring(0, 110) + '…' }
                Write-Output ("{0}  {1}  {2}" -f $c.sha.Substring(0, 7), $c.commit.author.date.Substring(0, 10), $msg)
            }
        }
        'releases' {
            foreach ($r in $data) {
                $pre = if ($r.prerelease) { '预发布' } else { '正式' }
                $assets = @($r.assets).Count
                Write-Output ("{0} | {1} | {2} | 附件{3}个 | {4}" -f $r.tag_name, (OrDash $r.published_at), $pre, $assets, (OrDash $r.name))
            }
        }
        'latest' {
            $n = @($data.assets).Count
            V '最新 release: {{TAG}}（{{PUB}}）
名称: {{NAME}} | 附件 {{N}} 个
链接: {{URL}}' ([ordered]@{
                TAG = $data.tag_name; PUB = OrDash $data.published_at
                NAME = OrDash $data.name; N = $n; URL = OrDash $data.html_url
            })
        }
        'languages' {
            $total = 0.0
            foreach ($p in $data.PSObject.Properties) { $total += [double]$p.Value }
            if ($total -le 0) { Say '无语言统计数据。'; exit 0 }
            foreach ($p in ($data.PSObject.Properties | Sort-Object { [double]$_.Value } -Descending)) {
                Write-Output ("{0,-22} {1,10:N0}B  {2,6:P1}" -f $p.Name, [double]$p.Value, ([double]$p.Value / $total))
            }
        }
        'contributors' {
            foreach ($c in $data) { Write-Output ("{0}  {1}" -f $c.login, $c.contributions) }
        }
        'issues' {
            $n = 0
            foreach ($i in $data) {
                if ($i.PSObject.Properties.Name -contains 'pull_request') { continue }
                Write-Output ("#{0} [{1}] {2} — {3} {4}" -f $i.number, $i.state, $i.title, $i.user.login, $i.created_at.Substring(0, 10))
                $n++
            }
            if ($n -eq 0) { Write-Output '(本页内无纯 issue；GitHub 的 /issues 端点会把 PR 混在一起，已过滤)' }
        }
        'pulls' {
            foreach ($p in $data) {
                Write-Output ("#{0} {1} | {2} -> {3} | draft={4} | {5}" -f $p.number, $p.title, $p.head.ref, $p.base.ref, $p.draft, $p.user.login)
            }
        }
        'branches' { foreach ($b in $data) { Write-Output $b.name } }
        'tree' {
            $i = 0
            foreach ($t in $data.tree) {
                $i++
                if ($i -gt 300) { Write-Output '…（视图截断到 300 条；完整清单请用 -q 自行过滤）'; break }
                if ($t.type -eq 'tree') { Write-Output ("{0}/" -f $t.path) }
                else { Write-Output ("{0}  ({1}B)" -f $t.path, $t.size) }
            }
            if ($data.PSObject.Properties.Name -contains 'truncated' -and $data.truncated) {
                Say '注意：文件树过大已被 GitHub 截断（truncated=true）。'
            }
        }
        'search' {
            Write-Output ("共匹配 {0} 个仓库，本页返回 {1} 条（抓取时刻 {2}）" -f $data.total_count, @($data.items).Count, $now)
            Write-Output ''
            foreach ($r in $data.items) {
                $d = if ($r.description) { $r.description } else { '-' }
                if ($d.Length -gt 80) { $d = $d.Substring(0, 80) + '…' }
                Write-Output ("{0} | {1} | ⭐{2} | {3}" -f $r.full_name, (OrDash $r.language), $r.stargazers_count, $d)
            }
        }
        default { Say "未知视图: $View（-h 看可用列表）"; exit 2 }
    }
} finally {
    foreach ($p in @($hdrFile, $bodyFile, $payloadFile)) {
        if ($p -and (Test-Path -LiteralPath $p)) { Remove-Item -LiteralPath $p -Force -ErrorAction SilentlyContinue }
    }
    if ($env:GITHUB_TOKEN) { Remove-Item Env:\GITHUB_TOKEN -ErrorAction SilentlyContinue }
}
