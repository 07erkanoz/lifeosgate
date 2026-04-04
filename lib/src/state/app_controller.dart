import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:lifeos_sftp_drive/src/utils/platform_utils.dart' as pu;
import 'package:lifeos_sftp_drive/src/models/connection_profile.dart';
import 'package:lifeos_sftp_drive/src/i18n/app_strings.dart';
import 'package:lifeos_sftp_drive/src/models/log_entry.dart';
import 'package:lifeos_sftp_drive/src/services/ai_service.dart';
import 'package:lifeos_sftp_drive/src/services/linux_mount_service.dart';
import 'package:lifeos_sftp_drive/src/services/sftp_browser_service.dart';
import 'package:lifeos_sftp_drive/src/services/snippet_service.dart';
import 'package:path_provider/path_provider.dart';

enum ActionSource { ui, tray }

/// Transfer progress info
class TransferProgress {
  TransferProgress({
    required this.fileName,
    required this.totalBytes,
    this.transferredBytes = 0,
    this.isComplete = false,
    this.isError = false,
    this.errorMsg,
  });
  final String fileName;
  final int totalBytes;
  int transferredBytes;
  bool isComplete;
  bool isError;
  String? errorMsg;
  double get progress =>
      totalBytes > 0 ? (transferredBytes / totalBytes).clamp(0.0, 1.0) : 0.0;
}

class AppController extends ChangeNotifier {
  AppController() {
    _connections = [];
    _initFuture = _loadFromDisk();
    addLog('Application started', level: LogLevel.info, notify: false);
  }

  late final Future<void> _initFuture;
  bool _loaded = false;

  /// Wait for settings/profiles to be loaded from disk.
  Future<void> get ready => _initFuture;

  final snippetService = SnippetService();

  late List<ConnectionProfile> _connections;
  final List<LogEntry> _logs = [];

  // ─── SFTP Session Pool (persists across tab switches) ──────────
  final Map<String, SftpConnectionSession> _sftpSessions = {};
  final List<TransferProgress> _activeTransfers = [];

  SftpConnectionSession? getSftpSession(String profileId) =>
      _sftpSessions[profileId];

  void setSftpSession(String profileId, SftpConnectionSession session) {
    _sftpSessions[profileId] = session;
  }

  Future<void> closeSftpSession(String profileId) async {
    final session = _sftpSessions.remove(profileId);
    await session?.close();
  }

  bool hasSftpSession(String profileId) => _sftpSessions.containsKey(profileId);

  List<TransferProgress> get activeTransfers =>
      List.unmodifiable(_activeTransfers);

  TransferProgress addTransfer(String fileName, int totalBytes) {
    final tp = TransferProgress(fileName: fileName, totalBytes: totalBytes);
    _activeTransfers.add(tp);
    notifyListeners();
    return tp;
  }

  void updateTransfer(
    TransferProgress tp, {
    int? transferred,
    bool? complete,
    bool? error,
    String? errorMsg,
  }) {
    if (transferred != null) tp.transferredBytes = transferred;
    if (complete != null) tp.isComplete = complete;
    if (error != null) tp.isError = error;
    if (errorMsg != null) tp.errorMsg = errorMsg;
    notifyListeners();
  }

  void removeTransfer(TransferProgress tp) {
    _activeTransfers.remove(tp);
    notifyListeners();
  }

  void clearCompletedTransfers() {
    _activeTransfers.removeWhere((t) => t.isComplete || t.isError);
    notifyListeners();
  }

  bool _minimizeToTray = true;
  bool _launchAtStartup = false;
  bool _linuxRegisterAsTerminal = false;
  AppLocale _locale = AppLocale.tr;

  // Terminal font settings
  String _terminalFontFamily = 'Cascadia Code';
  double _terminalFontSize = 15.0;
  double _terminalLineHeight = 1.35;
  String _terminalTheme = 'LifeOS Gate';
  String _terminalShell =
      'auto'; // 'auto' or shell id like 'powershell', 'wsl', 'gitbash'
  String _appThemeMode = 'dark'; // 'dark' or 'light'

  // Window effect settings
  String _windowEffect = pu.isWindows ? 'mica' : 'none';
  double _windowOpacity = 1.0;

  // Window geometry (remembered across sessions)
  double? _windowWidth;
  double? _windowHeight;
  double? _windowX;
  double? _windowY;

  // Alarm thresholds (percentage)
  double _cpuAlarmThreshold = 90.0;
  double _memAlarmThreshold = 90.0;
  double _diskAlarmThreshold = 90.0;
  bool _alarmsEnabled = true;

