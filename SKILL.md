---
name: opencode-update
description: Safely upgrade OpenCode on Windows when `/update` or `opencode upgrade` hangs or times out. Use when the user asks to update/upgrade OpenCode, says `/update` 卡住 or 超时, reports "opencode 升级失败", or needs the TUI/background-service/opencode.exe lock explained. Runs a bundled PowerShell script that arms a detached updater, shows live progress in its own window, stops the shared service, waits for scheduled `opencode run` jobs, installs from a plain shell, and verifies the new binary.
metadata:
  origin: user
tools: Bash, Read
---

# OpenCode 升级（Windows）

## 为什么 `/update` 会卡住

`/update` 和 `opencode upgrade` 都在**当前进程里**执行：

```
npm install --global --force @opencode/cli@<ver>
```

它要覆盖 `…\@opencode\cli\bin\opencode.exe`。Windows 不允许替换正在运行的 exe，而下面这些
进程都在跑同一个文件：

| 进程 | 何时存在 |
| --- | --- |
| TUI（无参数） | 你开着 opencode 的时候 |
| `serve --service` | V2 常驻后台服务，关掉 TUI 也可能还在 |
| `run --agent …` | 定时任务（日报、选题）拉起的无头任务 |

文件被占用 → npm 覆盖失败/挂起 → 界面等到超时。`opencode uninstall` 能成，是因为它会先停服务。

## 用法

脚本：`scripts/update-opencode.ps1`（与本文件同目录）。

### 1. 在 OpenCode 里（最常见）

```powershell
pwsh -NoProfile -File "<skill-dir>/scripts/update-opencode.ps1" -Detach
```

它只做**布防**：用 WMI 起一个隐藏守护进程（不受 OpenCode 的进程树影响），并校验它确实活着。
然后你退出 OpenCode，守护进程会自行完成：

```
等你退出 TUI → 等定时任务的 run 跑完 → 停 service → 确认 exe 可写 → npm 安装 → 校验版本
```

调用完要告诉用户：**进度窗口会自动打开，现在退出 OpenCode 即可，升级会在后台完成**，并给出日志位置。

> `-WaitMinutes` 的预算从布防那一刻算起，默认 15 分钟；超时未退出则放弃（日志里会写明）。

### 1.1 进度窗口（即时反馈）

`-Detach` 会额外用 WMI 拉起 `scripts/watch-opencode-update.ps1`，在独立控制台窗口里实时显示：

```
OpenCode 升级进度    已用时 00:36
--------------------------------------------------------------------------
  版本：2.2.5 → （处理中）
  [###---------------------------------]   8%   阶段 2/6 · 等待退出 OpenCode  |
  现在：OpenCode 仍在运行（TUI PID 33004）
  提示：退出 OpenCode 后本窗口会自动继续
  预算剩余 14:23

  步骤
  + 1 检查环境并布防
  > 2 等待退出 OpenCode   ←
  . 3 等待定时任务结束
  . 4 停止后台服务
  . 5 npm 安装
  . 6 校验版本

  最近日志
  [13:43:05] 守护进程启动：等待调用方退出（最多 15 分钟）
```

- 每 0.5 秒刷新：倒计时、旋转指示、npm 输出都会即时更新，不用自己 tail 日志。
- 窗口是**独立可见控制台**（WMI + ShowWindow=1），**关掉 OpenCode 不会带走它**；守护进程本身用 ShowWindow=0 隐藏，不额外弹黑窗。
  结束时播放提示音并弹窗（成功/未执行/失败 + 原因 + 日志路径）。
- 进度数据写入 `progress.json`（阶段、百分比、剩余秒数、6 个步骤状态、日志尾部）；窗口只是只读消费者，不会改变升级结果。
- 不想开窗口：`-Detach -NoWatch`。想看但没开：随时单独运行 watch 脚本。
- 复盘时窗口打开即终态，默认不弹窗（避免每次查看历史都挡一个模态框）；要弹窗加 `-Notify`。
  这种情况下窗口会停留等你按回车再关闭（`-Quiet` 除外），不会一闪而过。
- 进度条用 ASCII `#`/`-`、步骤用 `+ > . x !`：中文 Windows 控制台的 GBK 代码页会把 `█ ✔ ▶` 显示成 `?`。

```powershell
# 围观正在进行的升级（或事后看最近一次结果）
pwsh -NoProfile -File "<skill-dir>/scripts/watch-opencode-update.ps1"

# 排查用：只渲染一帧到 stdout，不开窗口
pwsh -NoProfile -File "<skill-dir>/scripts/watch-opencode-update.ps1" -Snapshot
```

