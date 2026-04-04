import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter/material.dart' show DefaultTabController, TabBarView;
import 'package:flutter/services.dart';
import 'package:lifeos_sftp_drive/src/i18n/app_strings.dart';
import 'package:lifeos_sftp_drive/src/services/ai_service.dart';
import 'package:lifeos_sftp_drive/src/ai/agent/ai_agent_models.dart';
import 'package:lifeos_sftp_drive/src/services/snippet_service.dart';
import 'package:lifeos_sftp_drive/src/state/app_controller.dart';
import 'package:lifeos_sftp_drive/src/terminal/local_terminal_controller.dart';
import 'package:lifeos_sftp_drive/src/ui/terminal_themes.dart';
import 'package:lifeos_sftp_drive/src/ui/theme_tokens.dart';
import 'package:lifeos_sftp_drive/src/ui/widgets/ai_chat_panel.dart';
import 'package:lifeos_sftp_drive/src/utils/terminal_timeline_text.dart';
import 'package:xterm/xterm.dart';

const _kVisibleHandoffMarker = '__LIFEOS_VISIBLE_HANDOFF__';

class LocalTerminalView extends StatefulWidget {
  const LocalTerminalView({
    super.key,
    required this.controller,
    this.appController,
  });
  final LocalTerminalController controller;
  final AppController? appController;
  @override
  State<LocalTerminalView> createState() => _LocalTerminalViewState();
}

class _LocalTerminalViewState extends State<LocalTerminalView> {
  late final TerminalController _termCtrl = TerminalController();
  final _cmdInputCtrl = TextEditingController();
  final _searchCtrl = TextEditingController();
  final _cmdInputFocus = FocusNode();
  final List<String> _commandHistory = [];
  int _historyIndex = -1;
  bool _showSearch = false;
  bool _showQuickPanel = false;
  bool _commandBarFocused = false;
  AiResponse? _aiSuggestion;
  bool _aiLoading = false;
  String? _aiError;

  final _chatKey = GlobalKey<AiChatPanelState>();

  // Command timing
  DateTime? _lastCmdTime;
  String? _lastCmdDuration;

  // Split terminal: 0=none, 1=horizontal, 2=vertical
  int _splitMode = 0;
  LocalTerminalController? _splitController;
  late final TerminalController _splitTermCtrl = TerminalController();

  bool get _isTr => widget.appController?.locale == AppLocale.tr;

  static const _winCommands = [
    _QCmd('System', 'systeminfo | findstr /B /C:"OS"', FluentIcons.system),
    _QCmd(
      'Disk',
      'Get-PSDrive -PSProvider FileSystem | Format-Table Name,Used,Free,Root',
      FluentIcons.hard_drive,
    ),
    _QCmd(
      'Memory',
      'Get-Process | Sort-Object WorkingSet -Descending | Select-Object -First 15 Name,@{N="MB";E={[math]::Round(\$_.WorkingSet/1MB,1)}}',
      FluentIcons.database,
    ),
    _QCmd(
      'Top',
      'Get-Process | Sort-Object CPU -Descending | Select-Object -First 20 Name,CPU,WorkingSet',
      FluentIcons.processing,
    ),
    _QCmd('Network', 'ipconfig', FluentIcons.globe),
    _QCmd(
      'Services',
      'Get-Service | Where-Object Status -eq Running | Select-Object -First 20 Name,DisplayName',
      FluentIcons.settings,
    ),
    _QCmd('Docker', 'docker ps', FluentIcons.devices3),
    _QCmd(
      'Ports',
      'netstat -ano | findstr LISTENING',
      FluentIcons.plug_connected,
    ),
    _QCmd('Users', 'query user 2>nul || whoami', FluentIcons.people),
    _QCmd(
      'CPU',
      'wmic cpu get Name,NumberOfCores,MaxClockSpeed /format:list',
      FluentIcons.processing_run,
    ),
    _QCmd(
      'Uptime',
      'powershell -c "(Get-Date) - (Get-CimInstance Win32_OperatingSystem).LastBootUpTime"',
      FluentIcons.timer,
    ),
    _QCmd('Files', 'dir', FluentIcons.folder_open),
    _QCmd('Git', 'git status', FluentIcons.branch_merge),
    _QCmd('Processes', 'tasklist /FO TABLE | more', FluentIcons.task_list),
    _QCmd('Path', 'echo %PATH:;=\n%', FluentIcons.open_pane),
  ];

  static const _unixCommands = [
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
    _QCmd('Ports', 'ss -tulnp', FluentIcons.plug_connected),
    _QCmd('Users', 'who', FluentIcons.people),
    _QCmd('CPU', 'lscpu | head -20', FluentIcons.processing_run),
    _QCmd('Uptime', 'uptime', FluentIcons.timer),
    _QCmd('Files', 'ls -la', FluentIcons.folder_open),
    _QCmd('Git', 'git status', FluentIcons.branch_merge),
    _QCmd('Processes', 'ps aux | head -20', FluentIcons.task_list),
    _QCmd('Path', 'echo \$PATH | tr ":" "\\n"', FluentIcons.open_pane),
  ];

  /// Returns quick commands based on active shell type.
  List<_QCmd> get _quickCommands =>
      widget.controller.isUnixShell ? _unixCommands : _winCommands;