  // AI Assistant settings
  String _aiProvider =
      'gemini'; // gemini, claude, openai, openrouter, groq, grok
  String _aiModel = 'gemini-2.5-flash';
  String _aiApiKey = '';
  final Map<String, String> _aiApiKeysByProvider = {};
  bool _aiAutoExecute = false; // auto-run safe commands without confirmation
  bool _aiDangerConfirm = true; // always confirm dangerous commands
  bool _aiSmartDetect = true; // auto-detect natural language vs command
  // command card visibility in AI panel: off | error_only
  String _aiPanelCommandCardMode = 'error_only';
  bool _aiWatchMode = true; // verify-focused autonomous loop
  bool _aiPlanApproval = true; // require plan review before execution
  // auto | build | deploy | debug | ops
  String _aiToolbeltProfile = 'auto';
  bool _agentPageEnabled = true; // dedicated CLI agent page visibility

  // SSH Session Continuity settings
  // session mode: off | smart | always
  String _sshSessionMode = 'smart';
  bool _sshAutoReconnect = true;
  int _sshReconnectMaxAttempts = 8;
  // install policy: ask_once | never_install | auto_if_possible
  String _sshTmuxInstallPolicy = 'ask_once';
  bool _sshTimeMachineEnabled = true;
  int _sshTimeMachineMaxEvents = 4000;
  // hostKey -> allowed | denied
  final Map<String, String> _sshTmuxHostDecisions = {};
  // hostKey -> ['main', 'prod', ...]
  final Map<String, List<String>> _sshNamedSessionsByHost = {};
  // hostKey -> selected session name
  final Map<String, String> _sshActiveNamedSessionByHost = {};

  // AI History
  final List<AiHistoryEntry> _aiHistory = [];

  List<ConnectionProfile> get connections => List.unmodifiable(_connections);
  List<LogEntry> get logs => List.unmodifiable(_logs);

  bool get minimizeToTray => _minimizeToTray;
  bool get launchAtStartup => _launchAtStartup;
  bool get linuxRegisterAsTerminal => _linuxRegisterAsTerminal;
  AppLocale get locale => _locale;
  AppStrings get strings => AppStrings(_locale);

  int get mountedCount => _connections.where((e) => e.mounted).length;

  String get terminalFontFamily => _terminalFontFamily;
  double get terminalFontSize => _terminalFontSize;
  double get terminalLineHeight => _terminalLineHeight;
  String get terminalTheme => _terminalTheme;
  String get terminalShell => _terminalShell;
  String get appThemeMode => _appThemeMode;
  bool get isDarkMode => _appThemeMode == 'dark';
  String get windowEffect => _windowEffect;
  double get windowOpacity => _windowOpacity;
  double? get windowWidth => _windowWidth;
  double? get windowHeight => _windowHeight;
  double? get windowX => _windowX;
  double? get windowY => _windowY;

  double get cpuAlarmThreshold => _cpuAlarmThreshold;
  double get memAlarmThreshold => _memAlarmThreshold;
  double get diskAlarmThreshold => _diskAlarmThreshold;
  bool get alarmsEnabled => _alarmsEnabled;

  void setCpuAlarmThreshold(double v) {
    _cpuAlarmThreshold = v;
    notifyListeners();
    _saveSettings();
  }

  void setMemAlarmThreshold(double v) {
    _memAlarmThreshold = v;
    notifyListeners();
    _saveSettings();
  }

  void setDiskAlarmThreshold(double v) {
    _diskAlarmThreshold = v;
    notifyListeners();
    _saveSettings();
  }

  void setAlarmsEnabled(bool v) {
    _alarmsEnabled = v;
    notifyListeners();
    _saveSettings();
  }

  String get aiProvider => _aiProvider;
  String get aiModel => _aiModel;
  String get aiApiKey => _aiApiKey;
  Map<String, String> get aiApiKeysByProvider =>
      Map.unmodifiable(_aiApiKeysByProvider);
  bool get aiAutoExecute => _aiAutoExecute;
  bool get aiDangerConfirm => _aiDangerConfirm;
  bool get aiEnabled => aiApiKey.trim().isNotEmpty;
  bool get aiSmartDetect => _aiSmartDetect;
  String get aiPanelCommandCardMode => _aiPanelCommandCardMode;
  bool get aiWatchMode => _aiWatchMode;
  bool get aiPlanApproval => _aiPlanApproval;
  String get aiToolbeltProfile => _aiToolbeltProfile;
  bool get agentPageEnabled => _agentPageEnabled;
  String get sshSessionMode => _sshSessionMode;
  bool get sshAutoReconnect => _sshAutoReconnect;
  int get sshReconnectMaxAttempts => _sshReconnectMaxAttempts;
  String get sshTmuxInstallPolicy => _sshTmuxInstallPolicy;
  bool get sshTimeMachineEnabled => _sshTimeMachineEnabled;
  int get sshTimeMachineMaxEvents => _sshTimeMachineMaxEvents;
  Map<String, String> get sshTmuxHostDecisions =>
      Map.unmodifiable(_sshTmuxHostDecisions);
  Map<String, List<String>> get sshNamedSessionsByHost =>
      Map.unmodifiable(_sshNamedSessionsByHost);
  Map<String, String> get sshActiveNamedSessionByHost =>
      Map.unmodifiable(_sshActiveNamedSessionByHost);

