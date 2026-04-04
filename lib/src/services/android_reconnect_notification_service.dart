import 'dart:async';
import 'dart:convert';

import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:lifeos_sftp_drive/src/utils/platform_utils.dart' as pu;

enum ReconnectNotificationAction { reconnectNow, resumeLastSession }

class ReconnectNotificationCommand {
  const ReconnectNotificationCommand({
    required this.tabId,
    required this.action,
  });

  final String tabId;
  final ReconnectNotificationAction action;
}

@pragma('vm:entry-point')
void onReconnectNotificationTapBackground(NotificationResponse response) {
  AndroidReconnectNotificationService.instance.handleNotificationResponse(
    response,
  );
}

class AndroidReconnectNotificationService {
  AndroidReconnectNotificationService._();

  static final AndroidReconnectNotificationService instance =
      AndroidReconnectNotificationService._();

  static const _channelId = 'lifeos_gate_reconnect';
  static const _channelName = 'SSH Reconnect';
  static const _channelDescription = 'Reconnect actions for SSH disconnections';
  static const _actionReconnect = 'reconnect_now';
  static const _actionResume = 'resume_last_session';

  final FlutterLocalNotificationsPlugin _plugin =
      FlutterLocalNotificationsPlugin();
  final StreamController<ReconnectNotificationCommand> _commandsController =
      StreamController<ReconnectNotificationCommand>.broadcast();
  bool _initialized = false;

  Stream<ReconnectNotificationCommand> get commands =>
      _commandsController.stream;

  Future<void> ensureInitialized() async {
    if (!pu.isAndroid || _initialized) {
      return;
    }

    const initSettings = InitializationSettings(
      android: AndroidInitializationSettings('@mipmap/ic_launcher'),
    );

    await _plugin.initialize(
      initSettings,
      onDidReceiveNotificationResponse: handleNotificationResponse,
      onDidReceiveBackgroundNotificationResponse:
          onReconnectNotificationTapBackground,
    );

    final androidPlugin = _plugin
        .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin
        >();
    await androidPlugin?.requestNotificationsPermission();
    await androidPlugin?.createNotificationChannel(
      const AndroidNotificationChannel(
        _channelId,
        _channelName,
        description: _channelDescription,
        importance: Importance.high,
      ),
    );

    _initialized = true;
  }

  Future<void> showReconnectActions({
    required String tabId,
    required String hostLabel,
    required bool isTr,
  }) async {
    if (!pu.isAndroid) return;
    await ensureInitialized();
    if (!_initialized) return;

    final details = NotificationDetails(
      android: AndroidNotificationDetails(
        _channelId,
        _channelName,
        channelDescription: _channelDescription,
        importance: Importance.high,
        priority: Priority.high,
        category: AndroidNotificationCategory.status,
        autoCancel: true,
        onlyAlertOnce: true,
        actions: [
          AndroidNotificationAction(
            _actionReconnect,
            isTr ? 'Yeniden Bağlan' : 'Reconnect',
            showsUserInterface: true,
            cancelNotification: true,
          ),
          AndroidNotificationAction(
            _actionResume,
            isTr ? 'Son Oturuma Dön' : 'Resume Last Session',
            showsUserInterface: true,
            cancelNotification: true,
          ),
        ],
      ),
    );

    final title = isTr ? 'SSH bağlantısı koptu' : 'SSH connection lost';
    final body = isTr
        ? '$hostLabel için bir işlem seç.'
        : 'Choose an action for $hostLabel.';

    await _plugin.show(
      _idForTab(tabId),
      title,
      body,
      details,
      payload: jsonEncode({'tabId': tabId}),
    );
  }

  Future<void> cancelForTab(String tabId) async {
    if (!pu.isAndroid || !_initialized) return;
    await _plugin.cancel(_idForTab(tabId));
  }

  Future<void> cancelAll() async {
    if (!pu.isAndroid || !_initialized) return;
    await _plugin.cancelAll();
  }

  void handleNotificationResponse(NotificationResponse response) {
    final payload = response.payload;
    if (payload == null || payload.isEmpty) {
      return;
    }

    String tabId = '';
    try {
      final decoded = jsonDecode(payload);
      if (decoded is Map<String, dynamic>) {
        tabId = (decoded['tabId'] ?? '').toString();
      }
    } catch (_) {
      tabId = '';
    }
    if (tabId.isEmpty) {
      return;
    }

    final action = response.actionId == _actionResume
        ? ReconnectNotificationAction.resumeLastSession
        : ReconnectNotificationAction.reconnectNow;

    _commandsController.add(
      ReconnectNotificationCommand(tabId: tabId, action: action),
    );
  }

  int _idForTab(String tabId) {
    final hash = tabId.hashCode & 0x7fffffff;
    return 40000 + (hash % 20000);
  }
}

