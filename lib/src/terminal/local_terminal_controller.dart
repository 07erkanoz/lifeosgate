import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_pty/flutter_pty.dart';
import 'package:lifeos_sftp_drive/src/state/app_controller.dart';
import 'package:lifeos_sftp_drive/src/utils/platform_utils.dart' as pu;
import 'package:lifeos_sftp_drive/src/utils/terminal_timeline_text.dart';
import 'package:xterm/xterm.dart';

class LocalTerminalSessionEvent {
  const LocalTerminalSessionEvent({
    required this.timestamp,
    required this.type,
    required this.message,
    this.metadata,
  });

  final DateTime timestamp;
  final String type;
  final String message;
  final Map<String, dynamic>? metadata;
}

/// Controller for a local terminal using a real PTY (pseudo-terminal).
///
/// Uses flutter_pty for ConPTY (Windows) / forkpty (Linux/macOS) support,
/// which enables proper TUI rendering (colors, cursor, box-drawing, resize).
class LocalTerminalController extends ChangeNotifier {
  LocalTerminalController({String? shellId, this.appController})
    : _shellId = shellId ?? 'auto',
      terminal = Terminal(maxLines: 20000) {
    terminal.onOutput = (data) {
      _captureTypedCommandInput(data);
      _pty?.write(utf8.encode(data));
    };
    terminal.onResize = (w, h, pw, ph) {
      if (w <= 0 || h <= 0) {
        return;
      }
      _pty?.resize(w, h);
    };
  }

  final String _shellId;
  final Terminal terminal;
  final AppController? appController;
  Pty? _pty;
  bool _running = false;
  bool _disposed = false;
  String? _error;
  final List<LocalTerminalSessionEvent> _sessionEvents = [];
  final StreamController<String> _outputChunksController =
      StreamController<String>.broadcast();
  String _typedInputLine = '';
  bool _inInputEscapeSequence = false;
  bool _exitHandled = false;

  late pu.ShellInfo _resolvedShell;

  bool get running => _running;
  String? get error => _error;
  List<LocalTerminalSessionEvent> get sessionEvents =>
      List.unmodifiable(_sessionEvents);
  Stream<String> get outputChunks => _outputChunksController.stream;

  /// Whether the active shell uses Unix commands (bash, zsh, wsl, git bash).
  bool get isUnixShell => _running ? _resolvedShell.isUnix : false;
  String get shellName => _running ? _resolvedShell.name : _shellId;

  void sendCommand(
    String command, {
    String source = 'ui',
    bool ensureTrailingNewLine = true,
  }) {
    final trimmed = command.trim();
    if (trimmed.isEmpty) {
      return;
    }
    final payload = ensureTrailingNewLine ? '$trimmed\n' : trimmed;
    if ((source == 'ai' || source == 'ai_agent') && isUnixShell) {
      // Prevent mixing with partially typed prompt text before AI command.
      terminal.textInput('\x15');
    }
    terminal.textInput(payload);
    _recordEvent('command', trimmed, metadata: {'source': source});
  }

  pu.ShellInfo _resolveShell() {
    final available = pu.detectAvailableShells();
    if (_shellId != 'auto') {
      final match = available.where((s) => s.id == _shellId);
      if (match.isNotEmpty) return match.first;
    }
    // auto: first available shell
    return available.isNotEmpty
        ? available.first
        : pu.ShellInfo('cmd', 'cmd', 'cmd.exe');
  }

  Future<void> start() async {
    if (_running || _disposed) return;
    if (pu.isMobile) {
      _error =
          'Local terminal is not available on mobile. Use SSH terminal instead.';
      terminal.write(
        '\r\nLocal terminal is not available on this platform.\r\nUse SSH terminal to connect to a server.\r\n',
      );
      _recordEvent(
        'start_error',
        'Local terminal unavailable on this platform',
      );
      notifyListeners();
      return;
    }

    _resolvedShell = _resolveShell();
    _error = null;
    terminal.write('Starting ${_resolvedShell.name}...\r\n');
    notifyListeners();

    try {
      _exitHandled = false;
      final workDir =
          Platform.environment['HOME'] ??
          Platform.environment['USERPROFILE'] ??
          '.';
      final shellPath = _resolvedShell.path;
      final columns = terminal.viewWidth > 0 ? terminal.viewWidth : 80;
      final rows = terminal.viewHeight > 0 ? terminal.viewHeight : 24;

      final env = Map<String, String>.from(Platform.environment);
      env['TERM'] = 'xterm-256color';

      final List<String> args;
      if (_resolvedShell.id == 'wsl') {
        args = ['--', 'bash', '--login'];
      } else if (_resolvedShell.id == 'gitbash') {
        args = ['--login', '-i'];
      } else if (pu.isWindows &&
          (shellPath.contains('powershell') || shellPath.contains('pwsh'))) {
        args = ['-NoLogo', '-NoExit'];
      } else {
        args = [];
      }

      final pty = Pty.start(
        shellPath,
        arguments: args,
        environment: env,
        workingDirectory: workDir,
        columns: columns,
        rows: rows,
      );

      _pty = pty;
      _running = true;
      terminal.buffer.clear();
      terminal.buffer.setCursor(0, 0);
      _recordEvent(
        'start',
        'Started ${_resolvedShell.name}',
        metadata: {'shell': _resolvedShell.id, 'workDir': workDir},
      );
      notifyListeners();

      pty.output
          .cast<List<int>>()
          .transform(const Utf8Decoder(allowMalformed: true))
          .listen((chunk) {
            if (!_outputChunksController.isClosed) {
              _outputChunksController.add(chunk);
            }
            terminal.write(chunk);
            _recordOutputChunk(chunk);
          }, onDone: () => _onProcessExit());

      pty.exitCode.then((_) => _onProcessExit());
    } catch (e) {
      _error = e.toString();
      terminal.write('\r\nError: $_error\r\n');
      _recordEvent('start_error', _error ?? 'unknown');
      _running = false;
      notifyListeners();
    }
  }

