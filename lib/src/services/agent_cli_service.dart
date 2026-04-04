import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:dartssh2/dartssh2.dart';
import 'package:lifeos_sftp_drive/src/models/connection_profile.dart';
import 'package:lifeos_sftp_drive/src/utils/tmux_utils.dart';
import 'package:path_provider/path_provider.dart';

// DEBUG: temporary file logger
void _debugLog(String msg) {
  try {
    File('C:\\Projeler\\debug_agent.log').writeAsStringSync(
      '${DateTime.now().toIso8601String()} $msg\n',
      mode: FileMode.append,
    );
  } catch (_) {}
}

enum AgentCliProvider { claude, codex, gemini }

enum AgentCliTarget { local, ssh }

extension AgentCliProviderX on AgentCliProvider {
  String get id => name;

  String get label {
    switch (this) {
      case AgentCliProvider.claude:
        return 'Claude';
      case AgentCliProvider.codex:
        return 'Codex';
      case AgentCliProvider.gemini:
        return 'Gemini';
    }
  }

  String get binary {
    switch (this) {
      case AgentCliProvider.claude:
        return 'claude';
      case AgentCliProvider.codex:
        return 'codex';
      case AgentCliProvider.gemini:
        return 'gemini';
    }
  }

  String get defaultModel {
    switch (this) {
      case AgentCliProvider.claude:
        return 'claude-opus-4-6';
      case AgentCliProvider.codex:
        return 'gpt-5.3-codex';
      case AgentCliProvider.gemini:
        return 'auto';
    }
  }

  List<String> get models {
    switch (this) {
      case AgentCliProvider.claude:
        return const [
          'claude-opus-4-6',
          'claude-sonnet-4-6',
          'claude-haiku-4-5-20251001',
        ];
      case AgentCliProvider.codex:
        return const [
          'gpt-5.3-codex',
          'gpt-5.2-codex',
          'gpt-5.1-codex',
          'gpt-5.1-codex-mini',
        ];
      case AgentCliProvider.gemini:
        return const [
          'auto',
          'gemini-2.5-flash',
          'gemini-2.5-pro',
          'gemini-2.5-flash-lite',
          'gemini-3-flash-preview',
          'gemini-3-pro-preview',
          'gemini-3.1-pro-preview',
        ];
    }
  }
}

/// Message roles:
///  - 'user'        : user-sent message
///  - 'assistant'   : final AI response text
///  - 'streaming'   : partial streaming text (transient, not persisted)
///  - 'system'      : system/error message
///  - 'tool_use'    : agent executed a tool (toolName + text as input)
///  - 'tool_result' : output of a tool execution
class AgentCliMessage {
  const AgentCliMessage({
    required this.id,
    required this.role,
    required this.text,
    required this.createdAt,
    this.toolName,
    this.costUsd,
    this.files,
    this.filePath,
    this.diffOld,
    this.diffNew,
  });

  final String id;
  final String role;
  final String text;
  final DateTime createdAt;
  final String? toolName;     // for tool_use messages
  final double? costUsd;      // for result messages with cost
  final List<String>? files;  // attached file paths
  final String? filePath;     // tool_use: target file path
  final String? diffOld;      // Edit tool: old_string for diff view
  final String? diffNew;      // Edit tool: new_string for diff view

  AgentCliMessage copyWith({String? text, String? role, double? costUsd}) {
    return AgentCliMessage(
      id: id,
      role: role ?? this.role,
      text: text ?? this.text,
      createdAt: createdAt,
      toolName: toolName,
      costUsd: costUsd ?? this.costUsd,
      files: files,
      filePath: filePath,
      diffOld: diffOld,
      diffNew: diffNew,
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'role': role == 'streaming' ? 'assistant' : role,
    'text': text,
    'createdAt': createdAt.toIso8601String(),
    if (toolName != null) 'toolName': toolName,
    if (costUsd != null) 'costUsd': costUsd,
    if (files != null && files!.isNotEmpty) 'files': files,
    if (filePath != null) 'filePath': filePath,
    if (diffOld != null) 'diffOld': diffOld,
    if (diffNew != null) 'diffNew': diffNew,
  };

  factory AgentCliMessage.fromJson(Map<String, dynamic> json) {
    final filesRaw = json['files'];
    List<String>? files;
    if (filesRaw is List) {
      files = filesRaw.map((e) => e.toString()).toList();
    }
    return AgentCliMessage(
      id: (json['id'] ?? '').toString(),
      role: (json['role'] ?? 'assistant').toString(),
      text: (json['text'] ?? '').toString(),
      createdAt:
          DateTime.tryParse((json['createdAt'] ?? '').toString()) ??
          DateTime.now(),
      toolName: json['toolName'] as String?,
      costUsd: (json['costUsd'] as num?)?.toDouble(),
      files: files,
      filePath: json['filePath'] as String?,
      diffOld: json['diffOld'] as String?,
      diffNew: json['diffNew'] as String?,
    );
  }
}

class AgentCliSession {
  const AgentCliSession({
    required this.id,
    required this.provider,
    required this.target,
    required this.model,
    this.name,
    this.profileId,
    this.cwd,
    this.cliSessionId,
    required this.createdAt,
    required this.updatedAt,
    required this.messages,
  });

  final String id;
  final AgentCliProvider provider;
  final AgentCliTarget target;
  final String model;
  final String? name;
  final String? profileId;
  final String? cwd;
  final String? cliSessionId;
  final DateTime createdAt;
  final DateTime updatedAt;
  final List<AgentCliMessage> messages;

  AgentCliSession copyWith({
    String? model,
    String? name,
    String? profileId,
    String? cwd,
    String? cliSessionId,
    DateTime? updatedAt,
    List<AgentCliMessage>? messages,
  }) {
    return AgentCliSession(
      id: id,
      provider: provider,
      target: target,
      model: model ?? this.model,
      name: name ?? this.name,
      profileId: profileId ?? this.profileId,
      cwd: cwd ?? this.cwd,
      cliSessionId: cliSessionId ?? this.cliSessionId,
      createdAt: createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      messages: messages ?? this.messages,
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'provider': provider.id,
    'target': target.name,
    'model': model,
    if (name != null && name!.trim().isNotEmpty) 'name': name,
    if (profileId != null) 'profileId': profileId,
    if (cwd != null) 'cwd': cwd,
    if (cliSessionId != null) 'cliSessionId': cliSessionId,
    'createdAt': createdAt.toIso8601String(),
    'updatedAt': updatedAt.toIso8601String(),
    'messages': messages.map((e) => e.toJson()).toList(),
  };

  factory AgentCliSession.fromJson(Map<String, dynamic> json) {
    AgentCliProvider parseProvider(String value) {
      return AgentCliProvider.values.firstWhere(
        (e) => e.id == value,
        orElse: () => AgentCliProvider.codex,
      );
    }

    AgentCliTarget parseTarget(String value) {
      return AgentCliTarget.values.firstWhere(
        (e) => e.name == value,
        orElse: () => AgentCliTarget.local,
      );
    }

    final provider = parseProvider((json['provider'] ?? '').toString());
    final messagesRaw = json['messages'];
    final messages = <AgentCliMessage>[];
    if (messagesRaw is List) {
      for (final item in messagesRaw) {
        if (item is Map<String, dynamic>) {
          messages.add(AgentCliMessage.fromJson(item));
        } else if (item is Map) {
          messages.add(AgentCliMessage.fromJson(item.cast<String, dynamic>()));
        }
      }
    }

    final modelRaw = (json['model'] ?? '').toString().trim();
    final sessionId = (json['id'] ?? '').toString().trim();
    return AgentCliSession(
      id: sessionId.isEmpty ? _randomId() : sessionId,
      provider: provider,
      target: parseTarget((json['target'] ?? '').toString()),
      model: modelRaw.isEmpty ? provider.defaultModel : modelRaw,
      name: (json['name'] as String?)?.trim(),
      profileId: (json['profileId'] as String?)?.trim(),
      cwd: (json['cwd'] as String?)?.trim(),
      cliSessionId: (json['cliSessionId'] as String?)?.trim(),
      createdAt:
          DateTime.tryParse((json['createdAt'] ?? '').toString()) ??
          DateTime.now(),
      updatedAt:
          DateTime.tryParse((json['updatedAt'] ?? '').toString()) ??
          DateTime.now(),
      messages: messages,
    );
  }
}

class AgentCliStoreData {
  const AgentCliStoreData({
    required this.provider,
    required this.target,
    required this.selectedProfileByProvider,
    required this.selectedModelByProvider,
    required this.selectedSessionByScope,
    required this.sessions,
    this.fontSize = 13.0,
    this.cwdByProvider = const {},
    this.streamingTimeoutMinutes = 5,
    this.agentTmuxEnabled = true,
  });

  final AgentCliProvider provider;
  final AgentCliTarget target;
  final Map<String, String> selectedProfileByProvider;
  final Map<String, String> selectedModelByProvider;
  final Map<String, String> selectedSessionByScope;
  final List<AgentCliSession> sessions;
  final double fontSize;
  final Map<String, String> cwdByProvider;
  final int streamingTimeoutMinutes;
  final bool agentTmuxEnabled;

  factory AgentCliStoreData.initial() {
    return AgentCliStoreData(
      provider: AgentCliProvider.codex,
      target: AgentCliTarget.local,
      selectedProfileByProvider: const {},
      selectedModelByProvider: {
        for (final p in AgentCliProvider.values) p.id: p.defaultModel,
      },
      selectedSessionByScope: const {},
      sessions: const [],
      fontSize: 13.0,
    );
  }

  AgentCliStoreData copyWith({
    AgentCliProvider? provider,
    AgentCliTarget? target,
    Map<String, String>? selectedProfileByProvider,
    Map<String, String>? selectedModelByProvider,
    Map<String, String>? selectedSessionByScope,
    List<AgentCliSession>? sessions,
    double? fontSize,
    Map<String, String>? cwdByProvider,
    int? streamingTimeoutMinutes,
    bool? agentTmuxEnabled,
  }) {
    return AgentCliStoreData(
      provider: provider ?? this.provider,
      target: target ?? this.target,
      selectedProfileByProvider:
          selectedProfileByProvider ?? this.selectedProfileByProvider,
      selectedModelByProvider:
          selectedModelByProvider ?? this.selectedModelByProvider,
      selectedSessionByScope:
          selectedSessionByScope ?? this.selectedSessionByScope,
      sessions: sessions ?? this.sessions,
      fontSize: fontSize ?? this.fontSize,
      cwdByProvider: cwdByProvider ?? this.cwdByProvider,
      streamingTimeoutMinutes:
          streamingTimeoutMinutes ?? this.streamingTimeoutMinutes,
      agentTmuxEnabled: agentTmuxEnabled ?? this.agentTmuxEnabled,
    );
  }

