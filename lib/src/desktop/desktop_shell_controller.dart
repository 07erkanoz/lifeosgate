import 'dart:async';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_acrylic/flutter_acrylic.dart' as acrylic;
import 'package:lifeos_sftp_drive/src/models/log_entry.dart';
import 'package:lifeos_sftp_drive/src/state/app_controller.dart';
import 'package:lifeos_sftp_drive/src/utils/platform_utils.dart' as pu;
// import 'package:tray_manager/tray_manager.dart'; // DISABLED: tray temporarily removed
import 'package:window_manager/window_manager.dart';

class DesktopShellController with /* TrayListener, */ WindowListener {
  DesktopShellController(this.appController);

  final AppController appController;
  // bool _allowClose = false; // DISABLED: tray minimize removed, close always exits
  bool? _lastLaunchAtStartup;
  bool? _lastLinuxRegisterAsTerminal;

  Future<void> start() async {
    if (!pu.isDesktop) {
      return;
    }

    await _initWindow();
  }

  Future<void> _initWindow() async {
    // --- Phase 1: initialize acrylic (effect applied later after window is ready) ---
    try {
      if (pu.isWindows) {
        await acrylic.Window.initialize();
      }
    } catch (_) {}

    // --- Phase 2: window_manager basic setup ---
    await windowManager.ensureInitialized();
    await windowManager.setTitle('LifeOS Gate');
    await windowManager.setMinimumSize(const Size(600, 400));
    await windowManager.setPreventClose(true);

    if (pu.isWindows) {
      try {
        await windowManager.setTitleBarStyle(
          TitleBarStyle.hidden,
          windowButtonVisibility: false,
        );
      } catch (_) {}
    }

    // --- Phase 3: restore geometry ---
    await appController.ready;

    final sw = appController.windowWidth;
    final sh = appController.windowHeight;
    final sx = appController.windowX;
    final sy = appController.windowY;
    if (!pu.isLinux) {
      if (sw != null && sh != null && sw >= 600 && sh >= 400) {
        await windowManager.setSize(Size(sw, sh));
        await Future.delayed(const Duration(milliseconds: 50));
        await windowManager.setSize(Size(sw, sh));
      }
      if (sx != null && sy != null) {
        await windowManager.setPosition(Offset(sx, sy));
      }
    }

    // --- Phase 4: apply effect, then show window ---
    // Window starts hidden (native auto-show disabled in flutter_window.cpp).
    // Apply all visual effects first so the user never sees a raw/default window.
    try {
      if (pu.isWindows) {
        // hideWindowControls also sets up the window for transparency (WS_EX_LAYERED).
        // Must be called before setEffect for mica/acrylic to work.
        await acrylic.Window.hideWindowControls();
        await _applyWindowEffect(appController.windowEffect);
      }
    } catch (_) {}

    // Now show the fully styled window
    await windowManager.show();
    await windowManager.focus();

    windowManager.addListener(this);
    appController.addListener(_onStateChanged);

    // --- Tray DISABLED ---
    // try {
    //   trayManager.addListener(this);
    //   await trayManager.setIcon(_resolveTrayIconPath());
    //   try { await trayManager.setToolTip('LifeOS Gate'); } catch (_) {}
    //   await _refreshTrayMenu();
    // } catch (_) {}
    _geometryPollTimer = Timer.periodic(
      const Duration(seconds: 3),
      (_) => _saveGeometrySilent(),
    );

    if (pu.isWindows || pu.isLinux) {
      unawaited(_syncStartupRegistryIfNeeded(force: true));
    }
  }

  Future<void> dispose() async {
    if (!pu.isDesktop) {
      return;
    }
    appController.removeListener(_onStateChanged);
    // trayManager.removeListener(this); // DISABLED
    windowManager.removeListener(this);
    // if (_ready) {
    //   await trayManager.destroy();
    // }
  }

  // --- Tray menu DISABLED ---
  // Future<void> _refreshTrayMenu() async { ... }

  void _onStateChanged() {
    // Re-apply window effect when theme changes (dark ↔ light)
    if (pu.isWindows) {
      unawaited(_applyWindowEffect(appController.windowEffect));
    }
    if (pu.isWindows || pu.isLinux) {
      unawaited(_syncStartupRegistryIfNeeded());
    }
  }

