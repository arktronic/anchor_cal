import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:timezone/data/latest.dart' as tz;

import 'services/event_monitor_service.dart';
import 'services/background_service.dart';
import 'services/settings_service.dart';
import 'services/permissions_helper.dart';
import 'screens/settings_screen.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  tz.initializeTimeZones();
  await SettingsService.instance.init();
  await EventMonitorService.instance.init();
  await BackgroundService.instance.init();

  if (SettingsService.instance.persistOverReboot) {
    await BackgroundService.instance.registerPeriodicTask();
  }

  // Check if app was launched from a notification tap
  final launchDetails = await FlutterLocalNotificationsPlugin()
      .getNotificationAppLaunchDetails();
  if (launchDetails?.didNotificationLaunchApp ?? false) {
    final response = launchDetails!.notificationResponse;
    if (response != null) {
      await EventMonitorService.instance.handleNotificationAction(response);
    }
    SystemNavigator.pop();
    return;
  }

  // Immediate refresh on app launch (handles post-upgrade, etc.)
  // Only if we already have permissions - otherwise let the UI handle onboarding.
  if (await PermissionsHelper.hasAllEssentialPermissions()) {
    EventMonitorService.instance.refreshNotifications();
  }

  runApp(const AnchorCalApp());
}

class AnchorCalApp extends StatelessWidget {
  const AnchorCalApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'AnchorCal',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF7C3AED)),
        useMaterial3: true,
      ),
      home: const SettingsScreen(),
    );
  }
}
