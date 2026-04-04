import 'package:lifeos_sftp_drive/src/ai/agent/ai_agent_models.dart';
import 'package:lifeos_sftp_drive/src/services/ai_service.dart';

typedef AiAgentCommandExecutor =
    Future<AiAgentCommandResult> Function(String command);
typedef AiAgentScriptWriter =
    Future<AiAgentCommandResult> Function(AiAgentAction action);

class AiAgentPolicy {
  const AiAgentPolicy({
    required this.autoExecuteSafe,
    required this.dangerConfirm,
    this.maxSteps = 8,
    this.maxRuntime = const Duration(minutes: 5),
  });

  final bool autoExecuteSafe;
  final bool dangerConfirm;
  final int maxSteps;
  final Duration maxRuntime;
}

class AiAgentEngine {
  bool _stopRequested = false;

  bool get stopRequested => _stopRequested;

  void requestStop() {
    _stopRequested = true;
  }

  void resetStop() {
    _stopRequested = false;
  }

  Future<AiAgentRunResult> run({
    required AiService service,
    required AiAgentMode mode,
    required String userGoal,
    required List<AiAgentStepRecord> previousSteps,
    required AiAgentPolicy policy,
    required AiAgentCommandExecutor executeCommand,
    required AiAgentScriptWriter executeScriptWrite,
    required String Function() readTerminalOutput,
    required String shellName,
    required String osInfo,
    bool watchMode = false,
    String toolbeltProfile = 'auto',
    List<String> memoryNotes = const [],
    bool preferTurkish = false,
    AiAgentAction? pendingAction,
    bool executePendingAction = false,
  }) async {
    final steps = List<AiAgentStepRecord>.from(previousSteps);
    var pending = pendingAction;
    final startedAt = DateTime.now();
    final primaryGoal = _extractLatestUserMessageFromContext(userGoal);
    final normalizedGoal = _normalizeTextForMatch(primaryGoal);
    final isTr = preferTurkish || _looksTurkish(primaryGoal);
    final updateCheckGoal = _goalLooksUpdateCheck(normalizedGoal);
    final updateActionGoal =
        _goalLooksUpgradeAction(normalizedGoal) && !updateCheckGoal;
    final readOnlyGoal =
        mode != AiAgentMode.script && _goalLooksReadOnly(normalizedGoal);
    final packageActionGoal =
        mode != AiAgentMode.script && _goalLooksPackageAction(normalizedGoal);

    if (_stopRequested) {
      return AiAgentRunResult(
        completed: false,
        stopped: true,
        waitingUser: false,
        totalSteps: steps.length,
        steps: steps,
        pendingAction: pending,
      );
    }

    if (pending != null && executePendingAction) {
      AiAgentCommandResult? commandResult;
      if (pending.type == AiAgentActionType.runCommand) {
        var command = pending.command?.trim() ?? '';
        if (command.isNotEmpty) {
          command = _sanitizeGeneratedCommand(command);
          if (!updateCheckGoal &&
              !updateActionGoal &&
              _isReadOnlyUpdateCheckCommand(command)) {
            command = _inferReadOnlyInfoCommandForGoal(
              normalizedGoal: normalizedGoal,
              osInfo: osInfo,
            );
          }
          if (readOnlyGoal && _isPackageMutationCommand(command)) {
            command = _inferReadOnlyInfoCommandForGoal(
              normalizedGoal: normalizedGoal,
              osInfo: osInfo,
            );
          }
          if (updateCheckGoal) {
            final preferred = _preferredUpdateCheckCommandForOs(osInfo);
            if (preferred.isNotEmpty &&
                !_isReadOnlyUpdateCheckCommand(command)) {
              command = preferred;
            }
          }
          if (updateActionGoal && _isReadOnlyUpdateCheckCommand(command)) {
            final mutation = _resolveUpgradeCommandForOs(osInfo);
            if (mutation.isNotEmpty) {
              command = mutation;
            }
          }
          command = _resolveUpdateCheckCommandForOs(command, osInfo);
          if (command != (pending.command?.trim() ?? '')) {
            pending = pending.copyWith(command: command);
          }
          commandResult = await executeCommand(command);
        }
      } else if (pending.type == AiAgentActionType.writeScript) {
        commandResult = await executeScriptWrite(pending);
      }

      if (commandResult != null) {
        if (_isVisibleHandoffOutput(commandResult.output)) {
          return AiAgentRunResult(
            completed: false,
            stopped: false,
            waitingUser: true,
            totalSteps: steps.length,
            steps: steps,
            message: _extractVisibleHandoffMessage(commandResult.output, isTr),
          );
        }
        steps.add(
          AiAgentStepRecord(
            index: steps.length + 1,
            action: pending,
            commandResult: commandResult,
          ),
        );
        if (commandResult.timedOut ||
            _commandSeemsWaitingInput(commandResult.output)) {
          return AiAgentRunResult(
            completed: false,
            stopped: false,
            waitingUser: true,
            totalSteps: steps.length,
            steps: steps,
            message: isTr
                ? 'Komut etkileşim bekliyor veya hala çalışıyor olabilir. Terminalde tamamlayıp "devam" yaz.'
                : 'Command may still be running or waiting for interactive input. Finish it in terminal, then type "continue".',
          );
        }
        if (pending.type == AiAgentActionType.runCommand &&
            packageActionGoal &&
            commandResult.success &&
            _isPackageMutationCommand(pending.command ?? '')) {
          if (watchMode) {
            final watchResult = await _runWatchVerificationIfNeeded(
              steps: steps,
              osInfo: osInfo,
              executeCommand: executeCommand,
              isTr: isTr,
            );
            if (watchResult != null) {
              return watchResult;
            }
          }
          return AiAgentRunResult(
            completed: true,
            stopped: false,
            waitingUser: false,
            totalSteps: steps.length,
            steps: steps,
            message: isTr
                ? 'Paket islemi tamamlandi.'
                : 'Package operation completed.',
          );
        }

        if (pending.type == AiAgentActionType.runCommand &&
            updateCheckGoal &&
            commandResult.success &&
            _isReadOnlyUpdateCheckCommand(pending.command ?? '')) {
          return AiAgentRunResult(
            completed: true,
            stopped: false,
            waitingUser: false,
            totalSteps: steps.length,
            steps: steps,
            message: _buildUpdateCheckConversationReply(
              output: commandResult.output,
              isTr: isTr,
            ),
          );
        }
      }
      pending = null;
    } else if (pending != null) {
      return AiAgentRunResult(
        completed: false,
        stopped: false,
        waitingUser: true,
        totalSteps: steps.length,
        steps: steps,
        pendingAction: pending,
      );
    }

    while (true) {
      if (_stopRequested) {
        return AiAgentRunResult(
          completed: false,
          stopped: true,
          waitingUser: false,
          totalSteps: steps.length,
          steps: steps,
        );
      }

      if (steps.length >= policy.maxSteps) {
        return AiAgentRunResult(
          completed: false,
          stopped: false,
          waitingUser: true,
          totalSteps: steps.length,
          steps: steps,
          message: isTr
              ? 'Maksimum adim limitine ulasildi (${policy.maxSteps}). Devam etmek icin kararini bekliyorum.'
              : 'Max step limit reached (${policy.maxSteps}). Waiting for manual decision.',
        );
      }

      if (DateTime.now().difference(startedAt) > policy.maxRuntime) {
        return AiAgentRunResult(
          completed: false,
          stopped: false,
          waitingUser: true,
          totalSteps: steps.length,
          steps: steps,
          message: isTr
              ? 'Maksimum calisma suresine ulasildi. Devam etmek icin kararini bekliyorum.'
              : 'Max runtime reached. Waiting for manual decision.',
        );
      }

      final action = await service.askAgentAction(
        userGoal: userGoal,
        mode: mode,
        shellName: shellName,
        osInfo: osInfo,
        lastOutput: readTerminalOutput(),
        steps: steps,
        watchMode: watchMode,
        toolbeltProfile: toolbeltProfile,
        memoryNotes: memoryNotes,
      );

      if (action.type == AiAgentActionType.reply) {
        steps.add(AiAgentStepRecord(index: steps.length + 1, action: action));
        if (action.done) {
          return AiAgentRunResult(
            completed: true,
            stopped: false,
            waitingUser: false,
            totalSteps: steps.length,
            steps: steps,
            message: action.message,
          );
        }
        continue;
      }

      if (action.type == AiAgentActionType.askUser) {
        steps.add(AiAgentStepRecord(index: steps.length + 1, action: action));
        return AiAgentRunResult(
          completed: false,
          stopped: false,
          waitingUser: true,
          totalSteps: steps.length,
          steps: steps,
          message: action.message,
        );
      }

      if (action.type == AiAgentActionType.finish || action.done) {
        steps.add(
          AiAgentStepRecord(
            index: steps.length + 1,
            action: action.copyWith(type: AiAgentActionType.finish, done: true),
          ),
        );
        return AiAgentRunResult(
          completed: true,
          stopped: false,
          waitingUser: false,
          totalSteps: steps.length,
          steps: steps,
          message: action.message,
        );
      }

      if (action.type == AiAgentActionType.writeScript) {
        final path = action.scriptPath?.trim() ?? '';
        final content = action.scriptContent?.trim() ?? '';
        if (path.isEmpty || content.isEmpty) {
          final missing = AiAgentAction(
            type: AiAgentActionType.askUser,
            message: isTr
                ? 'Script yolu/icerigi eksik. Lutfen adimi netlestir.'
                : 'Script path/content is missing. Please refine the step.',
          );
          steps.add(
            AiAgentStepRecord(index: steps.length + 1, action: missing),
          );
          return AiAgentRunResult(
            completed: false,
            stopped: false,
            waitingUser: true,
            totalSteps: steps.length,
            steps: steps,
            message: missing.message,
          );
        }

        if (readOnlyGoal) {
          final pendingScript = action.copyWith(
            requiresConfirmation: true,
            message: action.message?.trim().isNotEmpty == true
                ? action.message
                : (isTr
                      ? 'Hedef bilgi amacli gorunuyor. Script yazmadan once onay gerekli.'
                      : 'The goal looks read-only. Approval is required before writing a script.'),
          );
          return AiAgentRunResult(
            completed: false,
            stopped: false,
            waitingUser: true,
            totalSteps: steps.length,
            steps: steps,
            pendingAction: pendingScript,
            message: pendingScript.message,
          );
        }

        final needsApproval =
            action.requiresConfirmation || !policy.autoExecuteSafe;
        if (needsApproval) {
          return AiAgentRunResult(
            completed: false,
            stopped: false,
            waitingUser: true,
            totalSteps: steps.length,
            steps: steps,
            pendingAction: action,
            message: action.message,
          );
        }

        final commandResult = await executeScriptWrite(action);
        steps.add(
          AiAgentStepRecord(
            index: steps.length + 1,
            action: action,
            commandResult: commandResult,
          ),
        );
        continue;
      }

      var command = action.command?.trim() ?? '';
      command = _sanitizeGeneratedCommand(command);
      if (command.isEmpty) {
        final missing = AiAgentAction(
          type: AiAgentActionType.askUser,
          message: isTr
              ? 'Komut bos geldi. Lutfen istegi netlestir.'
              : 'Command is empty. Please refine the instruction.',
        );
        steps.add(AiAgentStepRecord(index: steps.length + 1, action: missing));
        return AiAgentRunResult(
          completed: false,
          stopped: false,
          waitingUser: true,
          totalSteps: steps.length,
          steps: steps,
          message: missing.message,
        );
      }
      if (!updateCheckGoal &&
          !updateActionGoal &&
          _isReadOnlyUpdateCheckCommand(command)) {
        command = _inferReadOnlyInfoCommandForGoal(
          normalizedGoal: normalizedGoal,
          osInfo: osInfo,
        );
      }
      if (readOnlyGoal && _isPackageMutationCommand(command)) {
        command = _inferReadOnlyInfoCommandForGoal(
          normalizedGoal: normalizedGoal,
          osInfo: osInfo,
        );
      }
      if (updateCheckGoal) {
        final preferred = _preferredUpdateCheckCommandForOs(osInfo);
        if (preferred.isNotEmpty && !_isReadOnlyUpdateCheckCommand(command)) {
          command = preferred;
        }
      }
      if (updateActionGoal && _isReadOnlyUpdateCheckCommand(command)) {
        final mutation = _resolveUpgradeCommandForOs(osInfo);
        if (mutation.isNotEmpty) {
          command = mutation;
        }
      }
      command = _resolveUpdateCheckCommandForOs(command, osInfo);
      final actionWithCommand = action.copyWith(command: command);

      if (_isImmediateDuplicateRunCommand(steps, command)) {
        final lastStep = _lastRunCommandStep(steps);
        final lastSucceeded = lastStep?.commandResult?.success ?? false;
        if (lastSucceeded) {
          final previousOutput = lastStep?.commandResult?.output ?? '';
          return AiAgentRunResult(
            completed: true,
            stopped: false,
            waitingUser: false,
            totalSteps: steps.length,
            steps: steps,
            message: _buildNaturalDuplicateReply(
              command: command,
              output: previousOutput,
              isTr: isTr,
              updateCheckGoal: updateCheckGoal,
            ),
          );
        }
        if (updateCheckGoal &&
            (_lastRunCommandStep(steps)?.commandResult?.success ?? false)) {
          final previousOutput =
              _lastRunCommandStep(steps)?.commandResult?.output ?? '';
          return AiAgentRunResult(
            completed: true,
            stopped: false,
            waitingUser: false,
            totalSteps: steps.length,
            steps: steps,
            message: _buildUpdateCheckConversationReply(
              output: previousOutput,
              isTr: isTr,
            ),
          );
        }
        if (packageActionGoal &&
            _isPackageMutationCommand(command) &&
            _hasSuccessfulRunCommand(steps, command)) {
          return AiAgentRunResult(
            completed: true,
            stopped: false,
            waitingUser: false,
            totalSteps: steps.length,
            steps: steps,
            message: isTr
                ? 'Paket islemi tamamlandi.'
                : 'Package operation completed.',
          );
        }
        final duplicateAction = actionWithCommand.copyWith(
          requiresConfirmation: true,
          message: isTr
              ? 'Ayni komut tekrarlandi. Devam etmeden once onayla: $command'
              : 'The same command is repeating. Confirm before continuing: $command',
        );
        return AiAgentRunResult(
          completed: false,
          stopped: false,
          waitingUser: true,
          totalSteps: steps.length,
          steps: steps,
          pendingAction: duplicateAction,
          message: duplicateAction.message,
        );
      }

      if (readOnlyGoal && _isStateChangingCommand(command)) {
        final confirmAction = actionWithCommand.copyWith(
          requiresConfirmation: true,
          message: actionWithCommand.message?.trim().isNotEmpty == true
              ? actionWithCommand.message
              : (isTr
                    ? 'Hedef kontrol/bilgi odakli. Degisiklik yapan komut icin onay gerekli.'
                    : 'Goal is read-only/informational. Approval is required for a state-changing command.'),
        );
        return AiAgentRunResult(
          completed: false,
          stopped: false,
          waitingUser: true,
          totalSteps: steps.length,
          steps: steps,
          pendingAction: confirmAction,
          message: confirmAction.message,
        );
      }

      final dangerous = isDangerousCommand(command);
      final needsApproval =
          actionWithCommand.requiresConfirmation ||
          (dangerous && policy.dangerConfirm) ||
          (!dangerous && !policy.autoExecuteSafe);
      if (needsApproval) {
        return AiAgentRunResult(
          completed: false,
          stopped: false,
          waitingUser: true,
          totalSteps: steps.length,
          steps: steps,
          pendingAction: actionWithCommand,
          message: actionWithCommand.message,
        );
      }

      final commandResult = await executeCommand(command);
      steps.add(
        AiAgentStepRecord(
          index: steps.length + 1,
          action: actionWithCommand,
          commandResult: commandResult,
        ),
      );

      if (_isVisibleHandoffOutput(commandResult.output)) {
        return AiAgentRunResult(
          completed: false,
          stopped: false,
          waitingUser: true,
          totalSteps: steps.length,
          steps: steps,
          message: _extractVisibleHandoffMessage(commandResult.output, isTr),
        );
      }

      if (commandResult.timedOut ||
          _commandSeemsWaitingInput(commandResult.output)) {
        return AiAgentRunResult(
          completed: false,
          stopped: false,
          waitingUser: true,
          totalSteps: steps.length,
          steps: steps,
          message: isTr
              ? 'Komut etkileşim bekliyor veya hala çalışıyor olabilir. Terminalde tamamlayıp "devam" yaz.'
              : 'Command may still be running or waiting for interactive input. Finish it in terminal, then type "continue".',
        );
      }

      if (packageActionGoal &&
          commandResult.success &&
          _isPackageMutationCommand(command)) {
        if (watchMode) {
          final watchResult = await _runWatchVerificationIfNeeded(
            steps: steps,
            osInfo: osInfo,
            executeCommand: executeCommand,
            isTr: isTr,
          );
          if (watchResult != null) {
            return watchResult;
          }
        }
        return AiAgentRunResult(
          completed: true,
          stopped: false,
          waitingUser: false,
          totalSteps: steps.length,
          steps: steps,
          message: isTr
              ? 'Paket islemi tamamlandi.'
              : 'Package operation completed.',
        );
      }

      if (updateCheckGoal &&
          commandResult.success &&
          _isReadOnlyUpdateCheckCommand(command)) {
        return AiAgentRunResult(
          completed: true,
          stopped: false,
          waitingUser: false,
          totalSteps: steps.length,
          steps: steps,
          message: _buildUpdateCheckConversationReply(
            output: commandResult.output,
            isTr: isTr,
          ),
        );
      }
    }
  }

