import 'package:android_intent_plus/android_intent.dart';

/// Service to launch the system calendar app.
class CalendarLauncher {
  /// Launch the system calendar app showing a specific event.
  /// Falls back to opening the calendar app if event-specific URI fails.
  static Future<void> openEvent(String eventId) async {
    // Try content://com.android.calendar/events/{id}
    final eventUri = Uri.parse('content://com.android.calendar/events/$eventId');
    
    try {
      final intent = AndroidIntent(
        action: 'android.intent.action.VIEW',
        data: eventUri.toString(),
      );
      await intent.launch();
    } catch (_) {
      // Fallback: just open the calendar app
      await openCalendarApp();
    }
  }

  /// Launch the system calendar app.
  static Future<void> openCalendarApp() async {
    // Open calendar at current time
    const calendarUri = 'content://com.android.calendar/time/';
    
    try {
      final intent = AndroidIntent(
        action: 'android.intent.action.VIEW',
        data: '$calendarUri${DateTime.now().millisecondsSinceEpoch}',
      );
      await intent.launch();
    } catch (_) {
      // No calendar app available - silently fail (no internet fallback per privacy policy)
    }
  }
}
