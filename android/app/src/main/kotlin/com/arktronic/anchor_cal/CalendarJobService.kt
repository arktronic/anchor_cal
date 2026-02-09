package com.arktronic.anchor_cal

import android.app.job.JobInfo
import android.app.job.JobParameters
import android.app.job.JobScheduler
import android.app.job.JobService
import android.content.ComponentName
import android.content.Context
import android.provider.CalendarContract
import androidx.work.Data
import androidx.work.ExistingWorkPolicy
import androidx.work.OneTimeWorkRequestBuilder
import androidx.work.WorkManager
import dev.fluttercommunity.workmanager.BackgroundWorker

/**
 * JobService triggered by calendar content changes.
 * Enqueues WorkManager task to refresh notifications via Dart.
 */
class CalendarJobService : JobService() {

    companion object {
        private const val JOB_ID = 1001

        private fun buildJobInfo(context: Context): JobInfo {
            val componentName = ComponentName(context, CalendarJobService::class.java)
            return JobInfo.Builder(JOB_ID, componentName)
                .addTriggerContentUri(
                    JobInfo.TriggerContentUri(
                        CalendarContract.Events.CONTENT_URI,
                        JobInfo.TriggerContentUri.FLAG_NOTIFY_FOR_DESCENDANTS
                    )
                )
                .addTriggerContentUri(
                    JobInfo.TriggerContentUri(
                        CalendarContract.Calendars.CONTENT_URI,
                        JobInfo.TriggerContentUri.FLAG_NOTIFY_FOR_DESCENDANTS
                    )
                )
                // Delay slightly to batch rapid changes
                .setTriggerContentUpdateDelay(500)
                .setTriggerContentMaxDelay(2000)
                .build()
        }

        /**
         * Schedule the job to watch for calendar changes.
         * No-op if already scheduled.
         */
        fun schedule(context: Context) {
            val jobScheduler = context.getSystemService(Context.JOB_SCHEDULER_SERVICE) as JobScheduler
            if (jobScheduler.getPendingJob(JOB_ID) != null) return
            jobScheduler.schedule(buildJobInfo(context))
        }

        /**
         * Cancel the scheduled job.
         */
        fun cancel(context: Context) {
            val jobScheduler = context.getSystemService(Context.JOB_SCHEDULER_SERVICE) as JobScheduler
            jobScheduler.cancel(JOB_ID)
        }
    }

    override fun onStartJob(params: JobParameters?): Boolean {
        // Trigger WorkManager task to refresh notifications
        val inputData = Data.Builder()
            .putString(BackgroundWorker.DART_TASK_KEY, "anchorCalRefresh")
            .build()

        val workRequest = OneTimeWorkRequestBuilder<BackgroundWorker>()
            .setInputData(inputData)
            .addTag("calendar_change_refresh")
            .build()

        WorkManager.getInstance(applicationContext).enqueueUniqueWork(
            "calendar_change_work",
            ExistingWorkPolicy.REPLACE,
            workRequest
        )

        // Re-schedule to continue watching (content jobs are one-shot)
        schedule(applicationContext)

        // Return false - work is handed off to WorkManager
        return false
    }

    override fun onStopJob(params: JobParameters?): Boolean {
        // Return true to reschedule if stopped prematurely
        return true
    }
}