  String _buildUpdateCheckConversationReply({
    required String output,
    required bool isTr,
  }) {
    final normalized = _normalizeTextForMatch(output);
    final packages = _extractOutdatedPackages(output);
    final seemsUpToDate =
        normalized.contains('sisteminiz guncel') ||
        normalized.contains('system is up to date') ||
        normalized.contains('up to date') ||
        normalized.contains('guncel.');

    if (packages.isNotEmpty) {
      final shortList = packages.take(4).join(', ');
      return isTr
          ? 'Kontrol ettim; güncelleme bekleyen paketler var: $shortList. İstersen güncelleme adımını başlatayım.'
          : 'Checked. There are pending package updates: $shortList. I can start the update step if you want.';
    }

    if (seemsUpToDate) {
      return isTr
          ? 'Kontrol ettim; sistemin güncel görünüyor.'
          : 'Checked. Your system looks up to date.';
    }

    return isTr
        ? 'Kontrol ettim. Çıktıda belirgin bir güncelleme listesi görünmüyor.'
        : 'Checked. The output does not show a clear pending update list.';
  }

  String _buildNaturalDuplicateReply({
    required String command,
    required String output,
    required bool isTr,
    required bool updateCheckGoal,
  }) {
    if (updateCheckGoal) {
      return _buildUpdateCheckConversationReply(output: output, isTr: isTr);
    }

    final normalizedCommand = _normalizeCommand(command);
    if (normalizedCommand.contains('date')) {
      final time = _extractTimeFromOutput(output);
      if (time != null) {
        return isTr
            ? 'Evet, kontrol ettim. Şu an saat $time.'
            : 'Yes, I checked. The current time is $time.';
      }
    }

    final summary = _summarizeOutputForConversation(output);
    if (summary.isNotEmpty) {
      return isTr
          ? 'Evet, kontrol ettim. Sonuca göre: $summary'
          : 'Yes, I checked. Based on the output: $summary';
    }

    return isTr
        ? 'Evet, kontrol ettim. Sonuç aynı görünüyor.'
        : 'Yes, I checked. The result looks unchanged.';
  }

