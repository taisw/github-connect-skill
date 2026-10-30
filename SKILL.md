---
name: github-connect-local
description: 当用户要连接或操作 GitHub（也常被写成 gethub / gitHub / git hub / 吉特哈勃）时使用。覆盖五类需求：查仓库信息（star、fork、README、最近更新、提交、release、issue、贡献者）；管理自己的仓库（建库、看分支与 PR、创建 issue/PR、读写仓库内文件）；追热门趋势（按语言/主题/时间窗口找新项目与热门项目）；读代码做分析（讲清项目定位、目录结构、关键实现与数据流）；下载仓库资产（release 附件 PDF/EPUB/压缩包、仓库内单文件、整仓源码压缩包，自动做完整性校验）。支持私有仓库，Token 由用户每次运行时临时提供，技能内不写死、不保存任何凭据。触发示例：“连一下我的 GitHub”“看看 xxx 这个仓库怎么样”“帮我在 GitHub 上建个仓库”“最近 Python 有什么热门项目”“讲讲这个 repo 是怎么实现的”“能直接给我那个 PDF 吗”。
---

# GitHub 连接助手（本机版）

通过 GitHub REST API 完成仓库查询、仓库管理、趋势发现、代码分析与资产下载。本技能自带三个封装脚本，所有 GitHub 交互都走它们，不要另写一次性 curl 拼接。

## 〇、本机运行环境事实（先读这段，与云端不同）

| 项 | 本机情况 | 影响 |
| --- | --- | --- |
| Shell | Windows PowerShell 5.1 | 无 `&&`/`?:`/`??`；语句用 `;` 分隔 |
| `bash` / `jq` / `git` | **都没有** | 云端原版 `ghapi.sh`、`git-auth.sh` 在本机跑不了；已改写为 `.ps1`，`-q` 改用 Python 表达式 |
| `curl.exe` | 系统自带，可用 | **必须加 `--ssl-no-revoke`**，否则 schannel 吊销检查会直接失败（CRYPT_E_NO_REVOCATION_CHECK） |
| `python` | 可用（3.13） | 承担 JSON 过滤、base64 解码、文件头魔数校验 |
| `file` 命令 | 没有 | 类型校验用 Python 读魔数（脚本已内置） |
| `Invoke-WebRequest` | 不要用 | 大文件会先全读进内存、极慢；统一用 curl.exe |
| GitHub 直连速度 | **实测 2.3–3.6 MB/s，是最快链路** | 与云端「直连几十 KB/s、必须走镜像」相反。默认直连优先、gh-proxy 兜底 |
| 连接器状态 | GitHub 自定义连接已登记，需用户把 Token 填入连接器配置才可用 | 未连接前一律走匿名 API；写操作按第一节索取一次性 Token |

`.ps1` 必须带 UTF-8 BOM，否则 PowerShell 5.1 按 GBK 读取会把中文搞乱、直接解析报错。改动脚本后跑一次：
```powershell
& powershell.exe -NoProfile -File <技能目录>\scripts\add-bom.ps1 -Dir <技能目录>\scripts
```

## 一、凭据规则（最高优先级，先读这一段再动手）

1. **技能内永不保存 Token。** 不写入任何文件、脚本、配置、`.git/config`、PowerShell 配置文件，也不写进长期记忆。
2. **公开数据默认匿名访问**，不要一上来就索取 Token。只有两种情况才索取：用户明确要做写操作；或匿名请求返回 404/403 且目标很可能是私有资源。
3. **下载慢不等于缺权限。** 不要因为下载超时或慢就向用户索取 Token、也不要建议用户登录账号——账号权限不加速公开 release 下载，慢在网络链路，按第 E 节换链路。
4. **索取话术**（一次说清，不要挤牙膏）：
   > 这个操作要用你的 GitHub 账号权限。请给我一个 Personal Access Token（GitHub → Settings → Developer settings → Personal access tokens）。建议用 fine-grained token，只勾这次需要的权限、有效期设短一点，用完可以在同一页面直接撤销。