  void setTerminalFontFamily(String value) {
    _terminalFontFamily = value;
    notifyListeners();
    _saveSettings();
  }

  void setTerminalFontSize(double value) {
    _terminalFontSize = value;
    notifyListeners();
    _saveSettings();
  }

  void setTerminalLineHeight(double value) {
    _terminalLineHeight = value;
    notifyListeners();
    _saveSettings();
  }

  void setTerminalTheme(String value) {
    _terminalTheme = value;
    notifyListeners();
    _saveSettings();
  }

  void setTerminalShell(String value) {
    _terminalShell = value;
    notifyListeners();
    _saveSettings();
  }

  void setAppThemeMode(String value) {
    _appThemeMode = value;
    // Auto-switch terminal theme to match
    final isLightTerm =
        _terminalTheme.contains('Light') ||
        _terminalTheme.contains('Latte') ||
        _terminalTheme.contains('GitHub');
    if (value == 'light' && !isLightTerm) _terminalTheme = 'LifeOS Light';
    if (value == 'dark' && isLightTerm) _terminalTheme = 'LifeOS Gate';
    notifyListeners();
    _saveSettings();
  }

  void setWindowEffect(String value) {
    _windowEffect = value;
    notifyListeners();
    _saveSettings();
  }

  void setWindowOpacity(double value) {
    _windowOpacity = value.clamp(0.3, 1.0).toDouble();
    notifyListeners();
    _saveSettings();
  }

  void setAiProvider(String value) {
    _aiProvider = value;
    _aiApiKey = _aiApiKeysByProvider[value] ?? '';
    notifyListeners();
    _saveSettings();
  }

  void setAiModel(String value) {
    _aiModel = value;
    notifyListeners();
    _saveSettings();
  }

  void setAiApiKey(String value) {
    final normalized = value.trim();
    _aiApiKey = normalized;
    if (normalized.isEmpty) {
      _aiApiKeysByProvider.remove(_aiProvider);
    } else {
      _aiApiKeysByProvider[_aiProvider] = normalized;
    }
    notifyListeners();
    _saveSettings();
  }

  void setAiAutoExecute(bool value) {
    _aiAutoExecute = value;
    notifyListeners();
    _saveSettings();
  }

  void setAiDangerConfirm(bool value) {
    _aiDangerConfirm = value;
    notifyListeners();
    _saveSettings();
  }

  void setAiSmartDetect(bool value) {
    _aiSmartDetect = value;
    notifyListeners();
    _saveSettings();
  }

  void setAiPanelCommandCardMode(String value) {
    const allowed = {'off', 'error_only'};
    _aiPanelCommandCardMode = allowed.contains(value) ? value : 'error_only';
    notifyListeners();
    _saveSettings();
  }

  void setAiWatchMode(bool value) {
    _aiWatchMode = value;
    notifyListeners();
    _saveSettings();
  }

  void setAiPlanApproval(bool value) {
    _aiPlanApproval = value;
    notifyListeners();
    _saveSettings();
  }

  void setAiToolbeltProfile(String value) {
    const allowed = {'auto', 'build', 'deploy', 'debug', 'ops'};
    _aiToolbeltProfile = allowed.contains(value) ? value : 'auto';
    notifyListeners();
    _saveSettings();
  }

  void setAgentPageEnabled(bool value) {
    _agentPageEnabled = value;
    notifyListeners();
    _saveSettings();
  }

  void setSshSessionMode(String value) {
    const allowed = {'off', 'smart', 'always'};
    _sshSessionMode = allowed.contains(value) ? value : 'smart';
    notifyListeners();
    _saveSettings();
  }

  void setSshAutoReconnect(bool value) {
    _sshAutoReconnect = value;
    notifyListeners();
    _saveSettings();
  }

  void setSshReconnectMaxAttempts(int value) {
    _sshReconnectMaxAttempts = value.clamp(1, 30).toInt();
    notifyListeners();
    _saveSettings();
  }

  void setSshTmuxInstallPolicy(String value) {
    const allowed = {'ask_once', 'never_install', 'auto_if_possible'};
    _sshTmuxInstallPolicy = allowed.contains(value) ? value : 'ask_once';
    notifyListeners();
    _saveSettings();
  }

  void setSshTimeMachineEnabled(bool value) {
    _sshTimeMachineEnabled = value;
    notifyListeners();
    _saveSettings();
  }

  void setSshTimeMachineMaxEvents(int value) {
    _sshTimeMachineMaxEvents = value.clamp(500, 20000).toInt();
    notifyListeners();
    _saveSettings();
  }

  String getTmuxHostDecision(String hostKey) {
    final value = _sshTmuxHostDecisions[hostKey];
    if (value == 'allowed') return 'allowed';
    if (value == 'denied') return 'denied';
    return 'unknown';
  }

  void setTmuxHostDecision(String hostKey, String decision) {
    if (hostKey.trim().isEmpty) return;
    if (decision != 'allowed' && decision != 'denied') return;
    _sshTmuxHostDecisions[hostKey] = decision;
    notifyListeners();
    _saveSettings();
  }