  Map<String, dynamic> toJson() => {
    'provider': provider.id,
    'target': target.name,
    'selectedProfileByProvider': selectedProfileByProvider,
    'selectedModelByProvider': selectedModelByProvider,
    'selectedSessionByScope': selectedSessionByScope,
    'sessions': sessions.map((e) => e.toJson()).toList(),
    'fontSize': fontSize,
    'cwdByProvider': cwdByProvider,
    'streamingTimeoutMinutes': streamingTimeoutMinutes,
    'agentTmuxEnabled': agentTmuxEnabled,
  };

  factory AgentCliStoreData.fromJson(Map<String, dynamic> json) {
    AgentCliProvider parseProvider(String value) {
      return AgentCliProvider.values.firstWhere(
        (e) => e.id == value,
        orElse: () => AgentCliProvider.codex,
      );
    }

    AgentCliTarget parseTarget(String value) {
      return AgentCliTarget.values.firstWhere(
        (e) => e.name == value,
        orElse: () => AgentCliTarget.local,
      );
    }

    final selectedModelByProvider = <String, String>{
      for (final p in AgentCliProvider.values) p.id: p.defaultModel,
    };
    final modelRaw = json['selectedModelByProvider'];
    if (modelRaw is Map) {
      modelRaw.forEach((key, value) {
        final providerId = key.toString().trim();
        final model = value.toString().trim();
        if (providerId.isNotEmpty && model.isNotEmpty) {
          selectedModelByProvider[providerId] = model;
        }
      });
    }

    final selectedSessionByScope = <String, String>{};
    final sessionSelRaw = json['selectedSessionByScope'];
    if (sessionSelRaw is Map) {
      sessionSelRaw.forEach((key, value) {
        final scope = key.toString().trim();
        final sid = value.toString().trim();
        if (scope.isNotEmpty && sid.isNotEmpty) {
          selectedSessionByScope[scope] = sid;
        }
      });
    }

    final sessions = <AgentCliSession>[];
    final sessionsRaw = json['sessions'];
    if (sessionsRaw is List) {
      for (final item in sessionsRaw) {
        if (item is Map<String, dynamic>) {
          sessions.add(AgentCliSession.fromJson(item));
        } else if (item is Map) {
          sessions.add(AgentCliSession.fromJson(item.cast<String, dynamic>()));
        }
      }
    }

    // Parse selectedProfileByProvider with migration from old selectedProfileId
    final selectedProfileByProvider = <String, String>{};
    final profileMapRaw = json['selectedProfileByProvider'];
    if (profileMapRaw is Map) {
      profileMapRaw.forEach((key, value) {
        final pid = key.toString().trim();
        final val = value.toString().trim();
        if (pid.isNotEmpty && val.isNotEmpty) {
          selectedProfileByProvider[pid] = val;
        }
      });
    } else {
      // Migration: old selectedProfileId → broadcast to all providers
      final legacyId = (json['selectedProfileId'] ?? '').toString().trim();
      if (legacyId.isNotEmpty) {
        for (final p in AgentCliProvider.values) {
          selectedProfileByProvider[p.id] = legacyId;
        }
      }
    }

    return AgentCliStoreData(
      provider: parseProvider((json['provider'] ?? '').toString()),
      target: parseTarget((json['target'] ?? '').toString()),
      selectedProfileByProvider: selectedProfileByProvider,
      selectedModelByProvider: selectedModelByProvider,
      selectedSessionByScope: selectedSessionByScope,
      sessions: sessions,
      fontSize: (json['fontSize'] as num?)?.toDouble() ?? 13.0,
      cwdByProvider: () {
        final raw = json['cwdByProvider'];
        if (raw is Map) {
          return raw.map((k, v) => MapEntry(k.toString(), v.toString()));
        }
        return <String, String>{};
      }(),
      streamingTimeoutMinutes: (json['streamingTimeoutMinutes'] as num?)?.toInt() ?? 5,
      agentTmuxEnabled: json['agentTmuxEnabled'] as bool? ?? true,
    );
  }
}

class AgentCliStore {
  Future<AgentCliStoreData> load() async {
    try {
      final file = await _file();
      if (!await file.exists()) {
        return AgentCliStoreData.initial();
      }
      final raw = await file.readAsString();
      final json = jsonDecode(raw);
      if (json is Map<String, dynamic>) {
        return AgentCliStoreData.fromJson(json);
      }
      if (json is Map) {
        return AgentCliStoreData.fromJson(json.cast<String, dynamic>());
      }
      return AgentCliStoreData.initial();
    } catch (_) {
      return AgentCliStoreData.initial();
    }
  }

  Future<void> save(AgentCliStoreData data) async {
    try {
      final file = await _file();
      await file.writeAsString(jsonEncode(data.toJson()));
    } catch (_) {}
  }

  Future<File> _file() async {
    final dir = await getApplicationSupportDirectory();
    return File('${dir.path}${Platform.pathSeparator}agent_cli_store.json');
  }

  // ── Remote (SSH) hybrid history ─────────────────────────────

  /// Save sessions to remote `.lifeos/agent_history.json` via SFTP.
  Future<void> saveRemote(
    SSHClient client,
    String remoteCwd,
    List<AgentCliSession> sessions,
  ) async {
    try {
      final sftp = await client.sftp();
      final dir = '$remoteCwd/.lifeos';
      // Ensure directory exists
      try { await sftp.mkdir(dir); } catch (_) {}
      final path = '$dir/agent_history.json';
      final data = jsonEncode(sessions.map((s) => s.toJson()).toList());
      final file = await sftp.open(path, mode: SftpFileOpenMode.create | SftpFileOpenMode.write | SftpFileOpenMode.truncate);
      await file.writeBytes(utf8.encode(data));
      await file.close();
    } catch (_) {}
  }

  /// Load sessions from remote `.lifeos/agent_history.json` via SFTP.
  Future<List<AgentCliSession>> loadRemote(
    SSHClient client,
    String remoteCwd,
  ) async {
    try {
      final sftp = await client.sftp();
      final path = '$remoteCwd/.lifeos/agent_history.json';
      final file = await sftp.open(path, mode: SftpFileOpenMode.read);
      final bytes = await file.readBytes();
      await file.close();
      final raw = utf8.decode(bytes);
      final list = jsonDecode(raw);
      if (list is List) {
        return list.map((e) {
          if (e is Map<String, dynamic>) return AgentCliSession.fromJson(e);
          if (e is Map) return AgentCliSession.fromJson(e.cast<String, dynamic>());
          return null;
        }).whereType<AgentCliSession>().toList();
      }
    } catch (_) {}
    return [];
  }

  /// Merge remote sessions into local data. Returns updated data if changed.
  AgentCliStoreData? mergeRemoteSessions(
    AgentCliStoreData local,
    List<AgentCliSession> remote,
  ) {
    if (remote.isEmpty) return null;
    final localIds = local.sessions.map((s) => s.id).toSet();
    final merged = List<AgentCliSession>.from(local.sessions);
    bool changed = false;
    for (final rs in remote) {
      if (!localIds.contains(rs.id)) {
        merged.add(rs);
        changed = true;
      } else {
        // Update if remote is newer
        final localIdx = merged.indexWhere((s) => s.id == rs.id);
        if (localIdx >= 0 && rs.updatedAt.isAfter(merged[localIdx].updatedAt)) {
          merged[localIdx] = rs;
          changed = true;
        }
      }
    }
    if (!changed) return null;
    return local.copyWith(sessions: merged);
  }
}

class AgentCliExecutionResult {
  const AgentCliExecutionResult({
    required this.success,
    required this.assistantText,
    required this.rawOutput,
    required this.exitCode,
    required this.durationMs,
    this.errorMessage,
    this.cliSessionId,
  });

  final bool success;
  final String assistantText;
  final String rawOutput;
  final int exitCode;
  final int durationMs;
  final String? errorMessage;
  final String? cliSessionId;
}

class AgentDirEntry {
  const AgentDirEntry({required this.name, required this.isDir});
  final String name;
  final bool isDir;
}

/// Streaming event types emitted during CLI execution
enum AgentStreamEventType { text, toolUse, toolResult, cost, sessionId, done, error, timeout }

class AgentStreamEvent {
  const AgentStreamEvent({
    required this.type,
    this.text,
    this.toolName,
    this.toolInput,
    this.costUsd,
    this.sessionId,
    this.exitCode,
    this.filePath,
    this.diffOld,
    this.diffNew,
  });
  final AgentStreamEventType type;
  final String? text;
  final String? toolName;
  final String? toolInput;
  final double? costUsd;
  final String? sessionId;
  final int? exitCode;
  final String? filePath;      // tool_use: target file path
  final String? diffOld;       // Edit tool: old_string for diff
  final String? diffNew;       // Edit tool: new_string for diff
}

class AgentCliRuntime {
  // ── Active process/session tracking for force-kill ──────────
  Process? _activeLocalProcess;
  SSHSession? _activeSshSession;
  String? _activeSshPoolKey;  // track which pool entry is in use

  /// Force-kill the currently running agent process/session.
  void forceStop() {
    try { _activeLocalProcess?.kill(ProcessSignal.sigkill); } catch (_) {}
    try { _activeSshSession?.close(); } catch (_) {}
    // Remove pool entry to prevent reuse of potentially broken connection
    if (_activeSshPoolKey != null) {
      _removeSshClient(_activeSshPoolKey!);
    }
    _activeLocalProcess = null;
    _activeSshSession = null;
    _activeSshPoolKey = null;
  }

  // ── SSH Connection Pool ───────────────────────────────────────
  final Map<String, SSHClient> _sshPool = {};
  final Map<String, DateTime> _sshPoolLastUsed = {};
  // Guard against concurrent connection creation for same key
  final Map<String, Future<SSHClient>> _sshPoolPending = {};

