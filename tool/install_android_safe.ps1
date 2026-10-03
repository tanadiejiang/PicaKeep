<#
.SYNOPSIS
    安全地把 PicaKeep 装到 Android 设备上 —— **保留应用数据**。

.DESCRIPTION
    ## 为什么需要这个脚本

    用 `flutter run` 装到**有数据的设备**上是有风险的：一旦安装失败
    （最常见是空间不足），Flutter 工具会打印

        Uninstalling old version...

    然后**卸载应用**再装。Android 卸载会连应用私有目录一起删掉，而 PicaKeep 的
    默认下载根目录正是私有目录：

        /data/user/0/lingxue.picakeep/files/download

    里面装着 `download.db`（下载记录/收藏元数据）与**已下载的漫画本体**。
    实测发生过一次：profile APK 65.8 MB（三 ABI 的 fat 包）+ 设备空间不足
    → 安装失败 → 自动卸载 → 手机上已下载内容全部丢失且无法恢复。

    ## 这个脚本做了什么

    1. **打单 ABI 的 *非 split* 包**（`--target-platform android-arm64`）。
       看似反直觉：`--split-per-abi` 更小（43.9 MB vs 47.0 MB），但它会让
       **versionCode 带上 ABI 偏移**（实测 arm64-v8a = 基准 + 2000），而 IDE 的
       Run / `flutter run` 装的是**不含偏移**的包。两者交替使用必然降级，
       而降级会让 `flutter run` 卸载重装。省 3 MB 不值得担这个风险。
    2. **构建前 `flutter clean`**：Flutter 的 profile **增量 AOT 重编译**会产出
       未裁剪的 `libapp.so`，让产物虚胖。实测同一 commit 的 arm64 profile 包：
       clean 后 43.8 MB，改一行代码后增量构建 **62.5 MB（+19 MB）**，
       无源码变化的增量构建才复用回 43.8 MB。开发时几乎每次构建都有源码变化，
       所以这里默认走干净构建 —— 包越大越容易装不下。
    3. **`adb install -r` 覆盖安装**：`-r` 保留应用数据。
    4. **安装前检查设备可用空间**，不够就提前停下并提示清理，
       而不是等到安装失败后由工具去卸载。
    5. **安装前检查版本号降级**，并打印设备上当前的 versionCode。见下面第 3 条陷阱。
    6. **失败绝不自动卸载**：`-r` 失败时脚本只报错退出，由人决定下一步，
       不会出现"工具替你删数据"。

    ## 两条会把应用数据清空的失败路径（都已实测发生过）

    Flutter 工具在 **`adb install -r` 失败且应用已安装**时会**无条件卸载重装**
    （`flutter_tools` 的 `AndroidDevice.installApp`：打印 `Uninstalling old
    version...` → `adb uninstall` → 再装）。它不询问用户，也不区分失败原因。
    触发过两次：

    - **空间不足**：`INSTALL_FAILED_INSUFFICIENT_STORAGE`（fat 包 65.8 MB 那次）；
    - **版本号降级**：`INSTALL_FAILED_VERSION_DOWNGRADE`。Android 要求
      versionCode 单调不减，而本项目的 `version: x.y.z+N` 长期写死 `+1`
      （1.9.71 → 1.9.84 一直是 `+1`），versionName 在前缀递增。
      只要设备上装过任何 versionCode > 1 的包，之后所有 `+1` 的构建都会降级。

    两条路径的共同后果：应用私有目录（含默认下载根目录
    `/data/user/0/lingxue.picakeep/files/download` 里的 `download.db` 与已下载
    漫画）被递归删除，Android 不走回收站，**不可恢复**。

.PARAMETER Mode
构建模式：profile（默认，性能剖面用）/ debug。release 已禁止。

.PARAMETER Device
    目标设备序列号。省略时自动选择唯一在线的设备；多台在线会要求显式指定。

.PARAMETER MinFreeMb
    安装前要求的最小可用空间（MB），默认 600。空间低于该值直接停下。

.PARAMETER SkipClean
    跳过构建前的 `flutter clean`。**默认不跳过。** Flutter 的 profile 增量 AOT
    重编译会产出未裁剪的 `libapp.so`：实测同一 commit 的 arm64 profile 包，
    clean 后 43.8 MB，改一行代码后增量构建变成 62.5 MB（+19 MB），只有源码
    没变时增量构建才复用回 43.8 MB。开发时几乎每次构建前都改过代码，因此默认
    用干净构建换体积。只在明确不需要时（例如连续多次构建且空间充裕）才加这个开关。

.PARAMETER AppId
    目标应用包名，默认 `lingxue.picakeep`。用于读取设备上已装包的 versionCode
    以预判降级。

.EXAMPLE
    pwsh tool\install_android_safe.ps1
    以 profile 模式 + arm64 构建并覆盖安装到唯一在线的设备。

.EXAMPLE
    # release 模式已禁止；只能使用 -Mode debug 或 -Mode profile
