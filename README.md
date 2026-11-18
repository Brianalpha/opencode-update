# opencode-update

在 **Windows** 上安全升级 [OpenCode](https://opencode.ai) 的 skill：绕开 `/update` 与
`opencode upgrade` 的“升级卡住 / 超时”。

## 问题

`/update` 和 `opencode upgrade` 都在**当前进程里**执行：

```
npm install --global --force @opencode/cli@<ver>
```

它要覆盖 `…\@opencode\cli\bin\opencode.exe`。Windows 不允许替换正在运行的 exe，而这些进程都在跑同一个文件：

| 进程 | 何时存在 |
| --- | --- |
| TUI（无参数） | 你开着 opencode 的时候 |
| `serve --service` | 常驻后台服务，关掉 TUI 也可能还在 |
| `run --agent …` | 定时任务（日报、抓取等）拉起的无头任务 |

文件被占用 → npm 覆盖失败或挂起 → 界面等到超时。`opencode uninstall` 能成，是因为它会先停服务。

## 它怎么做

不在“正在运行”的时候装，而是把安装排到文件真正空闲的时刻：

```
检查环境并布防 → 等 TUI 退出 → 等定时任务的 run 跑完 → 停后台服务 → npm 安装 → 校验版本
```

- `-Detach` 用 WMI 起一个**独立守护进程**（不在 OpenCode 的进程树里），随后你可以退出 TUI；
- 同时拉起一个**独立进度窗口**，实时显示阶段、百分比、倒计时、步骤清单和日志尾部；
- 安装前后比对 `@opencode/cli/package.json` 与 `opencode --version`，不一致或 exe/shim 缺失都判失败；
- 同一时刻只允许一个升级流程（`update.lock`），避免并发把 `node_modules` 删坏。

## 安装

前提：OpenCode 是通过 **npm 全局安装**的（`@opencode/cli`），Windows 10/11，有 PowerShell 5.1 或 pwsh 7+。

推荐直接 clone 到 skills 目录 —— 之后 `git pull` 就能更新：

```powershell
$dest = Join-Path $env:USERPROFILE ".config\opencode\skills\opencode-update"
git clone https://github.com/Brianalpha/opencode-update.git $dest
```

装完确认能解析到本机的 npm 前缀（此时应先退出 OpenCode）：

```powershell
pwsh -NoProfile -File "$dest\scripts\update-opencode.ps1" -DryRun
```

也可以下载 zip 解压到同一位置，效果一样，只是没法 `git pull`。

## 用法

### 1. 在 OpenCode 里（最常见）

```powershell
pwsh -NoProfile -File "<skill-dir>\scripts\update-opencode.ps1" -Detach
```

它只做**布防**：起守护进程并确认它活着，然后打印日志位置。之后**退出 OpenCode 即可**，
升级会在后台完成，进度窗口会自动打开。

> `-WaitMinutes` 的预算从布防那一刻算起，默认 15 分钟；超时未退出就放弃（日志里会写明）。

### 2. 普通终端、opencode 已关闭

```powershell
pwsh -NoProfile -File "<skill-dir>\scripts\update-opencode.ps1"
```

有进程占用时直接拒绝（exit 2）并列出占用者，不会硬闯。

### 3. 只看进度

```powershell
pwsh -NoProfile -File "<skill-dir>\scripts\watch-opencode-update.ps1"            # 围观 / 事后复盘
pwsh -NoProfile -File "<skill-dir>\scripts\watch-opencode-update.ps1" -Snapshot  # 渲染一帧到 stdout
```

### 参数

| 参数 | 作用 | 默认 |
| --- | --- | --- |
| `-DryRun` | 只探测并打印计划，绝不安装 | off |
| `-Force` | 结束占用进程；**在 TUI 内会被拒绝**（会杀掉自己） | off |
| `-WaitMinutes N` | 布防后等你退出 TUI 的预算 | 15 |
| `-DrainMinutes N` | 退出后等定时任务 run 跑完的预算 | 15 |
| `-Restart` | 升级完自动打开 opencode | off |
| `-NoWatch` | 不自动打开进度窗口 | off |

### 退出码

| 码 | 含义 |
| --- | --- |
| 0 | 成功，或已布防 |
| 1 | 出错（npm 失败、版本不一致、exe 缺失、布防失败） |
| 2 | 前置条件不满足（进程占用、锁冲突、等待超时） |

## 结果在哪看

| 路径 | 内容 |
| --- | --- |
| 进度窗口 | `-Detach` 自动打开，也可手动运行 watch 脚本 |
| `%LOCALAPPDATA%\opencode-update\progress.json` | 实时进度（阶段、百分比、剩余秒数、步骤状态、日志尾部） |
| `%LOCALAPPDATA%\opencode-update\latest.log` | 最近一次升级的完整过程，运行中实时追加 |
| `%LOCALAPPDATA%\opencode-update\latest-result.json` | `status` / `from` / `to` / `expected` / 失败原因 |
| `%LOCALAPPDATA%\opencode-update\update-*.log` | 历史日志 |

失败时带上 `latest.log` 内容再排查。`-DryRun` 只写 `latest-dryrun.json`，不会覆盖上一次真实升级的记录。

## 升级后验收

```powershell
opencode --version                       # 新版本号
Test-Path "<npm prefix>\opencode.cmd"    # True = shim 已重建
opencode run --standalone "只回复 ok"     # headless + 插件能否加载
```

`<npm prefix>` 取自 `npm config get prefix --location=global`（通常是 `%APPDATA%\npm`）。
第三条能提前暴露插件/API 不兼容，而不是等到定时任务跑起来才发现。

## 验证状态

详见 [SKILL.md](SKILL.md) 的「验证状态」一节，包含已实测的路径（成功、失败、超时、锁冲突、失联判定、
进度窗口可见性）与未实测的边界（真实环境“退出 TUI → 安装 → 版本变化”的完整链路等）。

记录来自作者的一台 Windows 机器。换设备后建议先跑一次 `-DryRun`，确认解析到的 npm 前缀、exe 路径
与进程列表符合预期，再正式布防。

## 已知限制

- 只适用于 **npm 全局安装**的 OpenCode；不是 npm 安装时脚本会直接报“找不到 exe”。
- 依赖该包的 postinstall 把平台二进制拷进 `bin\opencode.exe`；若全局策略跳过 postinstall，
  按提示补一次 `npm i -g @opencode/cli@latest --allow-scripts=@opencode/cli`。
- `-Detach -Force` 会跳过“别杀自己祖先”的保护，可能中断等待期间新起的定时任务；不确定就别带。
- `-Detach` 模式下 `-Restart` 拉起的窗口可能不可见，升级完手动打开最稳。
- 结果始终以 `latest-result.json` / `progress.json` / `latest.log` 为准，不依赖弹窗是否被看到。

## 许可

未附带开源许可证，使用即表示自行承担风险。如需再分发，请先加一个明确的许可文件。