  /// Public access to SSH pool for remote history sync.
  Future<SSHClient> getOrCreateSshClient(ConnectionProfile profile, {String? tag}) => _getOrCreateSshClient(profile, tag: tag);

  String _sshPoolKey(ConnectionProfile profile, {String? tag}) {
    final base = '${profile.host}:${profile.port}:${profile.username}';
    return tag != null ? '$base:$tag' : base;
  }

  Future<SSHClient> _getOrCreateSshClient(ConnectionProfile profile, {String? tag}) async {
    final key = _sshPoolKey(profile, tag: tag);
    // Return existing if alive
    final existing = _sshPool[key];
    if (existing != null) {
      // Quick health check — run trivial command with 3s timeout
      try {
        await existing.run('true').timeout(const Duration(seconds: 3));
        _sshPoolLastUsed[key] = DateTime.now();
        return existing;
      } catch (_) {
        // Connection is dead — remove and recreate
        _removeSshClient(key);
      }
    }
    // Prevent concurrent creation for same key
    if (_sshPoolPending.containsKey(key)) {
      return _sshPoolPending[key]!;
    }
    final future = _createSshClient(profile, key);
    _sshPoolPending[key] = future;
    try {
      return await future;
    } finally {
      _sshPoolPending.remove(key);
    }
  }

  Future<SSHClient> _createSshClient(ConnectionProfile profile, String key) async {
    final socket = await SSHSocket.connect(
      profile.host,
      profile.port,
    ).timeout(const Duration(seconds: 12));
    final identities = await _loadIdentities(profile);
    final client = SSHClient(
      socket,
      username: profile.username,
      identities: identities.isEmpty ? null : identities,
      onPasswordRequest: profile.password.trim().isEmpty
          ? null
          : () => profile.password,
    );
    _sshPool[key] = client;
    _sshPoolLastUsed[key] = DateTime.now();
    return client;
  }

  void _removeSshClient(String key) {
    final client = _sshPool.remove(key);
    _sshPoolLastUsed.remove(key);
    try {
      client?.close();
    } catch (_) {}
  }

  /// Close all pooled SSH connections
  void disposePool() {
    for (final entry in _sshPool.entries) {
      try {
        entry.value.close();
      } catch (_) {}
    }
    _sshPool.clear();
    _sshPoolLastUsed.clear();
  }

  /// List directories in a local path
  Future<List<AgentDirEntry>> listLocalDir(String path) async {
    try {
      final dir = Directory(path);
      if (!await dir.exists()) return const [];
      final entries = <AgentDirEntry>[];
      await for (final entity in dir.list(followLinks: false)) {
        if (entity is Directory) {
          final name = entity.path.split(Platform.pathSeparator).last;
          if (name.startsWith('.')) continue; // skip hidden
          entries.add(AgentDirEntry(name: name, isDir: true));
        }
      }
      entries.sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
      return entries;
    } catch (_) {
      return const [];
    }
  }

  /// List directories on a remote SSH host
  Future<List<AgentDirEntry>> listSshDir(
    ConnectionProfile profile,
    String path,
  ) async {
    try {
      final cmd =
          'ls -1pA ${_shellQuote(path)} 2>/dev/null | grep "/" | head -100';
      final raw = await _runSshText(profile, cmd, timeout: const Duration(seconds: 8));
      final entries = <AgentDirEntry>[];
      for (final line in raw.split('\n')) {
        final trimmed = line.trim();
        if (trimmed.isEmpty) continue;
        final name = trimmed.endsWith('/') ? trimmed.substring(0, trimmed.length - 1) : trimmed;
        if (name.isEmpty || name.startsWith('.')) continue;
        entries.add(AgentDirEntry(name: name, isDir: true));
      }
      entries.sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
      return entries;
    } catch (_) {
      return const [];
    }
  }

  Future<bool> isCliAvailableLocal(AgentCliProvider provider) async {
    try {
      if (Platform.isWindows) {
        final res = await Process.run('where', [
          provider.binary,
        ], runInShell: true);
        return res.exitCode == 0;
      }
      final res = await Process.run('which', [provider.binary]);
      return res.exitCode == 0;
    } catch (_) {
      return false;
    }
  }

  Future<bool> isCliAvailableSsh(
    ConnectionProfile profile,
    AgentCliProvider provider,
  ) async {
    // Use login shell (-l) to ensure PATH includes npm global bin, nvm, etc.
    final cmd =
        'export PATH="\$HOME/.local/bin:\$HOME/.npm-global/bin:\$HOME/.nvm/versions/node/*/bin:/usr/local/bin:/usr/bin:\$PATH"; '
        'command -v ${provider.binary} >/dev/null 2>&1 && echo __LIFEOS_OK__ || echo __LIFEOS_MISSING__';
    try {
      final out = await _runSshText(
        profile,
        cmd,
        timeout: const Duration(seconds: 10),
      );
      return out.contains('__LIFEOS_OK__');
    } catch (_) {
      return false;
    }
  }

  String loginCommand(AgentCliProvider provider) {
    switch (provider) {
      case AgentCliProvider.claude:
        return 'claude login';
      case AgentCliProvider.codex:
        return 'codex login';
      case AgentCliProvider.gemini:
        return 'gemini auth login';
    }
  }

  String installCommand(AgentCliProvider provider) {
    switch (provider) {
      case AgentCliProvider.claude:
        return 'npm i -g @anthropic-ai/claude-code';
      case AgentCliProvider.codex:
        return 'npm i -g @openai/codex';
      case AgentCliProvider.gemini:
        return 'npm i -g @google/gemini-cli';
    }
  }

  // ── STREAMING EXECUTION ─────────────────────────────────────
  /// Execute CLI locally with streaming callbacks.
  Future<AgentCliExecutionResult> executeLocalStreaming({
    required AgentCliProvider provider,
    required String model,
    required String prompt,
    required bool preferTurkish,
    required void Function(AgentStreamEvent event) onEvent,
    String? resumeSessionId,
    String? cwd,
    String approvalMode = 'auto',
    Duration timeout = const Duration(minutes: 5),
    bool Function()? isStopRequested,
  }) async {
    final start = DateTime.now();
    final spec = _buildCommand(
      provider: provider, model: model, prompt: prompt,
      preferTurkish: preferTurkish, resumeSessionId: resumeSessionId,
      approvalMode: approvalMode,
    );
    if (spec == null) {
      return const AgentCliExecutionResult(
        success: false, assistantText: '', rawOutput: '',
        exitCode: 127, durationMs: 0, errorMessage: 'Unsupported provider.',
      );
    }
    try {
      final env = Map<String, String>.from(Platform.environment);
      env['TERM'] = 'xterm-256color';
      env['PYTHONIOENCODING'] = 'utf-8';
      env['LANG'] = 'en_US.UTF-8';
      final workDir = (cwd != null && cwd.trim().isNotEmpty) ? cwd.trim() : null;

      final process = await Process.start(
        spec.command, spec.args,
        workingDirectory: workDir, runInShell: true, environment: env,
      );
      _activeLocalProcess = process;

      _resetCodexStreamState();
      final rawBuf = StringBuffer();
      final textBuf = StringBuffer();
      String? sessionId;
      double totalCost = 0;
      bool timedOut = false;
      bool stopped = false;
      var pending = '';

      // Timeout timer — kills process after duration
      final timer = Timer(timeout, () {
        timedOut = true;
        process.kill(ProcessSignal.sigterm);
        Future.delayed(const Duration(seconds: 3), () {
          try { process.kill(ProcessSignal.sigkill); } catch (_) {}
        });
      });

      try {
        await for (final bytes in process.stdout) {
          // Check stop request each chunk
          if (!stopped && isStopRequested != null && isStopRequested()) {
            stopped = true;
            process.kill(ProcessSignal.sigterm);
            Future.delayed(const Duration(seconds: 3), () {
              try { process.kill(ProcessSignal.sigkill); } catch (_) {}
            });
          }
          final chunk = utf8.decode(bytes, allowMalformed: true);
          rawBuf.write(chunk);
          final merged = '$pending$chunk';
          final lines = merged.split('\n');
          pending = lines.removeLast();
          for (final line in lines) {
            final trimmed = line.trim();
            if (trimmed.isEmpty) continue;
            _parseStreamLine(trimmed, textBuf, onEvent, (sid) => sessionId = sid, (c) => totalCost += c);
          }
        }
        final tail = pending.trim();
        if (tail.isNotEmpty) {
          _parseStreamLine(tail, textBuf, onEvent, (sid) => sessionId = sid, (c) => totalCost += c);
        }
      } finally {
        timer.cancel();
        _activeLocalProcess = null;
      }

      final exitCode = await process.exitCode.timeout(
        const Duration(seconds: 10), onTimeout: () { process.kill(); return 124; },
      );
      final elapsed = DateTime.now().difference(start).inMilliseconds;
      final text = textBuf.toString().trim();
      final rawOutput = rawBuf.toString();
      final parsed = _parseCliOutput(provider, rawOutput);
      final parsedText = parsed.text.trim();
      final assistantText = text.isNotEmpty
          ? text
          : (parsedText.isNotEmpty
              ? parsedText
              : _cleanCliOutputForDisplay(rawOutput));
      final effectiveSessionId = sessionId ?? parsed.sessionId;

      if (timedOut) {
        onEvent(AgentStreamEvent(type: AgentStreamEventType.timeout, text: 'Timeout after ${timeout.inMinutes}m'));
      }
      onEvent(AgentStreamEvent(type: AgentStreamEventType.done, exitCode: exitCode));

      return AgentCliExecutionResult(
        success: !timedOut && !stopped && exitCode == 0,
        assistantText: assistantText,
        rawOutput: rawOutput, exitCode: exitCode, durationMs: elapsed,
        errorMessage: timedOut
            ? 'Timeout after ${timeout.inMinutes} minutes.'
            : (stopped ? 'Stopped by user.' : (exitCode == 0 ? null : _normalizeFailureMessage(provider: provider, output: rawOutput, fallback: 'Failed.'))),
        cliSessionId: effectiveSessionId,
      );
    } catch (e) {
      final elapsed = DateTime.now().difference(start).inMilliseconds;
      onEvent(AgentStreamEvent(type: AgentStreamEventType.error, text: e.toString()));
      return AgentCliExecutionResult(
        success: false, assistantText: '', rawOutput: '',
        exitCode: 124, durationMs: elapsed, errorMessage: e.toString(),
      );
    }
  }

