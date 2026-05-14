package lingxue.picakeep

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import androidx.core.app.NotificationCompat

class PicaKeepForegroundService : Service() {
    override fun onCreate() {
        super.onCreate()
        ensureNotificationChannel()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == ACTION_STOP) {
            stopForeground(STOP_FOREGROUND_REMOVE)
            stopSelf()
            return START_NOT_STICKY
        }

        val notification = buildNotification(intent)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            startForeground(
                NOTIFICATION_ID,
                notification,
                ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC,
            )
        } else {
            startForeground(NOTIFICATION_ID, notification)
        }
        return START_STICKY
    }

    override fun onDestroy() {
        stopForeground(STOP_FOREGROUND_REMOVE)
        super.onDestroy()
    }

    override fun onBind(intent: Intent?): IBinder? = null

    private fun buildNotification(intent: Intent?): android.app.Notification {
        val title = intent?.getStringExtra(EXTRA_TITLE)?.takeIf { it.isNotBlank() }
            ?: "PicaKeep 服务端"
        val content = intent?.getStringExtra(EXTRA_CONTENT)?.takeIf { it.isNotBlank() }
            ?: "服务端正在后台保持在线"
        val statusText = intent?.getStringExtra(EXTRA_STATUS_TEXT)?.takeIf { it.isNotBlank() }
        val port = intent?.getIntExtra(EXTRA_PORT, -1)?.takeIf { it != null && it > 0 }
        val launchIntent = packageManager.getLaunchIntentForPackage(packageName)?.apply {
            addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP)
        }
        val contentIntent = launchIntent?.let {
            PendingIntent.getActivity(
                this,
                0,
                it,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
            )
        }

        val builder = NotificationCompat.Builder(this, CHANNEL_ID)
            .setContentTitle(title)
            .setContentText(content)
            .setStyle(NotificationCompat.BigTextStyle().bigText(content))
            .setSmallIcon(android.R.drawable.stat_sys_upload_done)
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setSilent(true)
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .setCategory(NotificationCompat.CATEGORY_SERVICE)

        if (contentIntent != null) {
            builder.setContentIntent(contentIntent)
        }
        if (!statusText.isNullOrBlank()) {
            builder.setSubText(statusText)
        }
        if (port != null) {
            builder.setTicker("PicaKeep 服务端端口 $port")
        }
        return builder.build()
    }

    private fun ensureNotificationChannel() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) {
            return
        }
        val channel = NotificationChannel(
            CHANNEL_ID,
            "PicaKeep Foreground Service",
            NotificationManager.IMPORTANCE_LOW,
        ).apply {
            description = "保持 PicaKeep 服务端在后台持续运行"
            setShowBadge(false)
        }
        val manager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        manager.createNotificationChannel(channel)
    }

    companion object {
        private const val CHANNEL_ID = "picakeep_foreground_service"
        private const val NOTIFICATION_ID = 9527
        private const val ACTION_START = "picakeep.action.START_FOREGROUND_SERVICE"
        private const val ACTION_STOP = "picakeep.action.STOP_FOREGROUND_SERVICE"
        private const val EXTRA_TITLE = "title"
        private const val EXTRA_CONTENT = "content"
        private const val EXTRA_STATUS_TEXT = "statusText"
        private const val EXTRA_PORT = "port"

        fun start(
            context: Context,
            title: String,
            content: String,
            statusText: String?,
            port: Int?,
            adminUrl: String?,
        ) {
            val intent = Intent(context, PicaKeepForegroundService::class.java).apply {
                action = ACTION_START
                putExtra(EXTRA_TITLE, title)
                putExtra(EXTRA_CONTENT, content)
                putExtra(EXTRA_STATUS_TEXT, statusText)
                if (port != null) {
                    putExtra(EXTRA_PORT, port)
                }
                if (!adminUrl.isNullOrBlank()) {
                    putExtra("adminUrl", adminUrl)
                }
            }
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                context.startForegroundService(intent)
            } else {
                context.startService(intent)
            }
        }

        fun stop(context: Context) {
            val intent = Intent(context, PicaKeepForegroundService::class.java).apply {
                action = ACTION_STOP
            }
            context.startService(intent)
            context.stopService(Intent(context, PicaKeepForegroundService::class.java))
        }
    }
}