5. **Token 只以子进程环境变量形式传入当前这一次调用**，不要写进会话变量、不要落文件：
   ```powershell
   powershell.exe -NoProfile -Command "`$env:GITHUB_TOKEN='<用户提供的值>'; & '<技能目录>\scripts\ghapi.ps1' /user -View user"
   ```
   `ghapi.ps1` 退出前会主动清掉进程内的 `GITHUB_TOKEN`。
6. **绝不回显 Token。** 回复正文、执行说明、错误信息里都不得出现完整或片段 Token。向用户展示将要执行的命令时，一律用 `$GITHUB_TOKEN` 占位。
7. 本轮结束后告知用户：Token 只在这一次命令里用过，没有落盘；若要长期自动化，建议改用 SSH key 或每次重新提供。
   **例外**：如果用户已把 Token 填进「连接器」配置（那是持久凭据），要如实说明这一点，并提醒用短期、最小权限的 Token、随时可在 GitHub 撤销。
8. **最小权限对照表**（建议用户按需勾选，不要一律要 `repo` 全权）：

   | 要做的事 | fine-grained 权限 | classic scope |
   | --- | --- | --- |
   | 读公开数据 | 不需要 Token | 不需要 Token |
   | 读私有仓库内容 | Contents: Read（+ Metadata: Read） | `repo` |
   | 创建仓库 | Administration: Read and write | `repo` |
   | 读写仓库内文件 | Contents: Read and write | `repo` |
   | 读写 issue | Issues: Read and write | `repo` |
   | 读写 PR | Pull requests: Read and write | `repo` |

## 二、自带脚本

三个脚本都在本技能目录下，调用时先解析出本技能 `SKILL.md` 所在目录，再用 `<技能目录>\scripts\xxx.ps1` 形式执行。

- **`scripts/ghapi.ps1`** — GitHub REST API 封装。自动带 `Accept` / `X-GitHub-Api-Version` / `User-Agent` 头，并对本机补 `--ssl-no-revoke`；`GITHUB_TOKEN` 存在则加 `Authorization: Bearer`，不存在则匿名。支持 `-X` 方法、`-d` JSON 请求体、`-f` 文件请求体、`-q` Python 表达式（可用 `-q @文件`）、`-View` 内置中文视图、`--raw` 原样输出。401/403/404/422/限流/网络失败都有明确中文报错，失败时退出码非 0。
- **`scripts/ghdl.ps1`** — 下载 + 完整性校验 + 交付改名一条命令做完。按 `-Chains` 顺序尝试（默认直连优先、gh-proxy 兜底），校验通过才改名成交付名。
- **`scripts/git-auth.ps1`** — 需要鉴权的 git 命令包装器（本机装了 Git for Windows 之后才生效）。凭据通过临时 `GIT_ASKPASS` 传递，**不会写进 `.git/config`、不出现在 remote URL、不进 git 凭据缓存**，临时文件用完即删。**本机当前没有 git**，脚本会直接报错并列出可用的 REST 兜底接口，不会假装执行成功。

具体接口路径与表达式写法见 [references/api-recipes.md](references/api-recipes.md)，下载链路与校验流程见 [references/download-assets.md](references/download-assets.md)。

## 三、任务分流

先判断本轮属于哪一类（一轮里可能混合多类，按下面顺序做完），再执行。

### A. 查仓库信息

1. 从用户话里解析 `owner/repo`。只给了项目名时，先用 `/search/repositories?q=<名称>` 找候选；有多个同名候选就列出让用户选，不要猜一个就当结论。只给作者人名（如某人的书）时，同理先搜项目名关键词，再用描述里的作者信息确认归属，严禁把同名不同作者的项目当结论。
2. 取基本信息 + README + 最近提交，按需补 release / languages / contributors / issues。
3. 汇总输出固定小节：**项目定位 → 关键数字（star / fork / open issues / 语言 / 许可 / 最近 push） → README 摘要 → 近期活跃度 → 风险或注意点**。
4. 所有数字必须来自 API 返回，标注抓取时刻。API 没给的字段写“⚠️未获取”，不要用印象补。

### B. 管理我的仓库

1. 写操作前先确认 Token 已提供，否则先索取。
2. 建库：`POST /user/repos`（组织下用 `POST /orgs/{org}/repos`）。建库参数里 `name` / `private` / `description` / `auto_init` 缺失且影响结果时，问一次再建。
3. **本机没有 git**：涉及“改仓库里的文件、建分支、开关 issue/PR”改用 REST 接口（见 recipes 的兜底表）；真正的 `clone / commit / push` 需要先装 Git for Windows，**这属于安装外部程序，必须先征得用户授权**，不自行安装、也不谎称已推送。
4. 写操作请求体一律走 `-f 临时文件`（内联 JSON 的引号会被 PowerShell 破坏），**用完立即删除**；临时文件里只放请求体，不放 Token。
5. commit / PR message 用户没给就根据改动内容拟一条简洁英文/中文（跟随仓库已有提交风格），拟好后直接用，不必反复确认。
6. **破坏性操作红线**：force push、删除分支、删除仓库、改仓库可见性、批量关闭 issue —— 必须用户在同一句里明确要求，且执行前复述将影响的对象（仓库名/分支名）并等一次确认。

### C. 追热门趋势

1. **GitHub 没有官方 Trending API。** 默认用 search 接口近似：`q=created:><N天前日期>&sort=stars&order=desc`，并**明确告知用户这是“时间窗口 + star 排序”的近似结果，不等于官网 Trending 榜单**。
2. 用户点名要官网 Trending 原样榜单时，改用网页抓取 `https://github.com/trending`（可带 `?since=daily|weekly|monthly`、`/trending/<language>`）。
3. 默认输出 10 条，表格列：**项目 | 语言 | star | 简介（一句话，中文）**；能拿到时间窗口内新增 star 时再加一列。
4. search 接口限流较严（认证 30 次/分，匿名 10 次/分），一次请求拿够 `per_page`，不要循环翻页刷。

