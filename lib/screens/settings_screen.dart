import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:permission_handler/permission_handler.dart';

import '../services/settings_service.dart';
import '../services/event_monitor_service.dart';
import '../services/permissions_helper.dart';
import '../services/background_service.dart';
import 'debug_log_screen.dart';

/// Settings screen for AnchorCal app configuration.
class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  final SettingsService _settings = SettingsService.instance;
  final EventMonitorService _eventMonitor = EventMonitorService.instance;

  int _snoozeDuration = 15;
  bool _persistOverReboot = true;
  bool _refreshing = false;
  bool _showPermissionOverlay = false;

  // Permission states
  bool _hasCalendarPermission = false;
  bool _hasNotificationPermission = false;
  bool _hasExactAlarmPermission = false;
  bool _hasBatteryOptimization = false;
  bool? _isAutoRevokeDisabled; // null = not supported
  bool _calendarPermanentlyDenied = false;
  bool _notificationPermanentlyDenied = false;

  late final AppLifecycleListener _lifecycleListener;

  @override
  void initState() {
    super.initState();
    _lifecycleListener = AppLifecycleListener(onResume: _checkPermissions);
    _loadSettings();
    _checkPermissionsAndShowOverlay();
  }

  @override
  void dispose() {
    _lifecycleListener.dispose();
    super.dispose();
  }

  Future<void> _checkPermissionsAndShowOverlay() async {
    await _checkPermissions();
    // Show overlay on first run if essential permissions missing
    if (!_hasCalendarPermission || !_hasNotificationPermission) {
      setState(() => _showPermissionOverlay = true);
    }
  }

  Future<void> _loadSettings() async {
    await _settings.init();
    setState(() {
      _snoozeDuration = _settings.snoozeDurationMinutes;
      _persistOverReboot = _settings.persistOverReboot;
    });
  }

  Future<void> _checkPermissions() async {
    final calendarStatus = await Permission.calendarFullAccess.status;
    final notificationStatus = await Permission.notification.status;
    final exactAlarm = await PermissionsHelper.hasExactAlarmPermission();
    final battery = await PermissionsHelper.isBatteryOptimizationDisabled();
    final autoRevoke = await PermissionsHelper.isAutoRevokeDisabled();

    setState(() {
      _hasCalendarPermission = calendarStatus.isGranted;
      _hasNotificationPermission = notificationStatus.isGranted;
      _hasExactAlarmPermission = exactAlarm;
      _hasBatteryOptimization = battery;
      _isAutoRevokeDisabled = autoRevoke;
      _calendarPermanentlyDenied = calendarStatus.isPermanentlyDenied;
      _notificationPermanentlyDenied = notificationStatus.isPermanentlyDenied;
    });
  }

  Future<void> _refreshNotifications() async {
    setState(() => _refreshing = true);

    try {
      // Request all permissions including calendar
      final perms = await PermissionsHelper.requestAllPermissions();

      if (!(perms['calendar'] ?? false)) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Calendar permission required')),
          );
        }
        return;
      }

      if (!(perms['notification'] ?? false)) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Notification permission required')),
          );
        }
        return;
      }

      await _eventMonitor.refreshNotifications();

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Notifications refreshed')),
        );
      }
    } finally {
      if (mounted) {
        setState(() => _refreshing = false);
        await _checkPermissions();
      }
    }
  }

  Future<void> _setSnoozeDuration(int minutes) async {
    await _settings.setSnoozeDurationMinutes(minutes);
    setState(() => _snoozeDuration = minutes);
  }

  Future<void> _setPersistOverReboot(bool value) async {
    await _settings.setPersistOverReboot(value);
    setState(() => _persistOverReboot = value);

    if (value) {
      await BackgroundService.instance.registerPeriodicTask();
    } else {
      await BackgroundService.instance.cancelAll();
    }
  }

  Future<void> _requestCalendarPermission() async {
    final status = await Permission.calendarFullAccess.request();
    setState(() => _hasCalendarPermission = status.isGranted);
  }

  Future<void> _requestNotificationPermission() async {
    final status = await Permission.notification.request();
    setState(() => _hasNotificationPermission = status.isGranted);
  }

  Future<void> _requestExactAlarmPermission() async {
    final granted = await PermissionsHelper.requestExactAlarmPermission();
    setState(() => _hasExactAlarmPermission = granted);
  }

  Future<void> _requestBatteryOptimization() async {
    final granted =
        await PermissionsHelper.requestBatteryOptimizationExemption();
    setState(() => _hasBatteryOptimization = granted);
  }

  Future<void> _openAutoRevokeSettings() async {
    await PermissionsHelper.openAutoRevokeSettings();
    // Recheck after returning from settings
    await _checkPermissions();
  }

  Widget _buildPermissionTile({
    required String title,
    required String subtitle,
    required bool granted,
    required VoidCallback onRequest,
    bool permanentlyDenied = false,
  }) {
    return ListTile(
      title: Text(title),
      subtitle: Text(subtitle),
      trailing: granted
          ? const Icon(Icons.check_circle, color: Colors.green)
          : permanentlyDenied
          ? TextButton(
              onPressed: openAppSettings,
              style: TextButton.styleFrom(
                padding: EdgeInsets.zero,
                minimumSize: const Size(48, 36),
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
              child: const Text('Settings'),
            )
          : TextButton(
              onPressed: onRequest,
              style: TextButton.styleFrom(
                padding: EdgeInsets.zero,
                minimumSize: const Size(48, 36),
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
              child: const Text('Grant'),
            ),
    );
  }

  Future<void> _onPermissionOverlayProceed() async {
    setState(() => _showPermissionOverlay = false);
    await _refreshNotifications();
  }

  Widget _buildPermissionOverlay() {
    return Container(
      color: Colors.black54,
      child: Center(
        child: Card(
          margin: const EdgeInsets.all(32),
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Image.asset('assets/logo.png', width: 64, height: 64),
                const SizedBox(height: 16),
                const Text(
                  'Welcome to AnchorCal',
                  style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 16),
                const Text(
                  'AnchorCal needs a few permissions to work:\n\n'
                  '• Calendar access to read your events\n'
                  '• Notifications to alert you\n'
                  '• Exact alarms for precise timing\n'
                  '• Battery exemption for reliability\n\n'
                  'Calendar data is stored locally and never shared.',
                  textAlign: TextAlign.left,
                ),
                const SizedBox(height: 24),
                ElevatedButton(
                  onPressed: _onPermissionOverlayProceed,
                  style: ElevatedButton.styleFrom(
                    minimumSize: const Size(200, 48),
                  ),
                  child: const Text('Grant Permissions'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('AnchorCal Settings')),
      body: Stack(
        children: [
          ListView(
            children: [
              // Refresh Section
              Padding(
                padding: const EdgeInsets.all(16),
                child: ElevatedButton.icon(
                  onPressed: _refreshing ? null : _refreshNotifications,
                  icon: _refreshing
                      ? const SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.refresh),
                  label: Text(
                    _refreshing ? 'Refreshing...' : 'Refresh Notifications',
                  ),
                  style: ElevatedButton.styleFrom(
                    minimumSize: const Size.fromHeight(48),
                  ),
                ),
              ),

              const Divider(),

              // Settings Section
              const Padding(
                padding: EdgeInsets.fromLTRB(16, 8, 16, 0),
                child: Text(
                  'SETTINGS',
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.bold,
                    color: Colors.grey,
                  ),
                ),
              ),

              ListTile(
                title: const Text('Snooze Duration'),
                subtitle: Text('$_snoozeDuration minutes'),
                trailing: DropdownButton<int>(
                  value: _snoozeDuration,
                  items: const [
                    DropdownMenuItem(value: 5, child: Text('5 min')),
                    DropdownMenuItem(value: 10, child: Text('10 min')),
                    DropdownMenuItem(value: 15, child: Text('15 min')),
                    DropdownMenuItem(value: 30, child: Text('30 min')),
                    DropdownMenuItem(value: 60, child: Text('1 hour')),
                  ],
                  onChanged: (value) {
                    if (value != null) _setSnoozeDuration(value);
                  },
                ),
              ),

              SwitchListTile(
                title: const Text('Persist Over Reboot'),
                subtitle: const Text('Keep notifications after device restart'),
                value: _persistOverReboot,
                onChanged: _setPersistOverReboot,
              ),

              const Divider(),

              // Permissions Section
              const Padding(
                padding: EdgeInsets.fromLTRB(16, 8, 16, 0),
                child: Text(
                  'PERMISSIONS',
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.bold,
                    color: Colors.grey,
                  ),
                ),
              ),

              _buildPermissionTile(
                title: 'Calendar Access',
                subtitle: _calendarPermanentlyDenied
                    ? 'Denied. Tap Settings to grant manually.'
                    : 'Required to read calendar events',
                granted: _hasCalendarPermission,
                onRequest: _requestCalendarPermission,
                permanentlyDenied: _calendarPermanentlyDenied,
              ),

              _buildPermissionTile(
                title: 'Notifications',
                subtitle: _notificationPermanentlyDenied
                    ? 'Denied. Tap Settings to grant manually.'
                    : 'Required to show event notifications',
                granted: _hasNotificationPermission,
                onRequest: _requestNotificationPermission,
                permanentlyDenied: _notificationPermanentlyDenied,
              ),

              _buildPermissionTile(
                title: 'Exact Alarms',
                subtitle: 'For precise notification timing',
                granted: _hasExactAlarmPermission,
                onRequest: _requestExactAlarmPermission,
              ),

              _buildPermissionTile(
                title: 'Battery Optimization',
                subtitle: 'Prevent app from being restricted',
                granted: _hasBatteryOptimization,
                onRequest: _requestBatteryOptimization,
              ),

              // Only show auto-revoke if supported (Android 11+)
              if (_isAutoRevokeDisabled != null)
                _buildPermissionTile(
                  title: 'Prevent Permission Revocation',
                  subtitle: 'Keep permissions when app appears unused',
                  granted: _isAutoRevokeDisabled!,
                  onRequest: _openAutoRevokeSettings,
                ),

              const Divider(),

              // About Section
              const Padding(
                padding: EdgeInsets.fromLTRB(16, 8, 16, 0),
                child: Text(
                  'ABOUT',
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.bold,
                    color: Colors.grey,
                  ),
                ),
              ),

              ListTile(
                leading: const Icon(Icons.info_outline),
                title: const Text('About AnchorCal'),
                trailing: const Icon(Icons.chevron_right),
                onTap: () async {
                  final info = await PackageInfo.fromPlatform();
                  if (!context.mounted) return;
                  showAboutDialog(
                    context: context,
                    applicationIcon: Image.asset(
                      'assets/logo.png',
                      width: 64,
                      height: 64,
                    ),
                    applicationName: info.appName,
                    applicationVersion: 'v${info.version}',
                    children: [
                      const SizedBox(height: 16),
                      const Text(
                        'This application is open source software, released under the ISC License.\n\n',
                      ),
                      const Text(
                        'Source code available at:\nhttps://github.com/arktronic/anchor_cal',
                      ),
                    ],
                  );
                },
              ),

              // Debug section (debug builds only)
              if (kDebugMode) ...[
                const Divider(),
                const Padding(
                  padding: EdgeInsets.fromLTRB(16, 8, 16, 0),
                  child: Text(
                    'DEBUG',
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.bold,
                      color: Colors.orange,
                    ),
                  ),
                ),
                ListTile(
                  leading: const Icon(Icons.bug_report, color: Colors.orange),
                  title: const Text('Notification Log'),
                  subtitle: const Text('View notification event history'),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () {
                    Navigator.push(
                      context,
                      MaterialPageRoute(builder: (_) => const DebugLogScreen()),
                    );
                  },
                ),
              ],

              // Info Section
              const Padding(
                padding: EdgeInsets.all(16),
                child: Text(
                  'AnchorCal monitors your calendar and shows persistent '
                  'notifications for active events. Notifications remain until '
                  'you dismiss them.',
                  style: TextStyle(color: Colors.grey),
                ),
              ),
            ],
          ),
          if (_showPermissionOverlay) _buildPermissionOverlay(),
        ],
      ),
    );
  }
}
