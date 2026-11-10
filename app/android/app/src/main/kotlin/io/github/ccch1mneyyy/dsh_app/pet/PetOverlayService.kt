package io.github.ccch1mneyyy.dsh_app.pet

import io.github.ccch1mneyyy.dsh_app.i18n.AppStrings
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import android.util.Log
import io.github.ccch1mneyyy.dsh_app.MainActivity
import io.github.ccch1mneyyy.dsh_app.R

/**
 * Keeps the process (and with it Dart's connection to a remote host) up while the pet is out and
 * DshService isn't running — someone who only uses remote hosts. With the local engine running,
 * DshService already does this and the pet rides on it. Not sticky: without the app's Dart side
 * there is nothing to show, so it isn't brought back after the process dies.
 */
class PetOverlayService : Service() {
    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == ACTION_SNOOZE) {
            PetOverlay.snoozeToday()
            return START_NOT_STICKY
        }
        ensureChannel(this)
        val n = notification(this)
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
                startForeground(NOTIFICATION_ID, n, ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE)
            } else {
                startForeground(NOTIFICATION_ID, n)
            }
            running = true
        } catch (e: Exception) {
            Log.w("DshPet", "pet service could not go foreground", e)
            running = false
            stopSelf()
        }
        return START_NOT_STICKY
    }

    override fun onDestroy() {
        running = false
        super.onDestroy()
    }

    companion object {
        private const val ACTION_SNOOZE = "io.github.ccch1mneyyy.dsh_app.PET_SNOOZE"
        private const val CHANNEL_ID = "dsh-pet"
        private const val NOTIFICATION_ID = 3090

        @Volatile var running = false
            private set

        /** Starts or stops the service to match [on]; does nothing when it already matches. */
        fun ensure(context: Context, on: Boolean) {
            if (on == running) return
            try {
                if (on) {
                    context.startForegroundService(Intent(context, PetOverlayService::class.java))
                    running = true
                } else {
                    context.stopService(Intent(context, PetOverlayService::class.java))
                    running = false
                }
            } catch (e: Exception) {
                // Background start refused (a vendor policy): the pet still shows while the process lives.
                Log.w("DshPet", "pet service ${if (on) "start" else "stop"} refused", e)
                running = false
            }
        }

        private fun ensureChannel(context: Context) {
            val nm = context.getSystemService(NotificationManager::class.java) ?: return
            nm.createNotificationChannel(
                NotificationChannel(CHANNEL_ID, AppStrings.get(context, R.string.pet_channel), NotificationManager.IMPORTANCE_MIN).apply {
                    setShowBadge(false)
                },
            )
        }

        private fun notification(context: Context): Notification {
            val open = PendingIntent.getActivity(
                context, NOTIFICATION_ID,
                Intent(context, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP),
                PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
            )
            val snooze = PendingIntent.getService(
                context, NOTIFICATION_ID + 1,
                Intent(context, PetOverlayService::class.java).setAction(ACTION_SNOOZE),
                PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
            )
            return Notification.Builder(context, CHANNEL_ID)
                .setSmallIcon(R.drawable.ic_stat_dsh)
                .setContentTitle(AppStrings.APP_NAME)
                .setContentText(AppStrings.get(context, R.string.pet_running))
                .setOngoing(true)
                .setContentIntent(open)
                .addAction(Notification.Action.Builder(null, AppStrings.get(context, R.string.pet_snooze), snooze).build())
                .build()
        }
    }
}
