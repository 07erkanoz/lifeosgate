import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

const _aiPanelSessionSchemaVersion = 3;

class AiPanelStoredCommand {
  const AiPanelStoredCommand({
    required this.command,
    required this.output,
    required this.success,
    required this.durationMs,
    required this.createdAt,
    this.exitCode,
    this.cwd,
  });

  final String command;
  final String output;
  final int? exitCode;
  final bool success;
  final int durationMs;
  final String? cwd;
  final DateTime createdAt;

  Map<String, dynamic> toJson() => {
    'command': command,
    'output': output,
    if (exitCode != null) 'exitCode': exitCode,
    'success': success,
    'durationMs': durationMs,
    if (cwd != null && cwd!.trim().isNotEmpty) 'cwd': cwd,
    'createdAt': createdAt.toIso8601String(),
  };

  factory AiPanelStoredCommand.fromJson(Map<String, dynamic> json) {
    return AiPanelStoredCommand(
      command: (json['command'] ?? '').toString(),
      output: (json['output'] ?? '').toString(),
      exitCode: json['exitCode'] is num
          ? (json['exitCode'] as num).toInt()
          : null,
      success: json['success'] == true,
      durationMs: json['durationMs'] is num
          ? (json['durationMs'] as num).toInt()
          : 0,
      cwd: (json['cwd'] as String?)?.trim(),
      createdAt:
          DateTime.tryParse((json['createdAt'] ?? '').toString()) ??
          DateTime.now(),
    );
  }
}

class AiPanelStoredMessage {
  const AiPanelStoredMessage({
    required this.id,
    required this.role,
    required this.text,
    required this.createdAt,
    this.command,
    this.scriptPath,
    this.scriptContent,
    this.stepNumber,
    this.commandResult,
  });

  final String id;
  final String role;
  final String text;
  final String? command;
  final String? scriptPath;
  final String? scriptContent;
  final int? stepNumber;
  final AiPanelStoredCommand? commandResult;
  final DateTime createdAt;

  Map<String, dynamic> toJson() => {
    'id': id,
    'role': role,
    'text': text,
    if (command != null && command!.trim().isNotEmpty) 'command': command,
    if (scriptPath != null && scriptPath!.trim().isNotEmpty)
      'scriptPath': scriptPath,
    if (scriptContent != null && scriptContent!.trim().isNotEmpty)
      'scriptContent': scriptContent,
    if (stepNumber != null) 'stepNumber': stepNumber,
    if (commandResult != null) 'commandResult': commandResult!.toJson(),
    'createdAt': createdAt.toIso8601String(),
  };

  factory AiPanelStoredMessage.fromJson(Map<String, dynamic> json) {
    final cmdRaw = json['commandResult'];
    Map<String, dynamic>? cmdMap;
    if (cmdRaw is Map<String, dynamic>) {
      cmdMap = cmdRaw;
    } else if (cmdRaw is Map) {
      cmdMap = cmdRaw.map((key, value) => MapEntry(key.toString(), value));
    }
    return AiPanelStoredMessage(
      id: (json['id'] ?? '').toString(),
      role: (json['role'] ?? 'assistant').toString(),
      text: (json['text'] ?? '').toString(),
      command: (json['command'] as String?)?.trim(),
      scriptPath: (json['scriptPath'] as String?)?.trim(),
      scriptContent: json['scriptContent'] as String?,
      stepNumber: json['stepNumber'] is num
          ? (json['stepNumber'] as num).toInt()
          : null,
      commandResult: cmdMap == null
          ? null
          : AiPanelStoredCommand.fromJson(cmdMap),
      createdAt:
          DateTime.tryParse((json['createdAt'] ?? '').toString()) ??
          DateTime.now(),
    );
  }
}

class AiPanelStoredSession {
  const AiPanelStoredSession({
    required this.id,
    required this.scopeKey,
    required this.provider,
    required this.createdAt,
    required this.updatedAt,
    required this.messages,
    required this.recentCommands,
    required this.awaitingAnswer,
    required this.summary,
    required this.memoryNotes,
    this.goal,
    this.pendingQuestion,
    this.serverSessionId,
    this.cliSessionId,
    this.pendingAction,
  });

  final String id;
  final String scopeKey;
  final String provider;
  final DateTime createdAt;
  final DateTime updatedAt;
  final String? goal;
  final String summary;
  final List<String> memoryNotes;
  final bool awaitingAnswer;
  final String? pendingQuestion;
  final String? serverSessionId;
  final String? cliSessionId;
  final Map<String, dynamic>? pendingAction;
  final List<AiPanelStoredMessage> messages;
  final List<AiPanelStoredCommand> recentCommands;

