<#
git-auth.ps1 — 用运行时的 GITHUB_TOKEN 执行需要鉴权的 git 命令（PowerShell 版，替代 git-auth.sh）

安全设计（与原版一致）：
  - Token 只从环境变量 GITHUB_TOKEN 读取，通过临时 GIT_ASKPASS 脚本在 git 提示时按需回传；
  - 不写入 .git/config，不出现在 remote URL，不进 git 凭据缓存（credential.helper 显式置空）；
  - 临时 askpass 文件用完即删；脚本自身不回显 Token。

用法:
  $env:GITHUB_TOKEN='...'; powershell -File git-auth.ps1 clone --depth 1 https://github.com/owner/repo.git
  $env:GITHUB_TOKEN='...'; powershell -File git-auth.ps1 push origin main

本机没有 git 时：明确报错并给出 REST API 兜底路径清单，绝不假装执行成功。
#>
[CmdletBinding()]
param(
    [Parameter(ValueFromRemainingArguments = $true)][string[]]$GitArgs
)

$ErrorActionPreference = 'Stop'
function Say($m) { [Console]::Error.WriteLine("git-auth: $m") }

if (-not $GitArgs -or $GitArgs.Count -eq 0) {
    Say "用法: `$env:GITHUB_TOKEN='...' powershell -File git-auth.ps1 <git 子命令> [参数...]"
    exit 2
}

if ($GitArgs[0] -in @('--help', '-h')) {
    Write-Output '用运行时的 GITHUB_TOKEN 执行鉴权 git 命令；凭据不落盘、不进缓存。'
    exit 0
}

if (-not $env:GITHUB_TOKEN) {
    Say '未设置 GITHUB_TOKEN，无法执行需要鉴权的 git 操作。请让用户临时提供一个 Personal Access Token（本技能不会保存它）。'
    exit 1
}

$git = Get-Command git -ErrorAction SilentlyContinue
if (-not $git) {
    Say '本机未安装 git，无法执行 git 命令。以下操作可先用 REST API 兜底（走 ghapi.ps1）：'
    Say '  建库            POST /user/repos'
    Say '  读/写单文件     GET/PUT /repos/{o}/{r}/contents/{path}（PUT 需 base64 内容 + sha）'
    Say '  建/删分支       POST/DELETE /repos/{o}/{r}/git/refs/heads/{branch}'
    Say '  issue / PR      POST /repos/{o}/{r}/issues 、 /pulls'
    Say '  整仓源码下载     https://github.com/{o}/{r}/archive/refs/heads/{branch}.tar.gz（走 ghdl.ps1）'
    Say '真正的 clone/commit/push 需要先安装 Git for Windows，请经用户授权后再装。'
    exit 127
}

# 关闭一切交互式提示，避免无人值守环境挂住
$env:GIT_TERMINAL_PROMPT = '0'
$env:GCM_INTERACTIVE = 'never'
$env:GIT_CONFIG_NOSYSTEM = '1'

$askpass = Join-Path $env:TEMP ("askpass-{0}.cmd" -f [Guid]::NewGuid().ToString('N'))
try {
    # askpass 从环境变量读凭据，不在磁盘留任何秘密
    Set-Content -LiteralPath $askpass -Encoding ASCII -Value @'
@echo off
echo %GITHUB_TOKEN%
'@
    $env:GIT_ASKPASS = $askpass
    $env:SSH_ASKPASS_REQUIRE = 'never'

    & git -c credential.helper= @GitArgs
    $status = $LASTEXITCODE
} finally {
    if (Test-Path -LiteralPath $askpass) { Remove-Item -LiteralPath $askpass -Force }
}

if ($status -ne 0) {
    Say "git $($GitArgs[0]) 失败（退出码 $status）。常见原因：Token 权限不足（缺 Contents: Read/Write）、分支不存在、或非快进推送被拒（先 fetch + pull --rebase，不要直接强推）。"
}
exit $status
