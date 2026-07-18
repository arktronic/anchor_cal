# Notification Ghost Bug Investigation

**Status**: In progress — root cause identified but fix not yet implemented or tested.

**Last updated**: 2026-07-06

---

## Problem Statement

After a device reboot (or app update via `MY_PACKAGE_REPLACED`), previously-dismissed notifications reappear on screen. They were dismissed by the user swiping them away. Opening the app "fixes" the issue — the ghost notifications disappear.

---

## What We Know (Verified)

### 1. awesome_notifications registers a BOOT_COMPLETED receiver

From `awesome_notifications` v0.12.1 `android/src/main/AndroidManifest.xml` (confirmed):

```xml
<receiver android:name=".DartRefreshSchedulesReceiver"
    android:enabled="true" android:exported="true">
    <intent-filter>
        <action android:name="android.intent.action.BOOT_COMPLETED"/>
        <action android:name="android.intent.action.LOCKED_BOOT_COMPLETED"/>
        <action android:name="android.intent.action.MY_PACKAGE_REPLACED"/>
        <action android:name="android.intent.action.QUICKBOOT_POWERON"/>
        <action android:name="com.htc.intent.action.QUICKBOOT_POWERON"/>
        <action android:name="android.app.action.SCHEDULE_EXACT_ALARM_PERMISSION_STATE_CHANGED"/>
    </intent-filter>
</receiver>
```

**Verified**: awesome_notifications plugin registers `DartRefreshSchedulesReceiver` to listen for `BOOT_COMPLETED`, `MY_PACKAGE_REPLACED`, and related intents.

### 2. awesome_notifications core is in a separate library

From `awesome_notifications` v0.12.1 `android/build.gradle` (confirmed):

```gradle
dependencies {
    implementation 'me.carda:AndroidAwnCore:0.12.1'
}
```

The core classes (`AwesomeNotifications`, `RefreshSchedulesReceiver`, etc.) are in a **separate Android Maven library** (`AndroidAwnCore`). This library's source code is **not available** in the awesome_notifications GitHub repo.

**Verified**: `DartRefreshSchedulesReceiver` extends `RefreshSchedulesReceiver` from `me.carda.awesome_notifications.core.broadcasters.receivers` (confirmed from `DartRefreshSchedulesReceiver.java`).

**Unknown**: We could not locate the `AndroidAwnCore` source code. It may be in a private or separate repository. All attempts to fetch core receiver classes (e.g., `RefreshSchedulesReceiver.java`, `AwesomeNotifications.java`, `ScheduledNotificationReceiver.java`) returned 404 errors.

### 3. User dismissal flow works correctly

When user swipes a notification away:

1. awesome_notifications fires `onDismissActionReceivedMethod` → `NotificationController.onDismissActionReceivedMethod()` in `event_monitor_service.dart`
2. `_dismissEvent()` is called, which:
   - Saves the event hash to `DismissedEventsStore` (SharedPreferences-backed JSON store) ✅
   - Calls `AwesomeNotifications().cancel(notificationId)` ✅
3. The hash is also kept in `ActiveNotificationStore` as a cross-isolate safety net ✅

**Verified**: Both `DismissedEventsStore` and `ActiveNotificationStore` work correctly and persist data across restarts.

### 4. App open "fixes" the issue

From `main.dart` (confirmed):

```dart
if (await PermissionsHelper.hasAllEssentialPermissions()) {
    EventMonitorService.instance.refreshNotifications();
}
```

When the user opens the app:
1. `refreshNotifications()` → `CalendarRefreshService.fullRefresh()`
2. For each calendar event, `EventProcessor.processEvent()` checks `_dismissedStore.isDismissed(reminderHash)`
3. If dismissed → cancels the ghost notification via `AwesomeNotifications().cancel(notificationId)`
4. Notifications disappear ✅

**Verified**: This is a "second pass" — it only works because awesome_notifications' receiver has already finished running before the app starts.

### 5. BootReceiver exists and runs

From `BootReceiver.kt` (confirmed):

```kotlin
class BootReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        // 1. Cancel ALL visible notifications
        notificationManager.cancelAll()
        
        // 2. Clear active notification hashes
        prefs.edit().remove("flutter.active_notification_hashes").apply()
        
        // 3. Schedule CalendarJobService
        CalendarJobService.schedule(context)
        
        // 4. Enqueue WorkManager task for Dart-side refresh
        WorkManager.getInstance(context).enqueueUniqueWork(...)
    }
}
```