  void clearTmuxHostDecision(String hostKey) {
    if (hostKey.trim().isEmpty) return;
    if (_sshTmuxHostDecisions.remove(hostKey) == null) return;
    notifyListeners();
    _saveSettings();
  }

  void clearTmuxHostDecisions() {
    if (_sshTmuxHostDecisions.isEmpty) return;
    _sshTmuxHostDecisions.clear();
    notifyListeners();
    _saveSettings();
  }

  List<String> getSshNamedSessionsForHost(String hostKey) {
    final current = _sshNamedSessionsByHost[hostKey];
    if (current == null || current.isEmpty) {
      return const ['main'];
    }
    return List.unmodifiable(current);
  }

  String getSshActiveSessionNameForHost(String hostKey) {
    final sessions = getSshNamedSessionsForHost(hostKey);
    final selected = _sshActiveNamedSessionByHost[hostKey];
    if (selected != null && sessions.contains(selected)) {
      return selected;
    }
    return sessions.first;
  }

  void setSshNamedSessionsForHost(String hostKey, List<String> names) {
    if (hostKey.trim().isEmpty) return;
    final normalized = _normalizeSessionNames(names);
    _sshNamedSessionsByHost[hostKey] = normalized;
    final currentSelected = _sshActiveNamedSessionByHost[hostKey];
    if (currentSelected == null || !normalized.contains(currentSelected)) {
      _sshActiveNamedSessionByHost[hostKey] = normalized.first;
    }
    notifyListeners();
    _saveSettings();
  }

  void setSshActiveSessionNameForHost(String hostKey, String sessionName) {
    if (hostKey.trim().isEmpty) return;
    final normalized = _normalizeSessionNames([sessionName]);
    final chosen = normalized.first;
    final sessions = _normalizeSessionNames([
      ...getSshNamedSessionsForHost(hostKey),
      chosen,
    ]);
    _sshNamedSessionsByHost[hostKey] = sessions;
    _sshActiveNamedSessionByHost[hostKey] = chosen;
    notifyListeners();
    _saveSettings();
  }

  List<String> _normalizeSessionNames(List<String> names) {
    final seen = <String>{};
    final out = <String>[];
    for (final raw in names) {
      final value = raw.trim();
      if (value.isEmpty) continue;
      if (seen.add(value)) {
        out.add(value);
      }
    }
    if (out.isEmpty) {
      return ['main'];
    }
    return out;
  }

  List<AiHistoryEntry> get aiHistory => List.unmodifiable(_aiHistory);

  void addAiHistory(AiHistoryEntry entry) {
    _aiHistory.insert(0, entry);
    if (_aiHistory.length > 100) _aiHistory.removeLast(); // keep last 100
    notifyListeners();
    _saveAiHistory();
  }

  void clearAiHistory() {
    _aiHistory.clear();
    notifyListeners();
    _saveAiHistory();
  }

  Future<void> _saveAiHistory() async {
    try {
      final dir = await getApplicationSupportDirectory();
      final file = File('${dir.path}${Platform.pathSeparator}ai_history.json');
      await file.writeAsString(
        jsonEncode(_aiHistory.map((e) => e.toJson()).toList()),
      );
    } catch (_) {}
  }

  Future<void> _loadAiHistory() async {
    try {
      final dir = await getApplicationSupportDirectory();
      final file = File('${dir.path}${Platform.pathSeparator}ai_history.json');
      if (await file.exists()) {
        final list = (jsonDecode(await file.readAsString()) as List)
            .cast<Map<String, dynamic>>();
        _aiHistory.addAll(list.map((e) => AiHistoryEntry.fromJson(e)));
      }
    } catch (_) {}
  }

  void setWindowGeometry({
    double? width,
    double? height,
    double? x,
    double? y,
  }) {
    _windowWidth = width ?? _windowWidth;
    _windowHeight = height ?? _windowHeight;
    _windowX = x ?? _windowX;
    _windowY = y ?? _windowY;
    _saveSettings();
  }

  // ─── Persistence ─────────────────────────────────────────────────

  Future<File> get _storageFile async {
    final dir = await getApplicationSupportDirectory();
    return File('${dir.path}${Platform.pathSeparator}profiles.json');
  }

  Future<File> get _settingsFile async {
    final dir = await getApplicationSupportDirectory();
    return File('${dir.path}${Platform.pathSeparator}settings.json');
  }