  /// Execute CLI via SSH with streaming callbacks.
  Future<AgentCliExecutionResult> executeSshStreaming({
    required ConnectionProfile profile,
    required AgentCliProvider provider,
    required String model,
    required String prompt,
    required bool preferTurkish,
    required void Function(AgentStreamEvent event) onEvent,
    String? resumeSessionId,
    String? cwd,
    String approvalMode = 'auto',
    Duration timeout = const Duration(minutes: 5),
    bool Function()? isStopRequested,
    bool useTmux = false,
    String? tmuxSessionName,
    bool tmuxRecover = false,
  }) async {
    final start = DateTime.now();
    final spec = _buildCommand(
      provider: provider, model: model, prompt: prompt,
      preferTurkish: preferTurkish, resumeSessionId: resumeSessionId,
      approvalMode: approvalMode,
    );
    if (spec == null) {
      return const AgentCliExecutionResult(
        success: false, assistantText: '', rawOutput: '',
        exitCode: 127, durationMs: 0, errorMessage: 'Unsupported provider.',
      );
    }
    final invocation = _shellJoin(spec.command, spec.args);
    final remoteCwd = (cwd != null && cwd.trim().isNotEmpty)
        ? cwd.trim()
        : (profile.remotePath.trim().isEmpty ? '~' : profile.remotePath);
    final sshPoolTag = 'agent:${provider.id}';
    final sshKey = _sshPoolKey(profile, tag: sshPoolTag);
    _activeSshPoolKey = sshKey;
    SSHClient? sshClient;
    try {
      // Try pool first
      try {
        sshClient = await _getOrCreateSshClient(profile, tag: sshPoolTag);
      } catch (_) {
        _removeSshClient(sshKey);
        sshClient = await _getOrCreateSshClient(profile, tag: sshPoolTag);
      }
      final client = sshClient;
      String? activeTmuxSessionName;

      Future<void> killActiveTmuxSession() async {
        final sessionName = activeTmuxSessionName;
        if (sessionName == null || sessionName.trim().isEmpty) return;
        try {
          await client.run(
            'tmux kill-session -t ${_shellQuote(sessionName)} >/dev/null 2>&1 || true',
          );
        } catch (_) {}
      }

      // Build wrapped command
      final envSetup =
          'export PATH="\$HOME/.local/bin:\$HOME/.npm-global/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:\$PATH"; '
          'export LANG=en_US.UTF-8; '
          'export NO_COLOR=1; '
          'export FORCE_COLOR=0; '
          'cd ${_shellQuote(remoteCwd)} >/dev/null 2>&1 || exit 11; ';

      // Redirect stdin to /dev/null to avoid "no stdin" warnings from CLI tools.
      // Safe because all providers receive prompt as argument, not via stdin.
      const stdinRedirect = ' < /dev/null';

      final baseWrapped = '$envSetup'
          '$invocation$stdinRedirect 2>&1; '
          '__x=\$?; printf "\\n__LIFEOS_EXIT__%s\\n" "\$__x"';
      var wrapped = baseWrapped;
      bool tmuxActive = false;

      if (useTmux) {
        final rawSession = (tmuxSessionName != null && tmuxSessionName.trim().isNotEmpty)
            ? tmuxSessionName.trim()
            : TmuxUtils.buildAgentSessionName(
                providerId: provider.id,
                username: profile.username,
                host: profile.host,
                port: profile.port,
              );
        final sessionName = TmuxUtils.normalizeTmuxToken(rawSession);
        activeTmuxSessionName = sessionName;

        var hasTmux = await TmuxUtils.hasTmux(client);
        if (!hasTmux) {
          hasTmux = await TmuxUtils.installTmux(client);
        }

        if (hasTmux) {
          // Write command to a script file (avoids all escaping issues)
          final scriptPath = '/tmp/.lifeos_cli_run_$sessionName.sh';
          final logPath = '/tmp/.lifeos_cli_$sessionName.log';
          final scriptContent =
              '#!/bin/bash\n'
              '$envSetup'
              '$invocation$stdinRedirect 2>&1 | tee ${_shellQuote(logPath)}; '
              'printf "\\n__LIFEOS_EXIT__%s\\n" "\$?" >> ${_shellQuote(logPath)}\n';

          // Step 1: Write script + start tmux (via client.run, not execute)
          await client.run(
            'printf %s ${_shellQuote(scriptContent)} > ${_shellQuote(scriptPath)} && '
            'chmod +x ${_shellQuote(scriptPath)} && '
            'rm -f ${_shellQuote(logPath)} && touch ${_shellQuote(logPath)} && '
            'tmux kill-session -t ${_shellQuote(sessionName)} 2>/dev/null; '
            'tmux new-session -d -s ${_shellQuote(sessionName)} "bash ${_shellQuote(scriptPath)}"',
          ).timeout(const Duration(seconds: 10));

          // Step 2: Stream via tail -f (will be read by await for loop below)
          // tail -f exits when we close the SSH session (on timeout/stop/done)
          wrapped = 'sleep 0.3; tail -f ${_shellQuote(logPath)}';
          tmuxActive = true;
        } else {
          activeTmuxSessionName = null;
        }
      }

      _debugLog('[SSH-CMD ${provider.id}] tmux=$tmuxActive wrapped=${wrapped.substring(0, wrapped.length > 400 ? 400 : wrapped.length)}');
      final session = await client.execute(wrapped);
      _activeSshSession = session;
      _resetCodexStreamState();
      final rawBuf = StringBuffer();
      final textBuf = StringBuffer();
      String? cliSessionId;
      double totalCost = 0;
      bool timedOut = false;
      bool stopped = false;
      var pending = '';

      // Timeout timer
      final timer = Timer(timeout, () {
        timedOut = true;
        session.close();
        unawaited(killActiveTmuxSession());
      });

      try {
        await for (final bytes in session.stdout) {
          if (!stopped && isStopRequested != null && isStopRequested()) {
            stopped = true;
            session.close();
            unawaited(killActiveTmuxSession());
          }
          final chunk = utf8.decode(bytes, allowMalformed: true);
          // DEBUG
          _debugLog('[SSH-CHUNK ${provider.id}] ${chunk.length}B: ${chunk.substring(0, chunk.length > 300 ? 300 : chunk.length).replaceAll('\n', '\\n')}');
          rawBuf.write(chunk);
          final merged = '$pending$chunk';
          final lines = merged.split('\n');
          pending = lines.removeLast();
          bool exitMarkerSeen = false;
          for (final line in lines) {
            final trimmed = line.trim();
            if (trimmed.isEmpty) continue;
            if (trimmed.contains('__LIFEOS_EXIT__')) {
              exitMarkerSeen = true;
              continue;
            }
            _parseStreamLine(trimmed, textBuf, onEvent, (sid) => cliSessionId = sid, (c) => totalCost += c);
          }
          // In tmux mode, tail -f won't exit on its own — close when done
          if (exitMarkerSeen && tmuxActive) {
            session.close();
            break;
          }
        }
        final tail = pending.trim();
        if (tail.isNotEmpty && !tail.contains('__LIFEOS_EXIT__')) {
          _parseStreamLine(tail, textBuf, onEvent, (sid) => cliSessionId = sid, (c) => totalCost += c);
        }
      } finally {
        timer.cancel();
        _activeSshSession = null;
      }
      _debugLog('[SSH-DONE ${provider.id}] raw=${rawBuf.length}B text=${textBuf.length}B sid=$cliSessionId timedOut=$timedOut stopped=$stopped');
      session.close();

      final raw = rawBuf.toString();
      final parsedExit = RegExp(r'__LIFEOS_EXIT__(\d+)').firstMatch(raw)?.group(1);
      final exitCode = int.tryParse(parsedExit ?? '') ?? 1;
      final elapsed = DateTime.now().difference(start).inMilliseconds;
      final text = textBuf.toString().trim();
      final cleanedRaw = raw
          .replaceAll(RegExp(r'__LIFEOS_EXIT__\d+'), '')
          .trim();
      final parsed = _parseCliOutput(provider, cleanedRaw);
      final parsedText = parsed.text.trim();
      final assistantText = text.isNotEmpty
          ? text
          : (parsedText.isNotEmpty
              ? parsedText
              : _cleanCliOutputForDisplay(cleanedRaw));
      final effectiveSessionId = cliSessionId ?? parsed.sessionId;

      if (timedOut) {
        onEvent(AgentStreamEvent(type: AgentStreamEventType.timeout, text: 'Timeout after ${timeout.inMinutes}m'));
      }
      onEvent(AgentStreamEvent(type: AgentStreamEventType.done, exitCode: exitCode));

      return AgentCliExecutionResult(
        success: !timedOut && !stopped && exitCode == 0,
        assistantText: assistantText,
        rawOutput: cleanedRaw, exitCode: exitCode, durationMs: elapsed,
        errorMessage: timedOut
            ? 'Timeout after ${timeout.inMinutes} minutes.'
            : (stopped ? 'Stopped by user.' : null),
        cliSessionId: effectiveSessionId,
      );
    } catch (e, st) {
      _debugLog('[SSH-ERROR ${provider.id}] $e\n$st');
      _removeSshClient(sshKey);
      final elapsed = DateTime.now().difference(start).inMilliseconds;
      onEvent(AgentStreamEvent(type: AgentStreamEventType.error, text: e.toString()));
      return AgentCliExecutionResult(
        success: false, assistantText: '', rawOutput: '',
        exitCode: 124, durationMs: elapsed, errorMessage: e.toString(),
      );
    }
  }

  // Codex streaming state: track whether we've seen the "codex" marker
  bool _codexSeenMarker = false;
  bool _codexSeenTokensUsed = false;

  void _resetCodexStreamState() {
    _codexSeenMarker = false;
    _codexSeenTokensUsed = false;
  }

