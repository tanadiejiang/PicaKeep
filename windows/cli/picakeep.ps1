# PicaKeep Windows CLI 启动器(由 picakeep.cmd 调用)。
# 复用安装目录上一层的 GUI 二进制 picakeep.exe 的 --server 模式(能读资源、不弹窗),
# 与 Linux 的 picakeep wrapper 体验一致:server / stop / status / logs / 无参开 GUI。
param([Parameter(ValueFromRemainingArguments=$true)] [string[]] $Args)

$ErrorActionPreference = 'SilentlyContinue'
$AppExe   = Join-Path (Split-Path -Parent $PSScriptRoot) 'picakeep.exe'  # {app}\picakeep.exe
$Port     = 9527
$StateDir = Join-Path $env:LOCALAPPDATA 'PicaKeep'
$PidFile  = Join-Path $StateDir 'server.pid'
$LogFile  = Join-Path $StateDir 'server.log'

function Get-ServerPid {
  if (Test-Path $PidFile) {
    $p = (Get-Content $PidFile -ErrorAction SilentlyContinue | Select-Object -First 1)
    if ($p -and (Get-Process -Id $p -ErrorAction SilentlyContinue)) { return [int]$p }
  }
  return $null
}

function Get-PortPid {
  $c = Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue | Select-Object -First 1
  if ($c) { return [int]$c.OwningProcess }
  $line = (netstat -ano | Select-String ":$Port\s+.*LISTENING" | Select-Object -First 1)
  if ($line) { return [int]($line.ToString() -split '\s+')[-1] }
  return $null
}

function Show-Urls {
  Write-Host "  本机:     http://127.0.0.1:$Port/admin-view"
  Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
    Where-Object { $_.IPAddress -notlike '127.*' -and $_.IPAddress -notlike '169.254.*' } |
    ForEach-Object { Write-Host "  局域网:   http://$($_.IPAddress):$Port/admin-view" }
}

function Show-Version {
  $ver = 'unknown'
  if (Test-Path $AppExe) {
    $vi = (Get-Item $AppExe -ErrorAction SilentlyContinue).VersionInfo
    if ($vi -and $vi.ProductVersion) { $ver = $vi.ProductVersion }
    elseif ($vi -and $vi.FileVersion) { $ver = $vi.FileVersion }
  }
  $os = (Get-CimInstance Win32_OperatingSystem -ErrorAction SilentlyContinue)
  $osName = if ($os) { "$($os.Caption) $($os.Version)" } else { [System.Environment]::OSVersion.VersionString }
  $arch = $env:PROCESSOR_ARCHITECTURE
  Write-Host "PicaKeep v$ver"
  Write-Host "  系统:     $osName ($arch)"
  Write-Host "  可执行:   $AppExe"
}

$cmd = if ($Args -and $Args.Count -gt 0) { $Args[0] } else { '' }

switch -Regex ($cmd) {
  '^(server|s|up|start)$' {
    $running = Get-ServerPid
    if (-not $running) { $running = Get-PortPid }
    if ($running) {
      Write-Host "PicaKeep 服务端已在运行 (PID $running)。"
      Show-Urls
      break
    }
    New-Item -ItemType Directory -Force -Path $StateDir | Out-Null
    $rest = if ($Args.Count -gt 1) { $Args[1..($Args.Count-1)] } else { @() }
    $p = Start-Process -FilePath $AppExe -ArgumentList (@('--server') + $rest) `
           -WindowStyle Hidden -PassThru
    Set-Content -Path $PidFile -Value $p.Id
    Start-Sleep -Seconds 1
    Write-Host "PicaKeep 服务端已在后台启动 (PID $($p.Id))。"
    Show-Urls
    Write-Host "  日志: picakeep logs    停止: picakeep stop"
  }
  '^(stop|x|down)$' {
    $target = Get-ServerPid
    if (-not $target) { $target = Get-PortPid }
    if ($target) {
      Stop-Process -Id $target -Force -ErrorAction SilentlyContinue
      Remove-Item $PidFile -ErrorAction SilentlyContinue
      Write-Host "已停止 PicaKeep 服务端 (PID $target)。"
    } else {
      Write-Host "PicaKeep 服务端未在运行。"
    }
  }
  '^(status|st)$' {
    $target = Get-ServerPid
    if ($target) {
      Write-Host "运行中 (PID $target),端口 $Port。"; Show-Urls
    } else {
      $target = Get-PortPid
      if ($target) {
        Write-Host "运行中 (PID $target,端口 $Port;PID 文件缺失,可 picakeep stop 停止)。"; Show-Urls
      } else {
        Write-Host "未运行。"
      }
    }
  }
  '^(logs|l|log)$' {
    if (Test-Path $LogFile) { Get-Content $LogFile -Tail 50 -Wait } else { Write-Host "暂无日志($LogFile)。" }
  }
  '^(version|-v|--version|-V)$' {
    Show-Version
  }
  '^--server$' {
    & $AppExe @Args
  }
  default {
    # 无子命令:直接打开 GUI(前台)。
    & $AppExe @Args
  }
}