### D. 读代码做分析

1. 优先用 API 拿文件树（`/git/trees/{branch}?recursive=1`）和单文件（`/contents/{path}`），**本机没有 git，不要用整仓 clone 作为默认手段**。
2. 需要通读或多文件交叉分析时，下载 archive 压缩包到工作区临时目录解开；分析完主动说明目录位置，用户不需要时清理。
3. 私有仓库的文件树与内容需带 Token 走同一批接口。
4. 分析产出固定结构：**项目定位 → 技术栈与依赖 → 目录结构（带一句话说明） → 核心模块与入口 → 关键数据流 → 值得注意的实现或坑 → 上手建议**。
5. 结论要指向具体文件/函数，不要泛泛而谈。引用代码片段控制在必要长度。

### E. 下载仓库资产（PDF / EPUB / 压缩包 / 单文件 / 整仓源码）

1. **先分清要下什么**，不要一律下整仓：
   - release 附件（电子书 PDF、EPUB、安装包）→ release asset 的 `browser_download_url`；
   - 仓库内某个文本文件 → `/contents/{path}`（`-View content` 已自动解 base64），**不要为一个小文件下载整仓**；
   - 整仓源码 → archive 压缩包（本环境实测比走镜像更快，无 `.git` 对象开销）。
2. **本环境直连最快**（实测 2.3–3.6 MB/s），默认先走直连，失败再换 `gh-proxy.com` 兜底；动手前照 references 里的「链路快测」验一次，不要把历史数字当永久保证。
3. 固定五步，**一条命令里做完**（`ghdl.ps1` 已封装）：拿期望字节数（优先 API 的 `asset.size`）→ 下载到 `.part` 临时名 → 校验字节数一致且魔数类型正确 → 重命名为中文交付文件名 → 交付。校验不过就删掉半成品换链路重下，**绝不交付不完整文件，也不谎报成功**。
4. 不要用后台挂起 + 轮询等待来硬扛慢链路——正确做法是先快测再换链路。
5. 交付文件名用中文（如 `深入理解AI-Agent-中文版.pdf`），扩展名保留原样。
6. 私有仓库的资产仍需 Token，这时才按凭据规则索取；公开资产不要要 Token。
7. 向用户报告时给出：实际下载字节数、速度/耗时、来源链接、走的是哪条链路，以及该链接是滚动标签还是固定版本（影响下次能否拿到新版）。

## 四、失败处理（不要静默重试）

| 情况 | 处理 |
| --- | --- |
| 401 | Token 无效或过期。告知用户重新提供，最多重试 1 次 |
| 403 且 `x-ratelimit-remaining: 0` | 限流。脚本已直接换算成北京时间报出重置时间；改走网页抓取或建议稍后再试；**禁止循环重试** |
| 403 其他 | 权限不足。把脚本打印的已授予 scope 转述给用户，指出还缺哪一项 |
| 404 | 仓库不存在，或是私有仓库而当前凭据无权访问。先核对 `owner/repo` 拼写，再问是否为私有。**`/releases/latest` 返回 404 通常只是没有正式 release 或最新被标为预发布**，不代表仓库私有，改用 `/releases?per_page=5` 看列表 |
| 422 | 请求体校验失败。把 API 返回的 `message` 原样转述，修正后再发 |
| `CRYPT_E_NO_REVOCATION_CHECK` / curl (35) | 忘加 `--ssl-no-revoke`。脚本内部已加；手写 curl 必须补上 |
| 脚本中文乱码 / 解析报错 | `.ps1` 缺 UTF-8 BOM，跑一次 `scripts/add-bom.ps1` |
| `-q` 表达式 SyntaxError | 引号被多层 shell 剥掉。改为把表达式落成文件用 `-q @文件`（优先直接用 `-View`） |
| 下载超时 / 速度异常慢 | 先快测再换链路重试（最多试 2 条），仍失败则把直链给用户并说明原因，不谎报成功 |
| 网络失败（HTTP 000） | 明确说该链路不通并换下一条；不用历史数据或猜测冒充结果 |

## 五、输出规范

- 关键数字标注抓取时刻；不同时间口径的数据不混用。
- 仓库地址、issue/PR 编号给出可点击链接（`https://github.com/owner/repo/...`）。
- 未获取到的数据用 ⚠️ 标注，不用旧数据冒充实时数据。
- 交到用户手上的本地文件走交付流程（把绝对路径作为最终交付物提交），不要只贴裸路径。
- 回复全程中文；代码、命令、字段名、仓库名保留原文。