  String? _extractTimeFromOutput(String output) {
    final matches = RegExp(
      r'\b(\d{1,2}:\d{2}(?::\d{2})?)\b',
    ).allMatches(output).toList(growable: false);
    if (matches.isEmpty) {
      return null;
    }
    return matches.last.group(1);
  }

  String _summarizeOutputForConversation(String output) {
    for (final raw in output.split('\n').reversed) {
      final line = raw.trim();
      if (line.isEmpty) {
        continue;
      }
      final lower = line.toLowerCase();
      if (lower.startsWith('exit=') ||
          lower.startsWith('command ') ||
          lower.startsWith('komut ')) {
        continue;
      }
      if (line.length > 140) {
        return '${line.substring(0, 140)}...';
      }
      return line;
    }
    return '';
  }

  List<String> _extractOutdatedPackages(String output) {
    final result = <String>[];
    final seen = <String>{};
    for (final raw in output.split('\n')) {
      final line = raw.trim();
      if (line.isEmpty) {
        continue;
      }
      final lower = line.toLowerCase();
      if (lower.startsWith('eskimi') ||
          lower.startsWith('outdated') ||
          lower.startsWith('sisteminiz guncel') ||
          lower.startsWith('system is up to date')) {
        continue;
      }

      String? pkg;
      if (line.contains('->')) {
        pkg = line.split(RegExp(r'\s+')).first.trim();
      } else if (RegExp(r'^[a-z0-9._+-]+\s+[0-9]').hasMatch(lower)) {
        pkg = line.split(RegExp(r'\s+')).first.trim();
      }

      if (pkg == null || pkg.isEmpty) {
        continue;
      }
      final key = pkg.toLowerCase();
      if (seen.add(key)) {
        result.add(pkg);
      }
      if (result.length >= 8) {
        break;
      }
    }
    return result;
  }

