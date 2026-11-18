<#
.SYNOPSIS
  安全升级 Windows 上的 OpenCode（绕开“运行中的 exe 无法被覆盖”）。

.DESCRIPTION
  背景：`/update` 与 `opencode upgrade` 都在当前进程里执行
  `npm install -g --force @opencode/cli@<ver>`，要覆盖 bin\opencode.exe。
  Windows 不允许替换正在运行的 exe，而 TUI、`serve --service`、定时任务拉起的
  `opencode run` 都占着同一个文件，于是安装挂起、界面超时。

  本脚本把安装安排到“文件真的空闲”的时刻：
    -DryRun        只探测并打印计划，绝不安装
    -Detach        在 OpenCode 内调用：布防守护进程，等你退出 TUI 后自动完成
    -RunAfterExit  内部模式（守护进程使用）

  进度可视化：运行期间持续写 progress.json（阶段/百分比/倒计时/日志尾部），
  -Detach 会额外拉起 watch-opencode-update.ps1 的独立进度窗口，关掉 OpenCode 也还在。
  加 -NoWatch 可不开窗口。

  退出码：0 成功/已布防；1 出错；2 前置条件不满足（占用、锁冲突、等待超时）

.NOTES
  测试用注入：-NpmCmd / -NpmPrefix / -Exe / -LogPath 可覆盖默认解析，
  便于用桩程序离线验证成功与失败分支，不必碰真实安装。
#>
[CmdletBinding()]
param(
  [switch]$DryRun,
  [switch]$Force,
  [switch]$Detach,
  [switch]$RunAfterExit,
  [int]$WaitPid = 0,
  [int]$WaitMinutes = 15,
  [int]$DrainMinutes = 15,
  [string]$LogPath = '',
  [string]$NpmPrefix = '',
  [string]$NpmCmd = '',
  [string]$Exe = '',
  [switch]$Restart,
  [switch]$NoWatch,
  [string]$ProgressPath = '',
  [string]$ViewerScript = '',
  [string]$FromVersion = ''
)

$ErrorActionPreference = 'Stop'
$Package = '@opencode/cli'
$script:LockHeld = $false

# npm 必须走 npm.cmd：PowerShell 直接调 npm（npm.ps1 包装器）在捕获输出时会被解析坏。
if (-not $NpmCmd) { $NpmCmd = (Get-Command npm.cmd -ErrorAction SilentlyContinue | Select-Object -First 1).Source }
if (-not $NpmCmd -or -not (Test-Path $NpmCmd)) {
  Write-Host '找不到 npm.cmd，无法继续。'
  exit 1
}

function Resolve-NpmPrefix {
  if ($NpmPrefix) { return $NpmPrefix }
  # --location=global：避免项目目录下的 .npmrc 里 prefix= 把安装目标带偏
  $p = $null
  try { $p = (& $NpmCmd config get prefix --location=global 2>$null) } catch {}
  if (-not $p) { $p = Join-Path $env:APPDATA 'npm' }
  $p = ([string]$p).Trim()
  if ($p -notmatch '^[A-Za-z]:\\') { $p = Join-Path $env:APPDATA 'npm' }
  return $p
}

$NpmPrefix = Resolve-NpmPrefix
if (-not $Exe) { $Exe = Join-Path $NpmPrefix 'node_modules\@opencode\cli\bin\opencode.exe' }
$PkgJson = Join-Path $NpmPrefix 'node_modules\@opencode\cli\package.json'
$Shim = Join-Path $NpmPrefix 'opencode.cmd'

