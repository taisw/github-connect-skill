# GitHub API 速查（本机 PowerShell 版）

下文 `$S` 代表本技能目录（`SKILL.md` 所在目录）。所有 API 调用统一走 `$S\scripts\ghapi.ps1`，需要鉴权的 git 命令走 `$S\scripts\git-auth.ps1`，下载走 `$S\scripts\ghdl.ps1`。

## 调用约定

- 统一形态：`powershell.exe -NoProfile -ExecutionPolicy Bypass -File $S\scripts\ghapi.ps1 <路径> [选项]`
- 需要账号权限时，Token 只设在**子进程**环境变量里，不要写文件、不要 export 到会话：
  ```powershell
  powershell.exe -NoProfile -Command "`$env:GITHUB_TOKEN='<用户提供的值>'; & '$S\scripts\ghapi.ps1' /user -View user"
  ```
  `ghapi.ps1` 在退出前会主动清掉进程内的 `GITHUB_TOKEN`。**向用户展示命令时 Token 一律写成 `$GITHUB_TOKEN` 占位，绝不贴真实值。**
- URL 含 `?` `&` `:` 时整体用**单引号**包裹，否则会被 PowerShell 拆开。
- 本机没有 `jq`，`-q` 改吃 **Python 表达式**（JSON 根对象记作 `d`）。跨多层 shell 传参时引号会被剥掉，**含引号的表达式一律落成文件再用 `-q @文件`**：
  ```powershell
  Set-Content -LiteralPath _expr.py -Value "[a['name'] for a in d['assets']]" -Encoding UTF8
  & powershell.exe -NoProfile -File $S\scripts\ghapi.ps1 '/repos/o/r/releases/latest' -q '@_expr.py'
  ```
- 常用取数优先用内置 `-View`（已排好版、自动标注抓取时刻），比手写表达式省事：
  `rate | user | repo | readme | commits | releases | latest | languages | contributors | issues | pulls | branches | tree | search | content`
- `--raw` 与 `-q`/`-View` 互斥，只用于拿原始响应体。

## 0. 连接自检

```powershell
# 匿名是否通 + 还剩多少配额（不需要 Token）
& powershell.exe -NoProfile -File $S\scripts\ghapi.ps1 /rate_limit -View rate

# 验 Token 并拿账号名，把登录名回给用户确认身份
& powershell.exe -NoProfile -Command "`$env:GITHUB_TOKEN='...'; & '$S\scripts\ghapi.ps1' /user -View user"
```

首次「连一下 GitHub」按这两步走：先匿名测连通性，再验 Token。

## A. 查仓库信息

```powershell
$R = '/repos/{owner}/{repo}'

& powershell.exe -NoProfile -File $S\scripts\ghapi.ps1 $R -View repo          # 关键数字 + 定位
& powershell.exe -NoProfile -File $S\scripts\ghapi.ps1 "$R/readme" -View readme # README（已解 base64）
& powershell.exe -NoProfile -File $S\scripts\ghapi.ps1 "$R/commits?per_page=10" -View commits
& powershell.exe -NoProfile -File $S\scripts\ghapi.ps1 "$R/releases/latest" -View latest
& powershell.exe -NoProfile -File $S\scripts\ghapi.ps1 "$R/languages" -View languages
& powershell.exe -NoProfile -File $S\scripts\ghapi.ps1 "$R/contributors?per_page=10" -View contributors
& powershell.exe -NoProfile -File $S\scripts\ghapi.ps1 "$R/issues?state=open&per_page=20" -View issues  # 已过滤掉 PR
& powershell.exe -NoProfile -File $S\scripts\ghapi.ps1 '/search/repositories?q={关键词}&per_page=10&sort=stars' -View search
```

## B. 管理我的仓库（均需 Token）

```powershell
# 我的仓库列表（按最近 push）。表达式先落成文件（内容见注释），避免引号被多层剥掉
#   _expr.py 内容:  [f"{r['full_name']} private={r['private']} {r['pushed_at'][:10]}" for r in d]
& powershell.exe -NoProfile -File $S\scripts\ghapi.ps1 '/user/repos?per_page=50&sort=pushed' -q "@_expr.py"

# 建个人仓库：请求体一定走 -f 文件（含中文/多行时内联会被引号破坏），用完立即删
#   _body.json 内容:  {"name":"my-repo","private":true,"description":"...","auto_init":true}
#   _expr.py   内容:  f"已创建: {d['full_name']} -> {d['html_url']}"
& powershell.exe -NoProfile -File $S\scripts\ghapi.ps1 /user/repos -X POST -f _body.json -q "@_expr.py"
# 组织下建库：把 /user/repos 换成 /orgs/{org}/repos

