
# AnchorCal

Android-only Flutter utility. Hooks into system calendar, monitors events, and shows persistent notifications for active events. Notifications remain after event ends until user dismisses (swipe or button). Supports multiple calendars. No internet access. Minimal UI: persistent notifications and a settings screen.

## Usage

1. Grant calendar and notification permissions.
2. App monitors calendar events and posts persistent notifications.
   - Calendar changes are detected in near-real-time via native content observer.
   - A periodic background task also runs as a fallback.
3. Notifications persist until user dismisses.
4. Configure behavior in settings.

## Possible Future Enhancements

- **Calendar selection UI** — Allow enabling/disabling specific calendars. Currently all calendars are monitored.