if (-not $LogPath) {
  $baseDir = Join-Path $env:LOCALAPPDATA 'opencode-update'
  if (-not (Test-Path $baseDir)) { New-Item -ItemType Directory -Path $baseDir -Force | Out-Null }
  $LogPath = Join-Path $baseDir ('update-{0}.log' -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
}
$LogDir = Split-Path -Parent $LogPath
if (-not (Test-Path $LogDir)) { New-Item -ItemType Directory -Path $LogDir -Force | Out-Null }
$LatestLog = Join-Path $LogDir 'latest.log'
$ResultPath = Join-Path $LogDir 'latest-result.json'
$DryRunResult = Join-Path $LogDir 'latest-dryrun.json'
$LockPath = Join-Path $LogDir 'update.lock'
if (-not $ProgressPath) { $ProgressPath = Join-Path $LogDir 'progress.json' }
if (-not $ViewerScript) {
  $skillRoot = $PSScriptRoot
  if (-not $skillRoot) { $skillRoot = Split-Path -Parent $PSCommandPath }
  $ViewerScript = Join-Path $skillRoot 'watch-opencode-update.ps1'
}

$script:Utf8NoBom = New-Object System.Text.UTF8Encoding($false)
$script:Tail = New-Object System.Collections.ArrayList
$script:StartedAt = Get-Date
$script:RunId = [IO.Path]::GetFileNameWithoutExtension($LogPath) -replace '^update-', ''
$script:FromVersion = $FromVersion
$script:ToVersion = ''
$script:ExpectedVersion = ''
$script:CurrentPhaseIndex = -1
$script:LastPhaseId = ''
$script:PhaseStartedAt = $script:StartedAt
$script:Phases = @(
  [pscustomobject]@{ id = 'preflight'; label = '检查环境并布防'; percent = 2; hint = '' }
  [pscustomobject]@{ id = 'wait-tui'; label = '等待退出 OpenCode'; percent = 8; hint = '退出 OpenCode 后本窗口会自动继续' }
  [pscustomobject]@{ id = 'drain'; label = '等待定时任务结束'; percent = 30; hint = '不掐断正在写日报/选题的 run' }
  [pscustomobject]@{ id = 'stop-service'; label = '停止后台服务'; percent = 50; hint = '' }
  [pscustomobject]@{ id = 'install'; label = 'npm 安装'; percent = 65; hint = '通常 30-90 秒' }
  [pscustomobject]@{ id = 'verify'; label = '校验版本'; percent = 92; hint = '' }
)

function Write-Log {
  param([string]$Message)
  $line = '[{0}] {1}' -f (Get-Date -Format 'HH:mm:ss'), $Message
  Write-Host $line
  [void]$script:Tail.Add($line)
  while ($script:Tail.Count -gt 10) { $script:Tail.RemoveAt(0) }
  # 日志绝不能成为中断升级的原因（父子同写一个文件时偶发共享冲突）：
  # 同时维护 latest.log，外部 tail 它也能实时看到，而不是只在结束时拷一次。
  # dry-run 不碰 latest.log，避免覆盖上一次真实升级的记录；
  # 没抢到锁的流程也不写，免得把“另一个升级在跑”混进对方日志。
  $targets = @($LogPath)
  if (-not $DryRun -and $script:LockHeld) { $targets += $LatestLog }
  foreach ($target in $targets) {
    for ($i = 0; $i -lt 3; $i++) {
      try { Add-Content -Path $target -Value $line -Encoding utf8 -ErrorAction Stop; break }
      catch { Start-Sleep -Milliseconds 30 }
    }
  }
}

function Get-PhaseIndex {
  param([string]$Id)
  for ($i = 0; $i -lt $script:Phases.Count; $i++) {
    if ($script:Phases[$i].id -eq $Id) { return $i }
  }
  return -1
}

# 写结构化进度（progress.json），供 watch-opencode-update.ps1 实时渲染。
# 失败绝不打断升级：进度只是观察面，不是控制流。
function Set-Progress {
  param(
    [string]$Phase = '',
    [string]$Status = 'running',
    [string]$Detail = '',
    [string]$Hint = '',
    [int]$Remaining = -1,
    [string]$From = '',
    [string]$To = '',
    [string]$Expected = '',
    [string]$Reason = ''
  )
  if ($DryRun) { return }

  $now = Get-Date
  $idx = $script:CurrentPhaseIndex
  if ($Phase) { $idx = Get-PhaseIndex $Phase }
  if ($idx -lt 0) { $idx = 0 }
  $script:CurrentPhaseIndex = $idx

  $id = $script:Phases[$idx].id
  if ($id -ne $script:LastPhaseId) {
    $script:LastPhaseId = $id
    $script:PhaseStartedAt = $now
  }

  if ($From) { $script:FromVersion = $From }
  if ($To) { $script:ToVersion = $To }
  if ($Expected) { $script:ExpectedVersion = $Expected }
  if (-not $Hint) { $Hint = $script:Phases[$idx].hint }

  $percent = [int]$script:Phases[$idx].percent
  if ($Status -eq 'success') { $percent = 100 }

  $states = @()
  for ($i = 0; $i -lt $script:Phases.Count; $i++) {
    $state = 'pending'
    if ($Status -eq 'success') { $state = 'done' }
    elseif ($i -lt $idx) { $state = 'done' }
    elseif ($i -eq $idx) {
      if ($Status -eq 'failed') { $state = 'failed' }
      elseif ($Status -eq 'blocked' -or $Status -eq 'armed-failed') { $state = 'blocked' }
      else { $state = 'active' }
    }
    $states += [ordered]@{ id = $script:Phases[$i].id; label = $script:Phases[$i].label; state = $state }
  }

  $payload = [ordered]@{
    runId            = $script:RunId
    pid              = $PID
    status           = $Status
    phase            = $id
    phaseIndex       = ($idx + 1)
    phaseTotal       = $script:Phases.Count
    percent          = $percent
    label            = [string]$script:Phases[$idx].label
    detail           = $Detail
    hint             = $Hint
    from             = $script:FromVersion
    to               = $script:ToVersion
    expected         = $script:ExpectedVersion
    reason           = $Reason
    startedAt        = $script:StartedAt.ToString('o')
    phaseStartedAt   = $script:PhaseStartedAt.ToString('o')
    updatedAt        = $now.ToString('o')
    remainingSeconds = $Remaining
    log              = $LogPath
    phases           = $states
    tail             = @($script:Tail)
  }

  $json = $null
  try { $json = $payload | ConvertTo-Json -Depth 6 } catch {}
  if ($json) { [void](Write-JsonAtomic -Path $ProgressPath -Json $json) }
}

# 原子写 JSON：先写本进程专属 tmp，再替换目标；读方（500ms 轮询）不会读到半截文件。
function Write-JsonAtomic {
  param([string]$Path, [string]$Json)
  $tmp = '{0}.{1}.tmp' -f $Path, $PID
  try {
    [IO.File]::WriteAllText($tmp, $Json, $script:Utf8NoBom)
    for ($i = 0; $i -lt 5; $i++) {
      try { Move-Item -Path $tmp -Destination $Path -Force -ErrorAction Stop; return $true }
      catch {
        if ($i -eq 4) {
          # 目标被读者短暂占用时退化为直接覆盖；损坏的中间态由查看器忽略
          try {
            [IO.File]::WriteAllText($Path, $Json, $script:Utf8NoBom)
            try { Remove-Item $tmp -Force -ErrorAction SilentlyContinue } catch {}
            return $true
          } catch {}
        } else { Start-Sleep -Milliseconds 40 }
      }
    }
  } catch {}
  try { if (Test-Path $tmp) { Remove-Item $tmp -Force -ErrorAction SilentlyContinue } } catch {}
  return $false
}

function Set-Result {
  param([string]$Status, [string]$From = '', [string]$To = '', [string]$Expected = '', [string]$Reason = '')
  $payload = [ordered]@{
    ok       = ($Status -eq 'success')
    status   = $Status
    from     = $From
    to       = $To
    expected = $Expected
    reason   = $Reason
    at       = (Get-Date).ToString('o')
    log      = $LogPath
  }
  $target = $ResultPath
  if ($DryRun) { $target = $DryRunResult }
  $json = $null
  try { $json = $payload | ConvertTo-Json -Depth 4 } catch {}
  if ($json) { [void](Write-JsonAtomic -Path $target -Json $json) }
}

# 用 WMI 创建进程：OpenCode 可能用 Job Object 管理子进程，Start-Process 起的进程
# 会随 TUI 退出一起被杀。ShowWindow=0 让守护进程不弹黑窗，1 让进度窗口正常可见。
function Invoke-ProcessCreate {
  param([string]$CommandLine, [int]$ShowWindow = 1)
  try {
    $startupClass = Get-CimClass -ClassName Win32_ProcessStartup -ErrorAction Stop
    $startup = New-CimInstance -CimClass $startupClass -ClientOnly
    $startup.ShowWindow = $ShowWindow
    return Invoke-CimMethod -ClassName Win32_Process -MethodName Create -Arguments @{
      CommandLine              = $CommandLine
      ProcessStartupInformation = $startup
    }
  } catch {
    Write-Log "带窗口参数启动失败（$($_.Exception.Message)），退回默认启动"
    return Invoke-CimMethod -ClassName Win32_Process -MethodName Create -Arguments @{ CommandLine = $CommandLine }
  }
}

# 另开一个独立控制台窗口显示进度：用 WMI 创建，父进程不是 TUI，
# 因此关掉 OpenCode 不会把进度窗口一起带走。
function Start-ProgressViewer {
  param([string]$PwshPath)
  if ($DryRun -or $NoWatch) { return 0 }
  if (-not (Test-Path $ViewerScript)) {
    Write-Log "未找到进度窗口脚本（$ViewerScript），跳过可视化"
    return 0
  }
  $argv = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $ViewerScript,
    '-ProgressPath', $ProgressPath, '-ResultPath', $ResultPath, '-LockPath', $LockPath)
  $cmdLine = '"' + $PwshPath + '" ' + (($argv | ForEach-Object { Quote-Arg $_ }) -join ' ')
  $viewerPid = 0
  try {
    $r = Invoke-ProcessCreate -CommandLine $cmdLine -ShowWindow 1
    if ($r.ReturnValue -eq 0) { $viewerPid = [int]$r.ProcessId }
    else { Write-Log "进度窗口启动失败（ReturnValue=$($r.ReturnValue)），升级继续" }
  } catch {
    Write-Log "进度窗口启动异常：$($_.Exception.Message)，升级继续"
  }
  if ($viewerPid -le 0) { return 0 }
  # 只“创建成功”不够：脚本路径错/语法错时进程会秒退，这里再验一次存活
  Start-Sleep -Milliseconds 1200
  if (-not (Get-Process -Id $viewerPid -ErrorAction SilentlyContinue)) {
    Write-Log "进度窗口（PID $viewerPid）启动后立即退出；可手动运行：$ViewerScript"
    return 0
  }
  return $viewerPid
}

