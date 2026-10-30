# 用于连接任务型ai的GitHub 连接助手（Windows 本机版）

通过 GitHub REST API 完成五类任务：查仓库信息、管理仓库、追热门趋势、读代码分析、下载资产（带完整性校验）。**全 PowerShell 实现，不需要 bash / jq / git / file 命令。**

## 快速开始

```powershell
# 匿名查仓库信息（不需要 Token）
powershell -NoProfile -File scripts\ghapi.ps1 /repos/microsoft/vscode -View repo

# 查 API 剩余配额
powershell -NoProfile -File scripts\ghapi.ps1 /rate_limit -View rate

# 带 Token 查自己的账号（Token 只在子进程环境变量里，退出即清）
powershell -NoProfile -Command "`$env:GITHUB_TOKEN='ghp_xxx'; & 'scripts\ghapi.ps1' /user -View user"

# 下载公开 release 资产（自动校验字节数+魔数，通过才交付）
powershell -NoProfile -File scripts\ghdl.ps1 -Url 'https://github.com/.../releases/download/.../file.pdf' -Out '中文文件名.pdf' -Expect 1234567
```

## 环境要求

| 依赖 | 本机必须有吗 | 说明 |
| --- | --- | --- |
| Windows PowerShell 5.1 | ✅ | 系统自带 |
| `curl.exe` | ✅ | 系统自带，脚本已统一加 `--ssl-no-revoke` |
| `python` | ✅ | 承担 JSON 过滤、base64 解码、文件头魔数校验 |
| git | ❌ | 没有也不影响 REST 操作；读写文件走 Contents API 兜底 |
| bash / jq / file | ❌ | 全部不需要 |

## 脚本一览

| 脚本 | 用途 | 凭据来源 |
| --- | --- | --- |
| `scripts/ghapi.ps1` | GitHub REST API 封装。内置 16 种中文输出视图，失败时中文报错 + 限流北京时间换算 | `$env:GITHUB_TOKEN`（未设置则匿名） |
| `scripts/ghdl.ps1` | 下载 + 完整性校验 + 交付改名。HEAD 拿期望字节数 → 下载到 .part → 校验字节数+魔数 → 通过才改名 | 公开资产不需要凭据 |
| `scripts/git-auth.ps1` | 装了 git 后用于需要鉴权的 git 操作，凭据只通过临时 askpass 传递、不落盘 | `$env:GITHUB_TOKEN` |
| `scripts/add-bom.ps1` | 给 `.ps1` 文件补 UTF-8 BOM（PowerShell 5.1 读中文必需） | 无 |

详细用法见 [scripts/README.md](scripts/README.md)，API 接口速查见 [references/api-recipes.md](references/api-recipes.md)，下载链路与校验见 [references/download-assets.md](references/download-assets.md)。

## 凭据安全

- **技能内永不保存 Token**，不写入任何文件、脚本、配置、`.git/config`、PowerShell 配置文件
- Token 只在子进程环境变量中临用即清；向用户展示命令时一律用 `$GITHUB_TOKEN` 占位
- 公开数据默认匿名访问，不主动索取 Token

## 许可

MIT