package com.arktronic.anchor_cal

import android.os.Build
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private val CHANNEL = "anchor_cal/permissions"

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        // Schedule calendar change job for real-time updates
        CalendarJobService.schedule(applicationContext)

        // Set up method channel for permission checks
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "isAutoRevokeWhitelisted" -> {
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                        val isWhitelisted = packageManager.isAutoRevokeWhitelisted
                        result.success(isWhitelisted)
                    } else {
                        // Auto-revoke not applicable before Android 11
                        result.success(null)
                    }
                }
                else -> result.notImplemented()
            }
        }
    }
}