function Get-OcProcess {
  $all = Get-CimInstance Win32_Process -Filter "Name='opencode.exe'" -ErrorAction SilentlyContinue
  $escaped = [regex]::Escape($Exe)
  @($all | Where-Object {
      $_.ExecutablePath -eq $Exe -or
      (-not $_.ExecutablePath -and [string]$_.CommandLine -match $escaped)
    })
}

function Get-OcKind {
  param($Proc)
  $cmd = [string]$Proc.CommandLine
  $m = [regex]::Match($cmd, '^"[^"]+"\s*(.*)$')
  $rest = if ($m.Success) { $m.Groups[1].Value } else { ($cmd -replace '^\S+\s*', '') }
  $first = ''
  if ($rest.Trim()) { $first = ($rest.Trim() -split '\s+')[0] }
  if ($first -eq 'run') { return 'run' }
  if ($first -eq 'serve') { return 'service' }
  return 'tui'
}

function Get-AncestorOpencodePid {
  $cursor = $PID
  for ($i = 0; $i -lt 10; $i++) {
    $proc = Get-CimInstance Win32_Process -Filter "ProcessId=$cursor" -ErrorAction SilentlyContinue
    if (-not $proc) { return 0 }
    if ($proc.Name -eq 'opencode.exe' -and $proc.ExecutablePath -eq $Exe) { return [int]$proc.ProcessId }
    $cursor = [int]$proc.ParentProcessId
    if ($cursor -le 0) { return 0 }
  }
  return 0
}

