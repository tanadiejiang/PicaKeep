<#
.SYNOPSIS
    把手机上原项目（PicaComic）的登录态搬到 PicaKeep，省去逐个重新登录。

.DESCRIPTION
    ## 为什么能搬

    PicaKeep 与原项目同源，数据布局高度一致：
      - 源数据：`<data>/comic_source/<key>.data`（JSON）
      - cookie：sqlite，两边都用 `cookie_jar` 包，表结构相同
        （`cookies(name, value, domain, path, expires, secure, httpOnly)`）

    ## 三个必须处理的差异（都实测踩过）

    1. **cookie 库布局不同**
       原项目共用一个 `files/cookies.db`；PicaKeep 是各源独立库：

         EH      -> comic_source/eh_cookies.db
         JM      -> comic_source/jm_cookies.db
         Komiic  -> comic_source/komiic/cookies.db
         nhentai -> files/cookies.db          （恰好同名同位置，直接复制）

       把原库整个复制到每个位置是**安全的**：`loadForRequest(Uri)` 按
       domain/path 过滤，EH 的请求不会带出 JM 的 cookie。

    2. **字段名不同**
       - **JM**：原项目写 `id`，PicaKeep 要 `uid`；而且还需要一个
         `token: 'logged_in'` —— `ComicSource.isLoggedIn` 只看 `token` 非空，
         缺了它即使 cookie 有效也会被判成未登录。
       - **nhentai**：原数据只有 `{"account":"ok"}`，PicaKeep 需要额外的
         `token` 与 `name`（`'Nhentai'` 是它登录流程写入的固定占位，
         源码注释里写明了这一点）。

    3. **文件属主必须是应用自己**
       root 复制出来的文件属主是 `root`，应用根本读不了。必须 chown 到
       目标包的 uid，并把权限收紧成 `u+rwX,go-rwx`。

    ## 搬不了的东西

    - **Pixiv**：原项目没有这个源，只能重新登录。
    - **Komiic 的 token 常常已过期**：脚本会打印每个数据文件的修改时间，
      太旧的要预期重登（实测遇到近一年前的 token）。
    - 过期 cookie 不会被剔除，交给 `cookie_jar` 按 expires 自己过滤。

    ## 安全性

    - 全程只读源应用，**不修改也不删除**源数据。
    - 默认**跳过目标已存在的文件**，保护你在 PicaKeep 里新登录的状态；
      需要覆盖时显式加 `-Force`。
    - 运行前会 `force-stop` 目标应用，避免边写边读；跑完自己启动即可。

.PARAMETER SourcePackage
    源应用包名，默认 `com.github.pacalini.pica_comic`。

.PARAMETER TargetPackage
    目标应用包名，默认 `lingxue.picakeep`。

.PARAMETER Device
    adb 设备序列号；省略时自动选择唯一在线设备，多台在线会要求显式指定。

.PARAMETER Force
    覆盖目标已存在的源数据。默认跳过。

.PARAMETER SkipCookies
    只搬 `.data`（账号配置），不碰 cookie。

.EXAMPLE
    pwsh tool\import_from_picacomic.ps1
    一次性搬完能搬的登录态（跳过 PicaKeep 里已有的）。

.EXAMPLE
    pwsh tool\import_from_picacomic.ps1 -Force
    连已存在的也一起覆盖。

.EXAMPLE
    pwsh tool\import_from_picacomic.ps1 -Device 192.168.5.185:5555 -SkipCookies
#>
[CmdletBinding()]
param(
    [string]$SourcePackage = 'com.github.pacalini.pica_comic',
    [string]$TargetPackage = 'lingxue.picakeep',
    [string]$Device = '',
    [switch]$Force,
    [switch]$SkipCookies
)

$ErrorActionPreference = 'Stop'

function Write-Step($text) { Write-Host "==> $text" -ForegroundColor Cyan }
function Write-Ok($text)   { Write-Host "    $text" -ForegroundColor Green }
function Write-Skip($text) { Write-Host "    跳过：$text" -ForegroundColor DarkGray }
function Write-Warn2($text) { Write-Host "!!  $text" -ForegroundColor Yellow }
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
    Write-Fail '没有在线设备。'
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

