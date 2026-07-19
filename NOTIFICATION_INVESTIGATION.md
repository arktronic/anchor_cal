# Notification Ghost Bug Investigation

**Status**: Root cause confirmed via logcat — native `DartRefreshSchedulesReceiver` creates notifications ~600ms before `BootReceiver` runs; periodic native `cancelAll()` is the only working mitigation.

**Last updated**: 2026-07-18

---

## Problem Statement

After a device reboot (or app update via `MY_PACKAGE_REPLACED`), previously-dismissed notifications reappear on screen. Opening the app "fixes" the issue — ghost notifications disappear.

---

## What We Know (Verified)

### 1. awesome_notifications registers a BOOT_COMPLETED receiver

Confirmed: `DartRefreshSchedulesReceiver` listens for `BOOT_COMPLETED`, `MY_PACKAGE_REPLACED`, and related intents (from `awesome_notifications` v0.12.1 manifest).

### 2. awesome_notifications core is in a separate library

Confirmed: `AndroidAwnCore:0.12.1` source code is **not publicly available**. All attempts to fetch core classes returned 404.

### 3. User dismissal flow works correctly

Confirmed: When user swipes a notification away, the hash is saved to `DismissedEventsStore` (SharedPreferences) and `AwesomeNotifications().cancel()` is called.

### 4. App open "fixes" the issue

Confirmed: `refreshNotifications()` → `fullRefresh()` → checks `isDismissed()` → cancels ghost notifications. This is a "second pass" that only works after the receiver has finished.

### 5. BootReceiver runs on BOOT_COMPLETED/MY_PACKAGE_REPLACED

Confirmed: `BootReceiver.kt` clears active hashes and enqueues a WorkManager task for Dart-side refresh.

### 6. WorkManager background refresh checks dismissed store

Confirmed: `background_service.dart` initializes awesome_notifications and calls `fullRefresh()` which iterates calendar events and checks `isDismissed()`.

---

## NEW FINDINGS (2026-07-18 — Confirmed via logcat)

### Finding 1: Dart isolate starts BEFORE BootReceiver

```
19:59:35.333  DartRefreshSchedulesReceiver starts (Dart isolate)
19:59:35.940  Our BootReceiver starts  (607ms later)
```

The Dart isolate was ALREADY INITIALIZED when our `BootReceiver` ran. `AndroidAwnCore` (native code) has the old scheduled notifications in memory and keeps re-creating them.

### Finding 2: awesome_notifications does NOT remove from internal persistence on dismiss

When user dismisses, awesome_notifications removes from status bar but does NOT remove from internal persistence. This is why notifications re-appear on boot/update.

### Finding 3: awesome_notifications re-creates notifications for 8+ seconds

After our `cancelAll()`, the Dart isolate continues re-creating notifications from internal persistence. The periodic native `cancelAll()` in `BootReceiver.kt` is the ONLY thing that prevents ghosts because it cancels while awesome_notifications is still re-creating them.

### Finding 4: Dart-side `onNotificationCreatedMethod` is insufficient

The callback fires when notifications are created, but it runs AFTER awesome_notifications has already created the notification. The ghost appears on screen before the Dart callback can cancel it. We instrumented the callback to check `DismissedEventsStore` and cancel if dismissed — this confirms the callback fires, but confirms it's too late to prevent the ghost.

### Finding 5: Dart isolate works on boot

The background isolate IS initialized enough to load `DismissedEventsStore` and call `isDismissed()` during the `onNotificationCreatedMethod` callback. The isolate works — the problem is purely timing.

---

## What We Don't Know

### Critical Unknowns

1. **AndroidAwnCore source code**: Source is **not publicly available**. We cannot see what `RefreshSchedulesReceiver`, `AwesomeNotifications`, or `ScheduledNotificationReceiver` actually do.

2. **Exact timing window**: We know Dart isolate starts ~600ms before `BootReceiver`, but we don't know exactly how fast awesome_notifications creates each notification after the Dart isolate starts.

3. **Can we prevent Dart isolate from starting on BOOT/MY_PACKAGE_REPLACED?**: This would be the cleanest fix but requires understanding the receiver architecture.

### Non-Critical Unknowns

4. **Whether `onNotificationDisplayedMethod` fires** for boot-time notifications

---

## Working Mitigation

Periodic native `cancelAll()` for 30 seconds after boot/update (implemented in `BootReceiver.kt`). This is acknowledged as a hack — it masks the symptom but doesn't address the root cause. It works because it cancels while awesome_notifications is still re-creating notifications from internal persistence.

---

## Potential Fix Directions

### Direction A: Prevent Dart isolate from starting on BOOT/MY_PACKAGE_REPLACED

Modify the receiver registration so the Dart isolate doesn't start on boot/update. This would prevent awesome_notifications from re-creating notifications at all. **Untested** — requires understanding the receiver architecture.

### Direction B: Fix awesome_notifications internal persistence

This is **impossible** — source code is unavailable. awesome_notifications does not remove dismissed notifications from its internal persistence.

### Direction C: Accept the current behavior

The ghost notifications disappear when the user opens the app. If the window of visibility is short enough (milliseconds), this may be "good enough." However, the bug is visible and the periodic `cancelAll()` is a hack.

---

## Files Referenced

| File | Purpose |
|------|---------|
| `lib/main.dart` | App entry point, triggers refresh on launch |
| `lib/services/event_monitor_service.dart` | Notification callbacks (created/displayed/dismissed/action) |
| `lib/services/calendar_refresh_service.dart` | Shared refresh logic (foreground + background) |
| `lib/services/event_processor.dart` | Processes calendar events, checks dismissed store before creating |
| `lib/services/dismissed_events_store.dart` | Persistent dismissed/snoozed hash store (SharedPreferences) |
| `lib/services/background_service.dart` | WorkManager background refresh |
| `android/.../BootReceiver.kt` | Handles BOOT_COMPLETED, MY_PACKAGE_REPLACED |
| `android/.../AndroidManifest.xml` | App manifest with receiver registrations |
