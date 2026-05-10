package com.example.picakeep

import android.Manifest
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.Environment
import android.os.Handler
import android.os.Looper
import android.os.PowerManager
import android.os.SystemClock
import android.provider.Settings
import android.util.Log
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

    private val shizukuPermissionListener =
        Shizuku.OnRequestPermissionResultListener { requestCode, grantResult ->
            if (requestCode != REQUEST_CODE_SHIZUKU) {
                return@OnRequestPermissionResultListener
            }
            val granted = grantResult == PackageManager.PERMISSION_GRANTED
            cachedShizukuPermission = granted
            cachedShizukuPermissionAt = System.currentTimeMillis()
            pendingShizukuPermissionResult?.success(granted)
            pendingShizukuPermissionResult = null
        }

    override fun onCreate(savedInstanceState: Bundle?) {
        Log.i(TAG, "startup onCreate +${SystemClock.elapsedRealtime() - launchStartElapsedMs}ms")
        super.onCreate(savedInstanceState)
        WindowCompat.setDecorFitsSystemWindows(window, false)
        window.statusBarColor = android.graphics.Color.TRANSPARENT
        window.navigationBarColor = android.graphics.Color.TRANSPARENT
        WindowCompat.getInsetsController(window, window.decorView)?.systemBarsBehavior =
            WindowInsetsControllerCompat.BEHAVIOR_SHOW_TRANSIENT_BARS_BY_SWIPE
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
            STORAGE_ACCESS_CHANNEL,
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "hasManageAllFilesAccess" -> result.success(hasManageAllFilesAccess())
                "openManageAllFilesAccessSettings" -> {
                    openManageAllFilesAccessSettings()
                    result.success(null)
                }
                "isShizukuAvailable" -> result.success(isShizukuAvailable())
                "hasShizukuPermission" -> result.success(hasShizukuPermission())
                "getShizukuStatus" -> {
                    result.success(
                        mapOf(
                            "installed" to isShizukuInstalled(),
                            "running" to isShizukuAvailable(),
                            "permissionGranted" to hasShizukuPermission(),
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
                    hasRootAccess()
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
    ): ProcessTextResult {
        val stdout = storageExecutor.submit<String> {
            process.inputStream.bufferedReader().use { it.readText() }
        }
        val stderr = storageExecutor.submit<String> {
            process.errorStream.bufferedReader().use { it.readText().trim() }
        }
        val waitResult = storageExecutor.submit<Int> {
            process.waitFor()
        }
        try {
            val exitCode = waitResult.get(timeoutMs, TimeUnit.MILLISECONDS)
            return ProcessTextResult(
                exitCode,
                stdout.get(1, TimeUnit.SECONDS),
                stderr.get(1, TimeUnit.SECONDS),
            )
        } catch (error: Throwable) {
            process.destroyForcibly()
            waitResult.cancel(true)
            stdout.cancel(true)
            stderr.cancel(true)
            throw error
        }
    }

    private fun executeBytesProcess(
        process: Process,
        timeoutMs: Long = PRIVILEGED_READ_TIMEOUT_MS,
    ): ProcessBytesResult {
        val stdout = storageExecutor.submit<ByteArray> {
            process.inputStream.use { it.readBytes() }
        }
        val stderr = storageExecutor.submit<String> {
            process.errorStream.bufferedReader().use { it.readText().trim() }
        }
        val waitResult = storageExecutor.submit<Int> {
            process.waitFor()
        }
        try {
            val exitCode = waitResult.get(timeoutMs, TimeUnit.MILLISECONDS)
            return ProcessBytesResult(
                exitCode,
                stdout.get(1, TimeUnit.SECONDS),
                stderr.get(1, TimeUnit.SECONDS),
            )
        } catch (error: Throwable) {
            process.destroyForcibly()
            waitResult.cancel(true)
            stdout.cancel(true)
            stderr.cancel(true)
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

    private fun hasShizukuPermission(): Boolean {
        val now = System.currentTimeMillis()
        cachedShizukuPermission?.let { cached ->
            if (now - cachedShizukuPermissionAt < ACCESS_CACHE_MS) {
                return cached
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

    private fun hasRootAccess(): Boolean {
        val now = System.currentTimeMillis()
        cachedRootAccess?.let { cached ->
            if (now - cachedRootAccessAt < ACCESS_CACHE_MS) {
                return cached
            }
        }
        val granted = runCatching {
            val completed = executeTextProcess(
                Runtime.getRuntime().exec(arrayOf("su", "-c", "id")),
                PRIVILEGED_PROCESS_TIMEOUT_MS,
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
        if (!hasRootAccess()) {
            throw IllegalStateException("Root 未授权")
        }
        return listDirectoryEntriesWithCandidates(path) { command ->
            Runtime.getRuntime().exec(arrayOf("su", "-c", command))
        }
    }

    private fun readFileWithRoot(path: String): ByteArray {
        if (!hasRootAccess()) {
            throw IllegalStateException("Root 未授权")
        }
        return readFileWithCandidates(path) { command ->
            Runtime.getRuntime().exec(arrayOf("su", "-c", command))
        }
    }

    private fun existsWithRoot(path: String): Boolean {
        if (!hasRootAccess()) {
            return false
        }
        return existsWithCandidates(path) { command ->
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
        return listDirectoryEntriesWithCandidates(path) { command ->
            newShizukuProcess(arrayOf("sh", "-c", command), null, null)
        }
    }

    private fun readFileWithShizuku(path: String): ByteArray {
        if (!hasShizukuPermission()) {
            throw IllegalStateException("Shizuku 未授权")
        }
        return readFileWithCandidates(path) { command ->
            newShizukuProcess(arrayOf("sh", "-c", command), null, null)
        }
    }

    private fun existsWithShizuku(path: String): Boolean {
        if (!hasShizukuPermission()) {
            return false
        }
        return existsWithCandidates(path) { command ->
            newShizukuProcess(arrayOf("sh", "-c", command), null, null)
        }
    }

    private fun listDirectoryEntriesWithCandidates(
        path: String,
        startProcess: (String) -> Process,
    ): List<Map<String, String>> {
        var lastError: String? = null
        for (candidate in candidatePaths(path)) {
            val command =
                "if [ -d ${shellEscape(candidate)} ]; then cd ${shellEscape(candidate)} && for e in ./* ./.[!.]* ./..?*; do [ -e \"\$e\" ] || continue; name=\${e#./}; if [ -d \"\$e\" ]; then printf 'd\\t%s\\n' \"\$name\"; elif [ -f \"\$e\" ]; then printf 'f\\t%s\\n' \"\$name\"; fi; done; else echo __PICAKKEEP_NO_DIR__ 1>&2; exit 2; fi"
            val completed = executeTextProcess(startProcess(command))
            val stdout = completed.stdout
            val stderr = completed.stderr
            if (completed.exitCode == 0) {
                return stdout
                    .lineSequence()
                    .map { it.trim() }
                    .filter { it.isNotEmpty() }
                    .mapNotNull { line ->
                        val index = line.indexOf('\t')
                        if (index <= 0 || index == line.length - 1) {
                            null
                        } else {
                            val type = if (line.substring(0, index) == "d") "directory" else "file"
                            val name = line.substring(index + 1).trim()
                            if (name.isEmpty() || name == "." || name == "..") {
                                null
                            } else {
                                mapOf("type" to type, "name" to name)
                            }
                        }
                    }
                    .distinctBy { "${it["type"]}\u0000${it["name"]}" }
                    .sortedWith(compareBy<Map<String, String>> { it["type"] != "directory" }.thenBy { it["name"]?.lowercase() })
                    .toList()
            }
            lastError = buildPrivilegedError(stderr, "目录不存在或当前应用不可访问", "目录读取失败")
        }
        throw IllegalStateException(lastError ?: "目录读取失败")
    }

    private fun readFileWithCandidates(
        path: String,
        startProcess: (String) -> Process,
    ): ByteArray {
        var lastError: String? = null
        for (candidate in candidatePaths(path)) {
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
        startProcess: (String) -> Process,
    ): Boolean {
        for (candidate in candidatePaths(path)) {
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

    private fun candidatePaths(path: String): LinkedHashSet<String> {
        val normalized = path.trim().ifEmpty { "/" }
        val candidatePaths = linkedSetOf(normalized)
        if (normalized.startsWith("/data/user/0/")) {
            candidatePaths.add(normalized.replaceFirst("/data/user/0/", "/data/data/"))
        }
        if (normalized.startsWith("/data/data/")) {
            candidatePaths.add(normalized.replaceFirst("/data/data/", "/data/user/0/"))
        }
        if (normalized.startsWith("/storage/emulated/0/")) {
            candidatePaths.add(normalized.replaceFirst("/storage/emulated/0/", "/sdcard/"))
        }
        if (normalized.startsWith("/sdcard/")) {
            candidatePaths.add(normalized.replaceFirst("/sdcard/", "/storage/emulated/0/"))
        }
        return candidatePaths
    }

    private fun buildPrivilegedError(stderr: String, notFoundMessage: String, fallback: String): String {
        return if (stderr.contains("__PICAKKEEP_NO_DIR__") || stderr.contains("__PICAKKEEP_NO_FILE__")) {
            notFoundMessage
        } else if (stderr.isNotBlank()) {
            stderr
        } else {
            fallback
        }
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

    private fun shellEscape(value: String): String =
        "'" + value.replace("'", "'\"'\"'") + "'"

    companion object {
        private const val TAG = "PicaKeepStartup"
        private const val FOREGROUND_SERVICE_CHANNEL =
            "com.example.picakeep/foreground_service"
        private const val STORAGE_ACCESS_CHANNEL =
            "com.example.picakeep/storage_access"
        private const val REQUEST_CODE_POST_NOTIFICATIONS = 1001
        private const val REQUEST_CODE_SHIZUKU = 1002
        private const val PRIVILEGED_PROCESS_TIMEOUT_MS = 5_000L
        private const val PRIVILEGED_READ_TIMEOUT_MS = 15_000L
        private const val ACCESS_CACHE_MS = 1_500L
    }
}
