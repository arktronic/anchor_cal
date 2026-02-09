package com.arktronic.anchor_cal

import android.app.Application

class AnchorCalApplication : Application() {
    override fun onCreate() {
        super.onCreate()
        // Ensure calendar change monitoring is registered whenever the
        // process starts, including WorkManager background task launches.
        CalendarJobService.schedule(this)
    }
}
