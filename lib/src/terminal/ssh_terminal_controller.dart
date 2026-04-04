import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter/foundation.dart';
import 'package:lifeos_sftp_drive/src/i18n/app_strings.dart';
import 'package:lifeos_sftp_drive/src/models/connection_profile.dart';
import 'package:lifeos_sftp_drive/src/state/app_controller.dart';
import 'package:lifeos_sftp_drive/src/utils/terminal_timeline_text.dart';
import 'package:xterm/xterm.dart';

enum TmuxInstallChoice { allowInstall, denyInstall, skipOnce }

class TmuxInstallPrompt {
  const TmuxInstallPrompt({
    required this.hostKey,
    required this.profile,
    required this.distroName,
    required this.packageManager,
    required this.tmuxAlreadyInstalled,
  });

  final String hostKey;
  final ConnectionProfile profile;
  final String distroName;
  final String packageManager;
  final bool tmuxAlreadyInstalled;
}

class TmuxInstallPromptResult {
  const TmuxInstallPromptResult({
    required this.choice,
    this.rememberChoice = false,
  });

  final TmuxInstallChoice choice;
  final bool rememberChoice;
}

class TerminalSessionEvent {
  const TerminalSessionEvent({
    required this.timestamp,
    required this.type,
    required this.message,
    this.metadata,
  });

  final DateTime timestamp;
  final String type;
  final String message;
  final Map<String, dynamic>? metadata;

  Map<String, dynamic> toJson() => {
    'timestamp': timestamp.toIso8601String(),
    'type': type,
    'message': message,
    if (metadata != null) 'metadata': metadata,
  };
}

class SshTerminalController extends ChangeNotifier {
  SshTerminalController({
    required this.profile,
    required this.strings,
    this.appController,
    this.onTmuxInstallPrompt,
    this.onReconnectAttentionChanged,
  }) : terminal = Terminal(maxLines: 20000) {
    terminal.onOutput = (data) {
      _captureTypedCommandInput(data);
      final session = _session;
      if (session == null) {
        return;
      }
      session.write(Uint8List.fromList(utf8.encode(data)));
    };

    terminal.onResize = (width, height, pixelWidth, pixelHeight) {
      final session = _session;
      if (session == null) {
        return;
      }
      if (width <= 0 || height <= 0) {
        return;
      }
      session.resizeTerminal(width, height, pixelWidth, pixelHeight);
    };

    terminal.onTitleChange = (value) {
      final next = value.trim();
      if (next.isEmpty) {
        return;
      }
      _title = next;
      notifyListeners();
    };
  }

  final ConnectionProfile profile;
  final AppStrings strings;
  final Terminal terminal;
  final AppController? appController;
  final Future<TmuxInstallPromptResult> Function(TmuxInstallPrompt prompt)?
  onTmuxInstallPrompt;
  final void Function(bool requiresAttention)? onReconnectAttentionChanged;

  SSHClient? _client;
  SSHSession? _session;
  StreamSubscription<String>? _stdoutSub;
  StreamSubscription<String>? _stderrSub;
  bool _connecting = false;
  bool _connected = false;
  bool _reconnecting = false;
  int _reconnectAttempt = 0;
  bool _disposed = false;
  bool _manualDisconnectRequested = false;
  String? _error;
  String _title = '';
  bool _insideTmux = false;
  String? _tmuxSessionName;
  String _tmuxNamedSession = 'main';
  Timer? _reconnectTimer;
  int _sessionToken = 0;
  final List<TerminalSessionEvent> _sessionEvents = [];
  final StreamController<String> _outputChunksController =
      StreamController<String>.broadcast();
  String _typedInputLine = '';
  bool _inInputEscapeSequence = false;
  bool _requiresReconnectAttention = false;

  bool get connecting => _connecting;
  bool get connected => _connected;
  bool get reconnecting => _reconnecting;
  int get reconnectAttempt => _reconnectAttempt;
  String? get error => _error;
  String get title => _title.isEmpty ? profile.name : _title;
  bool get insideTmux => _insideTmux;
  String? get tmuxSessionName => _tmuxSessionName;
  String get tmuxNamedSession => _tmuxNamedSession;
  List<TerminalSessionEvent> get sessionEvents =>
      List.unmodifiable(_sessionEvents);
  Stream<String> get outputChunks => _outputChunksController.stream;
  String tmuxSessionIdForNamedSession(String namedSession) =>
      _buildTmuxSessionName(namedSession);

