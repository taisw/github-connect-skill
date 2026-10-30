# 脚本说明（本机 PowerShell 版）

| 脚本 | 用途 | 凭据来源 |
| --- | --- | --- |
| `ghapi.ps1` | 调用 GitHub REST API，统一处理请求头、`--ssl-no-revoke`、错误码、限流换算与输出视图 | 环境变量 `GITHUB_TOKEN`，未设置则匿名；退出前自清 |
| `ghdl.ps1` | 下载仓库资产 + 完整性校验 + 交付改名，一条命令做完 | 公开资产不需要凭据 |
| `git-auth.ps1` | 本机装有 git 时，执行需要鉴权的 git 命令 | `GITHUB_TOKEN` 经临时 `GIT_ASKPASS` 传递 |
| `add-bom.ps1` | 给本目录 `.ps1` 补 UTF-8 BOM（PowerShell 5.1 必需） | 无 |

调用形态：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File ghapi.ps1 /repos/owner/name -View repo
```

四个脚本都**不读取、不写入任何凭据文件**，Token 只活在单次子进程的环境变量里，进程结束即消失。不要把 Token 写进脚本、配置、`.git/config`、PowerShell 启动文件或长期记忆，也不要在给用户的回复里回显。

与云端原版的差异（本机无 bash / jq / git / file）：

- `-q` 参数由 jq 过滤器改为 **Python 表达式**（JSON 根对象记作 `d`）；因跨层 shell 会剥引号，含引号的表达式请用 `-q @文件`。
- 新增 `-View` 内置中文视图（`rate / user / repo / readme / commits / releases / latest / languages / contributors / issues / pulls / branches / tree / search / content`），常规取数不必写表达式。
- 类型校验由 `file` 命令改为 Python 读文件头魔数。
- 下载链路顺序改为**直连优先、`gh-proxy.com` 兜底**（本机实测直连 2.3–3.6 MB/s，镜像约 200–270 KB/s，与云端结论相反）。

各自 `-h` 可查看用法。