  Future<AiAgentRunResult?> _runWatchVerificationIfNeeded({
    required List<AiAgentStepRecord> steps,
    required String osInfo,
    required AiAgentCommandExecutor executeCommand,
    required bool isTr,
  }) async {
    final verifyCommand = _preferredUpdateCheckCommandForOs(osInfo).trim();
    if (verifyCommand.isEmpty) {
      return null;
    }
    if (_hasSuccessfulRunCommand(steps, verifyCommand)) {
      final lastVerify = _findLastRunCommandResult(steps, verifyCommand);
      return AiAgentRunResult(
        completed: true,
        stopped: false,
        waitingUser: false,
        totalSteps: steps.length,
        steps: steps,
        message: _buildWatchVerificationReply(
          output: lastVerify?.output ?? '',
          isTr: isTr,
        ),
      );
    }

    final verifyAction = AiAgentAction(
      type: AiAgentActionType.runCommand,
      command: verifyCommand,
      message: isTr
          ? 'Değişiklik sonrası doğrulama kontrolünü çalıştırıyorum.'
          : 'Running post-change verification check.',
      reason: isTr
          ? 'Watch mode doğrulama adımı'
          : 'Watch mode verification step',
      expectedSignal: isTr
          ? 'Güncelleme çıktısı veya güncel bilgisi'
          : 'Update list or up-to-date signal',
    );
    final verifyResult = await executeCommand(verifyCommand);
    steps.add(
      AiAgentStepRecord(
        index: steps.length + 1,
        action: verifyAction,
        commandResult: verifyResult,
      ),
    );
    if (verifyResult.timedOut ||
        _commandSeemsWaitingInput(verifyResult.output)) {
      return AiAgentRunResult(
        completed: false,
        stopped: false,
        waitingUser: true,
        totalSteps: steps.length,
        steps: steps,
        message: isTr
            ? 'Doğrulama komutu etkileşim bekliyor olabilir. Terminalde tamamlayıp "devam" yaz.'
            : 'Verification command may be waiting for input. Finish it in terminal, then type "continue".',
      );
    }
    return AiAgentRunResult(
      completed: true,
      stopped: false,
      waitingUser: false,
      totalSteps: steps.length,
      steps: steps,
      message: _buildWatchVerificationReply(
        output: verifyResult.output,
        isTr: isTr,
      ),
    );
  }

