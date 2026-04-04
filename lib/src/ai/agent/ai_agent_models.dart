enum AiAgentMode { chat, explain, script, agent }

extension AiAgentModeWire on AiAgentMode {
  String get wireName {
    switch (this) {
      case AiAgentMode.chat:
        return 'chat';
      case AiAgentMode.explain:
        return 'explain';
      case AiAgentMode.script:
        return 'script';
      case AiAgentMode.agent:
        return 'agent';
    }
  }
}

enum AiAgentActionType { reply, runCommand, writeScript, askUser, finish }

class AiAgentAction {
  const AiAgentAction({
    required this.type,
    this.message,
    this.command,
    this.scriptPath,
    this.scriptContent,
    this.scriptLanguage,
    this.validationCommand,
    this.done = false,
    this.requiresConfirmation = false,
    this.reason,
    this.expectedSignal,
  });

  final AiAgentActionType type;
  final String? message;
  final String? command;
  final String? scriptPath;
  final String? scriptContent;
  final String? scriptLanguage;
  final String? validationCommand;
  final bool done;
  final bool requiresConfirmation;
  final String? reason;
  final String? expectedSignal;

  AiAgentAction copyWith({
    AiAgentActionType? type,
    String? message,
    String? command,
    String? scriptPath,
    String? scriptContent,
    String? scriptLanguage,
    String? validationCommand,
    bool? done,
    bool? requiresConfirmation,
    String? reason,
    String? expectedSignal,
  }) {
    return AiAgentAction(
      type: type ?? this.type,
      message: message ?? this.message,
      command: command ?? this.command,
      scriptPath: scriptPath ?? this.scriptPath,
      scriptContent: scriptContent ?? this.scriptContent,
      scriptLanguage: scriptLanguage ?? this.scriptLanguage,
      validationCommand: validationCommand ?? this.validationCommand,
      done: done ?? this.done,
      requiresConfirmation: requiresConfirmation ?? this.requiresConfirmation,
      reason: reason ?? this.reason,
      expectedSignal: expectedSignal ?? this.expectedSignal,
    );
  }
}

class AiAgentCommandResult {
  const AiAgentCommandResult({
    required this.command,
    required this.output,
    required this.success,
    required this.durationMs,
    this.exitCode,
    this.cwd,
    this.timedOut = false,
    this.cancelled = false,
  });

  final String command;
  final String output;
  final int? exitCode;
  final String? cwd;
  final bool success;
  final int durationMs;
  final bool timedOut;
  final bool cancelled;

  factory AiAgentCommandResult.cancelled(String command) =>
      AiAgentCommandResult(
        command: command,
        output: '',
        success: false,
        durationMs: 0,
        cancelled: true,
      );

  factory AiAgentCommandResult.timeout(
    String command, {
    required int durationMs,
    String output = '',
  }) => AiAgentCommandResult(
    command: command,
    output: output,
    success: false,
    durationMs: durationMs,
    timedOut: true,
  );
}

class AiAgentStepRecord {
  AiAgentStepRecord({
    required this.index,
    required this.action,
    this.commandResult,
    DateTime? timestamp,
  }) : timestamp = timestamp ?? DateTime.now();

  final int index;
  final AiAgentAction action;
  final AiAgentCommandResult? commandResult;
  final DateTime timestamp;
}

class AiAgentRunResult {
  const AiAgentRunResult({
    required this.completed,
    required this.stopped,
    required this.waitingUser,
    required this.totalSteps,
    required this.steps,
    this.pendingAction,
    this.message,
  });

  final bool completed;
  final bool stopped;
  final bool waitingUser;
  final int totalSteps;
  final List<AiAgentStepRecord> steps;
  final AiAgentAction? pendingAction;
  final String? message;
}