  /// Shared JSON/text line parser for CLI streaming output.
  /// Handles Claude stream-json, Codex --json JSONL, and Gemini stream-json.
  void _parseStreamLine(
    String trimmed,
    StringBuffer textBuf,
    void Function(AgentStreamEvent) onEvent,
    void Function(String) onSessionId,
    void Function(double) onCost,
  ) {
    if (trimmed.startsWith('{') && trimmed.endsWith('}')) {
      try {
        final evt = jsonDecode(trimmed);
        if (evt is! Map) return;
        final type = (evt['type'] ?? '').toString();
        final role = (evt['role'] ?? '').toString();

        // ── Claude --include-partial-messages: stream_event wrapper ──
        // Events come as {"type":"stream_event","event":{"type":"content_block_delta",...}}
        if (type == 'stream_event' && evt['event'] is Map) {
          final inner = evt['event'] as Map;
          final innerType = (inner['type'] ?? '').toString();
          if (innerType == 'content_block_delta') {
            final delta = inner['delta'];
            if (delta is Map) {
              // Text delta
              if (delta['type'] == 'text_delta' && delta['text'] is String) {
                final t = delta['text'].toString();
                textBuf.write(t);
                onEvent(AgentStreamEvent(type: AgentStreamEventType.text, text: t));
              }
              // Tool input delta (accumulate JSON)
              if (delta['type'] == 'input_json_delta' && delta['partial_json'] is String) {
                // Partial tool input — will be captured in content_block_start
              }
            }
          } else if (innerType == 'content_block_start') {
            final cb = inner['content_block'];
            if (cb is Map && cb['type'] == 'tool_use') {
              final toolName = (cb['name'] ?? 'tool').toString();
              onEvent(AgentStreamEvent(
                type: AgentStreamEventType.toolUse,
                toolName: toolName,
                toolInput: '',
              ));
            }
          }
          return;
        }

        // ── Claude format: content_block_delta (legacy --verbose without --include-partial-messages) ──
        if (type == 'content_block_delta') {
          final delta = evt['delta'];
          if (delta is Map && delta['text'] is String) {
            final t = delta['text'].toString();
            textBuf.write(t);
            onEvent(AgentStreamEvent(type: AgentStreamEventType.text, text: t));
          }
          return;
        }

        // ── Claude format: content_block_start (tool_use) ──
        if (type == 'content_block_start') {
          final cb = evt['content_block'];
          if (cb is Map && cb['type'] == 'tool_use') {
            final toolName = (cb['name'] ?? 'tool').toString();
            final input = cb['input'];
            final inputStr = input != null
                ? (input is String ? input : jsonEncode(input))
                : '';
            // Extract structured data from tool input
            String? filePath;
            String? diffOld;
            String? diffNew;
            if (input is Map) {
              filePath = (input['file_path'] ?? input['path'] ?? input['command'])?.toString();
              diffOld = input['old_string']?.toString();
              diffNew = input['new_string']?.toString();
            }
            onEvent(AgentStreamEvent(
              type: AgentStreamEventType.toolUse,
              toolName: toolName,
              toolInput: inputStr.length > 500 ? '${inputStr.substring(0, 500)}...' : inputStr,
              filePath: filePath,
              diffOld: diffOld,
              diffNew: diffNew,
            ));
          }
          return;
        }

        // ── Gemini format: {"type":"init","session_id":"..."} ──
        if (type == 'init') {
          if (evt['session_id'] is String) {
            onSessionId(evt['session_id'].toString());
            onEvent(AgentStreamEvent(type: AgentStreamEventType.sessionId, sessionId: evt['session_id'].toString()));
          }
          return;
        }

        // ── Gemini format: {"type":"message","role":"assistant","content":"...","delta":true} ──
        if (type == 'message' && role == 'assistant') {
          var content = (evt['content'] ?? '').toString().trim();
          if (content.isNotEmpty) {
            content = _cleanGeminiThinking(content);
            if (content.isNotEmpty) {
              textBuf.write(content);
              onEvent(AgentStreamEvent(type: AgentStreamEventType.text, text: content));
            }
          }
          return;
        }

        // ── Gemini/Claude format: {"type":"message","role":"user"} — skip echo ──
        if (type == 'message' && role == 'user') {
          return;
        }

        // ── tool_result ──
        if (type == 'tool_result') {
          final content = (evt['content'] ?? '').toString();
          final trunc = content.length > 500 ? '${content.substring(0, 500)}...' : content;
          onEvent(AgentStreamEvent(type: AgentStreamEventType.toolResult, text: trunc));
          return;
        }

        // ── result (final) ──
        if (type == 'result') {
          // Gemini: result text
          if (evt['result'] != null) {
            final r = evt['result'].toString().trim();
            if (r.isNotEmpty && textBuf.isEmpty) {
              textBuf.write(r);
              onEvent(AgentStreamEvent(type: AgentStreamEventType.text, text: r));
            }
          }
          // Claude: total_cost_usd
          if (evt['total_cost_usd'] is num) {
            onCost((evt['total_cost_usd'] as num).toDouble());
            onEvent(AgentStreamEvent(type: AgentStreamEventType.cost, costUsd: (evt['total_cost_usd'] as num).toDouble()));
          }
          // Gemini: stats.total_tokens (no cost field, but track tokens)
          if (evt['stats'] is Map) {
            final stats = evt['stats'] as Map;
            if (stats['duration_ms'] is num) {
              // Duration available in stats
            }
          }
          if (evt['session_id'] is String) {
            onSessionId(evt['session_id'].toString());
            onEvent(AgentStreamEvent(type: AgentStreamEventType.sessionId, sessionId: evt['session_id'].toString()));
          }
          return;
        }

        // ── Claude format: {"type":"assistant","message":{"content":[...]}} ──
        if (type == 'assistant' && evt['message'] is Map) {
          final content = (evt['message'] as Map)['content'];
          if (content is List) {
            for (final item in content) {
              if (item is! Map) continue;
              final blockType = (item['type'] ?? '').toString();
              if (blockType == 'text' && item['text'] != null) {
                textBuf.write(item['text'].toString());
                onEvent(AgentStreamEvent(type: AgentStreamEventType.text, text: item['text'].toString()));
              } else if (blockType == 'tool_use') {
                final input = item['input'];
                final inputStr = input is String ? input : (input != null ? jsonEncode(input) : '');
                final trunc = inputStr.length > 500 ? '${inputStr.substring(0, 500)}...' : inputStr;
                String? fp;
                String? dOld;
                String? dNew;
                if (input is Map) {
                  fp = (input['file_path'] ?? input['path'] ?? input['command'])?.toString();
                  dOld = input['old_string']?.toString();
                  dNew = input['new_string']?.toString();
                }
                onEvent(AgentStreamEvent(type: AgentStreamEventType.toolUse, toolName: (item['name'] ?? 'tool').toString(), toolInput: trunc, filePath: fp, diffOld: dOld, diffNew: dNew));
              } else if (blockType == 'tool_result') {
                final r = (item['content'] ?? '').toString();
                final trunc = r.length > 500 ? '${r.substring(0, 500)}...' : r;
                onEvent(AgentStreamEvent(type: AgentStreamEventType.toolResult, text: trunc));
              }
            }
          }
          if (evt['session_id'] is String) onSessionId(evt['session_id'].toString());
          return;
        }

        // ── Codex JSONL: thread.started → session ID ──
        if (type == 'thread.started') {
          if (evt['thread_id'] is String) {
            onSessionId(evt['thread_id'].toString());
            onEvent(AgentStreamEvent(type: AgentStreamEventType.sessionId, sessionId: evt['thread_id'].toString()));
          }
          return;
        }

        // ── Codex JSONL: item.started → command starting ──
        if (type == 'item.started' && evt['item'] is Map) {
          final item = evt['item'] as Map;
          if (item['type'] == 'command_execution') {
            onEvent(AgentStreamEvent(
              type: AgentStreamEventType.toolUse,
              toolName: 'bash',
              toolInput: (item['command'] ?? '').toString(),
            ));
          }
          return;
        }

        // ── Codex JSONL: item.completed → agent_message or command_execution ──
        if (type == 'item.completed' && evt['item'] is Map) {
          final item = evt['item'] as Map;
          final itemType = (item['type'] ?? '').toString();
          // Agent text response
          if (itemType == 'agent_message') {
            final t = (item['text'] ?? '').toString().trim();
            if (t.isNotEmpty) {
              textBuf.write(t);
              onEvent(AgentStreamEvent(type: AgentStreamEventType.text, text: t));
            }
          }
          // Command execution completed → show output as tool_result (TRUNCATED!)
          else if (itemType == 'command_execution') {
            final output = (item['aggregated_output'] ?? '').toString().trim();
            if (output.isNotEmpty) {
              final trunc = output.length > 500 ? '${output.substring(0, 500)}...' : output;
              onEvent(AgentStreamEvent(type: AgentStreamEventType.toolResult, text: trunc));
            }
          }
          return;
        }

        // ── Codex JSONL: turn.completed → usage stats ──
        if (type == 'turn.completed' || type == 'thread.completed') {
          if (evt['thread_id'] is String) {
            onSessionId(evt['thread_id'].toString());
          }
          final usage = evt['usage'];
          if (usage is Map && usage['input_tokens'] is num) {
            // Codex doesn't report cost but we can track tokens
          }
          return;
        }

        // ── Catch any session_id in any event ──
        if (evt['session_id'] is String) onSessionId(evt['session_id'].toString());
        if (evt['thread_id'] is String) onSessionId(evt['thread_id'].toString());
      } catch (_) {}
    } else {
      // Plain text line (Codex CLI or other non-JSON output)
      final lower = trimmed.toLowerCase();

      // ── Codex CLI state machine ──
      // Format: header... | user | <echo> | codex | <RESPONSE> | tokens used | <num> | <DUPLICATE>
      if (lower.startsWith('openai codex v')) return;
      if (lower == '--------') return;
      if (lower.startsWith('workdir:')) return;
      if (lower.startsWith('provider:')) { return; }
      if (lower.startsWith('approval:')) return;
      if (lower.startsWith('sandbox:')) return;
      if (lower.startsWith('model:') && lower.length < 60) return;
      if (lower.startsWith('reasoning effort:')) return;
      if (lower.startsWith('reasoning summaries:')) return;
      if (lower.startsWith('mcp startup')) return;
      if (lower.contains('warn codex_core')) return;
      if (lower.startsWith('session id:')) {
        final sid = trimmed.substring(11).trim();
        if (sid.isNotEmpty) onSessionId(sid);
        return;
      }

      // ── Codex-specific state machine ──
      if (lower == 'user') { _codexSeenMarker = false; return; }
      if (lower == 'codex') { _codexSeenMarker = true; return; }
      if (lower.startsWith('tokens used')) { _codexSeenTokensUsed = true; return; }
      if (RegExp(r'^[\d,\.]+$').hasMatch(trimmed)) return;
      if (_codexSeenTokensUsed) return;
      // Codex tool activity (web search, file read, etc) → show as tool_use
      if (lower.startsWith('web search:') || lower.startsWith('reading file:') ||
          lower.startsWith('writing file:') || lower.startsWith('running:') ||
          lower.startsWith('patch:') || lower.startsWith('creating:')) {
        onEvent(AgentStreamEvent(
          type: AgentStreamEventType.toolUse,
          toolName: trimmed.split(':').first.trim(),
          toolInput: trimmed.contains(':') ? trimmed.substring(trimmed.indexOf(':') + 1).trim() : '',
        ));
        return;
      }
      // Skip known noise and error dumps
      if (!_codexSeenMarker && (lower == 'openai' || lower == 'none' || lower == 'never' || lower.length < 4)) return;
      // Skip Gemini/CLI error dump lines
      if (lower.contains('gaxioserror') || lower.contains('gaxios')) return;
      if (lower.startsWith('at ') && (lower.contains('(') || lower.contains('async'))) return;
      if (lower.contains('node_modules/')) return;
      if (lower.startsWith('headers:') || lower.startsWith('request:')) return;
      if (lower.contains('status: 429') || lower.contains('too many requests')) return;
      if (lower.contains('retrying with backoff')) return;
      if (lower.startsWith('attempt') && lower.contains('failed')) return;
      if (lower.startsWith("'") && lower.endsWith("' +")) return;  // Gemini JS error continuation lines
      if (lower.contains('no stdin data received')) return;  // Claude stdin warning
      // Gemini 429/5xx error dump — aggressive filter for multi-line error objects
      if (_isGeminiErrorDumpLine(lower)) return;
      final cleaned = _cleanCliOutputForDisplay(trimmed);
      if (cleaned.isNotEmpty) {
        textBuf.write(cleaned);
        textBuf.write('\n');
        onEvent(AgentStreamEvent(type: AgentStreamEventType.text, text: '$cleaned\n'));
      }
    }
  }