  void switchTmuxNamedSession(String namedSession) {
    if (!_connected || !profile.tmuxEnabled) {
      return;
    }
    final normalized = namedSession.trim();
    if (normalized.isEmpty) {
      return;
    }

    final hostKey = _tmuxHostKey();
    final existing =
        appController?.getSshNamedSessionsForHost(hostKey) ?? const ['main'];
    if (!existing.contains(normalized)) {
      appController?.setSshNamedSessionsForHost(hostKey, [
        ...existing,
        normalized,
      ]);
    }
    appController?.setSshActiveSessionNameForHost(hostKey, normalized);

    final sessionId = _buildTmuxSessionName(normalized);
    final sessionQuoted = _shellQuote(sessionId);
    _tmuxNamedSession = normalized;
    _tmuxSessionName = sessionId;
    _insideTmux = true;

    sendCommand(
      'tmux has-session -t $sessionQuoted 2>/dev/null || tmux new-session -d -s $sessionQuoted',
      source: 'tmux_switch_prepare',
    );
    sendCommand(
      'tmux switch-client -t $sessionQuoted 2>/dev/null || tmux attach-session -t $sessionQuoted',
      source: 'tmux_switch',
    );
    _recordEvent(
      'tmux_switch',
      strings.isTr
          ? 'tmux oturumu degisti: $sessionId'
          : 'tmux session switched: $sessionId',
      metadata: {'namedSession': normalized, 'sessionId': sessionId},
    );
    notifyListeners();
  }

  void removeTmuxNamedSession(
    String namedSession, {
    String? fallbackNamedSession,
  }) {
    if (!_connected || !profile.tmuxEnabled) {
      return;
    }
    final target = namedSession.trim();
    if (target.isEmpty) {
      return;
    }

    final hostKey = _tmuxHostKey();
    final wasActiveInUi =
        appController?.getSshActiveSessionNameForHost(hostKey) == target;
    final currentSessions = [
      ...(appController?.getSshNamedSessionsForHost(hostKey) ?? const ['main']),
    ];
    final remaining = currentSessions.where((s) => s != target).toList();
    if (remaining.isEmpty) {
      remaining.add('main');
    }

    var nextSession = fallbackNamedSession?.trim() ?? '';
    if (nextSession.isEmpty || !remaining.contains(nextSession)) {
      nextSession = remaining.first;
    }

    appController?.setSshNamedSessionsForHost(hostKey, remaining);
    appController?.setSshActiveSessionNameForHost(hostKey, nextSession);

    final targetId = _buildTmuxSessionName(target);
    final targetQuoted = _shellQuote(targetId);

    final mustSwitchBeforeDelete = _tmuxNamedSession == target || wasActiveInUi;
    if (mustSwitchBeforeDelete) {
      final nextId = _buildTmuxSessionName(nextSession);
      final nextQuoted = _shellQuote(nextId);
      sendCommand(
        'tmux has-session -t $nextQuoted 2>/dev/null || tmux new-session -d -s $nextQuoted',
        source: 'tmux_delete_prepare',
      );
      sendCommand(
        'tmux switch-client -t $nextQuoted 2>/dev/null || tmux attach-session -t $nextQuoted',
        source: 'tmux_delete_switch',
      );
      _tmuxNamedSession = nextSession;
      _tmuxSessionName = nextId;
      _insideTmux = true;
    }

    sendCommand(
      'tmux kill-session -t $targetQuoted 2>/dev/null || true',
      source: 'tmux_delete',
    );
    _recordEvent(
      'tmux_delete',
      strings.isTr
          ? 'tmux oturumu silindi: $targetId'
          : 'tmux session deleted: $targetId',
      metadata: {'namedSession': target, 'sessionId': targetId},
    );
    notifyListeners();
  }