  Future<void> _loadFromDisk() async {
    try {
      final file = await _storageFile;
      if (await file.exists()) {
        final raw = await file.readAsString();
        final list = (jsonDecode(raw) as List).cast<Map<String, dynamic>>();
        _connections = list.map((e) => ConnectionProfile.fromJson(e)).toList();
      }
    } catch (e) {
      addLog('Failed to load profiles: $e', level: LogLevel.error);
    }
    try {
      final sf = await _settingsFile;
      if (await sf.exists()) {
        final map = jsonDecode(await sf.readAsString()) as Map<String, dynamic>;
        _terminalFontFamily =
            (map['terminalFontFamily'] as String?) ?? _terminalFontFamily;
        _terminalFontSize =
            (map['terminalFontSize'] as num?)?.toDouble() ?? _terminalFontSize;
        _terminalLineHeight =
            (map['terminalLineHeight'] as num?)?.toDouble() ??
            _terminalLineHeight;
        _terminalTheme = (map['terminalTheme'] as String?) ?? _terminalTheme;
        _terminalShell = (map['terminalShell'] as String?) ?? _terminalShell;
        _appThemeMode = (map['appThemeMode'] as String?) ?? _appThemeMode;
        _windowEffect = (map['windowEffect'] as String?) ?? _windowEffect;
        _windowOpacity =
            ((map['windowOpacity'] as num?)?.toDouble() ?? _windowOpacity)
                .clamp(0.3, 1.0)
                .toDouble();
        _locale = (map['locale'] as String?) == 'en'
            ? AppLocale.en
            : AppLocale.tr;
        _minimizeToTray = (map['minimizeToTray'] as bool?) ?? _minimizeToTray;
        _launchAtStartup =
            (map['launchAtStartup'] as bool?) ?? _launchAtStartup;
        _linuxRegisterAsTerminal =
            (map['linuxRegisterAsTerminal'] as bool?) ??
            _linuxRegisterAsTerminal;
        _aiProvider = (map['aiProvider'] as String?) ?? _aiProvider;
        _aiModel = (map['aiModel'] as String?) ?? _aiModel;
        _aiApiKey = (map['aiApiKey'] as String?) ?? _aiApiKey;
        _aiApiKeysByProvider.clear();
        final aiKeysRaw = map['aiApiKeysByProvider'];
        if (aiKeysRaw is Map) {
          aiKeysRaw.forEach((key, value) {
            final provider = key.toString().trim();
            final apiKey = value.toString().trim();
            if (provider.isEmpty || apiKey.isEmpty) return;
            _aiApiKeysByProvider[provider] = apiKey;
          });
        }
        // Backward compatibility: migrate legacy single key to current provider.
        if (_aiApiKey.trim().isNotEmpty &&
            !_aiApiKeysByProvider.containsKey(_aiProvider)) {
          _aiApiKeysByProvider[_aiProvider] = _aiApiKey.trim();
        }
        _aiApiKey = _aiApiKeysByProvider[_aiProvider] ?? '';
        _aiAutoExecute = (map['aiAutoExecute'] as bool?) ?? _aiAutoExecute;
        _aiDangerConfirm =
            (map['aiDangerConfirm'] as bool?) ?? _aiDangerConfirm;
        _aiSmartDetect = (map['aiSmartDetect'] as bool?) ?? _aiSmartDetect;
        _aiPanelCommandCardMode =
            (map['aiPanelCommandCardMode'] as String?) ??
            _aiPanelCommandCardMode;
        if (_aiPanelCommandCardMode != 'off' &&
            _aiPanelCommandCardMode != 'error_only') {
          _aiPanelCommandCardMode = 'error_only';
        }
        _aiWatchMode = (map['aiWatchMode'] as bool?) ?? _aiWatchMode;
        _aiPlanApproval =
            (map['aiPlanApproval'] as bool?) ?? _aiPlanApproval;
        _aiToolbeltProfile =
            (map['aiToolbeltProfile'] as String?) ?? _aiToolbeltProfile;
        if (_aiToolbeltProfile != 'auto' &&
            _aiToolbeltProfile != 'build' &&
            _aiToolbeltProfile != 'deploy' &&
            _aiToolbeltProfile != 'debug' &&
            _aiToolbeltProfile != 'ops') {
          _aiToolbeltProfile = 'auto';
        }
        _agentPageEnabled =
            (map['agentPageEnabled'] as bool?) ?? _agentPageEnabled;
        _sshSessionMode = (map['sshSessionMode'] as String?) ?? _sshSessionMode;
        if (_sshSessionMode != 'off' &&
            _sshSessionMode != 'smart' &&
            _sshSessionMode != 'always') {
          _sshSessionMode = 'smart';
        }
        _sshAutoReconnect =
            (map['sshAutoReconnect'] as bool?) ?? _sshAutoReconnect;
        _sshReconnectMaxAttempts =
            ((map['sshReconnectMaxAttempts'] as num?)?.toInt() ??
                    _sshReconnectMaxAttempts)
                .clamp(1, 30);
        _sshTmuxInstallPolicy =
            (map['sshTmuxInstallPolicy'] as String?) ?? _sshTmuxInstallPolicy;
        if (_sshTmuxInstallPolicy != 'ask_once' &&
            _sshTmuxInstallPolicy != 'never_install' &&
            _sshTmuxInstallPolicy != 'auto_if_possible') {
          _sshTmuxInstallPolicy = 'ask_once';
        }
        _sshTimeMachineEnabled =
            (map['sshTimeMachineEnabled'] as bool?) ?? _sshTimeMachineEnabled;
        _sshTimeMachineMaxEvents =
            ((map['sshTimeMachineMaxEvents'] as num?)?.toInt() ??
                    _sshTimeMachineMaxEvents)
                .clamp(500, 20000);
        _sshTmuxHostDecisions.clear();
        final hostDecisionsRaw = map['sshTmuxHostDecisions'];
        if (hostDecisionsRaw is Map) {
          hostDecisionsRaw.forEach((key, value) {
            final k = key.toString();
            final v = value.toString();
            if (k.isEmpty) return;
            if (v == 'allowed' || v == 'denied') {
              _sshTmuxHostDecisions[k] = v;
            }
          });
        }
        _sshNamedSessionsByHost.clear();
        final namedSessionsRaw = map['sshNamedSessionsByHost'];
        if (namedSessionsRaw is Map) {
          namedSessionsRaw.forEach((key, value) {
            final hostKey = key.toString();
            if (hostKey.trim().isEmpty) return;
            if (value is List) {
              final sessions = _normalizeSessionNames(
                value.map((e) => e.toString()).toList(),
              );
              _sshNamedSessionsByHost[hostKey] = sessions;
            }
          });
        }
        _sshActiveNamedSessionByHost.clear();
        final activeNamedRaw = map['sshActiveNamedSessionByHost'];
        if (activeNamedRaw is Map) {
          activeNamedRaw.forEach((key, value) {
            final hostKey = key.toString();
            final selected = value.toString().trim();
            if (hostKey.isEmpty || selected.isEmpty) return;
            final sessions = getSshNamedSessionsForHost(hostKey);
            if (sessions.contains(selected)) {
              _sshActiveNamedSessionByHost[hostKey] = selected;
            }
          });
        }
        _cpuAlarmThreshold =
            (map['cpuAlarmThreshold'] as num?)?.toDouble() ??
            _cpuAlarmThreshold;
        _memAlarmThreshold =
            (map['memAlarmThreshold'] as num?)?.toDouble() ??
            _memAlarmThreshold;
        _diskAlarmThreshold =
            (map['diskAlarmThreshold'] as num?)?.toDouble() ??
            _diskAlarmThreshold;
        _alarmsEnabled = (map['alarmsEnabled'] as bool?) ?? _alarmsEnabled;
        _windowWidth = (map['windowWidth'] as num?)?.toDouble();
        _windowHeight = (map['windowHeight'] as num?)?.toDouble();
        _windowX = (map['windowX'] as num?)?.toDouble();
        _windowY = (map['windowY'] as num?)?.toDouble();
      }
    } catch (_) {}
    try {
      await _loadAiHistory();
    } catch (_) {}
    try {
      await snippetService.load();
    } catch (_) {}
    _loaded = true;
    notifyListeners();

    // On Linux, detect mount status in background so startup UI is not delayed.
    if (pu.isLinux) {
      _refreshMountedProfilesInBackground();
    }
  }