  AiAgentCommandResult? _findLastRunCommandResult(
    List<AiAgentStepRecord> steps,
    String command,
  ) {
    final target = _normalizeCommand(command);
    if (target.isEmpty) {
      return null;
    }
    for (var i = steps.length - 1; i >= 0; i--) {
      final step = steps[i];
      if (step.action.type != AiAgentActionType.runCommand) {
        continue;
      }
      final current = _normalizeCommand(step.action.command ?? '');
      if (current == target) {
        return step.commandResult;
      }
    }
    return null;
  }

  String _buildWatchVerificationReply({
    required String output,
    required bool isTr,
  }) {
    final check = _buildUpdateCheckConversationReply(
      output: output,
      isTr: isTr,
    );
    return isTr
        ? '$check Doğrulama adımı tamamlandı.'
        : '$check Verification step completed.';
  }

  AiAgentStepRecord? _lastRunCommandStep(List<AiAgentStepRecord> steps) {
    for (var i = steps.length - 1; i >= 0; i--) {
      final step = steps[i];
      if (step.action.type == AiAgentActionType.runCommand) {
        return step;
      }
    }
    return null;
  }

  String _resolveUpdateCheckCommandForOs(String command, String osInfo) {
    final normalized = _normalizeCommand(command);
    if (normalized != 'checkupdates') {
      return command;
    }

    final preferred = _preferredUpdateCheckCommandForOs(osInfo);
    return preferred.isNotEmpty ? preferred : command;
  }