### 2. 普通终端、opencode 已关闭

```powershell
pwsh -NoProfile -File "<skill-dir>/scripts/update-opencode.ps1"
```

有进程占用时直接拒绝（exit 2）并列出占用者，不会硬闯。

### 参数

| 参数 | 作用 | 默认 |
| --- | --- | --- |
| `-DryRun` | 只探测并打印计划，绝不安装 | off |
| `-Force` | 结束占用进程；**在 TUI 内会被拒绝**（会杀掉自己） | off |
| `-WaitMinutes N` | 布防后等你退出 TUI 的预算 | 15 |
| `-DrainMinutes N` | 退出后等定时任务 run 跑完的预算 | 15 |
| `-Restart` | 升级完自动打开 opencode | off |
| `-NoWatch` | 不自动打开进度窗口 | off |

watch 脚本参数：

| 参数 | 作用 | 默认 |
| --- | --- | --- |
| `-Snapshot` | 渲染一帧到 stdout 后退出；无状态时最多等 3 秒（测试/排查） | off |
| `-Quiet` | 结束时不响铃、不弹窗 | off |
| `-Notify` | 即使打开时已是终态也弹窗（复盘用） | off |
| `-KeepOpen` | 结束后等回车再关闭 | off |
| `-WaitForStartSeconds N` | 还没有进度文件时最多等多久（`-Snapshot` 同样遵守） | 60 |

### 退出码

| 码 | 含义 |
| --- | --- |
| 0 | 成功，或已布防 |
| 1 | 出错（npm 失败、版本不一致、exe 缺失、布防失败） |
| 2 | 前置条件不满足（进程占用、锁冲突、等待超时） |

## 结果在哪看

- 进度窗口：`-Detach` 自动打开；也可手动运行 watch 脚本（见 1.1）
- `%LOCALAPPDATA%\opencode-update\progress.json`：实时进度（阶段、百分比、剩余秒数、步骤状态、日志尾部）。
  升级结束后仍保留最后一次状态，可直接用 `-Snapshot` 复盘
- `%LOCALAPPDATA%\opencode-update\latest.log`：本次或最近一次升级的完整过程，**运行中实时追加**；
  每次真实运行开始时清空重写（`-DryRun` 完全不碰它，不会覆盖上一次真实记录）
- `%LOCALAPPDATA%\opencode-update\latest-result.json`：`status` 取值
  `armed` / `running` / `success` / `blocked` / `failed` / `armed-failed`，
  以及 `from` / `to` / `expected`
  （`armed` 表示守护进程已在排队，此时 `ok=false` 属正常）
- `-DryRun` 只写 `latest-dryrun.json`，不会覆盖上一次真实升级的 result，也不写 `progress.json`
  （历史日志仍在 `update-*.log`）
- 失败时带上 `latest.log` 内容再排查

## 执行前提醒

1. 有其他 opencode 进程在跑（`Get-Process opencode`）时，守护进程会先等它们结束；等不到就放弃，不会掐断。
2. 如果有定时用 `opencode run` 拉起的任务（日报、选题、抓取之类），升级可能撞上某一轮：
   npm 安装期间 shim 短暂缺失，那一轮就会失败。守护进程会先等 run 跑完，但重试间隔短的任务仍可能在
   安装的几十秒里被拉起。这不是硬禁止 —— 先确认这个任务被打断后能否安全补跑；能补跑就直接升级，
   补跑前按任务自己的幂等规则确认是否已经执行过，避免重复提交。
3. 先跑 `-DryRun` 是廉价保险。

## 升级后验收

```powershell
opencode --version                                   # 新版本号
Test-Path "<npm prefix>\opencode.cmd"                # True = shim 已重建
opencode run --standalone "只回复 ok"                 # headless + 插件能否加载
```

`<npm prefix>` 就是 `npm config get prefix --location=global` 的输出（通常是 `%APPDATA%\npm`），
脚本的 `latest-result.json` 里也会带上实际版本供对照。

第三条能提前暴露插件/API 不兼容，而不是等到定时任务跑起来才发现。

## 验证状态（2026-11-10，作者本机）

已实测（全部使用隔离的 `-LogPath` / 临时前缀，不碰真实安装）：

