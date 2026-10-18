# 独立配置与终端增强

这个可选入口用于在已有 Windows 虚拟机上运行一套独立的 Claude 环境，同时解决 SSH 会话中鼠标滚轮不响应的问题。命令名为 `fureclaude`，原来的 `fuclaude` 继续使用原配置。

工作目录仍通过 VMware 共享；登录、设置、历史和程序副本保存在虚拟机本地。这里的隔离是配置隔离，不是额外的 Windows 安全沙箱。

## 依赖与文件位置

先按主 README 配好 SSH 密钥、共享工作目录和 `FUCLAUDE_*` 环境变量，确认 `fuclaude --version` 能运行。宿主机和虚拟机使用 64 位 Windows PowerShell 5.1；交互会话在宿主机 Windows Terminal 中运行。

宿主机保留仓库根目录中的这些文件，并把该目录加入 PATH：

```text
fuclaude-host.ps1
fureclaude.bat
fureclaude-host.ps1
fureclaude-terminal.cs
```

虚拟机中的目录结构：

```text
%LOCALAPPDATA%\fureclaude\
  bin\
    reclaude.exe
    OpenConsole.exe
    fureclaude-vm.ps1
    fureclaude-update-claude.ps1
    fureclaude-terminal-server.ps1
    fureclaude-terminal.cs
  home\
    .claude\keybindings.json
    .local\bin\claude.exe
    AppData\Local\
    AppData\Roaming\
```

当前独立入口通过兼容启动器 `reclaude.exe` 调用自己的 Claude 副本。程序文件需要自行准备；仓库不包含可执行文件或账户资料。普通官方 Claude 入口仍是 `fuclaude`。

## 首次部署

下面的命令在**虚拟机 PowerShell** 执行，示例假设仓库位于共享盘 `W:\pass-claude-check`。按实际位置修改 `$repo`。首次部署使用一个不存在的新目录，避免覆盖已有安装：

```powershell
$ErrorActionPreference = 'Stop'
$repo = 'W:\pass-claude-check'
$base = Join-Path $env:LOCALAPPDATA 'fureclaude'
if (Test-Path -LiteralPath $base) { throw "目录已存在，请检查后使用已有安装：$base" }

foreach ($relative in @('bin', 'home\.claude', 'home\.local\bin', 'home\AppData\Local', 'home\AppData\Roaming')) {
    New-Item -ItemType Directory -Path (Join-Path $base $relative) -Force | Out-Null
}
foreach ($file in @('fureclaude-vm.ps1', 'fureclaude-update-claude.ps1', 'fureclaude-terminal-server.ps1')) {
    Copy-Item -LiteralPath (Join-Path $repo "vm\$file") -Destination (Join-Path $base "bin\$file")
}
Copy-Item -LiteralPath (Join-Path $repo 'fureclaude-terminal.cs') -Destination (Join-Path $base 'bin\fureclaude-terminal.cs')
Copy-Item -LiteralPath (Join-Path $repo 'vm\fureclaude-keybindings.json') -Destination (Join-Path $base 'home\.claude\keybindings.json')

# 只复制已安装的程序，不复制原来的认证和配置目录。
Copy-Item -LiteralPath (Join-Path $env:USERPROFILE '.local\bin\claude.exe') -Destination (Join-Path $base 'home\.local\bin\claude.exe')
```

若 Claude 安装在其他位置，把最后一行的源路径改成实际 `claude.exe`。目标必须是独立的普通文件，不能链接回共享的 `.local` 或 `.claude`。