  String _inferReadOnlyInfoCommandForGoal({
    required String normalizedGoal,
    required String osInfo,
  }) {
    final lowerOs = osInfo.toLowerCase();
    if (_goalLooksDesktopEnvironmentInfo(normalizedGoal)) {
      if (lowerOs.contains('windows')) {
        return r'echo Desktop shell: Windows Explorer';
      }
      return r'printf "XDG_CURRENT_DESKTOP=%s\nDESKTOP_SESSION=%s\nXDG_SESSION_TYPE=%s\n" "${XDG_CURRENT_DESKTOP:-unknown}" "${DESKTOP_SESSION:-unknown}" "${XDG_SESSION_TYPE:-unknown}"';
    }
    if (_goalLooksDistroInfo(normalizedGoal)) {
      if (lowerOs.contains('windows')) {
        return r'systeminfo | findstr /B /C:"OS Name" /C:"OS Version"';
      }
      return 'cat /etc/os-release';
    }
    return _fallbackInfoCommandForOs(osInfo);
  }

  String _fallbackInfoCommandForOs(String osInfo) {
    if (osInfo.toLowerCase().contains('windows')) {
      return r'systeminfo | findstr /B /C:"OS Name" /C:"OS Version"';
    }
    return 'uname -a';
  }

  bool _goalLooksDesktopEnvironmentInfo(String normalizedGoal) {
    const hints = [
      'masaustu',
      'masa ustu',
      'desktop',
      'gnome',
      'kde',
      'xfce',
      'mate',
      'cinnamon',
      'lxqt',
      'wayland',
      'x11',
      'de oturumu',
      'desktop environment',
    ];
    return hints.any(normalizedGoal.contains);
  }

  bool _goalLooksDistroInfo(String normalizedGoal) {
    const hints = [
      'distro',
      'distribution',
      'linux dagitim',
      'hangi linux',
      'os surum',
      'isletim sistemi',
      'operating system',
      'ubuntu mu',
      'arch mi',
      'debian mi',
      'suse mi',
      'fedora mi',
    ];
    return hints.any(normalizedGoal.contains);
  }

  String _extractPackageManagerFromOsInfo(String osInfo) {
    final lower = osInfo.toLowerCase();
    final match = RegExp(r'pm=([a-z0-9_+.-]+)').firstMatch(lower);
    if (match != null) {
      return match.group(1) ?? '';
    }
    if (lower.contains('arch')) return 'pacman';
    if (lower.contains('ubuntu') || lower.contains('debian')) return 'apt';
    if (lower.contains('fedora') ||
        lower.contains('rhel') ||
        lower.contains('centos') ||
        lower.contains('rocky') ||
        lower.contains('alma')) {
      return 'dnf';
    }
    if (lower.contains('suse')) return 'zypper';
    if (lower.contains('alpine')) return 'apk';
    return '';
  }

  String _resolveUpgradeCommandForOs(String osInfo) {
    final pm = _extractPackageManagerFromOsInfo(osInfo);
    switch (pm) {
      case 'pacman':
        return 'pacman -Syu';
      case 'apt':
      case 'apt-get':
        return 'apt update && apt upgrade -y';
      case 'dnf':
        return 'dnf upgrade -y';
      case 'yum':
        return 'yum update -y';
      case 'zypper':
        return 'zypper update -y';
      case 'apk':
        return 'apk update && apk upgrade';
      default:
        if (osInfo.toLowerCase().contains('windows')) {
          return 'winget upgrade --all';
        }
        return '';
    }
  }

  String _preferredUpdateCheckCommandForOs(String osInfo) {
    final lower = osInfo.toLowerCase();
    final pm = _extractPackageManagerFromOsInfo(osInfo);
    switch (pm) {
      case 'pacman':
        if (lower.contains('manjaro')) {
          return 'pamac checkupdates -a';
        }
        return 'pacman -Qu';
      case 'apt':
      case 'apt-get':
        return 'apt list --upgradable 2>/dev/null';
      case 'dnf':
        return 'dnf check-update || true';
      case 'yum':
        return 'yum check-update || true';
      case 'zypper':
        return 'zypper lu';
      case 'apk':
        return 'apk version -l "<"';
      default:
        if (lower.contains('windows')) {
          return 'winget upgrade --all --include-unknown';
        }
        return '';
    }
  }

