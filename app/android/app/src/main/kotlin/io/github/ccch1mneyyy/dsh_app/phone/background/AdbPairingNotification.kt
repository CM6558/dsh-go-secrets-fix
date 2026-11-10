package io.github.ccch1mneyyy.dsh_app.phone.background

import io.github.ccch1mneyyy.dsh_app.i18n.AppStrings
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.RemoteInput
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import io.github.ccch1mneyyy.dsh_app.R

/**
 * LADB-style pairing helper: a heads-up notification carrying a [RemoteInput] text box, so the
 * person types the 6-digit code straight from the notification while the system's
 * 「无线调试 → 使用配对码配对设备」dialog (and Settings' pairing sheet) is on screen. The code is
 * handed to [BackgroundControl.adbPair]; it is never sent anywhere else. Uses framework
 * android.app APIs only (minSdk 26), so no extra support-library dependency.
 */
object AdbPairingNotification {
    const val CHANNEL_ID = "dsh_phone_pairing"
    const val NOTIFICATION_ID = 0x05D4
    const val CODE_KEY = "dsh_pairing_code"
    private const val ACTION_SUBMIT = "io.github.ccch1mneyyy.dsh_app.PHONE_ADB_PAIR_CODE"

    fun show(context: Context) {
        val manager = context.getSystemService(NotificationManager::class.java)
        manager.createNotificationChannel(
            NotificationChannel(CHANNEL_ID, AppStrings.get(context, R.string.pairing_channel), NotificationManager.IMPORTANCE_HIGH))
        val remoteInput = RemoteInput.Builder(CODE_KEY).setLabel(AppStrings.get(context, R.string.pairing_code)).build()
        val submit = Intent(ACTION_SUBMIT).setPackage(context.packageName)
        val pending = PendingIntent.getBroadcast(
            context, 0, submit, PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_MUTABLE)
        val action = Notification.Action.Builder(0, AppStrings.get(context, R.string.pairing_enter), pending)
            .addRemoteInput(remoteInput)
            .setAllowGeneratedReplies(false)
            .build()
        val notification = Notification.Builder(context, CHANNEL_ID)
            .setSmallIcon(R.drawable.ic_stat_dsh)
            .setContentTitle(AppStrings.get(context, R.string.pairing_title))
            .setContentText(AppStrings.get(context, R.string.pairing_text))
            .setOngoing(true)
            .addAction(action)
            .build()
        manager.notify(NOTIFICATION_ID, notification)
    }

    fun dismiss(context: Context) {
        context.getSystemService(NotificationManager::class.java).cancel(NOTIFICATION_ID)
    }

    /** The code the person typed, or null. */
    fun codeFrom(intent: Intent): String? =
        RemoteInput.getResultsFromIntent(intent)?.getCharSequence(CODE_KEY)?.toString()?.trim()

    /** Registered in the manifest; forwards the typed code to the control object. */
    class Receiver : BroadcastReceiver() {
        override fun onReceive(context: Context, intent: Intent) {
            val code = codeFrom(intent) ?: return
            dismiss(context)
            BackgroundControl.get(context).adbPair(code, null)
        }
    }
}
