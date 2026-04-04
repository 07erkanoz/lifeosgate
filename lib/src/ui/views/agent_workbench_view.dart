import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter/services.dart';
import 'package:lifeos_sftp_drive/src/models/connection_profile.dart';
import 'package:lifeos_sftp_drive/src/services/agent_cli_service.dart';
import 'package:path_provider/path_provider.dart' as path_provider;
import 'package:lifeos_sftp_drive/src/state/app_controller.dart';
import 'package:lifeos_sftp_drive/src/ui/theme_tokens.dart';
import 'package:lifeos_sftp_drive/src/utils/platform_utils.dart' as pu;
import 'package:lifeos_sftp_drive/src/ui/widgets/agent_diff_viewer.dart';

// DEBUG: temporary file logger
void _debugLog(String msg) {
  try {
    File('C:\\Projeler\\debug_agent.log').writeAsStringSync(
      '${DateTime.now().toIso8601String()} $msg\n',
      mode: FileMode.append,
    );
  } catch (_) {}
}

// ── Provider colors ─────────────────────────────────────────────
const _claudeColor = Color(0xFF6366F1);
const _codexColor = Color(0xFF22C55E);
const _geminiColor = Color(0xFF3B82F6);

Color _providerColor(AgentCliProvider p) {
  switch (p) {
    case AgentCliProvider.claude:
      return _claudeColor;
    case AgentCliProvider.codex:
      return _codexColor;
    case AgentCliProvider.gemini:
      return _geminiColor;
  }
}

String _providerInitial(AgentCliProvider p) {
  switch (p) {
    case AgentCliProvider.claude:
      return 'C';
    case AgentCliProvider.codex:
      return 'X';
    case AgentCliProvider.gemini:
      return 'G';
  }
}

class AgentWorkbenchView extends StatefulWidget {
  const AgentWorkbenchView({
    super.key,
    required this.appController,
    this.onSendLocalTerminalCommand,
    this.onSendSshTerminalCommand,
  });

  final AppController appController;
  final Future<void> Function(String command)? onSendLocalTerminalCommand;
  final Future<void> Function(ConnectionProfile profile, String command)?
      onSendSshTerminalCommand;

  @override
  State<AgentWorkbenchView> createState() => _AgentWorkbenchViewState();
}

class _AgentWorkbenchViewState extends State<AgentWorkbenchView> {
  final AgentCliStore _store = AgentCliStore();
  final AgentCliRuntime _runtime = AgentCliRuntime();
  final TextEditingController _inputCtrl = TextEditingController();
  final ScrollController _scrollCtrl = ScrollController();
  final FocusNode _inputFocus = FocusNode();

  AgentCliStoreData _data = AgentCliStoreData.initial();
  bool _loading = true;
  bool _checkingCli = false;
  // Per-provider sending/stop state — getter/setter preserves all existing references
  final Map<String, bool> _sendingByProvider = {};
  bool get _sending => _sendingByProvider[_provider.id] ?? false;

  final Map<String, bool> _stopByProvider = {};
  String? _activeRunProviderId;
  bool _cliReady = false;
  String _status = '';
  bool _showSessionDrawer = false;
  bool _showSettings = false;
  // CWD is per-provider: each provider can work on a different project
  final Map<String, String> _cwdByProvider = {};
  String get _cwd => _cwdByProvider[_provider.id] ?? '';
  set _cwd(String value) => _cwdByProvider[_provider.id] = value;
  String _approvalMode = 'auto';
  double _totalCost = 0;
  double _fontSize = 13.0;
  bool _fullscreen = false;

  bool get _isTr => widget.appController.locale.name == 'tr';
  AgentCliProvider get _provider => _data.provider;
  AgentCliTarget get _target => _data.target;

  String get _selectedModel {
    return _data.selectedModelByProvider[_provider.id] ??
        _provider.defaultModel;
  }

  List<ConnectionProfile> get _profiles => widget.appController.connections;

  ConnectionProfile? get _selectedProfile {
    if (_target != AgentCliTarget.ssh) return null;
    final id = _data.selectedProfileByProvider[_provider.id] ?? '';
    for (final p in _profiles) {
      if (p.id == id) return p;
    }
    return _profiles.isNotEmpty ? _profiles.first : null;
  }

  /// Normalize CWD for scope key (lowercase on Windows, trim trailing slashes)
  String _normalizeCwdForScope(String cwd) {
    var c = cwd.trim();
    if (c.isEmpty) return '';
    // Normalize path separators
    c = c.replaceAll('\\', '/');
    // Remove trailing slash (except root)
    while (c.length > 1 && c.endsWith('/')) {
      c = c.substring(0, c.length - 1);
    }
    if (pu.isWindows) c = c.toLowerCase();
    return c;
  }

  String get _scopeKey {
    final cwdPart = _normalizeCwdForScope(_cwd);
    if (_target == AgentCliTarget.local) {
      return 'local:${_provider.id}:$cwdPart';
    }
    final profileId = _selectedProfile?.id ?? '';
    return 'ssh:${_provider.id}:$profileId:$cwdPart';
  }

  List<AgentCliSession> _scopeSessionsFor(AgentCliStoreData data) {
    final provider = data.provider;
    final target = data.target;
    String? profileId;
    if (target == AgentCliTarget.ssh) {
      final selectedPid = (data.selectedProfileByProvider[data.provider.id] ?? '').trim();
      if (selectedPid.isNotEmpty) {
        profileId = selectedPid;
      } else if (_profiles.isNotEmpty) {
        profileId = _profiles.first.id;
      }
    }
    final cwdNorm = _normalizeCwdForScope(_cwd);
    final filtered = data.sessions.where((session) {
      if (session.provider != provider || session.target != target) return false;
      if (target == AgentCliTarget.ssh && session.profileId != profileId) return false;
      // Match by CWD — if session has no cwd, show it in any scope (legacy sessions)
      final sessionCwd = _normalizeCwdForScope(session.cwd ?? '');
      if (sessionCwd.isEmpty || cwdNorm.isEmpty) return true;
      return sessionCwd == cwdNorm;
    }).toList();
    filtered.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    return filtered;
  }

  List<AgentCliSession> get _scopeSessions => _scopeSessionsFor(_data);

  AgentCliSession? get _currentSession {
    final sid = _data.selectedSessionByScope[_scopeKey];
    if (sid == null || sid.isEmpty) {
      return _scopeSessions.isNotEmpty ? _scopeSessions.first : null;
    }
    for (final session in _scopeSessions) {
      if (session.id == sid) return session;
    }
    return _scopeSessions.isNotEmpty ? _scopeSessions.first : null;
  }

  @override
  void initState() {
    super.initState();
    _init();
  }

  @override
  void dispose() {
    _inputCtrl.dispose();
    _scrollCtrl.dispose();
    _inputFocus.dispose();
    super.dispose();
  }

  Future<void> _init() async {
    final loaded = await _store.load();
    if (!mounted) return;
    setState(() {
      _data = loaded;
      _loading = false;
      _fontSize = loaded.fontSize;
      // Load CWD per provider from store (persisted)
      final defaultCwd = pu.isDesktop ? Directory.current.path : '~';
      for (final p in AgentCliProvider.values) {
        final stored = loaded.cwdByProvider[p.id];
        if (stored != null && stored.trim().isNotEmpty) {
          _cwdByProvider[p.id] = stored;
        } else {
          // Fallback: check sessions for last used CWD
          final sessionCwd = loaded.sessions
              .where((s) => s.provider == p && s.cwd != null && s.cwd!.trim().isNotEmpty)
              .map((s) => s.cwd!)
              .firstOrNull;
          _cwdByProvider[p.id] = sessionCwd ?? defaultCwd;
        }
      }
    });
    await _normalizeState();
    await _checkCliAvailability(silent: true);
    _scrollToBottom(jump: true);
  }

  Future<void> _normalizeState() async {
    var changed = false;
    var next = _data;
    if (!pu.isDesktop && next.target == AgentCliTarget.local) {
      next = next.copyWith(target: AgentCliTarget.ssh);
      changed = true;
    }
    if (_target == AgentCliTarget.ssh &&
        _profiles.isNotEmpty &&
        _selectedProfile == null) {
      final profileMap = Map<String, String>.from(next.selectedProfileByProvider);
      profileMap[_provider.id] = _profiles.first.id;
      next = next.copyWith(selectedProfileByProvider: profileMap);
      changed = true;
    }
    final modelMap = Map<String, String>.from(next.selectedModelByProvider);
    final selectedModel = modelMap[_provider.id]?.trim() ?? '';
    if (selectedModel.isEmpty || !_provider.models.contains(selectedModel)) {
      modelMap[_provider.id] = _provider.defaultModel;
      next = next.copyWith(selectedModelByProvider: modelMap);
      changed = true;
    }
    final scopeSessions = _scopeSessionsFor(next);
    final selectedScopeSession = next.selectedSessionByScope[_scopeKey];
    final hasScopeSessions = scopeSessions.isNotEmpty;
    if (!hasScopeSessions) {
      final created = _newSessionObject(
        provider: next.provider,
        target: next.target,
        model: modelMap[next.provider.id] ?? next.provider.defaultModel,
        profileId: next.target == AgentCliTarget.ssh
            ? () {
                final pid = (next.selectedProfileByProvider[next.provider.id] ?? '').trim();
                return pid.isEmpty
                    ? (_profiles.isNotEmpty ? _profiles.first.id : '')
                    : pid;
              }()
            : null,
      );
      final sessions = [created, ...next.sessions];
      final selectedSessionByScope = Map<String, String>.from(
        next.selectedSessionByScope,
      )..[_scopeKey] = created.id;
      next = next.copyWith(
        sessions: sessions,
        selectedSessionByScope: selectedSessionByScope,
      );
      changed = true;
    } else if (selectedScopeSession == null ||
        !scopeSessions.any((s) => s.id == selectedScopeSession)) {
      final selectedSessionByScope = Map<String, String>.from(
        next.selectedSessionByScope,
      )..[_scopeKey] = scopeSessions.first.id;
      next = next.copyWith(selectedSessionByScope: selectedSessionByScope);
      changed = true;
    }
    if (changed) {
      await _persist(next);
      if (!mounted) return;
      setState(() => _data = next);
    }
  }

  Future<void> _persist(AgentCliStoreData next) async {
    _data = next;
    await _store.save(next);
  }

  Future<void> _onProviderChanged(AgentCliProvider provider) async {
    final activeProvider = _activeRunProviderId;
    if (activeProvider != null && activeProvider != provider.id) {
      _stopByProvider[activeProvider] = true;
    }
    final modelMap = Map<String, String>.from(_data.selectedModelByProvider);
    final existing = modelMap[provider.id];
    if (existing == null || !provider.models.contains(existing)) {
      modelMap[provider.id] = provider.defaultModel;
    }
    final next = _data.copyWith(
      provider: provider,
      selectedModelByProvider: modelMap,
    );
    await _persist(next);
    if (!mounted) return;
    setState(() {
      _data = next;
      if (activeProvider != null && activeProvider != provider.id) {
        final label = _providerLabelById(activeProvider);
        _status = _isTr
            ? '$label oturumu kapatiliyor...'
            : 'Stopping $label session...';
      } else {
        _status = '';
      }
      _cliReady = false;
    });
    await _normalizeState();
    await _checkCliAvailability(silent: true);
    _scrollToBottom(jump: true);
  }

  Future<void> _onTargetChanged(AgentCliTarget target) async {
    var next = _data.copyWith(target: target);
    if (target == AgentCliTarget.ssh &&
        (next.selectedProfileByProvider[_provider.id] ?? '').trim().isEmpty &&
        _profiles.isNotEmpty) {
      final profileMap = Map<String, String>.from(next.selectedProfileByProvider);
      profileMap[_provider.id] = _profiles.first.id;
      next = next.copyWith(selectedProfileByProvider: profileMap);
    }
    await _persist(next);
    if (!mounted) return;
    setState(() {
      _data = next;
      _status = '';
      _cliReady = false;
    });
    await _normalizeState();
    await _checkCliAvailability(silent: true);
    _scrollToBottom(jump: true);
  }

  Future<void> _onProfileChanged(String profileId) async {
    final profileMap = Map<String, String>.from(_data.selectedProfileByProvider);
    profileMap[_provider.id] = profileId;
    final next = _data.copyWith(selectedProfileByProvider: profileMap);
    await _persist(next);
    if (!mounted) return;
    setState(() {
      _data = next;
      _status = '';
      _cliReady = false;
    });
    await _normalizeState();
    await _checkCliAvailability(silent: true);
    _scrollToBottom(jump: true);
  }

  Future<void> _onModelChanged(String model) async {
    final modelMap = Map<String, String>.from(_data.selectedModelByProvider)
      ..[_provider.id] = model;
    final current = _currentSession;
    var sessions = _data.sessions;
    if (current != null) {
      sessions = _replaceSession(
        current.copyWith(model: model, updatedAt: DateTime.now()),
      );
    }
    final next = _data.copyWith(
      selectedModelByProvider: modelMap,
      sessions: sessions,
    );
    await _persist(next);
    if (!mounted) return;
    setState(() => _data = next);
  }

  Future<void> _selectSession(String sessionId) async {
    final selectedMap = Map<String, String>.from(_data.selectedSessionByScope)
      ..[_scopeKey] = sessionId;
    final next = _data.copyWith(selectedSessionByScope: selectedMap);
    await _persist(next);
    if (!mounted) return;
    setState(() {
      _data = next;
      _showSessionDrawer = false;
    });
    _scrollToBottom(jump: true);
  }

