# Notification Ghost Bug Investigation

**Status**: Root cause **confirmed** via a real logcat capture with working diagnostics (see "2026-08-08 CONFIRMED root cause" below): `BootReceiver.kt` was unconditionally wiping `active_notification_hashes` on every boot/reinstall, which defeated the exact safety net meant to stop already-shown reminders from being re-created, causing 3-4-day-old event reminders to resurface as "ghosts" on every reinstall. **Fix applied and refined six times**: (1) removed the wipe entirely; (2) attempted a reconciliation against `AwesomeNotifications().getAllActiveNotificationIdsOnStatusBar()`, but that API **crashes** in the installed plugin version (see "2026-08-08 status-bar API is broken" below); (3) wiped only on genuine `BOOT_COMPLETED`, immediately — reopened the swipe-then-reboot race (see "2026-08-08 explicit requirement" below); (4) never wiping at all satisfied "dismissed never reappears" but broke the *other* half of the requirement — a real device test showed a genuinely un-dismissed reminder (`already active, skipping re-show`) correctly failing to reappear after a real reboot; (5) a fixed 10s delayed wipe worked but was correctly flagged as fragile (a hardcoded guess at worst-case device speed); (6) replaced with a chained wipe (self-calibrating to actual engine cold-start speed) that only ran for `BOOT_COMPLETED`. **Final update: now assuming `MY_PACKAGE_REPLACED` also clears the OS notification shade, so it gets the same chained wipe as `BOOT_COMPLETED`** — both events now behave identically in `BootReceiver.kt`.

**Last updated**: 2026-08-08 (both `BOOT_COMPLETED` and `MY_PACKAGE_REPLACED` now chain the `active_notification_hashes` wipe after the boot refresh task completes + 3s buffer)

---

## Problem Statement

After a device reboot (or app update via `MY_PACKAGE_REPLACED`), previously-dismissed notifications reappear on screen. Opening the app "fixes" the issue — ghost notifications disappear.

---

## What We Know (Verified)

### 1. awesome_notifications registers a BOOT_COMPLETED receiver

Confirmed: `DartRefreshSchedulesReceiver` listens for `BOOT_COMPLETED`, `MY_PACKAGE_REPLACED`, and related intents (from `awesome_notifications` v0.12.1 manifest).

### 2. awesome_notifications core is in a separate library

