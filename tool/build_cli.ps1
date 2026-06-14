param()

$ErrorActionPreference = 'Stop'

$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$BuildRoot = if ($env:PICAKEEP_BUILD_DIR) { $env:PICAKEEP_BUILD_DIR } else { Join-Path $RepoRoot 'build\cli' }
$NativeRoot = Join-Path $BuildRoot 'native'
$CompiledBinary = Join-Path $BuildRoot 'picakeep-native.exe'
$LauncherCmd = Join-Path $BuildRoot 'picakeep.cmd'
$LauncherPs1 = Join-Path $BuildRoot 'picakeep.ps1'
$MetaPath = Join-Path $BuildRoot 'build.meta'
$LogPath = Join-Path $BuildRoot 'build.log'
$VersionPath = Join-Path $BuildRoot 'picakeep.version'
$PackageVersion = (Get-Content (Join-Path $RepoRoot 'pubspec.yaml') |
  Where-Object { $_ -match '^\s*version:\s*(\S+)\s*$' } |
  ForEach-Object { $Matches[1] } |
  Select-Object -First 1)

New-Item -ItemType Directory -Force -Path $BuildRoot | Out-Null
Remove-Item -Recurse -Force -ErrorAction SilentlyContinue $NativeRoot
Remove-Item -Force -ErrorAction SilentlyContinue $CompiledBinary, $LauncherCmd, $LauncherPs1, $MetaPath, $LogPath, $VersionPath
New-Item -ItemType File -Force -Path $LogPath | Out-Null
Set-Content -Encoding ASCII -Path $VersionPath -Value $PackageVersion

function Write-Meta {
  param(
    [Parameter(Mandatory=$true)][string]$Mode,
    [Parameter(Mandatory=$true)][string]$Target
  )
  Set-Content -Encoding UTF8 -Path $MetaPath -Value @(
    "MODE=$Mode",
    "TARGET=$Target"
  )
}

function Copy-WebConsoleAssets {
  param([Parameter(Mandatory=$true)][string]$TargetDir)
  $assetSrc = Join-Path $RepoRoot 'assets\web_console'
  $assetDest = Join-Path $TargetDir 'assets\web_console'
  if (-not (Test-Path $assetSrc)) {
    Write-Warning "[build_cli] web console assets not found: $assetSrc"
    return
  }
  Remove-Item -Recurse -Force -ErrorAction SilentlyContinue $assetDest
  New-Item -ItemType Directory -Force -Path (Split-Path -Parent $assetDest) | Out-Null
  Copy-Item -Recurse -Force $assetSrc $assetDest
}

function Copy-VersionFile {
  param([Parameter(Mandatory=$true)][string]$TargetDir)
  New-Item -ItemType Directory -Force -Path $TargetDir | Out-Null
  $targetPath = Join-Path $TargetDir 'picakeep.version'
  if (-not (Test-Path $targetPath) -or (Resolve-Path $VersionPath).Path -ne (Resolve-Path $targetPath).Path) {
    Copy-Item -Force $VersionPath $targetPath
  }
}

function Convert-ToBuildRelativePath {
  param([Parameter(Mandatory=$true)][string]$Path)
  $root = (Resolve-Path $BuildRoot).Path.TrimEnd('\', '/')
  $full = (Resolve-Path $Path).Path
  if ($full.StartsWith($root, [System.StringComparison]::OrdinalIgnoreCase)) {
    return $full.Substring($root.Length).TrimStart('\', '/')
  }
  return $full
}

function Write-NativeLaunchers {
  param([Parameter(Mandatory=$true)][string]$NativeTarget)
  $targetForCmd = $NativeTarget -replace '/', '\'
  Set-Content -Encoding ASCII -Path $LauncherCmd -Value @"
@echo off
set "SCRIPT_DIR=%~dp0"
"%SCRIPT_DIR%$targetForCmd" %*
"@

  $targetForPs1 = $NativeTarget -replace '\\', '/'
  Set-Content -Encoding UTF8 -Path $LauncherPs1 -Value @"
`$ScriptDir = Split-Path -Parent `$MyInvocation.MyCommand.Path
`$Target = Join-Path `$ScriptDir '$targetForPs1'
& `$Target @args
exit `$LASTEXITCODE
"@

  Write-Meta -Mode 'native' -Target $NativeTarget
}

function Write-DartRunLaunchers {
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

  Write-Meta -Mode 'dart-run' -Target 'bin\picakeep.dart'
}

function Find-NativeBundleBinary {
  if (-not (Test-Path $NativeRoot)) {
    return $null
  }
  return Get-ChildItem -Path $NativeRoot -Recurse -File |
    Where-Object { $_.FullName -match '[\\/]bundle[\\/]bin[\\/][^\\/]+\.exe$' } |
    Select-Object -First 1
}

Write-Host "[build_cli] repo_root=$RepoRoot"
Write-Host "[build_cli] build_root=$BuildRoot"

& dart build cli --target bin/picakeep.dart --output $NativeRoot *>> $LogPath
if ($LASTEXITCODE -eq 0) {
  $nativeBinary = Find-NativeBundleBinary
  if ($nativeBinary) {
    $relativeTarget = Convert-ToBuildRelativePath $nativeBinary.FullName
    Copy-WebConsoleAssets $BuildRoot
    Copy-VersionFile $BuildRoot
    Write-NativeLaunchers $relativeTarget
    Write-Host '[build_cli] mode=native (dart build cli)'
    Write-Host "[build_cli] launcher=$LauncherCmd"
    exit 0
  }
}

& dart compile exe bin/picakeep.dart -o $CompiledBinary *>> $LogPath
if ($LASTEXITCODE -eq 0) {
  $relativeTarget = Convert-ToBuildRelativePath $CompiledBinary
  Copy-WebConsoleAssets $BuildRoot
  Copy-VersionFile $BuildRoot
  Write-NativeLaunchers $relativeTarget
  Write-Host '[build_cli] mode=native (dart compile exe)'
  Write-Host "[build_cli] launcher=$LauncherCmd"
  exit 0
}

& dart run bin/picakeep.dart -h *>> $LogPath
if ($LASTEXITCODE -eq 0) {
  Write-DartRunLaunchers
  Write-Host '[build_cli] mode=dart-run fallback'
  Write-Host "[build_cli] launcher=$LauncherCmd"
  Write-Host "[build_cli] build log: $LogPath"
  exit 0
}

Write-Error "[build_cli] failed: native build unavailable and source CLI is not runnable. Inspect log: $LogPath"
exit 1