  Future<void> _syncStartupRegistryIfNeeded({bool force = false}) async {
    final nextLaunchAtStartup = appController.launchAtStartup;
    final nextLinuxRegisterAsTerminal = pu.isLinux
        ? appController.linuxRegisterAsTerminal
        : false;
    final unchanged =
        _lastLaunchAtStartup == nextLaunchAtStartup &&
        (!pu.isLinux ||
            _lastLinuxRegisterAsTerminal == nextLinuxRegisterAsTerminal);
    if (!force && unchanged) {
      return;
    }
    _lastLaunchAtStartup = nextLaunchAtStartup;
    if (pu.isLinux) {
      _lastLinuxRegisterAsTerminal = nextLinuxRegisterAsTerminal;
    }
    await _updateStartupRegistry();
  }

  Future<void> _updateStartupRegistry() async {
    try {
      final exePath = Platform.resolvedExecutable;
      if (pu.isWindows) {
        if (appController.launchAtStartup) {
          await Process.run('reg', [
            'add',
            r'HKCU\Software\Microsoft\Windows\CurrentVersion\Run',
            '/v',
            'LifeOSSFTP',
            '/t',
            'REG_SZ',
            '/d',
            '"$exePath"',
            '/f',
          ]);
        } else {
          await Process.run('reg', [
            'delete',
            r'HKCU\Software\Microsoft\Windows\CurrentVersion\Run',
            '/v',
            'LifeOSSFTP',
            '/f',
          ]);
        }
      } else if (pu.isLinux) {
        final home = Platform.environment['HOME'] ?? '/tmp';
        final autostartDir = '$home/.config/autostart';
        final appsDir = '$home/.local/share/applications';
        final desktopFile = '$autostartDir/LifeOS Gate.desktop';
        final legacyDesktopFile = '$autostartDir/lifeos-sftp.desktop';
        final terminalDesktopFile = '$appsDir/lifeos-gate-terminal.desktop';
        final iconValue = _resolveLinuxLauncherIconValue(exePath);
        final execValue = _escapeDesktopExecArg(exePath);
        if (appController.launchAtStartup) {
          await Directory(autostartDir).create(recursive: true);
          // Clean up legacy launcher name.
          final legacy = File(legacyDesktopFile);
          if (await legacy.exists()) await legacy.delete();
          final desktopContent =
              '[Desktop Entry]\n'
              'Type=Application\n'
              'Name=LifeOS Gate\n'
              'Comment=SSH/SFTP Client\n'
              'Exec=$execValue\n'
              'Icon=$iconValue\n'
              'Terminal=false\n'
              'Categories=Network;RemoteAccess;\n'
              'StartupNotify=true\n';
          await _writeTextFileAtomicIfChanged(desktopFile, desktopContent);
        } else {
          final f = File(desktopFile);
          if (await f.exists()) await f.delete();
          final legacy = File(legacyDesktopFile);
          if (await legacy.exists()) await legacy.delete();
        }

        if (appController.linuxRegisterAsTerminal) {
          await Directory(appsDir).create(recursive: true);
          final terminalDesktopContent =
              '[Desktop Entry]\n'
              'Type=Application\n'
              'Name=LifeOS Gate Terminal\n'
              'Comment=LifeOS Gate Terminal Emulator\n'
              'Exec=$execValue\n'
              'Icon=$iconValue\n'
              'Terminal=false\n'
              'StartupNotify=true\n'
              'Categories=System;Utility;TerminalEmulator;\n'
              'Keywords=Terminal;Console;SSH;SFTP;\n'
              'StartupWMClass=com.example.lifeos_sftp_drive\n';
          await _writeTextFileAtomicIfChanged(
            terminalDesktopFile,
            terminalDesktopContent,
          );
        } else {
          final terminalDesktop = File(terminalDesktopFile);
          if (await terminalDesktop.exists()) await terminalDesktop.delete();
        }
      }
    } catch (_) {}
  }