将已校验来源的兼容启动器复制到 `bin\reclaude.exe`；已有安装可只复制这个可执行文件。需要下载时，可参考其[安装脚本](https://www.recode.cat/install.ps1)中的发布地址，下载对应架构的程序并对照同源 `.sha256` 文件校验。不要对这套目录运行会自动执行 `setup` 的全局安装流程。

### 准备 OpenConsole

在**宿主机 PowerShell** 查找 Windows Terminal 自带的 OpenConsole，检查数字签名并复制到虚拟机：

```powershell
$ErrorActionPreference = 'Stop'
$terminal = Get-AppxPackage -Name Microsoft.WindowsTerminal |
    Sort-Object Version -Descending | Select-Object -First 1
if (-not $terminal) { throw '请先安装 Windows Terminal，或使用微软官方便携版中的 OpenConsole.exe。' }
$openConsole = Join-Path $terminal.InstallLocation 'OpenConsole.exe'
$signature = Get-AuthenticodeSignature -LiteralPath $openConsole
if ($signature.Status -ne 'Valid' -or $signature.SignerCertificate.Subject -notmatch 'Microsoft Corporation') {
    throw 'OpenConsole 的 Microsoft 签名校验未通过。'
}
# 目标路径相对于 SSH 用户的 home；若使用自定义目录，请相应调整。
scp -i $env:FUCLAUDE_SSH_KEY $openConsole "${env:FUCLAUDE_SSH_TARGET}:AppData/Local/fureclaude/bin/OpenConsole.exe"
if ($LASTEXITCODE -ne 0) { throw 'OpenConsole 复制失败。' }
```

验证环境使用 Windows Terminal 1.24.12741.0 自带的 OpenConsole，虚拟机为 Windows 10 22H2。其他版本或架构需要自行确认兼容性，两个系统的架构应一致。不替换系统 conhost 或 SSH 服务。微软官方版本见 [Windows Terminal releases](https://github.com/microsoft/terminal/releases)。

默认远端入口为 `%LOCALAPPDATA%\fureclaude\bin\fureclaude-vm.ps1`，其中环境变量在虚拟机上展开。如果采用其他位置，在宿主机设置：

```powershell
$env:FURECLAUDE_REMOTE_COMMAND = 'D:\vm-tools\fureclaude\bin\fureclaude-vm.ps1'
```

终端服务脚本需要和该入口放在同一目录。路径支持空格；不要把 `%LOCALAPPDATA%` 换成宿主机展开后的 `$env:LOCALAPPDATA`。

## 使用与维护

在宿主机的共享项目目录打开终端：

```powershell
fureclaude login                 # 单独登录；按提示在浏览器完成授权
fureclaude                      # 新会话
fureclaude -c                   # 继续当前项目的上次会话
fureclaude --version            # 查看这套环境里的 Claude 版本
fureclaude update-claude --check # 只检查版本
fureclaude update-claude         # 更新独立的 Claude 程序副本
```

更新器从 Claude 官方发布地址获取程序，对照 manifest 校验 SHA256，再检查程序报告的版本，最后替换独立目录里的 `claude.exe`。上一版保存在同目录 `claude.previous.exe`。更新后退出旧会话并重新启动。兼容启动器本身需单独维护；入口会拒绝 `setup`、`unsetup`、`uninstall`、`update` 和桌面集成等命令。

新目录需要单独配置账户、代理、插件和 skills；入口会清理继承的 `ANTHROPIC_*`、`CLAUDE_*` 和 `RECLAUDE_*` 变量。不要复制原有凭据目录或把独立目录链接到共享认证目录。需要备份时，备份虚拟机中的整个 `home` 目录，并把它当作含凭据的私有文件处理。

入口只修改当前 SSH 进程的环境，重定向 `USERPROFILE`、`HOMEDRIVE`、`HOMEPATH`、`APPDATA` 和 `LOCALAPPDATA`，并检查主要配置路径是否为链接。主要路径检查不等同于对目录内所有文件做递归审计；应始终从空目录部署。

### 滚动与快捷键

鼠标滚轮在 Claude 全屏界面内滚动。示例 `keybindings.json` 把 `Alt+K` / `Alt+J` 绑定到 `scroll:pageUp` / `scroll:pageDown`。已有快捷键配置时应合并 `Scroll` 段，不要直接覆盖整个文件。

`Ctrl+V` 和直接右键都可以粘贴中文。启用鼠标事件后，终端原本会把右键交给远端应用；转发器将无修饰键的右键点击转换为宿主机剪贴板文本粘贴，并继续转发滚轮和其他鼠标事件。只有点击右键时才读取剪贴板，文本用括号粘贴序列包裹，支持多行内容。修改转发代码后需重启会话。

交互会话通过 `ssh -T` 传输输入和窗口尺寸，由虚拟机内的 OpenConsole 创建终端；这避免了验证环境中 Windows 自带 SSH 终端丢失鼠标事件的问题。已验证滚轮上下滚动、快捷键翻页、中文粘贴、窗口尺寸同步和正常退出。

管理命令、`-p` / `--print` 和重定向调用沿用原 SSH 通道。交互通道目前返回 OpenConsole 的退出状态，不保证传出内部 Claude 的退出码；需要检查命令退出码的自动化应使用非交互通道。

如果要临时切回原 SSH 终端：

```powershell
$env:FURECLAUDE_LEGACY_TTY = '1'
fureclaude -c
Remove-Item Env:FURECLAUDE_LEGACY_TTY
```

修改脚本或终端设置后，需要退出旧会话再运行 `fureclaude -c`。新进程才会加载新设置。

### 可选：完全访问模式

如需默认跳过权限确认，将以下字段合并到**虚拟机独立目录** `home\.claude\settings.json`：

```json
{
  "permissions": { "defaultMode": "bypassPermissions" },
  "skipDangerousModePermissionPrompt": true
}
```

这会跳过 Claude 的权限确认，Claude 仍可访问该虚拟机用户能访问的共享项目和其他资源。仓库没有预置账户设置或默认启用此模式。

## 排查

- `FUCLAUDE_DRY_RUN=1` 可查看目录映射与远端脚本，不连接虚拟机；排查结束后删除该环境变量。
- 报找不到入口：检查虚拟机 SSH 用户的 `%LOCALAPPDATA%`，或设置 `FURECLAUDE_REMOTE_COMMAND`。
- 交互会话打不开：检查 `OpenConsole.exe`、服务脚本和 C# 文件是否齐全且架构匹配；可先用 `FURECLAUDE_LEGACY_TTY=1` 验证原 SSH 通道。
- 报 linked profile path：检查独立 `home` 目录是否误用了原认证目录的符号链接或目录联接。
- 首次 SSH 连接应先单独完成并确认可用，尤其是密码登录或有口令的密钥；终端转发通道不会提供专用的密码输入界面。

## 开发验证

以下回归测试无需连接虚拟机，也不会读取真实剪贴板：

```powershell
powershell.exe -NoProfile -File tests\Test-TerminalUnicode.ps1
powershell.exe -NoProfile -File tests\Test-TerminalPaste.ps1
```

测试覆盖 Windows 原生输入记录中的中文、全角标点、emoji 代理对，以及右键按下/释放、跨批次鼠标序列、滚轮、普通快捷键和粘贴内容中的转义序列。实际 SSH 验证另外覆盖多行中文粘贴和滚轮事件。