  Future<void> connect({bool reconnect = false}) async {
    if (_connecting || _connected || _disposed) {
      return;
    }

    if (!reconnect) {
      _stopReconnectLoop();
    }
    _connecting = true;
    _error = null;
    if (!reconnect) {
      _manualDisconnectRequested = false;
      _reconnecting = false;
      _reconnectAttempt = 0;
      terminal.buffer.clear();
      terminal.buffer.setCursor(0, 0);
      terminal.write('${strings.terminalStarting}\r\n');
    }
    _recordEvent(
      'connect_start',
      reconnect
          ? (strings.isTr ? 'Yeniden baglanti basladi' : 'Reconnect started')
          : (strings.isTr ? 'Baglanti basladi' : 'Connection started'),
      metadata: {'reconnect': reconnect},
    );
    notifyListeners();

    try {
      if (profile.password.trim().isEmpty &&
          (profile.privateKeyPath == null ||
              profile.privateKeyPath!.trim().isEmpty)) {
        throw _TerminalConnectionException(strings.missingCredentialsError);
      }

      final identities = await _loadIdentities();
      final client = SSHClient(
        await SSHSocket.connect(profile.host, profile.port),
        username: profile.username,
        identities: identities.isEmpty ? null : identities,
        onPasswordRequest: profile.password.trim().isEmpty
            ? null
            : () => profile.password,
      );

      final ptyWidth = terminal.viewWidth > 0 ? terminal.viewWidth : 80;
      final ptyHeight = terminal.viewHeight > 0 ? terminal.viewHeight : 24;

      final session = await client.shell(
        pty: SSHPtyConfig(
          type: 'xterm-256color',
          width: ptyWidth,
          height: ptyHeight,
        ),
      );

      _client = client;
      _session = session;
      _connected = true;
      _connecting = false;
      if (!reconnect) {
        terminal.buffer.clear();
        terminal.buffer.setCursor(0, 0);
      }

      _subscribeToSessionStreams(session);

      final token = ++_sessionToken;
      unawaited(session.done.whenComplete(() => _onSessionDone(token)));

      final shouldRunStartup = await _preparePersistentSession(client);

      notifyListeners();

      Future.delayed(const Duration(milliseconds: 300), () {
        final realW = terminal.viewWidth;
        final realH = terminal.viewHeight;
        if (_session != null &&
            realW > 0 &&
            realH > 0 &&
            (realW != ptyWidth || realH != ptyHeight)) {
          _session!.resizeTerminal(realW, realH);
        }
      });

      if (shouldRunStartup) {
        await _runStartupFlow();
      }

      _setReconnectAttentionRequired(false);
      _recordEvent(
        reconnect ? 'reconnect_connected' : 'connected',
        reconnect
            ? (strings.isTr ? 'Yeniden baglandi' : 'Reconnected')
            : (strings.isTr ? 'Baglandi' : 'Connected'),
        metadata: {
          'insideTmux': _insideTmux,
          if (_tmuxSessionName != null) 'tmuxSession': _tmuxSessionName,
        },
      );
    } on _TerminalConnectionException catch (error) {
      _error = error.message;
      terminal.write('\r\n${error.message}\r\n');
      _recordEvent('connect_error', error.message);
    } on SocketException catch (error) {
      final details = error.osError?.message ?? error.message;
      _error =
          '${strings.hostUnreachableError(profile.host, profile.port)} ($details)';
      terminal.write('\r\n$_error\r\n');
      _recordEvent('connect_error', _error!);
    } on SSHAuthFailError {
      _error = strings.authenticationFailedError(profile.name);
      terminal.write('\r\n$_error\r\n');
      _recordEvent('connect_error', _error!);
    } catch (error) {
      _error =
          '${strings.terminalConnectionFailed(profile.name)} ${error.toString()}';
      terminal.write('\r\n$_error\r\n');
      _recordEvent('connect_error', _error!);
    } finally {
      if (!_connected) {
        _insideTmux = false;
        _tmuxSessionName = null;
      }
      if (_connecting) {
        _connecting = false;
      }
      if (!_disposed) {
        notifyListeners();
      }
    }
  }

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
    terminal.textInput(payload);
    _recordEvent(
      'command',
      trimmed,
      metadata: {'source': source, 'insideTmux': _insideTmux},
    );
  }

  Future<void> disconnect({
    bool showMessage = false,
    bool manual = true,
  }) async {
    if (_disposed) {
      return;
    }

    _manualDisconnectRequested = manual;
    _stopReconnectLoop();
    _sessionToken++;

    await _closeActiveConnection(
      showMessage: showMessage,
      disconnectMessage: strings.terminalDisconnected(profile.name),
      closeClient: true,
    );

    _recordEvent(
      manual ? 'manual_disconnect' : 'disconnect',
      manual
          ? (strings.isTr
                ? 'Kullanici baglantiyi kapatti'
                : 'User disconnected')
          : (strings.isTr ? 'Baglanti sonlandi' : 'Connection terminated'),
    );
    _setReconnectAttentionRequired(false);
  }

  Future<void> disposeController() async {
    _disposed = true;
    _stopReconnectLoop();
    await disconnect(manual: true);
    await _outputChunksController.close();
    _setReconnectAttentionRequired(false);
  }

  Future<void> reconnectFromNotification({
    required bool resumeLastSession,
  }) async {
    if (_disposed) return;
    _manualDisconnectRequested = false;
    _stopReconnectLoop();
    _setReconnectAttentionRequired(false);

    if (_connecting) {
      return;
    }

    if (_connected) {
      await _closeActiveConnection(
        showMessage: false,
        closeClient: true,
        disconnectMessage: null,
      );
    }

    await connect(reconnect: resumeLastSession);
    if (!_connected) {
      _setReconnectAttentionRequired(true);
    }
  }

  Future<void> _onSessionDone(int token) async {
    if (_disposed || token != _sessionToken) {
      return;
    }

    final wasConnected = _connected;
    await _closeActiveConnection(
      showMessage: false,
      closeClient: true,
      disconnectMessage: null,
    );

    if (!wasConnected) {
      return;
    }

    _recordEvent(
      'session_closed',
      strings.isTr ? 'Uzak oturum kapandi' : 'Remote session closed',
    );

    if (_manualDisconnectRequested) {
      return;
    }

    _setReconnectAttentionRequired(true);

    final autoReconnect = appController?.sshAutoReconnect ?? true;
    if (!autoReconnect) {
      terminal.write('\r\n${strings.terminalDisconnected(profile.name)}\r\n');
      return;
    }

    _startReconnectLoop();
  }

  Future<void> _closeActiveConnection({
    required bool showMessage,
    required bool closeClient,
    required String? disconnectMessage,
  }) async {
    await _stdoutSub?.cancel();
    await _stderrSub?.cancel();
    _stdoutSub = null;
    _stderrSub = null;

    _session = null;

    if (closeClient) {
      _client?.close();
    }
    _client = null;

    final wasConnected = _connected;
    _connected = false;
    _connecting = false;
    _insideTmux = false;
    _tmuxSessionName = null;
    _resetTypedInputCapture();

    if (showMessage && wasConnected && disconnectMessage != null) {
      terminal.write('\r\n$disconnectMessage\r\n');
    }

    if (!_disposed) {
      notifyListeners();
    }
  }

  void _startReconnectLoop() {
    if (_disposed || _manualDisconnectRequested) {
      return;
    }
    if (_reconnecting) {
      return;
    }

    _reconnecting = true;
    _reconnectAttempt = 0;
    terminal.write(
      '\r\n${strings.isTr ? "Baglanti koptu. Yeniden baglaniliyor..." : "Connection lost. Reconnecting..."}\r\n',
    );
    _recordEvent(
      'reconnect_scheduled',
      strings.isTr ? 'Yeniden baglanti planlandi' : 'Reconnect scheduled',
    );
    notifyListeners();
    _scheduleReconnectAttempt(const Duration(seconds: 1));
  }

  void _stopReconnectLoop() {
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    _reconnecting = false;
    _reconnectAttempt = 0;
  }

  void _scheduleReconnectAttempt(Duration delay) {
    _reconnectTimer?.cancel();
    _reconnectTimer = Timer(delay, () {
      unawaited(_attemptReconnect());
    });
  }

  Future<void> _attemptReconnect() async {
    if (_disposed || _manualDisconnectRequested || !_reconnecting) {
      return;
    }

    final maxAttempts = appController?.sshReconnectMaxAttempts ?? 8;
    if (_reconnectAttempt >= maxAttempts) {
      _reconnecting = false;
      terminal.write(
        '\r\n${strings.isTr ? "Yeniden baglanti basarisiz." : "Reconnect failed."}\r\n',
      );
      _recordEvent(
        'reconnect_failed',
        strings.isTr
            ? 'Yeniden baglanti denemeleri tukenmis'
            : 'Reconnect attempts exhausted',
        metadata: {'attempts': _reconnectAttempt, 'max': maxAttempts},
      );
      notifyListeners();
      return;
    }

    _reconnectAttempt += 1;
    _recordEvent(
      'reconnect_attempt',
      strings.isTr
          ? 'Yeniden baglanti denemesi #$_reconnectAttempt'
          : 'Reconnect attempt #$_reconnectAttempt',
      metadata: {'attempt': _reconnectAttempt, 'max': maxAttempts},
    );
    notifyListeners();

    await connect(reconnect: true);

    if (_connected) {
      _reconnecting = false;
      _reconnectAttempt = 0;
      terminal.write(
        '\r\n${strings.isTr ? "Yeniden baglandi." : "Reconnected."}\r\n',
      );
      _setReconnectAttentionRequired(false);
      _recordEvent(
        'reconnect_success',
        strings.isTr ? 'Yeniden baglanti basarili' : 'Reconnect successful',
      );
      notifyListeners();
      return;
    }

    final delaySeconds = _nextBackoffSeconds(_reconnectAttempt);
    _scheduleReconnectAttempt(Duration(seconds: delaySeconds));
  }

  int _nextBackoffSeconds(int attempt) {
    final value = attempt <= 1 ? 2 : (1 << (attempt - 1));
    if (value < 2) return 2;
    if (value > 30) return 30;
    return value;
  }

  void _subscribeToSessionStreams(SSHSession session) {
    _stdoutSub = session.stdout
        .cast<List<int>>()
        .transform(const Utf8Decoder(allowMalformed: true))
        .listen((chunk) {
          if (!_outputChunksController.isClosed) {
            _outputChunksController.add(chunk);
          }
          terminal.write(chunk);
          _recordOutputChunk(chunk, stream: 'stdout');
        });
    _stderrSub = session.stderr
        .cast<List<int>>()
        .transform(const Utf8Decoder(allowMalformed: true))
        .listen((chunk) {
          if (!_outputChunksController.isClosed) {
            _outputChunksController.add(chunk);
          }
          terminal.write(chunk);
          _recordOutputChunk(chunk, stream: 'stderr');
        });
  }

  void _recordOutputChunk(String chunk, {required String stream}) {
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
    if (_mergeWithLastOutputEvent(
      limited,
      stream: stream,
      rawLength: clean.length,
    )) {
      return;
    }
    _recordEvent(
      'output',
      limited,
      metadata: {'stream': stream, 'length': clean.length},
    );
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
      TerminalSessionEvent(
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
        // ANSI sequence end byte range.
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
    _recordEvent(
      'command',
      command,
      metadata: {'source': 'terminal_input', 'insideTmux': _insideTmux},
    );
  }

  void _resetTypedInputCapture() {
    _typedInputLine = '';
    _inInputEscapeSequence = false;
  }

  bool _mergeWithLastOutputEvent(
    String nextChunk, {
    required String stream,
    required int rawLength,
  }) {
    if (_sessionEvents.isEmpty) {
      return false;
    }

    final last = _sessionEvents.last;
    final sameStream =
        last.type == 'output' && last.metadata?['stream'] == stream;
    if (!sameStream) {
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
    _sessionEvents[_sessionEvents.length - 1] = TerminalSessionEvent(
      timestamp: DateTime.now(),
      type: 'output',
      message: compact,
      metadata: {'stream': stream, 'length': previousLength + rawLength},
    );
    return true;
  }

  Future<void> _runStartupFlow() async {
    final startupDirectory = _normalizeStartupDirectory(profile.remotePath);
    final hasStartupDirectory = _shouldRunStartupCd(startupDirectory);
    final startupCommands = profile.startupCommands
        .map((cmd) => cmd.trim())
        .where((cmd) => cmd.isNotEmpty)
        .toList(growable: false);
    final hasStartupCommands = startupCommands.isNotEmpty;

    if (hasStartupDirectory || hasStartupCommands) {
      await Future.delayed(const Duration(milliseconds: 500));
    }

    if (hasStartupDirectory) {
      sendCommand(
        _buildStartupCdCommand(startupDirectory),
        source: 'startup_directory',
      );
      await Future.delayed(const Duration(milliseconds: 200));
    }

    if (hasStartupCommands) {
      for (final cmd in startupCommands) {
        sendCommand(cmd, source: 'startup_command');
        await Future.delayed(const Duration(milliseconds: 200));
      }
    }
  }

  Future<bool> _preparePersistentSession(SSHClient client) async {
    if (!profile.tmuxEnabled) {
      _insideTmux = false;
      _tmuxSessionName = null;
      _tmuxNamedSession = 'main';
      return true;
    }

    final mode = appController?.sshSessionMode ?? 'smart';
    if (mode == 'off') {
      return true;
    }

    final hostKey = _tmuxHostKey();
    var tmuxAvailable = await _hasTmux(client);
    var hostDecision = appController?.getTmuxHostDecision(hostKey) ?? 'unknown';

    if (mode == 'smart' && hostDecision == 'unknown') {
      if (onTmuxInstallPrompt == null) {
        return true;
      }
      final distro = await _detectDistroName(client);
      final pm = await _detectPackageManager(client);
      final result = await onTmuxInstallPrompt!(
        TmuxInstallPrompt(
          hostKey: hostKey,
          profile: profile,
          distroName: distro,
          packageManager: pm,
          tmuxAlreadyInstalled: tmuxAvailable,
        ),
      );
      if (result.choice == TmuxInstallChoice.allowInstall) {
        hostDecision = 'allowed';
        if (result.rememberChoice) {
          appController?.setTmuxHostDecision(hostKey, 'allowed');
        }
      } else if (result.choice == TmuxInstallChoice.denyInstall) {
        appController?.setTmuxHostDecision(hostKey, 'denied');
        return true;
      } else {
        appController?.setTmuxHostDecision(hostKey, 'denied');
        return true;
      }
    }

    if (hostDecision == 'denied') {
      return true;
    }

    var hasTmux = tmuxAvailable;

    if (!hasTmux) {
      if (hostDecision == 'allowed') {
        hasTmux = await _installTmux(client);
      } else {
        hasTmux = await _maybeInstallTmux(client);
      }
      if (!hasTmux) {
        terminal.write(
          '\r\n${strings.isTr ? "tmux bulunamadi, normal oturum ile devam ediliyor." : "tmux not available, continuing with regular session."}\r\n',
        );
        _recordEvent(
          'tmux_unavailable',
          strings.isTr
              ? 'tmux yok, normal oturum kullaniliyor'
              : 'tmux unavailable, regular session used',
        );
        return true;
      }
    }

    final namedSession =
        appController?.getSshActiveSessionNameForHost(hostKey) ?? 'main';
    _tmuxNamedSession = namedSession;
    final sessionName = await _resolveTmuxSessionName(client, namedSession);
    final sessionQuoted = _shellQuote(sessionName);
    final hasExistingSession = await _hasTmuxSession(client, sessionName);

    if (hasExistingSession) {
      await _configureTmuxSession(client, sessionQuoted);
      sendCommand(
        'tmux attach-session -t $sessionQuoted',
        source: 'tmux_attach',
      );
      _insideTmux = true;
      _tmuxSessionName = sessionName;
      _recordEvent(
        'tmux_attach',
        strings.isTr
            ? 'Mevcut tmux oturumuna baglanildi: $sessionName'
            : 'Attached to existing tmux session: $sessionName',
      );
      await Future.delayed(const Duration(milliseconds: 250));
      return false;
    }

    await _runCommandText(
      client,
      'tmux new-session -d -s $sessionQuoted',
      timeout: const Duration(seconds: 20),
    );
    await _configureTmuxSession(client, sessionQuoted);
    sendCommand('tmux attach-session -t $sessionQuoted', source: 'tmux_new');
    _insideTmux = true;
    _tmuxSessionName = sessionName;
    _recordEvent(
      'tmux_new',
      strings.isTr
          ? 'Yeni tmux oturumu olusturuldu: $sessionName'
          : 'Created new tmux session: $sessionName',
    );
    await Future.delayed(const Duration(milliseconds: 250));
    return true;
  }

  Future<bool> _maybeInstallTmux(SSHClient client) async {
    final policy = appController?.sshTmuxInstallPolicy ?? 'ask_once';
    if (policy != 'auto_if_possible') {
      return false;
    }

    final installed = await _installTmux(client);
    if (!installed) {
      _recordEvent(
        'tmux_install_failed',
        strings.isTr ? 'tmux kurulumu basarisiz' : 'tmux installation failed',
      );
    }
    return installed;
  }

  Future<void> _configureTmuxSession(
    SSHClient client,
    String sessionQuoted,
  ) async {
    // Keep tmux session visually close to native terminal experience.
    await _runCommandText(
      client,
      'tmux set-option -t $sessionQuoted status off >/dev/null 2>&1 || true',
    );
    await _runCommandText(
      client,
      'tmux set-option -t $sessionQuoted set-titles off >/dev/null 2>&1 || true',
    );
  }

  Future<bool> _installTmux(SSHClient client) async {
    final packageManager = await _detectPackageManager(client);
    if (packageManager == 'unknown') {
      terminal.write(
        '\r\n${strings.isTr ? "Paket yoneticisi bulunamadi, tmux kurulumu atlaniyor." : "No package manager found, skipping tmux installation."}\r\n',
      );
      return false;
    }

    final isRoot = (await _runCommandText(client, 'id -u')).trim() == '0';
    final canSudo =
        (await _runCommandText(
          client,
          'sudo -n true >/dev/null 2>&1 && echo yes || echo no',
        )).trim().toLowerCase() ==
        'yes';

    if (!isRoot && !canSudo) {
      terminal.write(
        '\r\n${strings.isTr ? "tmux kurmak icin sudo yetkisi gerekiyor." : "sudo access is required to install tmux."}\r\n',
      );
      return false;
    }

    final prefix = isRoot ? '' : 'sudo -n ';
    final command = switch (packageManager) {
      'apt-get' => '${prefix}apt-get install -y tmux',
      'dnf' => '${prefix}dnf install -y tmux',
      'yum' => '${prefix}yum install -y tmux',
      'pacman' => '${prefix}pacman -Sy --noconfirm tmux',
      'zypper' => '${prefix}zypper --non-interactive install tmux',
      'apk' => '${prefix}apk add tmux',
      _ => '',
    };

    if (command.isEmpty) {
      return false;
    }

    terminal.write(
      '\r\n${strings.isTr ? "tmux kuruluyor..." : "Installing tmux..."}\r\n',
    );
    _recordEvent(
      'tmux_install_start',
      strings.isTr ? 'tmux kurulumu basladi' : 'tmux installation started',
      metadata: {'packageManager': packageManager},
    );

    await _runCommandText(client, command, timeout: const Duration(minutes: 2));
    final installed = await _hasTmux(client);
    if (installed) {
      terminal.write(
        '\r\n${strings.isTr ? "tmux kuruldu." : "tmux installed."}\r\n',
      );
      _recordEvent(
        'tmux_install_success',
        strings.isTr ? 'tmux kuruldu' : 'tmux installed',
        metadata: {'packageManager': packageManager},
      );
    }
    return installed;
  }

  Future<bool> _hasTmux(SSHClient client) async {
    final result = await _runCommandText(
      client,
      'command -v tmux >/dev/null 2>&1 && echo yes || echo no',
    );
    return result.trim().toLowerCase() == 'yes';
  }

  Future<bool> _hasTmuxSession(SSHClient client, String sessionName) async {
    final sessionQuoted = _shellQuote(sessionName);
    final result = await _runCommandText(
      client,
      'tmux has-session -t $sessionQuoted >/dev/null 2>&1 && echo yes || echo no',
    );
    return result.trim().toLowerCase() == 'yes';
  }

  Future<String> _resolveTmuxSessionName(
    SSHClient client,
    String namedSession,
  ) async {
    final preferred = _buildTmuxSessionName(namedSession);
    if (await _hasTmuxSession(client, preferred)) {
      return preferred;
    }

    final legacy = _buildLegacyTmuxSessionName(namedSession);
    if (legacy != preferred && await _hasTmuxSession(client, legacy)) {
      return legacy;
    }

    if (namedSession.trim().toLowerCase() == 'main') {
      final legacyHostOnly = _buildLegacyHostOnlyTmuxSessionName();
      if (await _hasTmuxSession(client, legacyHostOnly)) {
        return legacyHostOnly;
      }
    }

    return preferred;
  }

  Future<String> _detectPackageManager(SSHClient client) async {
    const managers = ['apt-get', 'dnf', 'yum', 'pacman', 'zypper', 'apk'];
    for (final manager in managers) {
      final result = await _runCommandText(
        client,
        'command -v $manager >/dev/null 2>&1 && echo yes || echo no',
      );
      if (result.trim().toLowerCase() == 'yes') {
        return manager;
      }
    }
    return 'unknown';
  }

  Future<String> _detectDistroName(SSHClient client) async {
    final distro = await _runCommandText(
      client,
      'cat /etc/os-release 2>/dev/null | grep PRETTY_NAME | cut -d" -f2',
    );
    if (distro.trim().isNotEmpty) {
      return distro.trim();
    }
    final uname = await _runCommandText(client, 'uname -srm');
    return uname.trim();
  }

  Future<String> _runCommandText(
    SSHClient client,
    String command, {
    Duration timeout = const Duration(seconds: 10),
  }) async {
    try {
      final result = await client.run(command).timeout(timeout);
      return utf8.decode(result, allowMalformed: true).trim();
    } catch (_) {
      return '';
    }
  }

  Future<List<SSHKeyPair>> _loadIdentities() async {
    final keyPath = profile.privateKeyPath?.trim();
    if (keyPath == null || keyPath.isEmpty) {
      return const [];
    }

    final file = File(keyPath);
    if (!await file.exists()) {
      throw _TerminalConnectionException(
        strings.privateKeyNotFoundError(keyPath),
      );
    }

    try {
      return SSHKeyPair.fromPem(await file.readAsString());
    } catch (_) {
      throw _TerminalConnectionException(strings.invalidPrivateKeyError);
    }
  }

  String _buildStartupCdCommand(String path) {
    if (path == '~' || path.startsWith('~/')) {
      return 'cd -- $path';
    }

    final escaped = path.replaceAll("'", "'\"'\"'");
    return "cd -- '$escaped'";
  }

  String _normalizeStartupDirectory(String path) => path.trim();

  bool _shouldRunStartupCd(String path) {
    if (path.isEmpty) return false;
    if (path == '.' || path == './') return false;
    return true;
  }

  String _shellQuote(String input) {
    final escaped = input.replaceAll("'", "'\"'\"'");
    return "'$escaped'";
  }

  String _buildTmuxSessionName(String namedSession) {
    final hostToken = _normalizeTmuxToken(
      '${profile.username}_${profile.host}_${profile.port}',
    );
    final namedToken = _normalizeTmuxToken(namedSession);
    final raw = 'lifeos_${hostToken}_$namedToken';
    if (raw.length <= 72) {
      return raw;
    }

    final hostShort = hostToken.length > 20
        ? hostToken.substring(0, 20)
        : hostToken;
    final namedShort = namedToken.length > 16
        ? namedToken.substring(0, 16)
        : namedToken;
    final hash = _stableHash('$hostToken:$namedToken');
    return 'lifeos_${hostShort}_${namedShort}_${hash.substring(0, 8)}';
  }

  String _buildLegacyTmuxSessionName(String namedSession) {
    final raw =
        'lifeos_${profile.username}_${profile.host}_${profile.port}_${namedSession.trim()}';
    final normalized = raw.toLowerCase().replaceAll(RegExp(r'[^a-z0-9_]'), '_');
    final collapsed = normalized.replaceAll(RegExp(r'_+'), '_');
    if (collapsed.length <= 48) return collapsed;
    return collapsed.substring(0, 48);
  }

  String _buildLegacyHostOnlyTmuxSessionName() {
    final raw = 'lifeos_${profile.username}_${profile.host}_${profile.port}';
    final normalized = raw.toLowerCase().replaceAll(RegExp(r'[^a-z0-9_]'), '_');
    final collapsed = normalized.replaceAll(RegExp(r'_+'), '_');
    if (collapsed.length <= 48) return collapsed;
    return collapsed.substring(0, 48);
  }

  String _normalizeTmuxToken(String value) {
    final normalized = value
        .trim()
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9_]'), '_')
        .replaceAll(RegExp(r'_+'), '_');
    if (normalized.isEmpty) return 'main';
    return normalized;
  }

  String _stableHash(String value) {
    var hash = 0x811c9dc5;
    for (final byte in utf8.encode(value)) {
      hash ^= byte;
      hash = (hash * 0x01000193) & 0xffffffff;
    }
    return hash.toRadixString(16).padLeft(8, '0');
  }

  String _tmuxHostKey() =>
      '${profile.username}@${profile.host}:${profile.port}';

  void _setReconnectAttentionRequired(bool value) {
    if (_requiresReconnectAttention == value) {
      return;
    }
    _requiresReconnectAttention = value;
    onReconnectAttentionChanged?.call(value);
  }
}

class _TerminalConnectionException implements Exception {
  const _TerminalConnectionException(this.message);

  final String message;
}