**CORRECTED (2026-08-08)**: `AndroidAwnCore` source code **is publicly available** at [github.com/rafaelsetragni/AndroidAwnCore](https://github.com/rafaelsetragni/AndroidAwnCore) (the Gradle dependency `me.carda:AndroidAwnCore:0.12.1` is the compiled artifact of this repo). The earlier claim that it was unavailable was wrong — prior fetch attempts likely targeted the wrong repo (the main `awesome_notifications` repo only contains the Flutter plugin glue classes and the iOS `AwnCore` Swift sources; the Android core lives in this separate sibling repo). See "Source-Grounded Findings" below for what the real code does.

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

**Refined by source (2026-08-08)**: this is confirmed and now precise. `DismissedNotificationReceiver.onReceiveBroadcastEvent` (native, in `AndroidAwnCore`) only calls `StatusBarManager.unregisterActiveNotification()` — it never touches the **schedule** persistence (`ScheduleManager`, backed by `SQLiteSchedulesDB`). The *only* code path that removes a schedule row on dismissal is our own Dart-side `AwesomeNotifications().cancel(id)` call in `EventMonitorService._dismissEvent()`, which reaches native `CancellationManager.cancelNotification()` → `cancelSchedule()` (removes the SQLite row + cancels the `AlarmManager` `PendingIntent`) **and** `dismissNotification()` (status bar). That Dart call runs inside a broadcast-triggered background isolate (`DartDismissedNotificationReceiver` → Flutter background execution) with no OS-guaranteed completion time. If the process is killed or the isolate hasn't finished before the device reboots, the schedule row in `SQLiteSchedulesDB` survives untouched by any native code, and `RefreshSchedulesReceiver` will legitimately re-arm it on next boot, reproducing the "ghost".

### Finding 3: awesome_notifications re-creates notifications for 8+ seconds

After our `cancelAll()`, the Dart isolate continues re-creating notifications from internal persistence. The periodic native `cancelAll()` in `BootReceiver.kt` is the ONLY thing that prevents ghosts because it cancels while awesome_notifications is still re-creating them.

### Finding 4: Dart-side `onNotificationCreatedMethod` is insufficient

The callback fires when notifications are created, but it runs AFTER awesome_notifications has already created the notification. The ghost appears on screen before the Dart callback can cancel it. We instrumented the callback to check `DismissedEventsStore` and cancel if dismissed — this confirms the callback fires, but confirms it's too late to prevent the ghost.

### Finding 5: Dart isolate works on boot

The background isolate IS initialized enough to load `DismissedEventsStore` and call `isDismissed()` during the `onNotificationCreatedMethod` callback. The isolate works — the problem is purely timing.

---

## Source-Grounded Findings (2026-08-08)

Confirmed by reading the actual `AndroidAwnCore` (Android) and `AwnCore` (iOS, inline in the main repo) source:

- **Schedules are persisted natively**, independent of Dart: Android uses a real SQLite table (`SQLiteSchedulesDB` via `ScheduleManager`), not SharedPreferences. iOS uses its own `SharedManager`/`ScheduleManager` equivalent.
- **`RefreshSchedulesReceiver`** (registered for `BOOT_COMPLETED`/`QUICKBOOT_POWERON`) does exactly one thing: `NotificationScheduler.refreshScheduledNotifications(context)` — it lists every row still present in the schedule table and, for any whose `AlarmManager` alarm is no longer active (true for all of them after a reboot, since the OS clears all alarms), re-arms it. If the computed "next valid date" for a row is already in the past, the re-arm effectively fires (near-)immediately — this is what looks like a "ghost."
- **A one-shot (`repeats: false`) schedule self-removes its row natively** the moment its alarm fires (`ScheduledNotificationReceiver` → `NotificationScheduler.cancelSchedule()`), with no Dart involvement. So a reminder that has already been *shown* to the user should already have no schedule row left — the leak is specifically for schedules whose row was never removed for some other reason.
- **Dismissing a notification does NOT remove its schedule row.** Native `DismissedNotificationReceiver` only clears `StatusBarManager`'s active-notification bookkeeping. Schedule cancellation only happens via Dart's `AwesomeNotifications().cancel(id)` (already used correctly in `EventMonitorService._dismissEvent()` and defensively in `EventProcessor.processEvent()` for already-dismissed/snoozed hashes).
- **This makes the real race precise**: our `cancel(id)` call runs inside a background isolate spawned in response to the dismiss broadcast (`DartDismissedNotificationReceiver`), with no guaranteed run-to-completion window from Android. If that isolate is killed, delayed, or never gets to run its method-channel call before the next boot, the schedule row for that reminder is never removed from `SQLiteSchedulesDB`, and `RefreshSchedulesReceiver` will legitimately (and correctly, per its own logic) re-arm and re-fire it.
- **The current `BootReceiver.kt` does not implement any periodic `cancelAll()`.** It only clears `flutter.active_notification_hashes` and enqueues a one-time WorkManager task (`anchorCalRefresh`). The "working mitigation" previously documented here does not exist in the codebase today — either it was reverted or never landed. This should be treated as an open item, not a confirmed fix.

## What We Don't Know

### Critical Unknowns

1. **Does the schedule row for a dismissed reminder actually still exist at reboot time?** Not yet verified empirically. Can be checked by calling `AwesomeNotifications().listScheduledNotifications()` immediately after a dismiss action and confirming the dismissed ID is gone, then again after a simulated reboot.
2. **Exact timing window**: how long the Dart background isolate takes to reach the `cancel()` method-channel call after a dismiss broadcast, relative to how soon a subsequent reboot can occur.
3. **Whether `onNotificationDisplayedMethod` fires** for boot-time notifications.

---

## Status of Previously-Documented Mitigation

The periodic native `cancelAll()` described in earlier revisions of this document as "implemented in `BootReceiver.kt`" is **not present in the current code** (verified 2026-08-08). Do not rely on it being active; if it's still desired as a stopgap, it needs to be (re)implemented.

---

## 2026-08-08 logcat capture: confirms `developer.log()` was NOT reaching plain `adb logcat`

A real repro captured via plain `adb logcat` (no `flutter attach`/`flutter logs`) showed:

```
08-08 22:35:19.272 D/AlphabeticIndexCompat( 9156): computeSectionName: cs: AnchorCal sectionName: A
08-08 22:35:19.549 D/AnchorCal.Boot(27482): BootReceiver triggered: android.intent.action.MY_PACKAGE_REPLACED at 1786242919549
08-08 22:35:20.317 D/AnchorCal.Boot(27482): Cleared active notification hashes (android.intent.action.MY_PACKAGE_REPLACED)
08-08 22:35:20.337 D/AnchorCal.Boot(27482): WorkManager refresh task enqueued at 1786242920336 (+787ms since receiver start)
08-08 22:35:21.836 D/Android: [Awesome Notifications](27482): LiceCycleManager listener successfully attached to Android (LifeCycleManager:69)
08-08 22:35:21.897 D/Android: [Awesome Notifications](27482): Awesome Notifications plugin attached to Android 37 (AwesomeNotificationsPlugin:141)
08-08 22:35:21.897 D/Android: [Awesome Notifications](27482): Awesome Notifications attached to engine for Android 37 (AwesomeNotificationsPlugin:123)
```

(Ghost notifications appeared right after this.)

**What this confirms**:

- `BootReceiver.kt`'s `Log.d("AnchorCal.Boot", ...)` calls (native Kotlin) show up fine, as expected — `WorkManager refresh task enqueued at ... (+787ms since receiver start)`.
- ~1.5s after the WorkManager task was enqueued, a Flutter engine (engine id 37) started up and the `awesome_notifications` plugin attached to it — this is our own WorkManager `BackgroundWorker` spinning up a Flutter engine to run `callbackDispatcher()` / `_refreshNotificationsInBackground()`, exactly as expected. Notably these plugin-attach logs are native (`AwesomeNotificationsPlugin.java`, using the plugin's own `Logger.d`) and are **not** gated behind the `AwesomeNotifications.debug` runtime flag (that flag is only read later, inside the Dart-invoked `initialize()` call) — which is why they show up even though our own Dart `debug:` parameters are `false`/gated.
- **Critically, no `AnchorCal`-tagged Dart log lines appear anywhere in this window** — no "Background refresh starting", no "fullRefresh start: N schedule rows present", despite the engine clearly being up and running by 22:35:21.897. This is exactly what the caveat in the "Monitoring" section predicted: **`developer.log()` does not reliably reach plain `adb logcat` without an attached VM service listener** (no `flutter attach`/`flutter logs` was running here). The native `Log.d`-based logs (Kotlin `BootReceiver`, and the plugin's own native `Logger`) are unaffected since they call `android.util.Log` directly.

**Fix applied**: all `_log()` helpers across the Dart codebase (`active_notification_store.dart`, `background_service.dart`, `calendar_refresh_service.dart`, `dismissed_events_store.dart`, `event_monitor_service.dart`, `event_processor.dart`) have been switched from `developer.log(message, name: '...')` to `debugPrint('[TagName] $message')`. `debugPrint()` always goes through `print()`/stdout, which the Flutter engine forwards to plain `adb logcat` under the `flutter` tag for debug builds, with no VM service listener required. The bracketed prefix (`[AnchorCal]`, `[AnchorCal.Boot]` is unchanged since it's native, `[AnchorCal.Action]`, `[AnchorCal.Store]`) preserves the ability to `grep`/`Select-String` by source, same as before.

---

## 2026-08-08 CONFIRMED root cause: `BootReceiver.kt` wiping `active_notification_hashes`

With `debugPrint()`-based logging working, a full boot-refresh capture was obtained (`08-08 22:39:57` → `22:40:08`). Key excerpts:

```
22:39:57.738  BootReceiver triggered: MY_PACKAGE_REPLACED
22:39:58.547  WorkManager refresh task enqueued (+808ms)
22:40:00.127  Awesome Notifications plugin attached to Android engine 37
22:40:02.143  [AnchorCal] Background refresh starting (source: workmanager_periodic)...
22:40:03.607  [AnchorCal] fullRefresh start: 30 schedule rows present: [642314188, 286778640, ...]
...
22:40:05.513  [AnchorCal.Store] STORE isDismissed hash=438be24d => true
22:40:05.513  [AnchorCal]     Reminder 15 min: already dismissed          <- Archi Sprint Review, started 2026-08-04 (4 days ago)
...
22:40:05.803  [AnchorCal.Store] STORE isDismissed hash=a9f406a1 => false
22:40:05.811  [AnchorCal]     Reminder 15 min: SHOWING notification!      <- Archi Daily Standup, started 2026-08-06 (2 days ago)
22:40:06.081  [AnchorCal.Store] ACTIVE add hash=a9f406a1, total=1
... (6 more "SHOWING notification!" lines for events from 2026-08-06/07, all isDismissed => false)
```

**Interpretation**:

- The 30 schedule rows present at boot were all still-future, legitimately-pending reminders (`"already scheduled, skipping"`), correctly re-armed by `RefreshSchedulesReceiver`. **None of them belonged to a dismissed event** in this run — so this particular capture does *not* show the SQLite-schedule-survival mechanism (Finding 2 / Source-Grounded Findings above) actually happening. That theory is still plausible for a different scenario but wasn't the cause here.
- The real culprit: **seven** reminders for events that already occurred 1-4 days earlier (Aug 4-7, "now" is Aug 8) got logged `isDismissed => false` and then **"SHOWING notification!"** — i.e., the app itself freshly re-created and displayed notifications for old, already-handled events, immediately after the reinstall. This is the observed "ghost."
- Why `isDismissed => false` for events the user had surely already seen/handled days earlier: because the *first* line of defense against re-showing an already-surfaced reminder is `ActiveNotificationStore` (`activeHashes.contains(reminderHash)` → `"already active, skipping re-show"`), not `DismissedEventsStore`. `DismissedEventsStore` is only populated by an explicit swipe/tap/snooze action; a notification that was simply shown and left alone (or whose dismiss action never got a chance to persist — the same isolate-completion risk described in Finding 2) never gets marked "dismissed," it only gets marked "active."
- **`BootReceiver.kt` was unconditionally clearing that exact `active_notification_hashes` tracking on every `BOOT_COMPLETED`/`MY_PACKAGE_REPLACED`** (`prefs.edit().remove("flutter.active_notification_hashes").apply()`), specifically so that notifications would "re-appear" if the OS had cleared the status bar. The unintended side effect: it also un-suppresses every reminder within the 5-day retention window (`EventProcessor`'s `cutoffUtc`) that was already shown but never formally dismissed, causing them to be freshly recreated as apparent "ghosts" on every single reinstall/reboot — exactly matching the reported symptom and this capture.

**Fix applied**: removed the `active_notification_hashes` wipe from `BootReceiver.kt`. `ActiveNotificationStore` is backed by `SharedPreferences`, which already survives reboots/reinstalls on its own — there's no need to manually clear it, and doing so was actively harmful. The original intent (recover if the OS wiped the status bar) is still handled correctly without the wipe: `RefreshSchedulesReceiver` re-arms genuinely pending schedules, and any notification the OS truly removed will simply not be in `AwesomeNotifications().getAllActiveNotificationIdsOnStatusBar()` if that's ever checked — but nothing in the current codebase actually depended on the wipe for correctness.

**Next verification step**: redeploy with `debug_deploy.bat` and repeat the same logcat capture. Expect zero (or far fewer) `"SHOWING notification!"` lines for events more than a few minutes old during the boot-triggered `fullRefresh`. If `"SHOWING notification!"` still occurs for stale events, `DismissedEventsStore`/`ActiveNotificationStore` writes may themselves be failing to persist (a variant of the Finding 2 isolate-completion race) and needs further investigation.

**Confirmed working**: the user redeployed and reported none of the old notifications reappeared.

---

## 2026-08-08 correctness follow-up: does removing the wipe break the *other* direction?

Good question raised after the fix above worked: **removing the wipe entirely trades one bug for a different, more subtle one.** `ActiveNotificationStore`'s `"already active, skip re-show"` check (in `EventProcessor.processEvent()`) is based purely on our own persisted bookkeeping — it never actually looks at whether the notification is still really on the status bar. Two facts combine to create a real regression risk:

1. A genuine device reboot (as opposed to just an app reinstall) clears the real Android notification shade — the system server does not restore previously-posted notifications after boot. Apps must explicitly re-post anything still relevant.
2. With the wipe removed, `ActiveNotificationStore` now survives reboots (as `SharedPreferences` always has) — so a reminder the user genuinely never saw/dismissed, whose real notification the OS just erased on reboot, would still be marked `"active"` in our bookkeeping and therefore **silently skipped forever**, never reappearing and never getting a chance to be marked dismissed either.

This is the exact scenario the original (flawed) wipe in `BootReceiver.kt` was trying to handle ("re-shown after reboot... since all prior notifications are gone") — it just did so far too bluntly (clearing *everything*, including entries for notifications whose real state we could have otherwise reasoned about, or that survived e.g. an app update without being cleared).

**Better fix**: `AndroidAwnCore`'s `StatusBarManager` exposes `isNotificationActiveOnStatusBar(int id)` / `getAllActiveNotificationIdsOnStatusBar()` (confirmed present in the installed `awesome_notifications` 0.12.1, exposed to Dart via `AwesomeNotifications().getAllActiveNotificationIdsOnStatusBar()`). These call `NotificationManager.getActiveNotifications()` directly — the real, live OS state, not any of the plugin's own persisted bookkeeping. `CalendarRefreshService.refreshNotifications()` now uses this at the start of every refresh (foreground and boot-triggered background alike) to reconcile `ActiveNotificationStore`: any hash marked "active" whose notification ID is **not** actually present on the status bar right now gets dropped from tracking, so `EventProcessor` will properly reconsider it instead of assuming it's still showing.

This restores the original intended behavior (an un-dismissed, previously-shown reminder reappears if the OS genuinely cleared it, e.g. on a real reboot) without the collateral damage of unconditionally wiping everything at every boot/reinstall (which is what caused the observed "ghost" bug in the first place, since it *also* erased tracking for notifications that hadn't actually been cleared by the specific event that triggered `BootReceiver`).

**Files changed**: `ActiveNotificationStore` gained a batch `removeAll(Set<String>)` method; `CalendarRefreshService.refreshNotifications()` now fetches `getAllActiveNotificationIdsOnStatusBar()` alongside the existing `listScheduledNotifications()` call and purges stale entries before processing events.

**Still to verify empirically**: this reconciliation logic hasn't yet been tested against a *real* device reboot (only the reinstall/`MY_PACKAGE_REPLACED` path has been repro'd so far). A genuine `BOOT_COMPLETED` test — with a reminder shown and deliberately left un-dismissed before rebooting — would confirm it reappears afterward instead of silently vanishing.

---

## 2026-08-08 status-bar API is broken: reverted the reconciliation approach

The reconciliation fix above sounded right in theory but broke on first real test. Logcat showed:

```
23:02:30.613 [AnchorCal] Found 10 calendars
23:02:30.858 [AnchorCal] Already scheduled: 30 notifications
23:02:30.873 E/Android: [Awesome Notifications] Attempt to invoke virtual method
  'java.lang.Object android.content.Context.getSystemService(java.lang.String)'
  on a null object reference (AwesomeNotificationsPlugin:58)
23:02:30.898 [AnchorCal] Calendar plugin error: PlatformException(UNKNOWN_EXCEPTION, ...)
23:02:30.899 [AnchorCal] Background refresh completed successfully
```

**What happened**: `AwesomeNotifications().getAllActiveNotificationIdsOnStatusBar()` (called right after the "Already scheduled" log line) crashed natively, and since it wasn't wrapped in its own try/catch, the exception propagated up and aborted the **entire** `refreshNotifications()` call — no calendar events were processed at all in that run, a much worse regression than the original bug (the "Background refresh completed successfully" line is misleading; it just means `fullRefresh()`'s outer catch swallowed the error, matching the doc comment "Swallow errors in background context").

**Root cause of the crash**: read the actual `AndroidAwnCore` source for `StatusBarManager`. It `extends NotificationListenerService` (an Android `Service`), but the singleton (`StatusBarManager.getInstance(context)`) is created by manually calling `new StatusBarManager(context, stringUtils)` — it is **never actually bound/started as a real Service by the Android system** (that would require the user to explicitly grant "Notification access" in Settings, a separate, rarely-granted permission this app doesn't request). Most of `StatusBarManager`'s methods correctly use the explicitly-passed `Context` parameter, but `_getAllActiveIdsWithoutServices()` (backing both `getAllActiveNotificationIdsOnStatusBar()` and `isNotificationActiveOnStatusBar()`) calls the bare, inherited `getSystemService(...)` — implicitly `this.getSystemService(...)` from the `Service`/`ContextWrapper` base class — instead of using the injected context. Since this object was never attached as a real Service, its inherited base context is null, so any inherited `Context` method NPEs. This looks like a genuine bug in the `awesome_notifications`/`AndroidAwnCore` library itself, not something fixable from our side.

**Fix**: reverted the `getAllActiveNotificationIdsOnStatusBar()` reconciliation entirely (removed from `CalendarRefreshService.refreshNotifications()`; removed the now-unused `ActiveNotificationStore.removeAll()` helper). Replaced with something that doesn't depend on a broken native API: **`BootReceiver.kt` now only wipes `active_notification_hashes` for a genuine `Intent.ACTION_BOOT_COMPLETED`, never for `MY_PACKAGE_REPLACED`.**

**Why this is actually the more correct fix, not just a workaround**: the assumption that `MY_PACKAGE_REPLACED` clears the real OS notification shade was never verified and is very likely wrong — Android does not automatically cancel an app's existing status-bar notifications on a simple reinstall/update. A genuine `BOOT_COMPLETED`, by contrast, definitely does clear them (well-documented OS behavior; the system server does not persist posted notifications across a reboot). So:

- **On reinstall** (`MY_PACKAGE_REPLACED`): don't wipe — the real notifications (and their correct "already shown" bookkeeping) survive, so nothing needs reconciling. This matches the confirmed-working fix from the first repro.
- **On a true reboot** (`BOOT_COMPLETED`): wipe — the real notifications are genuinely gone, so clearing our bookkeeping to match reality is correct, restoring the original intent (un-dismissed reminders reappear) without any dependency on the broken status-bar query API.

**Still to verify empirically**: a real device reboot test (not yet performed) to confirm a shown-but-un-dismissed reminder reappears after `BOOT_COMPLETED`, and that a reinstall no longer reproduces stale "ghost" notifications (already confirmed once, should hold since this code path is unchanged for `MY_PACKAGE_REPLACED`).

---

## 2026-08-08 explicit requirement: dismissed notifications must NEVER reappear, on either event

After the `BOOT_COMPLETED`-only wipe above, the user clarified the actual, real-world repro pattern and the hard requirement it implies: **swipe a notification away (dismiss it), then reinstall the app** — and historically this reappeared. The requirement is explicit and symmetric: *"A reboot or a reinstall MUST re-show ONLY un-dismissed notifications."* Dismissed ones must never come back, on **either** event.

**Why the `BOOT_COMPLETED`-only wipe still failed this requirement**: `ActiveNotificationStore` is the *only* thing that reliably protects a swiped-away notification from reappearing when its `DismissedEventsStore` write is delayed or lost. Tracing `EventMonitorService._dismissEvent()`:

- The swipe itself removes the notification from the real OS status bar **instantly and natively** — the user perceives it as "dismissed" immediately, independent of any Dart code.
- But persisting that fact to `DismissedEventsStore` requires a background isolate (`DartDismissedNotificationReceiver` → Flutter background execution) to cold-start a Flutter engine first — per the 2026-08-08 capture, that alone took **~1.5-2 seconds** (`WorkManager refresh task enqueued` → `Awesome Notifications plugin attached to Android engine`). If the app is reinstalled or the device reboots inside that window, the `DismissedEventsStore` write may never happen.
- `EventMonitorService._dismissEvent()` deliberately does **not** remove the hash from `ActiveNotificationStore` on dismiss (comment: "Keep hash in ActiveNotificationStore as a cross-isolate safety net") — specifically so `EventProcessor`'s `"already active, skip re-show"` check still catches it even if the `DismissedEventsStore` write never lands. This is the *real* safety net for the dismiss race, not `DismissedEventsStore` itself.
- Wiping `active_notification_hashes` on `BOOT_COMPLETED` — even only there — destroys that safety net for exactly the swipe-then-reboot case, so a genuinely-dismissed notification whose write hadn't landed yet **could still reappear after a real reboot**. That's a direct violation of the stated requirement.

**Fix applied at the time**: removed the `BOOT_COMPLETED` wipe too, so `BootReceiver.kt` never cleared `active_notification_hashes` on any event — later found to be too blunt (see below).

---

## 2026-08-08 delayed-wipe fix: a real device test showed the never-wipe fix broke the other half of the requirement

A real reboot test (reminder shown, deliberately left un-dismissed, then device rebooted) captured:

```
23:22:35.805 [AnchorCal]   Event "Test 1": 1 reminders, start=2026-08-08 23:30:00.000
23:22:35.837 [AnchorCal.Store] STORE isDismissed hash=12358def => false
23:22:36.282 [AnchorCal]     Reminder 10 min: already active, skipping re-show
```

This confirms the predicted trade-off from the never-wipe fix actually mattered in practice: `isDismissed` correctly returned `false` (it really wasn't dismissed), but `active_notification_hashes` — never cleared by the previous fix — still said this hash was "active," so `EventProcessor` skipped re-showing it even though the real reboot had genuinely cleared the OS notification. This violates the other half of the user's requirement ("a reboot ... MUST re-show ... un-dismissed notifications").

**Fix (first attempt, replaced)**: `BootReceiver.kt` enqueued a dedicated `ClearActiveHashesWorker` (a plain `androidx.work.Worker`, not the Flutter `BackgroundWorker` — no Flutter engine spin-up needed) with a fixed **10-second initial delay**, only for genuine `ACTION_BOOT_COMPLETED`. Correctly flagged as fragile: a fixed constant is a guess at worst-case device speed, not a guarantee — a slower/busier device could still lose the race, and a faster one pays an unnecessarily long wait.

**Fix (final)**: replaced the fixed delay with a **WorkManager chain**: `ClearActiveHashesWorker` now runs via `.then()` after the boot's own `anchorCalRefresh` (`boot_refresh_work`) task *completes*, plus a small 3-second buffer, instead of after an arbitrary constant. This self-calibrates to the actual device: `anchorCalRefresh` needs the same Flutter-engine cold-start cost a racing dismiss-write isolate does, so waiting for our own boot refresh to actually finish on *this* hardware is a real, adaptive signal rather than a guess at a worst case — a slow device naturally gets a longer effective wait, a fast one a shorter one. The 3s buffer only needs to cover the (independent) dismiss isolate starting slightly later than ours, not a full second cold-start. (At this point `MY_PACKAGE_REPLACED` still didn't trigger the wipe — see "MY_PACKAGE_REPLACED also assumed to clear notifications" below for the update that changed this.)

**Honest caveat**: this is still a heuristic, not a proof — the dismiss isolate and our own boot-refresh isolate are independent processes with no synchronization primitive between them, so an adversarial scheduling order could still in principle lose the race. A fully deterministic fix would require the dismiss write to happen synchronously and natively (e.g. bypassing the Flutter engine entirely), which isn't feasible without patching `AndroidAwnCore`: its dismiss `PendingIntent` targets its own receiver class explicitly, so no other manifest-registered receiver can observe that broadcast to write the flag natively and synchronously ourselves. Chaining after our own comparable engine-startup work is the most robust mitigation achievable without forking the plugin.

This resolves both halves of the requirement:
- **Dismissed never reappears**: whether on reboot or reinstall, a race-losing dismiss write lands well within the chained wait and `isDismissed` catches it before the active-hash bookkeeping is ever touched.
- **Un-dismissed reappears after a real reboot**: once the chained wait passes, `active_notification_hashes` is cleared, so a reminder that was genuinely never touched (like the `Test 1` case above) is no longer suppressed and gets recreated on the next refresh.

**Still to verify empirically**:
1. Swipe-dismiss a notification, then immediately run `debug_deploy.bat` (reinstall) — confirm it does **not** reappear.
2. Swipe-dismiss a notification, then immediately trigger a real device reboot — confirm it does **not** reappear either (chained after `anchorCalRefresh` + 3s buffer should cover this; both isolates pay similar cold-start cost).
3. Show a reminder, deliberately leave it un-dismissed, then reboot — confirm it now reappears once the boot refresh + buffer completes (this exact case previously failed, per the capture above).

---

## 2026-08-08 MY_PACKAGE_REPLACED also assumed to clear notifications

Earlier sections assumed `MY_PACKAGE_REPLACED` (reinstall/update) does **not** clear the OS notification shade, unlike a real `BOOT_COMPLETED` — that assumption was never verified empirically (see "2026-08-08 status-bar API is broken" above) and has now been changed: **both events are treated identically**. `BootReceiver.kt` no longer branches on `intent.action` for the wipe decision — the chained `ClearActiveHashesWorker` (after `boot_refresh_work` completes + 3s buffer) now runs unconditionally for both `BOOT_COMPLETED` and `MY_PACKAGE_REPLACED`.

This is consistent with the "dismissed never reappears" guarantee for the same reason as before: the chain still waits for a comparable engine cold-start before wiping, so a dismiss write racing a reinstall gets the same protection a dismiss write racing a reboot does.

**Still to verify empirically**:
1. Swipe-dismiss a notification, then immediately run `debug_deploy.bat` (reinstall) — confirm it does **not** reappear (now chained + buffered the same as reboot).
2. Show a reminder, deliberately leave it un-dismissed, then reinstall via `debug_deploy.bat` — confirm it now reappears once the boot refresh + buffer completes (previously it would not have, since `MY_PACKAGE_REPLACED` never wiped before this change).

---

## 2026-08-08 missing piece: clearing the store doesn't re-show anything by itself

Spotted before it caused a real failure: the chain was `boot_refresh_work` (runs `fullRefresh()` while `active_notification_hashes` is still populated) → `ClearActiveHashesWorker` (wipes it). Nothing then re-evaluated events after the wipe — a reminder freed up by clearing the store would just sit there, un-shown, until some unrelated future trigger happened to run `fullRefresh()` again (the next periodic WorkManager run, the user opening the app, or a calendar change). That could be minutes or hours later, effectively reintroducing the "un-dismissed reappears after reboot" gap this whole fix was for.

**Fix**: appended a third chained step, `postClearRefreshWork` — another `anchorCalRefresh` `BackgroundWorker` run — after `ClearActiveHashesWorker`. Since `WorkManager` chain steps are strictly sequential (each one only starts once the previous returns `Result.success()`), this adds no new timing guesswork: the final refresh is guaranteed to run only after the wipe has actually finished persisting, and by then `DismissedEventsStore` also reflects any dismiss write that landed during the earlier buffer. The full chain is now: `boot_refresh_work` → `clear_active_hashes` (+3s buffer) → `post_clear_refresh`.

**Still to verify empirically**: repeat test 3 from the "explicit requirement" section above (show a reminder, leave it un-dismissed, reboot) and confirm it now reappears automatically without needing to open the app or wait for the next periodic refresh.

---

## Potential Fix Directions

**Note**: the directions below (A/B/C) target the SQLite-schedule-survival theory, which is a separate, still-unconfirmed sub-case (a dismissed notification whose schedule row survives to a reboot replay). The root cause actually confirmed and fixed in this session was different — see "2026-08-08 CONFIRMED root cause" above.

### Direction A: Make schedule cancellation on dismiss more reliable

Since the root cause is now understood to be "the Dart-side `cancel()` call may not complete before reboot," the most targeted fix is ensuring that call reliably runs to completion — e.g., by not depending solely on the implicit background-isolate execution window, or by adding the defensive re-cancel (already present in `EventProcessor.processEvent`) to run as early as possible in the boot refresh path, before `RefreshSchedulesReceiver`'s native re-arm can fire. Ordering between two independently-registered `BOOT_COMPLETED` receivers is not guaranteed by Android, so this cannot be fully solved from our own receiver alone.

### Direction B: Verify and re-add a short-lived native `cancelAll()` guard after boot

Given Direction A can't guarantee ordering, a short, bounded native cleanup pass in `BootReceiver.kt` (re-implementing what was previously documented) remains a reasonable pragmatic mitigation — now that we know precisely *why* it works (it wins the race against `RefreshSchedulesReceiver`'s re-arm before our own Dart-side refresh has a chance to run).

### Direction C: Accept the current behavior

The ghost notifications disappear when the user opens the app. If the window of visibility is short enough (milliseconds), this may be "good enough." However, the bug is visible and there is currently no mitigation in place at all.

---

## Monitoring / How to Verify (added 2026-08-08)

Diagnostic instrumentation has been added so the leading hypothesis — *"the Dart-side `cancel()` call on dismiss doesn't reliably remove the schedule row from awesome_notifications' own `SQLiteSchedulesDB` before the next boot/reinstall, so `RefreshSchedulesReceiver` legitimately replays it"* — can be confirmed or refuted empirically, without needing native `AndroidAwnCore` debug logging (which won't be active in the critical window anyway — see below).

### What was added

1. **`EventMonitorService._dismissEvent()`** now checks `AwesomeNotifications().listScheduledNotifications()` immediately before and after calling `cancel(notificationId)`, and logs a `DIAGNOSTIC` entry (via `NotificationLogStore`, visible in the in-app Debug Log screen) stating whether the schedule row **survived** or was **removed**.
2. **`CalendarRefreshService.fullRefresh()`** (shared by both the foreground app-open path and the WorkManager background/boot path) now logs a `DIAGNOSTIC` snapshot of every schedule ID still present in the plugin at the moment the refresh starts.
3. **`BootReceiver.kt`** now logs precise `System.currentTimeMillis()` timestamps at receiver-start and after the WorkManager task is enqueued, tagged `AnchorCal.Boot`, to compare against Dart-side log timestamps.

### Repro steps (using `debug_deploy.bat`) — logcat only, do NOT open the app

**Important**: don't open the app at any point during observation. Launching the Activity runs `EventMonitorService.init()` in the foreground, which calls the same `fullRefresh()` that "fixes" ghosts — so opening the app to check anything (including the Debug Log screen) destroys the exact state you're trying to observe before you can confirm it. The WorkManager background task enqueued by `BootReceiver` runs `fullRefresh()` on its own, with no user interaction, and its diagnostic log lines are written via `debugPrint()` (switched from `developer.log()` — see "2026-08-08 logcat capture" above, which confirmed the latter doesn't reach plain `adb logcat`), which Flutter's engine reliably forwards to `adb logcat` under the `flutter` tag for debug builds, with no VM service listener required. So everything needed is now visible in plain logcat without touching the phone.

**Caveat (historical)**: earlier revisions of this doc warned that `developer.log()`'s routing to plain `adb logcat` wasn't guaranteed — this was confirmed true by a real capture (see above) and is why logging was switched to `debugPrint()`. If for some reason `debugPrint()` output still doesn't appear (e.g. a future Flutter engine change), fall back to `flutter logs`/`flutter attach`, which always receives Dart output via the VM service protocol. Either way, do **not** open the app UI itself to check — attaching a log listener from a terminal doesn't count as "opening the app" and won't trigger a foreground refresh.

1. Start capturing logs *before* reinstalling, so nothing is missed:
   ```powershell
   adb logcat -c  # clear old logs
   adb logcat -v time | Tee-Object -FilePath ghost_repro.log
   ```
   Leave this running in its own terminal for the rest of the repro.
2. In a separate terminal, let a reminder notification fire and stay visible, then dismiss it (swipe away, or use the in-app dismiss/snooze action) — **but avoid reopening the app after this**. Look in the logcat capture for the dismiss-time diagnostic line ("schedule row removed by cancel()" or "SURVIVED cancel()!").
3. Run `debug_deploy.bat` to reinstall (triggers `MY_PACKAGE_REPLACED`, which is one of the intents the plugin's own `DartRefreshSchedulesReceiver` listens for — confirmed in the plugin's `AndroidManifest.xml`). Do not tap the app icon afterward.
4. Watch the notification shade (visually, without unlocking into the app) for the ghost reappearing, and watch the logcat capture for `AnchorCal.Boot` (BootReceiver timestamps) and the `fullRefresh start` diagnostic line — this fires automatically once WorkManager runs the enqueued task, with no app interaction needed.
5. Compare: is the ghost notification's ID present in the `scheduledIds` list logged by that automatic `fullRefresh start` line? If yes, the schedule row survived to the reinstall replay, confirming the hypothesis — captured entirely without ever opening the app.
6. Only afterward, once you're done observing, feel free to open the app and check the Debug Log screen — all entries are persisted (`NotificationLogStore` backs onto `SharedPreferences`, shared across isolates), so nothing is lost by waiting.

### Reading logcat (what to grep for)

```powershell
adb logcat -v time | Select-String -Pattern "AnchorCal|Awesome Notifications"
```

- `AnchorCal.Boot` lines: our `BootReceiver`'s precise timestamps (native `Log.d`, unaffected by the logging change below).
- `[AnchorCal]` / `[AnchorCal.Action]` / `[AnchorCal.Store]` lines (note the brackets — this is the new `debugPrint()`-based format, tag is plain `flutter` in logcat with the bracketed name embedded in the message): our own log calls (`_log()` helpers), including the new "fullRefresh start: N schedule rows present: [...]" and "DIAGNOSTIC: schedule row for ID ..." lines. These are emitted by the WorkManager background isolate automatically — no app-opening required, and now reliably reach plain logcat (previously did not — see "2026-08-08 logcat capture" above).
- `Awesome Notifications` lines (the plugin's own `Logger` — tag is literally `Android: [Awesome Notifications]` with embedded ANSI color codes, hence the substring match). Note: most of the plugin's internal logs are gated behind a static `AwesomeNotifications.debug` flag that is **false by default in a freshly-launched process** and only gets set to `true` once Dart calls `.initialize(..., debug: true)` — which happens *after* `RefreshSchedulesReceiver` has already run in that process. Plugin *attach* logs (e.g. "Awesome Notifications plugin attached to Android") are not gated and do show up regardless, as seen in the 2026-08-08 capture. So don't expect verbose native logs during the critical replay window; the Dart-side `DIAGNOSTIC` log entries are the more reliable signal.

### What to do with the result

- **If schedule rows for dismissed notifications reliably survive to the automatic boot-refresh snapshot**: this confirms the race between the Dart-side `cancel()` (which can't be guaranteed to run to completion before a reboot) and the plugin's native `RefreshSchedulesReceiver`. The fix directions in this doc (A/B below) apply.
- **If schedule rows are reliably removed** (i.e., `cancel()` always wins in your testing) but ghosts still appear: the root cause is elsewhere (e.g., a notification ID collision from a recomputed event hash, or an orphaned schedule that was never associated with a currently-tracked hash) and needs separate investigation — check the `fullRefresh snapshot` diagnostic for *unexpected* IDs that don't map to any currently-valid event hash.
- **If the WorkManager background task's own `fullRefresh()` already reliably cleans up the ghost** (i.e., the diagnostic shows the row present but it's gone again moments later, without the app ever being opened): that would contradict the established "opening the app fixes it" behavior and is worth noting — it may mean the fix is timing-sensitive (WorkManager execution delay) rather than strictly requiring the app to be foregrounded.

---

## Files Referenced

| File | Purpose |
|------|---------|
| `lib/main.dart` | App entry point, triggers refresh on launch |
| `lib/services/event_monitor_service.dart` | Notification callbacks (created/displayed/dismissed/action); now also logs dismiss-time schedule-survival diagnostics |
| `lib/services/calendar_refresh_service.dart` | Shared refresh logic (foreground + background); now also logs a schedule-snapshot diagnostic at the start of `fullRefresh()` |
| `lib/services/event_processor.dart` | Processes calendar events, checks dismissed store before creating |
| `lib/services/active_notification_store.dart` | Tracks which reminders were already shown, to avoid duplicate re-shows |
| `lib/services/dismissed_events_store.dart` | Persistent dismissed/snoozed hash store (SharedPreferences) |
| `lib/services/background_service.dart` | WorkManager background refresh |
| `lib/services/notification_log_store.dart` | Persistent log store backing the Debug Log screen; now includes a `diagnostic` event type |
| `lib/screens/debug_log_screen.dart` | In-app log viewer — only for later/optional review, not needed for live monitoring |
| `android/.../BootReceiver.kt` | Handles BOOT_COMPLETED, MY_PACKAGE_REPLACED (both now assumed to clear the OS notification shade); logs precise timestamps for correlation; chains three steps: boot refresh → `ClearActiveHashesWorker` (+3s buffer) → a second refresh, so reminders freed by the wipe actually get re-shown right away |
| `android/.../ClearActiveHashesWorker.kt` | Plain (non-Flutter) `Worker` that clears `active_notification_hashes` from SharedPreferences; chained to run after the boot refresh task so it doesn't race a just-in-progress dismiss write |
| `android/.../AndroidManifest.xml` | App manifest with receiver registrations |
