<#
.SYNOPSIS
  OpenCode 升级进度窗口（只读，不会碰 opencode.exe）。

.DESCRIPTION
  每 0.5 秒读取一次 progress.json / latest-result.json，显示：
  当前阶段、进度条、倒计时、步骤清单、日志尾部；升级结束后播放提示音并弹窗。

  由 update-opencode.ps1 -Detach 自动拉起；也可以在任意终端手动运行，
  用于围观正在进行的升级，或事后查看最近一次结果。

.PARAMETER Snapshot
  渲染一帧到标准输出后退出，不开窗口、不弹窗（测试/排查用）。
  没有状态文件时最多等 3 秒，不会阻塞一分钟。

.PARAMETER Quiet
  结束时只更新画面，不播放提示音、不弹窗。

.PARAMETER KeepOpen
  结束时等待按回车再退出。

.PARAMETER WaitForStartSeconds
  还没检测到任何升级状态时，最多等待多少秒再放弃。

.EXAMPLE
  pwsh -NoProfile -File watch-opencode-update.ps1
#>
[CmdletBinding()]
param(
  [string]$ProgressPath = '',
  [string]$ResultPath = '',
  [string]$LockPath = '',
  [int]$RefreshMs = 500,
  [switch]$Snapshot,
  [switch]$Quiet,
  [switch]$KeepOpen,
  [switch]$Notify,
  [int]$WaitForStartSeconds = 60
)

$ErrorActionPreference = 'Stop'
$baseDir = Join-Path $env:LOCALAPPDATA 'opencode-update'
if (-not $ProgressPath) { $ProgressPath = Join-Path $baseDir 'progress.json' }
if (-not $ResultPath) { $ResultPath = Join-Path $baseDir 'latest-result.json' }
if (-not $LockPath) {
  # 兼容相对的 -ProgressPath：先转绝对路径，再取同目录的锁文件
  $progressFull = [IO.Path]::GetFullPath($ProgressPath)
  $LockPath = Join-Path (Split-Path -Parent $progressFull) 'update.lock'
}
$lockPath = $LockPath

$script:ReasonText = @{
  'tui still running'                   = 'OpenCode 没有在限期内退出'
  'run still active'                    = '定时任务仍在运行，超过等待预算'
  'opencode.exe still in use'           = 'opencode.exe 仍被其它进程占用'
  'exe not writable'                    = 'opencode.exe 仍不可写'
  'npm install failed'                  = 'npm install 返回非 0'
  'opencode.exe not found'              = '找不到 npm 安装的 opencode.exe'
  'already latest'                      = '已经是最新版本'
  'spawn failed'                        = '守护进程启动失败'
  'helper exited early'                 = '守护进程启动后立即退出'
  'helper starting'                     = '守护进程正在启动'
  'detached updater started'            = '守护进程已接管'
  'dry-run preview'                     = '仅预览，未安装'
}

$script:StatusText = @{
  armed        = '已布防'
  running      = '进行中'
  success      = '升级成功'
  blocked      = '未执行'
  failed       = '升级失败'
  'armed-failed' = '布防失败'
  stale        = '进程已退出'
  none         = '等待启动'
}

$script:PhaseState = @{
  done    = @{ Symbol = '+'; Color = 'Green' }
  active  = @{ Symbol = '>'; Color = 'Yellow' }
  pending = @{ Symbol = '.'; Color = 'DarkGray' }
  failed  = @{ Symbol = 'x'; Color = 'Red' }
  blocked = @{ Symbol = '!'; Color = 'Yellow' }
}

function Read-JsonFile {  param([string]$Path)
  try {
    if (-not (Test-Path $Path)) { return $null }
    $raw = [IO.File]::ReadAllText($Path, [Text.Encoding]::UTF8)
    if (-not $raw.Trim()) { return $null }
    return ($raw | ConvertFrom-Json)
  } catch { return $null }
}

function Get-WideWidth {
  param([string]$Text)
  $w = 0
  foreach ($ch in $Text.ToCharArray()) {
    $c = [int][char]$ch
    if (($c -ge 0x1100 -and $c -le 0x115F) -or
        ($c -ge 0x2E80 -and $c -le 0xA4CF) -or
        ($c -ge 0xAC00 -and $c -le 0xD7A3) -or
        ($c -ge 0xF900 -and $c -le 0xFAFF) -or
        ($c -ge 0xFE30 -and $c -le 0xFE4F) -or
        ($c -ge 0xFF00 -and $c -le 0xFF60) -or
        ($c -ge 0xFFE0 -and $c -le 0xFFE6)) { $w += 2 } else { $w += 1 }
  }
  return $w
}

