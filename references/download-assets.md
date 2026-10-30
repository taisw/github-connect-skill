# GitHub 文件下载链路（本机实测版）

适用于下载**公开** release 资产、压缩包与仓库内文件。**私有资源仍需 Token，但 Token 不会提速。**

## 本机实测结论（2026-10-22，Windows / PowerShell 环境）

用同一个 15,194,618 字节的公开 release 资产（cli/cli v2.103.0 windows_amd64.zip）实测：

| 链路 | 结果 |
| --- | --- |
| **直连 `github.com/.../releases/download/...`** | **HTTP 200，约 2.3–2.8 MB/s，15MB 约 5 秒下完** |
| 直连 archive 整仓包 | HTTP 200，约 3.6 MB/s |
| `gh-proxy.com/<完整 GitHub URL>` | HTTP 200，约 200–270 KB/s |
| `ghproxy.net/<完整 GitHub URL>` | HTTP 200，约 270 KB/s |
| `raw.githubusercontent.com` | HTTP 200/206，**通**（小文件正常） |
| `ghfast.top` / `mirror.ghproxy.com` / `gh.llkk.cc` / `hub.gitmirror.com` | HTTP 000，不通 |

**与云端环境结论相反**：那份快照里直连只有几十 KB/s、必须走镜像；本环境**直连反而最快，镜像慢 10 倍以上**。所以 `ghdl.ps1` 的默认链路顺序是 **直连优先、gh-proxy 兜底**。

> 这是本机一次实测快照，网络条件会变。**动手前先照下面「链路快测」验一次，不要把上面的数字当永久保证**；也不要因为某条镜像这次不通就断定全部不通。

## ⚠️ 本机两个必须知道的技术坑

1. **`curl.exe` 必须加 `--ssl-no-revoke`。** 本机系统自带 curl 走 schannel，默认要做证书吊销在线检查，在本网络下会直接失败：
   `curl: (35) schannel: ... CRYPT_E_NO_REVOCATION_CHECK (0x80092012)`
   `ghapi.ps1` / `ghdl.ps1` 内部已统一加上，你手写 curl 命令时也必须带。
2. **不能用 `Invoke-WebRequest` 下大文件。** 它会先把整包读进内存并受进度条拖累，实测极慢。统一用 `curl.exe`。
3. 本机**没有 `file` 命令**，类型校验改用 Python 读文件头魔数（`ghdl.ps1` 已内置）；也**没有 bash**，原 bash 脚本的 `[[ ]]` 静默跳过校验那个坑在这里以另一种形式存在——PowerShell 5.1 读不到 UTF-8 中文会**解析报错而不是静默失败**，所以 `.ps1` 必须带 UTF-8 BOM（`scripts/add-bom.ps1` 负责补）。

## 链路快测（动手前先跑，10 秒出结论）

```powershell
# 只测 8 秒，看各链路能拉多少
curl.exe -s -o NUL --ssl-no-revoke --connect-timeout 8 --max-time 8 -w '直连: %{speed_download} B/s HTTP %{http_code}' "<直链>"
curl.exe -s -o NUL --ssl-no-revoke --connect-timeout 8 --max-time 8 -w '镜像: %{speed_download} B/s HTTP %{http_code}' "https://gh-proxy.com/<直链>"
```

## 固定流程：一条命令做完下载 + 校验 + 改名

```powershell
# 推荐：期望字节数用 API 返回的 asset.size（最可靠），通过 -Expect 传入
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $S\scripts\ghdl.ps1 `
    -Url 'https://github.com/{owner}/{repo}/releases/download/{tag}/{asset}.zip' `
    -Out '中文交付名.zip' `
    -OutDir '<输出目录>' `
    -Expect 15194618 `
    -MaxTimeSec 300
```

脚本内部依次做完：HEAD/API 拿期望字节数 → 按 `-Chains` 顺序下到 `.part` → 校验（HTTP 200 **且** 实际字节数 == 期望 **且** 魔数类型符合扩展名）→ 全通过才改名成交付名 → 输出一行机器可读结果：

```
DELIVERED|<绝对路径>|<实际字节>|<期望字节>|<成功链路>|<耗时>|<类型>
```

任一校验不过：**删掉半成品、自动换下一条链路**；全部链路失败则非零退出并打印直链，**绝不交付不完整文件、绝不谎报成功**。

需要手工指定链路顺序时：`-Chains 'direct:%URL%','gh-proxy:https://gh-proxy.com/%URL%'`（`%URL%` 会被替换为直链）。

### 校验红线的三条硬规则（沿用原文，本机同样适用）

1. **拿不到期望字节数 = 校验不通过**，不下载不交付；先想办法从 API 拿 `asset.size`。
2. 交付前必须同时看到「期望字节数」与「实际字节数」两个数字且相等。
3. 类型不符（镜像返回错误页 / HTML）一律视为失败换链路。

## 拿资产 URL

```powershell
# 列 release（优先用 API 拿 browser_download_url，比在 README 里扒链接可靠）
& powershell.exe -NoProfile -File $S\scripts\ghapi.ps1 '/repos/{o}/{r}/releases?per_page=5' -View releases

# 某 tag 下全部附件名、体积与直链（这里的 size 就是最可靠的期望字节数）
#   _expr.py 内容:  [f"{a['name']} | {a['size']}B | {a['browser_download_url']}" for a in d['assets']]
& powershell.exe -NoProfile -File $S\scripts\ghapi.ps1 '/repos/{o}/{r}/releases/tags/{tag}' -q "@_expr.py"

# 只有预发布版时 /releases/latest 会 404，改用上面的 tags 或列表端点
```

有些仓库用滚动标签（如名为 `latest` 的 tag，指向随 main 推送重建的产物）发布电子书。这类链接**永远指向最新构建**，交付时要说明这一点；用户要固定版本就改用带版本号的 tag。

## 备选方案（本机优先级）

1. **直连** —— 本环境实测最快，首选。
2. **`https://gh-proxy.com/<完整 GitHub URL>`** —— 直连失败时的兜底（本环境约 200–270 KB/s）。
3. **仓库内单个文本文件** —— 直接 `ghapi.ps1 "$R/contents/{path}" -View content`，走 API 域名，不占下载链路。
4. **整仓源码** —— archive 压缩包 `https://github.com/{o}/{r}/archive/refs/heads/{branch}.tar.gz`，本环境实测约 3.6 MB/s，比 clone 更省（无 `.git` 对象开销，且本机没有 git）。
5. **都不行** —— 把直链原文给用户，说明失败原因和已尝试的链路。**不谎报成功，不交付未通过校验的文件。**

## 体积与体验约定

- 动手前先查体积（API 的 `asset.size` 或 HEAD 的 `content-length`）。超过 ~50MB 先告知用户文件多大再下。
- curl 同时给 `--connect-timeout`（8–10 秒）和 `--max-time`（按体积估，10MB 量级给 300 秒），避免无限挂起占住整轮。
- 用户说「太慢了」时，正确响应是**先快测再换链路重下**，不是让用户登录或提供 Token，也不是后台挂起慢慢等。
- 重复下载同一资产时可加一道 `python -c "import hashlib..."` 比对 sha256（API 的 `assets[].digest` 字段直接给了 `sha256:...`，可拿来对照）。
- **交付方式（本机与云端不同）**：不用 `MEDIA:` 行，改用交付工具的最终交付流程，把下载好的绝对路径交给用户。
