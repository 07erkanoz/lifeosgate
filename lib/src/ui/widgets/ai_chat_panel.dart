import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter/services.dart';
import 'package:lifeos_sftp_drive/src/ai/agent/ai_agent_engine.dart';
import 'package:lifeos_sftp_drive/src/ai/agent/ai_agent_models.dart';
import 'package:lifeos_sftp_drive/src/ai/session/ai_panel_session_store.dart';
import 'package:lifeos_sftp_drive/src/services/ai_service.dart';
import 'package:lifeos_sftp_drive/src/state/app_controller.dart';
import 'package:lifeos_sftp_drive/src/ui/theme_tokens.dart';
import 'package:lifeos_sftp_drive/src/utils/terminal_timeline_text.dart';
import 'package:speech_to_text/speech_to_text.dart';
import 'package:xterm/xterm.dart';

/// AI Chat Panel — slides up from bottom of terminal.
/// Agent loop runs only inside this panel and does not modify command bar flow.
class AiChatPanel extends StatefulWidget {
  const AiChatPanel({
    super.key,
    required this.appController,
    required this.terminal,
    required this.onExecuteCommand,
    this.onRunTrackedCommand,
    this.onInterruptCommand,
    this.shellName,
    this.osInfo,
    this.isRemote = false,
    this.scopeHost,
    this.scopeTmuxSession,
    this.scopeCwd,
  });

  final AppController appController;
  final Terminal terminal;
  final void Function(String command) onExecuteCommand;
  final Future<AiAgentCommandResult> Function(String command)?
  onRunTrackedCommand;
  final VoidCallback? onInterruptCommand;
  final String? shellName;
  final String? osInfo;
  final bool isRemote;
  final String? scopeHost;
  final String? scopeTmuxSession;
  final String? scopeCwd;

  @override
  State<AiChatPanel> createState() => AiChatPanelState();
}

class AiChatPanelState extends State<AiChatPanel> {
  static const bool _panelShortcutsEnabled = false;

  final _inputCtrl = TextEditingController();
  final _inputFocus = FocusNode();
  final _panelShortcutFocus = FocusNode();
  final _scrollCtrl = ScrollController();
  final List<_ChatMessage> _messages = [];
  final List<AiAgentStepRecord> _agentSteps = [];
  final AiAgentEngine _agentEngine = AiAgentEngine();
  final AiPanelSessionStore _runtimeStore = AiPanelSessionStore();
  final SpeechToText _speech = SpeechToText();
  final Set<String> _assistantMessageHashes = <String>{};
  final Set<String> _commandHashes = <String>{};
  final List<AiPanelStoredCommand> _runtimeCommands = [];

  bool _loading = false;
  bool _expanded = false;
  _ChatMode _mode = _ChatMode.chat;
  _AgentUiState _agentState = _AgentUiState.idle;
  String? _activeGoal;
  AiAgentAction? _pendingAction;
  AiPanelStoredSession? _runtimeSession;
  bool _runtimeSyncing = false;
  String _activeScopeKey = '';
  String _activeProviderId = '';
  String? _lastPendingQuestion;
  String? _approvedGoalKey;
  bool _awaitingPlanApproval = false;
  final List<String> _memoryNotes = [];
  Timer? _foregroundWatchTimer;
  bool _foregroundWatchBusy = false;

  bool _speechReady = false;
  bool _listening = false;
  String _voiceDraft = '';
  String _lastVoiceError = '';
  String? _cachedRemoteOsInfo;  // Cached SSH OS info from remote probe

  bool get _isTr =>
      widget.appController.locale.name.toLowerCase().startsWith('tr');
  bool get _voiceSupported => Platform.isAndroid || Platform.isIOS;

  /// Probe remote OS info via terminal and cache it.
  /// Returns detailed string like "Arch Linux (id=arch, pm=pacman)"
  Future<String> _getEffectiveOsInfo() async {
    if (!widget.isRemote) {
      return widget.osInfo ??
          '${Platform.operatingSystem} ${Platform.operatingSystemVersion}';
    }
    // Use cached value
    if (_cachedRemoteOsInfo != null) return _cachedRemoteOsInfo!;
    // Try to probe via terminal
    try {
      final cb = widget.onRunTrackedCommand;
      if (cb != null) {
        final result = await cb(
          'cat /etc/os-release 2>/dev/null | head -5 && echo "SHELL=\$SHELL" && which apt pacman dnf yum zypper 2>/dev/null | head -3',
        ).timeout(const Duration(seconds: 6));
        if (result.success && result.output.trim().isNotEmpty) {
          final output = result.output;
          final fields = <String, String>{};
          for (final line in output.split('\n')) {
            final idx = line.indexOf('=');
            if (idx > 0) {
              var key = line.substring(0, idx).trim();
              var val = line.substring(idx + 1).trim();
              if (val.startsWith('"') && val.endsWith('"')) {
                val = val.substring(1, val.length - 1);
              }
              fields[key] = val;
            }
          }
          final pretty = fields['PRETTY_NAME'] ?? fields['NAME'] ?? 'Linux';
          final id = fields['ID'] ?? '';
          final pm = output.contains('/pacman') ? 'pacman'
              : output.contains('/apt') ? 'apt'
              : output.contains('/dnf') ? 'dnf'
              : output.contains('/yum') ? 'yum'
              : output.contains('/zypper') ? 'zypper' : '';
          final shell = fields['SHELL'] ?? '';
          final parts = <String>[];
          if (id.isNotEmpty) parts.add('id=$id');
          if (pm.isNotEmpty) parts.add('pm=$pm');
          if (shell.isNotEmpty) parts.add('shell=$shell');
          _cachedRemoteOsInfo = parts.isEmpty
              ? 'Remote: $pretty'
              : 'Remote: $pretty (${parts.join(', ')})';
          return _cachedRemoteOsInfo!;
        }
      }
    } catch (_) {}
    _cachedRemoteOsInfo = widget.osInfo ?? 'Remote Linux server';
    return _cachedRemoteOsInfo!;
  }

  @override
  void initState() {
    super.initState();
    widget.appController.addListener(_onAppControllerChanged);
    unawaited(_initRuntimeSession());
    if (_voiceSupported) {
      _initSpeech();
    }
  }