function Format-Clip {
  param([string]$Text, [int]$Max)
  if ($Max -lt 4) { return '' }
  $sb = New-Object System.Text.StringBuilder
  $w = 0
  foreach ($ch in ([string]$Text).ToCharArray()) {
    $cw = if ($ch -match '[\u1100-\u115F\u2E80-\uA4CF\uAC00-\uD7A3\uF900-\uFAFF\uFE30-\uFE4F\uFF00-\uFF60\uFFE0-\uFFE6]') { 2 } else { 1 }
    if ($w + $cw -gt $Max) { return ($sb.ToString() + '…') }
    [void]$sb.Append($ch)
    $w += $cw
  }
  return $sb.ToString()
}

function Format-Duration {
  param([double]$Seconds)
  if ($Seconds -lt 0) { $Seconds = 0 }
  $ts = [TimeSpan]::FromSeconds($Seconds)
  if ($ts.TotalHours -ge 1) { return ('{0:00}:{1:00}:{2:00}' -f [int]$ts.TotalHours, $ts.Minutes, $ts.Seconds) }
  return ('{0:00}:{1:00}' -f $ts.Minutes, $ts.Seconds)
}

function Get-StatusText {
  param([string]$Status)
  if ($script:StatusText.ContainsKey($Status)) { return $script:StatusText[$Status] }
  return $Status
}

function Get-ReasonText {
  param([string]$Reason)
  if (-not $Reason) { return '' }
  if ($script:ReasonText.ContainsKey($Reason)) { return $script:ReasonText[$Reason] }
  return $Reason
}

