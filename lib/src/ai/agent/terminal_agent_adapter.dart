import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:lifeos_sftp_drive/src/ai/agent/ai_agent_models.dart';
import 'package:lifeos_sftp_drive/src/terminal/local_terminal_controller.dart';
import 'package:lifeos_sftp_drive/src/terminal/ssh_terminal_controller.dart';
import 'package:lifeos_sftp_drive/src/utils/terminal_timeline_text.dart';
import 'package:xterm/xterm.dart';

abstract class TerminalAgentAdapter {
  String get shellName;
  String get osInfo;
  bool get isRemote;

  String readRecentOutput({int maxLines = 40});

  Future<AiAgentCommandResult> executeCommand(
    String command, {
    Duration timeout = const Duration(minutes: 2),
  });

  void interrupt();
}

class SshTerminalAgentAdapter implements TerminalAgentAdapter {
  SshTerminalAgentAdapter(this.controller);

  final SshTerminalController controller;

  @override
  bool get isRemote => true;

  @override
  String get shellName =>
      '${controller.profile.username}@${controller.profile.host}';

  @override
  String get osInfo => 'Remote Linux server';

  @override
  String readRecentOutput({int maxLines = 40}) {
    final lines = controller.terminal.buffer.lines;
    if (lines.length == 0) return '';
    final start = lines.length > maxLines ? lines.length - maxLines : 0;
    final buf = StringBuffer();
    for (int i = start; i < lines.length; i++) {
      buf.writeln(lines[i].toString());
    }
    return TerminalTimelineText.sanitizeOutput(buf.toString());
  }

  @override
  Future<AiAgentCommandResult> executeCommand(
    String command, {
    Duration timeout = const Duration(minutes: 2),
  }) {
    final id = _markerId();
    final wrapped = _wrapUnixCommand(command, id: id);
    return _runWithMarkers(
      command: command,
      markerId: id,
      timeout: timeout,
      stream: controller.outputChunks,
      send: () => controller.sendCommand(wrapped, source: 'ai_agent'),
    );
  }

  @override
  void interrupt() {
    controller.terminal.keyInput(TerminalKey.keyC, ctrl: true);
  }
}

class LocalTerminalAgentAdapter implements TerminalAgentAdapter {
  LocalTerminalAgentAdapter(this.controller);

  final LocalTerminalController controller;

  @override
  bool get isRemote => false;

  @override
  String get shellName => controller.shellName;

  @override
  String get osInfo =>
      '${Platform.operatingSystem} ${Platform.operatingSystemVersion}';

  @override
  String readRecentOutput({int maxLines = 40}) {
    final lines = controller.terminal.buffer.lines;
    if (lines.length == 0) return '';
    final start = lines.length > maxLines ? lines.length - maxLines : 0;
    final buf = StringBuffer();
    for (int i = start; i < lines.length; i++) {
      buf.writeln(lines[i].toString());
    }
    return TerminalTimelineText.sanitizeOutput(buf.toString());
  }

  @override
  Future<AiAgentCommandResult> executeCommand(
    String command, {
    Duration timeout = const Duration(minutes: 2),
  }) {
    final id = _markerId();
    final lowerShell = shellName.toLowerCase();
    late final String wrapped;
    if (controller.isUnixShell) {
      wrapped = _wrapUnixCommand(command, id: id);
    } else if (lowerShell.contains('powershell') ||
        lowerShell.contains('pwsh')) {
      wrapped = _wrapPowerShellCommand(command, id: id);
    } else {
      wrapped = _wrapCmdCommand(command, id: id);
    }

    return _runWithMarkers(
      command: command,
      markerId: id,
      timeout: timeout,
      stream: controller.outputChunks,
      send: () => controller.sendCommand(wrapped, source: 'ai_agent'),
    );
  }

  @override
  void interrupt() {
    controller.sendSignal('\x03');
  }
}

String _markerId() {
  final now = DateTime.now().microsecondsSinceEpoch;
  final rnd = Random().nextInt(99999);
  return '${now}_$rnd';
}

String _wrapUnixCommand(String command, {required String id}) {
  return "printf '__LIFEOS_AGENT_BEGIN__${id}__\\n'; { $command; }; __lifeos_agent_exit=\$?; __lifeos_agent_cwd=\"\$(pwd 2>/dev/null || printf .)\"; printf '__LIFEOS_AGENT_END__${id}__EXIT=%s__CWD=%s\\n' \"\$__lifeos_agent_exit\" \"\$__lifeos_agent_cwd\"";
}