  Future<void> _newSession() async {
    final created = _newSessionObject(
      provider: _provider,
      target: _target,
      model: _selectedModel,
      profileId: _target == AgentCliTarget.ssh ? _selectedProfile?.id : null,
    );
    final selectedMap = Map<String, String>.from(_data.selectedSessionByScope)
      ..[_scopeKey] = created.id;
    final next = _data.copyWith(
      sessions: [created, ..._data.sessions],
      selectedSessionByScope: selectedMap,
    );
    await _persist(next);
    if (!mounted) return;
    setState(() {
      _data = next;
      _status = _isTr ? 'Yeni oturum.' : 'New session.';
    });
    _scrollToBottom(jump: true);
  }

  Future<void> _deleteCurrentSession() async {
    final current = _currentSession;
    if (current == null) return;
    final keep = _data.sessions.where((s) => s.id != current.id).toList();
    final selectedMap = Map<String, String>.from(_data.selectedSessionByScope)
      ..remove(_scopeKey);
    var next = _data.copyWith(
      sessions: keep,
      selectedSessionByScope: selectedMap,
    );
    await _persist(next);
    await _normalizeState();
    next = _data;
    if (!mounted) return;
    setState(() {
      _data = next;
      _status = _isTr ? 'Oturum silindi.' : 'Session removed.';
    });
  }

  Future<void> _renameCurrentSession() async {
    final current = _currentSession;
    if (current == null) return;
    final ctrl = TextEditingController(text: current.name ?? '');
    final renamed = await showDialog<String?>(
      context: context,
      builder: (ctx) => ContentDialog(
        title: Text(_isTr ? 'Oturumu Yeniden Adlandır' : 'Rename Session'),
        content: SizedBox(
          width: 360,
          child: TextBox(
            controller: ctrl,
            placeholder: _isTr ? 'Oturum adı' : 'Session name',
            autofocus: true,
          ),
        ),
        actions: [
          Button(
            onPressed: () => Navigator.pop(ctx, null),
            child: Text(_isTr ? 'İptal' : 'Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, ctrl.text.trim()),
            child: Text(_isTr ? 'Kaydet' : 'Save'),
          ),
        ],
      ),
    );
    if (renamed == null) return;
    final normalized = renamed.trim();
    final updated = current.copyWith(
      name: normalized.isEmpty ? '' : normalized,
      updatedAt: DateTime.now(),
    );
    final next = _data.copyWith(sessions: _replaceSession(updated));
    await _persist(next);
    if (!mounted) return;
    setState(() => _data = next);
  }

  Future<void> _exportCurrentSession() async {
    final current = _currentSession;
    if (current == null) return;
    final buf = StringBuffer();
    buf.writeln('# ${_provider.label} Session');
    buf.writeln('');
    buf.writeln('**Model:** ${current.model}');
    buf.writeln('**Date:** ${current.createdAt.toIso8601String().substring(0, 10)}');
    if (current.cwd != null) buf.writeln('**Directory:** ${current.cwd}');
    buf.writeln('');
    for (final m in current.messages) {
      if (m.role == 'user') {
        buf.writeln('## User');
        buf.writeln(m.text.trim());
        buf.writeln('');
      } else if (m.role == 'assistant') {
        buf.writeln('## ${_provider.label}');
        buf.writeln(m.text.trim());
        buf.writeln('');
      } else if (m.role == 'tool_use') {
        buf.writeln('> **Tool:** ${m.toolName ?? 'tool'}');
        buf.writeln('> ```');
        buf.writeln('> ${m.text.trim()}');
        buf.writeln('> ```');
        buf.writeln('');
      } else if (m.role == 'tool_result') {
        buf.writeln('> **Result:**');
        buf.writeln('> ```');
        buf.writeln('> ${m.text.trim()}');
        buf.writeln('> ```');
        buf.writeln('');
      } else if (m.role == 'system') {
        buf.writeln('> ⚠ ${m.text.trim()}');
        buf.writeln('');
      }
    }
    if (_totalCost > 0) {
      buf.writeln('---');
      buf.writeln('**Total cost:** \$${_totalCost.toStringAsFixed(4)}');
    }
    final md = buf.toString();
    await Clipboard.setData(ClipboardData(text: md));

    // Also save to file on desktop
    if (pu.isDesktop) {
      try {
        final date = DateTime.now().toIso8601String().substring(0, 10);
        final fileName = '${_provider.id}-$date.md';
        final dir = await path_provider.getApplicationDocumentsDirectory();
        final file = File('${dir.path}${Platform.pathSeparator}$fileName');
        await file.writeAsString(md);
        if (!mounted) return;
        setState(() {
          _status = _isTr
              ? 'Kopyalandı ve "$fileName" kaydedildi.'
              : 'Copied & saved as "$fileName".';
        });
        return;
      } catch (_) {}
    }
    if (!mounted) return;
    setState(() {
      _status = _isTr ? 'Markdown panoya kopyalandı.' : 'Markdown copied.';
    });
  }

  Future<void> _importSession() async {
    final inputCtrl = TextEditingController();
    final raw = await showDialog<String?>(
      context: context,
      builder: (ctx) => ContentDialog(
        title: Text(_isTr ? 'Oturum İçe Aktar' : 'Import Session'),
        content: SizedBox(
          width: 560,
          height: 240,
          child: TextBox(
            controller: inputCtrl,
            placeholder: _isTr
                ? 'Session JSON yapıştır...'
                : 'Paste session JSON...',
            maxLines: null,
            minLines: 10,
          ),
        ),
        actions: [
          Button(
            onPressed: () => Navigator.pop(ctx, null),
            child: Text(_isTr ? 'İptal' : 'Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, inputCtrl.text),
            child: Text(_isTr ? 'İçe Aktar' : 'Import'),
          ),
        ],
      ),
    );
    if (raw == null) return;
    final text = raw.trim();
    if (text.isEmpty) return;
    try {
      final decoded = jsonDecode(text);
      Map<String, dynamic>? sessionMap;
      if (decoded is Map<String, dynamic>) {
        sessionMap = decoded;
      } else if (decoded is Map) {
        sessionMap = decoded.cast<String, dynamic>();
      }
      if (sessionMap == null) throw const FormatException('invalid');
      final parsed = AgentCliSession.fromJson(sessionMap);
      final imported = AgentCliSession(
        id: _newId(),
        provider: _provider,
        target: _target,
        model: parsed.model.trim().isEmpty ? _selectedModel : parsed.model,
        name: parsed.name,
        profileId: _target == AgentCliTarget.ssh ? _selectedProfile?.id : null,
        cwd: parsed.cwd,
        cliSessionId: parsed.cliSessionId,
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
        messages: parsed.messages,
      );
      final selectedMap = Map<String, String>.from(_data.selectedSessionByScope)
        ..[_scopeKey] = imported.id;
      final next = _data.copyWith(
        sessions: [imported, ..._data.sessions],
        selectedSessionByScope: selectedMap,
      );
      await _persist(next);
      if (!mounted) return;
      setState(() {
        _data = next;
        _status = _isTr ? 'İçe aktarıldı.' : 'Imported.';
      });
      _scrollToBottom(jump: true);
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _status = _isTr ? 'Geçersiz JSON.' : 'Invalid JSON.';
      });
    }
  }

  AgentCliSession _newSessionObject({
    required AgentCliProvider provider,
    required AgentCliTarget target,
    required String model,
    String? profileId,
  }) {
    final now = DateTime.now();
    return AgentCliSession(
      id: _newId(),
      provider: provider,
      target: target,
      model: model,
      name: null,
      profileId: profileId?.trim().isEmpty ?? true ? null : profileId,
      cwd: _cwd.trim().isNotEmpty ? _cwd : null,
      createdAt: now,
      updatedAt: now,
      messages: const [],
    );
  }

  List<AgentCliSession> _replaceSession(AgentCliSession updated) {
    return _data.sessions.map((s) {
      if (s.id == updated.id) return updated;
      return s;
    }).toList();
  }

  AgentCliSession? _sessionById(String sessionId) {
    for (final session in _data.sessions) {
      if (session.id == sessionId) return session;
    }
    return null;
  }

  String _providerLabelById(String providerId) {
    for (final p in AgentCliProvider.values) {
      if (p.id == providerId) return p.label;
    }
    return providerId;
  }

  void _releaseActiveRunLock(String providerId) {
    if (_activeRunProviderId == providerId) {
      _activeRunProviderId = null;
    }
  }

  Future<bool> _ensureSingleActiveRun(String nextProviderId) async {
    final activeProvider = _activeRunProviderId;
    if (activeProvider == null) return true;

    _stopByProvider[activeProvider] = true;
    if (mounted) {
      setState(() {
        final label = _providerLabelById(activeProvider);
        _status = _isTr
            ? '$label oturumu kapatiliyor...'
            : 'Stopping $label session...';
      });
    }

    final deadline = DateTime.now().add(const Duration(seconds: 12));
    while (_activeRunProviderId != null && DateTime.now().isBefore(deadline)) {
      await Future.delayed(const Duration(milliseconds: 120));
    }

    if (_activeRunProviderId != null) {
      if (mounted) {
        setState(() {
          _status = _isTr
              ? 'Aktif islem kapanmadan yeni islem baslatilamiyor.'
              : 'Cannot start a new run until the active one stops.';
        });
      }
      return false;
    }
    return true;
  }

  Future<void> _checkCliAvailability({bool silent = false}) async {
    if (_checkingCli) return;
    if (_target == AgentCliTarget.ssh && _selectedProfile == null) {
      if (!mounted) return;
      setState(() {
        _cliReady = false;
        if (!silent) {
          _status = _isTr ? 'SSH sunucusu seç.' : 'Select SSH server.';
        }
      });
      return;
    }
    setState(() {
      _checkingCli = true;
      if (!silent) {
        _status = _isTr ? 'CLI kontrol...' : 'Checking CLI...';
      }
    });
    bool ready = false;
    try {
      if (_target == AgentCliTarget.local) {
        ready = await _runtime.isCliAvailableLocal(_provider);
      } else {
        ready = await _runtime.isCliAvailableSsh(_selectedProfile!, _provider);
      }
    } catch (_) {
      ready = false;
    }
    if (!mounted) return;
    setState(() {
      _checkingCli = false;
      _cliReady = ready;
      if (!silent) {
        _status = ready
            ? '${_provider.label} CLI ${_isTr ? 'hazır' : 'ready'}.'
            : '${_provider.label} CLI ${_isTr ? 'hazır değil' : 'not ready'}.';
      }
    });
  }

  Future<void> _sendTerminalSetupCommand({required bool install}) async {
    final localCb = widget.onSendLocalTerminalCommand;
    final sshCb = widget.onSendSshTerminalCommand;
    final profile = _selectedProfile;
    final cmd = install
        ? _runtime.installCommand(_provider)
        : _runtime.loginCommand(_provider);
    if (_target == AgentCliTarget.local) {
      if (localCb == null) {
        await Clipboard.setData(ClipboardData(text: cmd));
        if (!mounted) return;
        setState(() {
          _status = _isTr ? 'Komut kopyalandı.' : 'Copied.';
        });
        return;
      }
      await localCb(cmd);
      if (!mounted) return;
      setState(() {
        _status =
            _isTr ? 'Terminale gönderildi.' : 'Sent to terminal.';
      });
      return;
    }
    if (profile == null) {
      if (!mounted) return;
      setState(() {
        _status = _isTr ? 'SSH sunucusu seç.' : 'Select SSH server.';
      });
      return;
    }
    if (sshCb == null) {
      await Clipboard.setData(ClipboardData(text: cmd));
      if (!mounted) return;
      setState(() {
        _status = _isTr ? 'Komut kopyalandı.' : 'Copied.';
      });
      return;
    }
    await sshCb(profile, cmd);
    if (!mounted) return;
    setState(() {
      _status =
          _isTr ? 'SSH terminaline gönderildi.' : 'Sent to SSH terminal.';
    });
  }

  Future<void> _pickCwd() async {
    final picked = await showDialog<String?>(
      context: context,
      builder: (ctx) => _CwdPickerDialog(
        initialPath: _cwd,
        isTr: _isTr,
        isLocal: _target == AgentCliTarget.local,
        runtime: _runtime,
        profile: _selectedProfile,
      ),
    );
    if (picked == null || picked.isEmpty) return;
    setState(() => _cwd = picked);
    // Save CWD per provider to store (persisted across restarts)
    final cwdMap = Map<String, String>.from(_cwdByProvider);
    var next = _data.copyWith(cwdByProvider: cwdMap);
    // Also save to current session
    final current = _currentSession;
    if (current != null) {
      final updated = current.copyWith(cwd: picked, updatedAt: DateTime.now());
      next = next.copyWith(sessions: _replaceSession(updated));
    }
    await _persist(next);
    if (!mounted) return;
    setState(() => _data = next);
  }

