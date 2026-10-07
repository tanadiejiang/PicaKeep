param(
    [Parameter(Mandatory=$true)][string]$Device,
    [Parameter(Mandatory=$true)][string]$RunId,
    [Parameter(Mandatory=$true)][string]$ReportName
)
$ErrorActionPreference = 'Stop'
if ($RunId -notmatch '^\d{4}-\d{2}-\d{2}T[0-9-]+Z$' -or
    $ReportName -notmatch '^reader-[a-z0-9-]+\.json$') {
    throw 'Only an explicit benchmark run and report basename are accepted.'
}
$repoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$destination = Join-Path $repoRoot "docs\verification\image-pipeline-022\$ReportName"
$sourcePath = "/data/user/0/lingxue.picakeep/files/image-pipeline-022-profile/$RunId/profile-results.json"
$start = [Diagnostics.ProcessStartInfo]::new()
$start.FileName = 'E:\SDK\platform-tools-latest-windows\platform-tools\adb.exe'
$start.UseShellExecute = $false
$start.RedirectStandardOutput = $true
$start.RedirectStandardError = $true
foreach ($argument in @('-s',$Device,'exec-out','run-as','lingxue.picakeep','cat',$sourcePath)) {
    $start.ArgumentList.Add($argument)
}
$process = [Diagnostics.Process]::Start($start)
$memory = [IO.MemoryStream]::new()
try {
    $process.StandardOutput.BaseStream.CopyTo($memory)
    $errorText = $process.StandardError.ReadToEnd()
    $process.WaitForExit()
    if ($process.ExitCode -ne 0) { throw "Task report could not be read: $errorText" }
    $bytes = $memory.ToArray()
    $parsed = [Text.Encoding]::UTF8.GetString($bytes) | ConvertFrom-Json
    if ($parsed.runId -ne $RunId) { throw 'Report run identity differs from requested benchmark.' }
    [IO.File]::WriteAllBytes($destination, $bytes)
    Write-Output "Saved task report $destination ($($bytes.Length) bytes)."
} finally {
    $memory.Dispose()
    $process.Dispose()
}
