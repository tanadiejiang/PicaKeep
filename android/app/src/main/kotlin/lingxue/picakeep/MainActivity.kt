package lingxue.picakeep

import android.Manifest
import android.app.UiModeManager
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.ServiceConnection
import android.content.pm.PackageManager
import android.content.res.Configuration
import android.net.Uri
import android.net.wifi.WifiManager
import android.os.Build
import android.os.Bundle
import android.os.Environment
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.os.PowerManager
import androidx.core.splashscreen.SplashScreen.Companion.installSplashScreen
import org.json.JSONArray
import java.io.File
import android.os.SystemClock
import android.provider.Settings
import android.util.Log
import android.view.WindowManager
import androidx.core.app.ActivityCompat
import androidx.core.app.NotificationManagerCompat
import androidx.core.content.ContextCompat
import androidx.core.view.WindowCompat
import androidx.core.view.WindowInsetsControllerCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.renderer.FlutterUiDisplayListener
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import java.util.concurrent.TimeoutException
import lingxue.picakeep.shizuku.IPicaKeepShizukuFileService
import lingxue.picakeep.shizuku.PicaKeepShizukuFileService
import rikka.shizuku.Shizuku

class MainActivity : FlutterActivity() {
    private var pendingNotificationPermissionResult: MethodChannel.Result? = null
    private var pendingShizukuPermissionResult: MethodChannel.Result? = null
    private var cachedRootAccess: Boolean? = null
    private var cachedRootAccessAt: Long = 0L
    private var cachedShizukuPermission: Boolean? = null
    private var cachedShizukuPermissionAt: Long = 0L
    private val mainHandler = Handler(Looper.getMainLooper())
    private val storageExecutor = Executors.newCachedThreadPool()
    private val launchStartElapsedMs = SystemClock.elapsedRealtime()
    private var firstWindowFocusLogged = false
    private val shizukuUserServiceLock = java.lang.Object()
    @Volatile
    private var shizukuUserService: IPicaKeepShizukuFileService? = null
    @Volatile
    private var shizukuUserServiceBinding = false
    private var dynamicThemeChannel: MethodChannel? = null
    private var multicastLock: WifiManager.MulticastLock? = null
    private var lastForwardedNightFlag: Int = Int.MIN_VALUE

    private val shizukuUserServiceArgs by lazy {
        Shizuku.UserServiceArgs(
            ComponentName(packageName, PicaKeepShizukuFileService::class.java.name),
        ).processNameSuffix("shizuku_fs")
            .debuggable(BuildConfig.DEBUG)
            .version(1)
            .tag("picakeep_fs")
    }

    private val shizukuPermissionListener =
        Shizuku.OnRequestPermissionResultListener { requestCode, grantResult ->
            if (requestCode != REQUEST_CODE_SHIZUKU) {
                return@OnRequestPermissionResultListener
            }
            val granted = grantResult == PackageManager.PERMISSION_GRANTED
            cachedShizukuPermission = granted
            cachedShizukuPermissionAt = System.currentTimeMillis()
            if (granted) {
                ensureShizukuUserServiceBoundAsync()
            } else {
                clearShizukuUserService()
            }
            pendingShizukuPermissionResult?.success(granted)
            pendingShizukuPermissionResult = null
        }

    private val shizukuBinderReceivedListener =
        Shizuku.OnBinderReceivedListener {
            ensureShizukuUserServiceBoundAsync()
        }

    private val shizukuBinderDeadListener =
        Shizuku.OnBinderDeadListener {
            clearShizukuUserService()
        }

    private val shizukuUserServiceConnection =
        object : ServiceConnection {
            override fun onServiceConnected(name: ComponentName, service: IBinder) {
                synchronized(shizukuUserServiceLock) {
                    shizukuUserService = IPicaKeepShizukuFileService.Stub.asInterface(service)
                    shizukuUserServiceBinding = false
                    shizukuUserServiceLock.notifyAll()
                }
            }

            override fun onServiceDisconnected(name: ComponentName) {
                clearShizukuUserService()
            }

            override fun onBindingDied(name: ComponentName) {
                clearShizukuUserService()
            }

            override fun onNullBinding(name: ComponentName) {
                clearShizukuUserService()
            }
        }

    // NOTE: We intentionally do NOT override attachBaseContext to force a
    // uiMode here. Earlier we used createConfigurationContext +
    // applyOverrideConfiguration to lock the activity to a fixed uiMode based
    // on settings[32], but that "stickied" the override across config changes
    // (because of android:configChanges="...uiMode" the activity is not
    // recreated, so attachBaseContext never re-runs). Switching back to
    // "follow system" via UiModeManager would update the application uiMode
    // but the stale override on this activity stayed pinned to dark.
    //
    // UiModeManager.setApplicationNightMode (API 31+, see
    // applyApplicationNightMode below) is the supported way to express a
    // per-app night-mode preference and is honored by both the system splash
    // and the in-process resources. We rely on it exclusively now.

    override fun onCreate(savedInstanceState: Bundle?) {
        Log.i(TAG, "startup onCreate +${SystemClock.elapsedRealtime() - launchStartElapsedMs}ms")
        val splashScreen = installSplashScreen()
        splashScreen.setOnExitAnimationListener { provider -> provider.remove() }
        WindowCompat.setDecorFitsSystemWindows(window, false)
        window.statusBarColor = android.graphics.Color.TRANSPARENT
        window.navigationBarColor = android.graphics.Color.TRANSPARENT
        super.onCreate(savedInstanceState)
        // Sync per-app night mode to the system so the next cold-start splash
        // (drawn by system_server before our process starts) follows our setting.
        applyApplicationNightMode(readDarkModeSetting(this))
        val isDark = (resources.configuration.uiMode and Configuration.UI_MODE_NIGHT_MASK) ==
            Configuration.UI_MODE_NIGHT_YES
        WindowCompat.getInsetsController(window, window.decorView).apply {
            isAppearanceLightStatusBars = !isDark
            isAppearanceLightNavigationBars = !isDark
            systemBarsBehavior = WindowInsetsControllerCompat.BEHAVIOR_SHOW_TRANSIENT_BARS_BY_SWIPE
        }
    }

    override fun onConfigurationChanged(newConfig: Configuration) {
        super.onConfigurationChanged(newConfig)
        // MIUI emits onConfigurationChanged very frequently (observed ~every 6s
        // even while idle — status-bar/system churn, none of it relevant to our
        // theme). The previous guard still forwarded whenever 1s had elapsed, so
        // those 6s ticks all passed through and each one ran getCorePalette() +
        // double toColorScheme() + a full MaterialApp rebuild on the UI isolate,
        // steadily pressuring the main thread into ANRs.
        //
        // The only configuration dimension our dynamic theme actually depends on
        // here is the uiMode night flag (light/dark). Wallpaper palette changes
        // do NOT arrive via onConfigurationChanged. So forward ONLY when the
        // night flag truly flips; ignore every other config change.
        val nightFlag = newConfig.uiMode and Configuration.UI_MODE_NIGHT_MASK
        if (nightFlag == lastForwardedNightFlag) {
            return
        }
        lastForwardedNightFlag = nightFlag
        dynamicThemeChannel?.invokeMethod("changed", null)
    }