  Future<AgentCliExecutionResult> executeLocal({
    required AgentCliProvider provider,
    required String model,
    required String prompt,
    required bool preferTurkish,
    String? resumeSessionId,
    String? cwd,
    Duration timeout = const Duration(minutes: 3),
  }) async {
    final start = DateTime.now();
    final spec = _buildCommand(
      provider: provider,
      model: model,
      prompt: prompt,
      preferTurkish: preferTurkish,
      resumeSessionId: resumeSessionId,
    );
    if (spec == null) {
      return const AgentCliExecutionResult(
        success: false,
        assistantText: '',
        rawOutput: '',
        exitCode: 127,
        durationMs: 0,
        errorMessage: 'Unsupported provider.',
      );
    }

    try {
      final env = Map<String, String>.from(Platform.environment);
      env['TERM'] = 'xterm-256color';
      final workDir = (cwd != null && cwd.trim().isNotEmpty)
          ? cwd.trim()
          : null;
      final timeoutSec = max(20, timeout.inSeconds);

      late ProcessResult result;
      // Force UTF-8 encoding for proper Turkish/Unicode character support
      env['PYTHONIOENCODING'] = 'utf-8';
      env['LANG'] = 'en_US.UTF-8';
      if (Platform.isWindows) {
        env['CHCP'] = '65001';
        result = await Process.run(
          spec.command,
          spec.args,
          workingDirectory: workDir,
          runInShell: true,
          environment: env,
          stdoutEncoding: utf8,
          stderrEncoding: utf8,
        ).timeout(timeout);
      } else {
        final joined = _shellJoin(spec.command, spec.args);
        final wrapped =
            'export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:\$PATH"; '
            'if command -v timeout >/dev/null 2>&1; then '
            'timeout ${timeoutSec}s $joined; '
            'else '
            '$joined; '
            'fi';
        result = await Process.run(
          'bash',
          ['-lc', wrapped],
          workingDirectory: workDir,
          runInShell: false,
          environment: env,
          stdoutEncoding: utf8,
          stderrEncoding: utf8,
        ).timeout(timeout + const Duration(seconds: 5));
      }

      final stdoutText = (result.stdout ?? '').toString();
      final stderrText = (result.stderr ?? '').toString();
      final raw = [
        if (stdoutText.trim().isNotEmpty) stdoutText.trim(),
        if (stderrText.trim().isNotEmpty) stderrText.trim(),
      ].join('\n');
      final parsed = _parseCliOutput(provider, raw);
      final elapsed = DateTime.now().difference(start).inMilliseconds;
      final authNeeded = _looksAuthNeeded(raw);
      final timedOut = result.exitCode == 124;
      final failMsg = _normalizeFailureMessage(
        provider: provider,
        output: raw,
        fallback: authNeeded
            ? _authRequiredMessage(provider)
            : (timedOut
                  ? 'CLI timeout reached.'
                  : (stderrText.trim().isEmpty
                        ? (stdoutText.trim().isEmpty
                              ? 'Command failed.'
                              : stdoutText)
                        : stderrText)),
      );
      return AgentCliExecutionResult(
        success: result.exitCode == 0,
        assistantText: parsed.text,
        rawOutput: raw,
        exitCode: result.exitCode,
        durationMs: elapsed,
        errorMessage: result.exitCode == 0 ? null : failMsg,
        cliSessionId: parsed.sessionId,
      );
    } catch (e) {
      final elapsed = DateTime.now().difference(start).inMilliseconds;
      return AgentCliExecutionResult(
        success: false,
        assistantText: '',
        rawOutput: '',
        exitCode: 124,
        durationMs: elapsed,
        errorMessage: e.toString(),
      );
    }
  }

  Future<AgentCliExecutionResult> executeSsh({
    required ConnectionProfile profile,
    required AgentCliProvider provider,
    required String model,
    required String prompt,
    required bool preferTurkish,
    String? resumeSessionId,
    String? cwd,
    Duration timeout = const Duration(minutes: 3),
  }) async {
    final start = DateTime.now();
    final spec = _buildCommand(
      provider: provider,
      model: model,
      prompt: prompt,
      preferTurkish: preferTurkish,
      resumeSessionId: resumeSessionId,
    );
    if (spec == null) {
      return const AgentCliExecutionResult(
        success: false,
        assistantText: '',
        rawOutput: '',
        exitCode: 127,
        durationMs: 0,
        errorMessage: 'Unsupported provider.',
      );
    }

    final invocation = _shellJoin(spec.command, spec.args);
    final remoteCwd = (cwd != null && cwd.trim().isNotEmpty)
        ? cwd.trim()
        : (profile.remotePath.trim().isEmpty ? '~' : profile.remotePath);
    final wrapped =
        'export PATH="\$HOME/.local/bin:\$HOME/.npm-global/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:\$PATH"; '
        'export LANG=en_US.UTF-8; '
        'export NO_COLOR=1; '
        'export FORCE_COLOR=0; '
        'cd ${_shellQuote(remoteCwd)} >/dev/null 2>&1 || exit 11; '
        '$invocation 2>&1; '
        '__lifeos_agent_exit=\$?; '
        "printf '\\n__LIFEOS_EXIT__%s\\n' \"\$__lifeos_agent_exit\"";

    try {
      final raw = await _runSshText(profile, wrapped, timeout: timeout);
      final parsedExit = RegExp(
        r'__LIFEOS_EXIT__(\d+)',
      ).firstMatch(raw)?.group(1);
      final exitCode = int.tryParse(parsedExit ?? '') ?? 1;
      final cleanedRaw = raw
          .replaceAll(RegExp(r'__LIFEOS_EXIT__\d+'), '')
          .trim();
      final parsed = _parseCliOutput(provider, cleanedRaw);
      final elapsed = DateTime.now().difference(start).inMilliseconds;
      final authNeeded = _looksAuthNeeded(cleanedRaw);
      final timedOut = exitCode == 124;
      final failMsg = _normalizeFailureMessage(
        provider: provider,
        output: cleanedRaw,
        fallback: authNeeded
            ? _authRequiredMessage(provider)
            : (timedOut
                  ? 'Remote CLI timeout reached.'
                  : (cleanedRaw.trim().isEmpty
                        ? 'Remote command failed.'
                        : cleanedRaw)),
      );
      return AgentCliExecutionResult(
        success: exitCode == 0,
        assistantText: parsed.text,
        rawOutput: cleanedRaw,
        exitCode: exitCode,
        durationMs: elapsed,
        errorMessage: exitCode == 0 ? null : failMsg,
        cliSessionId: parsed.sessionId,
      );
    } catch (e) {
      final elapsed = DateTime.now().difference(start).inMilliseconds;
      return AgentCliExecutionResult(
        success: false,
        assistantText: '',
        rawOutput: '',
        exitCode: 124,
        durationMs: elapsed,
        errorMessage: e.toString(),
      );
    }
  }

  _ParsedCliOutput _parseCliOutput(
    AgentCliProvider provider,
    String rawOutput,
  ) {
    final sessionId = _extractSessionId(rawOutput, provider);
    if (provider == AgentCliProvider.codex) {
      final text = _extractCodexAssistantText(rawOutput);
      return _ParsedCliOutput(text: text, sessionId: sessionId);
    }

    final text = _extractTextFromStreamJson(rawOutput);
    if (text.trim().isNotEmpty) {
      return _ParsedCliOutput(text: text.trim(), sessionId: sessionId);
    }
    return _ParsedCliOutput(
      text: _cleanCliOutputForDisplay(rawOutput),
      sessionId: sessionId,
    );
  }