  Future<void> _saveSettings() async {
    if (!_loaded)
      return; // Don't overwrite disk with default values before load completes
    try {
      final sf = await _settingsFile;
      await sf.writeAsString(
        jsonEncode({
          'terminalFontFamily': _terminalFontFamily,
          'terminalFontSize': _terminalFontSize,
          'terminalLineHeight': _terminalLineHeight,
          'terminalTheme': _terminalTheme,
          'terminalShell': _terminalShell,
          'appThemeMode': _appThemeMode,
          'windowEffect': _windowEffect,
          'windowOpacity': _windowOpacity,
          'locale': _locale == AppLocale.en ? 'en' : 'tr',
          'minimizeToTray': _minimizeToTray,
          'launchAtStartup': _launchAtStartup,
          'linuxRegisterAsTerminal': _linuxRegisterAsTerminal,
          'aiProvider': _aiProvider,
          'aiModel': _aiModel,
          'aiApiKey': _aiApiKey,
          if (_aiApiKeysByProvider.isNotEmpty)
            'aiApiKeysByProvider': _aiApiKeysByProvider,
          'aiAutoExecute': _aiAutoExecute,
          'aiDangerConfirm': _aiDangerConfirm,
          'aiSmartDetect': _aiSmartDetect,
          'aiPanelCommandCardMode': _aiPanelCommandCardMode,
          'aiWatchMode': _aiWatchMode,
          'aiPlanApproval': _aiPlanApproval,
          'aiToolbeltProfile': _aiToolbeltProfile,
          'agentPageEnabled': _agentPageEnabled,
          'sshSessionMode': _sshSessionMode,
          'sshAutoReconnect': _sshAutoReconnect,
          'sshReconnectMaxAttempts': _sshReconnectMaxAttempts,
          'sshTmuxInstallPolicy': _sshTmuxInstallPolicy,
          'sshTimeMachineEnabled': _sshTimeMachineEnabled,
          'sshTimeMachineMaxEvents': _sshTimeMachineMaxEvents,
          if (_sshTmuxHostDecisions.isNotEmpty)
            'sshTmuxHostDecisions': _sshTmuxHostDecisions,
          if (_sshNamedSessionsByHost.isNotEmpty)
            'sshNamedSessionsByHost': _sshNamedSessionsByHost,
          if (_sshActiveNamedSessionByHost.isNotEmpty)
            'sshActiveNamedSessionByHost': _sshActiveNamedSessionByHost,
          'cpuAlarmThreshold': _cpuAlarmThreshold,
          'memAlarmThreshold': _memAlarmThreshold,
          'diskAlarmThreshold': _diskAlarmThreshold,
          'alarmsEnabled': _alarmsEnabled,
          if (_windowWidth != null) 'windowWidth': _windowWidth,
          if (_windowHeight != null) 'windowHeight': _windowHeight,
          if (_windowX != null) 'windowX': _windowX,
          if (_windowY != null) 'windowY': _windowY,
        }),
      );
    } catch (_) {}
  }