String _wrapPowerShellCommand(String command, {required String id}) {
  return 'Write-Output "__LIFEOS_AGENT_BEGIN__${id}__"; try { $command } finally { \$lifeosCode = \$LASTEXITCODE; if (\$null -eq \$lifeosCode) { \$lifeosCode = 0 }; \$lifeosPwd = (Get-Location).Path; Write-Output "__LIFEOS_AGENT_END__${id}__EXIT=\$lifeosCode__CWD=\$lifeosPwd" }';
}

String _wrapCmdCommand(String command, {required String id}) {
  return '''
echo __LIFEOS_AGENT_BEGIN__${id}__
$command
echo __LIFEOS_AGENT_END__${id}__EXIT=%errorlevel%__CWD=%cd%
''';
}

Future<AiAgentCommandResult> _runWithMarkers({
  required String command,
  required String markerId,
  required Duration timeout,
  required Stream<String> stream,
  required void Function() send,
}) async {
  final beginToken = '__LIFEOS_AGENT_BEGIN__${markerId}__';
  final endPattern = RegExp(
    '__LIFEOS_AGENT_END__${RegExp.escape(markerId)}__EXIT=([-0-9]+)__CWD=([^\\r\\n]*)',
  );
  final started = DateTime.now();
  final result = Completer<AiAgentCommandResult>();
  var rawCombined = '';
  var cleanCombined = '';

  late final StreamSubscription<String> sub;
  sub = stream.listen((chunk) {
    if (chunk.isNotEmpty) {
      rawCombined = _appendLimitedRaw(rawCombined, chunk);
      final cleanedChunk = TerminalTimelineText.sanitizeOutput(chunk);
      if (cleanedChunk.isNotEmpty) {
        cleanCombined = _appendLimitedText(cleanCombined, cleanedChunk);
      }
    }
    final endMatch = endPattern.firstMatch(rawCombined);
    if (endMatch == null) {
      return;
    }

    final beginIndex = rawCombined.lastIndexOf(beginToken, endMatch.start);
    if (beginIndex == -1) {
      return;
    }
    var outputStart = rawCombined.indexOf('\n', beginIndex);
    if (outputStart == -1 || outputStart > endMatch.start) {
      outputStart = beginIndex + beginToken.length;
    } else {
      outputStart += 1;
    }

    final rawOutput = rawCombined.substring(outputStart, endMatch.start);
    final output = _cleanupAgentArtifacts(
      TerminalTimelineText.sanitizeOutput(rawOutput),
    );
    final exitCode = int.tryParse(endMatch.group(1) ?? '');
    final cwd = (endMatch.group(2) ?? '').trim();
    final duration = DateTime.now().difference(started).inMilliseconds;

    if (!result.isCompleted) {
      result.complete(
        AiAgentCommandResult(
          command: command,
          output: output,
          success: exitCode == 0,
          durationMs: duration,
          exitCode: exitCode,
          cwd: cwd.isEmpty ? null : cwd,
        ),
      );
    }
  });

  send();
  try {
    return await result.future.timeout(
      timeout,
      onTimeout: () => AiAgentCommandResult.timeout(
        command,
        durationMs: DateTime.now().difference(started).inMilliseconds,
        output: _tail(cleanCombined, 3000),
      ),
    );
  } finally {
    await sub.cancel();
  }
}

String _appendLimitedRaw(String current, String next, {int maxChars = 300000}) {
  final merged = current + next;
  if (merged.length <= maxChars) {
    return merged;
  }
  return merged.substring(merged.length - maxChars);
}

String _appendLimitedText(
  String current,
  String next, {
  int maxChars = 200000,
}) {
  final merged = current.isEmpty ? next : '$current\n$next';
  if (merged.length <= maxChars) {
    return merged;
  }
  return merged.substring(merged.length - maxChars);
}

String _tail(String value, int maxChars) {
  if (value.length <= maxChars) {
    return value;
  }
  return value.substring(value.length - maxChars);
}

String _cleanupAgentArtifacts(String output) {
  var clean = output;
  clean = clean.replaceAll(
    RegExp(r'__LIFEOS_AGENT_BEGIN__[^\r\n]*[\r\n]?'),
    '',
  );
  clean = clean.replaceAll(RegExp(r'__LIFEOS_AGENT_END__[^\r\n]*[\r\n]?'), '');
  clean = clean.replaceAll(
    RegExp(r'printf[^\r\n]*__LIFEOS_AGENT_[^\r\n]*[\r\n]?'),
    '',
  );
  clean = clean.replaceAll(RegExp(r'__lifeos_agent_[a-z_]+'), '');
  clean = clean.replaceAll(RegExp(r'LIFEOS_AGENT'), '');
  return clean.trim();
}
