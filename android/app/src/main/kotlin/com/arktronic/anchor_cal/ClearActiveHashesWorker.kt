package com.arktronic.anchor_cal

import android.content.Context
import android.util.Log
import androidx.work.Worker
import androidx.work.WorkerParameters

/**
 * Clears active_notification_hashes once the boot refresh task has finished,
 * so any in-flight dismiss-isolate write has had comparable time to land in
 * DismissedEventsStore. A true BOOT_COMPLETED clears the real OS notification
 * shade, so it's then safe to forget our "already shown" bookkeeping and let
 * still-relevant, never-dismissed reminders reappear.
 */
class ClearActiveHashesWorker(context: Context, params: WorkerParameters) : Worker(context, params) {
    override fun doWork(): Result {
        val prefs = applicationContext.getSharedPreferences("FlutterSharedPreferences", Context.MODE_PRIVATE)
        prefs.edit().remove("flutter.active_notification_hashes").apply()
        Log.d("AnchorCal.Boot", "Cleared active notification hashes after grace delay")
        return Result.success()
    }
}