  factory AiPanelStoredSession.initial({
    required String scopeKey,
    required String provider,
  }) {
    final now = DateTime.now();
    return AiPanelStoredSession(
      id: '${now.microsecondsSinceEpoch}-${provider.hashCode.abs()}',
      scopeKey: scopeKey,
      provider: provider,
      createdAt: now,
      updatedAt: now,
      goal: null,
      summary: '',
      memoryNotes: const [],
      awaitingAnswer: false,
      pendingQuestion: null,
      serverSessionId: null,
      cliSessionId: null,
      pendingAction: null,
      messages: const [],
      recentCommands: const [],
    );
  }

  AiPanelStoredSession copyWith({
    String? goal,
    String? summary,
    List<String>? memoryNotes,
    bool? awaitingAnswer,
    String? pendingQuestion,
    String? serverSessionId,
    String? cliSessionId,
    Map<String, dynamic>? pendingAction,
    DateTime? updatedAt,
    List<AiPanelStoredMessage>? messages,
    List<AiPanelStoredCommand>? recentCommands,
    bool clearPendingAction = false,
    bool clearPendingQuestion = false,
    bool clearGoal = false,
    bool clearServerSessionId = false,
    bool clearCliSessionId = false,
  }) {
    return AiPanelStoredSession(
      id: id,
      scopeKey: scopeKey,
      provider: provider,
      createdAt: createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      goal: clearGoal ? null : (goal ?? this.goal),
      summary: summary ?? this.summary,
      memoryNotes: memoryNotes ?? this.memoryNotes,
      awaitingAnswer: awaitingAnswer ?? this.awaitingAnswer,
      pendingQuestion: clearPendingQuestion
          ? null
          : (pendingQuestion ?? this.pendingQuestion),
      serverSessionId: clearServerSessionId
          ? null
          : (serverSessionId ?? this.serverSessionId),
      cliSessionId: clearCliSessionId
          ? null
          : (cliSessionId ?? this.cliSessionId),
      pendingAction: clearPendingAction
          ? null
          : (pendingAction ?? this.pendingAction),
      messages: messages ?? this.messages,
      recentCommands: recentCommands ?? this.recentCommands,
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'scopeKey': scopeKey,
    'provider': provider,
    'createdAt': createdAt.toIso8601String(),
    'updatedAt': updatedAt.toIso8601String(),
    if (goal != null && goal!.trim().isNotEmpty) 'goal': goal,
    'summary': summary,
    if (memoryNotes.isNotEmpty) 'memoryNotes': memoryNotes,
    'awaitingAnswer': awaitingAnswer,
    if (pendingQuestion != null && pendingQuestion!.trim().isNotEmpty)
      'pendingQuestion': pendingQuestion,
    if (serverSessionId != null && serverSessionId!.trim().isNotEmpty)
      'serverSessionId': serverSessionId,
    if (cliSessionId != null && cliSessionId!.trim().isNotEmpty)
      'cliSessionId': cliSessionId,
    if (pendingAction != null) 'pendingAction': pendingAction,
    'messages': messages.map((e) => e.toJson()).toList(),
    'recentCommands': recentCommands.map((e) => e.toJson()).toList(),
  };

  factory AiPanelStoredSession.fromJson(Map<String, dynamic> json) {
    final msgRaw = json['messages'];
    final cmdRaw = json['recentCommands'];
    final pendingActionRaw = json['pendingAction'];
    final memoryRaw = json['memoryNotes'];

    final messages = <AiPanelStoredMessage>[];
    if (msgRaw is List) {
      for (final item in msgRaw) {
        if (item is Map<String, dynamic>) {
          messages.add(AiPanelStoredMessage.fromJson(item));
        } else if (item is Map) {
          messages.add(
            AiPanelStoredMessage.fromJson(
              item.map((key, value) => MapEntry(key.toString(), value)),
            ),
          );
        }
      }
    }

    final recentCommands = <AiPanelStoredCommand>[];
    if (cmdRaw is List) {
      for (final item in cmdRaw) {
        if (item is Map<String, dynamic>) {
          recentCommands.add(AiPanelStoredCommand.fromJson(item));
        } else if (item is Map) {
          recentCommands.add(
            AiPanelStoredCommand.fromJson(
              item.map((key, value) => MapEntry(key.toString(), value)),
            ),
          );
        }
      }
    }

    final memoryNotes = <String>[];
    if (memoryRaw is List) {
      for (final item in memoryRaw) {
        final value = item.toString().trim();
        if (value.isNotEmpty && !memoryNotes.contains(value)) {
          memoryNotes.add(value);
        }
      }
    }

    Map<String, dynamic>? pendingAction;
    if (pendingActionRaw is Map<String, dynamic>) {
      pendingAction = pendingActionRaw;
    } else if (pendingActionRaw is Map) {
      pendingAction = pendingActionRaw.map(
        (key, value) => MapEntry(key.toString(), value),
      );
    }

    return AiPanelStoredSession(
      id: (json['id'] ?? '').toString().trim().isEmpty
          ? '${DateTime.now().microsecondsSinceEpoch}'
          : (json['id'] ?? '').toString().trim(),
      scopeKey: (json['scopeKey'] ?? '').toString(),
      provider: (json['provider'] ?? '').toString(),
      createdAt:
          DateTime.tryParse((json['createdAt'] ?? '').toString()) ??
          DateTime.now(),
      updatedAt:
          DateTime.tryParse((json['updatedAt'] ?? '').toString()) ??
          DateTime.now(),
      goal: (json['goal'] as String?)?.trim(),
      summary: (json['summary'] ?? '').toString(),
      memoryNotes: memoryNotes,
      awaitingAnswer: json['awaitingAnswer'] == true,
      pendingQuestion: (json['pendingQuestion'] as String?)?.trim(),
      serverSessionId: (json['serverSessionId'] as String?)?.trim(),
      cliSessionId: (json['cliSessionId'] as String?)?.trim(),
      pendingAction: pendingAction,
      messages: messages,
      recentCommands: recentCommands,
    );
  }
}

class AiPanelSessionStore {
  Future<AiPanelStoredSession?> loadScope(String scopeKey) async {
    final all = await loadAll();
    return all[scopeKey];
  }