BootReceiver runs on `BOOT_COMPLETED` and `MY_PACKAGE_REPLACED`. It cancels all visible notifications, clears active hashes, and enqueues a WorkManager task.

### 6. WorkManager background refresh checks dismissed store

From `background_service.dart` (confirmed):

```dart
await AwesomeNotifications().initialize(...)
await dismissedStore.clearExpiredSnoozes()
await dismissedStore.cleanupOldEntries()
await refreshService.fullRefresh()
```

The background refresh initializes awesome_notifications, then calls `fullRefresh()` which iterates calendar events and checks `isDismissed()`.

### 7. onNotificationCreatedMethod is a no-op

From `event_monitor_service.dart` (confirmed):

```dart
@pragma('vm:entry-point')
static Future<void> onNotificationCreatedMethod(
    ReceivedNotification receivedNotification,
) async {
    // Not used, but required by awesome_notifications
}
```

**Verified**: The `onNotificationCreatedMethod` callback is completely empty. This is the callback that fires when awesome_notifications creates any notification (including via the BOOT_COMPLETED receiver).

---

## What We Suspect (But Could Not Verify)

### Suspected Root Cause

awesome_notifications' `DartRefreshSchedulesReceiver` (fired by `BOOT_COMPLETED`) restores all previously-scheduled notifications from its internal persistence. This happens **independently** of the DismissedEventsStore because:

1. awesome_notifications' receiver is in the native layer (`AndroidAwnCore` library)
2. DismissedEventsStore is in Dart (SharedPreferences, requires Flutter isolate)
3. The native receiver does **not** know about the Dart-side dismissed store
4. The native receiver creates notifications via `AwesomeNotifications().createNotification()` or equivalent
5. This happens **before** the WorkManager task (Dart-side) can run its `isDismissed()` checks

### Timing Flow (Suspected)

```
BOOT_COMPLETED fires
├─ 1. awesome_notifications' DartRefreshSchedulesReceiver fires (native layer)
│   └─ Creates notifications from internal persistence  ← GHOSTS APPEAR HERE
├─ 2. Our BootReceiver.onReceive() fires (native layer)
│   ├─ cancelAll() — removes visible notifications
│   └─ clears active hashes
├─ 3. WorkManager enqueues background task
│   └─ Dart isolate starts (takes time to initialize)
│       ├─ Initializes awesome_notifications
│       ├─ Loads DismissedEventsStore
│       └─ fullRefresh() → isDismissed() → cancels ghosts ← TOO LATE
└─ 4. Ghost notifications visible during window between steps 1-3
```

**Not verified**: We don't know the exact execution order between `DartRefreshSchedulesReceiver` and `BootReceiver`. We don't know what `RefreshSchedulesReceiver` actually does (source unavailable). We don't know if `createNotification` triggers `onNotificationCreatedMethod`.

---

## What We Tried (And Failed)

### Attempt 1: Dart-side `cancelDismissedNotifications()` in `fullRefresh()`

Added a method to `CalendarRefreshService.fullRefresh()` that cancels notifications matching the dismissed store.

**Result**: Failed. The WorkManager task runs **after** awesome_notifications' receiver has already created the notifications. Same timing issue.

### Attempt 2: Native `notificationManager.cancelAll()` in `BootReceiver`

Added `notificationManager.cancelAll()` at the start of `BootReceiver.onReceive()`.

**Result**: Failed. Even though `cancelAll()` removes visible notifications, awesome_notifications' receiver may create them again. Or the receiver runs after the BootReceiver returns, re-creating notifications from its internal persistence.

---

## What We Don't Know

### Critical Unknowns

1. **AndroidAwnCore source code**: The core library (`me.carda:AndroidAwnCore:0.12.1`) source is **not publicly available**. We cannot see what `RefreshSchedulesReceiver`, `AwesomeNotifications`, or `ScheduledNotificationReceiver` actually do.

2. **Execution order**: We don't know if `DartRefreshSchedulesReceiver` runs before or after `BootReceiver`. Both listen for `BOOT_COMPLETED` and are exported.