  void _toggleSplit(int mode) {
    if (_splitMode == mode) {
      // Close split
      _splitController?.disposeController();
      _splitController = null;
      setState(() => _splitMode = 0);
    } else {
      // Open or change split direction
      if (_splitController == null) {
        _splitController = LocalTerminalController(
          shellId: widget.appController?.terminalShell ?? 'auto',
          appController: widget.appController,
        );
        _splitController!.start();
      }
      setState(() => _splitMode = mode);
    }
  }

  @override
  void initState() {
    super.initState();
    widget.appController?.addListener(_onSettingsChanged);
  }

  void _onSettingsChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    widget.appController?.removeListener(_onSettingsChanged);
    _termCtrl.dispose();
    _splitTermCtrl.dispose();
    _splitController?.disposeController();
    _cmdInputCtrl.dispose();
    _searchCtrl.dispose();
    _cmdInputFocus.dispose();
    super.dispose();
  }

  bool get _aiActive => widget.appController?.aiEnabled ?? false;

  void _sendCommand(String cmd) async {
    if (cmd.trim().isEmpty) return;

    // AI mode: # prefix
    if (cmd.trim().startsWith('#') && _aiActive) {
      _askAi(cmd.trim().substring(1).trim());
      _cmdInputCtrl.clear();
      return;
    }

    // Smart detect: if enabled and looks like natural language → AI
    if (_aiActive &&
        (widget.appController?.aiSmartDetect ?? false) &&
        looksLikeNaturalLanguage(cmd.trim())) {
      _askAi(cmd.trim());
      _cmdInputCtrl.clear();
      return;
    }

    if (!widget.controller.running) return;
    final command = cmd.trim();
    if (!await _canRunCommandByPolicy(command)) {
      return;
    }
    if (_commandHistory.isEmpty || _commandHistory.last != command) {
      _commandHistory.add(command);
    }
    _historyIndex = -1;
    // Track command timing
    if (_lastCmdTime != null) {
      final elapsed = DateTime.now().difference(_lastCmdTime!);
      _lastCmdDuration = _formatDuration(elapsed);
    }
    _lastCmdTime = DateTime.now();
    widget.controller.sendCommand(command, source: 'command_bar');
    _cmdInputCtrl.clear();
    setState(() {
      _showQuickPanel = false;
      _aiSuggestion = null;
    });
  }

  void _executeAiCommand(String cmd) async {
    if (!widget.controller.running) return;
    final command = cmd.trim();
    if (command.isEmpty) return;
    if (!await _canRunCommandByPolicy(command)) {
      return;
    }
    if (_commandHistory.isEmpty || _commandHistory.last != command) {
      _commandHistory.add(command);
    }
    _historyIndex = -1;
    widget.controller.sendCommand(command, source: 'ai');
    setState(() => _aiSuggestion = null);
  }

  void _interruptAiCommand() {
    widget.controller.sendSignal('\x03');
  }

  Future<AiAgentCommandResult> _runAiTrackedCommandLocal(String command) async {
    final cmd = command.trim();
    if (cmd.isEmpty) {
      return AiAgentCommandResult(
        command: command,
        output: _isTr ? 'Komut boş.' : 'Command is empty.',
        success: false,
        durationMs: 0,
        exitCode: 1,
      );
    }

    if (_needsInteractiveForeground(cmd)) {
      return AiAgentCommandResult(
        command: cmd,
        output: _isTr
            ? 'Bu komut etkileşim/şifre gerektirebilir. Görünür terminalde çalıştır.'
            : 'This command may require interaction/password. Run it in visible terminal.',
        success: false,
        durationMs: 0,
        exitCode: 1,
        timedOut: true,
      );
    }

    final started = DateTime.now();
    final cwd = _detectCurrentDirectoryFromTerminal();
    if (_shouldRunInVisibleTerminal(cmd)) {
      _executeAiCommand(cmd);
      return AiAgentCommandResult(
        command: cmd,
        output:
            '$_kVisibleHandoffMarker ${_isTr ? 'Komutu terminale gönderdim. Çalışma bitince "devam" yaz.' : 'Sent command to visible terminal. Type "continue" when it finishes.'}',
        success: false,
        durationMs: DateTime.now().difference(started).inMilliseconds,
        exitCode: null,
        cwd: cwd.isEmpty ? null : cwd,
        timedOut: true,
      );
    }

    final shellName = widget.controller.shellName.toLowerCase();
    Process? process;
    StreamSubscription<String>? outSub;
    StreamSubscription<String>? errSub;
    final out = StringBuffer();
    final err = StringBuffer();
    var timedOut = false;
    int? exitCode;

    try {
      final workingDir = _resolveWorkingDirectory(cwd);
      final startResult = await _startHiddenProcess(
        command: cmd,
        shellName: shellName,
        workingDirectory: workingDir,
      );
      process = startResult;

      outSub = process.stdout
          .transform(utf8.decoder)
          .listen((chunk) => out.write(chunk));
      errSub = process.stderr
          .transform(utf8.decoder)
          .listen((chunk) => err.write(chunk));

      try {
        exitCode = await process.exitCode.timeout(const Duration(seconds: 35));
      } on TimeoutException {
        timedOut = true;
        try {
          process.kill(ProcessSignal.sigkill);
        } catch (_) {}
      }

      await outSub.cancel();
      await errSub.cancel();
    } catch (e) {
      final durationMs = DateTime.now().difference(started).inMilliseconds;
      return AiAgentCommandResult(
        command: cmd,
        output: e.toString(),
        success: false,
        durationMs: durationMs,
        exitCode: 1,
        cwd: cwd.isEmpty ? null : cwd,
      );
    }

    final durationMs = DateTime.now().difference(started).inMilliseconds;
    final output = '${out.toString()}${err.toString()}'.trim();
    final success = !timedOut && (exitCode ?? 1) == 0;
    return AiAgentCommandResult(
      command: cmd,
      output: output,
      success: success,
      durationMs: durationMs,
      exitCode: timedOut ? null : exitCode,
      cwd: cwd.isEmpty ? null : cwd,
      timedOut: timedOut,
    );
  }

  Future<Process> _startHiddenProcess({
    required String command,
    required String shellName,
    required String? workingDirectory,
  }) async {
    if (widget.controller.isUnixShell) {
      if (Platform.isWindows && shellName.contains('wsl')) {
        return Process.start(
          'wsl.exe',
          ['bash', '-lc', command],
          workingDirectory: workingDirectory,
          runInShell: false,
        );
      }
      return Process.start(
        '/usr/bin/env',
        ['bash', '-lc', command],
        workingDirectory: workingDirectory,
        runInShell: false,
      );
    }

    if (shellName.contains('powershell') || shellName.contains('pwsh')) {
      return Process.start(
        'powershell',
        ['-NoProfile', '-NonInteractive', '-Command', command],
        workingDirectory: workingDirectory,
        runInShell: true,
      );
    }

    return Process.start(
      'cmd.exe',
      ['/c', command],
      workingDirectory: workingDirectory,
      runInShell: true,
    );
  }

  String? _resolveWorkingDirectory(String cwd) {
    final normalized = cwd.trim();
    if (normalized.isEmpty || normalized == '~') {
      return null;
    }
    try {
      final dir = Directory(normalized);
      if (dir.existsSync()) {
        return normalized;
      }
    } catch (_) {}
    return null;
  }

  bool _needsInteractiveForeground(String command) {
    final lower = command.toLowerCase();
    final patterns = <RegExp>[
      RegExp(r'(^|\s)sudo(\s|$)'),
      RegExp(r'(^|\s)su(\s|$)'),
      RegExp(r'(^|\s)passwd(\s|$)'),
      RegExp(r'(^|\s)ssh(\s|$)'),
      RegExp(r'(^|\s)sftp(\s|$)'),
      RegExp(r'(^|\s)top(\s|$)'),
      RegExp(r'(^|\s)htop(\s|$)'),
      RegExp(r'(^|\s)less(\s|$)'),
      RegExp(r'(^|\s)more(\s|$)'),
      RegExp(r'(^|\s)vim(\s|$)'),
      RegExp(r'(^|\s)nvim(\s|$)'),
      RegExp(r'(^|\s)nano(\s|$)'),
      RegExp(r'(^|\s)tmux(\s|$)'),
      RegExp(r'\bread\s+-p\b'),
      RegExp(r'(^|\s)select(\s|$)'),
    ];
    return patterns.any((p) => p.hasMatch(lower));
  }

  bool _shouldRunInVisibleTerminal(String command) {
    final lower = command.toLowerCase();
    const mutations = [
      ' apt install',
      ' apt remove',
      ' apt upgrade',
      ' apt-get install',
      ' apt-get remove',
      ' apt-get upgrade',
      ' pacman -s',
      ' pacman -r',
      ' pacman -syu',
      ' pamac install',
      ' pamac remove',
      ' pamac upgrade',
      ' dnf install',
      ' dnf remove',
      ' dnf upgrade',
      ' yum install',
      ' yum remove',
      ' yum update',
      ' zypper install',
      ' zypper remove',
      ' zypper update',
      ' winget install',
      ' winget uninstall',
      ' winget upgrade',
      ' choco install',
      ' choco uninstall',
      ' choco upgrade',
      ' rm ',
      ' mv ',
      ' chmod ',
      ' chown ',
      ' systemctl restart',
      ' systemctl start',
      ' systemctl stop',
    ];
    if (mutations.any(lower.contains)) {
      return true;
    }
    return _needsInteractiveForeground(command);
  }

  String _detectCurrentDirectoryFromTerminal() {
    final lines = widget.controller.terminal.buffer.lines;
    if (lines.length == 0) {
      return '';
    }
    final start = lines.length > 80 ? lines.length - 80 : 0;
    final tail = <String>[];
    for (int i = start; i < lines.length; i++) {
      final line = lines[i].toString().trim();
      if (line.isNotEmpty) {
        tail.add(line);
      }
    }
    for (int i = tail.length - 1; i >= 0; i--) {
      final line = tail[i];
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

  Future<void> _askAi(String query) async {
    final app = widget.appController;
    if (app == null || !app.aiEnabled) {
      setState(
        () => _aiError = _isTr
            ? 'API anahtarı ayarlanmamış. Ayarlar > AI Asistan'
            : 'No API key set. Go to Settings > AI Assistant',
      );
      return;
    }

    setState(() {
      _aiLoading = true;
      _aiError = null;
      _aiSuggestion = null;
    });

    try {
      final provider = AiProvider.values.firstWhere(
        (p) => p.name == app.aiProvider,
        orElse: () => AiProvider.gemini,
      );
      final service = AiService(
        provider: provider,
        apiKey: app.aiApiKey,
        model: app.aiModel,
      );

      // Get last 20 lines from terminal buffer for context
      final buffer = widget.controller.terminal.buffer;
      final lines = buffer.lines;
      final lineCount = lines.length;
      final startIdx = lineCount > 20 ? lineCount - 20 : 0;
      final lastOutputBuf = StringBuffer();
      for (int i = startIdx; i < lineCount; i++) {
        lastOutputBuf.writeln(lines[i].toString());
      }

      final shellName = widget.controller.shellName;
      final osInfo = _buildLocalOsInfo();

      final response = await service.ask(
        userMessage: query,
        shellName: shellName,
        currentDirectory: null,
        lastOutput: lastOutputBuf.toString(),
        osInfo: osInfo,
      );
      service.dispose();

      if (!mounted) return;

      // Save to AI history
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

      if (app.aiAutoExecute && !isDangerousCommand(response.command)) {
        _executeAiCommand(response.command);
        return;
      }

      setState(() {
        _aiSuggestion = response;
        _aiLoading = false;
      });
    } catch (e) {
      if (mounted)
        setState(() {
          _aiError = e.toString();
          _aiLoading = false;
        });
    }
  }

  String _buildLocalOsInfo() {
    final shellName = widget.controller.shellName;
    if (widget.controller.isUnixShell && shellName.contains('WSL')) {
      return 'WSL $shellName (Linux inside Windows)';
    }

    if (Platform.isLinux) {
      final release = _readLinuxOsRelease();
      final pretty = release['PRETTY_NAME'] ?? release['NAME'] ?? 'Linux';
      final id = (release['ID'] ?? '').trim();
      final idLike = (release['ID_LIKE'] ?? '').trim();
      final pm = _inferLinuxPackageManager(id: id, idLike: idLike);
      final details = <String>[];
      if (id.isNotEmpty) {
        details.add('id=$id');
      }
      if (idLike.isNotEmpty) {
        details.add('like=$idLike');
      }
      if (pm.isNotEmpty) {
        details.add('pm=$pm');
      }
      if (details.isEmpty) {
        return pretty;
      }
      return '$pretty (${details.join(', ')})';
    }

    return '${Platform.operatingSystem} ${Platform.operatingSystemVersion}';
  }

  Map<String, String> _readLinuxOsRelease() {
    try {
      final file = File('/etc/os-release');
      if (!file.existsSync()) {
        return const {};
      }
      final map = <String, String>{};
      final content = file.readAsStringSync();
      for (final rawLine in content.split('\n')) {
        final line = rawLine.trim();
        if (line.isEmpty || line.startsWith('#')) {
          continue;
        }
        final idx = line.indexOf('=');
        if (idx <= 0) {
          continue;
        }
        final key = line.substring(0, idx).trim();
        var value = line.substring(idx + 1).trim();
        if (value.length >= 2 &&
            ((value.startsWith('"') && value.endsWith('"')) ||
                (value.startsWith("'") && value.endsWith("'")))) {
          value = value.substring(1, value.length - 1);
        }
        map[key] = value;
      }
      return map;
    } catch (_) {
      return const {};
    }
  }

  String _inferLinuxPackageManager({
    required String id,
    required String idLike,
  }) {
    final text = '$id $idLike'.toLowerCase();
    if (text.contains('arch')) {
      return 'pacman';
    }
    if (text.contains('debian') || text.contains('ubuntu')) {
      return 'apt';
    }
    if (text.contains('rhel') ||
        text.contains('fedora') ||
        text.contains('centos') ||
        text.contains('rocky') ||
        text.contains('alma')) {
      return 'dnf';
    }
    if (text.contains('suse')) {
      return 'zypper';
    }
    if (text.contains('alpine')) {
      return 'apk';
    }
    return '';
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
    if (_historyIndex == -1) {
      _historyIndex = _commandHistory.length - 1;
    } else if (_historyIndex > 0) {
      _historyIndex--;
    }
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

  void _paste() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    if (data?.text != null && data!.text!.isNotEmpty) {
      widget.controller.terminal.textInput(data.text!);
    }
  }

  void _copySelection() {
    final selection = _termCtrl.selection;
    if (selection == null) return;
    final text = widget.controller.terminal.buffer.getText(selection);
    if (text.isNotEmpty) {
      Clipboard.setData(ClipboardData(text: text));
    }
  }

  String _formatDuration(Duration d) {
    if (d.inHours > 0) return '${d.inHours}h ${d.inMinutes.remainder(60)}m';
    if (d.inMinutes > 0) return '${d.inMinutes}m ${d.inSeconds.remainder(60)}s';
    if (d.inSeconds > 0)
      return '${d.inSeconds}.${(d.inMilliseconds.remainder(1000) ~/ 100)}s';
    return '${d.inMilliseconds}ms';
  }

  String _timelineTypeLabel(String type) {
    switch (type) {
      case 'command':
        return _isTr ? 'Komut' : 'Command';
      case 'output':
        return _isTr ? 'Çıktı' : 'Output';
      case 'start':
        return _isTr ? 'Başlangıç' : 'Start';
      case 'stop':
        return _isTr ? 'Durdur' : 'Stop';
      case 'process_exit':
        return _isTr ? 'Çıkış' : 'Exit';
      case 'start_error':
        return _isTr ? 'Hata' : 'Error';
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
      case 'start':
        return const Color(0xFF52D273);
      case 'stop':
      case 'process_exit':
        return const Color(0xFFF5A742);
      case 'start_error':
        return const Color(0xFFFF6B6B);
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
      case 'start':
        return FluentIcons.play;
      case 'stop':
      case 'process_exit':
        return FluentIcons.stop;
      case 'start_error':
        return FluentIcons.error;
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
    required LocalTerminalSessionEvent event,
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

  Widget _buildTerminalPane(
    Terminal terminal,
    TerminalController ctrl,
    TerminalTheme theme,
    double bgOpacity,
    double fontSize,
    double lineHeight,
    String fontFamily,
    String themeName,
  ) {
    return Listener(
      onPointerDown: (event) {
        if (event.buttons == 2) _showContextMenu(event.position);
      },
      child: FocusScope(
        autofocus: !_commandBarFocused,
        child: Shortcuts(
          shortcuts: {
            // Ctrl+Shift+C → copy selection
            LogicalKeySet(
              LogicalKeyboardKey.control,
              LogicalKeyboardKey.shift,
              LogicalKeyboardKey.keyC,
            ): const _TermActionIntent(
              'copy',
            ),
            // Ctrl+Shift+V → paste
            LogicalKeySet(
              LogicalKeyboardKey.control,
              LogicalKeyboardKey.shift,
              LogicalKeyboardKey.keyV,
            ): const _TermActionIntent(
              'paste',
            ),
            // Ctrl+C → send SIGINT to process (not terminal widget)
            LogicalKeySet(LogicalKeyboardKey.control, LogicalKeyboardKey.keyC):
                const _TermSignalIntent('\x03'),
            // Ctrl+D → send EOF
            LogicalKeySet(LogicalKeyboardKey.control, LogicalKeyboardKey.keyD):
                const _TermSignalIntent('\x04'),
            // Ctrl+Z → send SIGTSTP
            LogicalKeySet(LogicalKeyboardKey.control, LogicalKeyboardKey.keyZ):
                const _TermSignalIntent('\x1a'),
            // Ctrl+L → clear screen
            LogicalKeySet(LogicalKeyboardKey.control, LogicalKeyboardKey.keyL):
                const _TermSignalIntent('\x0c'),
            // Ctrl+A → beginning of line
            LogicalKeySet(LogicalKeyboardKey.control, LogicalKeyboardKey.keyA):
                const _TermSignalIntent('\x01'),
            // Ctrl+E → end of line
            LogicalKeySet(LogicalKeyboardKey.control, LogicalKeyboardKey.keyE):
                const _TermSignalIntent('\x05'),
            // Ctrl+U → kill line
            LogicalKeySet(LogicalKeyboardKey.control, LogicalKeyboardKey.keyU):
                const _TermSignalIntent('\x15'),
            // Ctrl+W → kill word
            LogicalKeySet(LogicalKeyboardKey.control, LogicalKeyboardKey.keyW):
                const _TermSignalIntent('\x17'),
            // Ctrl+R → reverse search
            LogicalKeySet(LogicalKeyboardKey.control, LogicalKeyboardKey.keyR):
                const _TermSignalIntent('\x12'),
          },
          child: Actions(
            actions: {
              _TermSignalIntent: CallbackAction<_TermSignalIntent>(
                onInvoke: (intent) {
                  // Send directly to process stdin, not through terminal widget
                  widget.controller.sendSignal(intent.signal);
                  return null;
                },
              ),
              _TermActionIntent: CallbackAction<_TermActionIntent>(
                onInvoke: (intent) {
                  if (intent.action == 'copy') _copySelection();
                  if (intent.action == 'paste') _paste();
                  return null;
                },
              ),
            },
            child: TerminalView(
              terminal,
              key: ValueKey('term_${themeName}_${fontSize}_$fontFamily'),
              controller: ctrl,
              autofocus: !_commandBarFocused,
              hardwareKeyboardOnly: true,
              theme: theme,
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
    );
  }

  void _showSnippetPanel() {
    final allSnippets = widget.appController?.snippetService.snippets ?? [];
    if (allSnippets.isEmpty) return;
    final searchCtrl = TextEditingController();
    String platformFilter = 'all';
    final platformLabels = {
      'all': _isTr ? 'Tümü' : 'All',
      'linux': 'Linux',
      'debian': 'Debian/Ubuntu',
      'arch': 'Arch',
      'rhel': 'RHEL/CentOS',
      'windows': 'Windows',
      'macos': 'macOS',
    };

    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) {
          final query = searchCtrl.text.toLowerCase();
          var filtered = allSnippets.where((s) {
            if (platformFilter != 'all' &&
                s.platform != 'all' &&
                s.platform != platformFilter) {
              if (platformFilter == 'arch' && s.platform == 'linux') {
              } // linux snippets show for arch too
              else if (platformFilter == 'debian' && s.platform == 'linux') {
              } else if (platformFilter == 'rhel' && s.platform == 'linux') {
              } else
                return false;
            }
            if (query.isNotEmpty) {
              return s.name.toLowerCase().contains(query) ||
                  s.command.toLowerCase().contains(query) ||
                  s.category.toLowerCase().contains(query);
            }
            return true;
          }).toList();
          final categories = filtered.map((s) => s.category).toSet().toList()
            ..sort();

          return ContentDialog(
            title: Text('Snippets (${filtered.length})'),
            content: SizedBox(
              width: 560,
              height: 450,
              child: Column(
                children: [
                  // Search + Platform filter
                  Row(
                    children: [
                      Expanded(
                        child: TextBox(
                          controller: searchCtrl,
                          placeholder: _isTr ? 'Ara...' : 'Search...',
                          style: const TextStyle(fontSize: 12),
                          onChanged: (_) => setDialogState(() {}),
                        ),
                      ),
                      const SizedBox(width: 8),
                      ComboBox<String>(
                        value: platformFilter,
                        items: platformLabels.entries
                            .map(
                              (e) => ComboBoxItem(
                                value: e.key,
                                child: Text(
                                  e.value,
                                  style: const TextStyle(fontSize: 11),
                                ),
                              ),
                            )
                            .toList(),
                        onChanged: (v) {
                          if (v != null)
                            setDialogState(() => platformFilter = v);
                        },
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  // Snippet list
                  Expanded(
                    child: ListView(
                      children: [
                        for (final cat in categories) ...[
                          Padding(
                            padding: const EdgeInsets.symmetric(vertical: 4),
                            child: Row(
                              children: [
                                Text(
                                  cat,
                                  style: TextStyle(
                                    color: workbenchAccent,
                                    fontSize: 11,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                                const SizedBox(width: 6),
                                Text(
                                  '(${filtered.where((s) => s.category == cat).length})',
                                  style: TextStyle(
                                    color: workbenchTextFaint,
                                    fontSize: 10,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          for (final s in filtered.where(
                            (s) => s.category == cat,
                          ))
                            _SnippetRow(
                              snippet: s,
                              isTr: _isTr,
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

  void _toggleSearch() {
    setState(() {
      _showSearch = !_showSearch;
      if (!_showSearch) _searchCtrl.clear();
    });
  }

  void _searchInTerminal(String query) {
    if (query.isEmpty) return;
    // xterm doesn't have built-in search highlight, but we can search buffer text
    final buffer = widget.controller.terminal.buffer;
    final lines = buffer.lines;
    for (int i = lines.length - 1; i >= 0; i--) {
      final line = lines[i].toString();
      if (line.toLowerCase().contains(query.toLowerCase())) {
        buffer.setCursor(0, i);
        break;
      }
    }
  }

  void _showContextMenu(Offset pos) {
    showBoundedContextMenu(
      context,
      pos,
      _buildCtxMenu,
      menuWidth: 220,
      menuHeight: 320,
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
            shortcut: 'Ctrl+L',
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
            label: _isTr ? 'Komut Geçmişi' : 'History',
            onTap: () {
              onDone();
              _showHistoryDialog();
            },
          ),
          if (!widget.controller.running) ...[
            Container(
              height: 0.5,
              margin: EdgeInsets.symmetric(horizontal: 8),
              color: workbenchBorder,
            ),
            _CtxRow(
              icon: FluentIcons.play,
              label: _isTr ? 'Başlat' : 'Start',
              onTap: () {
                onDone();
                widget.controller.start();
              },
            ),
          ],
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
                // Tab bar
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
                      // Command history
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
                      // AI history
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
                      // Timeline
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
                                    item['event']! as LocalTerminalSessionEvent;
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

    return Column(
      children: [
        // ─── Header ────────────────────────────────────────────────
        AnimatedBuilder(
          animation: widget.controller,
          builder: (_, __) => Container(
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
                    color: widget.controller.running
                        ? workbenchSuccess
                        : workbenchDanger,
                    shape: BoxShape.circle,
                    boxShadow: [
                      BoxShadow(
                        color:
                            (widget.controller.running
                                    ? workbenchSuccess
                                    : workbenchDanger)
                                .withValues(alpha: 0.4),
                        blurRadius: 6,
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 10),
                Text(
                  widget.controller.shellName,
                  style: TextStyle(
                    color: workbenchText,
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(width: 8),
                Container(
                  padding: EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  decoration: BoxDecoration(
                    color: workbenchHover,
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Text(
                    widget.controller.running
                        ? (_isTr ? 'Çalışıyor' : 'Running')
                        : (_isTr ? 'Durdu' : 'Stopped'),
                    style: TextStyle(
                      color: widget.controller.running
                          ? workbenchSuccess
                          : workbenchTextMuted,
                      fontSize: 10,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ),
                const Spacer(),
                // Action buttons
                _HeaderBtn(
                  icon: FluentIcons.lightning_bolt,
                  tooltip: _isTr ? 'Hızlı Komutlar' : 'Quick Commands',
                  active: _showQuickPanel,
                  onTap: () =>
                      setState(() => _showQuickPanel = !_showQuickPanel),
                ),
                const SizedBox(width: 4),
                _HeaderBtn(
                  icon: FluentIcons.code,
                  tooltip: _isTr ? 'Snippets' : 'Snippets',
                  onTap: () => _showSnippetPanel(),
                ),
                const SizedBox(width: 4),
                if (_aiActive) ...[
                  _HeaderBtn(
                    icon: FluentIcons.robot,
                    tooltip: _isTr ? 'AI Sohbet' : 'AI Chat',
                    onTap: () => _chatKey.currentState?.toggle(),
                  ),
                  const SizedBox(width: 4),
                  _HeaderBtn(
                    icon: FluentIcons.lightbulb,
                    tooltip: _isTr ? 'Çıktıyı Açıkla' : 'Explain Output',
                    onTap: () => _chatKey.currentState?.explainLastOutput(),
                  ),
                  const SizedBox(width: 4),
                ],
                _HeaderBtn(
                  icon: FluentIcons.search,
                  tooltip: _isTr ? 'Ara (Ctrl+F)' : 'Search (Ctrl+F)',
                  active: _showSearch,
                  onTap: _toggleSearch,
                ),
                const SizedBox(width: 4),
                _HeaderBtn(
                  icon: FluentIcons.history,
                  tooltip: _isTr ? 'Geçmiş' : 'History',
                  onTap: _showHistoryDialog,
                ),
                const SizedBox(width: 4),
                _HeaderBtn(
                  icon: FluentIcons.clear_selection,
                  tooltip: _isTr ? 'Temizle' : 'Clear',
                  onTap: () {
                    widget.controller.terminal.buffer.clear();
                    widget.controller.terminal.buffer.setCursor(0, 0);
                  },
                ),
                const SizedBox(width: 4),
                _HeaderBtn(
                  icon: FluentIcons.split_object,
                  tooltip: _isTr ? 'Yatay Böl' : 'Split Horizontal',
                  active: _splitMode == 1,
                  onTap: () => _toggleSplit(1),
                ),
                const SizedBox(width: 4),
                _HeaderBtn(
                  icon: FluentIcons.column_vertical_section,
                  tooltip: _isTr ? 'Dikey Böl' : 'Split Vertical',
                  active: _splitMode == 2,
                  onTap: () => _toggleSplit(2),
                ),
                if (!widget.controller.running) ...[
                  const SizedBox(width: 8),
                  GestureDetector(
                    onTap: () => widget.controller.start(),
                    child: Container(
                      height: 26,
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                      decoration: BoxDecoration(
                        color: workbenchAccent,
                        borderRadius: BorderRadius.circular(5),
                      ),
                      child: Center(
                        child: Text(
                          _isTr ? 'Başlat' : 'Start',
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
              ],
            ),
          ),
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
                    onSubmitted: _searchInTerminal,
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

        // ─── Terminal (with optional split) ─────────────────────────
        Expanded(
          child: _splitMode == 0
              ? _buildTerminalPane(
                  widget.controller.terminal,
                  _termCtrl,
                  tTheme,
                  bgOpacity,
                  fontSize,
                  lineHeight,
                  fontFamily,
                  schemeName,
                )
              : Flex(
                  direction: _splitMode == 1 ? Axis.vertical : Axis.horizontal,
                  children: [
                    Expanded(
                      child: _buildTerminalPane(
                        widget.controller.terminal,
                        _termCtrl,
                        tTheme,
                        bgOpacity,
                        fontSize,
                        lineHeight,
                        fontFamily,
                        schemeName,
                      ),
                    ),
                    Container(
                      width: _splitMode == 2 ? 1 : double.infinity,
                      height: _splitMode == 1 ? 1 : double.infinity,
                      color: workbenchAccent.withValues(alpha: 0.4),
                    ),
                    if (_splitController != null)
                      Expanded(
                        child: _buildTerminalPane(
                          _splitController!.terminal,
                          _splitTermCtrl,
                          tTheme,
                          bgOpacity,
                          fontSize,
                          lineHeight,
                          fontFamily,
                          schemeName,
                        ),
                      ),
                  ],
                ),
        ),

        // ─── AI Chat Panel ────────────────────────────────────────
        if (widget.appController != null)
          AiChatPanel(
            key: _chatKey,
            appController: widget.appController!,
            terminal: widget.controller.terminal,
            shellName: widget.controller.shellName,
            osInfo: _buildLocalOsInfo(),
            onExecuteCommand: _executeAiCommand,
            onRunTrackedCommand: _runAiTrackedCommandLocal,
            onInterruptCommand: _interruptAiCommand,
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
                // Command
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
                  const SizedBox(height: 6),
                  Text(
                    _aiSuggestion!.explanation!,
                    style: TextStyle(color: workbenchTextMuted, fontSize: 11),
                  ),
                ],
                const SizedBox(height: 10),
                // Action buttons
                Row(
                  children: [
                    GestureDetector(
                      onTap: _executeAiSuggestionWithPolicy,
                      child: Container(
                        height: 30,
                        padding: const EdgeInsets.symmetric(horizontal: 16),
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
                        padding: const EdgeInsets.symmetric(horizontal: 16),
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
                        padding: const EdgeInsets.symmetric(horizontal: 16),
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
                // Multi-step display
                if (_aiSuggestion!.isMultiStep &&
                    _aiSuggestion!.steps != null) ...[
                  const SizedBox(height: 10),
                  Text(
                    _isTr ? 'Adımlar:' : 'Steps:',
                    style: TextStyle(
                      color: workbenchAccent,
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 4),
                  for (int i = 0; i < _aiSuggestion!.steps!.length; i++)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 3),
                      child: Row(
                        children: [
                          Text(
                            '${i + 1}.',
                            style: TextStyle(
                              color: workbenchTextFaint,
                              fontSize: 11,
                            ),
                          ),
                          const SizedBox(width: 6),
                          Expanded(
                            child: Text(
                              _aiSuggestion!.steps![i],
                              style: TextStyle(
                                color: workbenchTextMuted,
                                fontSize: 11,
                                fontFamily: 'monospace',
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                ],
              ],
            ),
          ),

        // ─── Command Input Bar (Warp-style) ────────────────────────
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
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
                color: widget.controller.running
                    ? workbenchAccent
                    : workbenchTextFaint,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Focus(
                  onFocusChange: (f) => setState(() => _commandBarFocused = f),
                  child: KeyboardListener(
                    focusNode: FocusNode(),
                    onKeyEvent: (event) {
                      if (event is KeyDownEvent) {
                        if (event.logicalKey == LogicalKeyboardKey.arrowUp)
                          _historyUp();
                        if (event.logicalKey == LogicalKeyboardKey.arrowDown)
                          _historyDown();
                      }
                    },
                    child: TextBox(
                      controller: _cmdInputCtrl,
                      focusNode: _cmdInputFocus,
                      placeholder: _isTr
                          ? (_aiActive
                                ? 'Komut veya doğal dil yaz... (↑↓ geçmiş)'
                                : 'Komut yaz... (↑↓ geçmiş)')
                          : (_aiActive
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
              if (_lastCmdDuration != null) ...[
                const SizedBox(width: 8),
                Icon(FluentIcons.timer, size: 10, color: workbenchTextFaint),
                const SizedBox(width: 3),
                Text(
                  _lastCmdDuration!,
                  style: TextStyle(color: workbenchTextFaint, fontSize: 10),
                ),
              ],
              const SizedBox(width: 8),
              Text(
                '${_commandHistory.length}',
                style: TextStyle(color: workbenchTextFaint, fontSize: 10),
              ),
              const SizedBox(width: 4),
              Icon(FluentIcons.history, size: 10, color: workbenchTextFaint),
            ],
          ),
        ),
      ],
    );
  }
}

// ─── Quick Command ─────────────────────────────────────────────────

class _QCmd {
  const _QCmd(this.label, this.command, this.icon);
  final String label;
  final String command;
  final IconData icon;
}

class _TermSignalIntent extends Intent {
  const _TermSignalIntent(this.signal);
  final String signal;
}

class _TermActionIntent extends Intent {
  const _TermActionIntent(this.action);
  final String action;
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
            // Header row
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
            // Expanded details
            if (_expanded)
              Padding(
                padding: const EdgeInsets.fromLTRB(10, 0, 10, 10),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // Command
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
                    // Explanation
                    if (e.explanation != null) ...[
                      const SizedBox(height: 6),
                      Text(
                        e.explanation!,
                        style: TextStyle(
                          color: workbenchTextMuted,
                          fontSize: 11,
                          height: 1.4,
                        ),
                      ),
                    ],
                    // Steps
                    if (e.steps != null && e.steps!.isNotEmpty) ...[
                      const SizedBox(height: 6),
                      for (int i = 0; i < e.steps!.length; i++)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 2),
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
                    // Provider + model info
                    if (e.provider != null) ...[
                      const SizedBox(height: 6),
                      Text(
                        '${e.provider} / ${e.model ?? "?"}',
                        style: TextStyle(
                          color: workbenchTextFaint,
                          fontSize: 9,
                        ),
                      ),
                    ],
                    // Action buttons
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

// ─── History Tab Button ────────────────────────────────────────────

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

// ─── Snippet Row ───────────────────────────────────────────────────

class _SnippetRow extends StatefulWidget {
  const _SnippetRow({
    required this.snippet,
    required this.isTr,
    required this.onRun,
  });
  final Snippet snippet;
  final bool isTr;
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
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            widget.snippet.name,
                            style: TextStyle(
                              color: workbenchText,
                              fontSize: 12,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                        ),
                        if (widget.snippet.platform != 'all')
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 4,
                              vertical: 1,
                            ),
                            decoration: BoxDecoration(
                              color: workbenchHover,
                              borderRadius: BorderRadius.circular(3),
                            ),
                            child: Text(
                              widget.snippet.platform,
                              style: TextStyle(
                                color: workbenchTextFaint,
                                fontSize: 8,
                              ),
                            ),
                          ),
                      ],
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
                    if (widget.snippet.description.isNotEmpty) ...[
                      const SizedBox(height: 2),
                      Text(
                        widget.snippet.description,
                        style: TextStyle(
                          color: workbenchTextFaint,
                          fontSize: 10,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(width: 8),
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