function New-Frame {
  param($Progress, $Result, [int]$Width, [int]$Height, [int]$Tick, [datetime]$Now, [bool]$Stale = $false)

  $lines = New-Object System.Collections.Generic.List[object]
  $add = {
    param([string]$Text, [string]$Color = '')
    [void]$lines.Add([pscustomobject]@{ Text = $Text; Color = $Color })
  }

  $hrWidth = [Math]::Max(20, [Math]::Min($Width - 2, 76))
  $hr = '-' * $hrWidth

  $status = 'none'
  if ($Progress -and $Progress.status) { $status = [string]$Progress.status }
  elseif ($Result -and $Result.status) { $status = [string]$Result.status }
  if ($Stale) { $status = 'stale' }
  $terminal = @('success', 'blocked', 'failed', 'armed-failed', 'stale') -contains $status

  $startedAt = $null
  if ($Progress -and $Progress.startedAt) { $startedAt = [datetime]$Progress.startedAt }
  elseif ($Result -and $Result.at) { $startedAt = [datetime]$Result.at }
  $elapsed = ''
  if ($startedAt) { $elapsed = '已用时 ' + (Format-Duration ($Now - $startedAt).TotalSeconds) }

  $title = 'OpenCode 升级进度'
  if ($elapsed) { $add.Invoke(("{0}    {1}" -f $title, $elapsed), 'Cyan') } else { $add.Invoke($title, 'Cyan') }
  $add.Invoke($hr, 'DarkGray')

  $from = ''; $to = ''
  if ($Progress) { $from = [string]$Progress.from; $to = [string]$Progress.to }
  if (-not $from -and $Result) { $from = [string]$Result.from }
  if (-not $to -and $Result) { $to = [string]$Result.to }
  $version = ''
  if ($from -and $to) { $version = "$from → $to" }
  elseif ($from) { $version = "$from → （处理中）" }
  if ($version) { $add.Invoke('  版本：' + $version, '') }

  if ($status -eq 'none') {
    $add.Invoke('', '')
    $add.Invoke('  等待升级流程启动…', 'Yellow')
    $add.Invoke('  监听：' + (Format-Clip $ProgressPath ([Math]::Max(20, $Width - 10))), 'DarkGray')
    if ($Result) {
      $add.Invoke('  上一次：' + (Get-StatusText ([string]$Result.status)) + ' · ' + (Get-ReasonText ([string]$Result.reason)), 'DarkGray')
    }
    return $lines
  }

  # ---- 阶段 / 进度条 ----
  $pct = 0
  if ($Progress -and $null -ne $Progress.percent) { $pct = [int]$Progress.percent }
  elseif ($terminal -and $status -eq 'success') { $pct = 100 }
  if ($pct -lt 0) { $pct = 0 }
  if ($pct -gt 100) { $pct = 100 }

  $barWidth = [Math]::Max(12, [Math]::Min(36, $Width - 32))
  $filled = [int][Math]::Round($barWidth * $pct / 100.0)
  if ($filled -gt $barWidth) { $filled = $barWidth }
  $bar = '[' + ('#' * $filled) + ('-' * ($barWidth - $filled)) + ']'
  $barColor = 'Cyan'
  if ($status -eq 'success') { $barColor = 'Green' }
  elseif ($status -eq 'failed' -or $status -eq 'armed-failed') { $barColor = 'Red' }
  elseif ($status -eq 'blocked') { $barColor = 'Yellow' }
  elseif ($status -eq 'stale') { $barColor = 'DarkYellow' }

  if ($terminal) {
    $add.Invoke(("  {0} {1,3}%   {2}" -f $bar, $pct, (Get-StatusText $status)), $barColor)
  } else {
    $spin = '|/-\'[$Tick % 4]
    $label = ''
    if ($Progress -and $Progress.label) { $label = [string]$Progress.label }
    $phaseInfo = ''
    if ($Progress -and $Progress.phaseIndex) { $phaseInfo = ("阶段 {0}/{1} · " -f [int]$Progress.phaseIndex, [int]$Progress.phaseTotal) }
    $add.Invoke(("  {0} {1,3}%   {2}{3}  {4}" -f $bar, $pct, $phaseInfo, $label, $spin), $barColor)
  }

  $detail = ''
  if ($Progress -and $Progress.detail) { $detail = [string]$Progress.detail }
  if ($Stale) { $detail = '升级进程已退出，进度停止更新；请查看日志确认发生了什么' }
  if ($detail) { $add.Invoke('  现在：' + (Format-Clip $detail ([Math]::Max(24, $Width - 8))), '') }

  if (-not $terminal) {
    $hint = ''
    if ($Progress -and $Progress.hint) { $hint = [string]$Progress.hint }
    if ($hint) { $add.Invoke('  提示：' + (Format-Clip $hint ([Math]::Max(24, $Width - 8))), 'DarkGray') }
  } else {
    $reason = ''
    if ($Progress -and $Progress.reason) { $reason = [string]$Progress.reason }
    elseif ($Result -and $Result.reason) { $reason = [string]$Result.reason }
    if ($reason) {
      $reasonColor = if ($status -eq 'success') { 'DarkGray' } else { 'Yellow' }
      $add.Invoke('  原因：' + (Format-Clip (Get-ReasonText $reason) ([Math]::Max(24, $Width - 8))), $reasonColor)
    }
  }

  # ---- 倒计时 ----
  if (-not $terminal -and $Progress -and $null -ne $Progress.remainingSeconds) {
    $rem = [double]$Progress.remainingSeconds
    try { $rem -= ($Now - [datetime]$Progress.updatedAt).TotalSeconds } catch {}
    if ($rem -ge 0) {
      $remColor = if ($rem -lt 60) { 'Yellow' } else { 'DarkGray' }
      $add.Invoke('  预算剩余 ' + (Format-Duration $rem), $remColor)
    }
  }
  if (-not $terminal -and $Progress -and $Progress.phaseStartedAt) {
    try {
      $phaseElapsed = ($Now - [datetime]$Progress.phaseStartedAt).TotalSeconds
      $add.Invoke('  本阶段已用 ' + (Format-Duration $phaseElapsed), 'DarkGray')
    } catch {}
  }

  # ---- 步骤清单 ----
  $phases = @()
  if ($Progress -and $Progress.phases) { $phases = @($Progress.phases) }
  if ($phases.Count -gt 0) {
    $add.Invoke('', '')
    $add.Invoke('  步骤', 'DarkGray')
    $i = 0
    foreach ($ph in $phases) {
      $i++
      $state = 'pending'
      if ($ph.state) { $state = [string]$ph.state }
      $meta = $script:PhaseState[$state]
      if (-not $meta) { $meta = $script:PhaseState['pending'] }
      $mark = "  {0} {1} {2}" -f $meta.Symbol, $i, $ph.label
      if ($state -eq 'active' -and -not $terminal) { $mark += '   ←' }
      $add.Invoke($mark, $meta.Color)
    }
  }

  # ---- 日志尾部 ----
  $tail = @()
  if ($Progress -and $Progress.tail) { $tail = @($Progress.tail) }
  if ($tail.Count -gt 0) {
    $add.Invoke('', '')
    $add.Invoke('  最近日志', 'DarkGray')
    $maxLines = [Math]::Max(2, [Math]::Min(6, $Height - $lines.Count - 3))
    foreach ($t in ($tail | Select-Object -Last $maxLines)) {
      $add.Invoke('  ' + (Format-Clip ([string]$t) ([Math]::Max(20, $Width - 6))), 'DarkGray')
    }
  }

  if ($terminal) {
    $add.Invoke('', '')
    if ($status -eq 'success') {
      $add.Invoke('  升级完成，可以重新打开 OpenCode 了；本窗口可关闭。', 'Green')
    } elseif ($status -eq 'stale') {
      $add.Invoke('  升级进程已不在，结果未知；请查看日志后再决定是否重新布防。', 'Yellow')
    } else {
      $add.Invoke('  未完成升级，OpenCode 仍是原版本；本窗口可关闭。', 'Yellow')
    }
  }

  return $lines
}

