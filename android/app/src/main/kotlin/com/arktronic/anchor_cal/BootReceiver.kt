package com.arktronic.anchor_cal

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.util.Log
import androidx.work.Data
import androidx.work.ExistingWorkPolicy
import androidx.work.OneTimeWorkRequestBuilder
import androidx.work.WorkManager
import dev.fluttercommunity.workmanager.BackgroundWorker

/**
 * Receives BOOT_COMPLETED and MY_PACKAGE_REPLACED to re-register
 * background tasks and calendar monitoring.
 */
class BootReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != Intent.ACTION_BOOT_COMPLETED &&
            intent.action != Intent.ACTION_MY_PACKAGE_REPLACED) return

        // Clear active notification tracking so notifications are re-shown
        // after reboot or app update (all prior notifications are gone).
        val prefs = context.getSharedPreferences("FlutterSharedPreferences", Context.MODE_PRIVATE)
        prefs.edit().remove("flutter.active_notification_hashes").apply()
        Log.d("AnchorCal.Boot", "Cleared active notification hashes (${intent.action})")

        CalendarJobService.schedule(context)

        val inputData = Data.Builder()
            .putString(BackgroundWorker.DART_TASK_KEY, "anchorCalRefresh")
            .build()

        val workRequest = OneTimeWorkRequestBuilder<BackgroundWorker>()
            .setInputData(inputData)
            .addTag("boot_refresh")
            .build()

        WorkManager.getInstance(context).enqueueUniqueWork(
            "boot_refresh_work",
            ExistingWorkPolicy.REPLACE,
            workRequest
        )
    }
}