function Test-ExeWritable {
  if (-not (Test-Path $Exe)) { return $false }
  try {
    $fs = [IO.File]::Open($Exe, 'Open', 'ReadWrite', 'None')
    $fs.Close()
    return $true
  } catch { return $false }
}

function Get-OcVersion {
  if (-not (Test-Path $Exe)) { return '' }
  try {
    $out = (& $Exe --version 2>$null | Out-String)
    $m = [regex]::Match($out, '(?m)^\s*v?(\d+\.\d+\.\d+)\s*$')
    if (-not $m.Success) { $m = [regex]::Match($out, '(\d+\.\d+\.\d+)') }
    if ($m.Success) { return $m.Groups[1].Value }
    return ''
  } catch { return '' }
}

function Get-PackageVersion {
  if (-not (Test-Path $PkgJson)) { return '' }
  try { return ([string](Get-Content $PkgJson -Raw -Encoding utf8 | ConvertFrom-Json).version).Trim() } catch { return '' }
}

function Get-VersionCore {
  param([string]$Value)
  $m = [regex]::Match([string]$Value, '^\d+\.\d+\.\d+')
  if ($m.Success) { return $m.Value }
  return ''
}

function Get-InstallProblem {
  param([string]$To, [string]$Expected)
  if (-not (Test-Path $Exe)) { return 'exe missing after install (postinstall skipped?)' }
  if (-not (Test-Path $Shim)) { return 'opencode.cmd shim missing' }
  if (-not $To) { return 'cannot read opencode --version' }
  if (-not $Expected) { return 'cannot read package.json version' }
  # 预发布版本（1.2.3-beta.1）只比前三段，避免恒判 mismatch
  if ((Get-VersionCore $To) -ne (Get-VersionCore $Expected)) {
    return "binary version mismatch (package=$Expected binary=$To)"
  }
  return ''
}

function Enter-Lock {
  param([int]$WaitSeconds = 0)
  $deadline = (Get-Date).AddSeconds($WaitSeconds)
  while ($true) {
    try {
      $fs = [IO.File]::Open($LockPath, 'CreateNew', 'Write', 'None')
      $json = @{ pid = $PID; at = (Get-Date).ToString('o') } | ConvertTo-Json
      $bytes = [Text.Encoding]::UTF8.GetBytes($json)
      $fs.Write($bytes, 0, $bytes.Length)
      $fs.Close()
      $script:LockHeld = $true
      return $true
    } catch [System.IO.IOException] {
      $holder = 0
      $lockAt = $null
      try {
        $info = Get-Content $LockPath -Raw -ErrorAction SilentlyContinue | ConvertFrom-Json
        $holder = [int]$info.pid
        if ($info.at) { $lockAt = [datetime]$info.at }
      } catch {}
      $live = ($holder -gt 0 -and [bool](Get-Process -Id $holder -ErrorAction SilentlyContinue))
      # PID 可能被无关进程复用；升级流程最长约 30 分钟，超过 6 小时才强制接管
      $tooOld = ($lockAt -and ((Get-Date) - $lockAt).TotalHours -gt 6)
      if ($live -and -not $tooOld) {
        if ((Get-Date) -ge $deadline) { return $false }
        Start-Sleep -Seconds 2
        continue
      }
      if ($tooOld) { Write-Log "发现过期锁（PID $holder，超过 6 小时），接管" }
      else { Write-Log "发现陈旧锁（PID $holder 已不在），接管" }
      try { Remove-Item $LockPath -Force -ErrorAction SilentlyContinue } catch {}
      if (Test-Path $LockPath) { Start-Sleep -Milliseconds 200 }
    }
  }
}