  bool _hasSuccessfulRunCommand(List<AiAgentStepRecord> steps, String command) {
    final target = _normalizeCommand(command);
    if (target.isEmpty) {
      return false;
    }
    for (var i = steps.length - 1; i >= 0; i--) {
      final step = steps[i];
      if (step.action.type != AiAgentActionType.runCommand) {
        continue;
      }
      final prev = _normalizeCommand(step.action.command ?? '');
      if (prev == target && (step.commandResult?.success ?? false)) {
        return true;
      }
    }
    return false;
  }

  bool _isImmediateDuplicateRunCommand(
    List<AiAgentStepRecord> steps,
    String nextCommand,
  ) {
    final normalizedNext = _normalizeCommand(nextCommand);
    if (normalizedNext.isEmpty) {
      return false;
    }
    for (var i = steps.length - 1; i >= 0; i--) {
      final step = steps[i];
      if (step.action.type != AiAgentActionType.runCommand) {
        continue;
      }
      final previous = _normalizeCommand(step.action.command ?? '');
      return previous == normalizedNext;
    }
    return false;
  }

  String _normalizeCommand(String value) =>
      value.toLowerCase().replaceAll(RegExp(r'\s+'), ' ').trim();

  String _sanitizeGeneratedCommand(String value) {
    var text = value.replaceAll('\r\n', '\n').replaceAll('\r', '\n').trim();
    if (text.isEmpty) {
      return '';
    }
    if (text.startsWith('```')) {
      text = text
          .replaceFirst(RegExp(r'^```\w*\n?'), '')
          .replaceFirst(RegExp(r'\n?```$'), '')
          .trim();
    }

    final lines = text
        .split('\n')
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty)
        .toList();
    if (lines.isEmpty) {
      return '';
    }

    String candidate = lines.first;
    for (final line in lines) {
      if (!_looksMetaLine(line)) {
        candidate = line;
        break;
      }
    }