  String _extractTextFromStreamJson(String rawOutput) {
    final textBuf = StringBuffer();
    final assistantParts = <String>[];
    final lines = rawOutput.split('\n');
    for (final rawLine in lines) {
      final line = rawLine.trim();
      if (line.isEmpty) {
        continue;
      }
      if (!line.startsWith('{') || !line.endsWith('}')) {
        continue;
      }
      try {
        final decoded = jsonDecode(line);
        if (decoded is! Map) {
          continue;
        }
        final type = (decoded['type'] ?? '').toString();
        if (type == 'content_block_delta') {
          final delta = decoded['delta'];
          if (delta is Map && delta['text'] is String) {
            textBuf.write(delta['text'].toString());
          }
          continue;
        }
        if (type == 'assistant') {
          final message = decoded['message'];
          final content = (message is Map) ? message['content'] : null;
          if (content is List) {
            for (final item in content) {
              if (item is Map &&
                  item['type']?.toString() == 'text' &&
                  item['text'] != null) {
                textBuf.write(item['text'].toString());
              }
            }
          }
          continue;
        }
        if (type == 'message') {
          final role = (decoded['role'] ?? '').toString().trim().toLowerCase();
          if (role == 'assistant') {
            var content = (decoded['content'] ?? '').toString();
            content = _cleanGeminiThinking(content);
            if (content.trim().isNotEmpty) {
              final delta = decoded['delta'] == true;
              if (delta) {
                textBuf.write(content);
              } else {
                assistantParts.add(content);
              }
            }
          }
          continue;
        }
        if (type == 'result' && decoded['result'] != null) {
          final resultText = decoded['result'].toString().trim();
          if (resultText.isNotEmpty) {
            if (textBuf.isNotEmpty) {
              textBuf.write('\n');
            }
            textBuf.write(resultText);
          }
          continue;
        }
      } catch (_) {
        // ignore malformed event line
      }
    }

    if (assistantParts.isNotEmpty) {
      for (final part in assistantParts) {
        if (textBuf.isNotEmpty) {
          textBuf.write('\n');
        }
        textBuf.write(part.trim());
      }
    }

    if (textBuf.isNotEmpty) {
      return _cleanCliOutputForDisplay(textBuf.toString());
    }

    final plainBuf = StringBuffer();
    for (final rawLine in lines) {
      final line = rawLine.trimRight();
      if (line.trim().isEmpty) continue;
      final maybeJson = line.trim();
      if (maybeJson.startsWith('{') && maybeJson.endsWith('}')) continue;
      plainBuf.writeln(line);
    }
    return _cleanCliOutputForDisplay(plainBuf.toString());
  }

  String? _extractSessionId(String rawOutput, AgentCliProvider provider) {
    final jsonMatch = RegExp(
      r'"session_id"\s*:\s*"([^"]+)"',
      caseSensitive: false,
    ).firstMatch(rawOutput);
    if (jsonMatch != null) {
      final id = jsonMatch.group(1)?.trim();
      if (id != null && id.isNotEmpty) return id;
    }

    if (provider == AgentCliProvider.codex) {
      final codexMatch = RegExp(
        r'session id:\s*([a-z0-9-]+)',
        caseSensitive: false,
      ).firstMatch(rawOutput);
      if (codexMatch != null) {
        final id = codexMatch.group(1)?.trim();
        if (id != null && id.isNotEmpty) return id;
      }
    }

    if (provider == AgentCliProvider.gemini) {
      // Gemini CLI can be resumed with "latest" when explicit ID is not emitted.
      return 'latest';
    }
    return null;
  }

  _AiCliCommand? _buildCommand({
    required AgentCliProvider provider,
    required String model,
    required String prompt,
    required bool preferTurkish,
    String? resumeSessionId,
    String approvalMode = 'auto',
  }) {
    final mode = approvalMode;
    final normalizedPrompt = prompt.trim();
    if (normalizedPrompt.isEmpty) return null;

    switch (provider) {
      case AgentCliProvider.claude:
        final effectiveModel = _effectiveModel(provider, model);
        final allowedTools = mode == 'readonly'
            ? 'Read,Glob,Grep'
            : 'Bash,Read,Edit,Write,MultiEdit';
        final args = <String>[
          '-p',
          '--output-format', 'stream-json',
          '--verbose',
          '--include-partial-messages',
          '--max-turns', (mode == 'readonly' || mode == 'confirm') ? '1' : '50',
          '--allowedTools', allowedTools,
        ];
        if (effectiveModel.trim().isNotEmpty) {
          args.addAll(['--model', effectiveModel.trim()]);
        }
        if (resumeSessionId != null && resumeSessionId.trim().isNotEmpty) {
          args.addAll(['--resume', resumeSessionId.trim()]);
        }
        final claudePrompt = preferTurkish
            ? 'Türkçe yanıt ver. $normalizedPrompt'
            : normalizedPrompt;
        args.add(claudePrompt);
        return _AiCliCommand(command: 'claude', args: args);

      case AgentCliProvider.codex:
        final effectiveModel = _effectiveModel(provider, model);
        final isResume = resumeSessionId != null && resumeSessionId.trim().isNotEmpty;
        final args = <String>['exec'];
        // Codex uses -s (sandbox) and -a (approval) flags
        // These work for both new sessions and resume
        if (mode == 'readonly') {
          args.addAll(['-s', 'read-only']);
        } else if (mode == 'confirm') {
          args.add('--full-auto');
        } else {
          // auto: full network + disk access, no approval prompts
          args.add('--dangerously-bypass-approvals-and-sandbox');
        }
        if (isResume) {
          args.addAll(['resume', resumeSessionId.trim()]);
        }
        args.add('--skip-git-repo-check');
        // Use --json for JSONL streaming output
        args.add('--json');
        if (effectiveModel.trim().isNotEmpty &&
            effectiveModel.trim() != 'auto') {
          args.addAll(['--model', effectiveModel.trim()]);
        }
        args.add(normalizedPrompt);
        return _AiCliCommand(command: 'codex', args: args);

      case AgentCliProvider.gemini:
        final effectiveModel = _effectiveModel(provider, model);
        final args = <String>['--output-format', 'stream-json'];
        // Gemini approval modes: yolo (auto), confirm, deny-all (readonly)
        // Gemini approval modes: yolo, auto_edit, default, plan
        final geminiApproval = switch (mode) {
          'auto' => 'yolo',
          'confirm' => 'auto_edit',
          'readonly' => 'plan',
          _ => 'yolo',
        };
        args.addAll(['--approval-mode', geminiApproval]);
        if (effectiveModel.trim().isNotEmpty &&
            effectiveModel.trim() != 'auto') {
          args.addAll(['--model', effectiveModel.trim()]);
        }
        if (resumeSessionId != null && resumeSessionId.trim().isNotEmpty) {
          args.addAll(['--resume', resumeSessionId.trim()]);
        }
        final promptText = preferTurkish
            ? 'Her zaman Türkçe yanıt ver. $normalizedPrompt'
            : normalizedPrompt;
        args.addAll(['-p', promptText]);
        return _AiCliCommand(command: 'gemini', args: args);
    }
  }

  String _effectiveModel(AgentCliProvider provider, String model) {
    final requested = model.trim();
    if (requested.isNotEmpty && requested != 'auto') {
      return requested;
    }
    switch (provider) {
      case AgentCliProvider.gemini:
        // "auto" bazen kapasitesi düşük preview modele düşebiliyor.
        return 'gemini-2.5-flash';
      case AgentCliProvider.claude:
      case AgentCliProvider.codex:
        return provider.defaultModel;
    }
  }

  Future<String> _runSshText(
    ConnectionProfile profile,
    String command, {
    Duration timeout = const Duration(minutes: 2),
  }) async {
    final key = '${profile.host}:${profile.port}:${profile.username}';
    try {
      final client = await _getOrCreateSshClient(profile);
      final outBytes = await client.run(command).timeout(timeout);
      return utf8.decode(outBytes, allowMalformed: true);
    } catch (_) {
      // Stale connection - remove and retry once
      _removeSshClient(key);
      try {
        final client = await _getOrCreateSshClient(profile);
        final outBytes = await client.run(command).timeout(timeout);
        return utf8.decode(outBytes, allowMalformed: true);
      } catch (e2) {
        _removeSshClient(key);
        rethrow;
      }
    }
  }

  Future<List<SSHKeyPair>> _loadIdentities(ConnectionProfile profile) async {
    final keyPath = profile.privateKeyPath?.trim();
    if (keyPath == null || keyPath.isEmpty) {
      return const [];
    }
    final keyFile = File(keyPath);
    if (!await keyFile.exists()) {
      return const [];
    }
    final pem = await keyFile.readAsString();
    try {
      return SSHKeyPair.fromPem(pem);
    } catch (_) {
      return const [];
    }
  }

  String _shellJoin(String command, List<String> args) {
    final parts = [command, ...args.map(_shellQuote)];
    return parts.join(' ');
  }

  String _shellQuote(String value) {
    final escaped = value.replaceAll("'", "'\"'\"'");
    return "'$escaped'";
  }

  String _stripControlChars(String value) {
    return value
        .replaceAll(RegExp(r'\x1B\[[0-?]*[ -/]*[@-~]'), '')
        .replaceAll(RegExp(r'[\u0000-\u0008\u000B\u000C\u000E-\u001F]'), '')
        .trim();
  }

  /// Remove Gemini thinking/reasoning tokens from output.
  /// These appear as [Thought: true]...\n\n before the actual response.
  String _cleanGeminiThinking(String value) {
    var text = value;
    // Remove [Thought: true/false] blocks - Gemini's chain-of-thought
    text = text.replaceAll(RegExp(r'\[Thought:\s*(true|false)\]'), '');
    // Remove thinking lines that are clearly internal reasoning
    final lines = text.split('\n');
    final cleaned = <String>[];
    bool inThinking = false;
    for (final line in lines) {
      final trimmed = line.trim();
      // Skip common thinking patterns
      if (trimmed.startsWith('My strategy is to') ||
          trimmed.startsWith('I\'m now focusing') ||
          trimmed.startsWith('I am now organizing') ||
          trimmed.startsWith('I\'m focusing on') ||
          trimmed.startsWith('I will first state') ||
          trimmed.startsWith('I need to') && trimmed.contains('carefully') ||
          trimmed.startsWith('Let me think') ||
          trimmed.startsWith('I\'m carefully constructing')) {
        inThinking = true;
        continue;
      }
      // If line starts with actual Turkish content, stop skipping
      if (inThinking && _lineIsTurkish(trimmed)) {
        inThinking = false;
      }
      if (!inThinking) {
        cleaned.add(line);
      }
    }
    text = cleaned.join('\n');
    // Clean literal \n\n that appear as text instead of actual newlines
    text = text.replaceAll(r'\n\n', '\n');
    text = text.replaceAll(r'\n', '\n');
    return text.trim();
  }