  String _resolveLinuxLauncherIconValue(String exePath) {
    final sep = Platform.pathSeparator;
    final exeDir = File(exePath).parent.path;
    final candidates = <String>[
      '$exeDir${sep}data${sep}flutter_assets${sep}assets${sep}tray_icon.png',
      '$exeDir${sep}data${sep}flutter_assets${sep}assets${sep}tray_icon.ico',
    ];
    for (final path in candidates) {
      if (File(path).existsSync()) {
        return path;
      }
    }
    return 'application-default-icon';
  }

  String _escapeDesktopExecArg(String value) {
    final escaped = value.replaceAll(r'\', r'\\').replaceAll('"', r'\"');
    return '"$escaped"';
  }

  Future<void> _writeTextFileAtomicIfChanged(String path, String content) async {
    final target = File(path);
    try {
      if (await target.exists()) {
        final current = await target.readAsString();
        if (current == content) {
          return;
        }
      }
    } catch (_) {
      // Ignore read errors and continue with write.
    }

    await Directory(target.parent.path).create(recursive: true);
    final tmpPath = '$path.tmp.${DateTime.now().microsecondsSinceEpoch}';
    final tmp = File(tmpPath);
    try {
      await tmp.writeAsString(content, flush: true);
      if (await target.exists()) {
        await target.delete();
      }
      await tmp.rename(path);
    } catch (_) {
      try {
        await target.writeAsString(content, flush: true);
      } catch (_) {}
      if (await tmp.exists()) {
        await tmp.delete();
      }
    }
  }

  // --- Tray event handlers DISABLED ---
  // @override
  // void onTrayIconMouseDown() { ... }
  // @override
  // void onTrayIconRightMouseDown() { ... }
  // @override
  // void onTrayMenuItemClick(MenuItem menuItem) { ... }

  Future<void> _applyWindowEffect(String effect) async {
    try {
      if (pu.isWindows) {
        final isDark = appController.isDarkMode;
        switch (effect) {
          case 'mica':
            await acrylic.Window.setEffect(
              effect: acrylic.WindowEffect.mica,
              dark: isDark,
            );
            break;
          case 'acrylic':
            await acrylic.Window.setEffect(
              effect: acrylic.WindowEffect.acrylic,
              dark: isDark,
              color: const Color(0x00000000),
            );
            break;
          case 'transparent':
            await acrylic.Window.setEffect(
              effect: acrylic.WindowEffect.transparent,
              dark: isDark,
            );
            break;
          case 'tabbed':
            await acrylic.Window.setEffect(
              effect: acrylic.WindowEffect.tabbed,
              dark: isDark,
            );
            break;
          default:
            await acrylic.Window.setEffect(
              effect: acrylic.WindowEffect.disabled,
              dark: isDark,
            );
        }
      }
    } catch (_) {}
  }

  Timer? _geometrySaveTimer;
  Timer? _geometryPollTimer;
  Size? _lastSize;
  Offset? _lastPos;

  Future<void> _saveGeometrySilent() async {
    try {
      // Don't save geometry while maximized/fullscreen — those are temporary
      // states and we want to restore the normal window size.
      final maximized = await windowManager.isMaximized();
      final fullScreen = await windowManager.isFullScreen();
      if (maximized || fullScreen) return;

      final size = await windowManager.getSize();
      final pos = await windowManager.getPosition();
      // Skip if size is unreasonable
      if (size.width < 100 || size.height < 100) return;
      if (size.width == _lastSize?.width &&
          size.height == _lastSize?.height &&
          pos.dx == _lastPos?.dx &&
          pos.dy == _lastPos?.dy) {
        return;
      }
      _lastSize = size;
      _lastPos = pos;
      appController.setWindowGeometry(
        width: size.width,
        height: size.height,
        x: pos.dx,
        y: pos.dy,
      );
    } catch (e) {
      appController.addLog('Geometry save error: $e', level: LogLevel.warning);
    }
  }

  void _saveGeometryDebounced() {
    _geometrySaveTimer?.cancel();
    _geometrySaveTimer = Timer(
      const Duration(milliseconds: 500),
      _saveGeometrySilent,
    );
  }

  @override
  void onWindowResized() => _saveGeometryDebounced();

  @override
  void onWindowMoved() => _saveGeometryDebounced();

  @override
  void onWindowClose() async {
    _geometryPollTimer?.cancel();
    await _saveGeometrySilent(); // save before exit
    // Tray disabled — always close directly
    exit(0);
  }
}