  Future<Map<String, AiPanelStoredSession>> loadAll() async {
    try {
      final file = await _file();
      if (!await file.exists()) {
        return {};
      }
      final raw = await file.readAsString();
      final decoded = jsonDecode(raw);
      if (decoded is! Map) {
        return {};
      }
      final version = decoded['version'];
      if (version is! num) {
        return {};
      }
      final schema = version.toInt();
      if (schema < 2 || schema > _aiPanelSessionSchemaVersion) {
        return {};
      }
      final sessionsRaw = decoded['sessions'];
      if (sessionsRaw is! Map) {
        return {};
      }
      final out = <String, AiPanelStoredSession>{};
      sessionsRaw.forEach((key, value) {
        if (value is Map<String, dynamic>) {
          final session = AiPanelStoredSession.fromJson(value);
          if (session.scopeKey.trim().isNotEmpty) {
            out[session.scopeKey] = session;
          } else {
            out[key.toString()] = session;
          }
        } else if (value is Map) {
          final map = value.map((k, v) => MapEntry(k.toString(), v));
          final session = AiPanelStoredSession.fromJson(map);
          if (session.scopeKey.trim().isNotEmpty) {
            out[session.scopeKey] = session;
          } else {
            out[key.toString()] = session;
          }
        }
      });
      return out;
    } catch (_) {
      return {};
    }
  }

  Future<void> saveScope(AiPanelStoredSession session) async {
    try {
      final all = await loadAll();
      all[session.scopeKey] = _trimSession(session);
      await _saveAll(all);
    } catch (_) {}
  }

  Future<void> deleteScope(String scopeKey) async {
    try {
      final all = await loadAll();
      all.remove(scopeKey);
      await _saveAll(all);
    } catch (_) {}
  }

  Future<void> _saveAll(Map<String, AiPanelStoredSession> all) async {
    final file = await _file();
    final json = {
      'version': _aiPanelSessionSchemaVersion,
      'sessions': all.map((key, value) => MapEntry(key, value.toJson())),
    };
    await file.writeAsString(jsonEncode(json));
  }

  AiPanelStoredSession _trimSession(AiPanelStoredSession session) {
    final messages = session.messages.length > 160
        ? session.messages.sublist(session.messages.length - 160)
        : session.messages;
    final commands = session.recentCommands.length > 80
        ? session.recentCommands.sublist(session.recentCommands.length - 80)
        : session.recentCommands;
    final memoryNotes = session.memoryNotes.length > 24
        ? session.memoryNotes.sublist(session.memoryNotes.length - 24)
        : session.memoryNotes;
    return session.copyWith(
      messages: messages,
      recentCommands: commands,
      memoryNotes: memoryNotes,
      updatedAt: DateTime.now(),
    );
  }

  Future<File> _file() async {
    final dir = await getApplicationSupportDirectory();
    return File('${dir.path}${Platform.pathSeparator}ai_panel_sessions.json');
  }
}