function Exit-Lock {
  if (-not $script:LockHeld) { return }
  try {
    $holder = [int]((Get-Content $LockPath -Raw -ErrorAction SilentlyContinue | ConvertFrom-Json).pid)
    if ($holder -eq $PID) { Remove-Item $LockPath -Force -ErrorAction SilentlyContinue }
  } catch {}
  $script:LockHeld = $false
}

function Wait-CallerExit {
  param([int]$AncestorPid, [int]$Minutes)
  $waitIds = @()
  if ($AncestorPid -gt 0) {
    $anc = Get-OcProcess | Where-Object { $_.ProcessId -eq $AncestorPid }
    if ($anc -and (Get-OcKind $anc) -ne 'service') { $waitIds += $AncestorPid }
  }
  $deadline = (Get-Date).AddMinutes($Minutes)
  while ((Get-Date) -lt $deadline) {
    $tuis = @(Get-OcProcess | Where-Object { (Get-OcKind $_) -eq 'tui' })
    $alive = @($waitIds | Where-Object { Get-Process -Id $_ -ErrorAction SilentlyContinue })
    if ($tuis.Count -eq 0 -and $alive.Count -eq 0) { return $true }
    $remain = [int][Math]::Max(0, ($deadline - (Get-Date)).TotalSeconds)
    $detail = if ($tuis.Count -gt 0) {
      'OpenCode 仍在运行（TUI PID ' + (($tuis | ForEach-Object { $_.ProcessId }) -join ',') + '）'
    } else { 'TUI 已退出，等待进程收尾' }
    Set-Progress -Phase 'wait-tui' -Detail $detail -Remaining $remain
    Start-Sleep -Seconds 3
  }
  return $false
}

function Wait-RunsDrained {
  param([int]$Minutes)
  $deadline = (Get-Date).AddMinutes($Minutes)
  while ((Get-Date) -lt $deadline) {
    $runs = @(Get-OcProcess | Where-Object { (Get-OcKind $_) -eq 'run' })
    if ($runs.Count -eq 0) { return $true }
    Write-Log ("还有 " + $runs.Count + " 个 run 在跑（定时任务），等待结束…")
    $remain = [int][Math]::Max(0, ($deadline - (Get-Date)).TotalSeconds)
    Set-Progress -Phase 'drain' -Detail ("还有 $($runs.Count) 个定时任务 run 在跑") -Remaining $remain
    Start-Sleep -Seconds 5
  }
  return $false
}

function Wait-AllGone {
  param([int]$Seconds = 60)
  $deadline = (Get-Date).AddSeconds($Seconds)
  while ((Get-Date) -lt $deadline) {
    $left = @(Get-OcProcess)
    if ($left.Count -eq 0) { return $true }
    $remain = [int][Math]::Max(0, ($deadline - (Get-Date)).TotalSeconds)
    Set-Progress -Phase 'stop-service' -Detail ("还有 $($left.Count) 个 opencode 进程未退出") -Remaining $remain
    Start-Sleep -Seconds 2
  }
  return (@(Get-OcProcess).Count -eq 0)
}

function Invoke-NpmInstall {
  $argv = @('install', '--global', '--force', "$Package@latest", "--allow-scripts=$Package")
  Write-Log ('npm ' + ($argv -join ' '))
  if ($DryRun) { Write-Log '  (dry-run: 不执行)'; return 0 }
  $out = & $NpmCmd @argv 2>&1
  $code = $LASTEXITCODE
  foreach ($line in $out) {
    Write-Log ('  ' + $line)
    Set-Progress -Phase 'install' -Detail ('npm: ' + ([string]$line).Trim())
  }
  if ($code -eq 0) { return 0 }
  $text = ($out | Out-String)
  if ($text -match 'allow-scripts|Unknown argument|unknown option') {
    Write-Log 'npm 不支持 --allow-scripts，去掉该参数重试一次'
    $argv = @('install', '--global', '--force', "$Package@latest")
    Write-Log ('npm ' + ($argv -join ' '))
    $out = & $NpmCmd @argv 2>&1
    $code = $LASTEXITCODE
    foreach ($line in $out) {
      Write-Log ('  ' + $line)
      Set-Progress -Phase 'install' -Detail ('npm: ' + ([string]$line).Trim())
    }
    if ($code -eq 0) { return 0 }
  }
  return 1
}

