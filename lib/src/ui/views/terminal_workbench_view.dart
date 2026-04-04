import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter/material.dart' show DefaultTabController, TabBarView;
import 'package:flutter/services.dart';
import 'package:lifeos_sftp_drive/src/i18n/app_strings.dart';
import 'package:lifeos_sftp_drive/src/services/ai_service.dart';
import 'package:lifeos_sftp_drive/src/services/snippet_service.dart';
import 'package:lifeos_sftp_drive/src/state/app_controller.dart';
import 'package:lifeos_sftp_drive/src/terminal/ssh_terminal_controller.dart';
import 'package:lifeos_sftp_drive/src/ui/terminal_themes.dart';
import 'package:lifeos_sftp_drive/src/ui/theme_tokens.dart';
import 'package:lifeos_sftp_drive/src/ui/widgets/ai_chat_panel.dart';
import 'package:lifeos_sftp_drive/src/utils/platform_utils.dart' as pu;
import 'package:lifeos_sftp_drive/src/utils/terminal_timeline_text.dart';
import 'package:xterm/xterm.dart';

class TerminalWorkbenchView extends StatefulWidget {
  const TerminalWorkbenchView({
    super.key,
    required this.controller,
    this.appController,
  });
  final SshTerminalController controller;
  final AppController? appController;
  @override
  State<TerminalWorkbenchView> createState() => _TerminalWorkbenchViewState();
}

class _TerminalWorkbenchViewState extends State<TerminalWorkbenchView> {
  final List<String> _commandHistory = [];
  int _historyIndex = -1;
  bool _showQuickPanel = false;
  bool _showSearch = false;
  bool _commandBarFocused = false;
  final _chatKey = GlobalKey<AiChatPanelState>();
  AiResponse? _aiSuggestion;
  bool _aiLoading = false;
  String? _aiError;
  String? _cachedRemoteOsInfo;
  late final TerminalController _termCtrl = TerminalController();
  final _cmdInputCtrl = TextEditingController();
  final _searchCtrl = TextEditingController();
  final _cmdInputFocus = FocusNode();

  bool get _isTr => widget.appController?.locale == AppLocale.tr;

  static const _quickCommands = [
    _QCmd('System', 'uname -a', FluentIcons.system),
    _QCmd('Disk', 'df -h', FluentIcons.hard_drive),
    _QCmd('Memory', 'free -h', FluentIcons.database),
    _QCmd('Top', 'top -bn1 | head -20', FluentIcons.processing),
    _QCmd('Network', 'ip addr', FluentIcons.globe),
    _QCmd(
      'Services',
      'systemctl list-units --type=service --state=running',
      FluentIcons.settings,
    ),
    _QCmd('Docker', 'docker ps', FluentIcons.devices3),
    _QCmd('Syslog', 'tail -50 /var/log/syslog', FluentIcons.text_document),
    _QCmd('Nginx', 'systemctl status nginx', FluentIcons.globe),
    _QCmd('Ports', 'ss -tulnp', FluentIcons.plug_connected),
    _QCmd('Users', 'who', FluentIcons.people),
    _QCmd('CPU', 'lscpu | head -20', FluentIcons.processing_run),
    _QCmd('Uptime', 'uptime', FluentIcons.timer),
    _QCmd('Files', 'pwd && ls -la', FluentIcons.folder_open),
    _QCmd('Git', 'git status', FluentIcons.branch_merge),
  ];