#>
[CmdletBinding()]
param(
[ValidateSet('profile', 'debug')]
    [string]$Mode = 'profile',

    [string]$Device = '',

    [int]$MinFreeMb = 600,

    [switch]$SkipClean,

    [string]$AppId = 'lingxue.picakeep'
)

$ErrorActionPreference = 'Stop'

function Write-Step($text) { Write-Host "==> $text" -ForegroundColor Cyan }
function Write-Warn($text) { Write-Host "!!  $text" -ForegroundColor Yellow }
function Write-Fail($text) { Write-Host "xx  $text" -ForegroundColor Red }

# ── 1. 选设备 ────────────────────────────────────────────────────────────────
Write-Step '检查 adb 设备'
$rawDevices = & adb devices 2>&1
$serials = @(
    $rawDevices |
        Select-Object -Skip 1 |
        Where-Object { $_ -match '\sdevice$' } |
        ForEach-Object { ($_ -split '\s+')[0].Trim() } |
        Where-Object { $_ }
)

if ($serials.Count -eq 0) {
    Write-Fail '没有在线设备。请先连接（USB 或 adb connect <ip:port>）。'
    exit 1
}

if ($Device) {
    if ($serials -notcontains $Device) {
        Write-Fail "指定设备不在线：$Device。当前在线：$($serials -join ', ')"
        exit 1
    }
    $serial = $Device
} elseif ($serials.Count -eq 1) {
    $serial = $serials[0]
} else {
    Write-Fail "有多台设备在线，请用 -Device 指定：$($serials -join ', ')"
    exit 1
}
Write-Host "    目标设备：$serial"

# ── 2. 空间预检（避免走到"安装失败"那一步）──────────────────────────────────
Write-Step "检查设备可用空间（要求 >= ${MinFreeMb} MB）"
# 用不带参数的 `df` 全量输出：Android 上 `df /data` 在部分设备会返回**包含**
# /data 的那个挂载点（实测本机返回的是 /apex/... 而非 /data），
# 靠路径参数挑选不可靠，只能按"挂载点列 == /data"来找。
$dfOut = & adb -s $serial shell df 2>&1
$availableMb = $null
foreach ($line in $dfOut) {
    # 列：Filesystem 1K-blocks Used Available Use% Mounted-on
    $parts = @(($line -split '\s+') | Where-Object { $_ })
    if ($parts.Count -ge 6 -and $parts[-1] -eq '/data') {
        $kb = 0
        if ([int64]::TryParse($parts[-3], [ref]$kb)) {
            $availableMb = [math]::Round($kb / 1024, 0)
        }
        break
    }
}
if ($null -eq $availableMb) {
    Write-Warn '无法解析 /data 可用空间，跳过预检（继续安装）。'
} elseif ($availableMb -lt $MinFreeMb) {
    Write-Fail "可用空间仅 ${availableMb} MB，低于 ${MinFreeMb} MB。"
    Write-Fail '请先清理空间再装 —— 若硬装，安装可能失败并触发卸载，导致应用数据丢失。'
    exit 1
} else {
    Write-Host "    可用空间：${availableMb} MB（足够）"
}

# ── 3. 构建（单 ABI fat 包，与 IDE 的 Run 保持同一个 versionCode）───────────
# **刻意不用 `--split-per-abi`。**
#
# 分 ABI 会让 versionCode 带上 ABI 偏移（实测 arm64-v8a = 基准 + 2000），
# 而 IDE 的 Run / `flutter run` 装的是**不含偏移**的包。两者交替使用就会触发
# INSTALL_FAILED_VERSION_DOWNGRADE —— 那正是 `flutter run` 会**卸载重装**的
# 失败之一（应用私有数据连带被清空）。
#
# 正确做法是 `--target-platform android-arm64`：只打一个 ABI（体积与 IDE 几乎
# 相同），但**不引入 versionCode 偏移**。实测（均已 clean）：
#
#   build apk --target-platform android-arm64   47.0 MB   versionCode = N
#   build apk --split-per-abi (arm64)           43.9 MB   versionCode = N + 2000
#   build apk（不打任何限制，三 ABI fat）      111.2 MB   versionCode = N
#   flutter run（IDE 的 Run）                   47.6 MB   versionCode = N
#
# ⚠️ `--target-platform` **必须配 clean 使用**：增量构建会复用上一次三 ABI 的
# 中间产物，体积仍是 111 MB（这一点曾让我误判"该参数无效"）。本脚本默认 clean，
# 所以没这个问题；用 `-SkipClean` 时请自己留意体积。
Write-Step "构建 APK：$Mode / 单 ABI（与 IDE 同 versionCode）"

# **默认先 clean**：增量构建的 profile 产物会虚胖约 19 MB（未裁剪的 libapp.so），
# 而体积正是"空间不足 -> 安装失败 -> Flutter 自动卸载"链路的第一个条件。
# 实测同一 commit：clean 后 43.8 MB，增量构建 62.5 MB。
if ($SkipClean) {
    Write-Warn '已跳过 flutter clean（-SkipClean）：产物可能虚胖约 19 MB。'
} else {
    Write-Host '    清理旧产物（flutter clean），避免增量构建虚胖...'
    & flutter clean
    if ($LASTEXITCODE -ne 0) {
        Write-Fail "flutter clean 失败（exit $LASTEXITCODE）。"
        exit $LASTEXITCODE
    }
}