  Future<void> _saveToDisk() async {
    if (!_loaded)
      return; // Don't overwrite disk with default values before load completes
    try {
      final file = await _storageFile;
      final json = _connections.map((e) => e.toJson()).toList();
      await file.writeAsString(jsonEncode(json));
    } catch (e) {
      addLog('Failed to save profiles: $e', level: LogLevel.error);
    }
  }

  void _refreshMountedProfilesInBackground() {
    Future<void>(() async {
      try {
        final changed = await _detectMountedProfiles();
        if (changed) {
          notifyListeners();
        }
      } catch (_) {}
    });
  }

  Future<bool> _detectMountedProfiles() async {
    try {
      final linuxMount = LinuxMountService();
      if (_connections.isEmpty) return false;

      final profiles = List<ConnectionProfile>.from(_connections);
      final mountPoints = profiles
          .map((profile) => linuxMount.getMountPoint(profile))
          .toList(growable: false);
      final mountedStates = await Future.wait(
        mountPoints.map((mountPoint) => linuxMount.isMounted(mountPoint)),
      );

      var changed = false;
      final mountMap = <String, ({bool mounted, String mountPoint})>{};
      for (int i = 0; i < profiles.length; i++) {
        mountMap[profiles[i].id] = (
          mounted: mountedStates[i],
          mountPoint: mountPoints[i],
        );
      }

      _connections = _connections.map((profile) {
        final state = mountMap[profile.id];
        if (state == null) return profile;
        if (state.mounted && !profile.mounted) {
          changed = true;
          return profile.copyWith(
            mounted: true,
            mountedDriveLetter: state.mountPoint,
          );
        }
        if (!state.mounted && profile.mounted) {
          changed = true;
          return profile.copyWith(mounted: false, mountedDriveLetter: null);
        }
        return profile;
      }).toList();

      return changed;
    } catch (_) {
      return false;
    }
  }

  // ─── Connections ─────────────────────────────────────────────────

  void addConnection({
    required String name,
    required String host,
    required int port,
    required String username,
    required String remotePath,
    String password = '',
    String? privateKeyPath,
    String? preferredDriveLetter,
    String? group,
    String? color,
    List<String>? startupCommands,
    String? notes,
    bool tmuxEnabled = true,
    String? dbUser,
    String? dbPassword,
  }) {
    _connections = [
      ..._connections,
      ConnectionProfile(
        id: DateTime.now().microsecondsSinceEpoch.toString(),
        name: name,
        host: host,
        port: port,
        username: username,
        remotePath: remotePath.trim(),
        password: password,
        privateKeyPath: privateKeyPath,
        preferredDriveLetter: preferredDriveLetter,
        group: group,
        color: color,
        startupCommands: startupCommands ?? const [],
        notes: notes ?? '',
        tmuxEnabled: tmuxEnabled,
        dbUser: dbUser,
        dbPassword: dbPassword,
      ),
    ];
    addLog('Connection "$name" added', level: LogLevel.info, notify: false);
    notifyListeners();
    _saveToDisk();
  }

  void updateConnection({
    required String id,
    required String name,
    required String host,
    required int port,
    required String username,
    required String remotePath,
    String password = '',
    String? privateKeyPath,
    String? preferredDriveLetter,
    String? group,
    String? color,
    List<String>? startupCommands,
    String? notes,
    bool? tmuxEnabled,
    String? dbUser,
    String? dbPassword,
  }) {
    _connections = _connections
        .map(
          (item) => item.id == id
              ? item.copyWith(
                  name: name,
                  host: host,
                  port: port,
                  username: username,
                  remotePath: remotePath.trim(),
                  password: password,
                  privateKeyPath: privateKeyPath,
                  preferredDriveLetter: preferredDriveLetter,
                  group: group,
                  color: color,
                  startupCommands: startupCommands,
                  notes: notes,
                  tmuxEnabled: tmuxEnabled,
                  dbUser: dbUser,
                  dbPassword: dbPassword,
                )
              : item,
        )
        .toList();
    addLog('Connection "$name" updated', level: LogLevel.info, notify: false);
    notifyListeners();
    _saveToDisk();
  }