  @override
  void initState() {
    super.initState();
    widget.appController?.addListener(_onSettingsChanged);
    // After the first frame, force-sync terminal dimensions to the SSH session
    // so TUI apps (Codex, Claude CLI, htop) get the correct size immediately.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _forceResizeSync();
    });
  }

  /// Re-sends the real terminal dimensions to the SSH PTY.
  void _forceResizeSync() {
    final w = widget.controller.terminal.viewWidth;
    final h = widget.controller.terminal.viewHeight;
    if (w > 0 && h > 0) {
      widget.controller.terminal.onResize?.call(w, h, 0, 0);
    }
  }

  void _onSettingsChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    widget.appController?.removeListener(_onSettingsChanged);
    _termCtrl.dispose();
    _cmdInputCtrl.dispose();
    _searchCtrl.dispose();
    _cmdInputFocus.dispose();
    super.dispose();
  }

  bool get _aiEnabled => widget.appController?.aiEnabled ?? false;

  void _sendCommand(String cmd) async {
    if (cmd.trim().isEmpty) return;

    if (cmd.trim().startsWith('#') && _aiEnabled) {
      _askAi(cmd.trim().substring(1).trim());
      _cmdInputCtrl.clear();
      return;
    }

    // Smart detect
    if (_aiEnabled &&
        (widget.appController?.aiSmartDetect ?? false) &&
        looksLikeNaturalLanguage(cmd.trim())) {
      _askAi(cmd.trim());
      _cmdInputCtrl.clear();
      return;
    }

    if (!widget.controller.connected) return;
    final command = cmd.trim();
    if (!await _canRunCommandByPolicy(command)) {
      return;
    }
    if (_commandHistory.isEmpty || _commandHistory.last != command) {
      _commandHistory.add(command);
    }
    _historyIndex = -1;
    widget.controller.sendCommand(command, source: 'command_bar');
    _cmdInputCtrl.clear();
    setState(() {
      _showQuickPanel = false;
      _aiSuggestion = null;
    });
  }

  void _executeAiCommand(String cmd) async {
    if (!widget.controller.connected) return;
    final command = cmd.trim();
    if (command.isEmpty) return;
    if (!await _canRunCommandByPolicy(command)) {
      return;
    }
    if (_commandHistory.isEmpty || _commandHistory.last != command)
      _commandHistory.add(command);
    _historyIndex = -1;
    widget.controller.sendCommand(command, source: 'ai');
    setState(() => _aiSuggestion = null);
  }

  Future<bool> _canRunCommandByPolicy(String command) async {
    final dangerous = isDangerousCommand(command);
    final requireConfirm =
        dangerous && (widget.appController?.aiDangerConfirm ?? true);
    if (!requireConfirm) {
      return true;
    }
    if (!mounted) {
      return false;
    }

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => ContentDialog(
        title: Text(_isTr ? 'Tehlikeli Komut' : 'Dangerous Command'),
        content: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              _isTr
                  ? 'Bu komut sistemde kritik değişiklik yapabilir. Devam etmek istiyor musun?'
                  : 'This command can make critical changes on the system. Do you want to continue?',
            ),
            const SizedBox(height: 10),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: workbenchBg,
                borderRadius: BorderRadius.circular(6),
                border: Border.all(color: workbenchBorder, width: 0.5),
              ),
              child: SelectableText(
                command,
                style: TextStyle(
                  color: workbenchText,
                  fontSize: 12,
                  fontFamily: 'Cascadia Code',
                ),
              ),
            ),
          ],
        ),
        actions: [
          Button(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(_isTr ? 'Vazgeç' : 'Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(_isTr ? 'Devam Et' : 'Continue'),
          ),
        ],
      ),
    );
    return confirmed == true;
  }

  String _tmuxHostKey() =>
      '${widget.controller.profile.username}@${widget.controller.profile.host}:${widget.controller.profile.port}';

  String _shellQuote(String input) {
    final escaped = input.replaceAll("'", "'\"'\"'");
    return "'$escaped'";
  }

  bool _containsAny(String value, List<String> patterns) =>
      patterns.any(value.contains);

  String? _extractTmuxSessionName(String query) {
    final quoted = RegExp(r'''["']([^"']+)["']''').firstMatch(query);
    if (quoted != null) {
      return quoted.group(1)?.trim();
    }

    final lower = query.toLowerCase();
    final knownSessions =
        widget.appController?.getSshNamedSessionsForHost(_tmuxHostKey()) ??
        const ['main'];
    for (final session in knownSessions) {
      if (RegExp(
        '\\b${RegExp.escape(session.toLowerCase())}\\b',
      ).hasMatch(lower)) {
        return session;
      }
    }

    final patterns = [
      RegExp(
        r'\b(?:session|oturum|oturuma|oturumuna)\s+([a-zA-Z0-9._-]+)\b',
        caseSensitive: false,
      ),
      RegExp(
        r'\b(?:to|gec|geç|switch|attach|baglan|bağlan)\s+([a-zA-Z0-9._-]+)\b',
        caseSensitive: false,
      ),
      RegExp(
        r'\b([a-zA-Z0-9._-]+)\s+(?:oturumuna|oturuma|oturum|session)\b',
        caseSensitive: false,
      ),
    ];
    const stopWords = {
      'tmux',
      'session',
      'oturum',
      'oturuma',
      'oturumuna',
      'switch',
      'attach',
      'to',
      'gec',
      'geç',
      'baglan',
      'bağlan',
      'sil',
      'delete',
      'remove',
      'kill',
      'durdur',
      'stop',
      'kapat',
      'list',
      'listele',
      'show',
      'goster',
      'göster',
    };

    for (final pattern in patterns) {
      final match = pattern.firstMatch(query);
      final candidate = match?.group(1)?.trim();
      if (candidate == null || candidate.isEmpty) continue;
      if (stopWords.contains(candidate.toLowerCase())) continue;
      return candidate;
    }

    return null;
  }

  String _resolveTmuxSessionId(String sessionName) {
    final knownSessions =
        widget.appController?.getSshNamedSessionsForHost(_tmuxHostKey()) ??
        const ['main'];
    final named = knownSessions.firstWhere(
      (item) => item.toLowerCase() == sessionName.toLowerCase(),
      orElse: () => sessionName,
    );
    return widget.controller.tmuxSessionIdForNamedSession(named);
  }

  AiResponse? _resolveLocalTmuxIntent(String query) {
    final lower = query.toLowerCase().trim();
    final hasTmuxContext =
        lower.contains('tmux') ||
        lower.contains('oturum') ||
        lower.contains('session');
    if (!hasTmuxContext) return null;

    final isDelete = _containsAny(lower, [
      'sil',
      'delete',
      'remove',
      'kill session',
      'oturumu sil',
      'oturumu kaldır',
    ]);
    final isStop = _containsAny(lower, [
      'tmux durdur',
      'tmux kapat',
      'tmux stop',
      'stop tmux',
      'kill tmux',
    ]);
    final isList = _containsAny(lower, [
      'liste',
      'hangi',
      'goster',
      'göster',
      'list',
      'show',
      'kayıtlı',
      'kayitli',
    ]);
    final isSwitch = _containsAny(lower, [
      'geç',
      'gec',
      'switch',
      'attach',
      'bağlan',
      'baglan',
      'arasında geç',
      'between sessions',
    ]);

    if (isList) {
      return AiResponse(
        command:
            'tmux list-sessions -F "#{session_name}" 2>/dev/null || echo "${_isTr ? "tmux oturumu yok" : "no tmux session"}"',
        explanation: _isTr
            ? 'Sunucudaki kayıtlı tmux oturumlarını listeliyorum.'
            : 'Listing saved tmux sessions on the server.',
      );
    }

    if (isDelete) {
      final namedSession = _extractTmuxSessionName(query);
      if (namedSession == null) {
        return AiResponse(
          command: '',
          explanation: _isTr
              ? 'Hangi tmux oturumunu sileceğimi yaz (örnek: "prod oturumunu sil").'
              : 'Please specify which tmux session to delete (example: "delete prod session").',
        );
      }
      final sessionId = _resolveTmuxSessionId(namedSession);
      return AiResponse(
        command: 'tmux kill-session -t ${_shellQuote(sessionId)}',
        explanation: _isTr
            ? '"$namedSession" tmux oturumunu siliyorum.'
            : 'Deleting tmux session "$namedSession".',
      );
    }

    if (isStop) {
      return AiResponse(
        command: 'tmux kill-server',
        explanation: _isTr
            ? 'tmux sunucusunu ve tüm tmux oturumlarını durduruyorum.'
            : 'Stopping tmux server and all tmux sessions.',
      );
    }

    if (isSwitch) {
      final namedSession = _extractTmuxSessionName(query);
      if (namedSession == null) {
        return AiResponse(
          command: '',
          explanation: _isTr
              ? 'Geçmek istediğin tmux oturum adını yaz (örnek: "debug oturumuna geç").'
              : 'Please provide the tmux session name to switch to (example: "switch to debug").',
        );
      }
      final sessionId = _resolveTmuxSessionId(namedSession);
      final sessionQuoted = _shellQuote(sessionId);
      return AiResponse(
        command:
            'tmux switch-client -t $sessionQuoted 2>/dev/null || tmux attach-session -t $sessionQuoted',
        explanation: _isTr
            ? '"$namedSession" tmux oturumuna geçiyorum.'
            : 'Switching to tmux session "$namedSession".',
      );
    }

    return null;
  }

  void _handleAiResponse({
    required AppController app,
    required String query,
    required AiResponse response,
  }) {
    app.addAiHistory(
      AiHistoryEntry(
        query: query,
        command: response.command,
        explanation: response.explanation,
        steps: response.steps,
        provider: app.aiProvider,
        model: app.aiModel,
        timestamp: DateTime.now(),
      ),
    );

    if (response.command.trim().isNotEmpty &&
        app.aiAutoExecute &&
        !isDangerousCommand(response.command)) {
      if (mounted) {
        setState(() => _aiLoading = false);
      }
      _executeAiCommand(response.command);
      return;
    }

    if (!mounted) return;
    setState(() {
      _aiSuggestion = response;
      _aiLoading = false;
    });
  }

  Future<void> _askAi(String query) async {
    final app = widget.appController;
    if (app == null || !app.aiEnabled) return;

    setState(() {
      _aiLoading = true;
      _aiError = null;
      _aiSuggestion = null;
    });

    try {
      final localTmux = _resolveLocalTmuxIntent(query);
      if (localTmux != null) {
        _handleAiResponse(app: app, query: query, response: localTmux);
        return;
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

      final buffer = widget.controller.terminal.buffer;
      final lines = buffer.lines;
      final lineCount = lines.length;
      final startIdx = lineCount > 20 ? lineCount - 20 : 0;
      final lastOutputBuf = StringBuffer();
      for (int i = startIdx; i < lineCount; i++) {
        lastOutputBuf.writeln(lines[i].toString());
      }
      final lastOutput = lastOutputBuf.toString();

      final response = await service.ask(
        userMessage: query,
        shellName:
            '${widget.controller.profile.username}@${widget.controller.profile.host}',
        lastOutput: lastOutput,
        osInfo: _cachedRemoteOsInfo ?? 'Remote Linux server',
      );
      service.dispose();

      if (!mounted) return;
      _handleAiResponse(app: app, query: query, response: response);
    } catch (e) {
      if (mounted)
        setState(() {
          _aiError = e.toString();
          _aiLoading = false;
        });
    }
  }

  void _executeAiSuggestionWithPolicy() {
    final suggestion = _aiSuggestion;
    if (suggestion == null) {
      return;
    }
    _executeAiCommand(suggestion.command);
  }

  void _historyUp() {
    if (_commandHistory.isEmpty) return;
    if (_historyIndex == -1)
      _historyIndex = _commandHistory.length - 1;
    else if (_historyIndex > 0)
      _historyIndex--;
    _cmdInputCtrl.text = _commandHistory[_historyIndex];
    _cmdInputCtrl.selection = TextSelection.collapsed(
      offset: _cmdInputCtrl.text.length,
    );
  }

  void _historyDown() {
    if (_historyIndex == -1) return;
    if (_historyIndex < _commandHistory.length - 1) {
      _historyIndex++;
      _cmdInputCtrl.text = _commandHistory[_historyIndex];
    } else {
      _historyIndex = -1;
      _cmdInputCtrl.clear();
    }
    _cmdInputCtrl.selection = TextSelection.collapsed(
      offset: _cmdInputCtrl.text.length,
    );
  }

  void _copySelection() {
    final selection = _termCtrl.selection;
    if (selection == null) return;
    final text = widget.controller.terminal.buffer.getText(selection);
    if (text.isNotEmpty) Clipboard.setData(ClipboardData(text: text));
  }

  void _paste() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    if (data?.text != null && data!.text!.isNotEmpty) {
      widget.controller.terminal.textInput(data.text!);
    }
  }

  void _sendTerminalKey(
    TerminalKey key, {
    bool ctrl = false,
    bool alt = false,
    bool shift = false,
  }) {
    if (!widget.controller.connected) return;
    widget.controller.terminal.keyInput(
      key,
      ctrl: ctrl,
      alt: alt,
      shift: shift,
    );
  }

  void _toggleMobileKeyboard() {
    if (!pu.isMobile) return;
    final keyboardVisible = MediaQuery.of(context).viewInsets.bottom > 0;
    if (keyboardVisible) {
      FocusManager.instance.primaryFocus?.unfocus();
      _cmdInputFocus.unfocus();
      SystemChannels.textInput.invokeMethod<void>('TextInput.hide');
      return;
    }
    _cmdInputFocus.requestFocus();
    SystemChannels.textInput.invokeMethod<void>('TextInput.show');
  }

  void _showSnippetPanel() {
    final snippets = widget.appController?.snippetService.snippets ?? [];
    if (snippets.isEmpty) return;
    final searchCtrl = TextEditingController();
    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) {
          final query = searchCtrl.text.toLowerCase();
          final filtered = query.isEmpty
              ? snippets
              : snippets
                    .where(
                      (s) =>
                          s.name.toLowerCase().contains(query) ||
                          s.command.toLowerCase().contains(query),
                    )
                    .toList();
          final categories = filtered.map((s) => s.category).toSet().toList()
            ..sort();
          return ContentDialog(
            title: Text('Snippets'),
            content: SizedBox(
              width: 500,
              height: 400,
              child: Column(
                children: [
                  TextBox(
                    controller: searchCtrl,
                    placeholder: _isTr ? 'Ara...' : 'Search...',
                    style: const TextStyle(fontSize: 12),
                    onChanged: (_) => setDialogState(() {}),
                  ),
                  const SizedBox(height: 10),
                  Expanded(
                    child: ListView(
                      children: [
                        for (final cat in categories) ...[
                          Padding(
                            padding: EdgeInsets.symmetric(vertical: 4),
                            child: Text(
                              cat,
                              style: TextStyle(
                                color: workbenchAccent,
                                fontSize: 11,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                          for (final s in filtered.where(
                            (s) => s.category == cat,
                          ))
                            _SnippetRow(
                              snippet: s,
                              onRun: () {
                                Navigator.pop(ctx);
                                _sendCommand(s.command);
                              },
                            ),
                        ],
                      ],
                    ),
                  ),
                ],
              ),
            ),
            actions: [
              Button(
                onPressed: () => Navigator.pop(ctx),
                child: Text(_isTr ? 'Kapat' : 'Close'),
              ),
            ],
          );
        },
      ),
    );
  }

  void _toggleSearch() => setState(() {
    _showSearch = !_showSearch;
    if (!_showSearch) _searchCtrl.clear();
  });

  String _timelineTypeLabel(String type) {
    switch (type) {
      case 'command':
        return _isTr ? 'Komut' : 'Command';
      case 'output':
        return _isTr ? 'Çıktı' : 'Output';
      case 'connected':
      case 'connect_start':
        return _isTr ? 'Bağlantı' : 'Connection';
      case 'reconnect_attempt':
      case 'reconnect_success':
      case 'reconnect_failed':
      case 'reconnect_scheduled':
        return _isTr ? 'Yeniden Bağlan' : 'Reconnect';
      case 'tmux_switch':
      case 'tmux_delete':
      case 'tmux_new':
      case 'tmux_attach':
        return 'tmux';
      default:
        return type;
    }
  }

  String _timelineTimeLabel(DateTime value) {
    String two(int v) => v.toString().padLeft(2, '0');
    return '${two(value.hour)}:${two(value.minute)}:${two(value.second)}';
  }

  Color _timelineTypeColor(String type) {
    switch (type) {
      case 'command':
        return workbenchAccent;
      case 'output':
        return const Color(0xFF4AA8FF);
      case 'connected':
      case 'connect_start':
        return const Color(0xFF52D273);
      case 'reconnect_attempt':
      case 'reconnect_success':
      case 'reconnect_failed':
      case 'reconnect_scheduled':
        return const Color(0xFFF5A742);
      case 'tmux_switch':
      case 'tmux_delete':
      case 'tmux_new':
      case 'tmux_attach':
        return const Color(0xFFB884FF);
      default:
        return workbenchTextMuted;
    }
  }

  IconData _timelineTypeIcon(String type) {
    switch (type) {
      case 'command':
        return FluentIcons.chevron_right_med;
      case 'output':
        return FluentIcons.info;
      case 'connected':
      case 'connect_start':
        return FluentIcons.plug_connected;
      case 'reconnect_attempt':
      case 'reconnect_success':
      case 'reconnect_failed':
      case 'reconnect_scheduled':
        return FluentIcons.sync;
      case 'tmux_switch':
      case 'tmux_delete':
      case 'tmux_new':
      case 'tmux_attach':
        return FluentIcons.sync;
      default:
        return FluentIcons.info;
    }
  }

  List<String> _buildMergedCommandHistory(Iterable<String> timelineCommands) {
    final merged = [..._commandHistory];
    for (final raw in timelineCommands) {
      final cmd = TerminalTimelineText.sanitizeCommand(raw);
      if (cmd.isEmpty) {
        continue;
      }
      if (merged.isEmpty || merged.last != cmd) {
        merged.add(cmd);
      }
    }
    return merged;
  }

  Widget _buildTimelineEventTile({
    required BuildContext ctx,
    required TerminalSessionEvent event,
    required String message,
  }) {
    final canReplayCommand =
        event.type == 'command' && message.trim().isNotEmpty;
    final typeColor = _timelineTypeColor(event.type);
    final mono = event.type == 'command' || event.type == 'output';

    return GestureDetector(
      onTap: canReplayCommand
          ? () {
              Navigator.pop(ctx);
              _sendCommand(message.trim());
            }
          : null,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        decoration: BoxDecoration(
          color: workbenchHover.withValues(
            alpha: event.type == 'output' ? 0.18 : 0.32,
          ),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: typeColor.withValues(alpha: 0.26),
            width: 0.6,
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(_timelineTypeIcon(event.type), size: 11, color: typeColor),
                const SizedBox(width: 6),
                Text(
                  _timelineTypeLabel(event.type),
                  style: TextStyle(
                    color: typeColor,
                    fontSize: 10,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  _timelineTimeLabel(event.timestamp),
                  style: TextStyle(color: workbenchTextFaint, fontSize: 10),
                ),
                const Spacer(),
                if (canReplayCommand)
                  Text(
                    _isTr ? 'Tekrar Çalıştır' : 'Replay',
                    style: TextStyle(
                      color: workbenchAccent,
                      fontSize: 10,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              message,
              maxLines: event.type == 'output' ? 5 : 3,
              overflow: TextOverflow.ellipsis,
              softWrap: true,
              style: TextStyle(
                color: workbenchText,
                fontSize: 12,
                height: 1.35,
                fontFamily: mono ? 'Cascadia Code' : null,
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _showContextMenu(Offset pos) {
    showBoundedContextMenu(
      context,
      pos,
      _buildCtxMenu,
      menuWidth: 220,
      menuHeight: 350,
    );
  }

  Widget _buildCtxMenu(VoidCallback onDone) {
    return Container(
      width: 220,
      decoration: BoxDecoration(
        color: workbenchMenuBg,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: workbenchBorder, width: 0.5),
        boxShadow: menuShadow,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          _CtxRow(
            icon: FluentIcons.copy,
            label: _isTr ? 'Kopyala' : 'Copy',
            shortcut: 'Ctrl+Shift+C',
            onTap: () {
              onDone();
              _copySelection();
            },
          ),
          _CtxRow(
            icon: FluentIcons.paste,
            label: _isTr ? 'Yapıştır' : 'Paste',
            shortcut: 'Ctrl+Shift+V',
            onTap: () {
              onDone();
              _paste();
            },
          ),
          Container(
            height: 0.5,
            margin: EdgeInsets.symmetric(horizontal: 8),
            color: workbenchBorder,
          ),
          _CtxRow(
            icon: FluentIcons.search,
            label: _isTr ? 'Ara' : 'Search',
            shortcut: 'Ctrl+F',
            onTap: () {
              onDone();
              _toggleSearch();
            },
          ),
          _CtxRow(
            icon: FluentIcons.clear_selection,
            label: _isTr ? 'Temizle' : 'Clear',
            onTap: () {
              onDone();
              widget.controller.terminal.buffer.clear();
              widget.controller.terminal.buffer.setCursor(0, 0);
            },
          ),
          Container(
            height: 0.5,
            margin: EdgeInsets.symmetric(horizontal: 8),
            color: workbenchBorder,
          ),
          _CtxRow(
            icon: FluentIcons.lightning_bolt,
            label: _isTr ? 'Hızlı Komutlar' : 'Quick Commands',
            onTap: () {
              onDone();
              setState(() => _showQuickPanel = !_showQuickPanel);
            },
          ),
          _CtxRow(
            icon: FluentIcons.history,
            label: _isTr ? 'Geçmiş' : 'History',
            onTap: () {
              onDone();
              _showHistoryDialog();
            },
          ),
          Container(
            height: 0.5,
            margin: EdgeInsets.symmetric(horizontal: 8),
            color: workbenchBorder,
          ),
          _CtxRow(
            icon: FluentIcons.plug_disconnected,
            label: _isTr ? 'Yeniden Bağlan' : 'Reconnect',
            onTap: () {
              onDone();
              if (widget.controller.connected ||
                  widget.controller.reconnecting) {
                widget.controller
                    .disconnect(manual: true)
                    .then((_) => widget.controller.connect());
              } else {
                widget.controller.connect();
              }
            },
          ),
        ],
      ),
    );
  }

  void _showHistoryDialog() {
    final aiHistory = widget.appController?.aiHistory ?? [];
    final rawTimeline = widget.controller.sessionEvents;
    final timelineItems = <Map<String, Object>>[];
    for (final event in rawTimeline.reversed) {
      final cleanMessage = TerminalTimelineText.sanitizeMessage(event.message);
      if (cleanMessage.isEmpty) {
        continue;
      }
      timelineItems.add({'event': event, 'message': cleanMessage});
    }
    final mergedCommandHistory = _buildMergedCommandHistory(
      rawTimeline
          .where((event) => event.type == 'command')
          .map((event) => event.message),
    );

    if (mergedCommandHistory.isEmpty &&
        aiHistory.isEmpty &&
        timelineItems.isEmpty) {
      return;
    }
    showDialog(
      context: context,
      builder: (ctx) => ContentDialog(
        title: Text(_isTr ? 'Geçmiş' : 'History'),
        content: SizedBox(
          width: 560,
          height: 400,
          child: DefaultTabController(
            length: 3,
            child: Column(
              children: [
                Container(
                  height: 32,
                  decoration: BoxDecoration(
                    border: Border(
                      bottom: BorderSide(color: workbenchDivider, width: 0.5),
                    ),
                  ),
                  child: Row(
                    children: [
                      _HistoryTabBtn(
                        label: _isTr ? 'Komutlar' : 'Commands',
                        count: mergedCommandHistory.length,
                        index: 0,
                      ),
                      _HistoryTabBtn(
                        label: _isTr ? 'AI Geçmişi' : 'AI History',
                        count: aiHistory.length,
                        index: 1,
                      ),
                      _HistoryTabBtn(
                        label: 'Timeline',
                        count: timelineItems.length,
                        index: 2,
                      ),
                    ],
                  ),
                ),
                Expanded(
                  child: TabBarView(
                    children: [
                      ListView.builder(
                        itemCount: mergedCommandHistory.length,
                        itemBuilder: (_, i) {
                          final idx = mergedCommandHistory.length - 1 - i;
                          return _HistoryRow(
                            cmd: mergedCommandHistory[idx],
                            onTap: () {
                              Navigator.pop(ctx);
                              _sendCommand(mergedCommandHistory[idx]);
                            },
                          );
                        },
                      ),
                      aiHistory.isEmpty
                          ? Center(
                              child: Text(
                                _isTr
                                    ? 'Henüz AI geçmişi yok'
                                    : 'No AI history yet',
                                style: TextStyle(
                                  color: workbenchTextMuted,
                                  fontSize: 12,
                                ),
                              ),
                            )
                          : ListView.builder(
                              itemCount: aiHistory.length,
                              itemBuilder: (_, i) => _AiHistoryRow(
                                entry: aiHistory[i],
                                isTr: _isTr,
                                onExecute: () {
                                  Navigator.pop(ctx);
                                  _executeAiCommand(aiHistory[i].command);
                                },
                                onUseQuery: () {
                                  Navigator.pop(ctx);
                                  _cmdInputCtrl.text =
                                      '# ${aiHistory[i].query}';
                                  _cmdInputFocus.requestFocus();
                                },
                              ),
                            ),
                      timelineItems.isEmpty
                          ? Center(
                              child: Text(
                                _isTr
                                    ? 'Henüz timeline kaydı yok'
                                    : 'No timeline events yet',
                                style: TextStyle(
                                  color: workbenchTextMuted,
                                  fontSize: 12,
                                ),
                              ),
                            )
                          : ListView.separated(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 8,
                                vertical: 8,
                              ),
                              cacheExtent: 600,
                              itemCount: timelineItems.length,
                              separatorBuilder: (_, _) =>
                                  const SizedBox(height: 6),
                              itemBuilder: (_, i) {
                                final item = timelineItems[i];
                                final event =
                                    item['event']! as TerminalSessionEvent;
                                final message = item['message']! as String;
                                return _buildTimelineEventTile(
                                  ctx: ctx,
                                  event: event,
                                  message: message,
                                );
                              },
                            ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
        actions: [
          if (aiHistory.isNotEmpty)
            Button(
              onPressed: () {
                widget.appController?.clearAiHistory();
                Navigator.pop(ctx);
              },
              child: Text(_isTr ? 'AI Geçmişini Temizle' : 'Clear AI History'),
            ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(_isTr ? 'Kapat' : 'Close'),
          ),
        ],
      ),
    );
  }

  Future<void> _showTmuxSessionPicker() async {
    if (!widget.controller.connected) return;
    final app = widget.appController;
    final hostKey = _tmuxHostKey();

    final sessions = <String>[
      ...(app?.getSshNamedSessionsForHost(hostKey) ?? const ['main']),
    ];
    if (!sessions.contains(widget.controller.tmuxNamedSession)) {
      sessions.add(widget.controller.tmuxNamedSession);
    }

    var active =
        app?.getSshActiveSessionNameForHost(hostKey) ??
        widget.controller.tmuxNamedSession;
    if (!sessions.contains(active)) {
      sessions.add(active);
    }

    final newSessionCtrl = TextEditingController();
    try {
      void switchTo(BuildContext dialogContext, String sessionName) {
        app?.setSshActiveSessionNameForHost(hostKey, sessionName);
        widget.controller.switchTmuxNamedSession(sessionName);
        Navigator.pop(dialogContext);
      }

      Future<void> deleteSession(
        BuildContext dialogContext,
        StateSetter setDialogState,
        String sessionName,
      ) async {
        if (sessions.length <= 1) {
          return;
        }
        final confirmed = await showDialog<bool>(
          context: dialogContext,
          builder: (confirmCtx) => ContentDialog(
            title: Text(_isTr ? 'Oturumu Sil' : 'Delete Session'),
            content: Text(
              _isTr
                  ? '"$sessionName" tmux oturumunu silmek istiyor musun?'
                  : 'Do you want to delete tmux session "$sessionName"?',
            ),
            actions: [
              Button(
                onPressed: () => Navigator.pop(confirmCtx, false),
                child: Text(_isTr ? 'İptal' : 'Cancel'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(confirmCtx, true),
                child: Text(_isTr ? 'Sil' : 'Delete'),
              ),
            ],
          ),
        );
        if (confirmed != true) {
          return;
        }

        final fallbackSession = sessions.firstWhere(
          (s) => s != sessionName,
          orElse: () => 'main',
        );
        widget.controller.removeTmuxNamedSession(
          sessionName,
          fallbackNamedSession: fallbackSession,
        );

        final refreshed = <String>[
          ...(app?.getSshNamedSessionsForHost(hostKey) ?? const ['main']),
        ];
        var refreshedActive =
            app?.getSshActiveSessionNameForHost(hostKey) ?? refreshed.first;
        if (!refreshed.contains(refreshedActive)) {
          refreshedActive = refreshed.first;
        }

        setDialogState(() {
          sessions
            ..clear()
            ..addAll(refreshed);
          active = refreshedActive;
        });
      }

      Widget buildPickerBody(
        BuildContext dialogContext,
        StateSetter setDialogState,
      ) {
        return Column(
          children: [
            Align(
              alignment: Alignment.centerLeft,
              child: Text(
                _isTr
                    ? 'Seçtiğin oturum kalıcı olur ve sonraki açılışta otomatik açılır.'
                    : 'Selected session is remembered and auto-opened on next connect.',
                style: TextStyle(color: workbenchTextMuted, fontSize: 11),
              ),
            ),
            const SizedBox(height: 10),
            Expanded(
              child: ListView.builder(
                itemCount: sessions.length,
                itemBuilder: (_, i) {
                  final sessionName = sessions[i];
                  final isActive = sessionName == active;
                  return Container(
                    margin: const EdgeInsets.only(bottom: 6),
                    decoration: BoxDecoration(
                      color: isActive
                          ? workbenchAccent.withValues(alpha: 0.15)
                          : workbenchHover,
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(
                        color: isActive
                            ? workbenchAccent.withValues(alpha: 0.45)
                            : workbenchBorder,
                        width: 0.6,
                      ),
                    ),
                    child: Row(
                      children: [
                        Expanded(
                          child: GestureDetector(
                            behavior: HitTestBehavior.opaque,
                            onTap: () => switchTo(dialogContext, sessionName),
                            child: Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 10,
                                vertical: 8,
                              ),
                              child: Text(
                                sessionName,
                                style: TextStyle(
                                  color: isActive
                                      ? workbenchAccent
                                      : workbenchText,
                                  fontSize: 12,
                                  fontWeight: isActive
                                      ? FontWeight.w600
                                      : FontWeight.w500,
                                ),
                              ),
                            ),
                          ),
                        ),
                        if (isActive)
                          const Padding(
                            padding: EdgeInsets.only(right: 2),
                            child: Icon(FluentIcons.accept_medium, size: 12),
                          ),
                        IconButton(
                          icon: Icon(
                            FluentIcons.delete,
                            size: 11,
                            color: sessions.length <= 1
                                ? workbenchTextFaint
                                : workbenchDanger,
                          ),
                          onPressed: sessions.length <= 1
                              ? null
                              : () => deleteSession(
                                  dialogContext,
                                  setDialogState,
                                  sessionName,
                                ),
                        ),
                      ],
                    ),
                  );
                },
              ),
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                Expanded(
                  child: TextBox(
                    controller: newSessionCtrl,
                    placeholder: _isTr
                        ? 'Yeni oturum adı (örn: deploy)'
                        : 'New session name (e.g. deploy)',
                    onSubmitted: (_) {
                      final value = newSessionCtrl.text.trim();
                      if (value.isEmpty) return;
                      if (!sessions.contains(value)) {
                        setDialogState(() => sessions.add(value));
                      }
                      active = value;
                      app?.setSshNamedSessionsForHost(hostKey, sessions);
                      switchTo(dialogContext, value);
                    },
                  ),
                ),
                const SizedBox(width: 8),
                Button(
                  onPressed: () {
                    final value = newSessionCtrl.text.trim();
                    if (value.isEmpty) return;
                    if (!sessions.contains(value)) {
                      setDialogState(() => sessions.add(value));
                    }
                    active = value;
                    app?.setSshNamedSessionsForHost(hostKey, sessions);
                    switchTo(dialogContext, value);
                  },
                  child: Text(_isTr ? 'Ekle' : 'Add'),
                ),
              ],
            ),
          ],
        );
      }

      if (pu.isMobile) {
        await showDialog(
          context: context,
          builder: (ctx) => StatefulBuilder(
            builder: (ctx, setDialogState) {
              final bottomInset = MediaQuery.of(ctx).viewInsets.bottom;
              final safeBottom = MediaQuery.of(ctx).padding.bottom;
              final bottomPadding =
                  (safeBottom > 10 ? safeBottom : 10) + bottomInset;
              return Align(
                alignment: Alignment.bottomCenter,
                child: Padding(
                  padding: EdgeInsets.fromLTRB(10, 10, 10, bottomPadding),
                  child: ConstrainedBox(
                    constraints: BoxConstraints(
                      maxWidth: 760,
                      maxHeight: MediaQuery.of(ctx).size.height * 0.88,
                    ),
                    child: Container(
                      decoration: BoxDecoration(
                        color: workbenchPanel,
                        borderRadius: BorderRadius.circular(14),
                        border: Border.all(color: workbenchBorder, width: 0.6),
                        boxShadow: menuShadow,
                      ),
                      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Container(
                            width: 36,
                            height: 4,
                            decoration: BoxDecoration(
                              color: workbenchTextFaint.withValues(alpha: 0.45),
                              borderRadius: BorderRadius.circular(2),
                            ),
                          ),
                          const SizedBox(height: 10),
                          Row(
                            children: [
                              Expanded(
                                child: Text(
                                  _isTr ? 'tmux Oturumları' : 'tmux Sessions',
                                  style: TextStyle(
                                    color: workbenchText,
                                    fontSize: 14,
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                              ),
                              IconButton(
                                icon: const Icon(
                                  FluentIcons.chrome_close,
                                  size: 12,
                                ),
                                onPressed: () => Navigator.pop(ctx),
                              ),
                            ],
                          ),
                          const SizedBox(height: 8),
                          Flexible(child: buildPickerBody(ctx, setDialogState)),
                        ],
                      ),
                    ),
                  ),
                ),
              );
            },
          ),
        );
      } else {
        await showDialog(
          context: context,
          builder: (ctx) => StatefulBuilder(
            builder: (ctx, setDialogState) => ContentDialog(
              title: Text(_isTr ? 'tmux Oturumları' : 'tmux Sessions'),
              content: SizedBox(
                width: 420,
                height: 320,
                child: buildPickerBody(ctx, setDialogState),
              ),
              actions: [
                Button(
                  onPressed: () => Navigator.pop(ctx),
                  child: Text(_isTr ? 'Kapat' : 'Close'),
                ),
              ],
            ),
          ),
        );
      }
    } finally {
      newSessionCtrl.dispose();
    }
  }

  @override
  Widget build(BuildContext context) {
    final fontFamily =
        widget.appController?.terminalFontFamily ?? 'Cascadia Code';
    final fontSize = widget.appController?.terminalFontSize ?? 15.0;
    final lineHeight = widget.appController?.terminalLineHeight ?? 1.35;

    final isDark = widget.appController?.isDarkMode ?? true;
    final effectActive =
        isDark && (widget.appController?.windowEffect ?? 'none') != 'none';
    final opacity = widget.appController?.windowOpacity ?? 1.0;
    final schemeName =
        widget.appController?.terminalTheme ??
        (isDark ? 'LifeOS Gate' : 'LifeOS Light');
    final scheme =
        terminalSchemes[schemeName] ??
        terminalSchemes[isDark ? 'LifeOS Gate' : 'LifeOS Light']!;
    final bgOverride = effectActive
        ? TransparentTheme(effectActive: true, opacity: opacity).terminalBg
        : null;
    final tTheme = scheme.toTheme(backgroundOverride: bgOverride);
    final bgOpacity = effectActive ? opacity * 0.75 : 1.0;
    final isMobile = pu.isMobile;
    final compactHeader = isMobile;
    final terminalAutofocus = pu.isDesktop && !_commandBarFocused;
    final keyboardInset = isMobile
        ? MediaQuery.of(context).viewInsets.bottom
        : 0.0;
    final keyboardVisible = keyboardInset > 0;
    return Column(
      children: [
        // ─── Header ────────────────────────────────────────────────
        AnimatedBuilder(
          animation: widget.controller,
          builder: (_, __) {
            final isConnected = widget.controller.connected;
            final isReconnecting =
                widget.controller.reconnecting && !isConnected;
            final isConnecting =
                widget.controller.connecting && !isConnected && !isReconnecting;
            final reconnectMax =
                widget.appController?.sshReconnectMaxAttempts ?? 8;
            final reconnectAttempt = widget.controller.reconnectAttempt;
            final statusText = isConnected
                ? (_isTr ? 'Bağlı' : 'Connected')
                : isReconnecting
                ? (reconnectAttempt > 0
                      ? (_isTr
                            ? 'Yeniden bağlanıyor ($reconnectAttempt/$reconnectMax)...'
                            : 'Reconnecting ($reconnectAttempt/$reconnectMax)...')
                      : (_isTr ? 'Yeniden bağlanıyor...' : 'Reconnecting...'))
                : isConnecting
                ? (_isTr ? 'Bağlanıyor...' : 'Connecting...')
                : (_isTr ? 'Bağlı değil' : 'Disconnected');
            final statusColor = isConnected
                ? workbenchSuccess
                : (isReconnecting || isConnecting)
                ? workbenchWarning
                : workbenchTextMuted;
            final statusDotColor = (isReconnecting || isConnecting)
                ? workbenchWarning
                : isConnected
                ? workbenchSuccess
                : workbenchDanger;

            return Container(
              height: 40,
              padding: const EdgeInsets.symmetric(horizontal: 16),
              decoration: BoxDecoration(
                border: Border(
                  bottom: BorderSide(color: workbenchDivider, width: 0.5),
                ),
              ),
              child: Row(
                children: [
                  Container(
                    width: 10,
                    height: 10,
                    decoration: BoxDecoration(
                      color: statusDotColor,
                      shape: BoxShape.circle,
                      boxShadow: [
                        BoxShadow(
                          color: statusDotColor.withValues(alpha: 0.4),
                          blurRadius: 6,
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      '${widget.controller.profile.username}@${widget.controller.profile.host}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: workbenchText,
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 6,
                      vertical: 2,
                    ),
                    decoration: BoxDecoration(
                      color: workbenchHover,
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: Text(
                      statusText,
                      style: TextStyle(
                        color: statusColor,
                        fontSize: 10,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ),
                  if (widget.controller.insideTmux) ...[
                    const SizedBox(width: 6),
                    GestureDetector(
                      onTap: _showTmuxSessionPicker,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 6,
                          vertical: 2,
                        ),
                        decoration: BoxDecoration(
                          color: workbenchAccent.withValues(alpha: 0.15),
                          borderRadius: BorderRadius.circular(4),
                          border: Border.all(
                            color: workbenchAccent.withValues(alpha: 0.35),
                            width: 0.5,
                          ),
                        ),
                        child: Row(
                          children: [
                            Text(
                              'tmux:${widget.controller.tmuxNamedSession}',
                              style: TextStyle(
                                color: workbenchAccent,
                                fontSize: 10,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            const SizedBox(width: 4),
                            Icon(
                              FluentIcons.chevron_down_small,
                              size: 10,
                              color: workbenchAccent,
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                  if (!compactHeader) const Spacer(),
                  if (widget.controller.error != null)
                    Flexible(
                      child: Padding(
                        padding: const EdgeInsets.only(right: 10),
                        child: Text(
                          widget.controller.error!,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: workbenchDanger,
                            fontSize: 11,
                          ),
                        ),
                      ),
                    ),
                  _HeaderBtn(
                    icon: FluentIcons.lightning_bolt,
                    tooltip: _isTr ? 'Hızlı Komutlar' : 'Quick Commands',
                    active: _showQuickPanel,
                    onTap: () =>
                        setState(() => _showQuickPanel = !_showQuickPanel),
                  ),
                  const SizedBox(width: 4),
                  if (!compactHeader) ...[
                    _HeaderBtn(
                      icon: FluentIcons.code,
                      tooltip: 'Snippets',
                      onTap: () => _showSnippetPanel(),
                    ),
                    const SizedBox(width: 4),
                  ],
                  if (_aiEnabled) ...[
                    _HeaderBtn(
                      icon: FluentIcons.robot,
                      tooltip: _isTr ? 'AI Sohbet' : 'AI Chat',
                      onTap: () => _chatKey.currentState?.toggle(),
                    ),
                    const SizedBox(width: 4),
                    if (!compactHeader) ...[
                      _HeaderBtn(
                        icon: FluentIcons.lightbulb,
                        tooltip: _isTr ? 'Çıktıyı Açıkla' : 'Explain Output',
                        onTap: () => _chatKey.currentState?.explainLastOutput(),
                      ),
                      const SizedBox(width: 4),
                    ],
                  ],
                  _HeaderBtn(
                    icon: FluentIcons.search,
                    tooltip: _isTr ? 'Ara' : 'Search',
                    active: _showSearch,
                    onTap: _toggleSearch,
                  ),
                  const SizedBox(width: 4),
                  _HeaderBtn(
                    icon: FluentIcons.history,
                    tooltip: _isTr ? 'Geçmiş' : 'History',
                    onTap: _showHistoryDialog,
                  ),
                  if (!compactHeader) ...[
                    const SizedBox(width: 4),
                    _HeaderBtn(
                      icon: FluentIcons.clear_selection,
                      tooltip: _isTr ? 'Temizle' : 'Clear',
                      onTap: () {
                        widget.controller.terminal.buffer.clear();
                        widget.controller.terminal.buffer.setCursor(0, 0);
                      },
                    ),
                  ],
                  const SizedBox(width: 8),
                  GestureDetector(
                    onTap: widget.controller.connecting
                        ? null
                        : () {
                            if (widget.controller.connected ||
                                widget.controller.reconnecting) {
                              widget.controller
                                  .disconnect(manual: true)
                                  .then((_) => widget.controller.connect());
                            } else {
                              widget.controller.connect();
                            }
                          },
                    child: Container(
                      height: 26,
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                      decoration: BoxDecoration(
                        color:
                            (widget.controller.connected ||
                                widget.controller.reconnecting)
                            ? workbenchPanelAlt
                            : workbenchAccent,
                        borderRadius: BorderRadius.circular(5),
                      ),
                      child: Center(
                        child: compactHeader
                            ? Icon(
                                FluentIcons.sync,
                                size: 12,
                                color: Colors.white,
                              )
                            : Text(
                                (widget.controller.connected ||
                                        widget.controller.reconnecting)
                                    ? (_isTr ? 'Yeniden Bağlan' : 'Reconnect')
                                    : (_isTr ? 'Bağlan' : 'Connect'),
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 11,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                      ),
                    ),
                  ),
                ],
              ),
            );
          },
        ),

        // ─── Search Bar ────────────────────────────────────────────
        if (_showSearch)
          Container(
            height: 40,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            decoration: BoxDecoration(
              color: workbenchEditorBg,
              border: Border(
                bottom: BorderSide(
                  color: workbenchAccent.withValues(alpha: 0.3),
                  width: 1,
                ),
              ),
            ),
            child: Row(
              children: [
                Icon(FluentIcons.search, size: 12, color: workbenchTextMuted),
                const SizedBox(width: 8),
                Expanded(
                  child: TextBox(
                    controller: _searchCtrl,
                    autofocus: true,
                    placeholder: _isTr
                        ? 'Terminal içinde ara...'
                        : 'Search in terminal...',
                    placeholderStyle: TextStyle(
                      color: workbenchTextFaint,
                      fontSize: 12,
                    ),
                    style: TextStyle(color: workbenchText, fontSize: 12),
                    decoration: WidgetStateProperty.all(
                      BoxDecoration(color: Colors.transparent),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                GestureDetector(
                  onTap: _toggleSearch,
                  child: Icon(
                    FluentIcons.chrome_close,
                    size: 10,
                    color: workbenchTextMuted,
                  ),
                ),
              ],
            ),
          ),

        // ─── Quick Commands ────────────────────────────────────────
        if (_showQuickPanel)
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
              color: workbenchEditorBg,
              border: Border(
                bottom: BorderSide(color: workbenchDivider, width: 0.5),
              ),
            ),
            child: Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                for (final cmd in _quickCommands)
                  _QuickCmdChip(
                    cmd: cmd,
                    onTap: () => _sendCommand(cmd.command),
                  ),
              ],
            ),
          ),

        // ─── Terminal ──────────────────────────────────────────────
        Expanded(
          child: Listener(
            onPointerDown: (event) {
              if (event.buttons == 2) _showContextMenu(event.position);
            },
            child: FocusScope(
              autofocus: terminalAutofocus,
              child: TerminalView(
                widget.controller.terminal,
                key: ValueKey('term_${schemeName}_${fontSize}_$fontFamily'),
                controller: _termCtrl,
                autofocus: terminalAutofocus,
                hardwareKeyboardOnly: pu.isDesktop,
                theme: tTheme,
                backgroundOpacity: bgOpacity,
                textStyle: TerminalStyle(
                  fontSize: fontSize,
                  height: lineHeight,
                  fontFamily: fontFamily,
                  fontFamilyFallback: const [
                    'Cascadia Code',
                    'Cascadia Mono',
                    'Consolas',
                    'JetBrains Mono',
                    'Fira Code',
                    'Source Code Pro',
                    'DejaVu Sans Mono',
                    'Menlo',
                    'Liberation Mono',
                    'Noto Sans Mono',
                    'monospace',
                  ],
                ),
              ),
            ),
          ),
        ),

        // ─── AI Chat Panel ────────────────────────────────────────
        if (widget.appController != null)
          AiChatPanel(
            key: _chatKey,
            appController: widget.appController!,
            terminal: widget.controller.terminal,
            shellName:
                '${widget.controller.profile.username}@${widget.controller.profile.host}',
            osInfo: _cachedRemoteOsInfo ?? 'Remote Linux server',
            isRemote: true,
            scopeHost: widget.controller.profile.host,
            scopeTmuxSession: widget.controller.tmuxNamedSession,
            onExecuteCommand: _executeAiCommand,
          ),

        // ─── AI Suggestion ─────────────────────────────────────────
        if (_aiLoading)
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            decoration: BoxDecoration(
              color: workbenchEditorBg,
              border: Border(
                top: BorderSide(color: workbenchDivider, width: 0.5),
              ),
            ),
            child: Row(
              children: [
                const SizedBox(
                  width: 16,
                  height: 16,
                  child: ProgressRing(strokeWidth: 2),
                ),
                const SizedBox(width: 10),
                Text(
                  _isTr ? 'AI düşünüyor...' : 'AI is thinking...',
                  style: TextStyle(color: workbenchTextMuted, fontSize: 12),
                ),
              ],
            ),
          ),
        if (_aiError != null)
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            decoration: BoxDecoration(
              color: workbenchEditorBg,
              border: Border(
                top: BorderSide(color: workbenchDivider, width: 0.5),
              ),
            ),
            child: Row(
              children: [
                Icon(FluentIcons.error_badge, size: 12, color: workbenchDanger),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    _aiError!,
                    style: TextStyle(color: workbenchDanger, fontSize: 11),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                GestureDetector(
                  onTap: () => setState(() => _aiError = null),
                  child: Icon(
                    FluentIcons.chrome_close,
                    size: 10,
                    color: workbenchTextFaint,
                  ),
                ),
              ],
            ),
          ),
        if (_aiSuggestion != null)
          Container(
            padding: const EdgeInsets.all(12),
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
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(FluentIcons.robot, size: 12, color: workbenchAccent),
                    const SizedBox(width: 8),
                    Text(
                      'AI',
                      style: TextStyle(
                        color: workbenchAccent,
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const Spacer(),
                    if (isDangerousCommand(_aiSuggestion!.command))
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 6,
                          vertical: 2,
                        ),
                        decoration: BoxDecoration(
                          color: workbenchDanger.withValues(alpha: 0.15),
                          borderRadius: BorderRadius.circular(3),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              FluentIcons.warning,
                              size: 10,
                              color: workbenchDanger,
                            ),
                            const SizedBox(width: 4),
                            Text(
                              _isTr ? 'Tehlikeli' : 'Dangerous',
                              style: TextStyle(
                                color: workbenchDanger,
                                fontSize: 9,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ],
                        ),
                      ),
                    const SizedBox(width: 8),
                    GestureDetector(
                      onTap: () => setState(() => _aiSuggestion = null),
                      child: Icon(
                        FluentIcons.chrome_close,
                        size: 10,
                        color: workbenchTextFaint,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: workbenchBg,
                    borderRadius: BorderRadius.circular(6),
                    border: Border.all(color: workbenchBorder, width: 0.5),
                  ),
                  child: SelectableText(
                    _aiSuggestion!.command,
                    style: TextStyle(
                      color: workbenchText,
                      fontSize: 13,
                      fontFamily:
                          widget.appController?.terminalFontFamily ??
                          'monospace',
                    ),
                  ),
                ),
                if (_aiSuggestion!.explanation != null) ...[
                  SizedBox(height: 6),
                  Text(
                    _aiSuggestion!.explanation!,
                    style: TextStyle(color: workbenchTextMuted, fontSize: 11),
                  ),
                ],
                const SizedBox(height: 10),
                Row(
                  children: [
                    GestureDetector(
                      onTap: _executeAiSuggestionWithPolicy,
                      child: Container(
                        height: 30,
                        padding: EdgeInsets.symmetric(horizontal: 16),
                        decoration: BoxDecoration(
                          color: workbenchAccent,
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: Center(
                          child: Text(
                            _isTr ? 'Çalıştır' : 'Execute',
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    GestureDetector(
                      onTap: () {
                        _cmdInputCtrl.text = _aiSuggestion!.command;
                        _cmdInputFocus.requestFocus();
                        setState(() => _aiSuggestion = null);
                      },
                      child: Container(
                        height: 30,
                        padding: EdgeInsets.symmetric(horizontal: 16),
                        decoration: BoxDecoration(
                          color: workbenchHover,
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: Center(
                          child: Text(
                            _isTr ? 'Düzenle' : 'Edit',
                            style: TextStyle(
                              color: workbenchText,
                              fontSize: 12,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    GestureDetector(
                      onTap: () => setState(() => _aiSuggestion = null),
                      child: Container(
                        height: 30,
                        padding: EdgeInsets.symmetric(horizontal: 16),
                        decoration: BoxDecoration(
                          color: workbenchHover,
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: Center(
                          child: Text(
                            _isTr ? 'İptal' : 'Cancel',
                            style: TextStyle(
                              color: workbenchTextMuted,
                              fontSize: 12,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),

        // ─── Mobile Shortcut Keys ──────────────────────────────────
        if (isMobile)
          Container(
            height: 42,
            decoration: BoxDecoration(
              color: workbenchEditorBg,
              border: Border(
                top: BorderSide(color: workbenchDivider, width: 0.5),
              ),
            ),
            child: ListView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
              children: [
                _MobileTermKey(
                  label: 'Esc',
                  onTap: () => _sendTerminalKey(TerminalKey.escape),
                ),
                _MobileTermKey(
                  label: 'Tab',
                  onTap: () => _sendTerminalKey(TerminalKey.tab),
                ),
                _MobileTermKey(
                  label: 'Ctrl+C',
                  onTap: () => _sendTerminalKey(TerminalKey.keyC, ctrl: true),
                ),
                _MobileTermKey(
                  label: 'Ctrl+D',
                  onTap: () => _sendTerminalKey(TerminalKey.keyD, ctrl: true),
                ),
                _MobileTermKey(
                  label: 'Home',
                  onTap: () => _sendTerminalKey(TerminalKey.home),
                ),
                _MobileTermKey(
                  label: 'End',
                  onTap: () => _sendTerminalKey(TerminalKey.end),
                ),
                _MobileTermKey(
                  label: '↑',
                  onTap: () => _sendTerminalKey(TerminalKey.arrowUp),
                ),
                _MobileTermKey(
                  label: '↓',
                  onTap: () => _sendTerminalKey(TerminalKey.arrowDown),
                ),
                _MobileTermKey(
                  label: '←',
                  onTap: () => _sendTerminalKey(TerminalKey.arrowLeft),
                ),
                _MobileTermKey(
                  label: '→',
                  onTap: () => _sendTerminalKey(TerminalKey.arrowRight),
                ),
                _MobileTermKey(
                  label: 'Enter',
                  accent: true,
                  onTap: () => _sendTerminalKey(TerminalKey.enter),
                ),
              ],
            ),
          ),

        // ─── Command Input Bar (Warp-style) ────────────────────────
        AnimatedContainer(
          duration: const Duration(milliseconds: 160),
          curve: Curves.easeOut,
          padding: EdgeInsets.fromLTRB(12, 8, 12, 8 + keyboardInset),
          decoration: BoxDecoration(
            color: workbenchEditorBg,
            border: Border(
              top: BorderSide(color: workbenchDivider, width: 0.5),
            ),
          ),
          child: Row(
            children: [
              Icon(
                FluentIcons.chevron_right_med,
                size: 12,
                color: widget.controller.connected
                    ? workbenchAccent
                    : workbenchTextFaint,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Focus(
                  onFocusChange: (f) {
                    if (pu.isDesktop) {
                      setState(() => _commandBarFocused = f);
                    }
                  },
                  child: isMobile
                      ? TextBox(
                          controller: _cmdInputCtrl,
                          focusNode: _cmdInputFocus,
                          placeholder: _isTr
                              ? (_aiEnabled
                                    ? 'Komut veya doğal dil yaz...'
                                    : 'Komut yaz...')
                              : (_aiEnabled
                                    ? 'Type command or ask in natural language...'
                                    : 'Type command...'),
                          placeholderStyle: TextStyle(
                            color: workbenchTextFaint,
                            fontSize: 12,
                          ),
                          style: TextStyle(
                            color: workbenchText,
                            fontSize: 13,
                            fontFamily: fontFamily,
                          ),
                          decoration: WidgetStateProperty.all(
                            BoxDecoration(color: Colors.transparent),
                          ),
                          onSubmitted: (v) {
                            _sendCommand(v);
                            _cmdInputFocus.requestFocus();
                          },
                        )
                      : KeyboardListener(
                          focusNode: FocusNode(),
                          onKeyEvent: (event) {
                            if (event is KeyDownEvent) {
                              if (event.logicalKey ==
                                  LogicalKeyboardKey.arrowUp) {
                                _historyUp();
                              }
                              if (event.logicalKey ==
                                  LogicalKeyboardKey.arrowDown) {
                                _historyDown();
                              }
                            }
                          },
                          child: TextBox(
                            controller: _cmdInputCtrl,
                            focusNode: _cmdInputFocus,
                            placeholder: _isTr
                                ? (_aiEnabled
                                      ? 'Komut veya doğal dil yaz... (↑↓ geçmiş)'
                                      : 'Komut yaz... (↑↓ geçmiş)')
                                : (_aiEnabled
                                      ? 'Type command or ask in natural language... (↑↓ history)'
                                      : 'Type command... (↑↓ history)'),
                            placeholderStyle: TextStyle(
                              color: workbenchTextFaint,
                              fontSize: 12,
                            ),
                            style: TextStyle(
                              color: workbenchText,
                              fontSize: 13,
                              fontFamily: fontFamily,
                            ),
                            decoration: WidgetStateProperty.all(
                              BoxDecoration(color: Colors.transparent),
                            ),
                            onSubmitted: (v) {
                              _sendCommand(v);
                              _cmdInputFocus.requestFocus();
                            },
                          ),
                        ),
                ),
              ),
              if (isMobile) ...[
                const SizedBox(width: 8),
                GestureDetector(
                  onTap: _toggleMobileKeyboard,
                  child: Container(
                    height: 28,
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    decoration: BoxDecoration(
                      color: keyboardVisible
                          ? workbenchAccent.withValues(alpha: 0.16)
                          : workbenchHover,
                      borderRadius: BorderRadius.circular(6),
                      border: Border.all(
                        color: keyboardVisible
                            ? workbenchAccent.withValues(alpha: 0.5)
                            : workbenchBorder,
                        width: 0.5,
                      ),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          '⌨',
                          style: TextStyle(
                            color: keyboardVisible
                                ? workbenchAccent
                                : workbenchTextMuted,
                            fontSize: 12,
                          ),
                        ),
                        const SizedBox(width: 4),
                        Icon(
                          keyboardVisible
                              ? FluentIcons.chevron_down
                              : FluentIcons.chevron_up,
                          size: 10,
                          color: keyboardVisible
                              ? workbenchAccent
                              : workbenchTextMuted,
                        ),
                      ],
                    ),
                  ),
                ),
              ],
              if (!isMobile) ...[
                const SizedBox(width: 8),
                Text(
                  '${_commandHistory.length}',
                  style: TextStyle(color: workbenchTextFaint, fontSize: 10),
                ),
                const SizedBox(width: 4),
                Icon(FluentIcons.history, size: 10, color: workbenchTextFaint),
              ],
            ],
          ),
        ),
      ],
    );
  }
}

// ─── Quick Command ─────────────────────────────────────────────────

class _MobileTermKey extends StatelessWidget {
  const _MobileTermKey({
    required this.label,
    required this.onTap,
    this.accent = false,
  });
  final String label;
  final VoidCallback onTap;
  final bool accent;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(right: 6),
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
          decoration: BoxDecoration(
            color: accent
                ? workbenchAccent.withValues(alpha: 0.2)
                : workbenchHover,
            borderRadius: BorderRadius.circular(6),
            border: Border.all(
              color: accent
                  ? workbenchAccent.withValues(alpha: 0.45)
                  : workbenchBorder,
              width: 0.5,
            ),
          ),
          child: Center(
            child: Text(
              label,
              style: TextStyle(
                color: accent ? workbenchAccent : workbenchTextMuted,
                fontSize: 11,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _QCmd {
  const _QCmd(this.label, this.command, this.icon);
  final String label;
  final String command;
  final IconData icon;
}

class _QuickCmdChip extends StatefulWidget {
  const _QuickCmdChip({required this.cmd, required this.onTap});
  final _QCmd cmd;
  final VoidCallback onTap;
  @override
  State<_QuickCmdChip> createState() => _QuickCmdChipState();
}

class _QuickCmdChipState extends State<_QuickCmdChip> {
  bool _h = false;
  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      onEnter: (_) => setState(() => _h = true),
      onExit: (_) => setState(() => _h = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: Tooltip(
          message: widget.cmd.command,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            decoration: BoxDecoration(
              color: _h
                  ? workbenchAccent.withValues(alpha: 0.15)
                  : workbenchHover,
              borderRadius: BorderRadius.circular(6),
              border: Border.all(
                color: _h
                    ? workbenchAccent.withValues(alpha: 0.3)
                    : Colors.transparent,
                width: 0.5,
              ),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  widget.cmd.icon,
                  size: 11,
                  color: _h ? workbenchAccent : workbenchTextMuted,
                ),
                const SizedBox(width: 6),
                Text(
                  widget.cmd.label,
                  style: TextStyle(
                    color: _h ? workbenchText : workbenchTextMuted,
                    fontSize: 11,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// ─── Header Button ─────────────────────────────────────────────────

class _HeaderBtn extends StatefulWidget {
  const _HeaderBtn({
    required this.icon,
    required this.tooltip,
    required this.onTap,
    this.active = false,
  });
  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;
  final bool active;
  @override
  State<_HeaderBtn> createState() => _HeaderBtnState();
}

class _HeaderBtnState extends State<_HeaderBtn> {
  bool _h = false;
  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: widget.tooltip,
      child: MouseRegion(
        onEnter: (_) => setState(() => _h = true),
        onExit: (_) => setState(() => _h = false),
        child: GestureDetector(
          onTap: widget.onTap,
          child: Container(
            width: 28,
            height: 28,
            decoration: BoxDecoration(
              color: widget.active
                  ? workbenchAccent.withValues(alpha: 0.15)
                  : _h
                  ? workbenchHover
                  : Colors.transparent,
              borderRadius: BorderRadius.circular(6),
            ),
            child: Icon(
              widget.icon,
              size: 12,
              color: widget.active
                  ? workbenchAccent
                  : _h
                  ? workbenchText
                  : workbenchTextMuted,
            ),
          ),
        ),
      ),
    );
  }
}

// ─── Context Menu Row ──────────────────────────────────────────────

class _CtxRow extends StatefulWidget {
  const _CtxRow({
    required this.icon,
    required this.label,
    required this.onTap,
    this.shortcut,
  });
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final String? shortcut;
  @override
  State<_CtxRow> createState() => _CtxRowState();
}

class _CtxRowState extends State<_CtxRow> {
  bool _h = false;
  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      onEnter: (_) => setState(() => _h = true),
      onExit: (_) => setState(() => _h = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
          decoration: BoxDecoration(
            color: _h ? workbenchHover : Colors.transparent,
            borderRadius: BorderRadius.circular(4),
          ),
          child: Row(
            children: [
              Icon(widget.icon, size: 12, color: workbenchTextMuted),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  widget.label,
                  style: TextStyle(color: workbenchText, fontSize: 12),
                ),
              ),
              if (widget.shortcut != null)
                Text(
                  widget.shortcut!,
                  style: TextStyle(color: workbenchTextFaint, fontSize: 10),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

// ─── History Row ───────────────────────────────────────────────────

class _HistoryRow extends StatefulWidget {
  const _HistoryRow({required this.cmd, required this.onTap});
  final String cmd;
  final VoidCallback onTap;
  @override
  State<_HistoryRow> createState() => _HistoryRowState();
}

class _HistoryRowState extends State<_HistoryRow> {
  bool _h = false;
  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      onEnter: (_) => setState(() => _h = true),
      onExit: (_) => setState(() => _h = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          color: _h ? workbenchHover : Colors.transparent,
          child: Row(
            children: [
              Icon(
                FluentIcons.chevron_right_med,
                size: 10,
                color: workbenchAccent,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  widget.cmd,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: workbenchText,
                    fontSize: 12,
                    fontFamily: 'Cascadia Code',
                  ),
                ),
              ),
              GestureDetector(
                onTap: () {
                  Clipboard.setData(ClipboardData(text: widget.cmd));
                },
                child: Icon(
                  FluentIcons.copy,
                  size: 10,
                  color: workbenchTextFaint,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ─── AI History Row ────────────────────────────────────────────────

class _AiHistoryRow extends StatefulWidget {
  const _AiHistoryRow({
    required this.entry,
    required this.isTr,
    required this.onExecute,
    required this.onUseQuery,
  });
  final AiHistoryEntry entry;
  final bool isTr;
  final VoidCallback onExecute;
  final VoidCallback onUseQuery;
  @override
  State<_AiHistoryRow> createState() => _AiHistoryRowState();
}

class _AiHistoryRowState extends State<_AiHistoryRow> {
  bool _expanded = false;
  bool _h = false;

  @override
  Widget build(BuildContext context) {
    final e = widget.entry;
    final timeStr =
        '${e.timestamp.hour.toString().padLeft(2, '0')}:${e.timestamp.minute.toString().padLeft(2, '0')}';
    final dateStr = '${e.timestamp.day}/${e.timestamp.month}';

    return MouseRegion(
      onEnter: (_) => setState(() => _h = true),
      onExit: (_) => setState(() => _h = false),
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 2, horizontal: 4),
        decoration: BoxDecoration(
          color: _h ? workbenchHover : Colors.transparent,
          borderRadius: BorderRadius.circular(6),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            GestureDetector(
              onTap: () => setState(() => _expanded = !_expanded),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 8,
                ),
                child: Row(
                  children: [
                    Icon(FluentIcons.robot, size: 11, color: workbenchAccent),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        e.query,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: workbenchText,
                          fontSize: 12,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      '$dateStr $timeStr',
                      style: TextStyle(color: workbenchTextFaint, fontSize: 9),
                    ),
                    const SizedBox(width: 6),
                    Icon(
                      _expanded
                          ? FluentIcons.chevron_up
                          : FluentIcons.chevron_down,
                      size: 10,
                      color: workbenchTextFaint,
                    ),
                  ],
                ),
              ),
            ),
            if (_expanded)
              Padding(
                padding: const EdgeInsets.fromLTRB(10, 0, 10, 10),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(8),
                      decoration: BoxDecoration(
                        color: workbenchBg,
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: SelectableText(
                        e.command,
                        style: TextStyle(
                          color: workbenchText,
                          fontSize: 12,
                          fontFamily: 'monospace',
                        ),
                      ),
                    ),
                    if (e.explanation != null) ...[
                      SizedBox(height: 6),
                      Text(
                        e.explanation!,
                        style: TextStyle(
                          color: workbenchTextMuted,
                          fontSize: 11,
                          height: 1.4,
                        ),
                      ),
                    ],
                    if (e.steps != null && e.steps!.isNotEmpty) ...[
                      const SizedBox(height: 6),
                      for (int i = 0; i < e.steps!.length; i++)
                        Padding(
                          padding: EdgeInsets.only(bottom: 2),
                          child: Text(
                            '${i + 1}. ${e.steps![i]}',
                            style: TextStyle(
                              color: workbenchTextMuted,
                              fontSize: 11,
                              fontFamily: 'monospace',
                            ),
                          ),
                        ),
                    ],
                    if (e.provider != null) ...[
                      SizedBox(height: 6),
                      Text(
                        '${e.provider} / ${e.model ?? "?"}',
                        style: TextStyle(
                          color: workbenchTextFaint,
                          fontSize: 9,
                        ),
                      ),
                    ],
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        GestureDetector(
                          onTap: widget.onExecute,
                          child: Container(
                            height: 26,
                            padding: const EdgeInsets.symmetric(horizontal: 12),
                            decoration: BoxDecoration(
                              color: workbenchAccent,
                              borderRadius: BorderRadius.circular(4),
                            ),
                            child: Center(
                              child: Text(
                                widget.isTr ? 'Çalıştır' : 'Execute',
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 10,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(width: 6),
                        GestureDetector(
                          onTap: widget.onUseQuery,
                          child: Container(
                            height: 26,
                            padding: const EdgeInsets.symmetric(horizontal: 12),
                            decoration: BoxDecoration(
                              color: workbenchHover,
                              borderRadius: BorderRadius.circular(4),
                            ),
                            child: Center(
                              child: Text(
                                widget.isTr ? 'Tekrar Sor' : 'Ask Again',
                                style: TextStyle(
                                  color: workbenchText,
                                  fontSize: 10,
                                  fontWeight: FontWeight.w500,
                                ),
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(width: 6),
                        GestureDetector(
                          onTap: () =>
                              Clipboard.setData(ClipboardData(text: e.command)),
                          child: Container(
                            height: 26,
                            padding: const EdgeInsets.symmetric(horizontal: 12),
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
                                    widget.isTr ? 'Kopyala' : 'Copy',
                                    style: TextStyle(
                                      color: workbenchTextMuted,
                                      fontSize: 10,
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
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _HistoryTabBtn extends StatelessWidget {
  const _HistoryTabBtn({
    required this.label,
    required this.count,
    required this.index,
  });
  final String label;
  final int count;
  final int index;

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Builder(
        builder: (ctx) {
          final tabCtrl = DefaultTabController.of(ctx);
          return GestureDetector(
            onTap: () => tabCtrl.animateTo(index),
            child: AnimatedBuilder(
              animation: tabCtrl,
              builder: (_, __) {
                final active = tabCtrl.index == index;
                return Container(
                  height: 32,
                  decoration: BoxDecoration(
                    border: Border(
                      bottom: BorderSide(
                        color: active ? workbenchAccent : Colors.transparent,
                        width: 2,
                      ),
                    ),
                  ),
                  child: Center(
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          label,
                          style: TextStyle(
                            color: active ? workbenchText : workbenchTextMuted,
                            fontSize: 12,
                            fontWeight: active
                                ? FontWeight.w600
                                : FontWeight.w400,
                          ),
                        ),
                        const SizedBox(width: 6),
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 5,
                            vertical: 1,
                          ),
                          decoration: BoxDecoration(
                            color: active
                                ? workbenchAccent.withValues(alpha: 0.15)
                                : workbenchHover,
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: Text(
                            '$count',
                            style: TextStyle(
                              color: active
                                  ? workbenchAccent
                                  : workbenchTextFaint,
                              fontSize: 9,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),
          );
        },
      ),
    );
  }
}

class _SnippetRow extends StatefulWidget {
  const _SnippetRow({required this.snippet, required this.onRun});
  final Snippet snippet;
  final VoidCallback onRun;
  @override
  State<_SnippetRow> createState() => _SnippetRowState();
}

class _SnippetRowState extends State<_SnippetRow> {
  bool _h = false;
  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      onEnter: (_) => setState(() => _h = true),
      onExit: (_) => setState(() => _h = false),
      child: GestureDetector(
        onTap: widget.onRun,
        child: Container(
          margin: const EdgeInsets.only(bottom: 4),
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          decoration: BoxDecoration(
            color: _h ? workbenchHover : Colors.transparent,
            borderRadius: BorderRadius.circular(6),
          ),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      widget.snippet.name,
                      style: TextStyle(
                        color: workbenchText,
                        fontSize: 12,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      widget.snippet.command,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: workbenchTextMuted,
                        fontSize: 11,
                        fontFamily: 'monospace',
                      ),
                    ),
                  ],
                ),
              ),
              Icon(
                FluentIcons.play,
                size: 12,
                color: _h ? workbenchAccent : workbenchTextFaint,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