3. **Does `createNotification` trigger `onNotificationCreatedMethod`?**: When awesome_notifications' native code creates notifications on boot, does it invoke the Dart `onNotificationCreatedMethod` callback? We cannot verify this without the core source or by running tests.

4. **Does the callback run in the background isolate on boot?**: If `onNotificationCreatedMethod` fires, is the isolate initialized enough to load `DismissedEventsStore`? Currently the callback doesn't call `_ensureAwesomeNotificationsInitialized()`, unlike `onDismissActionReceivedMethod` and `onActionReceivedMethod`.

5. **Does awesome_notifications persist dismissed state?**: When user swipes a notification, awesome_notifications removes it from the status bar AND cancels it. But does it also remove it from its internal persistence so the receiver won't re-create it on boot? We suspect **no**, but cannot verify without core source.

6. **Does opening the app always trigger refresh?**: `main.dart` checks `hasAllEssentialPermissions()` before calling `refreshNotifications()`. If permissions are somehow lost between boot and app launch, the refresh won't run.

### Non-Critical Unknowns

7. **Exact millisecond timing** between receiver executions
8. **Whether `onNotificationDisplayedMethod` fires** for boot-time notifications (it does log, but we don't know if it fires for WakeLocker-created notifications)
9. **Whether `cancelAll()` removes scheduled (pending) notifications or only displayed ones**

---

## Current Code State

All previously attempted fixes have been **reverted**. The codebase is at its original state:

- `dismissed_events_store.dart`: Original methods only (`dismiss`, `isDismissed`, `getSnoozedUntil`, `clearExpiredSnoozes`, `cleanupOldEntries`)
- `calendar_refresh_service.dart`: Original `fullRefresh()` — no dismissal cancellation logic
- `BootReceiver.kt`: Has `cancelAll()` (from failed attempt 2) but it's not helping
- `NotificationController.onNotificationCreatedMethod`: Still a no-op
- `EventProcessor.processEvent()`: Checks `isDismissed()` before creating, but this runs after ghost notifications already exist

---

## Potential Fix Directions (Unverified)

### Direction A: Intercept in `onNotificationCreatedMethod`

Populate `onNotificationCreatedMethod` to:
1. Call `_ensureAwesomeNotificationsInitialized()`
2. Load `DismissedEventsStore`
3. Check if the created notification's hash is dismissed
4. If yes → `AwesomeNotifications().cancel(notificationId)`

**Risk**: The background isolate may not have SharedPreferences initialized when this fires. Need to verify.

### Direction B: Ensure `onNotificationCreatedMethod` callback is enabled

Currently the callback is registered in `EventMonitorService.init()`:

```dart
await AwesomeNotifications().setListeners(
    onNotificationCreatedMethod: NotificationController.onNotificationCreatedMethod,
    ...
);
```

But the method itself is empty. If this callback fires during boot-time notification creation (Direction A), it would be the cleanest interception point.

### Direction C: Native-side check in `BootReceiver`

Read SharedPreferences from the native side and cancel notifications matching dismissed hashes. This is complex because:
- SharedPreferences are Dart-side (JSON in a file)
- Native code would need to parse the same format
- Error-prone and duplicates logic

### Direction D: Accept the current behavior

The ghost notifications disappear when the user opens the app. If the window of visibility is short enough, this may be "good enough" from a UX perspective. However, the bug still exists and is visible.

---

## Files Referenced

| File | Purpose |
|------|---------|
| `lib/main.dart` | App entry point, triggers refresh on launch |
| `lib/services/event_monitor_service.dart` | Notification callbacks (created/displayed/dismissed/action) |
| `lib/services/calendar_refresh_service.dart` | Shared refresh logic (foreground + background) |
| `lib/services/event_processor.dart` | Processes calendar events, checks dismissed store before creating |
| `lib/services/dismissed_events_store.dart` | Persistent dismissed/snoozed hash store (SharedPreferences) |
| `lib/services/active_notification_store.dart` | Tracks active notification hashes |
| `lib/services/background_service.dart` | WorkManager background refresh |
| `android/.../BootReceiver.kt` | Handles BOOT_COMPLETED, MY_PACKAGE_REPLACED |
| `android/.../CalendarJobService.kt` | JobService for calendar change detection |
| `android/.../AndroidManifest.xml` | App manifest with receiver registrations |