  void removeConnection(String id) {
    final target = _connections.firstWhereOrNull((item) => item.id == id);
    _connections = _connections.where((item) => item.id != id).toList();
    addLog(
      'Connection "${target?.name ?? id}" removed',
      level: LogLevel.warning,
      notify: false,
    );
    notifyListeners();
    _saveToDisk();
  }

  // ─── Mount ───────────────────────────────────────────────────────

  void toggleMount(String id, {required ActionSource source}) {
    final target = _connections.firstWhereOrNull((item) => item.id == id);
    if (target == null) return;
    target.mounted ? unmount(id, source: source) : mount(id, source: source);
  }

  void mount(String id, {required ActionSource source}) {
    final target = _connections.firstWhereOrNull((item) => item.id == id);
    if (target == null || target.mounted) return;
    _connections = _connections
        .map(
          (item) => item.id == id
              ? item.copyWith(mounted: true, mountedDriveLetter: null)
              : item,
        )
        .toList();
    addLog(
      'Mounted "${target.name}" from ${source.name}',
      level: LogLevel.info,
      notify: false,
    );
    notifyListeners();
  }

  void markMounted(
    String id, {
    required ActionSource source,
    required String? driveLetter,
  }) {
    final target = _connections.firstWhereOrNull((item) => item.id == id);
    if (target == null) return;
    _connections = _connections
        .map(
          (item) => item.id == id
              ? item.copyWith(mounted: true, mountedDriveLetter: driveLetter)
              : item,
        )
        .toList();
    addLog(
      'Mounted "${target.name}" from ${source.name}${driveLetter == null ? "" : " as $driveLetter:"}',
      level: LogLevel.info,
      notify: false,
    );
    notifyListeners();
  }

  void unmount(String id, {required ActionSource source}) {
    final target = _connections.firstWhereOrNull((item) => item.id == id);
    if (target == null || !target.mounted) return;
    _connections = _connections
        .map(
          (item) => item.id == id
              ? item.copyWith(mounted: false, mountedDriveLetter: null)
              : item,
        )
        .toList();
    addLog(
      'Unmounted "${target.name}" from ${source.name}',
      level: LogLevel.info,
      notify: false,
    );
    notifyListeners();
  }

  void markUnmounted(String id, {required ActionSource source}) {
    final target = _connections.firstWhereOrNull((item) => item.id == id);
    if (target == null) return;
    _connections = _connections
        .map(
          (item) => item.id == id
              ? item.copyWith(mounted: false, mountedDriveLetter: null)
              : item,
        )
        .toList();
    addLog(
      'Unmounted "${target.name}" from ${source.name}',
      level: LogLevel.info,
      notify: false,
    );
    notifyListeners();
  }

  void mountAll({required ActionSource source}) {
    _connections = _connections
        .map((item) => item.copyWith(mounted: true, mountedDriveLetter: null))
        .toList();
    addLog(
      'Mounted all from ${source.name}',
      level: LogLevel.info,
      notify: false,
    );
    notifyListeners();
  }

  void unmountAll({required ActionSource source}) {
    _connections = _connections
        .map((item) => item.copyWith(mounted: false, mountedDriveLetter: null))
        .toList();
    addLog(
      'Unmounted all from ${source.name}',
      level: LogLevel.info,
      notify: false,
    );
    notifyListeners();
  }

  // ─── Settings ────────────────────────────────────────────────────

  void setMinimizeToTray(bool value) {
    _minimizeToTray = value;
    addLog(
      'Hide on close ${value ? "enabled" : "disabled"}',
      level: LogLevel.info,
      notify: false,
    );
    notifyListeners();
    _saveSettings();
  }

  void setLaunchAtStartup(bool value) {
    _launchAtStartup = value;
    addLog(
      'Launch at startup ${value ? "enabled" : "disabled"}',
      level: LogLevel.info,
      notify: false,
    );
    notifyListeners();
    _saveSettings();
  }

  void setLinuxRegisterAsTerminal(bool value) {
    _linuxRegisterAsTerminal = value;
    addLog(
      'Linux terminal integration ${value ? "enabled" : "disabled"}',
      level: LogLevel.info,
      notify: false,
    );
    notifyListeners();
    _saveSettings();
  }

  void setLocale(AppLocale value) {
    _locale = value;
    notifyListeners();
    _saveSettings();
  }

  // ─── Logs ────────────────────────────────────────────────────────

  void addLog(String message, {required LogLevel level, bool notify = true}) {
    _logs.add(LogEntry(time: DateTime.now(), level: level, message: message));
    if (notify) notifyListeners();
  }

  void clearLogs() {
    _logs.clear();
    notifyListeners();
  }
}

extension _IterableExt<T> on Iterable<T> {
  T? firstWhereOrNull(bool Function(T item) test) {
    for (final item in this) {
      if (test(item)) return item;
    }
    return null;
  }
}