function Quote-Arg {
  param([string]$Value)
  if ($Value -notmatch '[\s"]') { return $Value }
  $v = $Value -replace '(\\*)"', '$1$1\"'
  $v = $v -replace '(\\+)$', '$1$1'
  return '"' + $v + '"'
}

function Finish {
  param([string]$Status, [string]$From, [string]$To, [string]$Expected, [string]$Reason)
  if ($Status -eq 'success' -and -not $Reason -and $From -and $From -eq $To) { $Reason = 'already latest' }
  if ($Status -eq 'success') {
    $suffix = ''
    if ($Reason) { $suffix = "（$Reason）" }
    Write-Log "升级完成：$From → $To$suffix"
  } elseif ($Reason) {
    Write-Log "结束（$Status）：$Reason"
  }
  Set-Result -Status $Status -From $From -To $To -Expected $Expected -Reason $Reason
  Set-Progress -Status $Status -From $From -To $To -Expected $Expected -Reason $Reason
}

# ================================================================ 守护进程模式
if ($RunAfterExit) {
  # 窗口是隐藏的，未处理异常必须落到日志与 result，否则外面只能看到永久 running
  trap {
    try { Write-Log ("守护进程未处理异常：" + $_.Exception.Message) } catch {}
    try { Finish -Status 'failed' -From (Get-OcVersion) -Reason ('unhandled error: ' + $_.Exception.Message) } catch {}
    try { Exit-Lock } catch {}
    exit 1
  }
  if (-not (Enter-Lock -WaitSeconds 20)) {
    # 另一个升级流程正持锁：绝不能覆盖它的 result/progress，否则围观窗口会看到假状态
    Write-Log '另一个升级流程正在运行，退出'
    exit 2
  }
  try {
    # 先进度、后做慢操作：查看器靠 pid 判活，pid 必须尽早切成守护进程本身，
    # 否则前台退出后的空窗会被误判成“进程已退出”
    Set-Progress -Phase 'wait-tui' -Status 'running' -From $script:FromVersion `
      -Detail '守护进程已接管，准备等待 TUI 退出' -Remaining ($WaitMinutes * 60)
    Set-Result -Status 'running' -From $script:FromVersion -Reason 'detached updater started'
    $from = Get-OcVersion
    if (-not $from) { $from = $script:FromVersion }
    Write-Log "守护进程启动：等待调用方退出（最多 $WaitMinutes 分钟）"
    if ($from) {
      Set-Progress -Phase 'wait-tui' -From $from -Status 'running' `
        -Detail '等待 TUI 退出' -Remaining ($WaitMinutes * 60)
    }
    if (-not (Wait-CallerExit -AncestorPid $WaitPid -Minutes $WaitMinutes)) {
      Finish -Status 'blocked' -From $from -Reason 'tui still running'
      exit 2
    }

    # 先等无头任务跑完，再停服务——否则会掐断正在写日报/文章的 run
    Set-Progress -Phase 'drain' -Detail '检查是否有定时任务在跑' -Remaining ($DrainMinutes * 60)
    if (-not (Wait-RunsDrained -Minutes $DrainMinutes)) {
      Finish -Status 'blocked' -From $from -Reason 'run still active'
      exit 2
    }

    if (Test-Path $Exe) {
      Write-Log '停止后台服务：opencode service stop'
      Set-Progress -Phase 'stop-service' -Detail '执行 opencode service stop'
      if (-not $DryRun) {
        try { & $Exe service stop 2>&1 | ForEach-Object { Write-Log ('  ' + $_) } } catch { Write-Log ('  service stop 失败：' + $_.Exception.Message) }
      }
    }
    [void](Wait-AllGone -Seconds 60)

    $left = @(Get-OcProcess)
    if ($left.Count -gt 0 -and $Force) {
      foreach ($p in $left) { Write-Log "强制结束 PID $($p.ProcessId)"; if (-not $DryRun) { Stop-Process -Id $p.ProcessId -Force -ErrorAction SilentlyContinue } }
      Start-Sleep -Seconds 3
      $left = @(Get-OcProcess)
    }
    if ($left.Count -gt 0) {
      foreach ($p in $left) { Write-Log ("  占用中：PID $($p.ProcessId) [" + (Get-OcKind $p) + ']') }
      Finish -Status 'blocked' -From $from -Reason 'opencode.exe still in use'
      exit 2
    }

    if (-not $DryRun -and -not (Test-ExeWritable)) {
      Finish -Status 'blocked' -From $from -Reason 'exe not writable'
      exit 2
    }

    Write-Log "当前版本：$from"
    Set-Progress -Phase 'install' -From $from -Detail 'npm install -g --force @opencode/cli@latest'
    if ((Invoke-NpmInstall) -ne 0) {
      Finish -Status 'failed' -From $from -Reason 'npm install failed'
      exit 1
    }
    if ($DryRun) { Write-Log '(dry-run: 到此结束)'; exit 0 }

    Set-Progress -Phase 'verify' -Detail '读取 package.json 与 opencode --version'
    $expected = Get-PackageVersion
    $to = Get-OcVersion
    Write-Log "包版本=$expected，opencode --version=$to"
    $problem = Get-InstallProblem -To $to -Expected $expected
    if ($problem) {
      Finish -Status 'failed' -From $from -To $to -Expected $expected -Reason $problem
      Write-Log '提示：若 postinstall 被跳过，用 npm i -g @opencode/cli@latest --allow-scripts=@opencode/cli'
      exit 1
    }
    Finish -Status 'success' -From $from -To $to -Expected $expected
    if ($Restart) {
      Write-Log '尝试重新打开 opencode（detached 模式下窗口可能不可见）'
      Start-Process -FilePath $Exe -WorkingDirectory $env:USERPROFILE
    }
    exit 0
  } finally {
    Exit-Lock
  }
}

