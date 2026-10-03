package lingxue.picakeep

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.os.PowerManager
import android.os.SystemClock
import android.util.Log
import androidx.core.app.NotificationCompat
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import java.util.Locale

/** Native queue state survives Activity recreation; it never owns download files. */
object DownloadRuntime {
    const val CHANNEL = "lingxue.picakeep/download_notification"
    const val EXTRA_ROUTE = "picakeep.download.route"
    const val NOTIFICATION_ID = 9528
    const val CHANNEL_ID = "picakeep_download"
    private var channel: MethodChannel? = null
    private var messengerOwner: BinaryMessenger? = null
    private val handler = Handler(Looper.getMainLooper())
    var service: PicaKeepDownloadService? = null
    var starting = false
    var latest = emptyMap<String, Any?>()
    var failure: String? = null
    var lastHeartbeat = SystemClock.elapsedRealtime()
    var pendingRoute: String? = null
    var dismissed = false
    var networkAvailable = true

    fun connect(context: Context, messenger: BinaryMessenger) {
        val app = context.applicationContext
        channel?.setMethodCallHandler(null)
        messengerOwner = messenger
        networkAvailable = hasNetwork(app)
        channel = MethodChannel(messenger, CHANNEL).also { bridge ->
            bridge.setMethodCallHandler { call, result ->
                when (call.method) {
                    "update", "finish", "cancel" -> {
                        val args = call.arguments as? Map<*, *> ?: emptyMap<Any, Any>()
                        latest = args.entries.associate { it.key.toString() to it.value }
                        if (call.method == "cancel") latest = mapOf("state" to "empty")
                        lastHeartbeat = SystemClock.elapsedRealtime()
                        val state = latest["state"] as? String ?: "empty"
                        if (state == "running" || state == "waiting") {
                            dismissed = false
                            if (service != null) {
                                service?.applyLatest()
                            } else if (!starting && failure == null) {
                                starting = true
                                try {
                                    val intent = Intent(app, PicaKeepDownloadService::class.java)
                                    if (Build.VERSION.SDK_INT >= 26) app.startForegroundService(intent)
                                    else app.startService(intent)
                                } catch (error: Exception) {
                                    Log.w("PicaKeepDownload", "Could not start download foreground service", error)
                                    starting = false
                                    fail("系统暂不允许后台下载，请保持应用打开，或返回前台后继续")
                                }
                            }
                        } else if (service != null) {
                            service?.applyLatest()
                        } else if (!starting && !dismissed) {
                            publishTerminal(app)
                        }
                        result.success(status())
                    }
                    "status" -> result.success(status().plus("networkAvailable" to hasNetwork(app)))
                    "getInitialIntent" -> {
                        val route = pendingRoute
                        pendingRoute = null
                        result.success(route)
                    }
                    "foregrounded" -> {
                        failure = null
                        networkAvailable = hasNetwork(app)
                        event("networkChanged", networkAvailable)
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            }
        }
    }

    fun disconnect(messenger: BinaryMessenger?) {
        if (messengerOwner !== messenger) return
        channel?.setMethodCallHandler(null)
        channel = null
        messengerOwner = null
    }

    fun captureIntent(intent: Intent?) {
        val route = intent?.getStringExtra(EXTRA_ROUTE)
        if (route == "queue" || route == "downloaded") {
            pendingRoute = route
            intent.removeExtra(EXTRA_ROUTE)
            // Merely a hint. Cold starts always pull the retained payload.
            event("intentAvailable", null)
        }
    }

    fun event(name: String, payload: Any?) {
        handler.post { channel?.invokeMethod(name, payload) }
    }

    fun fail(message: String) {
        failure = message
        event("serviceStopped", message)
    }

    fun status(): Map<String, Any?> = mapOf(
        "failure" to failure,
        "serviceRunning" to (service != null),
        "networkAvailable" to networkAvailable,
    )

    fun hasNetwork(context: Context): Boolean {
        val manager = context.getSystemService(ConnectivityManager::class.java) ?: return true
        val caps = manager.getNetworkCapabilities(manager.activeNetwork) ?: return false
        // Validation can be unavailable with a private VPN/proxy. Real requests
        // remain authoritative; do not reject usable networks on that basis.
        return caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)
    }

    fun ensureChannel(context: Context) {
        if (Build.VERSION.SDK_INT >= 26) {
            context.getSystemService(NotificationManager::class.java).createNotificationChannel(
                NotificationChannel(CHANNEL_ID, "下载进度", NotificationManager.IMPORTANCE_LOW).apply {
                    description = "漫画与插画的下载进度及后台下载状态"
                    setShowBadge(false)
                },
            )
        }
    }

    private fun routeIntent(context: Context, route: String, code: Int): PendingIntent {
        val intent = Intent(context, MainActivity::class.java).apply {
            flags = Intent.FLAG_ACTIVITY_SINGLE_TOP
            putExtra(EXTRA_ROUTE, route)
        }
        return PendingIntent.getActivity(
            context, code, intent, PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
    }

    fun notification(context: Context, foreground: Boolean): Notification {
        val state = latest["state"] as? String ?: "paused"
        val total = (latest["total"] as? Number)?.toInt() ?: 0
        val done = (latest["completed"] as? Number)?.toInt() ?: 0
        val percent = ((latest["percent"] as? Number)?.toInt() ?: 0).coerceIn(0, 100)
        val title = when (state) {
            "running" -> "正在下载 $done/$total 本"
            "waiting" -> "等待网络 · 已完成 $done/$total 本"
            "finished" -> "下载完成 · $done/$total 本"
            "failed" -> "下载失败 · 已完成 $done/$total 本"
            else -> "已暂停 · 共 $total 本"
        }
        val content = when (state) {
            "running" -> "${latest["title"] ?: ""} · ${speedText((latest["speed"] as? Number)?.toLong() ?: 0)}"
            "waiting" -> "网络恢复后自动继续；可在下载管理器中暂停"
            "finished" -> "全部下载完成，点按查看下载队列"
            "failed" -> "部分任务未完成，点按查看并重试"
            else -> failure ?: "点按打开下载管理器继续下载"
        }
        val deleteIntent = PendingIntent.getBroadcast(
            context, 9528,
            Intent(context, DownloadNoticeDismissReceiver::class.java),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        return NotificationCompat.Builder(context, CHANNEL_ID)
            .setSmallIcon(R.drawable.ic_stat_download)
            .setContentTitle(title)
            .setContentText(content)
            .setStyle(NotificationCompat.BigTextStyle().bigText(content))
            .setOnlyAlertOnce(true)
            .setSilent(true)
            .setOngoing(foreground)
            .setAutoCancel(!foreground && state != "finished")
            .setCategory(NotificationCompat.CATEGORY_PROGRESS)
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .setContentIntent(routeIntent(context, "queue", 9528))
            .addAction(0, "打开", routeIntent(context, "downloaded", 9529))
            .setDeleteIntent(deleteIntent)
            .apply {
                if (state == "running") setProgress(100, percent, false)
                else setProgress(0, 0, false)
            }
            .build()
    }

    fun displayKey(): String = listOf(
        latest["state"], latest["total"], latest["completed"], latest["currentId"],
        latest["title"], latest["percent"], speedText((latest["speed"] as? Number)?.toLong() ?: 0),
    ).joinToString("|")

    fun speedText(value: Long): String = when {
        value >= 1024 * 1024 -> String.format(Locale.ROOT, "%.1f MB/s", value / (1024.0 * 1024))
        value >= 1024 -> String.format(Locale.ROOT, "%.1f KB/s", value / 1024.0)
        else -> "$value B/s"
    }

    fun publishTerminal(context: Context) {
        ensureChannel(context)
        val manager = context.getSystemService(NotificationManager::class.java)
        if (latest["state"] == "empty") manager.cancel(NOTIFICATION_ID)
        else if (!dismissed) {
            // A denied notification permission must never fail the download.
            runCatching { manager.notify(NOTIFICATION_ID, notification(context, false)) }
        }
    }
}

class DownloadNoticeDismissReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        DownloadRuntime.dismissed = true
        DownloadRuntime.event("dismissed", null)
    }
}

/** This service protects the existing Dart downloader while its engine is alive. */
class PicaKeepDownloadService : Service() {
    private val handler = Handler(Looper.getMainLooper())
    private var wakeLock: PowerManager.WakeLock? = null
    private var renewWakeLockAt = 0L
    private var callback: ConnectivityManager.NetworkCallback? = null
    private var promoted = false
    private var lastDisplayKey: String? = null
    private var lastNotifyAt = 0L
    private var lastTransition: String? = null
    private val watchdog = object : Runnable {
        override fun run() {
            // No Dart heartbeat: never leave a ghost foreground notification or
            // an unbounded CPU lock after the engine has gone away.
            if (SystemClock.elapsedRealtime() - DownloadRuntime.lastHeartbeat > 90_000) {
                stopWithReason("下载已中断，请打开应用继续未完成任务")
                return
            }
            if (DownloadRuntime.latest["state"] == "running") acquireCpu()
            handler.postDelayed(this, 30_000)
        }
    }

