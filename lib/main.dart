import 'dart:async';
import 'dart:io';
import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:flutter_background/flutter_background.dart';
import 'package:flutter/widgets.dart';
import 'package:lifeos_sftp_drive/src/app.dart';
import 'package:lifeos_sftp_drive/src/state/app_controller.dart';
import 'package:lifeos_sftp_drive/src/utils/platform_utils.dart' as pu;
import 'package:system_theme/system_theme.dart';

export 'package:lifeos_sftp_drive/src/app.dart';

void _logCrash(String source, Object error, StackTrace? stack) {
  final msg = '[$source] $error\n${stack ?? "no stack"}\n';
  debugPrint('🔴 CRASH: $msg');
  try {
    final logFile = File('${Directory.current.path}\\crash_log.txt');
    logFile.writeAsStringSync(
      '${DateTime.now().toIso8601String()} $msg\n',
      mode: FileMode.append,
    );
  } catch (_) {}
}

Future<void> _enableAndroidBackgroundExecution() async {
  if (!pu.isAndroid) return;

  const androidConfig = FlutterBackgroundAndroidConfig(
    notificationTitle: 'LifeOS Gate',
    notificationText: 'Keeping SSH and monitoring tasks active in background',
    notificationImportance: AndroidNotificationImportance.normal,
    notificationIcon: AndroidResource(name: 'ic_launcher', defType: 'mipmap'),
    enableWifiLock: true,
  );

  try {
    final initialized = await FlutterBackground.initialize(
      androidConfig: androidConfig,
    );
    if (initialized) {
      await FlutterBackground.enableBackgroundExecution();
    }
  } catch (error, stack) {
    _logCrash('AndroidBackground', error, stack);
  }
}

Future<void> main() async {
  runZonedGuarded(
    () async {
      WidgetsFlutterBinding.ensureInitialized();

      FlutterError.onError = (details) {
        _logCrash('FlutterError', details.exception, details.stack);
        FlutterError.presentError(details);
      };

      PlatformDispatcher.instance.onError = (error, stack) {
        _logCrash('PlatformDispatcher', error, stack);
        return true;
      };

      if (pu.isWindows) {
        SystemTheme.fallbackColor = const Color(0xFF0078D4);
        try {
          await SystemTheme.accentColor.load();
        } catch (_) {}
      }

      // Load all data from disk BEFORE starting the UI.
      // This guarantees no widget ever sees empty/default values.
      final appController = AppController();
      await appController.ready;

      runApp(LifeOsSftpDriveApp(appController: appController));

      unawaited(_enableAndroidBackgroundExecution());
    },
    (error, stack) {
      _logCrash('runZonedGuarded', error, stack);
    },
  );
}