# 分支 / PR / issue / CI
& powershell.exe -NoProfile -File $S\scripts\ghapi.ps1 "$R/branches" -View branches
& powershell.exe -NoProfile -File $S\scripts\ghapi.ps1 "$R/pulls?state=open&per_page=20" -View pulls
#   _expr.py 内容:  f"{d['state']} merged={d['merged']} 冲突={d['mergeable_state']} +{d['additions']}/-{d['deletions']}"
& powershell.exe -NoProfile -File $S\scripts\ghapi.ps1 "$R/pulls/{n}" -q "@_expr.py"
& powershell.exe -NoProfile -File $S\scripts\ghapi.ps1 "$R/pulls" -X POST -f _pr.json
& powershell.exe -NoProfile -File $S\scripts\ghapi.ps1 "$R/issues" -X POST -f _issue.json
& powershell.exe -NoProfile -File $S\scripts\ghapi.ps1 "$R/issues/{n}/comments" -X POST -d '{"body":"..."}'
#   _expr.py 内容:  [f"{w['name']} | {w['head_branch']} | {w['status']}/{w['conclusion']}" for w in d['workflow_runs']]
& powershell.exe -NoProfile -File $S\scripts\ghapi.ps1 "$R/actions/runs?per_page=5" -q "@_expr.py"
```

**本机没有 git，git 类操作怎么办**

`git-auth.ps1` 检测到缺 git 会直接报错并列出下面这些 REST 兜底路径，不会假装执行成功：

| 想做的事 | 兜底接口 |
| --- | --- |
| 建库 | `POST /user/repos` |
| 读文件 | `GET /repos/{o}/{r}/contents/{path}` → `-View content` |
| 写/改文件 | `PUT /repos/{o}/{r}/contents/{path}`，body 含 `message` + base64 `content`，改动还需当前 `sha` |
| 建分支 | `POST /repos/{o}/{r}/git/refs`（`{"ref":"heads/新分支","sha":"提交sha"}`） |
| 删分支 | `DELETE /repos/{o}/{r}/git/refs/heads/{branch}` |
| 整仓源码 | `https://github.com/{o}/{r}/archive/refs/heads/{branch}.tar.gz`，走 `ghdl.ps1` |
| 开关 issue / PR | `PATCH /repos/{o}/{r}/issues/{n}`、`POST .../pulls` |

真正的 `clone / commit / push` 必须先装 Git for Windows。**这属于安装外部程序，须先取得用户授权**，不要自行安装。装了之后 `git-auth.ps1` 即可用临时 askpass 方式工作。

写操作请求体优先 `-f 临时文件`，**用完立即删除**；临时文件里只放请求体，不放 Token。

## C. 追热门趋势（近似，非官网 Trending）

```powershell
# 近 7 天新建、按 star 排序
$d7 = (Get-Date).ToUniversalTime().AddDays(-7).ToString('yyyy-MM-dd')
& powershell.exe -NoProfile -File $S\scripts\ghapi.ps1 "/search/repositories?q=created:>$d7&sort=stars&order=desc&per_page=10" -View search

# 近 30 天有更新的某语言热门
$d30 = (Get-Date).ToUniversalTime().AddDays(-30).ToString('yyyy-MM-dd')
& powershell.exe -NoProfile -File $S\scripts\ghapi.ps1 "/search/repositories?q=language:python+pushed:>$d30&sort=stars&order=desc&per_page=10" -View search

# 按主题 / star 区间
& powershell.exe -NoProfile -File $S\scripts\ghapi.ps1 '/search/repositories?q=topic:llm+topic:agent&sort=stars&order=desc&per_page=10' -View search
& powershell.exe -NoProfile -File $S\scripts\ghapi.ps1 '/search/repositories?q=language:rust+stars:500..5000&sort=updated&order=desc&per_page=10' -View search
```

输出**必须声明口径**：「GitHub 无官方 Trending API，以下是时间窗口 + star 排序的近似结果」。用户点名要官网榜单时改抓 `https://github.com/trending`（可带 `?since=daily|weekly|monthly`、`/trending/<语言>`）。

## D. 读代码做分析

```powershell
$BR = & powershell.exe -NoProfile -File $S\scripts\ghapi.ps1 $R -q "@_expr.py"   # 表达式：d['default_branch']

& powershell.exe -NoProfile -File $S\scripts\ghapi.ps1 "$R/git/trees/$BR?recursive=1" -View tree   # 先看结构，比 clone 轻得多
& powershell.exe -NoProfile -File $S\scripts\ghapi.ps1 "$R/contents/{path}?ref=$BR" -View content # 读单文件
# 依赖清单逐个试：package.json / requirements.txt / pyproject.toml / go.mod / Cargo.toml / pom.xml
```

本机无 git 时**不要整仓 clone**，用文件树 + 按需读单文件即可；确实需要通读时走 archive 压缩包（`ghdl.ps1`），解开后分析完主动说明目录位置、按用户意愿清理。

分析产出固定结构：**项目定位 → 技术栈与依赖 → 目录结构（每项一句话） → 核心模块与入口 → 关键数据流 → 值得注意的实现或坑 → 上手建议**。结论落到具体文件路径与函数名。

## 限流参考

| 接口 | 匿名 | 带 Token |
| --- | --- | --- |
| core（普通 REST） | 60 次/小时 | 5000 次/小时 |
| search | 10 次/分钟 | 30 次/分钟 |

随时查余量：`ghapi.ps1 /rate_limit -View rate`。剩余为 0 时**不要重试**，改抓页面或告知用户重置时间。
