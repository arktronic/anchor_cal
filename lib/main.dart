import 'package:flutter/material.dart';

import 'services/event_monitor_service.dart';
import 'services/background_service.dart';
import 'services/settings_service.dart';
import 'services/permissions_helper.dart';
import 'screens/settings_screen.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await SettingsService.instance.init();
  await EventMonitorService.instance.init();
  await BackgroundService.instance.init();

  if (SettingsService.instance.persistOverReboot) {
    await BackgroundService.instance.registerPeriodicTask();
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