  /// Send a control signal (e.g. '\x03' for Ctrl+C) directly to the PTY.
  void sendSignal(String signal) {
    _pty?.write(utf8.encode(signal));
  }

  void _onProcessExit() {
    if (_disposed) return;
    if (_exitHandled) return;
    _exitHandled = true;
    _running = false;
    _pty = null;
    terminal.write('\r\nProcess exited.\r\n');
    _recordEvent('process_exit', 'Process exited');
    notifyListeners();
  }

  Future<void> stop() async {
    _recordEvent('stop', 'Stop requested');
    _resetTypedInputCapture();
    _pty?.kill();
    _pty = null;
    _running = false;
    if (!_disposed) notifyListeners();
  }

  Future<void> disposeController() async {
    _disposed = true;
    await stop();
    await _outputChunksController.close();
  }

  void _recordOutputChunk(String chunk) {
    if (!(appController?.sshTimeMachineEnabled ?? true)) {
      return;
    }
    final clean = TerminalTimelineText.sanitizeOutput(chunk);
    if (clean.trim().isEmpty) {
      return;
    }
    final limited = clean.length > 1200
        ? '${clean.substring(0, 1200)}...'
        : clean;
    if (_mergeWithLastOutputEvent(limited, rawLength: clean.length)) {
      return;
    }
    _recordEvent('output', limited, metadata: {'length': clean.length});
  }

  void _recordEvent(
    String type,
    String message, {
    Map<String, dynamic>? metadata,
  }) {
    if (!(appController?.sshTimeMachineEnabled ?? true)) {
      return;
    }
    final cleanMessage = type == 'command'
        ? TerminalTimelineText.sanitizeCommand(message)
        : TerminalTimelineText.sanitizeMessage(message);
    if (cleanMessage.isEmpty) {
      return;
    }

    final now = DateTime.now();
    if (_sessionEvents.isNotEmpty) {
      final last = _sessionEvents.last;
      final isRecentDuplicate =
          last.type == type &&
          last.message == cleanMessage &&
          now.difference(last.timestamp).inMilliseconds < 300;
      if (isRecentDuplicate) {
        return;
      }
    }

    _sessionEvents.add(
      LocalTerminalSessionEvent(
        timestamp: now,
        type: type,
        message: cleanMessage,
        metadata: metadata,
      ),
    );
    final maxEvents = appController?.sshTimeMachineMaxEvents ?? 4000;
    final overflow = _sessionEvents.length - maxEvents;
    if (overflow > 0) {
      _sessionEvents.removeRange(0, overflow);
    }
  }

  void _captureTypedCommandInput(String data) {
    if (!(appController?.sshTimeMachineEnabled ?? true) || data.isEmpty) {
      return;
    }

    for (final code in data.codeUnits) {
      if (_inInputEscapeSequence) {
        if (code >= 0x40 && code <= 0x7E) {
          _inInputEscapeSequence = false;
        }
        continue;
      }

      if (code == 0x1B) {
        _inInputEscapeSequence = true;
        continue;
      }

      if (code == 0x0D || code == 0x0A) {
        _flushTypedCommandLine();
        continue;
      }

      if (code == 0x08 || code == 0x7F) {
        if (_typedInputLine.isNotEmpty) {
          _typedInputLine = _typedInputLine.substring(
            0,
            _typedInputLine.length - 1,
          );
        }
        continue;
      }

      if (code < 0x20 || code == 0x7F) {
        continue;
      }
      _typedInputLine += String.fromCharCode(code);
    }
  }

  void _flushTypedCommandLine() {
    final command = TerminalTimelineText.sanitizeCommand(_typedInputLine);
    _typedInputLine = '';
    if (command.isEmpty) {
      return;
    }
    _recordEvent('command', command, metadata: {'source': 'terminal_input'});
  }

  void _resetTypedInputCapture() {
    _typedInputLine = '';
    _inInputEscapeSequence = false;
  }

  bool _mergeWithLastOutputEvent(String nextChunk, {required int rawLength}) {
    if (_sessionEvents.isEmpty) {
      return false;
    }
    final last = _sessionEvents.last;
    if (last.type != 'output') {
      return false;
    }
    final recent =
        DateTime.now().difference(last.timestamp).inMilliseconds < 700;
    if (!recent) {
      return false;
    }

    final merged = '${last.message}\n$nextChunk';
    final compact = merged.length > 1200
        ? '...${merged.substring(merged.length - 1197)}'
        : merged;
    final previousLength = (last.metadata?['length'] as int?) ?? 0;
    _sessionEvents[_sessionEvents.length - 1] = LocalTerminalSessionEvent(
      timestamp: DateTime.now(),
      type: 'output',
      message: compact,
      metadata: {'length': previousLength + rawLength},
    );
    return true;
  }
}