  /// Detect Gemini CLI error dump lines (GaxiosError, HTTP headers, config objects).
  bool _isGeminiErrorDumpLine(String lower) {
    // JSON-like error object fields
    if (lower.startsWith('"error"') || lower.startsWith('"code"') || lower.startsWith('"errors"')) return true;
    if (lower.startsWith('"domain"') || lower.startsWith('"details"') || lower.startsWith('"metadata"')) return true;
    if (lower.startsWith('"model"') && lower.contains('gemini')) return true;
    if (lower.startsWith('"message"') && lower.contains('resource')) return true;
    // JS config/request/response objects
    if (lower.startsWith('config:') || lower.startsWith('method:') || lower.startsWith('params:')) return true;
    if (lower.startsWith('response:') || lower.startsWith('signal:') || lower.startsWith('retry:')) return true;
    if (lower.startsWith('data:') && !lower.contains('data: {')) return true;
    // HTTP headers
    if (lower.contains('content-type') || lower.contains('content-length')) return true;
    if (lower.contains('user-agent') || lower.contains('x-goog-api')) return true;
    if (lower.contains('alt-svc') || lower.contains('server-timing')) return true;
    // JS function/object noise
    if (lower.contains('responsetype') || lower.contains('abortsignal')) return true;
    if (lower.contains('paramsserializer') || lower.contains('validatestatus')) return true;
    if (lower.contains('errorredactor') || lower.contains('defaulterrorredactor')) return true;
    if (lower.contains('[function:')) return true;
    if (lower.contains('[abortsignal]') || lower.contains('[object]')) return true;
    // Bare braces/brackets from dumped objects
    if (lower == '{' || lower == '}' || lower == '},') return true;
    if (lower == '[' || lower == ']' || lower == '],') return true;
    if (lower == '},' || lower == '],') return true;
    return false;
  }

  bool _lineIsTurkish(String line) {
    // Check for Turkish-specific characters
    return RegExp(r'[çğıöşüÇĞİÖŞÜ]').hasMatch(line);
  }

  String _cleanCliOutputForDisplay(String value) {
    final stripped = _stripControlChars(value);
    if (stripped.isEmpty) {
      return '';
    }
    final lines = stripped.split('\n');
    final filtered = <String>[];
    for (final raw in lines) {
      final line = raw.trimRight();
      final lower = line.trim().toLowerCase();
      if (lower.isEmpty) {
        if (filtered.isNotEmpty && filtered.last.isNotEmpty) {
          filtered.add('');
        }
        continue;
      }
      if (lower.startsWith('loaded cached credentials')) continue;
      if (lower.contains('yolo mode is enabled')) continue;
      if (lower.startsWith('reading additional input from stdin')) continue;
      if (lower.startsWith('openai codex v')) continue;
      if (lower == '--------') continue;
      if (lower.startsWith('workdir:')) continue;
      if (lower.startsWith('provider:')) continue;
      if (lower.startsWith('approval:')) continue;
      if (lower.startsWith('sandbox:')) continue;
      if (lower.startsWith('reasoning effort:')) continue;
      if (lower.startsWith('reasoning summaries:')) continue;
      if (lower.startsWith('tokens used')) continue;
      if (lower.startsWith('session id:')) continue;
      if (lower.startsWith('user') && line.trim() == 'user') continue;
      if (lower.startsWith('codex') && line.trim() == 'codex') continue;
      if (lower.contains('warn codex_core::')) continue;
      // Gemini CLI keychain / credential noise
      if (lower.contains('keychain initialization')) continue;
      if (lower.contains('libsecret')) continue;
      if (lower.contains('resource_exhausted')) continue;
      if (lower.contains('model_capacity_exhausted')) continue;
      if (lower.contains('no capacity available')) continue;
      if (lower.contains('googleapis.com')) continue;
      if (lower.contains('@type')) continue;
      if (lower.contains('ratelimitexceeded')) continue;
      // Gemini/CLI error dump noise
      if (lower.contains('gaxioserror')) continue;
      if (lower.contains('gaxios')) continue;
      if (lower.startsWith('at ') && lower.contains('(')) continue; // stack trace
      if (lower.startsWith('at async')) continue;
      if (lower.contains('node_modules/')) continue;
      if (lower.contains('headers:')) continue;
      if (lower.contains('alt-svc:')) continue;
      if (lower.contains('content-length:')) continue;
      if (lower.contains('content-type:')) continue;
      if (lower.contains('server-timing:')) continue;
      if (lower.contains('x-cloudai')) continue;
      if (lower.contains('x-content-type')) continue;
      if (lower.contains('x-frame-options')) continue;
      if (lower.contains('x-xss-protection')) continue;
      if (lower.startsWith('vary:')) continue;
      if (lower.startsWith('date:') && lower.contains('gmt')) continue;
      if (lower.startsWith('server:') && lower.length < 20) continue;
      if (lower.contains('statustext:')) continue;
      if (lower.contains('status: 429')) continue;
      if (lower.contains('too many requests')) continue;
      if (lower.startsWith('request:')) continue;
      if (lower.startsWith('error: undefined')) continue;
      if (lower.contains('[symbol(')) continue;
      if (lower.startsWith('attempt') && lower.contains('failed')) continue;
      if (lower.contains('retrying with backoff')) continue;
      if (lower.contains('filekeychain fallback')) continue;
      if (lower.contains('using filekeychain')) continue;
      if (lower.contains('cannot open shared object')) continue;
      // General CLI noise
      if (lower.startsWith('warning:') && lower.contains('keychain')) continue;
      if (lower.startsWith('debug:')) continue;
      if (lower.contains('deprecation warning')) continue;
      if (lower.contains('experimentalwarning')) continue;
      if (lower.startsWith('(node:') && lower.contains('warning')) continue;
      if (lower.startsWith('putsafely:')) continue;
      if (lower.contains('secure storage')) continue;
      if (lower.startsWith('model:') && lower.length < 60) continue;
      if (lower.startsWith('api_key:')) continue;
      // Codex echo/noise
      if (lower.startsWith('user:') || lower.startsWith('assistant:')) continue;
      if (lower.startsWith('konuşma bağlamına') || lower.startsWith('keep continuity')) continue;
      filtered.add(line);
    }
    while (filtered.isNotEmpty && filtered.first.trim().isEmpty) {
      filtered.removeAt(0);
    }
    while (filtered.isNotEmpty && filtered.last.trim().isEmpty) {
      filtered.removeLast();
    }
    return filtered.join('\n').trim();
  }

  String _extractCodexAssistantText(String rawOutput) {
    // Codex CLI output format:
    //   ...header (OpenAI Codex v..., workdir:, model:, etc.)...
    //   --------
    //   user
    //   <user message>
    //   mcp startup: ...
    //   codex
    //   <ACTUAL RESPONSE>          ← this is what we want
    //   tokens used
    //   <number>
    //   <RESPONSE REPEATED>        ← duplicate, skip this
    final lines = rawOutput.split('\n');

    // Find the "codex" marker line - response follows after it
    int codexMarkerIdx = -1;
    for (var i = lines.length - 1; i >= 0; i--) {
      if (lines[i].trim() == 'codex') {
        codexMarkerIdx = i;
        break;
      }
    }

    if (codexMarkerIdx >= 0 && codexMarkerIdx < lines.length - 1) {
      // Collect lines between "codex" and "tokens used"
      final responseBuf = StringBuffer();
      for (var i = codexMarkerIdx + 1; i < lines.length; i++) {
        final line = lines[i];
        final lower = line.trim().toLowerCase();
        if (lower == 'tokens used' || lower.startsWith('tokens used')) break;
        // Skip noise lines
        if (lower.startsWith('mcp startup')) continue;
        if (lower.startsWith('warn codex_core')) continue;
        if (lower.isEmpty && responseBuf.isEmpty) continue;
        if (responseBuf.isNotEmpty) responseBuf.write('\n');
        responseBuf.write(line);
      }
      final result = responseBuf.toString().trim();
      if (result.isNotEmpty) return result;
    }

    // Fallback: use cleaned output
    final cleaned = _cleanCliOutputForDisplay(rawOutput);
    if (cleaned.isEmpty) return '';
    return cleaned;
  }

  bool _looksAuthNeeded(String output) {
    final lower = output.toLowerCase();
    const markers = [
      'not logged in',
      'please login',
      'run',
      'auth login',
      'authentication required',
      'token',
      'credentials',
      'login required',
      'failed to authenticate',
      'authentication_error',
      'token has expired',
    ];
    if (!lower.contains('login') && !lower.contains('auth')) {
      if (!lower.contains('token') &&
          !lower.contains('credential') &&
          !lower.contains('authenticate')) {
        return false;
      }
    }
    return markers.any(lower.contains);
  }

  String _normalizeFailureMessage({
    required AgentCliProvider provider,
    required String output,
    required String fallback,
  }) {
    final lower = output.toLowerCase();
    if (_looksAuthNeeded(output)) {
      return _authRequiredMessage(provider);
    }
    if (lower.contains('resource_exhausted') ||
        lower.contains('model_capacity_exhausted') ||
        lower.contains('status 429') ||
        lower.contains('rate limit')) {
      return 'Provider rate limit reached. Please retry shortly or pick a different model.';
    }
    final cleaned = _cleanCliOutputForDisplay(output);
    if (cleaned.trim().isEmpty) {
      return fallback.trim();
    }
    final compact = cleaned.length > 900
        ? '${cleaned.substring(0, 900)}...'
        : cleaned;
    return compact.trim();
  }

  String _authRequiredMessage(AgentCliProvider provider) {
    switch (provider) {
      case AgentCliProvider.claude:
        return 'Claude CLI login required. Run: claude login';
      case AgentCliProvider.codex:
        return 'Codex CLI login required. Run: codex login';
      case AgentCliProvider.gemini:
        return 'Gemini CLI login required. Run: gemini auth login';
    }
  }
}

class _AiCliCommand {
  const _AiCliCommand({required this.command, required this.args});

  final String command;
  final List<String> args;
}

class _ParsedCliOutput {
  const _ParsedCliOutput({required this.text, required this.sessionId});

  final String text;
  final String? sessionId;
}

String _randomId() {
  final now = DateTime.now().microsecondsSinceEpoch;
  final rand = Random().nextInt(1 << 32);
  return '$now-${rand.toRadixString(16)}';
}