    override fun onCreate() {
        super.onCreate()
        DownloadRuntime.service = this
        DownloadRuntime.ensureChannel(this)
        registerNetwork()
        handler.postDelayed(watchdog, 30_000)
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        DownloadRuntime.service = this
        DownloadRuntime.starting = false
        try {
            // Always fulfill the startForegroundService deadline, even when a
            // very fast task finished before Android delivered this command.
            val notice = DownloadRuntime.notification(this, true)
            if (Build.VERSION.SDK_INT >= 29) {
                startForeground(DownloadRuntime.NOTIFICATION_ID, notice, ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC)
            } else {
                startForeground(DownloadRuntime.NOTIFICATION_ID, notice)
            }
            promoted = true
            applyLatest()
        } catch (error: Exception) {
            Log.w("PicaKeepDownload", "Could not promote download foreground service", error)
            stopWithReason("系统暂不允许后台下载，请保持应用打开，或返回前台后继续")
        }
        return START_NOT_STICKY
    }

    fun applyLatest() {
        if (!promoted) return
        val state = DownloadRuntime.latest["state"]
        if (state != "running" && state != "waiting") {
            releaseCpu()
            stopForeground(STOP_FOREGROUND_DETACH)
            promoted = false
            DownloadRuntime.publishTerminal(this)
            if (DownloadRuntime.service === this) DownloadRuntime.service = null
            stopSelf()
            return
        }
        if (state == "running") acquireCpu() else releaseCpu()
        val key = DownloadRuntime.displayKey()
        val transition = "${state}|${DownloadRuntime.latest["total"]}|${DownloadRuntime.latest["completed"]}|${DownloadRuntime.latest["currentId"]}"
        val now = SystemClock.elapsedRealtime()
        if (key == lastDisplayKey || (transition == lastTransition && now - lastNotifyAt < 1000)) return
        lastDisplayKey = key
        lastTransition = transition
        lastNotifyAt = now
        runCatching {
            getSystemService(NotificationManager::class.java).notify(
                DownloadRuntime.NOTIFICATION_ID, DownloadRuntime.notification(this, true),
            )
        }
    }