- 语法解析：两个脚本均 0 error
- 进度窗口渲染（合成状态）：阶段行、进度条百分比、倒计时、6 步清单、日志尾部；成功 / 未执行 / 失败三种
  终态的文案与原因；无数据分支；快照退出码 0（成功）/ 1（失败）/ 2（未执行）/ 5（无数据或失联）
- `-Detach -NoWatch -WaitMinutes 1`（真实环境）：生成 `progress.json`（`phase=wait-tui`、`percent=8`、
  6 阶段、`remaining≈60`、tail 非空、`pid` = 守护进程），`latest.log` 运行中实时追加，`-Snapshot` 能渲染真实进度
- `-Detach`（默认开窗）：WMI 起独立进度窗口，父进程不是当前 shell；桌面顶层窗口枚举确认 `visible=True`、
  标题为 `OpenCode 升级进度`，关闭后窗口消失；守护进程用 `ShowWindow=0`，不额外弹窗
- 守护进程超时链路：60 秒内 TUI 未退出 → `blocked / tui still running`，progress 的 wait-tui 标记 blocked，
  锁释放，快照显示“未执行”
- 成功路径离线验证（桩 `npm.cmd` + 真实 exe 副本 + 临时前缀）：exit 0，`progress=success/100%`、全部阶段
  done、`latest.log` 含安装输出
- 失败路径：npm 返回 1 → exit 1，`progress=failed`，install 阶段标记 failed
- 前台占用：exit 2，`progress=blocked`（`opencode.exe in use`），未执行 npm
- dry-run：`-DryRun` exit 2 且不写 `progress.json`、不改 `latest.log`；`-Detach -DryRun` 只打印将启动命令、
  不写 progress、无残留锁
- 失联判定：progress 的 pid 不存在、20 秒无更新且锁无人持有 → 显示“进程已退出”（exit 5）；
  pid 存活或锁持有者存活时不误判
- 锁忙：预置活 PID 的 `update.lock` → 守护进程 exit 2，且**不覆盖**在跑流程的 `progress.json` /
  `latest-result.json`（逐字节比对未变）
- 可见性：`-Detach` 后枚举桌面顶层窗口，确认存在 `visible=True`、标题为 `OpenCode 升级进度` 的窗口；
  关闭后窗口消失。`ShowWindow` 对照实验：0=隐藏（窗口存在但不可见），1=可见
- 查看器主循环：先写 running、2 秒后改 success → 查看器自动退出（exit 0）并渲染出 100% / 升级成功，
  stderr 为空（`-Quiet`，不弹框）

未实测：

- 真实环境“退出 TUI → npm 安装 → 版本变化”的完整成功链路（需要真的开着 TUI 退出，无法在会话内自证）
- 真实 TUI 退出后进度窗口继续存活（窗口由 WMI 创建、父进程不是 TUI，逻辑上成立，但没法在会话内真退一次）
- 真实 npm 失败（网络/权限）与 postinstall 被全局策略跳过这两种现场
- 进度窗口在 200% DPI / 极小窗口下的排版（代码做了宽度裁剪与行数上限，但没做视觉回归）

换设备后建议先跑一次 `-DryRun`，确认解析到的 npm 前缀、exe 路径与进程列表符合预期，再正式布防。

## 已知边界

- 只适用于 **npm 全局安装**（`%APPDATA%\npm\node_modules\@opencode\cli`）。前缀通过
  `npm config get prefix --location=global` 解析，避免被项目目录的 `.npmrc` 带偏；不是 npm 安装时脚本
  会直接报“找不到 exe”。
- 该包的 postinstall 负责把平台二进制拷进 `bin\opencode.exe`；脚本装完会比对该包的
  `package.json` 版本与 `opencode --version`，不一致或 exe 缺失都按失败处理。
- 同一时刻只允许一个升级流程（`update.lock`），并发会把 `node_modules` 删坏。
  锁持有者仍存活时一律不接管；只有 PID 不存在，或锁的 `at` 超过 6 小时才强制接管（防 PID 复用）。
- `-Detach -Force` 会跳过“别杀自己祖宗”的保护，代价是可能中断等待期间新起的定时任务；不确定就别带 `-Force`。
- `-Detach` 模式下 `-Restart` 拉起的窗口可能不可见；升级完成后手动打开最稳。
- 进度窗口是独立控制台进程，依赖 `pwsh`（没有则退回 `powershell`）；结束弹窗可能被全屏应用遮挡，
  结果始终以 `latest-result.json` / `progress.json` / `latest.log` 为准。
- 进度窗口只读 `progress.json`，不参与锁和安装；关掉它不会影响升级，重新运行即可继续围观。