function Show-Frame {
  param($Lines, [int]$Width, [int]$Height)
  try { [Console]::SetCursorPosition(0, 0) } catch { try { Clear-Host } catch {} }
  $max = [Math]::Max(6, $Height - 1)
  $count = [Math]::Min($Lines.Count, $max)
  for ($i = 0; $i -lt $count; $i++) {
    $line = $Lines[$i]
    $pad = $Width - 1 - (Get-WideWidth $line.Text)
    if ($pad -lt 0) { $pad = 0 }
    $text = $line.Text + (' ' * $pad)
    if ($line.Color) { Write-Host $text -NoNewline -ForegroundColor $line.Color }
    else { Write-Host $text -NoNewline }
    Write-Host ''
  }
  for ($i = $count; $i -lt $max; $i++) { Write-Host (' ' * ($Width - 1)) }
}

function Show-FinalNotice {
  param([string]$Status, [string]$Text, [string]$LogPath)
  if ($script:Quiet) { return }
  try { [System.Media.SystemSounds]::Asterisk.Play() } catch {}
  $icon = 'Information'
  if ($Status -eq 'failed' -or $Status -eq 'armed-failed') {
    $icon = 'Error'
    try { [System.Media.SystemSounds]::Hand.Play() } catch {}
  } elseif ($Status -eq 'blocked' -or $Status -eq 'stale') {
    $icon = 'Warning'
    try { [System.Media.SystemSounds]::Exclamation.Play() } catch {}
  }
  try {
    Add-Type -AssemblyName System.Windows.Forms
    $body = $Text + "`n`n日志：$LogPath"
    [void][System.Windows.Forms.MessageBox]::Show($body, 'OpenCode 升级', 'OK', $icon)
  } catch {}
}

# ---------------------------------------------------------------- 主循环
$lastProgress = $null
$waitSeconds = $WaitForStartSeconds
# 快照是“立刻给我一帧”，别因为没状态就干等一分钟
if ($Snapshot -and $waitSeconds -gt 3) { $waitSeconds = 3 }
$waitDeadline = (Get-Date).AddSeconds([Math]::Max(0, $waitSeconds))
$tick = 0
$finalStatus = 'none'
$firstFrame = $true
$firstFrameTerminal = $false

if (-not $Snapshot) {
  try { [Console]::Title = 'OpenCode 升级进度' } catch {}
  try { [Console]::CursorVisible = $false } catch {}
  try { [Console]::Clear() } catch { try { Clear-Host } catch {} }
}