# 所有 adb 调用都带上设备号，避免多设备时打错目标。
function AdbShell($cmd) { & adb -s $serial shell $cmd 2>&1 }
function SuShell($cmd) { & adb -s $serial shell "su -c `"$cmd`"" 2>&1 }

# ── 2. 前置检查 ──────────────────────────────────────────────────────────────
Write-Step '检查 root 权限'
$whoami = (SuShell 'id' | Out-String).Trim()
if ($whoami -notmatch 'uid=0') {
    Write-Fail '需要 root（su）才能读写其它应用的私有目录。'
    Write-Fail "当前：$whoami"
    exit 1
}
Write-Ok 'root 可用'

$srcFiles = "/data/user/0/$SourcePackage/files"
$tgtRoot = "/data/user/0/$TargetPackage"
$tgtFiles = "$tgtRoot/files"

Write-Step '定位源应用与目标应用'
$srcOk = (SuShell "test -d $srcFiles && echo yes" | Out-String).Trim()
if ($srcOk -ne 'yes') {
    Write-Fail "源应用数据目录不存在：$srcFiles"
    Write-Fail "确认 $SourcePackage 已安装并至少启动过一次。"
    exit 1
}
$tgtOk = (SuShell "test -d $tgtRoot && echo yes" | Out-String).Trim()
if ($tgtOk -ne 'yes') {
    Write-Fail "目标应用数据目录不存在：$tgtRoot"
    Write-Fail "先在手机上启动一次 $TargetPackage。"
    exit 1
}
$targetUid = (SuShell "stat -c %u $tgtRoot" | Out-String).Trim()
Write-Ok "源：$srcFiles"
Write-Ok "目标：$tgtFiles（uid=$targetUid）"

# ── 3. 停掉目标应用（避免边写边读）──────────────────────────────────────────
Write-Step "停止 $TargetPackage"
AdbShell "am force-stop $TargetPackage" | Out-Null
Write-Ok '已停止'

# ── 4. 需要搬运的源清单 ──────────────────────────────────────────────────────
# 每一项：源文件名 / 目标文件名 / 说明。
# 原项目里有而 PicaKeep 没有的源（htmanga、copy_manga、baozi 等）不在此列。
$dataEntries = @(
    @{ Src = 'ehentai.data';  Dst = 'ehentai.data';  Note = 'EH（登录态主要在 cookie，这里只带名称与收藏夹名）' },
    @{ Src = 'jm.data';       Dst = 'jm.data';       Note = 'JM（需字段转换 id->uid 并补 token）' },
    @{ Src = 'nhentai.data';  Dst = 'nhentai.data';  Note = 'nhentai（需补 token 与 name）' },
    @{ Src = 'picacg.data';   Dst = 'picacg.data';   Note = 'picacg（token 认证，结构一致）' },
    @{ Src = 'Komiic.data';   Dst = 'komiic.data';   Note = 'Komiic（注意大小写：原项目是大写 K）' }
)

Write-Step '源数据清单（含修改时间，用于判断新鲜度）'
foreach ($e in $dataEntries) {
    $p = "$srcFiles/comic_source/$($e.Src)"
    $meta = (SuShell "stat -c '%y %s' $p 2>/dev/null" | Out-String).Trim()
    if ($meta -and $meta -notmatch 'No such file') {
        $stamp = ($meta -split '\s+')[0]
        Write-Host ("    {0,-16} {1}  {2}" -f $e.Src, $stamp, $e.Note)
    } else {
        Write-Skip "$($e.Src)（源应用里没有）"
    }
}

# ── 5. 搬运 .data ────────────────────────────────────────────────────────────
Write-Step '搬运源数据（.data）'
SuShell "mkdir -p $tgtFiles/comic_source/komiic" | Out-Null

function Read-SourceData($name) {
    $p = "$srcFiles/comic_source/$name"
    $raw = (SuShell "cat $p 2>/dev/null" | Out-String).Trim()
    if (-not $raw) { return $null }
    try { return $raw | ConvertFrom-Json } catch { return $null }
}

# 内容一律走 base64 写入，避免 JSON 里的引号被 shell 吃掉。
function Write-TargetData($name, $json) {
    $dst = "$tgtFiles/comic_source/$name"
    $b64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($json))
    SuShell "echo -n '$b64' | base64 -d > $dst" | Out-Null
}

foreach ($e in $dataEntries) {
    $dst = "$tgtFiles/comic_source/$($e.Dst)"
    $exists = (SuShell "test -e $dst && echo yes" | Out-String).Trim()
    if ($exists -eq 'yes' -and -not $Force) {
        Write-Skip "$($e.Dst)（目标已存在；要覆盖加 -Force）"
        continue
    }
    $data = Read-SourceData $e.Src
    if ($null -eq $data) {
        Write-Skip "$($e.Src)（读不到或不是 JSON）"
        continue
    }

    # 逐源做字段适配 —— 这些名字对不上就会"看着有数据其实是未登录"。
    $out = $null
    switch ($e.Src) {
        'jm.data' {
            # 原项目：{account, name, id}  →  PicaKeep：{account, name, uid, token}
            $out = [ordered]@{
                account = $data.account
                name    = $data.name
                uid     = $data.id
                token   = 'logged_in'
            } | ConvertTo-Json -Compress -Depth 5
        }
        'nhentai.data' {
            # 原项目常常只有 {account:"ok"}；PicaKeep 要靠 token 判登录、靠 name 显示。
            $name = if ($data.name) { $data.name } else { 'Nhentai' }
            $out = [ordered]@{
                account = $data.account
                token   = 'logged_in'
                name    = $name
            } | ConvertTo-Json -Compress -Depth 5
        }
        default {
            $out = $data | ConvertTo-Json -Compress -Depth 5
        }
    }
    Write-TargetData $e.Dst $out
    Write-Ok "$($e.Dst)"
}

# ── 6. 搬运 cookie ───────────────────────────────────────────────────────────
if ($SkipCookies) {
    Write-Step '跳过 cookie（-SkipCookies）'
} else {
    Write-Step '搬运 cookie'
    $srcCookies = "$srcFiles/cookies.db"
    $cookieExists = (SuShell "test -f $srcCookies && echo yes" | Out-String).Trim()
    if ($cookieExists -ne 'yes') {
        Write-Warn2 "源应用没有 $srcCookies，跳过 cookie 搬运。"
    } else {
        # 原库覆盖的域（说明为什么每个目标都要一份完整拷贝）：
        #   .e-hentai.org / .exhentai.org / e-hentai.org / api.e-hentai.org
        #   forums.e-hentai.org / .nhentai.net / komiic.com
        #   cdn-msp*.jmapiproxy*.cc / cdn-msp*.jmdanjonproxy.* 等 JM CDN 域
        $cookieTargets = @(
            "$tgtFiles/comic_source/eh_cookies.db",
            "$tgtFiles/comic_source/jm_cookies.db",
            "$tgtFiles/comic_source/komiic/cookies.db",
            "$tgtFiles/cookies.db"
        )
        foreach ($dst in $cookieTargets) {
            $exists = (SuShell "test -e $dst && echo yes" | Out-String).Trim()
            if ($exists -eq 'yes' -and -not $Force) {
                Write-Skip "$dst（已存在）"
                continue
            }
            SuShell "cp $srcCookies $dst"
            Write-Ok $dst
        }
    }
}

# ── 7. 属主与权限 ────────────────────────────────────────────────────────────
# root 复制出来的文件属主是 root，应用读不了 —— 这一步漏了就等于白搬。
Write-Step "修正属主为 uid=$targetUid 并收紧权限"
SuShell "chown -R ${targetUid}:${targetUid} $tgtFiles"
SuShell "chmod -R u+rwX,go-rwx $tgtFiles"
Write-Ok '完成'

Write-Step '结果'
SuShell "ls -la $tgtFiles/comic_source/ $tgtFiles/cookies.db"

Write-Host ''
Write-Host '搬运完成。接下来：' -ForegroundColor Green
Write-Host '  1. 在手机上打开 PicaKeep，进「设置 → 账号」逐个确认登录状态；'
Write-Host '  2. EH / JM / picacg 一般直接可用；'
Write-Host '  3. Komiic 的 token 常常已过期，需要重登；'
Write-Host '  4. Pixiv 原项目没有，必须重新登录。'