    candidate = candidate.replaceFirst(
      RegExp(r'^(?:command|komut)\s*:\s*', caseSensitive: false),
      '',
    );
    candidate = candidate.replaceFirst(RegExp(r'^\$+\s*'), '');
    candidate = candidate.replaceFirst(RegExp(r'^[>#]+\s*'), '');
    candidate = candidate.replaceFirst(RegExp(r'^PS [^>]*>\s*'), '');
    candidate = candidate.replaceAll('`', '');
    return candidate.replaceAll(RegExp(r'\s+'), ' ').trim();
  }

  bool _looksMetaLine(String line) {
    final lower = line.toLowerCase();
    if (lower.startsWith('{') ||
        lower.startsWith('}') ||
        lower.startsWith('"action"') ||
        lower.startsWith('"command"') ||
        lower.startsWith('action:') ||
        lower.startsWith('message:') ||
        lower.startsWith('reason:')) {
      return true;
    }
    return false;
  }

  String _normalizeTextForMatch(String text) {
    return text
        .toLowerCase()
        .replaceAll('ç', 'c')
        .replaceAll('ğ', 'g')
        .replaceAll('ı', 'i')
        .replaceAll('ö', 'o')
        .replaceAll('ş', 's')
        .replaceAll('ü', 'u')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
  }

  String _extractLatestUserMessageFromContext(String userGoal) {
    final lines = userGoal.split('\n');
    for (final raw in lines.reversed) {
      final line = raw.trim();
      if (line.toLowerCase().startsWith('latest_user_message:')) {
        final value = line.substring('latest_user_message:'.length).trim();
        if (value.isNotEmpty) {
          return value;
        }
      }
    }
    return userGoal;
  }

  bool _looksTurkish(String text) {
    final lower = text.toLowerCase();
    if (RegExp(r'[çğıöşü]').hasMatch(lower)) {
      return true;
    }
    final normalized = _normalizeTextForMatch(text);
    const trHints = [
      'guncel',
      'guncelle',
      'kontrol',
      'listele',
      'bak',
      'lutfen',
      'yapar',
      'misin',
      'ac',
      'kapat',
    ];
    return trHints.any(normalized.contains);
  }

  bool _goalLooksReadOnly(String normalizedGoal) {
    if (_goalLooksUpdateCheck(normalizedGoal)) {
      return true;
    }

    const readOnlyHints = [
      'kontrol',
      'check',
      'status',
      'durum',
      'liste',
      'list',
      'show',
      'goster',
      'incele',
      'bak',
      'log',
      'cikti',
      'output',
      'bilgi',
      'info',
    ];
    const writeIntentHints = [
      'kur',
      'yukle',
      'install',
      'upgrade',
      'sil',
      'kaldir',
      'delete',
      'remove',
      'restart',
      'reboot',
      'deploy',
      'baslat',
      'durdur',
      'stop',
      'write',
      'script yaz',
    ];

    final hasReadOnly = readOnlyHints.any(normalizedGoal.contains);
    final hasWriteIntent = writeIntentHints.any(normalizedGoal.contains);
    return hasReadOnly && !hasWriteIntent;
  }

  bool _goalLooksPackageAction(String normalizedGoal) {
    if (_goalLooksUpdateCheck(normalizedGoal)) {
      return false;
    }
    const actionHints = [
      'guncelle',
      'upgrade',
      'update',
      'install',
      'kur',
      'yukle',
      'remove',
      'uninstall',
      'delete',
      'sil',
      'kaldir',
    ];
    return actionHints.any(normalizedGoal.contains);
  }

  bool _goalLooksUpgradeAction(String normalizedGoal) {
    const hints = [
      'guncelle',
      'upgrade',
      'update',
      'guncelleme yap',
      'sistemi guncelle',
      'paket guncelle',
      'full upgrade',
    ];
    return hints.any(normalizedGoal.contains);
  }

  bool _goalLooksUpdateCheck(String normalizedGoal) {
    const hints = [
      'guncelleme kontrol',
      'guncel mi',
      'guncelmis',
      'check updates',
      'update check',
      'outdated',
      'upgradable',
      'paket guncel',
      'update var mi',
      'upgrade var mi',
    ];
    return hints.any(normalizedGoal.contains);
  }

  bool _isPackageMutationCommand(String command) {
    final lower = command.toLowerCase();
    const patterns = [
      'apt install',
      'apt upgrade',
      'apt remove',
      'apt-get install',
      'apt-get upgrade',
      'apt-get remove',
      'pacman -s',
      'pacman -r',
      'pacman -syu',
      'pacman -su',
      'pamac install',
      'pamac upgrade',
      'pamac remove',
      'dnf install',
      'dnf upgrade',
      'dnf update',
      'dnf remove',
      'yum install',
      'yum update',
      'yum remove',
      'zypper install',
      'zypper update',
      'zypper remove',
      'apk add',
      'apk del',
      'apk upgrade',
      'winget install',
      'winget upgrade',
      'winget uninstall',
      'choco install',
      'choco upgrade',
      'choco uninstall',
    ];
    return patterns.any(lower.contains);
  }

  bool _isReadOnlyUpdateCheckCommand(String command) {
    final normalized = _normalizeCommand(command);
    return normalized == 'pacman -qu' ||
        normalized == 'pamac checkupdates' ||
        normalized == 'pamac checkupdates -a' ||
        normalized == 'apt list --upgradable 2>/dev/null' ||
        normalized == 'apt list --upgradable' ||
        normalized == 'dnf check-update || true' ||
        normalized == 'yum check-update || true' ||
        normalized == 'zypper lu' ||
        normalized == 'checkupdates';
  }

  bool _isStateChangingCommand(String command) {
    final lower = command.toLowerCase();
    const patterns = [
      'sudo ',
      ' apt install',
      ' apt upgrade',
      ' apt remove',
      'apt-get install',
      'apt-get upgrade',
      ' apt-get remove',
      'pacman -s',
      'pacman -r',
      'pacman -su',
      'pamac install',
      'pamac remove',
      'pamac upgrade',
      'dnf install',
      'dnf upgrade',
      'yum install',
      'yum update',
      'zypper install',
      'zypper update',
      'rm ',
      'mv ',
      'cp ',
      'chmod ',
      'chown ',
      'systemctl restart',
      'systemctl stop',
      'systemctl start',
      'service ',
      'kill ',
      'git commit',
      'git push',
      'docker rm',
      'docker stop',
      'docker restart',
      'kubectl delete',
      'kubectl apply',
    ];
    return patterns.any(lower.contains);
  }

  bool _commandSeemsWaitingInput(String output) {
    if (_isVisibleHandoffOutput(output)) {
      return true;
    }
    final lower = output.toLowerCase();
    const prompts = [
      '[sudo] password',
      'password for',
      'enter passphrase',
      'authentication is required',
      'do you want to continue',
      '(y/n)',
      '[y/n]',
      'şifre',
      'sifre',
      'press any key',
      'devam etmek istiyor musun',
    ];
    return prompts.any(lower.contains);
  }

  bool _isVisibleHandoffOutput(String output) {
    return output.contains('__LIFEOS_VISIBLE_HANDOFF__');
  }

  String _extractVisibleHandoffMessage(String output, bool isTr) {
    final clean = output.replaceAll('__LIFEOS_VISIBLE_HANDOFF__', '').trim();
    if (clean.isNotEmpty) {
      return clean;
    }
    return isTr
        ? 'Komutu görünür terminale gönderdim. Tamamlanınca "devam" yaz.'
        : 'Sent command to visible terminal. Type "continue" when it finishes.';
  }
}