while ($true) {
  $fresh = Read-JsonFile $ProgressPath
  if ($fresh) { $lastProgress = $fresh }
  $progress = $lastProgress
  $result = Read-JsonFile $ResultPath

  $status = 'none'
  if ($progress -and $progress.status) { $status = [string]$progress.status }
  elseif ($result -and $result.status) { $status = [string]$result.status }
  $terminal = @('success', 'blocked', 'failed', 'armed-failed') -contains $status

  # -Snapshot 也遵守“等升级启动”的语义，否则它永远只输出“等待启动”
  if ($Snapshot -and -not $progress -and -not $result -and (Get-Date) -lt $waitDeadline) {
    Start-Sleep -Milliseconds 200
    continue
  }

  # 守护进程被杀/异常退出时，进度文件会停在“进行中”；用 PID + 更新时间判定失联。
  # 锁持有者仍存活时不算失联（守护进程可能正在 Enter-Lock 或冷启动）。
  $now = Get-Date
  $stale = $false
  if (-not $terminal -and $progress -and $progress.pid) {
    $age = 0.0
    try { $age = ($now - [datetime]$progress.updatedAt).TotalSeconds } catch {}
    $alive = [bool](Get-Process -Id ([int]$progress.pid) -ErrorAction SilentlyContinue)
    $lockAlive = $false
    if (-not $alive) {
      try {
        $lockRaw = [IO.File]::ReadAllText($lockPath, [Text.Encoding]::UTF8)
        $lockPid = [int](($lockRaw | ConvertFrom-Json).pid)
        if ($lockPid -gt 0) { $lockAlive = [bool](Get-Process -Id $lockPid -ErrorAction SilentlyContinue) }
      } catch {}
    }
    if (-not $alive -and -not $lockAlive -and $age -gt 20) { $stale = $true }
  }
  if ($stale) {
    $status = 'stale'
    $terminal = $true
  }

  $width = 84
  $height = 28
  try { if ([Console]::WindowWidth -gt 30) { $width = [Console]::WindowWidth } } catch {}
  try { if ([Console]::WindowHeight -gt 10) { $height = [Console]::WindowHeight } } catch {}
  if ($width -lt 50) { $width = 50 }

  $frame = New-Frame -Progress $progress -Result $result -Width $width -Height $height -Tick $tick -Now $now -Stale $stale

  if ($Snapshot) {
    $frame | ForEach-Object { $_.Text }
    $code = 0
    if ($status -eq 'failed' -or $status -eq 'armed-failed') { $code = 1 }
    elseif ($status -eq 'blocked') { $code = 2 }
    elseif ($status -eq 'none' -or $status -eq 'stale') { $code = 5 }
    exit $code
  }

  Show-Frame -Lines $frame -Width $width -Height $height

  if ($terminal) {
    $finalStatus = $status
    if ($firstFrame) { $firstFrameTerminal = $true }
    $summary = (Get-StatusText $status)
    if ($progress -and $progress.from -and $progress.to) { $summary += ": $($progress.from) → $($progress.to)" }
    elseif ($result -and $result.from -and $result.to) { $summary += ": $($result.from) → $($result.to)" }
    $reason = ''
    if ($progress -and $progress.reason) { $reason = [string]$progress.reason }
    elseif ($result -and $result.reason) { $reason = [string]$result.reason }
    if ($reason) { $summary += "`n" + (Get-ReasonText $reason) }
    $logPath = ''
    if ($progress -and $progress.log) { $logPath = [string]$progress.log }
    elseif ($result -and $result.log) { $logPath = [string]$result.log }
    if (-not $firstFrame -or $Notify) {
      Show-FinalNotice -Status $status -Text $summary -LogPath $logPath
    }
    break
  }

  if (-not $progress -and (Get-Date) -ge $waitDeadline) {
    Write-Host ''
    Write-Host "未检测到升级流程（$ProgressPath 不存在）。" -ForegroundColor Yellow
    $finalStatus = 'none'
    break
  }

  $tick++
  $firstFrame = $false
  Start-Sleep -Milliseconds ([Math]::Max(120, $RefreshMs))
}

if (-not $Snapshot) {
  try { [Console]::CursorVisible = $true } catch {}
  # 复盘（打开即终态）时不弹窗，但别让窗口一闪而过
  if ($script:KeepOpen -or ($firstFrameTerminal -and -not $Quiet -and -not $Notify)) {
    Write-Host ''
    Read-Host '按回车关闭窗口' | Out-Null
  }
}

$code = 0
if ($finalStatus -eq 'failed' -or $finalStatus -eq 'armed-failed') { $code = 1 }
elseif ($finalStatus -eq 'blocked') { $code = 2 }
elseif ($finalStatus -eq 'none' -or $finalStatus -eq 'stale') { $code = 5 }
exit $code