    private fun acquireCpu() {
        val now = SystemClock.elapsedRealtime()
        if (wakeLock?.isHeld == true && now < renewWakeLockAt) return
        try {
            if (wakeLock == null) {
                wakeLock = getSystemService(PowerManager::class.java)
                    .newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "PicaKeep:download").apply {
                        setReferenceCounted(false)
                    }
            }
            // Non-reference-counted acquire renews the bounded timeout before
            // expiry. The watchdog still stops it when Dart stops heartbeating.
            wakeLock?.acquire(120_000)
            renewWakeLockAt = now + 60_000
        } catch (error: Exception) {
            DownloadRuntime.fail("设备暂不允许下载保持唤醒，锁屏下载可能中断")
        }
    }

    private fun releaseCpu() {
        wakeLock?.let { if (it.isHeld) runCatching { it.release() } }
        wakeLock = null
        renewWakeLockAt = 0L
    }

    private fun registerNetwork() {
        val manager = getSystemService(ConnectivityManager::class.java) ?: return
        val listener = object : ConnectivityManager.NetworkCallback() {
            private fun changed(blocked: Boolean = false) {
                handler.post {
                    val online = !blocked && DownloadRuntime.hasNetwork(this@PicaKeepDownloadService)
                    if (online != DownloadRuntime.networkAvailable) {
                        DownloadRuntime.networkAvailable = online
                        DownloadRuntime.event("networkChanged", online)
                    }
                }
            }
            override fun onAvailable(network: Network) = changed()
            override fun onLost(network: Network) = changed()
            override fun onCapabilitiesChanged(network: Network, caps: NetworkCapabilities) = changed()
            override fun onBlockedStatusChanged(network: Network, blocked: Boolean) = changed(blocked)
        }
        try {
            manager.registerDefaultNetworkCallback(listener)
            callback = listener
            DownloadRuntime.networkAvailable = DownloadRuntime.hasNetwork(this)
            DownloadRuntime.event("networkChanged", DownloadRuntime.networkAvailable)
        } catch (_: Exception) {
            DownloadRuntime.fail("网络状态监听暂不可用，断网后请在下载管理器中重试")
        }
    }

    private fun stopWithReason(message: String) {
        DownloadRuntime.fail(message)
        DownloadRuntime.latest = DownloadRuntime.latest + ("state" to "paused")
        releaseCpu()
        if (promoted) stopForeground(STOP_FOREGROUND_DETACH)
        promoted = false
        DownloadRuntime.publishTerminal(this)
        if (DownloadRuntime.service === this) DownloadRuntime.service = null
        stopSelf()
    }

    override fun onTimeout(startId: Int, fgsType: Int) {
        stopWithReason("系统后台下载时限已到，请回到应用后继续下载")
    }

    override fun onTaskRemoved(rootIntent: Intent?) {
        stopWithReason("应用已从最近任务移除，请重新打开后继续下载")
        super.onTaskRemoved(rootIntent)
    }

    override fun onDestroy() {
        handler.removeCallbacksAndMessages(null)
        callback?.let { callback ->
            runCatching { getSystemService(ConnectivityManager::class.java).unregisterNetworkCallback(callback) }
        }
        releaseCpu()
        if (DownloadRuntime.service === this) DownloadRuntime.service = null
        // Do not remove the detached, dismissible terminal notification here.
        super.onDestroy()
    }

    override fun onBind(intent: Intent?): IBinder? = null
}