# ================================================================ 前台模式
if (-not (Enter-Lock)) {
  Write-Log '另一个升级流程正在运行（update.lock 活跃），退出'
  exit 2
}
try {
  # 每次真实运行重新开始 latest.log，避免把上一轮的行混进来
  if (-not $DryRun) { try { [IO.File]::WriteAllText($LatestLog, '', $script:Utf8NoBom) } catch {} }
  Write-Log "OpenCode 升级助手（dry-run=$DryRun force=$Force detach=$Detach）"
  Write-Log "包路径：$Exe"
  if (-not (Test-Path $Exe)) {
    Write-Log "找不到 $Exe —— 这台机器可能不是用 npm 全局安装的 OpenCode，本脚本不适用。"
    Finish -Status 'failed' -Reason 'opencode.exe not found'
    exit 1
  }

  $from = Get-OcVersion
  $procs = @(Get-OcProcess)
  $ancestor = Get-AncestorOpencodePid
  Write-Log "当前版本：$from"
  Write-Log ("检测到 " + $procs.Count + " 个 opencode 进程：")
  foreach ($p in $procs) {
    $cmd = [string]$p.CommandLine
    if ($cmd.Length -gt 90) { $cmd = $cmd.Substring(0, 90) + '…' }
    Write-Log ("  PID $($p.ProcessId) [" + (Get-OcKind $p) + "] $cmd")
  }
  Write-Log ("exe 可写：$(Test-ExeWritable)")
  Set-Progress -Phase 'preflight' -From $from -Detail ("检测到 $($procs.Count) 个 opencode 进程，exe 可写=$(Test-ExeWritable)")

  if ($Detach) {
    $pwshExe = (Get-Command pwsh -ErrorAction SilentlyContinue).Source
    if (-not $pwshExe) { $pwshExe = (Get-Command powershell).Source }
    $childArgs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $PSCommandPath,
      '-RunAfterExit', '-WaitPid', "$ancestor", '-WaitMinutes', "$WaitMinutes",
      '-DrainMinutes', "$DrainMinutes", '-LogPath', $LogPath, '-NpmPrefix', $NpmPrefix,
      '-NpmCmd', $NpmCmd, '-Exe', $Exe, '-ProgressPath', $ProgressPath,
      '-FromVersion', $from)
    if ($DryRun) { $childArgs += '-DryRun' }
    if ($Force) { $childArgs += '-Force' }
    if ($Restart) { $childArgs += '-Restart' }

    if ($DryRun) {
      $preview = ($childArgs | ForEach-Object { Quote-Arg $_ }) -join ' '
      Write-Log ("(dry-run) 将启动：$pwshExe " + $preview)
      Write-Log '布防后请退出 OpenCode，升级会自动完成。'
      Finish -Status 'armed' -From $from -Reason 'dry-run preview'
      exit 0
    }

    # 先写 armed，再交锁、再 spawn；子进程会把状态改成 running
    Set-Result -Status 'armed' -From $from -Reason 'helper starting'
    Set-Progress -Phase 'wait-tui' -Status 'armed' -From $from `
      -Detail '等待 TUI 退出' -Remaining ($WaitMinutes * 60)
    Exit-Lock

    # 用 WMI 创建进程：OpenCode 可能用 Job Object 管理子进程，
    # Start-Process 起的守护进程会随 TUI 退出一起被杀。ShowWindow=0 避免多一个黑窗。
    $cmdLine = '"' + $pwshExe + '" ' + (($childArgs | ForEach-Object { Quote-Arg $_ }) -join ' ')
    $childPid = 0
    try {
      $r = Invoke-ProcessCreate -CommandLine $cmdLine -ShowWindow 0
      if ($r.ReturnValue -eq 0) { $childPid = [int]$r.ProcessId }
      else { Write-Log "WMI 启动失败（ReturnValue=$($r.ReturnValue)）" }
    } catch {
      Write-Log "WMI 启动异常：$($_.Exception.Message)"
    }
    if ($childPid -le 0) {
      Write-Log '无法启动守护进程，布防失败。可改为：退出 OpenCode 后在普通终端运行本脚本（不带 -Detach）。'
      Finish -Status 'armed-failed' -From $from -Reason 'spawn failed'
      exit 1
    }

    Start-Sleep -Seconds 3
    $child = Get-Process -Id $childPid -ErrorAction SilentlyContinue
    if (-not $child) {
      Write-Log "守护进程（PID $childPid）启动后立即退出，布防失败。请看日志：$LogPath"
      Finish -Status 'armed-failed' -From $from -Reason 'helper exited early'
      exit 1
    }
    Write-Log "已布防（守护进程 PID $childPid）：退出 OpenCode 后自动升级"
    $viewerPid = Start-ProgressViewer -PwshPath $pwshExe
    if ($viewerPid -gt 0) {
      Write-Log "进度窗口已打开（PID $viewerPid）：关掉 OpenCode 后它仍在，实时显示每一步"
    } elseif (-not $NoWatch) {
      Write-Log "进度窗口未打开；可手动运行：$ViewerScript"
    } else {
      Write-Log '已禁用进度窗口（-NoWatch）'
    }
    Write-Log "请在 $WaitMinutes 分钟内退出，否则守护进程会放弃"
    # 这里绝不能再写 result/progress：守护进程可能已经接管，回写 armed 会制造假状态
    $cur = $null
    try { $cur = Get-Content $ResultPath -Raw -ErrorAction SilentlyContinue | ConvertFrom-Json } catch {}
    if ($cur) { Write-Log "守护进程当前状态：$($cur.status)" }
    exit 0
  }

  if ($procs.Count -gt 0) {
    if ($Force) {
      if ($ancestor -gt 0) {
        Write-Log "拒绝 -Force：当前脚本就运行在 opencode（PID $ancestor）内部，强杀会连带终止本流程。"
        Write-Log '请改用：-Detach（布防后退出 OpenCode），或退出后在普通终端重跑。'
        Finish -Status 'blocked' -From $from -Reason 'refuse to kill own ancestor'
        exit 2
      }
      foreach ($p in $procs) { Write-Log "强制结束 PID $($p.ProcessId)"; if (-not $DryRun) { Stop-Process -Id $p.ProcessId -Force -ErrorAction SilentlyContinue } }
      Start-Sleep -Seconds 3
    } else {
      Write-Log ''
      Write-Log '当前还有 opencode 进程在跑，原地覆盖会被文件锁挡住。三种做法：'
      Write-Log '  1) 在 OpenCode 里用 -Detach 布防，退出后自动升级'
      Write-Log '  2) 退出 TUI / 停服务后，在普通终端重跑本脚本'
      Write-Log '  3) 加 -Force 强制结束（会中断正在跑的 run）'
      Finish -Status 'blocked' -From $from -Reason 'opencode.exe in use'
      exit 2
    }
  }

  if (-not $DryRun -and -not (Test-ExeWritable)) {
    Write-Log 'exe 仍不可写，终止。'
    Finish -Status 'blocked' -From $from -Reason 'exe not writable'
    exit 2
  }

  Set-Progress -Phase 'install' -From $from -Detail 'npm install -g --force @opencode/cli@latest'
  if ((Invoke-NpmInstall) -ne 0) {
    Write-Log '升级失败：npm install 返回非 0'
    Finish -Status 'failed' -From $from -Reason 'npm install failed'
    exit 1
  }
  if ($DryRun) { Write-Log '(dry-run: 到此结束)'; exit 0 }

  Set-Progress -Phase 'verify' -Detail '读取 package.json 与 opencode --version'
  $expected = Get-PackageVersion
  $to = Get-OcVersion
  Write-Log "包版本=$expected，opencode --version=$to"
  $problem = Get-InstallProblem -To $to -Expected $expected
  if ($problem) {
    Finish -Status 'failed' -From $from -To $to -Expected $expected -Reason $problem
    Write-Log '提示：若 postinstall 被跳过，用 npm i -g @opencode/cli@latest --allow-scripts=@opencode/cli'
    exit 1
  }
  Finish -Status 'success' -From $from -To $to -Expected $expected
  Write-Log "日志：$LogPath"
  if ($Restart) { Start-Process -FilePath $Exe -WorkingDirectory $env:USERPROFILE }
  exit 0
} finally {
  Exit-Lock
}
