package com.arktronic.anchor_cal

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import androidx.work.Data
import androidx.work.ExistingWorkPolicy
import androidx.work.OneTimeWorkRequestBuilder
import androidx.work.WorkManager
import dev.fluttercommunity.workmanager.BackgroundWorker

/**
 * Receives BOOT_COMPLETED and triggers immediate notification refresh.
 * Uses the workmanager plugin's BackgroundWorker to invoke the Dart callback.
 */
class BootReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action == Intent.ACTION_BOOT_COMPLETED) {
            // Schedule calendar change job for real-time updates
            CalendarJobService.schedule(context)

            // Use the same task name as defined in Dart's callbackDispatcher
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
}