    /**
     * Push the user's dark-mode preference (settings[32]) to the system via
     * [UiModeManager.setApplicationNightMode] (API 31+). Once set, system_server
     * will use the requested uiMode when resolving our launch theme on the
     * next cold start, so the splash background follows the in-app setting.
     *
     * - "0" -> follow system (MODE_NIGHT_AUTO)
     * - "1" -> force light (MODE_NIGHT_NO)
     * - "2" -> force dark  (MODE_NIGHT_YES)
     *
     * No-op below API 31 (older devices fall back to system uiMode for splash).
     */
    private fun applyApplicationNightMode(darkMode: String) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.S) {
            return
        }
        val uiModeManager = getSystemService(UiModeManager::class.java) ?: return
        val mode = when (darkMode) {
            "1" -> UiModeManager.MODE_NIGHT_NO
            "2" -> UiModeManager.MODE_NIGHT_YES
            else -> UiModeManager.MODE_NIGHT_AUTO
        }
        runCatching { uiModeManager.setApplicationNightMode(mode) }
            .onFailure { Log.w(TAG, "setApplicationNightMode failed for $darkMode", it) }
    }

    private fun readDarkModeSetting(ctx: Context): String {
        return try {
            val settingsFile = File(ctx.filesDir, "settings")
            if (settingsFile.exists()) {
                val json = JSONArray(settingsFile.readText())
                if (json.length() > 32) json.getString(32) else "0"
            } else {
                "0"
            }
        } catch (_: Exception) {
            "0"
        }
    }

    override fun onWindowFocusChanged(hasFocus: Boolean) {
        super.onWindowFocusChanged(hasFocus)
        if (hasFocus && !firstWindowFocusLogged) {
            firstWindowFocusLogged = true
            Log.i(TAG, "startup firstWindowFocus +${SystemClock.elapsedRealtime() - launchStartElapsedMs}ms")
        }
    }

    override fun onDestroy() {
        pendingNotificationPermissionResult = null
        pendingShizukuPermissionResult = null
        runCatching {
            Shizuku.removeRequestPermissionResultListener(shizukuPermissionListener)
        }
        runCatching {
            Shizuku.removeBinderReceivedListener(shizukuBinderReceivedListener)
        }
        runCatching {
            Shizuku.removeBinderDeadListener(shizukuBinderDeadListener)
        }
        runCatching {
            Shizuku.unbindUserService(shizukuUserServiceArgs, shizukuUserServiceConnection, false)
        }
        releaseMulticastLock()
        clearShizukuUserService()
        super.onDestroy()
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        Log.i(TAG, "startup configureFlutterEngine +${SystemClock.elapsedRealtime() - launchStartElapsedMs}ms")
        flutterEngine.renderer.addIsDisplayingFlutterUiListener(
            object : FlutterUiDisplayListener {
                override fun onFlutterUiDisplayed() {
                    Log.i(
                        TAG,
                        "startup flutterUiDisplayed +${SystemClock.elapsedRealtime() - launchStartElapsedMs}ms",
                    )
                    flutterEngine.renderer.removeIsDisplayingFlutterUiListener(this)
                }

                override fun onFlutterUiNoLongerDisplayed() = Unit
            },
        )
        runCatching {
            Shizuku.addRequestPermissionResultListener(shizukuPermissionListener)
            Shizuku.addBinderReceivedListenerSticky(shizukuBinderReceivedListener)
            Shizuku.addBinderDeadListener(shizukuBinderDeadListener)
        }
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            FOREGROUND_SERVICE_CHANNEL,
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "start" -> {
                    PicaKeepForegroundService.start(
                        context = this,
                        title = call.argument<String>("title") ?: "PicaKeep 服务端",
                        content = call.argument<String>("content") ?: "服务端正在后台保持在线",
                        statusText = call.argument("statusText"),
                        port = call.argument("port"),
                        adminUrl = call.argument("adminUrl"),
                    )
                    result.success(null)
                }
                "stop" -> {
                    PicaKeepForegroundService.stop(this)
                    result.success(null)
                }
                "requestNotificationPermission" -> handleNotificationPermissionRequest(result)
                "areNotificationsEnabled" -> {
                    result.success(NotificationManagerCompat.from(this).areNotificationsEnabled())
                }
                "isIgnoringBatteryOptimizations" -> {
                    result.success(isIgnoringBatteryOptimizations())
                }
                "openNotificationSettings" -> {
                    openNotificationSettings()
                    result.success(null)
                }
                "openBatteryOptimizationSettings" -> {
                    openBatteryOptimizationSettings()
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            KEEP_SCREEN_ON_CHANNEL,
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "set" -> {
                    window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
                    result.success(null)
                }
                "cancel" -> {
                    window.clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            MULTICAST_LOCK_CHANNEL,
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "acquire" -> {
                    acquireMulticastLock()
                    result.success(null)
                }
                "release" -> {
                    releaseMulticastLock()
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            APP_ICON_CHANNEL,
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "list" -> result.success(launcherIcons.map { it.toMap() })
                "current" -> result.success(currentLauncherIconId())
                "set" -> {
                    val id = call.argument<String>("id")
                    if (id == null) {
                        result.error("missing_id", "Icon id is required", null)
                    } else if (launcherIcons.none { it.id == id }) {
                        result.error("unknown_icon", "Unknown icon id: $id", null)
                    } else {
                        setLauncherIcon(id)
                        result.success(null)
                    }
                }
                else -> result.notImplemented()
            }
        }
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            NIGHT_MODE_CHANNEL,
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "setMode" -> {
                    val mode = call.argument<String>("mode") ?: "0"
                    applyApplicationNightMode(mode)
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
        dynamicThemeChannel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            DYNAMIC_THEME_CHANNEL,
        )
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            STORAGE_ACCESS_CHANNEL,
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "hasManageAllFilesAccess" -> result.success(hasManageAllFilesAccess())
                "openManageAllFilesAccessSettings" -> {
                    openManageAllFilesAccessSettings()
                    result.success(null)
                }
                "isShizukuAvailable" -> result.success(isShizukuAvailable())
                "hasShizukuPermission" -> {
                    val forceRefresh = call.argument<Boolean>("forceRefresh") == true
                    result.success(hasShizukuPermission(forceRefresh))
                }
                "getShizukuStatus" -> {
                    val forceRefresh = call.argument<Boolean>("forceRefresh") == true
                    result.success(
                        mapOf(
                            "installed" to isShizukuInstalled(),
                            "running" to isShizukuAvailable(),
                            "permissionGranted" to hasShizukuPermission(forceRefresh),
                        ),
                    )
                }
                "openShizukuApp" -> {
                    openShizukuApp()
                    result.success(null)
                }
                "requestShizukuPermission" -> handleShizukuPermissionRequest(result)
                "hasRootAccess" -> runStorageTask(
                    result,
                    "root_check_failed",
                    "Root 检测失败",
                ) {
                    val forceRefresh = call.argument<Boolean>("forceRefresh") == true
                    hasRootAccess(forceRefresh)
                }
                "listDirectoriesWithRoot" -> {
                    val path = call.argument<String>("path")
                    if (path.isNullOrBlank()) {
                        result.error("invalid_path", "path is required", null)
                        return@setMethodCallHandler
                    }
                    val targetPath = path.trim()
                    runStorageTask(
                        result,
                        "root_list_failed",
                        "Root 模式目录读取失败",
                    ) {
                        listDirectoriesWithRoot(targetPath)
                    }
                }
                "listDirectoryEntriesWithRoot" -> {
                    val path = call.argument<String>("path")
                    if (path.isNullOrBlank()) {
                        result.error("invalid_path", "path is required", null)
                        return@setMethodCallHandler
                    }
                    val targetPath = path.trim()
                    runStorageTask(
                        result,
                        "root_list_entries_failed",
                        "Root 模式目录读取失败",
                    ) {
                        listDirectoryEntriesWithRoot(targetPath)
                    }
                }
                "readFileWithRoot" -> {
                    val path = call.argument<String>("path")
                    if (path.isNullOrBlank()) {
                        result.error("invalid_path", "path is required", null)
                        return@setMethodCallHandler
                    }
                    val targetPath = path.trim()
                    runStorageTask(
                        result,
                        "root_read_failed",
                        "Root 模式文件读取失败",
                    ) {
                        readFileWithRoot(targetPath)
                    }
                }
                "writeFileWithRoot" -> {
                    val path = call.argument<String>("path")
                    val bytes = call.argument<ByteArray>("bytes")
                    if (path.isNullOrBlank() || bytes == null) {
                        result.error("invalid_path", "path and bytes are required", null)
                        return@setMethodCallHandler
                    }
                    val targetPath = path.trim()
                    runStorageTask(
                        result,
                        "root_write_failed",
                        "Root file write failed",
                    ) {
                        writeFileWithRoot(targetPath, bytes)
                        null
                    }
                }
                "existsWithRoot" -> {
                    val path = call.argument<String>("path")
                    if (path.isNullOrBlank()) {
                        result.success(false)
                        return@setMethodCallHandler
                    }
                    val targetPath = path.trim()
                    runStorageTask(
                        result,
                        "root_exists_failed",
                        "Root 模式文件检测失败",
                    ) {
                        existsWithRoot(targetPath)
                    }
                }
                "movePathWithRoot" -> {
                    val sourcePath = call.argument<String>("sourcePath")
                    val targetPath = call.argument<String>("targetPath")
                    if (sourcePath.isNullOrBlank() || targetPath.isNullOrBlank()) {
                        result.error("invalid_path", "sourcePath and targetPath are required", null)
                        return@setMethodCallHandler
                    }
                    runStorageTask(
                        result,
                        "root_move_failed",
                        "Root 模式文件移动失败",
                    ) {
                        movePathWithRoot(sourcePath.trim(), targetPath.trim())
                        null
                    }
                }
                "deletePathWithRoot" -> {
                    val path = call.argument<String>("path")
                    if (path.isNullOrBlank()) {
                        result.error("invalid_path", "path is required", null)
                        return@setMethodCallHandler
                    }
                    runStorageTask(
                        result,
                        "root_delete_failed",
                        "Root 模式文件删除失败",
                    ) {
                        deletePathWithRoot(path.trim())
                        null
                    }
                }
                "listDirectoriesWithShizuku" -> {
                    val path = call.argument<String>("path")
                    if (path.isNullOrBlank()) {
                        result.error("invalid_path", "path is required", null)
                        return@setMethodCallHandler
                    }
                    val targetPath = path.trim()
                    runStorageTask(
                        result,
                        "shizuku_list_failed",
                        "Shizuku 模式目录读取失败",
                    ) {
                        listDirectoriesWithShizuku(targetPath)
                    }
                }
                "listDirectoryEntriesWithShizuku" -> {
                    val path = call.argument<String>("path")
                    if (path.isNullOrBlank()) {
                        result.error("invalid_path", "path is required", null)
                        return@setMethodCallHandler
                    }
                    val targetPath = path.trim()
                    runStorageTask(
                        result,
                        "shizuku_list_entries_failed",
                        "Shizuku 模式目录读取失败",
                    ) {
                        listDirectoryEntriesWithShizuku(targetPath)
                    }
                }
                "listAndroidDataDirectoryWithShizuku" -> {
                    runStorageTask(
                        result,
                        "shizuku_android_data_list_failed",
                        "Shizuku 模式目录读取失败",
                    ) {
                        listAndroidDataDirectoryWithShizuku()
                    }
                }
                "readFileWithShizuku" -> {
                    val path = call.argument<String>("path")
                    if (path.isNullOrBlank()) {
                        result.error("invalid_path", "path is required", null)
                        return@setMethodCallHandler
                    }
                    val targetPath = path.trim()
                    runStorageTask(
                        result,
                        "shizuku_read_failed",
                        "Shizuku 模式文件读取失败",
                    ) {
                        readFileWithShizuku(targetPath)
                    }
                }
                "writeFileWithShizuku" -> {
                    val path = call.argument<String>("path")
                    val bytes = call.argument<ByteArray>("bytes")
                    if (path.isNullOrBlank() || bytes == null) {
                        result.error("invalid_path", "path and bytes are required", null)
                        return@setMethodCallHandler
                    }
                    val targetPath = path.trim()
                    runStorageTask(
                        result,
                        "shizuku_write_failed",
                        "Shizuku file write failed",
                    ) {
                        writeFileWithShizuku(targetPath, bytes)
                        null
                    }
                }
                "existsWithShizuku" -> {
                    val path = call.argument<String>("path")
                    if (path.isNullOrBlank()) {
                        result.success(false)
                        return@setMethodCallHandler
                    }
                    val targetPath = path.trim()
                    runStorageTask(
                        result,
                        "shizuku_exists_failed",
                        "Shizuku 模式文件检测失败",
                    ) {
                        existsWithShizuku(targetPath)
                    }
                }
                "movePathWithShizuku" -> {
                    val sourcePath = call.argument<String>("sourcePath")
                    val targetPath = call.argument<String>("targetPath")
                    if (sourcePath.isNullOrBlank() || targetPath.isNullOrBlank()) {
                        result.error("invalid_path", "sourcePath and targetPath are required", null)
                        return@setMethodCallHandler
                    }
                    runStorageTask(
                        result,
                        "shizuku_move_failed",
                        "Shizuku 模式文件移动失败",
                    ) {
                        movePathWithShizuku(sourcePath.trim(), targetPath.trim())
                        null
                    }
                }
                "deletePathWithShizuku" -> {
                    val path = call.argument<String>("path")
                    if (path.isNullOrBlank()) {
                        result.error("invalid_path", "path is required", null)
                        return@setMethodCallHandler
                    }
                    runStorageTask(
                        result,
                        "shizuku_delete_failed",
                        "Shizuku 模式文件删除失败",
                    ) {
                        deletePathWithShizuku(path.trim())
                        null
                    }
                }
                else -> result.notImplemented()
            }
        }
    }

    private fun <T> runStorageTask(
        result: MethodChannel.Result,
        errorCode: String,
        fallbackMessage: String,
        block: () -> T,
    ) {
        storageExecutor.execute {
            runCatching {
                block()
            }.onSuccess { value ->
                mainHandler.post {
                    result.success(value)
                }
            }.onFailure { error ->
                mainHandler.post {
                    result.error(errorCode, error.message ?: fallbackMessage, null)
                }
            }
        }
    }

    private data class ProcessTextResult(
        val exitCode: Int,
        val stdout: String,
        val stderr: String,
    )

    private data class ProcessBytesResult(
        val exitCode: Int,
        val stdout: ByteArray,
        val stderr: String,
    )

    private fun executeTextProcess(
        process: Process,
        timeoutMs: Long = PRIVILEGED_PROCESS_TIMEOUT_MS,
        operation: String = "process",
    ): ProcessTextResult {
        val deadlineNanos = System.nanoTime() + TimeUnit.MILLISECONDS.toNanos(timeoutMs)
        val stdout = storageExecutor.submit<String> {
            process.inputStream.bufferedReader().use { it.readText() }
        }
        val stderr = storageExecutor.submit<String> {
            process.errorStream.bufferedReader().use { it.readText().trim() }
        }
        val waitResult = storageExecutor.submit<Int> {
            process.waitFor()
        }
        fun remainingMs(minimumMs: Long = 1_000L): Long {
            val remaining = TimeUnit.NANOSECONDS.toMillis(deadlineNanos - System.nanoTime())
            return maxOf(minimumMs, remaining)
        }
        try {
            val exitCode = waitResult.get(timeoutMs, TimeUnit.MILLISECONDS)
            return ProcessTextResult(
                exitCode,
                stdout.get(remainingMs(), TimeUnit.MILLISECONDS),
                stderr.get(remainingMs(), TimeUnit.MILLISECONDS),
            )
        } catch (error: Throwable) {
            process.destroyForcibly()
            waitResult.cancel(true)
            stdout.cancel(true)
            stderr.cancel(true)
            if (error is TimeoutException) {
                throw IllegalStateException("$operation timeout after ${timeoutMs}ms", error)
            }
            throw error
        }
    }

    private fun executeBytesProcess(
        process: Process,
        timeoutMs: Long = PRIVILEGED_READ_TIMEOUT_MS,
        operation: String = "process",
    ): ProcessBytesResult {
        val deadlineNanos = System.nanoTime() + TimeUnit.MILLISECONDS.toNanos(timeoutMs)
        val stdout = storageExecutor.submit<ByteArray> {
            process.inputStream.use { it.readBytes() }
        }
        val stderr = storageExecutor.submit<String> {
            process.errorStream.bufferedReader().use { it.readText().trim() }
        }
        val waitResult = storageExecutor.submit<Int> {
            process.waitFor()
        }
        fun remainingMs(minimumMs: Long = 1_000L): Long {
            val remaining = TimeUnit.NANOSECONDS.toMillis(deadlineNanos - System.nanoTime())
            return maxOf(minimumMs, remaining)
        }
        try {
            val exitCode = waitResult.get(timeoutMs, TimeUnit.MILLISECONDS)
            return ProcessBytesResult(
                exitCode,
                stdout.get(remainingMs(), TimeUnit.MILLISECONDS),
                stderr.get(remainingMs(), TimeUnit.MILLISECONDS),
            )
        } catch (error: Throwable) {
            process.destroyForcibly()
            waitResult.cancel(true)
            stdout.cancel(true)
            stderr.cancel(true)
            if (error is TimeoutException) {
                throw IllegalStateException("$operation timeout after ${timeoutMs}ms", error)
            }
            throw error
        }
    }

    private fun executeBinaryWriteProcess(
        process: Process,
        bytes: ByteArray,
        timeoutMs: Long = PRIVILEGED_READ_TIMEOUT_MS,
        operation: String = "process",
    ): ProcessTextResult {
        val deadlineNanos = System.nanoTime() + TimeUnit.MILLISECONDS.toNanos(timeoutMs)
        val writer = storageExecutor.submit<Unit> {
            process.outputStream.use { output ->
                output.write(bytes)
                output.flush()
            }
        }
        val stdout = storageExecutor.submit<String> {
            process.inputStream.bufferedReader().use { it.readText() }
        }
        val stderr = storageExecutor.submit<String> {
            process.errorStream.bufferedReader().use { it.readText().trim() }
        }
        val waitResult = storageExecutor.submit<Int> {
            process.waitFor()
        }
        fun remainingMs(minimumMs: Long = 1_000L): Long {
            val remaining = TimeUnit.NANOSECONDS.toMillis(deadlineNanos - System.nanoTime())
            return maxOf(minimumMs, remaining)
        }
        try {
            writer.get(timeoutMs, TimeUnit.MILLISECONDS)
            val exitCode = waitResult.get(remainingMs(), TimeUnit.MILLISECONDS)
            return ProcessTextResult(
                exitCode,
                stdout.get(remainingMs(), TimeUnit.MILLISECONDS),
                stderr.get(remainingMs(), TimeUnit.MILLISECONDS),
            )
        } catch (error: Throwable) {
            process.destroyForcibly()
            writer.cancel(true)
            waitResult.cancel(true)
            stdout.cancel(true)
            stderr.cancel(true)
            if (error is TimeoutException) {
                throw IllegalStateException("$operation timeout after ${timeoutMs}ms", error)
            }
            throw error
        }
    }

    private fun handleNotificationPermissionRequest(result: MethodChannel.Result) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) {
            result.success(true)
            return
        }
        if (
            ContextCompat.checkSelfPermission(this, Manifest.permission.POST_NOTIFICATIONS) ==
                PackageManager.PERMISSION_GRANTED
        ) {
            result.success(true)
            return
        }
        if (pendingNotificationPermissionResult != null) {
            result.error("busy", "notification permission request already in progress", null)
            return
        }
        pendingNotificationPermissionResult = result
        ActivityCompat.requestPermissions(
            this,
            arrayOf(Manifest.permission.POST_NOTIFICATIONS),
            REQUEST_CODE_POST_NOTIFICATIONS,
        )
    }

    private fun handleShizukuPermissionRequest(result: MethodChannel.Result) {
        if (!isShizukuAvailable()) {
            result.success(false)
            return
        }
        if (hasShizukuPermission()) {
            result.success(true)
            return
        }
        if (pendingShizukuPermissionResult != null) {
            result.error("busy", "shizuku permission request already in progress", null)
            return
        }
        pendingShizukuPermissionResult = result
        runCatching {
            Shizuku.requestPermission(REQUEST_CODE_SHIZUKU)
        }.onFailure {
            pendingShizukuPermissionResult = null
            result.error(
                "shizuku_request_failed",
                it.message ?: "failed to request shizuku permission",
                null,
            )
        }
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray,
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode != REQUEST_CODE_POST_NOTIFICATIONS) {
            return
        }
        val granted =
            grantResults.isNotEmpty() && grantResults[0] == PackageManager.PERMISSION_GRANTED
        pendingNotificationPermissionResult?.success(granted)
        pendingNotificationPermissionResult = null
    }

    private fun isIgnoringBatteryOptimizations(): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.M) {
            return true
        }
        val powerManager = getSystemService(PowerManager::class.java) ?: return true
        return powerManager.isIgnoringBatteryOptimizations(packageName)
    }

    private fun hasManageAllFilesAccess(): Boolean {
        return Build.VERSION.SDK_INT < Build.VERSION_CODES.R || Environment.isExternalStorageManager()
    }

    private fun isShizukuInstalled(): Boolean {
        return isPackageInstalled("moe.shizuku.privileged.api") ||
            isPackageInstalled("moe.shizuku.manager")
    }

    private fun isPackageInstalled(packageName: String): Boolean {
        return runCatching {
            packageManager.getPackageInfo(packageName, 0)
            true
        }.getOrDefault(false)
    }

    private fun isShizukuAvailable(): Boolean {
        return runCatching {
            val binder = Shizuku.getBinder()
            binder?.isBinderAlive == true || Shizuku.pingBinder()
        }.getOrDefault(false)
    }

    private fun hasShizukuPermission(forceRefresh: Boolean = false): Boolean {
        val now = System.currentTimeMillis()
        if (!forceRefresh) {
            cachedShizukuPermission?.let { cached ->
                if (now - cachedShizukuPermissionAt < SHIZUKU_ACCESS_CACHE_MS) {
                    return cached
                }
            }
        }
        val granted = isShizukuAvailable() &&
            runCatching {
                Shizuku.checkSelfPermission() == PackageManager.PERMISSION_GRANTED
            }.getOrDefault(false)
        cachedShizukuPermission = granted
        cachedShizukuPermissionAt = now
        return granted
    }

    private fun hasRootAccess(forceRefresh: Boolean = false): Boolean {
        val now = System.currentTimeMillis()
        if (!forceRefresh) {
            cachedRootAccess?.let { cached ->
                if (now - cachedRootAccessAt < ROOT_ACCESS_CACHE_MS) {
                    return cached
                }
            }
        }
        val granted = runCatching {
            val completed = executeTextProcess(
                Runtime.getRuntime().exec(arrayOf("su", "-c", "id")),
                PRIVILEGED_PROCESS_TIMEOUT_MS,
                "root access check",
            )
            completed.exitCode == 0 &&
                (completed.stdout + completed.stderr).lowercase().contains("uid=0")
        }.getOrDefault(false)
        cachedRootAccess = granted
        cachedRootAccessAt = now
        return granted
    }

    private fun listDirectoriesWithRoot(path: String): List<String> {
        return listDirectoryEntriesWithRoot(path)
            .filter { it["type"] == "directory" }
            .map { it["name"].toString() }
            .distinct()
            .sortedBy { it.lowercase() }
    }

    private fun listDirectoryEntriesWithRoot(path: String): List<Map<String, String>> {
        if (false) {
            throw IllegalStateException("Root 未授权")
        }
        return listDirectoryEntriesWithCandidates(path, ::rootCandidatePaths) { command ->
            Runtime.getRuntime().exec(arrayOf("su", "-c", command))
        }
    }

    private fun readFileWithRoot(path: String): ByteArray {
        if (false) {
            throw IllegalStateException("Root 未授权")
        }
        return readFileWithCandidates(path, ::rootCandidatePaths) { command ->
            Runtime.getRuntime().exec(arrayOf("su", "-c", command))
        }
    }

    private fun writeFileWithRoot(path: String, bytes: ByteArray) {
        writeFileWithCandidates(path, bytes, ::rootCandidatePaths) { command ->
            Runtime.getRuntime().exec(arrayOf("su", "-c", command))
        }
    }

    private fun existsWithRoot(path: String): Boolean {
        if (false) {
            return false
        }
        return existsWithCandidates(path, ::rootCandidatePaths) { command ->
            Runtime.getRuntime().exec(arrayOf("su", "-c", command))
        }
    }

    private fun listDirectoriesWithShizuku(path: String): List<String> {
        return listDirectoryEntriesWithShizuku(path)
            .filter { it["type"] == "directory" }
            .map { it["name"].toString() }
            .distinct()
            .sortedBy { it.lowercase() }
    }

    private fun listDirectoryEntriesWithShizuku(path: String): List<Map<String, String>> {
        if (!hasShizukuPermission()) {
            throw IllegalStateException("Shizuku 未授权")
        }
        return runCatching {
            listDirectoryEntriesWithShizukuUserService(path)
        }.getOrElse { error ->
            Log.w(TAG, "Shizuku UserService directory listing failed for $path", error)
            listDirectoryEntriesWithShizukuShell(path)
        }
    }

    private fun listAndroidDataDirectoryWithShizuku(): List<Map<String, String>> {
        return listDirectoryEntriesWithShizuku(SHIZUKU_ANDROID_DATA_PATH)
    }

    private fun readFileWithShizuku(path: String): ByteArray {
        if (!hasShizukuPermission()) {
            throw IllegalStateException("Shizuku 未授权")
        }
        return runCatching {
            withShizukuUserService { service ->
                service.readFile(path)
            }
        }.getOrElse { error ->
            Log.w(TAG, "Shizuku UserService file read failed for $path", error)
            readFileWithShizukuShell(path)
        }
    }

    private fun writeFileWithShizuku(path: String, bytes: ByteArray) {
        if (!hasShizukuPermission()) {
            throw IllegalStateException("Shizuku permission not granted")
        }
        runCatching {
            withShizukuUserService { service ->
                service.writeFile(path, bytes)
            }
        }.getOrElse { error ->
            Log.w(TAG, "Shizuku UserService file write failed for $path", error)
            writeFileWithShizukuShell(path, bytes)
        }
    }

    private fun existsWithShizuku(path: String): Boolean {
        if (!hasShizukuPermission()) {
            return false
        }
        return runCatching {
            withShizukuUserService { service ->
                service.fileExists(path)
            }
        }.getOrElse { error ->
            Log.w(TAG, "Shizuku UserService file exists failed for $path", error)
            existsWithShizukuShell(path)
        }
    }

    private fun deletePathWithRoot(path: String) {
        deletePathWithCandidates(path, ::rootCandidatePaths) { command ->
            Runtime.getRuntime().exec(arrayOf("su", "-c", command))
        }
    }

    private fun deletePathWithShizuku(path: String) {
        if (!hasShizukuPermission()) {
            throw IllegalStateException("Shizuku 未授权")
        }
        runCatching {
            withShizukuUserService { service ->
                service.deletePath(path)
            }
        }.getOrElse { error ->
            Log.w(TAG, "Shizuku UserService delete failed for $path", error)
            deletePathWithShizukuShell(path)
        }
    }

    private fun movePathWithRoot(sourcePath: String, targetPath: String) {
        movePathWithCandidates(sourcePath, targetPath, ::rootCandidatePaths) { command ->
            Runtime.getRuntime().exec(arrayOf("su", "-c", command))
        }
    }

    private fun movePathWithShizuku(sourcePath: String, targetPath: String) {
        if (!hasShizukuPermission()) {
            throw IllegalStateException("Shizuku 未授权")
        }
        runCatching {
            withShizukuUserService { service ->
                service.movePath(sourcePath, targetPath)
            }
        }.getOrElse { error ->
            Log.w(TAG, "Shizuku UserService move failed for $sourcePath -> $targetPath", error)
            movePathWithShizukuShell(sourcePath, targetPath)
        }
    }

    private fun listDirectoryEntriesWithShizukuUserService(path: String): List<Map<String, String>> {
        return withShizukuUserService { service ->
            parseDirectoryEntries(service.listEntries(path).asSequence())
        }
    }

    private fun listDirectoryEntriesWithShizukuShell(path: String): List<Map<String, String>> {
        return listDirectoryEntriesWithCandidates(path) { command ->
            newShizukuProcess(arrayOf("sh", "-c", command), null, null)
        }
    }

    private fun readFileWithShizukuShell(path: String): ByteArray {
        return readFileWithCandidates(path) { command ->
            newShizukuProcess(arrayOf("sh", "-c", command), null, null)
        }
    }

    private fun writeFileWithShizukuShell(path: String, bytes: ByteArray) {
        writeFileWithCandidates(path, bytes) { command ->
            newShizukuProcess(arrayOf("sh", "-c", command), null, null)
        }
    }

    private fun existsWithShizukuShell(path: String): Boolean {
        return existsWithCandidates(path) { command ->
            newShizukuProcess(arrayOf("sh", "-c", command), null, null)
        }
    }

    private fun deletePathWithShizukuShell(path: String) {
        deletePathWithCandidates(path) { command ->
            newShizukuProcess(arrayOf("sh", "-c", command), null, null)
        }
    }

    private fun movePathWithShizukuShell(sourcePath: String, targetPath: String) {
        movePathWithCandidates(sourcePath, targetPath) { command ->
            newShizukuProcess(arrayOf("sh", "-c", command), null, null)
        }
    }

    private fun <T> withShizukuUserService(block: (IPicaKeepShizukuFileService) -> T): T {
        val service =
            getShizukuUserService()
                ?: throw IllegalStateException("Shizuku UserService 未就绪")
        return try {
            block(service)
        } catch (error: Throwable) {
            clearShizukuUserService()
            throw error
        }
    }

    private fun getShizukuUserService(
        timeoutMs: Long = SHIZUKU_USER_SERVICE_BIND_TIMEOUT_MS,
    ): IPicaKeepShizukuFileService? {
        if (!hasShizukuPermission()) {
            return null
        }
        shizukuUserService?.let { service ->
            if (service.asBinder()?.isBinderAlive == true) {
                return service
            }
        }
        bindShizukuUserServiceIfNeeded()
        val deadline = SystemClock.elapsedRealtime() + timeoutMs
        synchronized(shizukuUserServiceLock) {
            while (true) {
                shizukuUserService?.let { service ->
                    if (service.asBinder()?.isBinderAlive == true) {
                        return service
                    }
                }
                val remainingMs = deadline - SystemClock.elapsedRealtime()
                if (remainingMs <= 0L) {
                    return null
                }
                try {
                    shizukuUserServiceLock.wait(remainingMs)
                } catch (_: InterruptedException) {
                    Thread.currentThread().interrupt()
                    return null
                }
            }
        }
    }

    private fun ensureShizukuUserServiceBoundAsync() {
        storageExecutor.execute {
            bindShizukuUserServiceIfNeeded()
        }
    }

    private fun bindShizukuUserServiceIfNeeded() {
        if (!hasShizukuPermission()) {
            return
        }
        synchronized(shizukuUserServiceLock) {
            shizukuUserService?.let { service ->
                if (service.asBinder()?.isBinderAlive == true) {
                    return
                }
            }
            if (shizukuUserServiceBinding) {
                return
            }
            shizukuUserServiceBinding = true
        }
        runCatching {
            Shizuku.bindUserService(shizukuUserServiceArgs, shizukuUserServiceConnection)
        }.onFailure { error ->
            synchronized(shizukuUserServiceLock) {
                shizukuUserServiceBinding = false
                shizukuUserServiceLock.notifyAll()
            }
            Log.w(TAG, "Failed to bind Shizuku UserService", error)
        }
    }

    private fun clearShizukuUserService() {
        synchronized(shizukuUserServiceLock) {
            shizukuUserService = null
            shizukuUserServiceBinding = false
            shizukuUserServiceLock.notifyAll()
        }
    }

    private fun parseDirectoryEntries(lines: Sequence<String>): List<Map<String, String>> {
        return lines
            .map { it.trimEnd() }
            .filter { it.isNotBlank() }
            .mapNotNull { rawLine ->
                val parts = rawLine.split('\t', limit = 2)
                if (parts.size != 2) {
                    null
                } else {
                    val type = parts[0].trim()
                    val name = parts[1].trim()
                    when {
                        name.isEmpty() || name == "." || name == ".." -> null
                        type != "directory" && type != "file" -> null
                        else -> mapOf("type" to type, "name" to name)
                    }
                }
            }.distinctBy { "${it["type"]}\u0000${it["name"]}" }
            .sortedWith(
                compareBy<Map<String, String>> { it["type"] != "directory" }
                    .thenBy { it["name"]?.lowercase() },
            ).toList()
    }

    private fun listDirectoryEntriesWithCandidates(
        path: String,
        candidatePathProvider: (String) -> LinkedHashSet<String> = ::candidatePaths,
        startProcess: (String) -> Process,
    ): List<Map<String, String>> {
        var lastError: String? = null
        for (candidate in candidatePathProvider(path)) {
            val completed = try {
                executeTextProcess(
                    startProcess(directoryListCommand(candidate)),
                    PRIVILEGED_DIRECTORY_LIST_TIMEOUT_MS,
                    "directory listing for $candidate",
                )
            } catch (error: Throwable) {
                lastError = "$candidate: ${exceptionDetail(error)}"
                continue
            }
            val stderr = completed.stderr
            if (completed.exitCode == 0) {
                return parseDirectoryEntries(completed.stdout.lineSequence())
            }
            lastError = buildPrivilegedError(stderr, "目录不存在或当前应用不可访问", "目录读取失败")
        }
        throw IllegalStateException(lastError ?: "目录读取失败")
    }

    private fun readFileWithCandidates(
        path: String,
        candidatePathProvider: (String) -> LinkedHashSet<String> = ::candidatePaths,
        startProcess: (String) -> Process,
    ): ByteArray {
        var lastError: String? = null
        for (candidate in candidatePathProvider(path)) {
            val command =
                "if [ -f ${shellEscape(candidate)} ]; then cat ${shellEscape(candidate)}; else echo __PICAKKEEP_NO_FILE__ 1>&2; exit 2; fi"
            val completed = executeBytesProcess(startProcess(command))
            if (completed.exitCode == 0) {
                return completed.stdout
            }
            lastError = buildPrivilegedError(completed.stderr, "文件不存在或当前应用不可访问", "文件读取失败")
        }
        throw IllegalStateException(lastError ?: "文件读取失败")
    }

    private fun existsWithCandidates(
        path: String,
        candidatePathProvider: (String) -> LinkedHashSet<String> = ::candidatePaths,
        startProcess: (String) -> Process,
    ): Boolean {
        for (candidate in candidatePathProvider(path)) {
            val completed = executeTextProcess(
                startProcess("[ -e ${shellEscape(candidate)} ]"),
                PRIVILEGED_PROCESS_TIMEOUT_MS,
            )
            if (completed.exitCode == 0) {
                return true
            }
        }
        return false
    }

    private fun deletePathWithCandidates(
        path: String,
        candidatePathProvider: (String) -> LinkedHashSet<String> = ::candidatePaths,
        startProcess: (String) -> Process,
    ) {
        var lastError: String? = null
        for (candidate in candidatePathProvider(path)) {
            val command =
                "if [ -e ${shellEscape(candidate)} ] || [ -L ${shellEscape(candidate)} ]; then rm -rf ${shellEscape(candidate)}; else echo __PICAKKEEP_NO_PATH__ 1>&2; exit 2; fi"
            val completed = executeTextProcess(startProcess(command))
            if (completed.exitCode == 0) {
                return
            }
            lastError = buildPrivilegedError(
                completed.stderr,
                "路径不存在或当前应用不可访问",
                "文件删除失败",
            )
        }
        throw IllegalStateException(lastError ?: "文件删除失败")
    }

    private fun writeFileWithCandidates(
        path: String,
        bytes: ByteArray,
        candidatePathProvider: (String) -> LinkedHashSet<String> = ::candidatePaths,
        startProcess: (String) -> Process,
    ) {
        var lastError: String? = null
        for (candidate in candidatePathProvider(path)) {
            val targetParent = parentPath(candidate)
            val tempPath = "$candidate.__picakeep_tmp__"
            val command =
                "mkdir -p ${shellEscape(targetParent)} && tmp=${shellEscape(tempPath)} && cat > \"\$tmp\" && mv \"\$tmp\" ${shellEscape(candidate)}"
            val completed = executeBinaryWriteProcess(startProcess(command), bytes)
            if (completed.exitCode == 0) {
                return
            }
            lastError = if (completed.stderr.isNotBlank()) completed.stderr else "File write failed"
        }
        throw IllegalStateException(lastError ?: "File write failed")
    }

    private fun movePathWithCandidates(
        sourcePath: String,
        targetPath: String,
        candidatePathProvider: (String) -> LinkedHashSet<String> = ::candidatePaths,
        startProcess: (String) -> Process,
    ) {
        var lastError: String? = null
        for (sourceCandidate in candidatePathProvider(sourcePath)) {
            for (targetCandidate in candidatePathProvider(targetPath)) {
                val targetParent = parentPath(targetCandidate)
                val command =
                    "if [ -e ${shellEscape(sourceCandidate)} ] || [ -L ${shellEscape(sourceCandidate)} ]; then mkdir -p ${shellEscape(targetParent)} && mv ${shellEscape(sourceCandidate)} ${shellEscape(targetCandidate)}; else echo __PICAKKEEP_NO_PATH__ 1>&2; exit 2; fi"
                val completed = executeTextProcess(startProcess(command))
                if (completed.exitCode == 0) {
                    return
                }
                lastError = buildPrivilegedError(
                    completed.stderr,
                    "路径不存在或当前应用不可访问",
                    "文件移动失败",
                )
            }
        }
        throw IllegalStateException(lastError ?: "文件移动失败")
    }

    private fun candidatePaths(path: String): LinkedHashSet<String> {
        val normalized = path.trim().ifEmpty { "/" }
        val candidatePaths = linkedSetOf(normalized)
        if (normalized == "/data/user/0") {
            candidatePaths.add("/data/data")
            candidatePaths.add("/data_mirror/data_ce/null/0")
        }
        if (normalized.startsWith("/data/user/0/")) {
            candidatePaths.add(normalized.replaceFirst("/data/user/0/", "/data/data/"))
            candidatePaths.add(
                normalized.replaceFirst("/data/user/0/", "/data_mirror/data_ce/null/0/"),
            )
        }
        if (normalized == "/data/data") {
            candidatePaths.add("/data/user/0")
            candidatePaths.add("/data_mirror/data_ce/null/0")
        }
        if (normalized.startsWith("/data/data/")) {
            candidatePaths.add(normalized.replaceFirst("/data/data/", "/data/user/0/"))
            candidatePaths.add(
                normalized.replaceFirst("/data/data/", "/data_mirror/data_ce/null/0/"),
            )
        }
        if (normalized == "/data_mirror/data_ce/null/0") {
            candidatePaths.add("/data/user/0")
            candidatePaths.add("/data/data")
        }
        if (normalized.startsWith("/data_mirror/data_ce/null/0/")) {
            candidatePaths.add(
                normalized.replaceFirst("/data_mirror/data_ce/null/0/", "/data/user/0/"),
            )
            candidatePaths.add(
                normalized.replaceFirst("/data_mirror/data_ce/null/0/", "/data/data/"),
            )
        }
        if (normalized.startsWith("/storage/emulated/0/")) {
            candidatePaths.add(normalized.replaceFirst("/storage/emulated/0/", "/sdcard/"))
        }
        if (normalized.startsWith("/sdcard/")) {
            candidatePaths.add(normalized.replaceFirst("/sdcard/", "/storage/emulated/0/"))
        }
        return candidatePaths
    }

    private fun rootCandidatePaths(path: String): LinkedHashSet<String> {
        val normalized = path.trim().ifEmpty { "/" }
        val candidates = linkedSetOf<String>()
        realSharedStoragePath(normalized)?.let { candidates.add(it) }
        candidates.addAll(candidatePaths(normalized))
        return candidates
    }

    private fun realSharedStoragePath(path: String): String? {
        val normalized = path.trim().ifEmpty { "/" }
        return when {
            normalized == "/storage/emulated/0" -> "/data/media/0"
            normalized.startsWith("/storage/emulated/0/") ->
                normalized.replaceFirst("/storage/emulated/0/", "/data/media/0/")
            normalized == "/sdcard" -> "/data/media/0"
            normalized.startsWith("/sdcard/") ->
                normalized.replaceFirst("/sdcard/", "/data/media/0/")
            else -> null
        }
    }

    private fun directoryListCommand(candidate: String): String =
        """
        target=${shellEscape(candidate)}
        if [ ! -e "${'$'}target" ]; then
          echo __PICAKKEEP_NODIR__ 1>&2
          exit 2
        fi
        if [ ! -d "${'$'}target" ]; then
          echo __PICAKKEEP_NOTDIR__ 1>&2
          exit 3
        fi
        cd "${'$'}target" || {
          echo __PICAKKEEP_CD_FAILED__ 1>&2
          exit 4
        }

        list_with_ls() {
          LC_ALL=C ls -1A 2>/dev/null | while IFS= read -r name; do
            [ -n "${'$'}name" ] || continue
            [ "${'$'}name" = "." ] && continue
            [ "${'$'}name" = ".." ] && continue
            if [ -d "${'$'}name" ]; then
              kind=directory
            elif [ -f "${'$'}name" ]; then
              kind=file
            else
              kind=other
            fi
            printf '%s\t%s\n' "${'$'}kind" "${'$'}name"
          done
        }

        list_with_find() {
          find . -mindepth 1 -maxdepth 1 2>/dev/null | while IFS= read -r item; do
            [ -n "${'$'}item" ] || continue
            name=${'$'}{item#./}
            [ -n "${'$'}name" ] || continue
            if [ -d "${'$'}item" ]; then
              kind=directory
            elif [ -f "${'$'}item" ]; then
              kind=file
            else
              kind=other
            fi
            printf '%s\t%s\n' "${'$'}kind" "${'$'}name"
          done
        }

        output=${'$'}(list_with_ls)
        status=${'$'}?
        if [ ${'$'}status -eq 0 ] && [ -n "${'$'}output" ]; then
          printf '%s\n' "${'$'}output"
          exit 0
        fi

        output=${'$'}(list_with_find)
        status=${'$'}?
        if [ ${'$'}status -eq 0 ]; then
          printf '%s\n' "${'$'}output"
          exit 0
        fi

        echo __PICAKKEEP_LIST_FAILED__ 1>&2
        exit 5
        """.trimIndent()

    private fun parentPath(path: String): String {
        val normalized = path.trim().ifEmpty { "/" }
        val index = normalized.replace('\\', '/').lastIndexOf('/')
        return when {
            index <= 0 -> "/"
            else -> normalized.substring(0, index)
        }
    }

    private fun buildPrivilegedError(stderr: String, notFoundMessage: String, fallback: String): String {
        return if (stderr.contains("__PICAKKEEP_NO_DIR__") ||
            stderr.contains("__PICAKKEEP_NODIR__") ||
            stderr.contains("__PICAKKEEP_NO_FILE__") ||
            stderr.contains("__PICAKKEEP_NO_PATH__")
        ) {
            notFoundMessage
        } else if (stderr.contains("__PICAKKEEP_NOTDIR__")) {
            "目标不是目录"
        } else if (stderr.contains("__PICAKKEEP_CD_FAILED__")) {
            "进入目录失败"
        } else if (stderr.contains("__PICAKKEEP_LIST_FAILED__")) {
            "目录列出命令失败"
        } else if (stderr.isNotBlank()) {
            stderr
        } else {
            fallback
        }
    }

    private fun exceptionDetail(error: Throwable): String {
        return error.message?.takeIf { it.isNotBlank() } ?: error.javaClass.simpleName
    }

    private fun newShizukuProcess(
        command: Array<String>,
        environment: Array<String>?,
        workingDirectory: String?,
    ): Process {
        val method =
            Shizuku::class.java.getDeclaredMethod(
                "newProcess",
                Array<String>::class.java,
                Array<String>::class.java,
                String::class.java,
            )
        method.isAccessible = true
        return method.invoke(null, command, environment, workingDirectory) as Process
    }

    private fun openManageAllFilesAccessSettings() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.R) {
            return
        }
        val appIntent = Intent(Settings.ACTION_MANAGE_APP_ALL_FILES_ACCESS_PERMISSION).apply {
            data = Uri.parse("package:$packageName")
        }
        runCatching {
            startActivity(appIntent)
        }.onFailure {
            launchSettingsIntent(Intent(Settings.ACTION_MANAGE_ALL_FILES_ACCESS_PERMISSION))
        }
    }

    private fun openShizukuApp() {
        val launchIntent =
            packageManager.getLaunchIntentForPackage("moe.shizuku.privileged.api")
                ?: packageManager.getLaunchIntentForPackage("moe.shizuku.manager")
        if (launchIntent != null) {
            startActivity(launchIntent)
            return
        }
        startActivity(
            Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS).apply {
                data = Uri.parse("package:moe.shizuku.privileged.api")
            },
        )
    }

    private fun openNotificationSettings() {
        launchSettingsIntent(
            Intent(Settings.ACTION_APP_NOTIFICATION_SETTINGS).apply {
                putExtra(Settings.EXTRA_APP_PACKAGE, packageName)
            },
        )
    }

    private fun openBatteryOptimizationSettings() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.M) {
            return
        }
        val action =
            if (isIgnoringBatteryOptimizations()) {
                Settings.ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS
            } else {
                Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS
            }
        launchSettingsIntent(
            Intent(action).apply {
                if (action == Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS) {
                    data = Uri.parse("package:$packageName")
                }
            },
        )
    }

    private fun launchSettingsIntent(intent: Intent) {
        runCatching {
            startActivity(intent)
        }.onFailure {
            startActivity(
                Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS).apply {
                    data = Uri.parse("package:$packageName")
                },
            )
        }
    }

    private fun acquireMulticastLock() {
        val existingLock = multicastLock
        if (existingLock?.isHeld == true) {
            return
        }
        val wifiManager = applicationContext.getSystemService(Context.WIFI_SERVICE) as? WifiManager
            ?: return
        multicastLock = wifiManager.createMulticastLock("picakeep-mdns").apply {
            setReferenceCounted(false)
            acquire()
        }
    }

    private fun releaseMulticastLock() {
        multicastLock?.let { lock ->
            runCatching {
                if (lock.isHeld) {
                    lock.release()
                }
            }
        }
        multicastLock = null
    }

    private fun currentLauncherIconId(): String {
        val packageManager = packageManager
        return launcherIcons.firstOrNull { icon ->
            packageManager.getComponentEnabledSetting(icon.componentName(this)) ==
                PackageManager.COMPONENT_ENABLED_STATE_ENABLED
        }?.id ?: launcherIcons.first().id
    }

    private fun setLauncherIcon(id: String) {
        val packageManager = packageManager
        launcherIcons.forEach { icon ->
            packageManager.setComponentEnabledSetting(
                icon.componentName(this),
                if (icon.id == id) {
                    PackageManager.COMPONENT_ENABLED_STATE_ENABLED
                } else {
                    PackageManager.COMPONENT_ENABLED_STATE_DISABLED
                },
                PackageManager.DONT_KILL_APP,
            )
        }
    }

    private fun shellEscape(value: String): String =
        "'" + value.replace("'", "'\"'\"'") + "'"

    private data class LauncherIcon(
        val id: String,
        val label: String,
        val className: String,
    ) {
        fun componentName(activity: MainActivity): ComponentName =
            ComponentName(activity.packageName, "${activity.packageName}.$className")

        fun toMap(): Map<String, String> = mapOf(
            "id" to id,
            "label" to label,
        )
    }

    companion object {
        private const val TAG = "PicaKeepStartup"
        private const val FOREGROUND_SERVICE_CHANNEL =
            "lingxue.picakeep/foreground_service"
        private const val KEEP_SCREEN_ON_CHANNEL =
            "lingxue.picakeep/keepScreenOn"
        private const val MULTICAST_LOCK_CHANNEL =
            "lingxue.picakeep/multicast_lock"
        private const val APP_ICON_CHANNEL =
            "lingxue.picakeep/app_icon"
        private const val NIGHT_MODE_CHANNEL =
            "lingxue.picakeep/night_mode"
        private const val DYNAMIC_THEME_CHANNEL =
            "lingxue.picakeep/dynamic_theme"
        private const val STORAGE_ACCESS_CHANNEL =
            "lingxue.picakeep/storage_access"
        private const val REQUEST_CODE_POST_NOTIFICATIONS = 1001
        private const val REQUEST_CODE_SHIZUKU = 1002
        private const val PRIVILEGED_PROCESS_TIMEOUT_MS = 5_000L
        private const val PRIVILEGED_DIRECTORY_LIST_TIMEOUT_MS = 45_000L
        private const val PRIVILEGED_READ_TIMEOUT_MS = 15_000L
        private const val SHIZUKU_ACCESS_CACHE_MS = 1_500L
        private const val SHIZUKU_USER_SERVICE_BIND_TIMEOUT_MS = 4_000L
        private const val ROOT_ACCESS_CACHE_MS = 30 * 60 * 1000L
        private const val SHIZUKU_ANDROID_DATA_PATH = "/storage/emulated/0/Android/data"
        private val launcherIcons = listOf(
            LauncherIcon("blue", "Blue", "LauncherBlue"),
            LauncherIcon("coral", "Coral", "LauncherCoral"),
            LauncherIcon("red", "Red", "LauncherRed"),
            LauncherIcon("pink", "Pink", "LauncherPink"),
            LauncherIcon("purple", "Purple", "LauncherPurple"),
            LauncherIcon("indigo", "Indigo", "LauncherIndigo"),
            LauncherIcon("cyan", "Cyan", "LauncherCyan"),
            LauncherIcon("teal", "Teal", "LauncherTeal"),
            LauncherIcon("green", "Green", "LauncherGreen"),
            LauncherIcon("lime", "Lime", "LauncherLime"),
            LauncherIcon("yellow", "Yellow", "LauncherYellow"),
            LauncherIcon("amber", "Amber", "LauncherAmber"),
            LauncherIcon("orange", "Orange", "LauncherOrange"),
        )
    }
}
