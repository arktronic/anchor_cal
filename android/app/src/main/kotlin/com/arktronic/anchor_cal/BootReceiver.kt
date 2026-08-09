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
import java.util.concurrent.TimeUnit

/**
 * Receives BOOT_COMPLETED and MY_PACKAGE_REPLACED to re-register
 * background tasks and calendar monitoring.
 */
class BootReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != Intent.ACTION_BOOT_COMPLETED &&
            intent.action != Intent.ACTION_MY_PACKAGE_REPLACED) return

        // Precise timestamp for correlating with Dart-side logs (developer.log
        // 'AnchorCal'/'AnchorCal.Boot') and awesome_notifications' own native
        // logs (logcat tag contains "Awesome Notifications") to determine
        // ordering between this receiver and the plugin's RefreshSchedulesReceiver.
        val startTime = System.currentTimeMillis()
        Log.d("AnchorCal.Boot", "BootReceiver triggered: ${intent.action} at $startTime")

        CalendarJobService.schedule(context)

        val inputData = Data.Builder()
            .putString(BackgroundWorker.DART_TASK_KEY, "anchorCalRefresh")
            .build()

        val bootRefreshWork = OneTimeWorkRequestBuilder<BackgroundWorker>()
            .setInputData(inputData)
            .addTag("boot_refresh")
            .build()

        // Both BOOT_COMPLETED and MY_PACKAGE_REPLACED clear the OS notification
        // shade, so it's correct to forget "already shown" bookkeeping and let
        // a never-dismissed reminder reappear. Chained after our own boot
        // refresh (not a fixed guess) so it waits for this device's actual
        // Flutter engine cold-start time - the same cost a racing dismiss
        // write pays - before wiping; the 3s buffer covers the dismiss
        // isolate starting slightly later than ours.
        val clearWork = OneTimeWorkRequestBuilder<ClearActiveHashesWorker>()
            .setInitialDelay(3, TimeUnit.SECONDS)
            .addTag("clear_active_hashes")
            .build()

        // Clearing alone doesn't re-show anything - nothing re-evaluates events
        // again until some unrelated future trigger. Chained (not timed) so it
        // only runs once the clear has actually finished persisting.
        val postClearRefreshWork = OneTimeWorkRequestBuilder<BackgroundWorker>()
            .setInputData(inputData)
            .addTag("post_clear_refresh")
            .build()

        WorkManager.getInstance(context).beginUniqueWork(
            "boot_refresh_work",
            ExistingWorkPolicy.REPLACE,
            bootRefreshWork
        ).then(clearWork).then(postClearRefreshWork).enqueue()

        Log.d(
            "AnchorCal.Boot",
            "WorkManager refresh task enqueued at ${System.currentTimeMillis()} " +
                "(+${System.currentTimeMillis() - startTime}ms since receiver start)"
        )
    }
}
