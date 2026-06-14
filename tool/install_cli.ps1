param()

$ErrorActionPreference = 'Stop'

$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$BuildRoot = if ($env:PICAKEEP_BUILD_DIR) { $env:PICAKEEP_BUILD_DIR } else { Join-Path $RepoRoot 'build\cli' }
$InstallRoot = if ($env:PICAKEEP_INSTALL_ROOT) { $env:PICAKEEP_INSTALL_ROOT } else { Join-Path $env:LOCALAPPDATA 'PicaKeepCLI' }
$BinDir = if ($env:PICAKEEP_BIN_DIR) { $env:PICAKEEP_BIN_DIR } else { Join-Path $InstallRoot 'bin' }
$LauncherCmd = Join-Path $BinDir 'picakeep.cmd'
$LauncherPs1 = Join-Path $BinDir 'picakeep.ps1'
$MetaPath = Join-Path $BuildRoot 'build.meta'
$VersionPath = Join-Path $BuildRoot 'picakeep.version'

& (Join-Path $RepoRoot 'tool\build_cli.ps1')
if ($LASTEXITCODE -ne 0) {
  exit $LASTEXITCODE
}

New-Item -ItemType Directory -Force -Path $BinDir, $InstallRoot | Out-Null

function Copy-WebConsoleAssets {
  $assetSrc = Join-Path $RepoRoot 'assets\web_console'
  $assetDest = Join-Path $InstallRoot 'assets\web_console'
  if (-not (Test-Path $assetSrc)) {
    Write-Warning "[install_cli] web console assets not found: $assetSrc"
    return
  }
  Remove-Item -Recurse -Force -ErrorAction SilentlyContinue $assetDest
  New-Item -ItemType Directory -Force -Path (Split-Path -Parent $assetDest) | Out-Null
  Copy-Item -Recurse -Force $assetSrc $assetDest
}

function Copy-VersionFile {
  if (Test-Path $VersionPath) {
    Copy-Item -Force $VersionPath (Join-Path $InstallRoot 'picakeep.version')
  }
}

$Mode = 'dart-run'
$Target = 'bin\picakeep.dart'
if (Test-Path $MetaPath) {
  Get-Content $MetaPath | ForEach-Object {
    if ($_ -match '^MODE=(.*)$') { $script:Mode = $Matches[1] }
    if ($_ -match '^TARGET=(.*)$') { $script:Target = $Matches[1] }
  }
}

switch ($Mode) {
  'native' {
    $nativeInstallRoot = Join-Path $InstallRoot 'native'
    Remove-Item -Recurse -Force -ErrorAction SilentlyContinue $nativeInstallRoot
    if (Test-Path (Join-Path $BuildRoot 'native')) {
      Copy-Item -Recurse -Force (Join-Path $BuildRoot 'native') $nativeInstallRoot
      $installedTarget = Join-Path $InstallRoot (Join-Path 'native' ($Target -replace '^native[\\/]', ''))
    } else {
      $installedTarget = Join-Path $InstallRoot 'picakeep-native.exe'
      Copy-Item -Force (Join-Path $BuildRoot $Target) $installedTarget
    }

    Set-Content -Encoding ASCII -Path $LauncherCmd -Value @"
@echo off
"$installedTarget" %*
"@

    $installedTargetForPs1 = $installedTarget.Replace("'", "''")
    Set-Content -Encoding UTF8 -Path $LauncherPs1 -Value @"
& '$installedTargetForPs1' @args
exit `$LASTEXITCODE
"@
  }
  default {
    Set-Content -Encoding ASCII -Path $LauncherCmd -Value @"
@echo off
cd /d "$RepoRoot"
dart run bin/picakeep.dart %*
"@

    $repoForPs1 = $RepoRoot.Replace("'", "''")
    Set-Content -Encoding UTF8 -Path $LauncherPs1 -Value @"
Set-Location '$repoForPs1'
& dart run bin/picakeep.dart @args
exit `$LASTEXITCODE
"@
  }
}

Copy-WebConsoleAssets
Copy-VersionFile

Write-Host "[install_cli] installed launcher: $LauncherCmd"
Write-Host "[install_cli] installed PowerShell launcher: $LauncherPs1"
if ($Mode -eq 'native') {
  Write-Host '[install_cli] install mode: native'
  Write-Host "[install_cli] runtime root: $InstallRoot"
} else {
  Write-Host '[install_cli] install mode: dart-run fallback'
  Write-Host "[install_cli] source checkout required: $RepoRoot"
}

$userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
$pathParts = @()
if ($userPath) {
  $pathParts = $userPath.Split(';') | Where-Object { $_ }
}
$alreadyInPath = $pathParts | Where-Object { $_.TrimEnd('\') -ieq $BinDir.TrimEnd('\') }
if ($alreadyInPath) {
  Write-Host "[install_cli] user PATH already contains $BinDir"
} else {
  $newUserPath = if ($userPath) { "$userPath;$BinDir" } else { $BinDir }
  [Environment]::SetEnvironmentVariable('Path', $newUserPath, 'User')
  Write-Host "[install_cli] added to user PATH: $BinDir"
  Write-Host '[install_cli] open a new terminal to use picakeep directly'
}

$currentPathParts = $env:Path.Split(';') | Where-Object { $_ }
$currentAlreadyInPath = $currentPathParts | Where-Object { $_.TrimEnd('\') -ieq $BinDir.TrimEnd('\') }
if (-not $currentAlreadyInPath) {
  $env:Path = "$BinDir;$env:Path"
  Write-Host "[install_cli] added to this install process PATH: $BinDir"
  Write-Host '[install_cli] if the parent terminal still cannot find picakeep, run:'
  Write-Host "  `$env:Path = '$BinDir;' + `$env:Path"
}

Write-Host '[install_cli] verify with:'
Write-Host '  Get-Command picakeep'
Write-Host '  picakeep -h'
Write-Host '  picakeep -v'