  @override
  void didUpdateWidget(covariant AiChatPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.appController != widget.appController) {
      oldWidget.appController.removeListener(_onAppControllerChanged);
      widget.appController.addListener(_onAppControllerChanged);
      unawaited(_syncRuntimeSession(force: true));
      return;
    }
    if (oldWidget.scopeHost != widget.scopeHost ||
        oldWidget.scopeTmuxSession != widget.scopeTmuxSession ||
        oldWidget.scopeCwd != widget.scopeCwd ||
        oldWidget.isRemote != widget.isRemote ||
        oldWidget.shellName != widget.shellName) {
      unawaited(_syncRuntimeSession(force: true));
    }
  }

  @override
  void dispose() {
    widget.appController.removeListener(_onAppControllerChanged);
    unawaited(_persistRuntimeSession());
    _stopForegroundWatchAutomation();
    _speech.stop();
    _inputCtrl.dispose();
    _inputFocus.dispose();
    _panelShortcutFocus.dispose();
    _scrollCtrl.dispose();
    super.dispose();
  }

  void toggle() {
    setState(() => _expanded = !_expanded);
    if (!_expanded) {
      _panelShortcutFocus.unfocus();
    }
  }

  void show() {
    if (!_expanded) setState(() => _expanded = true);
  }

  void hide() {
    _panelShortcutFocus.unfocus();
    if (_expanded) setState(() => _expanded = false);
  }

  /// Called from terminal views to explain the last output.
  void explainLastOutput() {
    show();
    setState(() => _mode = _ChatMode.explain);
    _sendMessage(
      _isTr
          ? 'Son terminal çıktısını açıkla'
          : 'Explain the last terminal output',
    );
  }

  /// Called from terminal views to detect errors.
  void detectErrors() {
    show();
    setState(() => _mode = _ChatMode.explain);
    _sendMessage(
      _isTr
          ? 'Terminal çıktısında hata var mı? Varsa çözüm öner.'
          : 'Are there any errors in the terminal output? If so, suggest a fix.',
    );
  }

  AiAgentMode _currentAgentMode() {
    switch (_mode) {
      case _ChatMode.chat:
        return AiAgentMode.chat;
      case _ChatMode.explain:
        return AiAgentMode.explain;
      case _ChatMode.script:
        return AiAgentMode.script;
      case _ChatMode.agent:
        return AiAgentMode.agent;
    }
  }

  String _readRecentTerminalOutput({int maxLines = 40}) {
    final lines = widget.terminal.buffer.lines;
    if (lines.length == 0) {
      return '';
    }
    final start = lines.length > maxLines ? lines.length - maxLines : 0;
    final outputBuf = StringBuffer();
    for (int i = start; i < lines.length; i++) {
      outputBuf.writeln(lines[i].toString());
    }
    return AiService.sanitizeForApi(outputBuf.toString());
  }

  void _onAppControllerChanged() {
    final providerChanged =
        _activeProviderId != widget.appController.aiProvider;
    if (providerChanged) {
      unawaited(_syncRuntimeSession(force: true));
    }
  }

  Future<void> _initRuntimeSession() async {
    await _syncRuntimeSession(force: true);
  }

  Future<void> _syncRuntimeSession({bool force = false}) async {
    if (_runtimeSyncing) {
      return;
    }
    final scopeKey = _buildScopeKey();
    final providerId = widget.appController.aiProvider;
    if (!force &&
        scopeKey == _activeScopeKey &&
        providerId == _activeProviderId) {
      return;
    }

    _runtimeSyncing = true;
    try {
      await _persistRuntimeSession();
      final loaded = await _runtimeStore.loadScope(scopeKey);
      final session =
          loaded ??
          AiPanelStoredSession.initial(
            scopeKey: scopeKey,
            provider: providerId,
          );
      _applyRuntimeSession(session);
      _activeScopeKey = scopeKey;
      _activeProviderId = providerId;
    } finally {
      _runtimeSyncing = false;
    }
  }

  String _buildScopeKey() {
    final provider = widget.appController.aiProvider;
    if (widget.isRemote) {
      final host = (widget.scopeHost ?? _extractHostFromShellName()).trim();
      final normalizedHost = host.isEmpty ? 'unknown-host' : host;
      final tmux = (widget.scopeTmuxSession ?? 'main').trim();
      final normalizedTmux = tmux.isEmpty ? 'main' : tmux;
      return 'ssh:$normalizedHost:$normalizedTmux:$provider';
    }
    final cwd = _resolveLocalCwdScope();
    return 'local:$cwd:$provider';
  }

  String _extractHostFromShellName() {
    final shell = (widget.shellName ?? '').trim();
    if (shell.isEmpty) {
      return '';
    }
    final at = shell.lastIndexOf('@');
    if (at >= 0 && at < shell.length - 1) {
      return shell.substring(at + 1).trim();
    }
    return shell;
  }

  String _resolveLocalCwdScope() {
    final provided = (widget.scopeCwd ?? '').trim();
    if (provided.isNotEmpty) {
      return provided;
    }
    final detected = _detectCurrentDirectoryFromTerminal();
    if (detected.isNotEmpty) {
      return detected;
    }
    final envPwd = Platform.environment['PWD']?.trim() ?? '';
    if (envPwd.isNotEmpty) {
      return envPwd;
    }
    return '~';
  }

  String _detectCurrentDirectoryFromTerminal() {
    final raw = _readRecentTerminalOutput(maxLines: 80);
    if (raw.trim().isEmpty) {
      return '';
    }
    final lines = raw
        .split('\n')
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty)
        .toList(growable: false);
    for (int i = lines.length - 1; i >= 0; i--) {
      final line = lines[i];
      final ps = RegExp(r'^PS\s+(.+?)>\s*$').firstMatch(line);
      if (ps != null) {
        return ps.group(1)?.trim() ?? '';
      }
      final unixHost = RegExp(
        r'^[^@\s]+@[^:]+:([^#$]+)[#$]\s*$',
      ).firstMatch(line);
      if (unixHost != null) {
        return unixHost.group(1)?.trim() ?? '';
      }
      final unixSimple = RegExp(
        r'^([~./][^#$\s]*)\s*[#$]\s*$',
      ).firstMatch(line);
      if (unixSimple != null) {
        return unixSimple.group(1)?.trim() ?? '';
      }
      final winCmd = RegExp(r'^([A-Za-z]:\\[^>]*)>\s*$').firstMatch(line);
      if (winCmd != null) {
        return winCmd.group(1)?.trim() ?? '';
      }
    }
    return '';
  }

  void _applyRuntimeSession(AiPanelStoredSession session) {
    _runtimeSession = session;
    _messages
      ..clear()
      ..addAll(session.messages.map(_chatMessageFromStored));
    _runtimeCommands
      ..clear()
      ..addAll(session.recentCommands);
    _assistantMessageHashes
      ..clear()
      ..addAll(
        _messages
            .where((m) => m.role != _ChatRole.user)
            .map((m) => _messageHashForDedup(m)),
      );
    _commandHashes
      ..clear()
      ..addAll(session.recentCommands.map(_commandHash));
    _activeGoal = session.goal?.trim().isEmpty ?? true ? null : session.goal;
    _pendingAction = _actionFromMap(session.pendingAction);
    _lastPendingQuestion = session.pendingQuestion;
    _awaitingPlanApproval = false;
    _approvedGoalKey = null;
    _memoryNotes
      ..clear()
      ..addAll(session.memoryNotes);
    _agentSteps.clear();

    if (!mounted) {
      return;
    }
    setState(() {
      _agentState = session.awaitingAnswer || _pendingAction != null
          ? _AgentUiState.waiting
          : _AgentUiState.idle;
    });
    _scrollToBottom();
  }

  Future<void> _persistRuntimeSession() async {
    final session = _runtimeSession;
    if (session == null) {
      return;
    }

    final updated = session.copyWith(
      updatedAt: DateTime.now(),
      goal: _activeGoal,
      summary: _buildShortSummary(),
      memoryNotes: List<String>.from(_memoryNotes),
      awaitingAnswer: _agentState == _AgentUiState.waiting,
      pendingQuestion: _lastPendingQuestion,
      pendingAction: _actionToMap(_pendingAction),
      clearPendingAction: _pendingAction == null,
      clearPendingQuestion:
          (_lastPendingQuestion == null ||
          _lastPendingQuestion!.trim().isEmpty),
      messages: _messages.map(_storedMessageFromChat).toList(growable: false),
      recentCommands: List<AiPanelStoredCommand>.from(_runtimeCommands),
    );
    _runtimeSession = updated;
    await _runtimeStore.saveScope(updated);
  }

  Future<void> _clearCurrentConversation() async {
    _messages.clear();
    _agentSteps.clear();
    _runtimeCommands.clear();
    _assistantMessageHashes.clear();
    _commandHashes.clear();
    _pendingAction = null;
    _lastPendingQuestion = null;
    _activeGoal = null;
    _agentState = _AgentUiState.idle;
    _awaitingPlanApproval = false;
    _approvedGoalKey = null;
    _stopForegroundWatchAutomation();

    final session = _runtimeSession;
    if (session != null) {
      _runtimeSession = session.copyWith(
        updatedAt: DateTime.now(),
        messages: const [],
        recentCommands: const [],
        summary: '',
        awaitingAnswer: false,
        clearGoal: true,
        clearPendingAction: true,
        clearPendingQuestion: true,
      );
      await _persistRuntimeSession();
    }
  }

  String _buildShortSummary() {
    if (_messages.isEmpty) {
      return '';
    }
    final recent = _messages.length > 6
        ? _messages.sublist(_messages.length - 6)
        : _messages;
    final parts = <String>[];
    for (final m in recent) {
      final role = switch (m.role) {
        _ChatRole.user => _isTr ? 'Kullanıcı' : 'User',
        _ChatRole.assistant => 'Agent',
        _ChatRole.error => _isTr ? 'Hata' : 'Error',
      };
      final text = m.text.trim();
      if (text.isEmpty) continue;
      final compact = text.length > 120 ? '${text.substring(0, 120)}...' : text;
      parts.add('$role: $compact');
    }
    return parts.join('\n');
  }

  String _buildExecutionGoal({
    required String stage,
    required String latestUserMessage,
  }) {
    final followUp = stage == 'follow_up';
    final goal = (_activeGoal ?? latestUserMessage).trim();
    final summary = _buildShortSummary();
    final pending = _lastPendingQuestion?.trim() ?? '';
    final recent = _messages.length > 6
        ? _messages.sublist(_messages.length - 6)
        : _messages;
    final cmd = _runtimeCommands.isNotEmpty ? _runtimeCommands.last : null;

    final b = StringBuffer();
    b.writeln('session_stage: $stage');
    b.writeln('toolbelt_profile: ${widget.appController.aiToolbeltProfile}');
    b.writeln('watch_mode: ${widget.appController.aiWatchMode ? 'on' : 'off'}');
    b.writeln('goal: $goal');
    if (followUp && summary.isNotEmpty) {
      b.writeln('short_summary:');
      b.writeln(summary);
    }
    if (followUp && pending.isNotEmpty) {
      b.writeln('pending_question: $pending');
    }
    b.writeln('latest_user_message: $latestUserMessage');
    if (followUp && cmd != null) {
      b.writeln(
        'last_command: ${cmd.command} | exit=${cmd.exitCode ?? (cmd.success ? 0 : 1)} | success=${cmd.success}',
      );
      final output = cmd.output.trim();
      if (output.isNotEmpty) {
        final tail = output.length > 180
            ? output.substring(output.length - 180)
            : output;
        b.writeln('last_command_output_tail: $tail');
      }
    }
    if (followUp && recent.isNotEmpty) {
      b.writeln('recent_messages:');
      for (final m in recent) {
        final who = switch (m.role) {
          _ChatRole.user => 'user',
          _ChatRole.assistant => 'assistant',
          _ChatRole.error => 'error',
        };
        final text = m.text.trim();
        if (text.isEmpty) continue;
        final compact = text.length > 100
            ? '${text.substring(0, 100)}...'
            : text;
        b.writeln('- $who: $compact');
      }
    }
    if (_memoryNotes.isNotEmpty) {
      b.writeln('memory_notes:');
      for (final note in _memoryNotes.take(10)) {
        final clean = note.trim();
        if (clean.isEmpty) continue;
        final compact = clean.length > 180
            ? '${clean.substring(0, 180)}...'
            : clean;
        b.writeln('- $compact');
      }
    }
    return b.toString().trim();
  }

  void _rememberFromUserMessage(String userMsg) {
    final notes = _extractMemoryNotesFromUserText(userMsg);
    if (notes.isEmpty) {
      return;
    }
    final normalizedExisting = _memoryNotes
        .map((e) => _normalizeMemoryNote(e))
        .where((e) => e.isNotEmpty)
        .toSet();
    var changed = false;
    for (final note in notes) {
      final key = _normalizeMemoryNote(note);
      if (key.isEmpty || normalizedExisting.contains(key)) {
        continue;
      }
      normalizedExisting.add(key);
      _memoryNotes.add(note.trim());
      changed = true;
    }
    if (!changed) {
      return;
    }
    if (_memoryNotes.length > 24) {
      final drop = _memoryNotes.length - 24;
      _memoryNotes.removeRange(0, drop);
    }
    unawaited(_persistRuntimeSession());
  }

  String _normalizeMemoryNote(String text) {
    return text.toLowerCase().replaceAll(RegExp(r'\s+'), ' ').trim();
  }

  List<String> _extractMemoryNotesFromUserText(String text) {
    final clean = text.trim();
    if (clean.isEmpty) {
      return const [];
    }
    final lower = clean.toLowerCase();
    const cueWords = [
      'bundan sonra',
      'her zaman',
      'tercihim',
      'varsayılan',
      'default',
      'unutma',
      'şunu kullan',
      'sunu kullan',
      'always',
      'prefer',
      'remember',
      'from now on',
      'use this',
    ];
    if (!cueWords.any(lower.contains)) {
      return const [];
    }
    return [clean];
  }

  void _recordRuntimeCommand(AiAgentCommandResult result) {
    final snapshot = AiPanelStoredCommand(
      command: result.command.trim(),
      output: result.output.trim(),
      exitCode: result.exitCode,
      success: result.success,
      durationMs: result.durationMs,
      cwd: result.cwd,
      createdAt: DateTime.now(),
    );
    final hash = _commandHash(snapshot);
    if (_commandHashes.contains(hash)) {
      return;
    }
    _commandHashes.add(hash);
    _runtimeCommands.add(snapshot);
    if (_runtimeCommands.length > 80) {
      final extra = _runtimeCommands.length - 80;
      _runtimeCommands.removeRange(0, extra);
    }
  }

  String _commandHash(AiPanelStoredCommand command) {
    final base =
        '${command.command.trim()}|${command.exitCode ?? (command.success ? 0 : 1)}|${command.durationMs}|${command.output.trim()}';
    return _stableHash(base);
  }

  bool _appendMessage(
    _ChatMessage message, {
    String? eventId,
    bool persist = false,
  }) {
    if (message.role != _ChatRole.user) {
      final canonical = _messageHashForDedup(message);
      final eventHash = eventId == null ? null : 'evt:$eventId';
      if (_assistantMessageHashes.contains(canonical) ||
          (eventHash != null && _assistantMessageHashes.contains(eventHash))) {
        return false;
      }
      _assistantMessageHashes.add(canonical);
      if (eventHash != null) {
        _assistantMessageHashes.add(eventHash);
      }
    }
    _messages.add(message);
    if (persist) {
      unawaited(_persistRuntimeSession());
    }
    return true;
  }

  String _messageHashForDedup(_ChatMessage message) {
    final role = message.role.name;
    final text = message.text.trim();
    final command = message.command?.trim() ?? '';
    final script = message.scriptPath?.trim() ?? '';
    return _stableHash('$role|$text|$command|$script');
  }

  String _stableHash(String input) {
    var hash = 0x811C9DC5;
    for (final codeUnit in input.codeUnits) {
      hash ^= codeUnit;
      hash = (hash * 0x01000193) & 0xFFFFFFFF;
    }
    return hash.toRadixString(16).padLeft(8, '0');
  }

  String _newMessageId() => _newChatMessageId();

  String? _derivePendingQuestion(AiAgentRunResult result) {
    final pendingMsg = result.pendingAction?.message?.trim();
    if (pendingMsg != null && pendingMsg.isNotEmpty) {
      return pendingMsg;
    }
    final direct = result.message?.trim();
    if (direct != null && direct.isNotEmpty && direct.contains('?')) {
      return direct;
    }
    if (_messages.isEmpty) {
      return null;
    }
    for (int i = _messages.length - 1; i >= 0; i--) {
      final text = _messages[i].text.trim();
      if (text.isNotEmpty && text.contains('?')) {
        return text;
      }
    }
    return null;
  }

  String _normalizeAssistantText(String text) {
    final trimmed = text.trim();
    final looksActionJson =
        trimmed.startsWith('{') &&
        (trimmed.contains('"action"') || trimmed.contains("'action'"));
    if (!looksActionJson) {
      return text;
    }
    var normalized = trimmed
        .replaceAll('\u201c', '"')
        .replaceAll('\u201d', '"')
        .replaceAll('\u2018', "'")
        .replaceAll('\u2019', "'");
    normalized = normalized.replaceAll(RegExp(r',(\s*[}\]])'), r'$1');
    try {
      final decoded = jsonDecode(normalized);
      if (decoded is Map) {
        final message = decoded['message']?.toString().trim();
        if (message != null && message.isNotEmpty) {
          return message;
        }
        final command = decoded['command']?.toString().trim();
        if (command != null && command.isNotEmpty) {
          return _isTr ? 'Komut hazir: $command' : 'Command ready: $command';
        }
      }
    } catch (_) {
      // Keep original text if parsing fails.
    }
    return text;
  }

  AiPanelStoredMessage _storedMessageFromChat(_ChatMessage msg) {
    return AiPanelStoredMessage(
      id: msg.id,
      role: msg.role.name,
      text: msg.text,
      command: msg.command,
      scriptPath: msg.scriptPath,
      scriptContent: msg.scriptContent,
      stepNumber: msg.stepNumber,
      commandResult: msg.commandResult == null
          ? null
          : AiPanelStoredCommand(
              command: msg.commandResult!.command,
              output: msg.commandResult!.output,
              exitCode: msg.commandResult!.exitCode,
              success: msg.commandResult!.success,
              durationMs: msg.commandResult!.durationMs,
              cwd: msg.commandResult!.cwd,
              createdAt: msg.createdAt,
            ),
      createdAt: msg.createdAt,
    );
  }

  _ChatMessage _chatMessageFromStored(AiPanelStoredMessage msg) {
    final displayText = msg.role == 'assistant' || msg.role == 'error'
        ? _normalizeAssistantText(msg.text)
        : msg.text;
    return _ChatMessage(
      id: msg.id,
      role: _roleFromStored(msg.role),
      text: displayText,
      command: msg.command,
      scriptPath: msg.scriptPath,
      scriptContent: msg.scriptContent,
      stepNumber: msg.stepNumber,
      commandResult: msg.commandResult == null
          ? null
          : AiAgentCommandResult(
              command: msg.commandResult!.command,
              output: msg.commandResult!.output,
              exitCode: msg.commandResult!.exitCode,
              success: msg.commandResult!.success,
              durationMs: msg.commandResult!.durationMs,
              cwd: msg.commandResult!.cwd,
            ),
      createdAt: msg.createdAt,
    );
  }

  _ChatRole _roleFromStored(String role) {
    switch (role) {
      case 'user':
        return _ChatRole.user;
      case 'error':
        return _ChatRole.error;
      default:
        return _ChatRole.assistant;
    }
  }

  Map<String, dynamic>? _actionToMap(AiAgentAction? action) {
    if (action == null) {
      return null;
    }
    return {
      'type': action.type.name,
      if (action.message != null) 'message': action.message,
      if (action.command != null) 'command': action.command,
      if (action.scriptPath != null) 'scriptPath': action.scriptPath,
      if (action.scriptContent != null) 'scriptContent': action.scriptContent,
      if (action.scriptLanguage != null)
        'scriptLanguage': action.scriptLanguage,
      if (action.validationCommand != null)
        'validationCommand': action.validationCommand,
      'done': action.done,
      'requiresConfirmation': action.requiresConfirmation,
      if (action.reason != null) 'reason': action.reason,
      if (action.expectedSignal != null)
        'expectedSignal': action.expectedSignal,
    };
  }

  AiAgentAction? _actionFromMap(Map<String, dynamic>? map) {
    if (map == null || map.isEmpty) {
      return null;
    }
    final typeName = (map['type'] ?? '').toString();
    final type = AiAgentActionType.values.firstWhere(
      (e) => e.name == typeName,
      orElse: () => AiAgentActionType.askUser,
    );
    return AiAgentAction(
      type: type,
      message: map['message']?.toString(),
      command: map['command']?.toString(),
      scriptPath: map['scriptPath']?.toString(),
      scriptContent: map['scriptContent']?.toString(),
      scriptLanguage: map['scriptLanguage']?.toString(),
      validationCommand: map['validationCommand']?.toString(),
      done: map['done'] == true,
      requiresConfirmation: map['requiresConfirmation'] == true,
      reason: map['reason']?.toString(),
      expectedSignal: map['expectedSignal']?.toString(),
    );
  }

  Future<void> _sendMessage(String text) async {
    if (text.trim().isEmpty) {
      return;
    }
    await _syncRuntimeSession();
    final session = _runtimeSession;
    if (session == null) {
      return;
    }

    final userMsg = text.trim();
    _rememberFromUserMessage(userMsg);
    final continuationByHint = _looksLikeContinuationMessage(userMsg);
    final continuationByQuestion =
        _pendingAction != null || _agentState == _AgentUiState.waiting;
    final continuation = continuationByHint || continuationByQuestion;
    if (_loading && !(continuation && _pendingAction != null)) {
      return;
    }
    _inputCtrl.clear();

    final hasContext =
        (_activeGoal?.trim().isNotEmpty ?? false) && _messages.isNotEmpty;
    final reuseContext = continuation && hasContext;
    final hasServerSession = session.serverSessionId?.trim().isNotEmpty == true;
    final stage = reuseContext
        ? 'follow_up'
        : (hasServerSession ? 'resume' : 'start');

    setState(() {
      _appendMessage(
        _ChatMessage(
          id: _newMessageId(),
          role: _ChatRole.user,
          text: userMsg,
          createdAt: DateTime.now(),
        ),
      );
      if (!reuseContext) {
        _activeGoal = userMsg;
        _pendingAction = null;
        _lastPendingQuestion = null;
        _agentSteps.clear();
        _awaitingPlanApproval = false;
        _approvedGoalKey = null;
      } else {
        _activeGoal = _activeGoal?.trim().isNotEmpty == true
            ? _activeGoal
            : userMsg;
        _lastPendingQuestion = null;
      }
    });

    if (_awaitingPlanApproval) {
      if (_looksLikeRejectionMessage(userMsg)) {
        setState(() {
          _awaitingPlanApproval = false;
          _agentState = _AgentUiState.idle;
          _appendMessage(
            _ChatMessage(
              id: _newMessageId(),
              role: _ChatRole.assistant,
              text: _isTr
                  ? 'Tamam, planı iptal ettim. İstersen hedefi değiştirip tekrar başlatabilirim.'
                  : 'Okay, I cancelled the plan. I can restart with a new goal anytime.',
              createdAt: DateTime.now(),
            ),
            eventId: 'plan_cancelled',
            persist: true,
          );
        });
        _scrollToBottom();
        return;
      }
      _awaitingPlanApproval = false;
      _approvedGoalKey = _currentGoalApprovalKey();
    }

    final updatedSession = session.copyWith(
      updatedAt: DateTime.now(),
      goal: _activeGoal,
      awaitingAnswer: false,
      serverSessionId: session.serverSessionId ?? session.id,
      clearPendingQuestion: true,
      clearPendingAction: true,
    );
    _runtimeSession = updatedSession;
    await _persistRuntimeSession();
    _scrollToBottom();

    if (reuseContext && _pendingAction != null) {
      _agentEngine.resetStop();
      await _runAgentLoop(
        executePendingAction: true,
        stage: stage,
        latestUserMessage: userMsg,
      );
      return;
    }

    _agentEngine.resetStop();
    await _runAgentLoop(
      executePendingAction: false,
      stage: stage,
      latestUserMessage: userMsg,
    );
  }

  bool _looksLikeContinuationMessage(String text) {
    final lower = text.trim().toLowerCase();
    const words = {
      'evet',
      'tamam',
      'devam',
      'olur',
      'ok',
      'peki',
      'aynen',
      'yes',
      'okey',
      'continue',
      'go on',
      'proceed',
    };
    if (words.contains(lower)) {
      return true;
    }
    return false;
  }

  bool _looksLikeRejectionMessage(String text) {
    final lower = text.trim().toLowerCase();
    const words = {
      'hayır',
      'hayir',
      'iptal',
      'dur',
      'vazgeç',
      'vazgec',
      'no',
      'cancel',
      'stop',
      'abort',
    };
    return words.contains(lower);
  }

  String _currentGoalApprovalKey() {
    final goal = (_activeGoal ?? '').trim().toLowerCase();
    final mode = _mode.name;
    final scope = _activeScopeKey;
    return _stableHash('$scope|$mode|$goal');
  }

  Future<void> _runAgentLoop({
    required bool executePendingAction,
    required String stage,
    required String latestUserMessage,
  }) async {
    final goal = _activeGoal;
    if (goal == null || goal.trim().isEmpty) {
      return;
    }

    setState(() {
      _loading = true;
      _agentState = _AgentUiState.running;
    });

    try {
      final app = widget.appController;
      final cliAgentMode = _mode == _ChatMode.agent;
      if (app.aiApiKey.trim().isEmpty) {
        throw Exception(
          _isTr
              ? 'API anahtarı ayarlanmamış. Ayarlar > AI Asistan bölümünden ekleyin.'
              : 'API key is not configured. Add it from Settings > AI Assistant.',
        );
      }
      final provider = AiProvider.values.firstWhere(
        (p) => p.name == app.aiProvider,
        orElse: () => AiProvider.gemini,
      );
      final service = AiService(
        provider: provider,
        apiKey: app.aiApiKey,
        model: app.aiModel,
      );
      // Load conversation history for multi-turn support
      for (final msg in _messages) {
        if (msg.role == _ChatRole.user) {
          service.addToHistory('user', msg.text);
        } else if (msg.role == _ChatRole.assistant) {
          service.addToHistory('assistant', msg.text);
        }
      }

      final planGateNeeded =
          _currentAgentMode() == AiAgentMode.agent &&
          app.aiPlanApproval &&
          !executePendingAction &&
          !_awaitingPlanApproval &&
          _approvedGoalKey != _currentGoalApprovalKey();
      if (planGateNeeded) {
        final planned = await _preparePlanApproval(
          service: service,
          latestUserMessage: latestUserMessage,
        );
        if (planned) {
          if (!mounted) return;
          setState(() {
            _loading = false;
            _agentState = _AgentUiState.waiting;
          });
          await _persistRuntimeSession();
          _scrollToBottom();
          return;
        }
      }

      final previousCount = _agentSteps.length;
      late final AiAgentRunResult result;
      final executionGoal = _buildExecutionGoal(
        stage: stage,
        latestUserMessage: latestUserMessage,
      );
      try {
        result = await _agentEngine.run(
          service: service,
          mode: _currentAgentMode(),
          userGoal: executionGoal,
          previousSteps: _agentSteps,
          pendingAction: _pendingAction,
          executePendingAction: executePendingAction,
          policy: AiAgentPolicy(
            autoExecuteSafe: cliAgentMode ? true : app.aiAutoExecute,
            dangerConfirm: app.aiDangerConfirm,
            maxSteps: cliAgentMode ? 16 : 8,
            maxRuntime: cliAgentMode
                ? const Duration(minutes: 8)
                : const Duration(minutes: 5),
          ),
          executeCommand: _runTrackedCommand,
          executeScriptWrite: _writeScriptStep,
          readTerminalOutput: () => _readRecentTerminalOutput(maxLines: 30),
          shellName: widget.shellName ?? (widget.isRemote ? 'ssh' : 'local'),
          osInfo: await _getEffectiveOsInfo(),
          preferTurkish: _isTr,
          watchMode: app.aiWatchMode,
          toolbeltProfile: app.aiToolbeltProfile,
          memoryNotes: _memoryNotes,
        );
      } finally {
        service.dispose();
      }

      if (!mounted) return;

      _agentSteps
        ..clear()
        ..addAll(result.steps);

      _appendMessagesFromAgentSteps(previousCount, result.steps);

      if (result.stopped) {
        _stopForegroundWatchAutomation();
        _pendingAction = result.pendingAction;
        _agentState = _AgentUiState.paused;
        if (result.message != null && result.message!.trim().isNotEmpty) {
          _addAssistantMessageIfNotDuplicate(result.message!);
        }
      } else if (result.completed) {
        _stopForegroundWatchAutomation();
        _pendingAction = null;
        _lastPendingQuestion = null;
        _awaitingPlanApproval = false;
        _approvedGoalKey = _currentGoalApprovalKey();
        _agentState = _AgentUiState.done;
        if (result.message != null && result.message!.trim().isNotEmpty) {
          _addAssistantMessageIfNotDuplicate(result.message!);
        }
        final summaryReport = _buildCompletionReport(result);
        if (summaryReport != null && summaryReport.trim().isNotEmpty) {
          _addAssistantMessageIfNotDuplicate(summaryReport);
        }
      } else if (result.waitingUser) {
        _pendingAction = result.pendingAction;
        _lastPendingQuestion = _derivePendingQuestion(result);
        _agentState = _AgentUiState.waiting;
        if (_pendingAction == null &&
            result.message != null &&
            result.message!.trim().isNotEmpty) {
          _addAssistantMessageIfNotDuplicate(result.message!);
        }
      } else {
        _agentState = _AgentUiState.idle;
      }

      setState(() {
        _loading = false;
      });
      await _persistRuntimeSession();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _appendMessage(
          _ChatMessage(
            id: _newMessageId(),
            role: _ChatRole.error,
            text: e.toString(),
            createdAt: DateTime.now(),
          ),
          persist: true,
        );
        _loading = false;
        _agentState = _AgentUiState.paused;
      });
    }
    _scrollToBottom();
  }

  Future<bool> _preparePlanApproval({
    required AiService service,
    required String latestUserMessage,
  }) async {
    final goal = (_activeGoal ?? '').trim();
    if (goal.isEmpty) {
      return false;
    }
    final executionGoal = _buildExecutionGoal(
      stage: 'start',
      latestUserMessage: latestUserMessage,
    );
    final plan = await service.askAgentPlan(
      userGoal: executionGoal,
      mode: _currentAgentMode(),
      shellName: widget.shellName ?? (widget.isRemote ? 'ssh' : 'local'),
      osInfo: await _getEffectiveOsInfo(),
      lastOutput: _readRecentTerminalOutput(maxLines: 30),
      toolbeltProfile: widget.appController.aiToolbeltProfile,
      watchMode: widget.appController.aiWatchMode,
      memoryNotes: _memoryNotes,
    );
    final planText = _formatPlanText(plan);
    _awaitingPlanApproval = true;
    _lastPendingQuestion = _isTr
        ? 'Plan hazır. Devam edeyim mi?'
        : 'Plan is ready. Continue?';
    _appendMessage(
      _ChatMessage(
        id: _newMessageId(),
        role: _ChatRole.assistant,
        text: planText,
        createdAt: DateTime.now(),
      ),
      eventId: 'plan_gate:${_stableHash(planText)}',
      persist: true,
    );
    return true;
  }

  String _formatPlanText(AiAgentPlan plan) {
    final b = StringBuffer();
    if (_isTr) {
      b.writeln('Plan hazır: ${plan.summary}');
      if (plan.steps.isNotEmpty) {
        for (int i = 0; i < plan.steps.length; i++) {
          b.writeln('${i + 1}. ${plan.steps[i]}');
        }
      }
      b.write('Uygulamadan önce onayını bekliyorum. "devam" yazman yeterli.');
      return b.toString().trim();
    }
    b.writeln('Plan ready: ${plan.summary}');
    if (plan.steps.isNotEmpty) {
      for (int i = 0; i < plan.steps.length; i++) {
        b.writeln('${i + 1}. ${plan.steps[i]}');
      }
    }
    b.write('Waiting for your approval before execution. Type "continue".');
    return b.toString().trim();
  }

  String? _buildCompletionReport(AiAgentRunResult result) {
    if (_currentAgentMode() != AiAgentMode.agent || result.steps.isEmpty) {
      return null;
    }
    final commandSteps = result.steps
        .where((s) => s.action.type == AiAgentActionType.runCommand)
        .toList(growable: false);
    final scriptSteps = result.steps
        .where((s) => s.action.type == AiAgentActionType.writeScript)
        .toList(growable: false);
    final successCount = commandSteps
        .where((s) => s.commandResult?.success == true)
        .length;
    final failCount = commandSteps.length - successCount;
    final last = _runtimeCommands.isNotEmpty ? _runtimeCommands.last : null;
    final tail = last == null
        ? ''
        : _summarizeResultTail(last.output, fallback: last.command);

    if (_isTr) {
      final parts = <String>[
        'Özet rapor: ${result.steps.length} adım tamamlandı.',
        '${commandSteps.length} komut çalıştı ($successCount başarılı${failCount > 0 ? ', $failCount hatalı' : ''}).',
      ];
      if (scriptSteps.isNotEmpty) {
        parts.add('${scriptSteps.length} script adımı işlendi.');
      }
      if (tail.isNotEmpty) {
        parts.add('Son durum: $tail');
      }
      return parts.join(' ');
    }
    final parts = <String>[
      'Summary report: ${result.steps.length} steps completed.',
      '${commandSteps.length} commands executed ($successCount successful${failCount > 0 ? ', $failCount failed' : ''}).',
    ];
    if (scriptSteps.isNotEmpty) {
      parts.add('${scriptSteps.length} script steps processed.');
    }
    if (tail.isNotEmpty) {
      parts.add('Latest state: $tail');
    }
    return parts.join(' ');
  }

  String _summarizeResultTail(String output, {required String fallback}) {
    final lines = output
        .split('\n')
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty)
        .toList(growable: false);
    if (lines.isEmpty) {
      return fallback;
    }
    for (int i = lines.length - 1; i >= 0; i--) {
      final line = lines[i];
      final lower = line.toLowerCase();
      if (lower.startsWith('exit=') || lower.startsWith('command')) {
        continue;
      }
      return line.length > 140 ? '${line.substring(0, 140)}...' : line;
    }
    return fallback;
  }

  void _appendMessagesFromAgentSteps(
    int previousCount,
    List<AiAgentStepRecord> steps,
  ) {
    if (steps.length <= previousCount) {
      return;
    }
    for (int i = previousCount; i < steps.length; i++) {
      final step = steps[i];
      final action = step.action;
      switch (action.type) {
        case AiAgentActionType.reply:
        case AiAgentActionType.askUser:
        case AiAgentActionType.finish:
          final msg = _normalizeAssistantText(
            (action.message ?? '').trim(),
          ).trim();
          if (msg.isNotEmpty) {
            _appendMessage(
              _ChatMessage(
                id: _newMessageId(),
                role: _ChatRole.assistant,
                text: msg,
                stepNumber: step.index,
                createdAt: DateTime.now(),
              ),
              eventId: 'step:${step.index}:${action.type.name}:$msg',
            );
          }
          break;
        case AiAgentActionType.runCommand:
          final fallback = _isTr ? 'Komut çalıştırıldı.' : 'Command executed.';
          final handoff = _isVisibleHandoffResult(step.commandResult);
          final success = step.commandResult?.success ?? false;
          final msg = _normalizeAssistantText(
            (action.message ?? action.reason ?? fallback).trim(),
          ).trim();
          final messageText = handoff
              ? _extractVisibleHandoffMessage(step.commandResult?.output ?? '')
              : msg;
          final shouldShowStepMessage =
              !(_mode == _ChatMode.chat && (success || handoff));
          if (shouldShowStepMessage) {
            _appendMessage(
              _ChatMessage(
                id: _newMessageId(),
                role: (success || handoff)
                    ? _ChatRole.assistant
                    : _ChatRole.error,
                text: messageText,
                command: action.command,
                stepNumber: step.index,
                commandResult: step.commandResult,
                createdAt: DateTime.now(),
              ),
              eventId:
                  'step:${step.index}:${action.type.name}:${action.command ?? ''}',
            );
          }
          if (step.commandResult != null) {
            _recordRuntimeCommand(step.commandResult!);
            _startForegroundWatchAutomationIfNeeded(step.commandResult!);
          }
          _persistAiHistoryStep(action, step.commandResult);
          break;
        case AiAgentActionType.writeScript:
          final path =
              action.scriptPath ??
              (_isTr ? 'belirtilmemiş dosya' : 'unspecified file');
          final fallback = _isTr
              ? 'Script yazıldı ve doğrulandı.'
              : 'Script was written and validated.';
          final msg = _normalizeAssistantText(
            (action.message ?? action.reason ?? fallback).trim(),
          ).trim();
          _appendMessage(
            _ChatMessage(
              id: _newMessageId(),
              role: _ChatRole.assistant,
              text: msg,
              command: step.commandResult?.command,
              stepNumber: step.index,
              commandResult: step.commandResult,
              scriptPath: path,
              scriptContent: action.scriptContent,
              createdAt: DateTime.now(),
            ),
            eventId:
                'step:${step.index}:${action.type.name}:$path:${step.commandResult?.command ?? ''}',
          );
          if (step.commandResult != null) {
            _recordRuntimeCommand(step.commandResult!);
          }
          _persistAiHistoryStep(action, step.commandResult);
          break;
      }
    }
  }

  void _addAssistantMessageIfNotDuplicate(String text) {
    final normalized = _normalizeAssistantText(text).trim();
    if (normalized.isEmpty) {
      return;
    }
    final msg = _ChatMessage(
      id: _newMessageId(),
      role: _ChatRole.assistant,
      text: normalized,
      createdAt: DateTime.now(),
    );
    _appendMessage(msg, eventId: 'assistant:${_stableHash(normalized)}');
  }

  Future<void> _handleCommandBubbleExecute(_ChatMessage message) async {
    final command = message.command?.trim() ?? '';
    if (command.isEmpty || _loading) {
      return;
    }

    final result = await _runTrackedCommand(command);
    if (!mounted) {
      return;
    }
    _recordRuntimeCommand(result);
    _startForegroundWatchAutomationIfNeeded(result);

    final pendingCommand = _pendingAction?.command?.trim() ?? '';
    final isPendingMatch =
        pendingCommand.isNotEmpty &&
        pendingCommand.toLowerCase() == command.toLowerCase();
    if (isPendingMatch) {
      _pendingAction = null;
      _lastPendingQuestion = null;
      _agentEngine.resetStop();
      await _runAgentLoop(
        executePendingAction: false,
        stage: 'follow_up',
        latestUserMessage: _isTr ? 'Komutu çalıştırdım' : 'I ran the command',
      );
      return;
    }

    setState(() {
      final isHandoff = _isVisibleHandoffResult(result);
      _appendMessage(
        _ChatMessage(
          id: _newMessageId(),
          role: (result.success || isHandoff)
              ? _ChatRole.assistant
              : _ChatRole.error,
          text: result.success
              ? (_isTr ? 'Komut çalıştırıldı.' : 'Command executed.')
              : (isHandoff
                    ? _extractVisibleHandoffMessage(result.output)
                    : (result.timedOut
                          ? (_isTr
                                ? 'Komut gönderildi. Tamamlanınca "devam" yazabilirsin.'
                                : 'Command sent. You can type "continue" when it finishes.')
                          : (_isTr
                                ? 'Komut çalıştırılırken hata oluştu.'
                                : 'Command execution failed.'))),
          command: command,
          commandResult: result,
          createdAt: DateTime.now(),
        ),
        eventId:
            'manual_run:${message.id}:${result.exitCode ?? -1}:${result.timedOut ? 1 : 0}',
      );
    });
    _scrollToBottom();
  }

  Future<AiAgentCommandResult> _runTrackedCommand(String command) async {
    if (widget.onRunTrackedCommand != null) {
      return widget.onRunTrackedCommand!(command);
    }

    final started = DateTime.now();
    final before = _readRecentTerminalOutput(maxLines: 220);
    widget.onExecuteCommand(command);
    final awaitResult = await _awaitTerminalCommandCompletion(
      baseline: before,
      maxWait: const Duration(seconds: 35),
    );
    final after = awaitResult.snapshot;
    final output = _extractOutputTail(before: before, after: after);
    final durationMs = DateTime.now().difference(started).inMilliseconds;
    final waitingInput =
        awaitResult.waitingInput || _hasInteractiveInputRequest(output);
    final success =
        !awaitResult.timedOut &&
        !waitingInput &&
        !_looksLikeCommandFailure(output);

    return AiAgentCommandResult(
      command: command,
      output: output,
      success: success,
      durationMs: durationMs,
      exitCode: success ? 0 : 1,
      timedOut: awaitResult.timedOut,
    );
  }

  Future<_TerminalAwaitResult> _awaitTerminalCommandCompletion({
    required String baseline,
    Duration maxWait = const Duration(seconds: 35),
  }) async {
    var last = _readRecentTerminalOutput(maxLines: 220);
    var stableFor = Duration.zero;
    var promptStableFor = Duration.zero;
    var seenChange = false;
    var sawPrompt = false;
    const step = Duration(milliseconds: 220);
    var waited = Duration.zero;

    while (waited < maxWait) {
      await Future.delayed(step);
      waited += step;
      final current = _readRecentTerminalOutput(maxLines: 220);
      if (current != baseline) {
        seenChange = true;
      }
      final tail = _extractOutputTail(before: baseline, after: current);

      if (seenChange && _tailLooksLikeShellPrompt(tail)) {
        sawPrompt = true;
        if (current == last) {
          promptStableFor += step;
          if (promptStableFor >= const Duration(milliseconds: 440)) {
            return _TerminalAwaitResult(
              snapshot: current,
              timedOut: false,
              waitingInput: false,
            );
          }
        } else {
          promptStableFor = Duration.zero;
        }
      }

      if (_hasInteractiveInputRequest(tail) && !sawPrompt) {
        if (current == last) {
          stableFor += step;
        } else {
          stableFor = Duration.zero;
        }
        if (stableFor >= const Duration(milliseconds: 900)) {
          return _TerminalAwaitResult(
            snapshot: current,
            timedOut: false,
            waitingInput: true,
          );
        }
      } else if (current == last) {
        stableFor += step;
      } else {
        stableFor = Duration.zero;
      }

      // Fallback for custom prompts/themes that are hard to pattern-match.
      if (seenChange &&
          stableFor >= const Duration(milliseconds: 1800) &&
          !_hasInteractiveInputRequest(tail)) {
        return _TerminalAwaitResult(
          snapshot: current,
          timedOut: false,
          waitingInput: false,
        );
      }

      last = current;
    }
    return _TerminalAwaitResult(
      snapshot: last,
      timedOut: true,
      waitingInput: false,
    );
  }

  bool _tailLooksLikeShellPrompt(String outputTail) {
    final tail = outputTail.trimRight();
    if (tail.isEmpty) {
      return false;
    }
    final lines = tail.split('\n');
    final last = lines.last.trimRight();
    if (last.isEmpty) {
      return false;
    }

    final promptPatterns = [
      RegExp(r'^[^\s@]+@[^:\s]+:[^#$]*[#$]\s*$'),
      RegExp(r'^(~|/[^#$]*|\.[^#$]*)\s*[#$]\s*$'),
      RegExp(r'^[#$]\s*$'),
      RegExp(r'^[A-Za-z]:\\[^>\n]*>\s*$'),
      RegExp(r'^PS [^>\n]+>\s*$'),
    ];
    return promptPatterns.any((p) => p.hasMatch(last));
  }

  bool _hasInteractiveInputRequest(String output) {
    final lower = output.toLowerCase();
    const patterns = [
      '[sudo] password',
      'password for',
      'enter passphrase',
      'authentication is required',
      'do you want to continue',
      'devam etmek istiyor musun',
      '(y/n)',
      '[y/n]',
      '[yes/no]',
      'press any key',
      'şifre',
      'sifre',
    ];
    return patterns.any(lower.contains);
  }

  String _extractOutputTail({required String before, required String after}) {
    if (after.isEmpty) {
      return '';
    }
    if (before.isEmpty) {
      return after.trim();
    }
    if (after.startsWith(before)) {
      return after.substring(before.length).trim();
    }
    final beforeLines = before.split('\n');
    final afterLines = after.split('\n');
    int overlap = 0;
    final maxOverlap = beforeLines.length < afterLines.length
        ? beforeLines.length
        : afterLines.length;
    for (int n = maxOverlap; n > 0; n--) {
      final beforeTail = beforeLines.sublist(beforeLines.length - n).join('\n');
      final afterHead = afterLines.sublist(0, n).join('\n');
      if (beforeTail == afterHead) {
        overlap = n;
        break;
      }
    }
    final tail = afterLines.sublist(overlap).join('\n').trim();
    return tail.isEmpty ? after.trim() : tail;
  }

  bool _looksLikeCommandFailure(String output) {
    final lower = output.toLowerCase();
    const errorSignals = [
      'command not found',
      'permission denied',
      'no such file',
      'failed',
      'error:',
      'hata:',
      'cannot',
      'not recognized as an internal or external command',
      'is not recognized as',
      'traceback (most recent call last)',
    ];
    return errorSignals.any(lower.contains);
  }

  bool _isVisibleHandoffResult(AiAgentCommandResult? result) {
    if (result == null) {
      return false;
    }
    return result.output.contains('__LIFEOS_VISIBLE_HANDOFF__');
  }

  String _extractVisibleHandoffMessage(String output) {
    final clean = output.replaceAll('__LIFEOS_VISIBLE_HANDOFF__', '').trim();
    if (clean.isNotEmpty) {
      return clean;
    }
    return _isTr
        ? 'Komutu görünür terminale gönderdim. Tamamlanınca "devam" yaz.'
        : 'Sent command to visible terminal. Type "continue" when it finishes.';
  }

  void _stopForegroundWatchAutomation() {
    _foregroundWatchTimer?.cancel();
    _foregroundWatchTimer = null;
    _foregroundWatchBusy = false;
  }

  void _startForegroundWatchAutomationIfNeeded(AiAgentCommandResult result) {
    if (!_isVisibleHandoffResult(result)) {
      return;
    }
    if (!widget.appController.aiWatchMode || widget.isRemote) {
      return;
    }
    _stopForegroundWatchAutomation();
    var baseline = _readRecentTerminalOutput(maxLines: 220);
    if (baseline.trim().isEmpty) {
      return;
    }
    _addAssistantMessageIfNotDuplicate(
      _isTr
          ? 'Komut görünür terminalde çalışıyor. Biter bitmez otomatik devam edeceğim.'
          : 'Command is running in visible terminal. I will auto-continue when it finishes.',
    );
    _foregroundWatchTimer = Timer.periodic(const Duration(seconds: 1), (
      timer,
    ) async {
      if (!mounted || _loading || _foregroundWatchBusy) {
        return;
      }
      _foregroundWatchBusy = true;
      try {
        final current = _readRecentTerminalOutput(maxLines: 220);
        if (current.trim().isEmpty || current == baseline) {
          return;
        }
        final tail = _extractOutputTail(before: baseline, after: current);
        final promptReady =
            _tailLooksLikeShellPrompt(tail) &&
            !_hasInteractiveInputRequest(tail);
        if (!promptReady) {
          baseline = current;
          return;
        }
        _stopForegroundWatchAutomation();
        _agentEngine.resetStop();
        await _runAgentLoop(
          executePendingAction: false,
          stage: 'follow_up',
          latestUserMessage: _isTr
              ? 'Ön plan komutu tamamlandı, devam et'
              : 'Foreground command finished, continue',
        );
      } finally {
        _foregroundWatchBusy = false;
      }
    });
  }

  Future<AiAgentCommandResult> _writeScriptStep(AiAgentAction action) async {
    final content = (action.scriptContent ?? '').trimRight();
    if (content.trim().isEmpty) {
      return AiAgentCommandResult(
        command: 'write_script',
        output: _isTr
            ? 'Script içeriği boş geldi. Dosya yazılamadı.'
            : 'Script content is empty. File was not written.',
        success: false,
        durationMs: 0,
        exitCode: 1,
      );
    }

    final path = (action.scriptPath?.trim().isNotEmpty ?? false)
        ? action.scriptPath!.trim()
        : _defaultScriptPath(action.scriptLanguage);
    final writeCommand = _buildScriptWriteCommand(
      path: path,
      content: content,
      language: action.scriptLanguage,
    );

    final writeResult = await _runTrackedCommand(writeCommand);
    if (!writeResult.success) {
      return AiAgentCommandResult(
        command: 'write_script:$path',
        output: writeResult.output,
        success: false,
        durationMs: writeResult.durationMs,
        exitCode: writeResult.exitCode,
        cwd: writeResult.cwd,
        timedOut: writeResult.timedOut,
        cancelled: writeResult.cancelled,
      );
    }

    final validationCommand = _resolveScriptValidationCommand(
      action: action,
      path: path,
    );
    if (validationCommand == null || validationCommand.trim().isEmpty) {
      return AiAgentCommandResult(
        command: 'write_script:$path',
        output: writeResult.output,
        success: true,
        durationMs: writeResult.durationMs,
        exitCode: writeResult.exitCode ?? 0,
        cwd: writeResult.cwd,
      );
    }

    final validateResult = await _runTrackedCommand(validationCommand);
    final output = StringBuffer();
    if (writeResult.output.trim().isNotEmpty) {
      output.writeln(writeResult.output.trim());
    }
    if (validateResult.output.trim().isNotEmpty) {
      if (output.isNotEmpty) {
        output.writeln('');
      }
      output.writeln(validateResult.output.trim());
    }

    return AiAgentCommandResult(
      command: 'write_script:$path',
      output: output.toString().trim(),
      success: validateResult.success,
      durationMs: writeResult.durationMs + validateResult.durationMs,
      exitCode: validateResult.exitCode ?? writeResult.exitCode,
      cwd: validateResult.cwd ?? writeResult.cwd,
      timedOut: validateResult.timedOut,
      cancelled: validateResult.cancelled,
    );
  }

  String _defaultScriptPath(String? language) {
    final ts = DateTime.now().millisecondsSinceEpoch;
    final lowerLang = (language ?? '').toLowerCase();
    if (_isUnixLikeShell) {
      if (lowerLang.contains('python')) {
        return './lifeos_script_$ts.py';
      }
      return './lifeos_script_$ts.sh';
    }
    if (_isPowerShellShell || lowerLang.contains('powershell')) {
      return '.\\lifeos_script_$ts.ps1';
    }
    return '.\\lifeos_script_$ts.cmd';
  }

  bool get _isUnixLikeShell {
    if (widget.isRemote) {
      return true;
    }
    final shell = (widget.shellName ?? '').toLowerCase();
    return shell.contains('bash') ||
        shell.contains('zsh') ||
        shell.contains('fish') ||
        shell.contains('wsl');
  }

  bool get _isPowerShellShell {
    final shell = (widget.shellName ?? '').toLowerCase();
    return shell.contains('powershell') || shell.contains('pwsh');
  }

  String _buildScriptWriteCommand({
    required String path,
    required String content,
    String? language,
  }) {
    if (_isUnixLikeShell) {
      return _buildUnixScriptWriteCommand(path: path, content: content);
    }
    return _buildWindowsScriptWriteCommand(
      path: path,
      content: content,
      language: language,
    );
  }

  String _buildUnixScriptWriteCommand({
    required String path,
    required String content,
  }) {
    final marker = '__LIFEOS_SCRIPT_${DateTime.now().microsecondsSinceEpoch}__';
    final quotedPath = _shellQuote(path);
    return '''
cat > $quotedPath <<'$marker'
$content
$marker
chmod +x $quotedPath
''';
  }

  String _buildWindowsScriptWriteCommand({
    required String path,
    required String content,
    String? language,
  }) {
    final encoded = base64Encode(utf8.encode(content));
    final escapedPath = path.replaceAll("'", "''");
    final psSnippet =
        "\$lifeosPath = '$escapedPath'; "
        "\$lifeosDir = Split-Path -Parent \$lifeosPath; "
        "if (\$lifeosDir) { [IO.Directory]::CreateDirectory(\$lifeosDir) | Out-Null }; "
        "\$lifeosBytes = [Convert]::FromBase64String('$encoded'); "
        "[IO.File]::WriteAllBytes(\$lifeosPath, \$lifeosBytes)";

    if (_isPowerShellShell ||
        (language ?? '').toLowerCase().contains('powershell')) {
      return psSnippet;
    }

    final escapedForCmd = psSnippet
        .replaceAll('"', '\\"')
        .replaceAll('%', '%%');
    return 'powershell -NoProfile -Command "$escapedForCmd"';
  }

  String? _resolveScriptValidationCommand({
    required AiAgentAction action,
    required String path,
  }) {
    final explicit = action.validationCommand?.trim();
    if (explicit != null && explicit.isNotEmpty) {
      return explicit;
    }

    if (_isUnixLikeShell) {
      return 'bash -n ${_shellQuote(path)}';
    }

    final language = (action.scriptLanguage ?? '').toLowerCase();
    final isPowerShellScript =
        _isPowerShellShell ||
        language.contains('powershell') ||
        language.contains('pwsh') ||
        path.toLowerCase().endsWith('.ps1');
    if (!isPowerShellScript) {
      return null;
    }
    final escapedPath = path.replaceAll("'", "''");
    return "powershell -NoProfile -Command \"\$null = [System.Management.Automation.Language.Parser]::ParseFile('$escapedPath', [ref]\$null, [ref]\$null)\"";
  }

  String _shellQuote(String input) {
    final escaped = input.replaceAll("'", "'\"'\"'");
    return "'$escaped'";
  }

  String _psQuote(String input) {
    final escaped = input.replaceAll("'", "''");
    return "'$escaped'";
  }

  String _cmdQuote(String input) {
    final escaped = input.replaceAll('"', '""');
    return '"$escaped"';
  }

  Future<void> _runScriptMessageAction({
    required _ChatMessage message,
    required _ScriptMessageAction action,
  }) async {
    final path = message.scriptPath?.trim();
    if (path == null || path.isEmpty) {
      return;
    }

    final command = switch (action) {
      _ScriptMessageAction.show => _buildScriptShowCommand(path),
      _ScriptMessageAction.run => _buildScriptRunCommand(path),
      _ScriptMessageAction.delete => _buildScriptDeleteCommand(path),
    };
    final stepLabel = switch (action) {
      _ScriptMessageAction.show =>
        _isTr
            ? 'Script içeriği terminalde gösterildi.'
            : 'Script content shown in terminal.',
      _ScriptMessageAction.run =>
        _isTr ? 'Script çalıştırıldı.' : 'Script executed.',
      _ScriptMessageAction.delete =>
        _isTr ? 'Script dosyası silindi.' : 'Script file deleted.',
    };
    final failedLabel = switch (action) {
      _ScriptMessageAction.show =>
        _isTr
            ? 'Script içeriği gösterilemedi.'
            : 'Failed to show script content.',
      _ScriptMessageAction.run =>
        _isTr ? 'Script çalıştırılamadı.' : 'Failed to execute script.',
      _ScriptMessageAction.delete =>
        _isTr ? 'Script dosyası silinemedi.' : 'Failed to delete script file.',
    };

    final result = await _runTrackedCommand(command);
    if (!mounted) {
      return;
    }

    final baseText = result.success ? stepLabel : failedLabel;
    setState(() {
      _appendMessage(
        _ChatMessage(
          id: _newMessageId(),
          role: result.success ? _ChatRole.assistant : _ChatRole.error,
          text: baseText,
          command: command,
          commandResult: result,
          scriptPath: action == _ScriptMessageAction.delete && result.success
              ? null
              : path,
          createdAt: DateTime.now(),
        ),
        eventId: 'script_action:${action.name}:$path:${result.exitCode ?? -1}',
        persist: true,
      );
    });
    _recordRuntimeCommand(result);
    _scrollToBottom();
  }

  String _buildScriptShowCommand(String path) {
    if (_isUnixLikeShell) {
      return 'sed -n \'1,220p\' ${_shellQuote(path)}';
    }
    if (_isPowerShellShell || path.toLowerCase().endsWith('.ps1')) {
      return 'Get-Content -LiteralPath ${_psQuote(path)} -TotalCount 220';
    }
    return 'type ${_cmdQuote(path)}';
  }

  String _buildScriptRunCommand(String path) {
    if (_isUnixLikeShell) {
      return 'bash ${_shellQuote(path)}';
    }
    if (_isPowerShellShell || path.toLowerCase().endsWith('.ps1')) {
      return 'powershell -NoProfile -ExecutionPolicy Bypass -File ${_psQuote(path)}';
    }
    return 'cmd /c ${_cmdQuote(path)}';
  }

  String _buildScriptDeleteCommand(String path) {
    if (_isUnixLikeShell) {
      return 'rm -f ${_shellQuote(path)}';
    }
    if (_isPowerShellShell || path.toLowerCase().endsWith('.ps1')) {
      return 'Remove-Item -Force -LiteralPath ${_psQuote(path)}';
    }
    return 'del /f /q ${_cmdQuote(path)}';
  }

  void _persistAiHistoryStep(
    AiAgentAction action,
    AiAgentCommandResult? result,
  ) {
    final query = _activeGoal?.trim();
    final command = action.command?.trim().isNotEmpty == true
        ? action.command!.trim()
        : (action.type == AiAgentActionType.writeScript
              ? 'write_script:${action.scriptPath ?? ''}'
              : null);
    if (query == null || query.isEmpty || command == null || command.isEmpty) {
      return;
    }
    final app = widget.appController;
    final suffix = result == null
        ? ''
        : ' (exit: ${result.exitCode ?? '?'}, ${result.durationMs}ms)';
    app.addAiHistory(
      AiHistoryEntry(
        query: query,
        command: command,
        explanation: '${action.message ?? action.reason ?? ''}$suffix'.trim(),
        provider: app.aiProvider,
        model: app.aiModel,
        timestamp: DateTime.now(),
        executed: result != null,
      ),
    );
  }

  Future<void> _continuePendingStep() async {
    if (_pendingAction == null || _loading) {
      return;
    }
    _agentEngine.resetStop();
    await _runAgentLoop(
      executePendingAction: true,
      stage: 'follow_up',
      latestUserMessage: _isTr ? 'Devam et' : 'Continue',
    );
  }

  Future<void> _editPendingStep() async {
    final action = _pendingAction;
    if (action == null || _loading) {
      return;
    }

    final isScript = action.type == AiAgentActionType.writeScript;
    final initialValue = isScript
        ? (action.scriptPath?.trim() ?? '')
        : (action.command?.trim() ?? '');
    final initialMessage = action.message?.trim() ?? '';
    final valueCtrl = TextEditingController(text: initialValue);
    final messageCtrl = TextEditingController(text: initialMessage);

    final result = await showDialog<_PendingEditResult>(
      context: context,
      builder: (context) {
        return ContentDialog(
          title: Text(
            _isTr ? 'Bekleyen adımı düzenle' : 'Edit pending step',
            style: TextStyle(color: workbenchText),
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextBox(
                controller: valueCtrl,
                placeholder: isScript
                    ? (_isTr ? 'Script yolu' : 'Script path')
                    : (_isTr ? 'Komut' : 'Command'),
              ),
              const SizedBox(height: 8),
              TextBox(
                controller: messageCtrl,
                placeholder: _isTr
                    ? 'Açıklama (opsiyonel)'
                    : 'Explanation (optional)',
              ),
            ],
          ),
          actions: [
            Button(
              child: Text(_isTr ? 'Vazgeç' : 'Cancel'),
              onPressed: () => Navigator.pop(context),
            ),
            FilledButton(
              child: Text(_isTr ? 'Kaydet' : 'Save'),
              onPressed: () {
                final nextValue = valueCtrl.text.trim();
                final nextMessage = messageCtrl.text.trim();
                Navigator.pop(
                  context,
                  _PendingEditResult(value: nextValue, message: nextMessage),
                );
              },
            ),
          ],
        );
      },
    );

    if (!mounted || result == null) {
      return;
    }
    if (result.value.trim().isEmpty) {
      setState(() {
        _appendMessage(
          _ChatMessage(
            id: _newMessageId(),
            role: _ChatRole.error,
            text: _isTr
                ? 'Bekleyen adım boş bırakılamaz.'
                : 'Pending step cannot be empty.',
            createdAt: DateTime.now(),
          ),
          eventId: 'pending_edit_empty',
          persist: true,
        );
      });
      _scrollToBottom();
      return;
    }

    final nextAction = isScript
        ? action.copyWith(
            scriptPath: result.value.trim(),
            message: result.message.trim().isEmpty
                ? action.message
                : result.message.trim(),
          )
        : action.copyWith(
            command: result.value.trim(),
            message: result.message.trim().isEmpty
                ? action.message
                : result.message.trim(),
          );

    setState(() {
      _pendingAction = nextAction;
      _lastPendingQuestion = nextAction.message?.trim();
      _appendMessage(
        _ChatMessage(
          id: _newMessageId(),
          role: _ChatRole.assistant,
          text: _isTr
              ? 'Bekleyen adım güncellendi. İstersen şimdi çalıştırabilirim.'
              : 'Pending step updated. I can run it now.',
          createdAt: DateTime.now(),
        ),
        eventId: 'pending_edit_saved:${DateTime.now().millisecondsSinceEpoch}',
        persist: true,
      );
    });
    await _persistRuntimeSession();
    _scrollToBottom();
  }

  Future<void> _skipPendingStep() async {
    if (_pendingAction == null || _loading) {
      return;
    }
    setState(() {
      _appendMessage(
        _ChatMessage(
          id: _newMessageId(),
          role: _ChatRole.assistant,
          text: _isTr
              ? 'Bekleyen adım atlandı. Yeni bir adım planlıyorum.'
              : 'Pending step skipped. Planning the next step.',
          createdAt: DateTime.now(),
        ),
        eventId: 'pending_skip:${DateTime.now().millisecondsSinceEpoch}',
        persist: true,
      );
      _pendingAction = null;
      _lastPendingQuestion = null;
      _agentState = _AgentUiState.running;
    });
    _agentEngine.resetStop();
    await _runAgentLoop(
      executePendingAction: false,
      stage: 'follow_up',
      latestUserMessage: _isTr ? 'Bekleyen adımı atla' : 'Skip pending step',
    );
  }

  Future<void> _replanPendingStep() async {
    if (_loading) {
      return;
    }
    final goal = (_activeGoal ?? '').trim();
    if (goal.isEmpty) {
      return;
    }

    setState(() {
      _pendingAction = null;
      _lastPendingQuestion = null;
      _awaitingPlanApproval = false;
      _approvedGoalKey = null;
      _agentState = _AgentUiState.running;
      _appendMessage(
        _ChatMessage(
          id: _newMessageId(),
          role: _ChatRole.assistant,
          text: _isTr
              ? 'Tamam, planı yeniliyorum ve daha iyi bir adım sırası çıkarıyorum.'
              : 'Okay, I am replanning with a better step sequence.',
          createdAt: DateTime.now(),
        ),
        eventId: 'pending_replan:${DateTime.now().millisecondsSinceEpoch}',
        persist: true,
      );
    });
    _agentEngine.resetStop();
    await _runAgentLoop(
      executePendingAction: false,
      stage: 'follow_up',
      latestUserMessage: _isTr ? 'Planı yeniden oluştur' : 'Rebuild the plan',
    );
  }

  void _stopAgent() {
    _agentEngine.requestStop();
    _stopForegroundWatchAutomation();
    widget.onInterruptCommand?.call();
    if (!mounted) return;
    setState(() {
      _loading = false;
      _agentState = _AgentUiState.paused;
      _appendMessage(
        _ChatMessage(
          id: _newMessageId(),
          role: _ChatRole.assistant,
          text: _isTr
              ? 'Agent durduruldu. İstersen devam edebiliriz.'
              : 'Agent stopped. You can continue when ready.',
          createdAt: DateTime.now(),
        ),
        eventId: 'agent_stopped',
        persist: true,
      );
    });
    _scrollToBottom();
  }

  Future<void> _initSpeech() async {
    try {
      final available = await _speech.initialize(
        onStatus: (status) {
          if (!_listening) return;
          if (status == 'done' || status == 'notListening') {
            _finishVoiceCapture();
          }
        },
        onError: (error) {
          if (!mounted) return;
          setState(() {
            _lastVoiceError = error.errorMsg;
            _listening = false;
          });
        },
      );
      if (!mounted) return;
      setState(() {
        _speechReady = available;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _speechReady = false;
        _lastVoiceError = e.toString();
      });
    }
  }

  Future<void> _toggleVoice() async {
    if (_loading) return;
    if (!_speechReady) {
      await _initSpeech();
      if (!_speechReady) {
        if (!mounted) return;
        setState(() {
          _appendMessage(
            _ChatMessage(
              id: _newMessageId(),
              role: _ChatRole.error,
              text: _isTr
                  ? 'Mikrofon erişimi açılamadı. Telefon izinlerini kontrol et.'
                  : 'Microphone access is not available. Check app permissions.',
              createdAt: DateTime.now(),
            ),
            persist: true,
          );
        });
        _scrollToBottom();
        return;
      }
    }

    if (_listening) {
      await _speech.stop();
      _finishVoiceCapture();
      return;
    }

    setState(() {
      _voiceDraft = '';
      _lastVoiceError = '';
      _listening = true;
    });

    await _speech.listen(
      localeId: _isTr ? 'tr_TR' : 'en_US',
      listenOptions: SpeechListenOptions(
        listenMode: ListenMode.confirmation,
        partialResults: true,
      ),
      onResult: (result) {
        final text = result.recognizedWords.trim();
        if (!mounted || text.isEmpty) return;
        setState(() {
          _voiceDraft = text;
          _inputCtrl.text = text;
          _inputCtrl.selection = TextSelection.fromPosition(
            TextPosition(offset: _inputCtrl.text.length),
          );
        });
      },
    );
  }

  void _finishVoiceCapture() {
    if (!_listening) return;
    final text = _voiceDraft.trim();
    setState(() {
      _listening = false;
    });
    if (text.isNotEmpty) {
      _sendMessage(text);
    }
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollCtrl.hasClients) {
        _scrollCtrl.animateTo(
          _scrollCtrl.position.maxScrollExtent,
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOut,
        );
      }
    });
  }

  String _agentStatusLabel() {
    switch (_agentState) {
      case _AgentUiState.idle:
        return _isTr ? 'Hazır' : 'Idle';
      case _AgentUiState.running:
        return _isTr ? 'Çalışıyor' : 'Running';
      case _AgentUiState.waiting:
        return _isTr ? 'Onay bekliyor' : 'Waiting approval';
      case _AgentUiState.paused:
        return _isTr ? 'Duraklatıldı' : 'Paused';
      case _AgentUiState.done:
        return _isTr ? 'Tamamlandı' : 'Done';
    }
  }

  Color _agentStatusColor() {
    switch (_agentState) {
      case _AgentUiState.idle:
        return workbenchTextMuted;
      case _AgentUiState.running:
        return workbenchSuccess;
      case _AgentUiState.waiting:
        return workbenchWarning;
      case _AgentUiState.paused:
        return workbenchDanger;
      case _AgentUiState.done:
        return workbenchAccent;
    }
  }

  bool get _hasPendingRunnableAction {
    final action = _pendingAction;
    if (action == null) {
      return false;
    }
    if (action.type == AiAgentActionType.writeScript) {
      return (action.scriptContent?.trim().isNotEmpty ?? false);
    }
    return (action.command?.trim().isNotEmpty ?? false);
  }

  String _pendingActionPreview() {
    final action = _pendingAction;
    if (action == null) {
      return '';
    }
    if (action.type == AiAgentActionType.writeScript) {
      final path = action.scriptPath ?? '';
      if (path.isEmpty) {
        return _isTr ? 'script oluşturma adımı' : 'script write step';
      }
      return 'write_script:$path';
    }
    return action.command ?? '';
  }

  KeyEventResult _handlePanelShortcutKeyEvent(KeyEvent event) {
    if (!_panelShortcutsEnabled) {
      return KeyEventResult.ignored;
    }
    if (event is! KeyDownEvent) {
      return KeyEventResult.ignored;
    }
    if (!_panelShortcutFocus.hasPrimaryFocus) {
      return KeyEventResult.ignored;
    }
    if (!_expanded || !_hasPendingRunnableAction || _loading) {
      return KeyEventResult.ignored;
    }
    if (_inputFocus.hasFocus) {
      return KeyEventResult.ignored;
    }

    final key = event.logicalKey;
    final isCtrlOrMeta =
        HardwareKeyboard.instance.isControlPressed ||
        HardwareKeyboard.instance.isMetaPressed;

    if (key == LogicalKeyboardKey.enter ||
        key == LogicalKeyboardKey.numpadEnter) {
      _panelShortcutFocus.unfocus();
      unawaited(_continuePendingStep());
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.escape) {
      _panelShortcutFocus.unfocus();
      unawaited(_skipPendingStep());
      return KeyEventResult.handled;
    }
    if (isCtrlOrMeta && key == LogicalKeyboardKey.keyR) {
      _panelShortcutFocus.unfocus();
      unawaited(_replanPendingStep());
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.appController.aiEnabled) return const SizedBox.shrink();

    // Collapsed: just the toggle bar.
    if (!_expanded) {
      return GestureDetector(
        onTap: toggle,
        child: Container(
          height: 32,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          decoration: BoxDecoration(
            color: workbenchEditorBg,
            border: Border(
              top: BorderSide(color: workbenchDivider, width: 0.5),
            ),
          ),
          child: Row(
            children: [
              Icon(FluentIcons.robot, size: 12, color: workbenchAccent),
              const SizedBox(width: 8),
              Text(
                _isTr ? 'AI Sohbet' : 'AI Chat',
                style: TextStyle(
                  color: workbenchAccent,
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(width: 8),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: _agentStatusColor().withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(
                    color: _agentStatusColor().withValues(alpha: 0.35),
                    width: 0.5,
                  ),
                ),
                child: Text(
                  _agentStatusLabel(),
                  style: TextStyle(
                    color: _agentStatusColor(),
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              const Spacer(),
              Icon(FluentIcons.chevron_up, size: 10, color: workbenchTextFaint),
            ],
          ),
        ),
      );
    }

    // Expanded: full chat panel.
    // Use 50% of available height (min 320, max 600)
    final screenHeight = MediaQuery.of(context).size.height;
    final panelHeight = (screenHeight * 0.50).clamp(320.0, 600.0);
    return Focus(
      focusNode: _panelShortcutFocus,
      onKeyEvent: (_, event) => _handlePanelShortcutKeyEvent(event),
      child: Container(
        height: panelHeight,
        decoration: BoxDecoration(
          color: workbenchEditorBg,
          border: Border(
            top: BorderSide(
              color: workbenchAccent.withValues(alpha: 0.3),
              width: 1,
            ),
          ),
        ),
        child: Column(
          children: [
            // Header
            Container(
              height: 40,
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Row(
                children: [
                  Icon(FluentIcons.robot, size: 12, color: workbenchAccent),
                  const SizedBox(width: 8),
                  Text(
                    _isTr ? 'AI Sohbet' : 'AI Chat',
                    style: TextStyle(
                      color: workbenchAccent,
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(width: 12),
                  _ModeChip(
                    label: _isTr ? 'Sohbet' : 'Chat',
                    active: _mode == _ChatMode.chat,
                    onTap: () => setState(() => _mode = _ChatMode.chat),
                  ),
                  const SizedBox(width: 4),
                  _ModeChip(
                    label: _isTr ? 'Açıkla' : 'Explain',
                    active: _mode == _ChatMode.explain,
                    onTap: () => setState(() => _mode = _ChatMode.explain),
                  ),
                  const SizedBox(width: 4),
                  _ModeChip(
                    label: 'Script',
                    active: _mode == _ChatMode.script,
                    onTap: () => setState(() => _mode = _ChatMode.script),
                  ),
                  const SizedBox(width: 4),
                  _ModeChip(
                    label: _isTr ? 'Agent' : 'Agent',
                    active: _mode == _ChatMode.agent,
                    onTap: () => setState(() => _mode = _ChatMode.agent),
                  ),
                  const SizedBox(width: 8),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 6,
                      vertical: 2,
                    ),
                    decoration: BoxDecoration(
                      color: _agentStatusColor().withValues(alpha: 0.15),
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(
                        color: _agentStatusColor().withValues(alpha: 0.35),
                        width: 0.5,
                      ),
                    ),
                    child: Text(
                      _agentStatusLabel(),
                      style: TextStyle(
                        color: _agentStatusColor(),
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  const Spacer(),
                  if (_hasPendingRunnableAction && !_loading)
                    _MiniActionButton(
                      label: _isTr ? 'Devam' : 'Continue',
                      onTap: _continuePendingStep,
                      color: workbenchSuccess,
                    ),
                  if (_loading || _agentState == _AgentUiState.waiting)
                    Padding(
                      padding: const EdgeInsets.only(left: 6),
                      child: _MiniActionButton(
                        label: _isTr ? 'Durdur' : 'Stop',
                        onTap: _stopAgent,
                        color: workbenchDanger,
                      ),
                    ),
                  if (_messages.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(left: 6),
                      child: GestureDetector(
                        onTap: () {
                          setState(() {
                            _messages.clear();
                            _agentSteps.clear();
                            _pendingAction = null;
                            _lastPendingQuestion = null;
                            _agentState = _AgentUiState.idle;
                            _runtimeCommands.clear();
                            _assistantMessageHashes.clear();
                            _commandHashes.clear();
                            _activeGoal = null;
                          });
                          unawaited(_clearCurrentConversation());
                        },
                        child: Text(
                          _isTr ? 'Temizle' : 'Clear',
                          style: TextStyle(
                            color: workbenchTextFaint,
                            fontSize: 12,
                          ),
                        ),
                      ),
                    ),
                  const SizedBox(width: 10),
                  GestureDetector(
                    onTap: toggle,
                    child: Icon(
                      FluentIcons.chevron_down,
                      size: 10,
                      color: workbenchTextFaint,
                    ),
                  ),
                ],
              ),
            ),
            Container(height: 0.5, color: workbenchBorder),

            // Messages.
            Expanded(
              child: _messages.isEmpty
                  ? Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            FluentIcons.robot,
                            size: 24,
                            color: workbenchTextFaint,
                          ),
                          const SizedBox(height: 8),
                          Text(
                            _mode == _ChatMode.explain
                                ? (_isTr
                                      ? 'Terminal çıktısını sormak için bir şey yazın'
                                      : 'Ask about terminal output')
                                : _mode == _ChatMode.script
                                ? (_isTr
                                      ? 'Oluşturmak istediğiniz scripti tanımlayın'
                                      : 'Describe the script you want to create')
                                : _mode == _ChatMode.agent
                                ? (_isTr
                                      ? 'Hedefi yazın, agent keşfetsin, uygulayıp doğrulasın'
                                      : 'Write the goal, the agent will inspect, apply, and verify')
                                : (_isTr
                                      ? 'Bir soru sorun veya yardım isteyin'
                                      : 'Ask a question or request help'),
                            style: TextStyle(
                              color: workbenchTextFaint,
                              fontSize: 12,
                            ),
                          ),
                        ],
                      ),
                    )
                  : ListView.builder(
                      controller: _scrollCtrl,
                      padding: const EdgeInsets.all(8),
                      itemCount: _messages.length + (_loading ? 1 : 0),
                      itemBuilder: (_, i) {
                        if (i == _messages.length) {
                          return Padding(
                            padding: const EdgeInsets.symmetric(
                              vertical: 4,
                              horizontal: 8,
                            ),
                            child: Row(
                              children: [
                                const SizedBox(
                                  width: 14,
                                  height: 14,
                                  child: ProgressRing(strokeWidth: 2),
                                ),
                                const SizedBox(width: 8),
                                Text(
                                  _isTr
                                      ? 'Agent çalışıyor...'
                                      : 'Agent is running...',
                                  style: TextStyle(
                                    color: workbenchTextMuted,
                                    fontSize: 12,
                                  ),
                                ),
                              ],
                            ),
                          );
                        }
                        return _ChatBubble(
                          message: _messages[i],
                          isTr: _isTr,
                          showStepLabel: _mode != _ChatMode.chat,
                          commandCardMode:
                              widget.appController.aiPanelCommandCardMode,
                          onExecute: _messages[i].command != null
                              ? () => _handleCommandBubbleExecute(_messages[i])
                              : null,
                          onShowScript: _messages[i].scriptPath != null
                              ? () => _runScriptMessageAction(
                                  message: _messages[i],
                                  action: _ScriptMessageAction.show,
                                )
                              : null,
                          onRunScript: _messages[i].scriptPath != null
                              ? () => _runScriptMessageAction(
                                  message: _messages[i],
                                  action: _ScriptMessageAction.run,
                                )
                              : null,
                          onDeleteScript: _messages[i].scriptPath != null
                              ? () => _runScriptMessageAction(
                                  message: _messages[i],
                                  action: _ScriptMessageAction.delete,
                                )
                              : null,
                        );
                      },
                    ),
            ),

            if (_hasPendingRunnableAction && !_loading)
              GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () {
                  if (!_panelShortcutsEnabled) {
                    return;
                  }
                  if (!_inputFocus.hasFocus) {
                    _panelShortcutFocus.requestFocus();
                  }
                },
                child: Container(
                  margin: const EdgeInsets.fromLTRB(12, 0, 12, 6),
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: workbenchWarning.withValues(alpha: 0.08),
                    borderRadius: BorderRadius.circular(6),
                    border: Border.all(
                      color: workbenchWarning.withValues(alpha: 0.35),
                      width: 0.5,
                    ),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        _isTr ? 'Bekleyen adım' : 'Pending step',
                        style: TextStyle(
                          color: workbenchWarning,
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        _pendingAction!.message?.trim().isNotEmpty == true
                            ? _pendingAction!.message!.trim()
                            : (_isTr
                                  ? 'Bu adım için onay gerekiyor.'
                                  : 'Approval is required for this step.'),
                        style: TextStyle(color: workbenchText, fontSize: 12),
                      ),
                      const SizedBox(height: 6),
                      Container(
                        width: double.infinity,
                        padding: const EdgeInsets.all(8),
                        decoration: BoxDecoration(
                          color: workbenchBg,
                          borderRadius: BorderRadius.circular(4),
                          border: Border.all(color: workbenchBorder, width: 0.5),
                        ),
                        child: SelectableText(
                          _pendingActionPreview(),
                          style: TextStyle(
                            color: workbenchText,
                            fontSize: 12,
                            fontFamily: 'monospace',
                          ),
                        ),
                      ),
                      const SizedBox(height: 8),
                      Row(
                        children: [
                          _MiniActionButton(
                            label: _isTr ? 'Sonraki Adımı Çalıştır' : 'Run Next',
                            onTap: _continuePendingStep,
                            color: workbenchSuccess,
                            padding: const EdgeInsets.symmetric(
                              horizontal: 10,
                              vertical: 5,
                            ),
                          ),
                          const SizedBox(width: 6),
                          _MiniActionButton(
                            label: _isTr ? 'Düzenle' : 'Edit',
                            onTap: _editPendingStep,
                            color: workbenchAccent,
                            padding: const EdgeInsets.symmetric(
                              horizontal: 10,
                              vertical: 5,
                            ),
                          ),
                          const SizedBox(width: 6),
                          _MiniActionButton(
                            label: _isTr ? 'Yeniden Planla' : 'Replan',
                            onTap: _replanPendingStep,
                            color: workbenchWarning,
                            padding: const EdgeInsets.symmetric(
                              horizontal: 10,
                              vertical: 5,
                            ),
                          ),
                          const SizedBox(width: 6),
                          _MiniActionButton(
                            label: _isTr ? 'Atla' : 'Skip',
                            onTap: _skipPendingStep,
                            color: workbenchTextMuted,
                            padding: const EdgeInsets.symmetric(
                              horizontal: 10,
                              vertical: 5,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 6),
                      Text(
                        _panelShortcutsEnabled
                            ? (_isTr
                                  ? 'Kısayol için bu kutuya tıkla: Enter=Çalıştır, Ctrl+R=Yeniden planla, Esc=Atla'
                                  : 'Click this box to enable shortcuts: Enter=Run, Ctrl+R=Replan, Esc=Skip')
                            : (_isTr
                                  ? 'Güvenli mod: klavye kısayolları geçici olarak kapalı.'
                                  : 'Safe mode: keyboard shortcuts are temporarily disabled.'),
                        style: TextStyle(color: workbenchTextFaint, fontSize: 11),
                      ),
                    ],
                  ),
                ),
              ),

            // Input bar.
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: BoxDecoration(
                border: Border(
                  top: BorderSide(color: workbenchDivider, width: 0.5),
                ),
              ),
              child: Row(
                children: [
                  Icon(
                    _mode == _ChatMode.script
                        ? FluentIcons.code
                        : _mode == _ChatMode.agent
                        ? FluentIcons.command_prompt
                        : _mode == _ChatMode.explain
                        ? FluentIcons.lightbulb
                        : FluentIcons.chat,
                    size: 12,
                    color: workbenchAccent,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: TextBox(
                      controller: _inputCtrl,
                      focusNode: _inputFocus,
                      placeholder: _mode == _ChatMode.script
                          ? (_isTr
                                ? 'Script tanımla...'
                                : 'Describe your script...')
                          : _mode == _ChatMode.agent
                          ? (_isTr
                                ? 'Hedefi yaz... (agent otomatik ilerler)'
                                : 'Write the goal... (agent runs autonomously)')
                          : _mode == _ChatMode.explain
                          ? (_isTr
                                ? 'Ne hakkında sormak istiyorsun?'
                                : 'What do you want to know?')
                          : (_isTr ? 'Bir şey sor...' : 'Ask something...'),
                      placeholderStyle: TextStyle(
                        color: workbenchTextFaint,
                        fontSize: 12,
                      ),
                      style: TextStyle(color: workbenchText, fontSize: 12),
                      decoration: WidgetStateProperty.all(
                        BoxDecoration(color: Colors.transparent),
                      ),
                      onSubmitted: (v) {
                        _sendMessage(v);
                        _inputFocus.requestFocus();
                      },
                    ),
                  ),
                  const SizedBox(width: 8),
                  if (_voiceSupported) ...[
                    Tooltip(
                      message: _listening
                          ? (_isTr ? 'Dinlemeyi durdur' : 'Stop listening')
                          : (_isTr ? 'Sesli komut' : 'Voice command'),
                      child: GestureDetector(
                        onTap: _toggleVoice,
                        child: Container(
                          width: 28,
                          height: 28,
                          decoration: BoxDecoration(
                            color: _listening
                                ? workbenchSuccess
                                : (_speechReady
                                      ? workbenchHover
                                      : workbenchDanger.withValues(alpha: 0.4)),
                            borderRadius: BorderRadius.circular(6),
                          ),
                          child: Icon(
                            _listening
                                ? FluentIcons.record2
                                : FluentIcons.microphone,
                            size: 12,
                            color: _listening ? Colors.white : workbenchText,
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                  ],
                  GestureDetector(
                    onTap: () {
                      _sendMessage(_inputCtrl.text);
                      _inputFocus.requestFocus();
                    },
                    child: Container(
                      width: 28,
                      height: 28,
                      decoration: BoxDecoration(
                        color: workbenchAccent,
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: const Icon(
                        FluentIcons.send,
                        size: 12,
                        color: Colors.white,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            if (_voiceSupported && (_listening || _lastVoiceError.isNotEmpty))
              Container(
                padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
                alignment: Alignment.centerLeft,
                child: Text(
                  _listening
                      ? (_isTr
                            ? 'Dinleniyor... konuşma bitince otomatik gönderilecek.'
                            : 'Listening... it will auto-send when you stop speaking.')
                      : (_isTr
                            ? 'Sesli giriş hatası: $_lastVoiceError'
                            : 'Voice input error: $_lastVoiceError'),
                  style: TextStyle(
                    color: _listening ? workbenchSuccess : workbenchDanger,
                    fontSize: 12,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _TerminalAwaitResult {
  const _TerminalAwaitResult({
    required this.snapshot,
    required this.timedOut,
    required this.waitingInput,
  });

  final String snapshot;
  final bool timedOut;
  final bool waitingInput;
}

class _PendingEditResult {
  const _PendingEditResult({required this.value, required this.message});

  final String value;
  final String message;
}

enum _ChatMode { chat, explain, script, agent }

enum _ChatRole { user, assistant, error }

enum _AgentUiState { idle, running, waiting, paused, done }

enum _ScriptMessageAction { show, run, delete }

class _ChatMessage {
  _ChatMessage({
    String? id,
    DateTime? createdAt,
    required this.role,
    required this.text,
    this.command,
    this.scriptPath,
    this.scriptContent,
    this.stepNumber,
    this.commandResult,
  }) : id = id ?? _newChatMessageId(),
       createdAt = createdAt ?? DateTime.now();

  final String id;
  final DateTime createdAt;
  final _ChatRole role;
  final String text;
  final String? command;
  final String? scriptPath;
  final String? scriptContent;
  final int? stepNumber;
  final AiAgentCommandResult? commandResult;
}

String _newChatMessageId() {
  final now = DateTime.now();
  return '${now.microsecondsSinceEpoch}-${now.millisecondsSinceEpoch % 100000}';
}

class _ModeChip extends StatelessWidget {
  const _ModeChip({
    required this.label,
    required this.active,
    required this.onTap,
  });

  final String label;
  final bool active;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: BoxDecoration(
          color: active
              ? workbenchAccent.withValues(alpha: 0.15)
              : Colors.transparent,
          borderRadius: BorderRadius.circular(4),
          border: Border.all(
            color: active
                ? workbenchAccent.withValues(alpha: 0.3)
                : workbenchBorder,
            width: 0.5,
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            color: active ? workbenchAccent : workbenchTextMuted,
            fontSize: 12,
            fontWeight: FontWeight.w500,
          ),
        ),
      ),
    );
  }
}

class _MiniActionButton extends StatelessWidget {
  const _MiniActionButton({
    required this.label,
    required this.onTap,
    required this.color,
    this.padding = const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
  });

  final String label;
  final VoidCallback onTap;
  final Color color;
  final EdgeInsets padding;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: padding,
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.16),
          borderRadius: BorderRadius.circular(4),
          border: Border.all(color: color.withValues(alpha: 0.35), width: 0.5),
        ),
        child: Text(
          label,
          style: TextStyle(
            color: color,
            fontSize: 12,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
    );
  }
}

class _ChatBubble extends StatelessWidget {
  const _ChatBubble({
    required this.message,
    required this.isTr,
    required this.showStepLabel,
    required this.commandCardMode,
    this.onExecute,
    this.onShowScript,
    this.onRunScript,
    this.onDeleteScript,
  });

  final _ChatMessage message;
  final bool isTr;
  final bool showStepLabel;
  final String commandCardMode;
  final VoidCallback? onExecute;
  final VoidCallback? onShowScript;
  final VoidCallback? onRunScript;
  final VoidCallback? onDeleteScript;

  @override
  Widget build(BuildContext context) {
    final isUser = message.role == _ChatRole.user;
    final isError = message.role == _ChatRole.error;
    final isVisibleHandoff =
        message.commandResult?.output.contains('__LIFEOS_VISIBLE_HANDOFF__') ??
        false;
    final hasProblemResult =
        message.commandResult != null &&
        !isVisibleHandoff &&
        (!message.commandResult!.success ||
            message.commandResult!.timedOut ||
            message.commandResult!.cancelled);
    final showCommandCards = switch (commandCardMode) {
      'off' => false,
      _ => isError || hasProblemResult,
    };
    final sanitizedCommand = message.command == null
        ? null
        : TerminalTimelineText.sanitizeCommand(message.command!);

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment: isUser
            ? MainAxisAlignment.end
            : MainAxisAlignment.start,
        children: [
          if (!isUser) ...[
            Container(
              width: 22,
              height: 22,
              margin: const EdgeInsets.only(right: 8, top: 2),
              decoration: BoxDecoration(
                color: isError
                    ? workbenchDanger.withValues(alpha: 0.15)
                    : workbenchAccent.withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(6),
              ),
              child: Icon(
                isError ? FluentIcons.error_badge : FluentIcons.robot,
                size: 11,
                color: isError ? workbenchDanger : workbenchAccent,
              ),
            ),
          ],
          Flexible(
            child: Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: isUser
                    ? workbenchAccent.withValues(alpha: 0.12)
                    : isError
                    ? workbenchDanger.withValues(alpha: 0.08)
                    : workbenchHover,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (showStepLabel &&
                      message.stepNumber != null &&
                      !isUser) ...[
                    Text(
                      isTr
                          ? 'Adım ${message.stepNumber}'
                          : 'Step ${message.stepNumber}',
                      style: TextStyle(
                        color: workbenchTextMuted,
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 4),
                  ],
                  SelectableText(
                    TerminalTimelineText.sanitizeMessage(message.text),
                    style: TextStyle(
                      color: isError ? workbenchDanger : workbenchText,
                      fontSize: 12,
                      height: 1.4,
                    ),
                  ),
                  if (message.scriptPath != null &&
                      message.scriptPath!.trim().isNotEmpty) ...[
                    const SizedBox(height: 8),
                    Text(
                      isTr ? 'Script dosyası' : 'Script file',
                      style: TextStyle(
                        color: workbenchTextMuted,
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(8),
                      decoration: BoxDecoration(
                        color: workbenchBg,
                        borderRadius: BorderRadius.circular(4),
                        border: Border.all(color: workbenchBorder, width: 0.5),
                      ),
                      child: SelectableText(
                        message.scriptPath!,
                        style: TextStyle(
                          color: workbenchText,
                          fontSize: 12,
                          fontFamily: 'monospace',
                        ),
                      ),
                    ),
                    if (onShowScript != null ||
                        onRunScript != null ||
                        onDeleteScript != null) ...[
                      const SizedBox(height: 6),
                      Row(
                        children: [
                          if (onShowScript != null)
                            GestureDetector(
                              onTap: onShowScript,
                              child: Container(
                                height: 24,
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 10,
                                ),
                                decoration: BoxDecoration(
                                  color: workbenchHover,
                                  borderRadius: BorderRadius.circular(4),
                                ),
                                child: Center(
                                  child: Text(
                                    isTr ? 'Göster' : 'Show',
                                    style: TextStyle(
                                      color: workbenchTextMuted,
                                      fontSize: 12,
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          if (onRunScript != null) ...[
                            const SizedBox(width: 6),
                            GestureDetector(
                              onTap: onRunScript,
                              child: Container(
                                height: 24,
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 10,
                                ),
                                decoration: BoxDecoration(
                                  color: workbenchAccent,
                                  borderRadius: BorderRadius.circular(4),
                                ),
                                child: Center(
                                  child: Text(
                                    isTr ? 'Çalıştır' : 'Run',
                                    style: const TextStyle(
                                      color: Colors.white,
                                      fontSize: 12,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ],
                          if (onDeleteScript != null) ...[
                            const SizedBox(width: 6),
                            GestureDetector(
                              onTap: onDeleteScript,
                              child: Container(
                                height: 24,
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 10,
                                ),
                                decoration: BoxDecoration(
                                  color: workbenchDanger.withValues(
                                    alpha: 0.18,
                                  ),
                                  borderRadius: BorderRadius.circular(4),
                                  border: Border.all(
                                    color: workbenchDanger.withValues(
                                      alpha: 0.35,
                                    ),
                                    width: 0.5,
                                  ),
                                ),
                                child: Center(
                                  child: Text(
                                    isTr ? 'Sil' : 'Delete',
                                    style: TextStyle(
                                      color: workbenchDanger,
                                      fontSize: 12,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ],
                      ),
                    ],
                  ],
                  if (message.scriptContent != null &&
                      message.scriptContent!.trim().isNotEmpty) ...[
                    const SizedBox(height: 8),
                    Text(
                      isTr ? 'Script içeriği' : 'Script content',
                      style: TextStyle(
                        color: workbenchTextMuted,
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(8),
                      decoration: BoxDecoration(
                        color: workbenchBg.withValues(alpha: 0.85),
                        borderRadius: BorderRadius.circular(4),
                        border: Border.all(color: workbenchBorder, width: 0.5),
                      ),
                      child: SelectableText(
                        _trimForPreview(message.scriptContent!, max: 1600),
                        style: TextStyle(
                          color: workbenchText,
                          fontSize: 12,
                          fontFamily: 'monospace',
                        ),
                      ),
                    ),
                    const SizedBox(height: 6),
                    Row(
                      children: [
                        GestureDetector(
                          onTap: () => Clipboard.setData(
                            ClipboardData(text: message.scriptContent!),
                          ),
                          child: Container(
                            height: 24,
                            padding: const EdgeInsets.symmetric(horizontal: 10),
                            decoration: BoxDecoration(
                              color: workbenchHover,
                              borderRadius: BorderRadius.circular(4),
                            ),
                            child: Center(
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Icon(
                                    FluentIcons.copy,
                                    size: 10,
                                    color: workbenchTextMuted,
                                  ),
                                  const SizedBox(width: 4),
                                  Text(
                                    isTr ? 'Scripti Kopyala' : 'Copy Script',
                                    style: TextStyle(
                                      color: workbenchTextMuted,
                                      fontSize: 12,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ],
                  if (showCommandCards && message.command != null) ...[
                    const SizedBox(height: 8),
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(8),
                      decoration: BoxDecoration(
                        color: workbenchBg,
                        borderRadius: BorderRadius.circular(4),
                        border: Border.all(color: workbenchBorder, width: 0.5),
                      ),
                      child: SelectableText(
                        sanitizedCommand ?? '',
                        style: TextStyle(
                          color: workbenchText,
                          fontSize: 12,
                          fontFamily: 'monospace',
                        ),
                      ),
                    ),
                    const SizedBox(height: 6),
                    Row(
                      children: [
                        GestureDetector(
                          onTap: onExecute,
                          child: Container(
                            height: 24,
                            padding: const EdgeInsets.symmetric(horizontal: 10),
                            decoration: BoxDecoration(
                              color: workbenchAccent,
                              borderRadius: BorderRadius.circular(4),
                            ),
                            child: Center(
                              child: Text(
                                isTr ? 'Çalıştır' : 'Run',
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 12,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(width: 6),
                        GestureDetector(
                          onTap: () => Clipboard.setData(
                            ClipboardData(text: message.command!),
                          ),
                          child: Container(
                            height: 24,
                            padding: const EdgeInsets.symmetric(horizontal: 10),
                            decoration: BoxDecoration(
                              color: workbenchHover,
                              borderRadius: BorderRadius.circular(4),
                            ),
                            child: Center(
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Icon(
                                    FluentIcons.copy,
                                    size: 10,
                                    color: workbenchTextMuted,
                                  ),
                                  const SizedBox(width: 4),
                                  Text(
                                    isTr ? 'Kopyala' : 'Copy',
                                    style: TextStyle(
                                      color: workbenchTextMuted,
                                      fontSize: 12,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ],
                  if (showCommandCards && message.commandResult != null) ...[
                    const SizedBox(height: 8),
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(8),
                      decoration: BoxDecoration(
                        color: workbenchBg.withValues(alpha: 0.75),
                        borderRadius: BorderRadius.circular(4),
                        border: Border.all(
                          color: workbenchBorder.withValues(alpha: 0.8),
                          width: 0.5,
                        ),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            _resultMeta(message.commandResult!, isTr: isTr),
                            style: TextStyle(
                              color: workbenchTextMuted,
                              fontSize: 12,
                              fontFamily: 'monospace',
                            ),
                          ),
                          if ((message.commandResult!.output)
                              .trim()
                              .isNotEmpty) ...[
                            const SizedBox(height: 6),
                            SelectableText(
                              _trimForPreview(message.commandResult!.output),
                              style: TextStyle(
                                color: workbenchText,
                                fontSize: 12,
                                fontFamily: 'monospace',
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
          if (isUser) const SizedBox(width: 30),
        ],
      ),
    );
  }

  static String _resultMeta(AiAgentCommandResult result, {required bool isTr}) {
    final exit = result.exitCode?.toString() ?? '?';
    final cwd = (result.cwd ?? '-').trim();
    final state = result.timedOut
        ? (isTr ? 'timeout' : 'timeout')
        : result.cancelled
        ? (isTr ? 'iptal' : 'cancelled')
        : (result.success
              ? (isTr ? 'başarılı' : 'ok')
              : (isTr ? 'hata' : 'error'));
    return 'exit=$exit | ${result.durationMs}ms | cwd=$cwd | $state';
  }

  static String _trimForPreview(String output, {int max = 900}) {
    final text = TerminalTimelineText.sanitizeOutput(output).trim();
    if (text.length <= max) return text;
    return '${text.substring(0, max)}...';
  }
}
