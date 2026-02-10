import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../services/notification_log_store.dart';

/// Debug screen showing notification event log.
/// Only accessible in debug builds.
class DebugLogScreen extends StatefulWidget {
  const DebugLogScreen({super.key});

  @override
  State<DebugLogScreen> createState() => _DebugLogScreenState();
}

class _DebugLogScreenState extends State<DebugLogScreen> {
  List<NotificationLogEntry> _entries = [];
  bool _loading = true;
  NotificationEventType? _filterType;

  @override
  void initState() {
    super.initState();
    _loadEntries();
  }

  Future<void> _loadEntries() async {
    setState(() => _loading = true);
    final entries = await NotificationLogStore.instance.getEntries();
    setState(() {
      _entries = entries;
      _loading = false;
    });
  }

  Future<void> _clearLog() async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Clear Log'),
        content: const Text('Delete all notification log entries?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Clear'),
          ),
        ],
      ),
    );
    if (confirm == true) {
      await NotificationLogStore.instance.clear();
      await _loadEntries();
    }
  }

  List<NotificationLogEntry> get _filteredEntries {
    if (_filterType == null) return _entries;
    return _entries.where((e) => e.eventType == _filterType).toList();
  }

  Color _colorForType(NotificationEventType type) {
    switch (type) {
      case NotificationEventType.scheduled:
        return Colors.blue;
      case NotificationEventType.shown:
        return Colors.green;
      case NotificationEventType.dismissed:
        return Colors.grey;
      case NotificationEventType.snoozed:
        return Colors.orange;
      case NotificationEventType.opened:
        return Colors.purple;
      case NotificationEventType.cancelled:
        return Colors.red;
    }
  }

  IconData _iconForType(NotificationEventType type) {
    switch (type) {
      case NotificationEventType.scheduled:
        return Icons.schedule;
      case NotificationEventType.shown:
        return Icons.notifications_active;
      case NotificationEventType.dismissed:
        return Icons.notifications_off;
      case NotificationEventType.snoozed:
        return Icons.snooze;
      case NotificationEventType.opened:
        return Icons.open_in_new;
      case NotificationEventType.cancelled:
        return Icons.cancel;
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!kDebugMode) {
      return Scaffold(
        appBar: AppBar(title: const Text('Debug Log')),
        body: const Center(child: Text('Debug mode only')),
      );
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text('Notification Log'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: _loadEntries,
            tooltip: 'Refresh',
          ),
          IconButton(
            icon: const Icon(Icons.delete_outline),
            onPressed: _clearLog,
            tooltip: 'Clear Log',
          ),
        ],
      ),
      body: Column(
        children: [
          // Filter chips
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            child: Row(
              children: [
                FilterChip(
                  label: const Text('All'),
                  selected: _filterType == null,
                  onSelected: (_) => setState(() => _filterType = null),
                ),
                const SizedBox(width: 4),
                ...NotificationEventType.values.map(
                  (type) => Padding(
                    padding: const EdgeInsets.only(left: 4),
                    child: FilterChip(
                      label: Text(type.name.toUpperCase()),
                      selected: _filterType == type,
                      onSelected: (_) => setState(() => _filterType = type),
                      selectedColor: _colorForType(type).withValues(alpha: 0.3),
                    ),
                  ),
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          // Stats
          Padding(
            padding: const EdgeInsets.all(8),
            child: Text(
              'Total: ${_entries.length} entries, '
              'Showing: ${_filteredEntries.length}',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
          // Entry list
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : _filteredEntries.isEmpty
                ? const Center(child: Text('No log entries'))
                : ListView.builder(
                    itemCount: _filteredEntries.length,
                    itemBuilder: (ctx, i) {
                      final entry = _filteredEntries[i];
                      return _buildEntryTile(entry);
                    },
                  ),
          ),
        ],
      ),
    );
  }

  Widget _buildEntryTile(NotificationLogEntry entry) {
    final timeFormat = DateFormat('MM/dd HH:mm:ss');
    final color = _colorForType(entry.eventType);

    return ExpansionTile(
      leading: Icon(_iconForType(entry.eventType), color: color),
      title: Text(
        entry.eventTitle,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: Text(
        '${entry.eventTypeName} @ ${timeFormat.format(entry.timestamp)}',
        style: TextStyle(color: color, fontSize: 12),
      ),
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _detailRow('Time', timeFormat.format(entry.timestamp)),
              _detailRow('Type', entry.eventTypeName),
              _detailRow('Hash', entry.eventHash.length > 16
                  ? entry.eventHash.substring(0, 16)
                  : entry.eventHash),
              if (entry.notificationId != null)
                _detailRow('Notification ID', entry.notificationId.toString()),
              if (entry.extra != null) _detailRow('Extra', entry.extra!),
            ],
          ),
        ),
      ],
    );
  }

  Widget _detailRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 100,
            child: Text(
              '$label:',
              style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 12),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: const TextStyle(fontSize: 12, fontFamily: 'monospace'),
            ),
          ),
        ],
      ),
    );
  }
}