& flutter build apk "--$Mode" --target-platform android-arm64
if ($LASTEXITCODE -ne 0) {
    Write-Fail "构建失败（exit $LASTEXITCODE）。"
    exit $LASTEXITCODE
}

$apkDir = [System.IO.Path]::GetFullPath(
    (Join-Path $PSScriptRoot '..\build\app\outputs\flutter-apk')
)
$apk = Join-Path $apkDir "app-$Mode.apk"
if (-not (Test-Path $apk)) {
    Write-Fail "找不到产物（$apkDir\app-$Mode.apk）。"
    Write-Host '提示：若刚用过 --split-per-abi，build 目录里只有分 ABI 产物；'
    Write-Host '      本脚本刻意打单 ABI 的 *非 split* 包，以与 IDE 的 Run 保持'
    Write-Host '      同一个 versionCode（原因见脚本头部说明）。'
    exit 1
}
$sizeMb = [math]::Round((Get-Item $apk).Length / 1MB, 1)
Write-Host "    产物：$apk（${sizeMb} MB）"

# ── 4. 版本号预检（降级会让 adb install -r 直接失败）────────────────────────
# Android 要求 versionCode 单调不减。`pubspec.yaml` 的 `version: x.y.z+N` 里 N 就是
# versionCode，本项目长期写死 `+1`（1.9.71 → 1.9.84 一直是 +1），而 versionName
# 在前缀递增 —— 只要设备上装过任何 versionCode > 1 的包，之后 +1 的构建就装不上。
#
# 更糟的是 **`flutter run` 遇到这个失败会直接卸载重装**（见 flutter_tools 的
# `AndroidDevice.installApp`：覆盖安装失败且应用已安装 → 打印 "Uninstalling old
# version..." → uninstall + install），应用私有目录连带被清空。本脚本只报告不卸载。
Write-Step '检查版本号是否会导致降级'
$deviceVersionCode = $null
$packageDump = & adb -s $serial shell dumpsys package $AppId 2>&1
foreach ($line in $packageDump) {
    if ($line -match 'versionCode=(\d+)') {
        $deviceVersionCode = [int]$Matches[1]
        break
    }
}
if ($null -eq $deviceVersionCode) {
    Write-Host "    设备上未安装 $AppId，属全新安装，不存在降级问题。"
} else {
    Write-Host "    设备上当前 versionCode：$deviceVersionCode"
    Write-Host '    待装包的 versionCode 取自 pubspec.yaml 的 `+N`；'
    Write-Host '    若 N 小于上面的数字，本次安装会以 INSTALL_FAILED_VERSION_DOWNGRADE 失败。'
    Write-Host '    修法：把 pubspec.yaml 的 build number 提到不低于设备值，例如：'
    Write-Host "        version: <当前版本>+$($deviceVersionCode + 1)" -ForegroundColor Yellow
    Write-Host '    或临时给构建命令加 --build-number（IDE 的 Additional run args 亦可）。'
}

# ── 5. 覆盖安装（保留数据）──────────────────────────────────────────────────
Write-Step 'adb install -r（覆盖安装，保留应用数据）'
$installOutput = & adb -s $serial install -r $apk 2>&1
$installExit = $LASTEXITCODE
$installOutput | ForEach-Object { Write-Host "    $_" }

if ($installExit -ne 0) {
    Write-Fail "安装失败（exit $installExit）。"
    Write-Host ''
    Write-Host '注意：脚本**没有**卸载应用，应用数据仍然完整。' -ForegroundColor Green
    $failureText = ($installOutput | Out-String)
    if ($failureText -match 'INSTALL_FAILED_VERSION_DOWNGRADE') {
        Write-Host ''
        Write-Host '失败原因是**版本号降级**（新包 versionCode 低于设备上已装的）。' -ForegroundColor Yellow
        Write-Host '这正是 `flutter run` 会自动卸载重装并清空数据的那种失败之一。'
        Write-Host "处理办法：把 pubspec.yaml 的 build number 提到 >= $deviceVersionCode，"
        Write-Host '然后重新运行本脚本；不要为了绕过它去用 `-d`（那会让版本号继续倒退）。'
    } else {
        Write-Host '其它常见原因：'
        Write-Host '  - 签名不一致（换成同一个 keystore 构建的包）'
        Write-Host '  - 空间不足（清理后重试；本脚本已做预检）'
    }
    Write-Host ''
    Write-Host '切记：不要改用 `flutter run` 来处理这个失败 —— 它会卸载应用。'
    exit $installExit
}

Write-Host ''
Write-Host '完成：已覆盖安装，应用数据保留。' -ForegroundColor Green
