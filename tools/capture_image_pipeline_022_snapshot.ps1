param([string]$SnapshotRoot = 'C:\Users\tanad\.codex\tmp\picakeep-022-flutter-build')
$ErrorActionPreference = 'Stop'
$sourceRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$snapshotPath = [IO.Path]::GetFullPath($SnapshotRoot)
if ($snapshotPath -ne 'C:\Users\tanad\.codex\tmp\picakeep-022-flutter-build') {
    throw 'This verification helper only writes its dedicated snapshot directory.'
}
$files = & git -C $sourceRoot -c core.quotepath=false ls-files --cached --others --exclude-standard
if ($LASTEXITCODE -ne 0) { throw 'Cannot enumerate the current source snapshot.' }
$copied = 0
foreach ($relative in $files) {
    if ($relative -match '(^|/)(build|\.cxx|\.dart_tool|\.plugin_symlinks|ephemeral|\.git)(/|$)') { continue }
    $sourcePath = [IO.Path]::GetFullPath((Join-Path $sourceRoot $relative))
    $targetPath = [IO.Path]::GetFullPath((Join-Path $snapshotPath $relative))
    if (!$sourcePath.StartsWith($sourceRoot + '\') -or !$targetPath.StartsWith($snapshotPath + '\')) {
        throw 'A source path escaped the verification directories.'
    }
    if (!(Test-Path -LiteralPath $sourcePath -PathType Leaf)) { continue }
    $item = Get-Item -LiteralPath $sourcePath -Force
    if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { continue }
    if (Test-Path -LiteralPath $targetPath -PathType Leaf) {
        $existing = Get-Item -LiteralPath $targetPath -Force
        if (($existing.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw 'Refusing to overwrite a linked snapshot file.'
        }
        if ($existing.Length -eq $item.Length -and
            (Get-FileHash -LiteralPath $sourcePath -Algorithm SHA256).Hash -eq
            (Get-FileHash -LiteralPath $targetPath -Algorithm SHA256).Hash) { continue }
    }
    New-Item -ItemType Directory -Path ([IO.Path]::GetDirectoryName($targetPath)) -Force | Out-Null
    Copy-Item -LiteralPath $sourcePath -Destination $targetPath -Force
    $copied++
}
if (Test-Path -LiteralPath (Join-Path $sourceRoot 'android\local.properties')) {
    Copy-Item -LiteralPath (Join-Path $sourceRoot 'android\local.properties') -Destination (Join-Path $snapshotPath 'android\local.properties') -Force
}
Write-Output "Copied $copied regular source files to $snapshotPath; no directory links followed."