  void _showHelp() {
    showDialog(
      context: context,
      builder: (ctx) => ContentDialog(
        title: Text(_isTr ? 'Agent Sayfası Hakkında' : 'About Agent Page'),
        constraints: const BoxConstraints(maxWidth: 520),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              _isTr
                  ? 'Bu sayfa Claude, Codex ve Gemini CLI araçlarını kullanarak projelerinizde otonom AI asistan çalıştırmanızı sağlar.'
                  : 'This page lets you run autonomous AI assistants on your projects using Claude, Codex and Gemini CLI tools.',
              style: TextStyle(color: workbenchText, fontSize: 13, height: 1.5),
            ),
            const SizedBox(height: 12),
            Text(
              _isTr ? 'Nasıl Kullanılır?' : 'How to Use?',
              style: TextStyle(color: workbenchAccent, fontSize: 13, fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 6),
            _helpItem(_isTr
                ? '1. Üstten provider seçin (Claude/Codex/Gemini)'
                : '1. Select a provider from top bar (Claude/Codex/Gemini)'),
            _helpItem(_isTr
                ? '2. Hedef seçin: Yerel (kendi bilgisayarınız) veya Sunucu (SSH)'
                : '2. Choose target: Local (your computer) or Server (SSH)'),
            _helpItem(_isTr
                ? '3. 📁 butonu ile proje dizinini seçin'
                : '3. Click 📁 to select your project directory'),
            _helpItem(_isTr
                ? '4. Mesaj yazıp gönderin - agent projeniz üzerinde çalışır'
                : '4. Type a message and send - the agent works on your project'),
            const SizedBox(height: 12),
            Text(
              _isTr ? 'Gereksinimler' : 'Requirements',
              style: TextStyle(color: workbenchWarning, fontSize: 13, fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 6),
            _helpItem(_isTr
                ? '• CLI aracı kurulu olmalı (⚙ Ayarlar > Kurulum butonu)'
                : '• CLI tool must be installed (⚙ Settings > Install button)'),
            _helpItem(_isTr
                ? '• CLI ile giriş yapılmış olmalı (⚙ Ayarlar > Login butonu)'
                : '• Must be logged in to CLI (⚙ Settings > Login button)'),
            _helpItem(_isTr
                ? '• Bu sayfa API key gerektirmez - CLI kendi hesabınızı kullanır'
                : '• This page does NOT need an API key - CLI uses your own account'),
            const SizedBox(height: 12),
            Text(
              _isTr ? 'tmux Entegrasyonu' : 'tmux Integration',
              style: TextStyle(color: workbenchAccent, fontSize: 13, fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 6),
            _helpItem(_isTr
                ? '• SSH hedefinde tmux açıksa agent komutu kalıcı bir tmux oturumunda çalışır'
                : '• When tmux is on for SSH target, agent commands run in a persistent tmux session'),
            _helpItem(_isTr
                ? '• Bağlantı koparsa agent çalışmaya devam eder — "Kurtar" butonu ile çıktıyı alabilirsiniz'
                : '• If connection drops, the agent keeps running — use "Recover" to get the output'),
            _helpItem(_isTr
                ? '• Her provider kendi tmux oturumuna sahiptir (lifeos_cli_* prefix)'
                : '• Each provider has its own tmux session (lifeos_cli_* prefix)'),
            _helpItem(_isTr
                ? '• Oturum geçmişi uzak sunucudaki proje dizinine kaydedilir (.lifeos/)'
                : '• Session history is saved to the remote project directory (.lifeos/)'),
            _helpItem(_isTr
                ? '• ⚙ Ayarlar satırından tmux toggle ve timeout ayarlanabilir'
                : '• Toggle tmux and set timeout from the ⚙ settings row'),
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: workbenchAccent.withValues(alpha: 0.08),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: workbenchAccent.withValues(alpha: 0.2)),
              ),
              child: Text(
                _isTr
                    ? '💡 İpucu: Terminal sayfasındaki "AI Sohbet" paneli ise API key ile çalışır ve CLI kurulumu gerektirmez. Ayarlar > AI Asistan bölümünden API key ekleyerek kullanabilirsiniz.'
                    : '💡 Tip: The "AI Chat" panel in the Terminal page works with API keys and does not require CLI installation. Add an API key from Settings > AI Assistant to use it.',
                style: TextStyle(color: workbenchText, fontSize: 12, height: 1.4),
              ),
            ),
          ],
        ),
        actions: [
          FilledButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(_isTr ? 'Anladım' : 'Got it'),
          ),
        ],
      ),
    );
  }

  Widget _helpItem(String text) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Text(
        text,
        style: TextStyle(color: workbenchTextMuted, fontSize: 12, height: 1.4),
      ),
    );
  }

  void _stopAgent() {
    final providerId = _provider.id;
    _runtime.forceStop();
    setState(() {
      _stopByProvider[providerId] = true;
      _sendingByProvider[providerId] = false;
      _releaseActiveRunLock(providerId);
      _status = _isTr ? 'Durduruldu.' : 'Stopped.';
    });
  }

  void _changeFontSize(double delta) {
    final next = (_fontSize + delta).clamp(10.0, 20.0);
    setState(() => _fontSize = next);
    final updated = _data.copyWith(fontSize: next);
    unawaited(_persist(updated));
  }

  Future<void> _clearChat() async {
    final current = _currentSession;
    if (current == null) return;
    final updated = current.copyWith(
      messages: const [],
      cliSessionId: null,
      updatedAt: DateTime.now(),
    );
    final next = _data.copyWith(sessions: _replaceSession(updated));
    await _persist(next);
    if (!mounted) return;
    setState(() {
      _data = next;
      _status = _isTr ? 'Sohbet temizlendi.' : 'Chat cleared.';
    });
  }

  Future<void> _sendPrompt([String? quickPrompt]) async {
    final text = quickPrompt ?? _inputCtrl.text.trim();
    if (text.isEmpty) return;
    // If already sending, stop current run first so new message can proceed
    if (_sending) {
      _stopAgent();
      // Brief wait for stop to propagate
      await Future.delayed(const Duration(milliseconds: 300));
    }
    if (quickPrompt == null) _inputCtrl.clear();

    await _normalizeState();
    final current = _currentSession;
    if (current == null) return;
    final runProvider = _provider;
    final runTarget = _target;
    final runSessionId = current.id;
    final runProfile = runTarget == AgentCliTarget.ssh ? _selectedProfile : null;
    final lockOk = await _ensureSingleActiveRun(runProvider.id);
    if (!lockOk) return;
    if (runTarget == AgentCliTarget.ssh && runProfile == null) {
      setState(() {
        _status = _isTr ? 'SSH sunucusu gerekli.' : 'SSH server required.';
      });
      return;
    }

    // Add user message
    _stopByProvider[runProvider.id] = false;
    final userMsg = AgentCliMessage(
      id: _newId(), role: 'user', text: text, createdAt: DateTime.now(),
    );
    final withUser = current.copyWith(
      updatedAt: DateTime.now(),
      messages: [...current.messages, userMsg],
    );
    var next = _data.copyWith(sessions: _replaceSession(withUser));
    await _persist(next);
    if (!mounted) return;
    setState(() {
      _data = next;
      _activeRunProviderId = runProvider.id;
      _sendingByProvider[runProvider.id] = true;
      _status = _isTr ? 'Agent çalışıyor...' : 'Agent running...';
    });
    _scrollToBottom();

    // Check CLI readiness for the captured provider/target/profile.
    var cliReadyForRun = false;
    try {
      if (runTarget == AgentCliTarget.local) {
        cliReadyForRun = await _runtime.isCliAvailableLocal(runProvider);
      } else {
        cliReadyForRun = await _runtime.isCliAvailableSsh(runProfile!, runProvider);
      }
    } catch (_) {
      cliReadyForRun = false;
    }
    if (!cliReadyForRun) {
      await _addMessageToSession(runSessionId, AgentCliMessage(
        id: _newId(), role: 'system',
        text: _isTr
            ? '${runProvider.label} CLI hazır değil. Ayarlardan "Kurulum" veya "Login" yap.'
            : '${runProvider.label} CLI not ready. Use Settings to Install/Login.',
        createdAt: DateTime.now(),
      ));
      if (!mounted) return;
      setState(() {
        _sendingByProvider[runProvider.id] = false;
        _releaseActiveRunLock(runProvider.id);
      });
      _scrollToBottom();
      return;
    }

    final prompt = _buildPrompt(
      provider: runProvider,
      history: withUser.messages,
      latestUserText: text,
      hasSession: withUser.cliSessionId != null,
    );
    final model = _selectedModel;
    final effectiveCwd = _cwd.trim().isNotEmpty ? _cwd.trim() : null;

    // Create a streaming assistant message placeholder
    final streamingId = _newId();
    final streamBuf = StringBuffer();

    void onStreamEvent(AgentStreamEvent evt) {
      if (!mounted) return;
      switch (evt.type) {
        case AgentStreamEventType.text:
          streamBuf.write(evt.text ?? '');
          // Update the streaming message in current session
          _updateStreamingMessageInSession(
            runSessionId,
            streamingId,
            streamBuf.toString(),
          );
          _scrollToBottom();
          break;
        case AgentStreamEventType.toolUse:
          // Update status with tool info
          if (mounted) {
            setState(() {
              final tool = evt.toolName ?? 'tool';
              final target = evt.filePath ?? '';
              _status = target.isNotEmpty ? '$tool: $target' : tool;
            });
          }
          _addMessageToSession(runSessionId, AgentCliMessage(
            id: _newId(), role: 'tool_use',
            text: evt.toolInput ?? '',
            toolName: evt.toolName,
            filePath: evt.filePath,
            diffOld: evt.diffOld,
            diffNew: evt.diffNew,
            createdAt: DateTime.now(),
          ));
          _scrollToBottom();
          break;
        case AgentStreamEventType.toolResult:
          final resultText = evt.text ?? '';
          // Only show if meaningful
          if (resultText.trim().length > 2) {
            _addMessageToSession(runSessionId, AgentCliMessage(
              id: _newId(), role: 'tool_result',
              text: resultText.length > 800 ? '${resultText.substring(0, 800)}...' : resultText,
              createdAt: DateTime.now(),
            ));
            _scrollToBottom();
          }
          break;
        case AgentStreamEventType.cost:
          setState(() => _totalCost = evt.costUsd ?? _totalCost);
          break;
        case AgentStreamEventType.sessionId:
          // Will be captured in the final result
          break;
        case AgentStreamEventType.timeout:
          setState(() => _status = _isTr ? 'Zaman aşımı!' : 'Timed out!');
          break;
        case AgentStreamEventType.done:
        case AgentStreamEventType.error:
          break;
      }
    }

    // Add initial streaming placeholder
    await _addMessageToSession(runSessionId, AgentCliMessage(
      id: streamingId, role: 'streaming', text: '', createdAt: DateTime.now(),
    ));

    // Execute with streaming
    final effectiveResumeId = withUser.cliSessionId;
    final timeoutDuration = Duration(minutes: _data.streamingTimeoutMinutes);
    AgentCliExecutionResult result;
    if (runTarget == AgentCliTarget.local) {
      result = await _runtime.executeLocalStreaming(
        provider: runProvider, model: model, prompt: prompt,
        preferTurkish: _isTr, onEvent: onStreamEvent,
        resumeSessionId: effectiveResumeId,
        cwd: effectiveCwd, approvalMode: _approvalMode,
        timeout: timeoutDuration,
        isStopRequested: () => _stopByProvider[runProvider.id] ?? false,
      );
    } else {
      result = await _runtime.executeSshStreaming(
        profile: runProfile!, provider: runProvider,
        model: model, prompt: prompt, preferTurkish: _isTr,
        onEvent: onStreamEvent, resumeSessionId: effectiveResumeId,
        cwd: effectiveCwd, approvalMode: _approvalMode,
        timeout: timeoutDuration,
        isStopRequested: () => _stopByProvider[runProvider.id] ?? false,
        useTmux: _data.agentTmuxEnabled,
      );
    }

    // If resume failed or returned empty (stale cliSessionId), retry once without resume
    final rawOut = result.rawOutput.toLowerCase();
    final resumeLooksInvalid =
        rawOut.contains('no rollout found') ||
        rawOut.contains('resume failed') ||
        rawOut.contains('session not found') ||
        rawOut.contains('thread/resume') ||
        rawOut.contains('invalid session identifier') ||
        rawOut.contains('use --list-sessions') ||
        rawOut.contains('could not find session') ||
        rawOut.contains('session does not exist') ||
        rawOut.contains('unknown session') ||
        rawOut.contains('error_during_execution');
    final noVisibleOutput =
        streamBuf.toString().trim().isEmpty &&
        result.assistantText.trim().isEmpty;
    final retryResume = withUser.cliSessionId != null && (
        (!result.success && resumeLooksInvalid) ||
        (result.success && noVisibleOutput));
    if (retryResume) {
      // Clear stale cliSessionId
      final cleared = withUser.copyWith(cliSessionId: null);
      final nextClear = _data.copyWith(sessions: _replaceSession(cleared));
      await _persist(nextClear);
      if (mounted) setState(() => _data = nextClear);
      // Retry without resume (re-run same streaming call)
      streamBuf.clear();
      if (runTarget == AgentCliTarget.local) {
        result = await _runtime.executeLocalStreaming(
          provider: runProvider, model: model, prompt: prompt,
          preferTurkish: _isTr, onEvent: onStreamEvent,
          resumeSessionId: null,
          cwd: effectiveCwd, approvalMode: _approvalMode,
          timeout: timeoutDuration,
          isStopRequested: () => _stopByProvider[runProvider.id] ?? false,
        );
      } else {
        result = await _runtime.executeSshStreaming(
          profile: runProfile!, provider: runProvider,
          model: model, prompt: prompt, preferTurkish: _isTr,
          onEvent: onStreamEvent, resumeSessionId: null,
          cwd: effectiveCwd, approvalMode: _approvalMode,
          timeout: timeoutDuration,
          isStopRequested: () => _stopByProvider[runProvider.id] ?? false,
          useTmux: _data.agentTmuxEnabled,
        );
      }
    }

    // Finalize: convert streaming message to assistant
    final streamedText = streamBuf.toString().trim();
    final parsedText = result.assistantText.trim();
    final finalText = streamedText.isNotEmpty ? streamedText : parsedText;
    _debugLog('[VIEW-FINAL ${runProvider.id}] streamed=${streamedText.length}B parsed=${parsedText.length}B final=${finalText.length}B success=${result.success} exit=${result.exitCode} err=${result.errorMessage}');
    if (!mounted) {
      _releaseActiveRunLock(runProvider.id);
      return;
    }

    final currentAfter = _sessionById(runSessionId);
    _debugLog('[VIEW-SESSION] runSessionId=$runSessionId found=${currentAfter != null} msgCount=${currentAfter?.messages.length} streamingMsgExists=${currentAfter?.messages.any((m) => m.id == streamingId)}');
    if (currentAfter == null) {
      _debugLog('[VIEW-SESSION] SESSION NOT FOUND - aborting finalize');
      _releaseActiveRunLock(runProvider.id);
      return;
    }

    // Replace streaming message with final assistant message
    final updatedMessages = currentAfter.messages.map((m) {
      if (m.id == streamingId) {
        return AgentCliMessage(
          id: m.id,
          role: result.success ? 'assistant' : 'system',
          text: finalText.isNotEmpty ? finalText : (result.errorMessage ?? (_isTr ? 'Yanıt boş.' : 'Empty response.')),
          createdAt: m.createdAt,
          costUsd: _totalCost > 0 ? _totalCost : null,
        );
      }
      return m;
    }).toList();

    final updated = currentAfter.copyWith(
      model: model,
      cliSessionId: result.cliSessionId ?? currentAfter.cliSessionId,
      updatedAt: DateTime.now(),
      messages: updatedMessages,
    );
    next = _data.copyWith(sessions: _replaceSession(updated));
    await _persist(next);
    if (!mounted) {
      _releaseActiveRunLock(runProvider.id);
      return;
    }
    // In confirm mode with successful result: add a "continue?" prompt
    final isConfirmMode = _approvalMode == 'confirm';
    final hasSessionId = result.cliSessionId != null && result.cliSessionId!.trim().isNotEmpty;

    setState(() {
      _data = next;
      _sendingByProvider[runProvider.id] = false;
      _releaseActiveRunLock(runProvider.id);
      _status = result.success
          ? '${result.durationMs}ms${_totalCost > 0 ? ' • \$${_totalCost.toStringAsFixed(4)}' : ''}'
          : '${_isTr ? 'Hata' : 'Error'} (${result.exitCode})${result.errorMessage != null ? ': ${result.errorMessage!.length > 60 ? result.errorMessage!.substring(0, 60) : result.errorMessage}' : ''}';
      if (isConfirmMode && result.success && hasSessionId) {
        _status += _isTr ? ' • Onay bekleniyor' : ' • Awaiting approval';
      }
    });
    _scrollToBottom();
  }

  /// Add a message to a specific session (without full persist for streaming speed).
  Future<void> _addMessageToSession(String sessionId, AgentCliMessage msg) async {
    final current = _sessionById(sessionId);
    if (current == null) return;
    final updated = current.copyWith(
      updatedAt: DateTime.now(),
      messages: [...current.messages, msg],
    );
    final next = _data.copyWith(sessions: _replaceSession(updated));
    _data = next;
    if (mounted) setState(() {});
  }

  /// Update a streaming message text in a specific session.
  void _updateStreamingMessageInSession(
    String sessionId,
    String messageId,
    String newText,
  ) {
    final current = _sessionById(sessionId);
    if (current == null) return;
    final updatedMessages = current.messages.map((m) {
      if (m.id == messageId) return m.copyWith(text: newText);
      return m;
    }).toList();
    final updated = current.copyWith(messages: updatedMessages);
    _data = _data.copyWith(sessions: _replaceSession(updated));
    if (mounted) setState(() {});
  }

  String _buildPrompt({
    required AgentCliProvider provider,
    required List<AgentCliMessage> history,
    required String latestUserText,
    required bool hasSession,
  }) {
    // Codex CLI maintains its own session context via --resume.
    // Just send the latest user text — resume handles the rest.
    if (provider == AgentCliProvider.codex) {
      return latestUserText;
    }
    final contextMessages = history
        .where((m) => m.role == 'user' || m.role == 'assistant')
        .toList();
    final keep = contextMessages.length > 12
        ? contextMessages.sublist(contextMessages.length - 12)
        : contextMessages;
    if (keep.isEmpty) return latestUserText;
    // For Claude/Gemini with --resume, only send latest user text
    // The CLI maintains its own session context
    if (hasSession) return latestUserText;
    // First message with context
    final buf = StringBuffer();
    if (_isTr) {
      buf.writeln(
        'Konuşma bağlamına sadık kal. Son kullanıcı mesajına cevap ver.',
      );
    } else {
      buf.writeln(
        'Keep continuity with conversation. Respond to latest user message.',
      );
    }
    buf.writeln('');
    for (final item in keep) {
      final who = item.role == 'assistant' ? 'Assistant' : 'User';
      buf.writeln('$who: ${item.text}');
    }
    buf.writeln('');
    buf.writeln('User: $latestUserText');
    return buf.toString().trim();
  }

  void _scrollToBottom({bool jump = false}) {
    // Double post-frame callback ensures ListView has fully laid out
    // new items before we query maxScrollExtent.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!_scrollCtrl.hasClients) return;
        final target = _scrollCtrl.position.maxScrollExtent;
        if (jump) {
          _scrollCtrl.jumpTo(target);
        } else {
          _scrollCtrl.animateTo(
            target,
            duration: const Duration(milliseconds: 180),
            curve: Curves.easeOut,
          );
        }
      });
    });
  }

  String _sessionLabel(AgentCliSession session) {
    final explicitName = session.name?.trim() ?? '';
    final titleMsg = explicitName.isNotEmpty
        ? explicitName
        : (session.messages.isNotEmpty
              ? session.messages.first.text.trim()
              : (_isTr ? 'Yeni oturum' : 'New session'));
    return titleMsg.length > 40
        ? '${titleMsg.substring(0, 40)}...'
        : titleMsg;
  }

  String _sessionTimestamp(AgentCliSession session) {
    return '${session.updatedAt.hour.toString().padLeft(2, '0')}:'
        '${session.updatedAt.minute.toString().padLeft(2, '0')}';
  }

  // ── BUILD ──────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return Center(
        child: ProgressRing(activeColor: _providerColor(_provider), strokeWidth: 3),
      );
    }
    if (!widget.appController.agentPageEnabled) {
      return Center(
        child: Text(
          _isTr
              ? 'Agent sayfası Ayarlar > AI Asistan bölümünden etkinleştirilebilir.'
              : 'Enable Agent page from Settings > AI Assistant.',
          style: TextStyle(color: workbenchTextFaint, fontSize: 13),
        ),
      );
    }

    final current = _currentSession;
    final messages = current?.messages ?? const <AgentCliMessage>[];
    final provColor = _providerColor(_provider);
    final effectActive = widget.appController.windowEffect != 'none';
    final opacity = widget.appController.windowOpacity;
    final tt = TransparentTheme(effectActive: effectActive, opacity: opacity);
    final isMobile = !pu.isDesktop;
    final keyboardVisible = MediaQuery.of(context).viewInsets.bottom > 0;

    // Use ScaffoldPage to get automatic keyboard avoidance on Android
    final content = Container(
      color: tt.bg,
      child: Column(
        children: [
            // ── TOP TOOLBAR ────────────────────────────────────
            // Hide toolbar in mobile fullscreen when keyboard is open
            if (!(_fullscreen && keyboardVisible && isMobile))
              _buildToolbar(provColor, tt),
            // ── SETTINGS ROW (collapsible) ─────────────────────
            if (_showSettings && !(_fullscreen && isMobile))
              _buildSettingsRow(provColor, tt),
            // ── MAIN AREA ──────────────────────────────────────
            Expanded(
              child: Row(
                children: [
                  // Session drawer - overlay on mobile
                  if (_showSessionDrawer && !isMobile)
                    _buildSessionDrawer(current, provColor, tt),
                  // Chat area
                  Expanded(
                    child: Stack(
                      children: [
                        _buildChatArea(current, messages, provColor, tt),
                        // Mobile session drawer as overlay
                        if (_showSessionDrawer && isMobile)
                          Positioned.fill(
                            child: GestureDetector(
                              onTap: () => setState(() => _showSessionDrawer = false),
                              child: Container(
                                color: Colors.black.withValues(alpha: 0.4),
                                alignment: Alignment.centerLeft,
                                child: _buildSessionDrawer(current, provColor, tt),
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      );

    // On mobile, add bottom padding equal to keyboard height
    // so input field stays above the keyboard
    if (isMobile) {
      final keyboardHeight = MediaQuery.of(context).viewInsets.bottom;
      return Padding(
        padding: EdgeInsets.only(bottom: keyboardHeight),
        child: content,
      );
    }
    return content;
  }

  // ── TOOLBAR ────────────────────────────────────────────────────

  Widget _buildToolbar(Color provColor, TransparentTheme tt) {
    final isMobile = !pu.isDesktop;
    if (isMobile) return _buildMobileToolbar(provColor, tt);
    return _buildDesktopToolbar(provColor, tt);
  }

  Widget _buildMobileToolbar(Color provColor, TransparentTheme tt) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
      decoration: BoxDecoration(
        color: tt.panelAlt,
        border: Border(bottom: BorderSide(color: workbenchBorder, width: 0.5)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Row 1: Provider tabs + status + actions
          Row(
            children: [
              _buildProviderTabs(),
              const SizedBox(width: 6),
              Container(
                width: 8, height: 8,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: _cliReady ? workbenchSuccess : workbenchDanger,
                ),
              ),
              if (_sending)
                Padding(
                  padding: const EdgeInsets.only(left: 6),
                  child: SizedBox(width: 12, height: 12,
                    child: ProgressRing(activeColor: provColor, strokeWidth: 2)),
                ),
              const Spacer(),
              _toolbarBtn(
                icon: FluentIcons.history, tooltip: _isTr ? 'Oturumlar' : 'Sessions',
                active: _showSessionDrawer,
                onPressed: () => setState(() => _showSessionDrawer = !_showSessionDrawer),
              ),
              _toolbarBtn(
                icon: _fullscreen ? FluentIcons.back_to_window : FluentIcons.full_screen,
                tooltip: _isTr ? 'Tam Ekran' : 'Fullscreen',
                active: _fullscreen,
                onPressed: () => setState(() => _fullscreen = !_fullscreen),
              ),
              _toolbarBtn(
                icon: FluentIcons.settings, tooltip: _isTr ? 'Ayarlar' : 'Settings',
                active: _showSettings,
                onPressed: () => setState(() => _showSettings = !_showSettings),
              ),
            ],
          ),
          const SizedBox(height: 4),
          // Row 2: Model + Server + Approval
          Row(
            children: [
              Expanded(
                child: _buildCompactSelect<String>(
                  value: _selectedModel,
                  items: _provider.models,
                  labelFn: (m) => _shortModelName(m),
                  onChanged: (v) => unawaited(_onModelChanged(v)),
                  width: double.infinity,
                ),
              ),
              const SizedBox(width: 4),
              if (_target == AgentCliTarget.ssh && _profiles.isNotEmpty)
                Expanded(
                  child: _buildCompactSelect<String>(
                    value: _selectedProfile?.id ?? '',
                    items: _profiles.map((p) => p.id).toList(),
                    labelFn: (id) {
                      final p = _profiles.firstWhere((p) => p.id == id, orElse: () => _profiles.first);
                      return p.name;
                    },
                    onChanged: (v) => unawaited(_onProfileChanged(v)),
                    width: double.infinity,
                  ),
                ),
              const SizedBox(width: 4),
              SizedBox(
                width: 68,
                child: _buildCompactSelect<String>(
                  value: _approvalMode,
                  items: const ['auto', 'confirm', 'readonly'],
                  labelFn: (m) => m == 'auto' ? 'Auto' : m == 'confirm' ? (_isTr ? 'Onay' : 'Ask') : (_isTr ? 'Oku' : 'Read'),
                  onChanged: (v) => setState(() => _approvalMode = v),
                  width: 68,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildDesktopToolbar(Color provColor, TransparentTheme tt) {
    return Container(
      height: 44,
      padding: const EdgeInsets.symmetric(horizontal: 8),
      decoration: BoxDecoration(
        color: tt.panelAlt,
        border: Border(bottom: BorderSide(color: workbenchBorder, width: 0.5)),
      ),
      child: Row(
        children: [
          _buildProviderTabs(),
          const SizedBox(width: 8),
          _buildCompactSelect<String>(
            value: _selectedModel,
            items: _provider.models,
            labelFn: (m) => _shortModelName(m),
            onChanged: (v) => unawaited(_onModelChanged(v)),
            width: 120,
          ),
          const SizedBox(width: 6),
          _buildCompactSelect<AgentCliTarget>(
            value: _target,
            items: [
              if (pu.isDesktop) AgentCliTarget.local,
              AgentCliTarget.ssh,
            ],
            labelFn: (t) => t == AgentCliTarget.local
                ? (_isTr ? 'Yerel' : 'Local')
                : (_isTr ? 'Sunucu' : 'SSH'),
            onChanged: (v) => unawaited(_onTargetChanged(v)),
            width: 72,
          ),
          if (_target == AgentCliTarget.ssh && _profiles.isNotEmpty) ...[
            const SizedBox(width: 6),
            _buildCompactSelect<String>(
              value: _selectedProfile?.id ?? '',
              items: _profiles.map((p) => p.id).toList(),
              labelFn: (id) {
                final p = _profiles.firstWhere((p) => p.id == id, orElse: () => _profiles.first);
                return p.name;
              },
              onChanged: (v) => unawaited(_onProfileChanged(v)),
              width: 130,
            ),
          ],
          const SizedBox(width: 6),
          _buildCompactSelect<String>(
            value: _approvalMode,
            items: const ['auto', 'confirm', 'readonly'],
            labelFn: (m) => m == 'auto' ? 'Auto' : m == 'confirm' ? (_isTr ? 'Onaylı' : 'Confirm') : (_isTr ? 'Salt Oku' : 'Read'),
            onChanged: (v) => setState(() => _approvalMode = v),
            width: 76,
          ),
          const SizedBox(width: 8),
          Container(
            width: 8, height: 8,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: _cliReady ? workbenchSuccess : workbenchDanger,
            ),
          ),
          if (_sending)
            Padding(
              padding: const EdgeInsets.only(left: 8),
              child: SizedBox(width: 14, height: 14,
                child: ProgressRing(activeColor: provColor, strokeWidth: 2)),
            ),
          const Spacer(),
          if (_status.trim().isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: Text(
                _status,
                style: TextStyle(color: workbenchTextFaint, fontSize: 10),
                overflow: TextOverflow.ellipsis,
              ),
            ),
          // Session drawer toggle
          _toolbarBtn(
            icon: FluentIcons.history,
            tooltip: _isTr ? 'Oturumlar' : 'Sessions',
            active: _showSessionDrawer,
            onPressed: () =>
                setState(() => _showSessionDrawer = !_showSessionDrawer),
          ),
          const SizedBox(width: 4),
          // Help
          _toolbarBtn(
            icon: FluentIcons.unknown,
            tooltip: _isTr ? 'Yardım' : 'Help',
            onPressed: _showHelp,
          ),
          const SizedBox(width: 4),
          // Settings toggle
          _toolbarBtn(
            icon: FluentIcons.settings,
            tooltip: _isTr ? 'Ayarlar' : 'Settings',
            active: _showSettings,
            onPressed: () => setState(() => _showSettings = !_showSettings),
          ),
        ],
      ),
    );
  }

  Widget _buildProviderTabs() {
    return Container(
      height: 30,
      decoration: BoxDecoration(
        color: workbenchEditorBg,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: workbenchBorder, width: 0.5),
      ),
      padding: const EdgeInsets.all(2),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: AgentCliProvider.values.map((p) {
          final active = p == _provider;
          final color = _providerColor(p);
          return GestureDetector(
            onTap: () => unawaited(_onProviderChanged(p)),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 150),
              padding: const EdgeInsets.symmetric(horizontal: 12),
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: active ? color : Colors.transparent,
                borderRadius: BorderRadius.circular(4),
              ),
              child: Text(
                p.label,
                style: TextStyle(
                  color: active ? Colors.white : workbenchTextMuted,
                  fontSize: 11.5,
                  fontWeight: active ? FontWeight.w600 : FontWeight.w500,
                ),
              ),
            ),
          );
        }).toList(),
      ),
    );
  }

  Widget _buildCompactSelect<T>({
    required T value,
    required List<T> items,
    required String Function(T) labelFn,
    required void Function(T) onChanged,
    double width = 100,
  }) {
    return SizedBox(
      width: width,
      height: 28,
      child: ComboBox<T>(
        value: items.contains(value) ? value : (items.isNotEmpty ? items.first : null),
        isExpanded: true,
        items: items
            .map((i) => ComboBoxItem<T>(
                  value: i,
                  child: Text(
                    labelFn(i),
                    style: const TextStyle(fontSize: 11),
                    overflow: TextOverflow.ellipsis,
                  ),
                ))
            .toList(),
        onChanged: (v) {
          if (v != null) onChanged(v);
        },
      ),
    );
  }

  Widget _toolbarBtn({
    required IconData icon,
    required String tooltip,
    required VoidCallback onPressed,
    bool active = false,
  }) {
    return Tooltip(
      message: tooltip,
      child: GestureDetector(
        onTap: onPressed,
        child: Container(
          width: 30,
          height: 30,
          decoration: BoxDecoration(
            color: active
                ? workbenchAccent.withValues(alpha: 0.15)
                : Colors.transparent,
            borderRadius: BorderRadius.circular(6),
          ),
          child: Icon(
            icon,
            size: 13,
            color: active ? workbenchAccent : workbenchTextMuted,
          ),
        ),
      ),
    );
  }

  String _shortModelName(String model) {
    if (model.contains('opus')) return 'Opus 4.6';
    if (model.contains('sonnet')) return 'Sonnet 4.6';
    if (model.contains('haiku')) return 'Haiku 4.5';
    if (model.contains('5.4-mini')) return '5.4 Mini';
    if (model.contains('5.4')) return 'GPT-5.4';
    if (model.contains('5.3')) return '5.3 Codex';
    if (model.contains('5.2')) return '5.2 Codex';
    if (model.contains('5.1-codex-mini')) return '5.1 Mini';
    if (model.contains('5.1-codex')) return '5.1 Codex';
    if (model == 'auto') return 'Auto';
    if (model.contains('3.1-pro')) return '3.1 Pro';
    if (model.contains('3-pro')) return '3 Pro';
    if (model.contains('3-flash')) return '3 Flash';
    if (model.contains('2.5-pro')) return '2.5 Pro';
    if (model.contains('2.5-flash-lite')) return '2.5 Lite';
    if (model.contains('2.5-flash')) return '2.5 Flash';
    return model.length > 14 ? '${model.substring(0, 14)}...' : model;
  }

  // ── SETTINGS ROW ──────────────────────────────────────────────

  Widget _buildSettingsRow(Color provColor, TransparentTheme tt) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: tt.panelAlt,
        border: Border(bottom: BorderSide(color: workbenchBorder, width: 0.5)),
      ),
      child: Row(
        children: [
          Text(
            'CLI:',
            style: TextStyle(
              color: workbenchTextMuted,
              fontSize: 11,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(width: 8),
          _compactBtn(
            label: _isTr ? 'Kurulum' : 'Install',
            icon: FluentIcons.download,
            onPressed: () => _sendTerminalSetupCommand(install: true),
          ),
          const SizedBox(width: 6),
          _compactBtn(
            label: 'Login',
            icon: FluentIcons.authenticator_app,
            onPressed: () => _sendTerminalSetupCommand(install: false),
          ),
          const SizedBox(width: 6),
          _compactBtn(
            label: _isTr ? 'Kontrol' : 'Check',
            icon: FluentIcons.sync,
            onPressed: _checkingCli ? null : () => _checkCliAvailability(),
          ),
          if (_target == AgentCliTarget.ssh) ...[
            const SizedBox(width: 12),
            Text('tmux', style: TextStyle(color: workbenchTextMuted, fontSize: 11, fontWeight: FontWeight.w600)),
            const SizedBox(width: 4),
            ToggleSwitch(
              checked: _data.agentTmuxEnabled,
              onChanged: (v) async {
                final next = _data.copyWith(agentTmuxEnabled: v);
                await _persist(next);
                if (mounted) setState(() => _data = next);
              },
            ),
          ],
          const SizedBox(width: 12),
          Text('Timeout:', style: TextStyle(color: workbenchTextMuted, fontSize: 11)),
          const SizedBox(width: 4),
          SizedBox(
            width: 65,
            child: ComboBox<int>(
              value: _data.streamingTimeoutMinutes,
              items: [3, 5, 10, 15, 30].map((m) => ComboBoxItem(value: m, child: Text('${m}m', style: const TextStyle(fontSize: 11)))).toList(),
              onChanged: (v) async {
                if (v == null) return;
                final next = _data.copyWith(streamingTimeoutMinutes: v);
                await _persist(next);
                if (mounted) setState(() => _data = next);
              },
            ),
          ),
          const Spacer(),
          _compactBtn(
            label: _isTr ? 'İçe Aktar' : 'Import',
            icon: FluentIcons.upload,
            onPressed: _importSession,
          ),
        ],
      ),
    );
  }

  Widget _compactBtn({
    required String label,
    required IconData icon,
    VoidCallback? onPressed,
  }) {
    return Button(
      onPressed: onPressed,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 11),
          const SizedBox(width: 4),
          Text(label, style: const TextStyle(fontSize: 11)),
        ],
      ),
    );
  }

  // ── SESSION DRAWER ────────────────────────────────────────────

  Widget _buildSessionDrawer(AgentCliSession? current, Color provColor, TransparentTheme tt) {
    final sessions = _scopeSessions;
    return Container(
      width: 260,
      decoration: BoxDecoration(
        color: tt.sidebar,
        border: Border(right: BorderSide(color: workbenchBorder, width: 0.5)),
      ),
      child: Column(
        children: [
          // Drawer header
          Container(
            height: 40,
            padding: const EdgeInsets.symmetric(horizontal: 10),
            decoration: BoxDecoration(
              border: Border(
                bottom: BorderSide(color: workbenchBorder, width: 0.5),
              ),
            ),
            child: Row(
              children: [
                Icon(FluentIcons.history, size: 12, color: workbenchTextMuted),
                const SizedBox(width: 6),
                Text(
                  _isTr ? 'Oturumlar' : 'Sessions',
                  style: TextStyle(
                    color: workbenchText,
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const Spacer(),
                GestureDetector(
                  onTap: _newSession,
                  child: Container(
                    padding: const EdgeInsets.all(4),
                    child: Icon(
                      FluentIcons.add,
                      size: 12,
                      color: provColor,
                    ),
                  ),
                ),
              ],
            ),
          ),
          // Session list
          Expanded(
            child: sessions.isEmpty
                ? Center(
                    child: Text(
                      _isTr ? 'Oturum yok' : 'No sessions',
                      style:
                          TextStyle(color: workbenchTextFaint, fontSize: 11),
                    ),
                  )
                : ListView.builder(
                    itemCount: sessions.length,
                    itemBuilder: (_, i) {
                      final s = sessions[i];
                      final isActive = s.id == current?.id;
                      return GestureDetector(
                        onTap: () => unawaited(_selectSession(s.id)),
                        onSecondaryTapUp: (details) {
                          if (isActive) {
                            showBoundedContextMenu(
                              context,
                              details.globalPosition,
                              (dismiss) => _buildSessionContextMenu(dismiss),
                            );
                          }
                        },
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 10,
                            vertical: 8,
                          ),
                          decoration: BoxDecoration(
                            color: isActive
                                ? provColor.withValues(alpha: 0.1)
                                : Colors.transparent,
                            border: Border(
                              left: BorderSide(
                                color: isActive
                                    ? provColor
                                    : Colors.transparent,
                                width: 2,
                              ),
                              bottom: BorderSide(
                                color: workbenchBorder.withValues(alpha: 0.3),
                                width: 0.5,
                              ),
                            ),
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                _sessionLabel(s),
                                style: TextStyle(
                                  color: isActive
                                      ? workbenchText
                                      : workbenchTextMuted,
                                  fontSize: 11.5,
                                  fontWeight: isActive
                                      ? FontWeight.w600
                                      : FontWeight.w400,
                                ),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                              const SizedBox(height: 2),
                              Row(
                                children: [
                                  Text(
                                    _sessionTimestamp(s),
                                    style: TextStyle(
                                      color: workbenchTextFaint,
                                      fontSize: 10,
                                    ),
                                  ),
                                  const SizedBox(width: 6),
                                  Text(
                                    '${s.messages.length} ${_isTr ? 'mesaj' : 'msgs'}',
                                    style: TextStyle(
                                      color: workbenchTextFaint,
                                      fontSize: 10,
                                    ),
                                  ),
                                ],
                              ),
                            ],
                          ),
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }

  Widget _buildSessionContextMenu(VoidCallback dismiss) {
    return Container(
      width: 180,
      decoration: BoxDecoration(
        color: workbenchMenuBg,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: workbenchBorder, width: 0.5),
        boxShadow: menuShadow,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          _contextMenuItem(
            icon: FluentIcons.rename,
            label: _isTr ? 'Adlandır' : 'Rename',
            onTap: () {
              dismiss();
              unawaited(_renameCurrentSession());
            },
          ),
          _contextMenuItem(
            icon: FluentIcons.share,
            label: _isTr ? 'Dışa Aktar' : 'Export',
            onTap: () {
              dismiss();
              unawaited(_exportCurrentSession());
            },
          ),
          Container(height: 0.5, color: workbenchBorder),
          _contextMenuItem(
            icon: FluentIcons.delete,
            label: _isTr ? 'Sil' : 'Delete',
            danger: true,
            onTap: () {
              dismiss();
              unawaited(_deleteCurrentSession());
            },
          ),
        ],
      ),
    );
  }

  Widget _contextMenuItem({
    required IconData icon,
    required String label,
    required VoidCallback onTap,
    bool danger = false,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: Row(
          children: [
            Icon(
              icon,
              size: 12,
              color: danger ? workbenchDanger : workbenchTextMuted,
            ),
            const SizedBox(width: 8),
            Text(
              label,
              style: TextStyle(
                color: danger ? workbenchDanger : workbenchText,
                fontSize: 12,
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ── CHAT AREA ─────────────────────────────────────────────────

  Widget _buildChatArea(
    AgentCliSession? current,
    List<AgentCliMessage> messages,
    Color provColor,
    TransparentTheme tt,
  ) {
    return Column(
      children: [
        // Chat header
        Container(
          height: 36,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          decoration: BoxDecoration(
            color: tt.panelAlt,
            border: Border(
              bottom: BorderSide(color: workbenchBorder, width: 0.5),
            ),
          ),
          child: Row(
            children: [
              Container(
                width: 8,
                height: 8,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: provColor,
                ),
              ),
              const SizedBox(width: 8),
              if (current != null)
                Expanded(
                  child: Text(
                    _sessionLabel(current),
                    style: TextStyle(
                      color: workbenchText,
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              // CWD indicator
              if (_cwd.isNotEmpty)
                GestureDetector(
                  onTap: _pickCwd,
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                    margin: const EdgeInsets.only(right: 8),
                    decoration: BoxDecoration(
                      color: workbenchEditorBg,
                      borderRadius: BorderRadius.circular(4),
                      border: Border.all(color: workbenchBorder, width: 0.5),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(FluentIcons.folder, size: 10, color: workbenchTextFaint),
                        const SizedBox(width: 4),
                        ConstrainedBox(
                          constraints: const BoxConstraints(maxWidth: 200),
                          child: Text(
                            _cwd.length > 30 ? '...${_cwd.substring(_cwd.length - 27)}' : _cwd,
                            style: TextStyle(
                              color: workbenchTextMuted,
                              fontSize: 10,
                              fontFamily: 'JetBrains Mono',
                            ),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              if (current?.cliSessionId != null)
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: Tooltip(
                    message: 'Session: ${current!.cliSessionId}',
                    child: Container(
                      width: 6,
                      height: 6,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: _sending ? workbenchSuccess : workbenchTextFaint,
                      ),
                    ),
                  ),
                ),
              // Font size
              _chatHeaderBtn(
                icon: FluentIcons.font_decrease,
                tooltip: _isTr ? 'Küçült' : 'Smaller',
                onPressed: () => _changeFontSize(-1),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 2),
                child: Text(
                  '${_fontSize.round()}',
                  style: TextStyle(color: workbenchTextFaint, fontSize: 9),
                ),
              ),
              _chatHeaderBtn(
                icon: FluentIcons.font_increase,
                tooltip: _isTr ? 'Büyüt' : 'Larger',
                onPressed: () => _changeFontSize(1),
              ),
              const SizedBox(width: 4),
              // Clear
              _chatHeaderBtn(
                icon: FluentIcons.clear,
                tooltip: _isTr ? 'Temizle' : 'Clear',
                onPressed: _clearChat,
              ),
              const SizedBox(width: 2),
              // Export
              _chatHeaderBtn(
                icon: FluentIcons.download,
                tooltip: _isTr ? 'Dışa Aktar' : 'Export',
                onPressed: _exportCurrentSession,
              ),
            ],
          ),
        ),
        // Messages
        Expanded(
          child: Container(
            color: tt.bg,
            child: messages.isEmpty
                ? _buildEmptyState(provColor)
                : ListView.builder(
                    controller: _scrollCtrl,
                    padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
                    itemCount: messages.length + (_sending ? 1 : 0),
                    itemBuilder: (_, i) {
                      if (i == messages.length && _sending) {
                        return _buildTypingIndicator(provColor);
                      }
                      final msg = messages[i];
                      // Tool messages: group consecutive tool_use/tool_result into a scrollable block
                      if (msg.role == 'tool_use' || msg.role == 'tool_result') {
                        // Skip if this tool msg was already rendered by a previous group
                        if (i > 0 && (messages[i - 1].role == 'tool_use' || messages[i - 1].role == 'tool_result')) {
                          return const SizedBox.shrink();
                        }
                        // Collect consecutive tool messages
                        final toolGroup = <AgentCliMessage>[];
                        for (var j = i; j < messages.length; j++) {
                          if (messages[j].role == 'tool_use' || messages[j].role == 'tool_result') {
                            toolGroup.add(messages[j]);
                          } else {
                            break;
                          }
                        }
                        return _AgentToolGroup(
                          tools: toolGroup,
                          isTr: _isTr,
                          fontSize: _fontSize,
                        );
                      }
                      return _AgentMessageTile(
                        message: msg,
                        provider: _provider,
                        isTr: _isTr,
                        fontSize: _fontSize,
                      );
                    },
                  ),
          ),
        ),
        // Quick prompts
        _buildQuickBar(provColor, tt),
        // Input
        _buildInputArea(provColor, tt),
      ],
    );
  }

  Widget _buildEmptyState(Color provColor) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 48,
            height: 48,
            decoration: BoxDecoration(
              color: provColor.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Center(
              child: Text(
                _providerInitial(_provider),
                style: TextStyle(
                  color: provColor,
                  fontSize: 22,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ),
          ),
          const SizedBox(height: 12),
          Text(
            '${_provider.label} Agent',
            style: TextStyle(
              color: workbenchText,
              fontSize: 15,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            _isTr
                ? 'Dosya düzenleme, kod yazma, hata ayıklama.'
                : 'File editing, code writing, debugging.',
            style: TextStyle(color: workbenchTextFaint, fontSize: 12),
          ),
        ],
      ),
    );
  }

  Widget _buildTypingIndicator(Color provColor) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        children: [
          Container(
            width: 26,
            height: 26,
            decoration: BoxDecoration(
              color: provColor.withValues(alpha: 0.15),
              borderRadius: BorderRadius.circular(6),
            ),
            child: Center(
              child: Text(
                _providerInitial(_provider),
                style: TextStyle(
                  color: provColor,
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          ),
          const SizedBox(width: 8),
          Text(
            _isTr ? '${_provider.label} yanıt yazıyor...' : '${_provider.label} is typing...',
            style: TextStyle(color: workbenchTextFaint, fontSize: 12),
          ),
          const SizedBox(width: 8),
          SizedBox(
            width: 12,
            height: 12,
            child: ProgressRing(activeColor: provColor, strokeWidth: 2),
          ),
        ],
      ),
    );
  }

  Widget _buildQuickBar(Color provColor, TransparentTheme tt) {
    // In confirm mode with a completed session: show Continue/Stop buttons
    final session = _currentSession;
    final isConfirmPaused = _approvalMode == 'confirm' &&
        !_sending &&
        session != null &&
        session.cliSessionId != null &&
        session.cliSessionId!.trim().isNotEmpty &&
        session.messages.isNotEmpty &&
        session.messages.last.role == 'assistant';

    if (isConfirmPaused) {
      return Container(
        height: 38,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        decoration: BoxDecoration(
          color: tt.panelAlt,
          border: Border(top: BorderSide(color: workbenchBorder, width: 0.5)),
        ),
        child: Row(
          children: [
            Icon(FluentIcons.info, size: 12, color: workbenchAccent),
            const SizedBox(width: 6),
            Text(
              _isTr ? 'Agent bir adim tamamladi.' : 'Agent completed a step.',
              style: TextStyle(color: workbenchTextMuted, fontSize: 11),
            ),
            const Spacer(),
            FilledButton(
              onPressed: () => _sendPrompt(_isTr ? 'Devam et' : 'Continue'),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(FluentIcons.play, size: 10),
                  const SizedBox(width: 4),
                  Text(_isTr ? 'Devam Et' : 'Continue', style: const TextStyle(fontSize: 11)),
                ],
              ),
            ),
            const SizedBox(width: 6),
            Button(
              onPressed: () {
                // Clear cliSessionId to prevent resume
                {
                  final cleared = session.copyWith(cliSessionId: null);
                  final next = _data.copyWith(sessions: _replaceSession(cleared));
                  _persist(next);
                  setState(() {
                    _data = next;
                    _status = _isTr ? 'Durduruldu' : 'Stopped';
                  });
                }
              },
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(FluentIcons.stop, size: 10),
                  const SizedBox(width: 4),
                  Text(_isTr ? 'Durdur' : 'Stop', style: const TextStyle(fontSize: 11)),
                ],
              ),
            ),
          ],
        ),
      );
    }

    final prompts = _isTr
        ? ['Hata ayıkla', 'Test yaz', 'Refactor', 'Açıkla', 'Optimize et']
        : ['Debug', 'Write tests', 'Refactor', 'Explain', 'Optimize'];
    return Container(
      height: 34,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: BoxDecoration(
        color: tt.panelAlt,
        border: Border(top: BorderSide(color: workbenchBorder, width: 0.5)),
      ),
      child: ListView(
        scrollDirection: Axis.horizontal,
        children: prompts.map((q) {
          return Padding(
            padding: const EdgeInsets.only(right: 6),
            child: Center(
              child: GestureDetector(
                onTap: _sending
                    ? null
                    : () {
                        _inputCtrl.text = '$q: ';
                        _inputFocus.requestFocus();
                      },
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 4,
                  ),
                  decoration: BoxDecoration(
                    color: workbenchPanelAlt,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(
                      color: workbenchBorder,
                      width: 0.5,
                    ),
                  ),
                  child: Text(
                    q,
                    style: TextStyle(
                      color: workbenchTextMuted,
                      fontSize: 11,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ),
              ),
            ),
          );
        }).toList(),
      ),
    );
  }

  Widget _buildInputArea(Color provColor, TransparentTheme tt) {
    final isMobile = !pu.isDesktop;
    final btnSize = isMobile ? 44.0 : 38.0;
    return Container(
      padding: EdgeInsets.fromLTRB(isMobile ? 8 : 12, 8, isMobile ? 8 : 12, 10),
      decoration: BoxDecoration(
        color: tt.panelAlt,
        border: Border(top: BorderSide(color: workbenchBorder, width: 0.5)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Expanded(
            child: Container(
              constraints: BoxConstraints(maxHeight: isMobile ? 100 : 120),
              decoration: BoxDecoration(
                color: workbenchEditorBg,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: workbenchBorder, width: 0.5),
              ),
              child: KeyboardListener(
                focusNode: FocusNode(),
                onKeyEvent: (event) {
                  // Desktop: Enter sends, Shift+Enter new line
                  if (!isMobile &&
                      event is KeyDownEvent &&
                      event.logicalKey == LogicalKeyboardKey.enter &&
                      !HardwareKeyboard.instance.isShiftPressed) {
                    _sendPrompt();
                  }
                },
                child: TextBox(
                  controller: _inputCtrl,
                  focusNode: _inputFocus,
                  placeholder: _isTr
                      ? '${_provider.label}\'a mesaj yaz...'
                      : 'Message ${_provider.label}...',
                  maxLines: isMobile ? 3 : 5,
                  minLines: 1,
                  style: TextStyle(fontSize: isMobile ? 14 : 13),
                  // Mobile: Enter sends message (single line behavior)
                  textInputAction: isMobile ? TextInputAction.send : TextInputAction.newline,
                  onSubmitted: (_) => _sendPrompt(),
                ),
              ),
            ),
          ),
          const SizedBox(width: 8),
          if (_sending) ...[
            // Stop button (red)
            SizedBox(
              width: btnSize,
              height: btnSize,
              child: FilledButton(
                onPressed: _stopAgent,
                style: ButtonStyle(
                  backgroundColor: const WidgetStatePropertyAll(Color(0xFFEF4444)),
                  shape: WidgetStatePropertyAll(
                    RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                  ),
                  padding: const WidgetStatePropertyAll(EdgeInsets.zero),
                ),
                child: const Icon(FluentIcons.stop, size: 14, color: Colors.white),
              ),
            ),
            const SizedBox(width: 4),
            // Send follow-up while agent running (blue)
            SizedBox(
              width: btnSize,
              height: btnSize,
              child: FilledButton(
                onPressed: () {
                  final text = _inputCtrl.text.trim();
                  if (text.isEmpty) return;
                  setState(() {
                    _stopByProvider[_provider.id] = true;
                    _sendingByProvider[_provider.id] = false;
                    _status = _isTr ? 'Durduruluyor...' : 'Stopping...';
                  });
                  Future.delayed(const Duration(milliseconds: 300), () {
                    if (mounted) _sendPrompt();
                  });
                },
                style: ButtonStyle(
                  backgroundColor: WidgetStatePropertyAll(provColor),
                  shape: WidgetStatePropertyAll(
                    RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                  ),
                  padding: const WidgetStatePropertyAll(EdgeInsets.zero),
                ),
                child: const Icon(FluentIcons.send, size: 14, color: Colors.white),
              ),
            ),
          ] else
            SizedBox(
              width: btnSize,
              height: btnSize,
              child: FilledButton(
                onPressed: () => _sendPrompt(),
                style: ButtonStyle(
                  backgroundColor: WidgetStatePropertyAll(provColor),
                  shape: WidgetStatePropertyAll(
                    RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                  ),
                  padding: const WidgetStatePropertyAll(EdgeInsets.zero),
                ),
                child: const Icon(FluentIcons.send, size: 14, color: Colors.white),
              ),
            ),
        ],
      ),
    );
  }

  Widget _chatHeaderBtn({
    required IconData icon,
    required String tooltip,
    required VoidCallback onPressed,
  }) {
    return Tooltip(
      message: tooltip,
      child: GestureDetector(
        onTap: onPressed,
        child: Container(
          width: 28,
          height: 28,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(6),
          ),
          child: Icon(icon, size: 12, color: workbenchTextMuted),
        ),
      ),
    );
  }

  String _newId() {
    final now = DateTime.now().microsecondsSinceEpoch;
    return '$now-${DateTime.now().millisecondsSinceEpoch % 100000}';
  }
}

// ── MESSAGE TILE ────────────────────────────────────────────────

class _AgentMessageTile extends StatelessWidget {
  const _AgentMessageTile({
    required this.message,
    required this.provider,
    required this.isTr,
    this.fontSize = 13.0,
  });

  final AgentCliMessage message;
  final AgentCliProvider provider;
  final bool isTr;
  final double fontSize;

  @override
  Widget build(BuildContext context) {
    final isUser = message.role == 'user';
    final isSystem = message.role == 'system';
    final isToolUse = message.role == 'tool_use';
    final isToolResult = message.role == 'tool_result';
    final isStreaming = message.role == 'streaming';
    final provColor = _providerColor(provider);
    final time =
        '${message.createdAt.hour.toString().padLeft(2, '0')}:${message.createdAt.minute.toString().padLeft(2, '0')}';

    // Tool messages are now rendered by _AgentToolGroup — should not reach here
    if (isToolUse || isToolResult) return const SizedBox.shrink();

    // Streaming message: show with typing indicator
    if (isStreaming) {
      return Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: 28, height: 28,
              margin: const EdgeInsets.only(top: 2),
              decoration: BoxDecoration(
                color: provColor.withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(7),
              ),
              child: Center(child: Text(
                _providerInitial(provider),
                style: TextStyle(color: provColor, fontSize: 12, fontWeight: FontWeight.w700),
              )),
            ),
            const SizedBox(width: 10),
            Flexible(
              child: Container(
                constraints: const BoxConstraints(maxWidth: 780),
                padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
                decoration: BoxDecoration(
                  color: workbenchPanelAlt,
                  borderRadius: const BorderRadius.only(
                    topLeft: Radius.circular(4), topRight: Radius.circular(12),
                    bottomLeft: Radius.circular(12), bottomRight: Radius.circular(12),
                  ),
                  border: Border.all(color: provColor.withValues(alpha: 0.3), width: 0.5),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(children: [
                      Text(provider.label, style: TextStyle(color: provColor, fontSize: 11, fontWeight: FontWeight.w600)),
                      const SizedBox(width: 6),
                      SizedBox(width: 10, height: 10, child: ProgressRing(activeColor: provColor, strokeWidth: 2)),
                    ]),
                    const SizedBox(height: 6),
                    if (message.text.trim().isNotEmpty)
                      _SimpleMarkdown(text: message.text.trim(), fontSize: fontSize)
                    else
                      Text(isTr ? 'Yazıyor...' : 'Typing...', style: TextStyle(color: workbenchTextFaint, fontSize: 12)),
                  ],
                ),
              ),
            ),
          ],
        ),
      );
    }

    if (isUser) {
      return Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.end,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Flexible(
              child: Container(
                constraints: const BoxConstraints(maxWidth: 700),
                padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
                decoration: BoxDecoration(
                  color: provColor.withValues(alpha: 0.12),
                  borderRadius: const BorderRadius.only(
                    topLeft: Radius.circular(12),
                    topRight: Radius.circular(12),
                    bottomLeft: Radius.circular(12),
                    bottomRight: Radius.circular(4),
                  ),
                  border: Border.all(
                    color: provColor.withValues(alpha: 0.2),
                    width: 0.5,
                  ),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    SelectableText(
                      message.text.trim(),
                      style: TextStyle(
                        color: workbenchText,
                        fontSize: fontSize,
                        height: 1.5,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      time,
                      style: TextStyle(color: workbenchTextFaint, fontSize: 9),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      );
    }

    if (isSystem) {
      return Padding(
        padding: const EdgeInsets.only(bottom: 10),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(
            color: workbenchWarning.withValues(alpha: 0.08),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
              color: workbenchWarning.withValues(alpha: 0.2),
              width: 0.5,
            ),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(FluentIcons.warning, size: 12, color: workbenchWarning),
              const SizedBox(width: 8),
              Expanded(
                child: SelectableText(
                  message.text.trim(),
                  style: TextStyle(
                    color: workbenchTextMuted,
                    fontSize: 12,
                    height: 1.4,
                  ),
                ),
              ),
            ],
          ),
        ),
      );
    }

    // Assistant message
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 28,
            height: 28,
            margin: const EdgeInsets.only(top: 2),
            decoration: BoxDecoration(
              color: provColor.withValues(alpha: 0.15),
              borderRadius: BorderRadius.circular(7),
            ),
            child: Center(
              child: Text(
                _providerInitial(provider),
                style: TextStyle(
                  color: provColor,
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          ),
          const SizedBox(width: 10),
          Flexible(
            child: Container(
              constraints: const BoxConstraints(maxWidth: 780),
              padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
              decoration: BoxDecoration(
                color: workbenchPanelAlt,
                borderRadius: const BorderRadius.only(
                  topLeft: Radius.circular(4),
                  topRight: Radius.circular(12),
                  bottomLeft: Radius.circular(12),
                  bottomRight: Radius.circular(12),
                ),
                border: Border.all(color: workbenchBorder, width: 0.5),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Text(
                        provider.label,
                        style: TextStyle(
                          color: provColor,
                          fontSize: 11,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(width: 6),
                      Text(
                        time,
                        style: TextStyle(
                          color: workbenchTextFaint,
                          fontSize: 9,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  _SimpleMarkdown(text: message.text.trim(), fontSize: fontSize),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ── CWD PICKER DIALOG ───────────────────────────────────────────

class _CwdPickerDialog extends StatefulWidget {
  const _CwdPickerDialog({
    required this.initialPath,
    required this.isTr,
    required this.isLocal,
    required this.runtime,
    this.profile,
  });

  final String initialPath;
  final bool isTr;
  final bool isLocal;
  final AgentCliRuntime runtime;
  final ConnectionProfile? profile;

  @override
  State<_CwdPickerDialog> createState() => _CwdPickerDialogState();
}

class _CwdPickerDialogState extends State<_CwdPickerDialog> {
  late String _currentPath;
  final TextEditingController _pathCtrl = TextEditingController();
  List<AgentDirEntry> _entries = [];
  bool _loading = false;

  @override
  void initState() {
    super.initState();
    _currentPath = widget.initialPath.isNotEmpty
        ? widget.initialPath
        : (widget.isLocal
              ? (pu.isWindows ? 'C:\\' : '/')
              : '/home');
    _pathCtrl.text = _currentPath;
    _loadDir(_currentPath);
  }

  @override
  void dispose() {
    _pathCtrl.dispose();
    super.dispose();
  }

  Future<void> _loadDir(String path) async {
    setState(() {
      _loading = true;
      _currentPath = path;
      _pathCtrl.text = path;
    });
    List<AgentDirEntry> entries;
    if (widget.isLocal) {
      entries = await widget.runtime.listLocalDir(path);
    } else if (widget.profile != null) {
      entries = await widget.runtime.listSshDir(widget.profile!, path);
    } else {
      entries = [];
    }
    if (!mounted) return;
    setState(() {
      _entries = entries;
      _loading = false;
    });
  }

  void _goUp() {
    String parent;
    if (pu.isWindows && widget.isLocal) {
      final parts = _currentPath.split(RegExp(r'[/\\]'));
      if (parts.length <= 1) return;
      parts.removeLast();
      parent = parts.join('\\');
      if (parent.endsWith(':')) parent = '$parent\\';
    } else {
      if (_currentPath == '/' || _currentPath.isEmpty) return;
      final parts = _currentPath.split('/');
      parts.removeLast();
      parent = parts.join('/');
      if (parent.isEmpty) parent = '/';
    }
    _loadDir(parent);
  }

  void _enterDir(String name) {
    String next;
    if (pu.isWindows && widget.isLocal) {
      next = _currentPath.endsWith('\\')
          ? '$_currentPath$name'
          : '$_currentPath\\$name';
    } else {
      next = _currentPath.endsWith('/')
          ? '$_currentPath$name'
          : '$_currentPath/$name';
    }
    _loadDir(next);
  }

  @override
  Widget build(BuildContext context) {
    return ContentDialog(
      title: Text(widget.isTr ? 'Proje Dizini Seç' : 'Select Project Directory'),
      constraints: const BoxConstraints(maxWidth: 560, maxHeight: 520),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Path input + go button
          Row(
            children: [
              Expanded(
                child: TextBox(
                  controller: _pathCtrl,
                  placeholder: widget.isTr ? 'Dizin yolu...' : 'Path...',
                  style: const TextStyle(fontSize: 12, fontFamily: 'JetBrains Mono'),
                  onSubmitted: (v) => _loadDir(v.trim()),
                ),
              ),
              const SizedBox(width: 6),
              Button(
                onPressed: () => _loadDir(_pathCtrl.text.trim()),
                child: const Icon(FluentIcons.forward, size: 12),
              ),
            ],
          ),
          const SizedBox(height: 8),
          // Current path display + up button
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            decoration: BoxDecoration(
              color: workbenchEditorBg,
              borderRadius: BorderRadius.circular(6),
              border: Border.all(color: workbenchBorder, width: 0.5),
            ),
            child: Row(
              children: [
                GestureDetector(
                  onTap: _goUp,
                  child: Container(
                    padding: const EdgeInsets.all(4),
                    decoration: BoxDecoration(
                      color: workbenchPanelAlt,
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: Icon(FluentIcons.up, size: 11, color: workbenchWarning),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    _currentPath,
                    style: TextStyle(
                      color: workbenchText,
                      fontSize: 11,
                      fontFamily: 'JetBrains Mono',
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                if (_loading)
                  SizedBox(
                    width: 14,
                    height: 14,
                    child: ProgressRing(strokeWidth: 2, activeColor: workbenchAccent),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 6),
          // Directory list
          Expanded(
            child: Container(
              decoration: BoxDecoration(
                color: workbenchEditorBg,
                borderRadius: BorderRadius.circular(6),
                border: Border.all(color: workbenchBorder, width: 0.5),
              ),
              child: _entries.isEmpty && !_loading
                  ? Center(
                      child: Text(
                        widget.isTr ? 'Alt klasör yok' : 'No subdirectories',
                        style: TextStyle(color: workbenchTextFaint, fontSize: 11),
                      ),
                    )
                  : ListView.builder(
                      itemCount: _entries.length,
                      itemBuilder: (_, i) {
                        final e = _entries[i];
                        return GestureDetector(
                          onTap: () => _enterDir(e.name),
                          child: Container(
                            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
                            decoration: BoxDecoration(
                              border: Border(
                                bottom: BorderSide(
                                  color: workbenchBorder.withValues(alpha: 0.3),
                                  width: 0.5,
                                ),
                              ),
                            ),
                            child: Row(
                              children: [
                                Icon(
                                  FluentIcons.folder_open,
                                  size: 13,
                                  color: workbenchWarning,
                                ),
                                const SizedBox(width: 8),
                                Expanded(
                                  child: Text(
                                    e.name,
                                    style: TextStyle(
                                      color: workbenchText,
                                      fontSize: 12,
                                    ),
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                                Icon(
                                  FluentIcons.chevron_right,
                                  size: 10,
                                  color: workbenchTextFaint,
                                ),
                              ],
                            ),
                          ),
                        );
                      },
                    ),
            ),
          ),
        ],
      ),
      actions: [
        Button(
          onPressed: () => Navigator.pop(context, null),
          child: Text(widget.isTr ? 'İptal' : 'Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, _currentPath),
          child: Text(widget.isTr ? 'Bu Dizini Seç' : 'Select This Directory'),
        ),
      ],
    );
  }
}

// ── SIMPLE MARKDOWN RENDERER ────────────────────────────────────

// ── Tool group: scrollable container for consecutive tool messages ────
class _AgentToolGroup extends StatefulWidget {
  const _AgentToolGroup({required this.tools, this.isTr = false, this.fontSize = 12});
  final List<AgentCliMessage> tools;
  final bool isTr;
  final double fontSize;

  @override
  State<_AgentToolGroup> createState() => _AgentToolGroupState();
}

class _AgentToolGroupState extends State<_AgentToolGroup> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    // Count only tool_use entries
    final useCount = widget.tools.where((t) => t.role == 'tool_use').length;
    final resultCount = widget.tools.where((t) => t.role == 'tool_result').length;
    final label = '$useCount ${widget.isTr ? 'islem' : 'tool call${useCount > 1 ? 's' : ''}'}';

    return Padding(
      padding: const EdgeInsets.only(bottom: 6, left: 38),
      child: Container(
        decoration: BoxDecoration(
          color: workbenchEditorBg,
          borderRadius: BorderRadius.circular(6),
          border: Border.all(color: workbenchBorder.withValues(alpha: 0.3), width: 0.5),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Header: "5 tool calls  ✓3  ˅"
            GestureDetector(
              onTap: () => setState(() => _expanded = !_expanded),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                child: Row(
                  children: [
                    Icon(FluentIcons.settings, size: 11, color: workbenchTextMuted),
                    const SizedBox(width: 5),
                    Text(
                      label,
                      style: TextStyle(color: workbenchTextMuted, fontSize: 11, fontWeight: FontWeight.w600),
                    ),
                    if (resultCount > 0) ...[
                      const SizedBox(width: 8),
                      Icon(FluentIcons.completed, size: 9, color: workbenchSuccess),
                      const SizedBox(width: 2),
                      Text('$resultCount', style: TextStyle(color: workbenchSuccess, fontSize: 10)),
                    ],
                    const Spacer(),
                    Icon(
                      _expanded ? FluentIcons.chevron_up : FluentIcons.chevron_down,
                      size: 9,
                      color: workbenchTextMuted,
                    ),
                  ],
                ),
              ),
            ),
            // Expanded: scrollable list of tool cards inside
            if (_expanded) ...[
              Container(height: 0.5, color: workbenchBorder.withValues(alpha: 0.2)),
              ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 200),
                child: ListView.builder(
                  shrinkWrap: true,
                  padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 4),
                  itemCount: widget.tools.length,
                  itemBuilder: (_, i) {
                    final t = widget.tools[i];
                    if (t.role == 'tool_use') {
                      // Find paired result
                      AgentCliMessage? result;
                      if (i + 1 < widget.tools.length && widget.tools[i + 1].role == 'tool_result') {
                        result = widget.tools[i + 1];
                      }
                      return _AgentToolCard(
                        message: t,
                        resultMessage: result,
                        fontSize: widget.fontSize,
                        isTr: widget.isTr,
                      );
                    }
                    // Skip tool_result if previous was tool_use (already paired)
                    if (t.role == 'tool_result' && i > 0 && widget.tools[i - 1].role == 'tool_use') {
                      return const SizedBox.shrink();
                    }
                    // Standalone tool_result
                    return _AgentToolResultCard(
                      message: t,
                      fontSize: widget.fontSize,
                      isTr: widget.isTr,
                    );
                  },
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

// ── Tool icon mapping ────────────────────────────────────────────
IconData _toolIcon(String? toolName) {
  switch (toolName?.toLowerCase()) {
    case 'bash': return FluentIcons.code;
    case 'read': return FluentIcons.document;
    case 'edit': case 'multiedit': return FluentIcons.edit;
    case 'write': return FluentIcons.add;
    case 'glob': return FluentIcons.search;
    case 'grep': return FluentIcons.text_field;
    case 'web_search': return FluentIcons.globe;
    default: return FluentIcons.settings;
  }
}

Color _toolColor(String? toolName) {
  switch (toolName?.toLowerCase()) {
    case 'bash': return const Color(0xFF81D4FA);
    case 'read': return const Color(0xFFB0BEC5);
    case 'edit': case 'multiedit': return const Color(0xFFFFCC02);
    case 'write': return const Color(0xFF66BB6A);
    case 'glob': case 'grep': return const Color(0xFF90CAF9);
    default: return workbenchTextMuted;
  }
}

/// Rich expandable tool_use card with icon, file path, and diff support.
class _AgentToolCard extends StatefulWidget {
  const _AgentToolCard({required this.message, this.resultMessage, this.fontSize = 12, this.isTr = false});
  final AgentCliMessage message;
  final AgentCliMessage? resultMessage;  // paired tool_result
  final double fontSize;
  final bool isTr;

  @override
  State<_AgentToolCard> createState() => _AgentToolCardState();
}

class _AgentToolCardState extends State<_AgentToolCard> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final m = widget.message;
    final r = widget.resultMessage;
    final toolName = m.toolName ?? 'tool';
    final hasDiff = m.diffOld != null && m.diffNew != null;
    final hasContent = m.text.trim().isNotEmpty;
    final hasResult = r != null && r.text.trim().isNotEmpty;
    final expandable = hasContent || hasDiff || hasResult;
    final icon = _toolIcon(m.toolName);
    final color = _toolColor(m.toolName);

    // Header label: "Edit  lib/src/app.dart" or just "bash"
    final headerLabel = m.filePath != null
        ? '$toolName  ${m.filePath}'
        : toolName;

    return Padding(
      padding: const EdgeInsets.only(bottom: 4, left: 38),
      child: GestureDetector(
        onTap: expandable ? () => setState(() => _expanded = !_expanded) : null,
        child: Container(
          decoration: BoxDecoration(
            color: workbenchEditorBg,
            borderRadius: BorderRadius.circular(6),
            border: Border.all(color: color.withValues(alpha: 0.2), width: 0.5),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Header row: icon + tool name + file path + result indicator + chevron
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                child: Row(
                  children: [
                    Icon(icon, size: 11, color: color),
                    const SizedBox(width: 5),
                    Expanded(
                      child: Text(
                        headerLabel,
                        style: TextStyle(
                          color: color,
                          fontSize: 11,
                          fontWeight: FontWeight.w600,
                          fontFamily: 'JetBrains Mono',
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    // Result success indicator (compact)
                    if (hasResult) ...[
                      const SizedBox(width: 6),
                      Icon(FluentIcons.completed, size: 9, color: workbenchSuccess),
                    ],
                    if (expandable) ...[
                      const SizedBox(width: 6),
                      Icon(
                        _expanded ? FluentIcons.chevron_up : FluentIcons.chevron_down,
                        size: 9,
                        color: workbenchTextMuted,
                      ),
                    ],
                  ],
                ),
              ),
              // Expanded: tool input + diff + result output
              if (_expanded) ...[
                Container(height: 0.5, color: workbenchBorder.withValues(alpha: 0.2)),
                if (hasDiff)
                  Padding(
                    padding: const EdgeInsets.all(6),
                    child: AgentDiffViewer(
                      oldText: m.diffOld!,
                      newText: m.diffNew!,
                      fontSize: widget.fontSize,
                    ),
                  )
                else if (hasContent)
                  Padding(
                    padding: const EdgeInsets.all(8),
                    child: SelectableText(
                      m.text.trim(),
                      style: TextStyle(
                        color: workbenchTextMuted,
                        fontSize: 10,
                        fontFamily: 'JetBrains Mono',
                        height: 1.4,
                      ),
                    ),
                  ),
                // Merged tool_result output
                if (hasResult) ...[
                  Container(height: 0.5, color: workbenchSuccess.withValues(alpha: 0.1)),
                  Padding(
                    padding: const EdgeInsets.all(8),
                    child: SelectableText(
                      r.text.trim(),
                      style: TextStyle(
                        color: workbenchTextMuted,
                        fontSize: 10,
                        fontFamily: 'JetBrains Mono',
                        height: 1.4,
                      ),
                    ),
                  ),
                ],
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// Collapsible tool_result card.
class _AgentToolResultCard extends StatefulWidget {
  const _AgentToolResultCard({required this.message, this.fontSize = 12, this.isTr = false});
  final AgentCliMessage message;
  final double fontSize;
  final bool isTr;

  @override
  State<_AgentToolResultCard> createState() => _AgentToolResultCardState();
}

class _AgentToolResultCardState extends State<_AgentToolResultCard> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final text = widget.message.text.trim();
    if (text.isEmpty) return const SizedBox.shrink();

    return Padding(
      padding: const EdgeInsets.only(bottom: 4, left: 38),
      child: GestureDetector(
        onTap: () => setState(() => _expanded = !_expanded),
        child: Container(
          decoration: BoxDecoration(
            color: workbenchSuccess.withValues(alpha: 0.04),
            borderRadius: BorderRadius.circular(6),
            border: Border.all(color: workbenchSuccess.withValues(alpha: 0.15), width: 0.5),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Always visible: header only
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                child: Row(
                  children: [
                    Icon(FluentIcons.completed, size: 10, color: workbenchSuccess),
                    const SizedBox(width: 4),
                    Text(
                      widget.isTr ? 'Sonuc' : 'Result',
                      style: TextStyle(color: workbenchSuccess, fontSize: 10, fontWeight: FontWeight.w600),
                    ),
                    const Spacer(),
                    Icon(
                      _expanded ? FluentIcons.chevron_up : FluentIcons.chevron_down,
                      size: 10,
                      color: workbenchTextMuted,
                    ),
                  ],
                ),
              ),
              // Expanded: full output
              if (_expanded) ...[
                Container(height: 0.5, color: workbenchSuccess.withValues(alpha: 0.1)),
                Padding(
                  padding: const EdgeInsets.all(8),
                  child: SelectableText(
                    text,
                    style: TextStyle(
                      color: workbenchTextMuted,
                      fontSize: 11,
                      fontFamily: 'JetBrains Mono',
                      height: 1.4,
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _SimpleMarkdown extends StatelessWidget {
  const _SimpleMarkdown({required this.text, this.fontSize = 13.0});
  final String text;
  final double fontSize;

  @override
  Widget build(BuildContext context) {
    final lines = text.split('\n');
    final widgets = <Widget>[];
    var i = 0;
    while (i < lines.length) {
      final line = lines[i];

      // Code block: ```
      if (line.trimLeft().startsWith('```')) {
        final lang = line.trimLeft().substring(3).trim();
        final codeLines = <String>[];
        i++;
        while (i < lines.length && !lines[i].trimLeft().startsWith('```')) {
          codeLines.add(lines[i]);
          i++;
        }
        if (i < lines.length) i++; // skip closing ```
        widgets.add(_buildCodeBlock(codeLines.join('\n'), lang));
        continue;
      }

      // Heading: # ## ###
      if (line.startsWith('### ')) {
        widgets.add(_buildHeading(line.substring(4), 3));
        i++;
        continue;
      }
      if (line.startsWith('## ')) {
        widgets.add(_buildHeading(line.substring(3), 2));
        i++;
        continue;
      }
      if (line.startsWith('# ')) {
        widgets.add(_buildHeading(line.substring(2), 1));
        i++;
        continue;
      }

      // Empty line
      if (line.trim().isEmpty) {
        widgets.add(const SizedBox(height: 6));
        i++;
        continue;
      }

      // List item: - or * or numbered
      if (RegExp(r'^[\s]*[-*]\s').hasMatch(line) ||
          RegExp(r'^[\s]*\d+\.\s').hasMatch(line)) {
        final indent = line.length - line.trimLeft().length;
        final content = line.trimLeft().replaceFirst(RegExp(r'^[-*]\s|^\d+\.\s'), '');
        widgets.add(_buildListItem(content, indent > 0));
        i++;
        continue;
      }

      // Normal paragraph with inline formatting
      widgets.add(Padding(
        padding: const EdgeInsets.only(bottom: 4),
        child: _buildRichLine(line),
      ));
      i++;
    }

    return SelectionArea(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: widgets,
      ),
    );
  }

  Widget _buildHeading(String text, int level) {
    final size = level == 1 ? 16.0 : level == 2 ? 14.5 : 13.5;
    return Padding(
      padding: const EdgeInsets.only(top: 8, bottom: 4),
      child: Text(
        text,
        style: TextStyle(
          color: workbenchText,
          fontSize: size,
          fontWeight: FontWeight.w700,
          height: 1.4,
        ),
      ),
    );
  }

  Widget _buildCodeBlock(String code, String lang) {
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.symmetric(vertical: 6),
      decoration: BoxDecoration(
        color: workbenchEditorBg,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: workbenchBorder, width: 0.5),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Header: language label + copy button
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
            decoration: BoxDecoration(
              border: Border(bottom: BorderSide(color: workbenchBorder.withValues(alpha: 0.3))),
            ),
            child: Row(
              children: [
                if (lang.isNotEmpty)
                  Text(
                    lang,
                    style: TextStyle(
                      color: workbenchTextFaint,
                      fontSize: 9,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                const Spacer(),
                GestureDetector(
                  onTap: () {
                    Clipboard.setData(ClipboardData(text: code));
                  },
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(FluentIcons.copy, size: 10, color: workbenchTextFaint),
                      const SizedBox(width: 3),
                      Text('Copy', style: TextStyle(color: workbenchTextFaint, fontSize: 9)),
                    ],
                  ),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(10),
            child: SelectableText(
              code,
              style: TextStyle(
                color: workbenchText,
                fontSize: 12,
                fontFamily: 'JetBrains Mono',
                height: 1.5,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildListItem(String content, bool nested) {
    return Padding(
      padding: EdgeInsets.only(left: nested ? 20.0 : 8.0, bottom: 3),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Container(
              width: 4,
              height: 4,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: workbenchTextMuted,
              ),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(child: _buildRichLine(content)),
        ],
      ),
    );
  }

  Widget _buildRichLine(String line) {
    final spans = <InlineSpan>[];
    final regex = RegExp(
      r'(`[^`]+`)|(\*\*[^*]+\*\*)|(\*[^*]+\*)',
    );
    var lastEnd = 0;
    for (final match in regex.allMatches(line)) {
      if (match.start > lastEnd) {
        spans.add(TextSpan(
          text: line.substring(lastEnd, match.start),
          style: TextStyle(color: workbenchText, fontSize: fontSize, height: 1.55),
        ));
      }
      final matched = match.group(0)!;
      if (matched.startsWith('`') && matched.endsWith('`')) {
        // Inline code
        spans.add(WidgetSpan(
          alignment: PlaceholderAlignment.middle,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
            decoration: BoxDecoration(
              color: workbenchEditorBg,
              borderRadius: BorderRadius.circular(3),
              border: Border.all(color: workbenchBorder, width: 0.5),
            ),
            child: Text(
              matched.substring(1, matched.length - 1),
              style: TextStyle(
                color: workbenchAccent,
                fontSize: 12,
                fontFamily: 'JetBrains Mono',
              ),
            ),
          ),
        ));
      } else if (matched.startsWith('**') && matched.endsWith('**')) {
        // Bold
        spans.add(TextSpan(
          text: matched.substring(2, matched.length - 2),
          style: TextStyle(
            color: workbenchText,
            fontSize: fontSize,
            fontWeight: FontWeight.w700,
            height: 1.55,
          ),
        ));
      } else if (matched.startsWith('*') && matched.endsWith('*')) {
        // Italic
        spans.add(TextSpan(
          text: matched.substring(1, matched.length - 1),
          style: TextStyle(
            color: workbenchText,
            fontSize: fontSize,
            fontStyle: FontStyle.italic,
            height: 1.55,
          ),
        ));
      }
      lastEnd = match.end;
    }
    if (lastEnd < line.length) {
      spans.add(TextSpan(
        text: line.substring(lastEnd),
        style: TextStyle(color: workbenchText, fontSize: fontSize, height: 1.55),
      ));
    }
    if (spans.isEmpty) {
      return Text(
        line,
        style: TextStyle(color: workbenchText, fontSize: fontSize, height: 1.55),
      );
    }
    return Text.rich(TextSpan(children: spans));
  }
}
