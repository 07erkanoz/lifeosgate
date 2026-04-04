import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:lifeos_sftp_drive/src/ai/agent/ai_agent_models.dart';

// ─── Provider Definitions ────────────────────────────────────────────

enum AiProvider {
  gemini('Gemini', 'https://generativelanguage.googleapis.com'),
  claude('Claude', 'https://api.anthropic.com'),
  openai('OpenAI / Codex', 'https://api.openai.com'),
  openrouter('OpenRouter', 'https://openrouter.ai/api'),
  groq('Groq', 'https://api.groq.com/openai'),
  grok('Grok (xAI)', 'https://api.x.ai');

  const AiProvider(this.label, this.baseUrl);
  final String label;
  final String baseUrl;
}

class AiModel {
  const AiModel(this.id, this.name, {this.isFree = false});
  final String id;
  final String name;
  final bool isFree;
}

// ─── Model Lists (March 2026) ────────────────────────────────────────

const geminiModels = [
  AiModel('gemini-3-pro-preview', 'Gemini 3 Pro Preview'),
  AiModel('gemini-3-flash-preview', 'Gemini 3 Flash Preview'),
  AiModel('gemini-2.5-pro', 'Gemini 2.5 Pro'),
  AiModel('gemini-2.5-flash', 'Gemini 2.5 Flash'),
  AiModel('gemini-2.5-flash-lite', 'Gemini 2.5 Flash Lite'),
  AiModel('gemini-2.0-flash', 'Gemini 2.0 Flash'),
];

const claudeModels = [
  AiModel('claude-opus-4-6', 'Claude Opus 4.6'),
  AiModel('claude-sonnet-4-6', 'Claude Sonnet 4.6'),
  AiModel('claude-sonnet-4-5-20250929', 'Claude Sonnet 4.5'),
  AiModel('claude-haiku-4-5-20251001', 'Claude Haiku 4.5'),
];

const openaiModels = [
  AiModel('gpt-5.4', 'GPT-5.4'),
  AiModel('gpt-5.4-mini', 'GPT-5.4 Mini'),
  AiModel('gpt-5.3-codex', 'GPT-5.3 Codex'),
  AiModel('gpt-5-codex', 'GPT-5 Codex'),
  AiModel('o3', 'o3 (Reasoning)'),
  AiModel('o4-mini', 'o4-mini (Reasoning)'),
];

const openrouterModels = [
  AiModel('anthropic/claude-sonnet-4.6', 'Claude Sonnet 4.6'),
  AiModel('anthropic/claude-opus-4.6', 'Claude Opus 4.6'),
  AiModel('openai/gpt-5.4', 'GPT-5.4'),
  AiModel('google/gemini-3-pro-preview', 'Gemini 3 Pro'),
  AiModel('google/gemini-2.5-flash', 'Gemini 2.5 Flash'),
  AiModel('deepseek/deepseek-v3.2', 'DeepSeek V3.2'),
  AiModel('meta-llama/llama-3.3-70b-instruct', 'Llama 3.3 70B', isFree: true),
  AiModel('openai/gpt-oss-120b', 'GPT-OSS 120B', isFree: true),
  AiModel('mistralai/devstral-2', 'Devstral 2', isFree: true),
];

const groqModels = [
  AiModel('llama-3.3-70b-versatile', 'Llama 3.3 70B'),
  AiModel('meta-llama/llama-4-scout-17b-16e-instruct', 'Llama 4 Scout 17B'),
  AiModel('deepseek-r1-distill-llama-70b', 'DeepSeek R1 Distill 70B'),
  AiModel('qwen-qwq-32b', 'Qwen QwQ 32B'),
  AiModel('openai/gpt-oss-120b', 'GPT-OSS 120B'),
];

const grokModels = [
  AiModel('grok-4-1-fast-reasoning', 'Grok 4.1 Fast (Reasoning)'),
  AiModel('grok-4-1-fast-non-reasoning', 'Grok 4.1 Fast'),
  AiModel('grok-3-beta', 'Grok 3 Beta'),
  AiModel('grok-3-mini-beta', 'Grok 3 Mini'),
];

List<AiModel> modelsForProvider(AiProvider provider) {
  switch (provider) {
    case AiProvider.gemini:
      return geminiModels;
    case AiProvider.claude:
      return claudeModels;
    case AiProvider.openai:
      return openaiModels;
    case AiProvider.openrouter:
      return openrouterModels;
    case AiProvider.groq:
      return groqModels;
    case AiProvider.grok:
      return grokModels;
  }
}

// ─── AI History ──────────────────────────────────────────────────────

class AiHistoryEntry {
  AiHistoryEntry({
    required this.query,
    required this.command,
    this.explanation,
    this.steps,
    this.provider,
    this.model,
    required this.timestamp,
    this.executed = false,
  });
  final String query;
  final String command;
  final String? explanation;
  final List<String>? steps;
  final String? provider;
  final String? model;
  final DateTime timestamp;
  bool executed;

  Map<String, dynamic> toJson() => {
    'query': query,
    'command': command,
    if (explanation != null) 'explanation': explanation,
    if (steps != null) 'steps': steps,
    if (provider != null) 'provider': provider,
    if (model != null) 'model': model,
    'timestamp': timestamp.toIso8601String(),
    'executed': executed,
  };

  factory AiHistoryEntry.fromJson(Map<String, dynamic> json) => AiHistoryEntry(
    query: json['query'] as String,
    command: json['command'] as String,
    explanation: json['explanation'] as String?,
    steps: (json['steps'] as List?)?.map((e) => e.toString()).toList(),
    provider: json['provider'] as String?,
    model: json['model'] as String?,
    timestamp:
        DateTime.tryParse(json['timestamp'] as String? ?? '') ?? DateTime.now(),
    executed: json['executed'] as bool? ?? false,
  );
}

// ─── Smart Detection: is this a natural language query or a shell command? ───

/// Returns true if the input looks like natural language (not a command).
bool looksLikeNaturalLanguage(String input) {
  final trimmed = input.trim();
  if (trimmed.isEmpty) return false;
  // Explicit AI prefix
  if (trimmed.startsWith('#')) return true;
  // Common command starters — these are definitely shell commands
  const cmdPrefixes = [
    'ls', 'cd', 'cp', 'mv', 'rm', 'cat', 'echo', 'grep', 'find', 'mkdir',
    'chmod',
    'chown',
    'tar',
    'zip',
    'unzip',
    'wget',
    'curl',
    'ssh',
    'scp',
    'git',
    'docker',
    'sudo',
    'apt',
    'yum',
    'dnf',
    'pacman',
    'pip',
    'npm',
    'node',
    'python',
    'systemctl', 'journalctl', 'top', 'htop', 'ps', 'kill', 'df', 'du', 'free',
    'ifconfig',
    'ip',
    'ping',
    'netstat',
    'ss',
    'iptables',
    'ufw',
    'nano',
    'vim',
    'vi',
    'head',
    'tail',
    'wc',
    'sort',
    'awk',
    'sed',
    'cut',
    'tr',
    'touch',
    'ln',
    'mount',
    'umount',
    'fdisk',
    'lsblk',
    'blkid',
    'who',
    'whoami',
    'uname',
    'hostname',
    'date',
    'cal',
    'uptime',
    'reboot',
    'shutdown',
    'poweroff',
    'man',
    'which',
    'whereis',
    'export', 'source', 'alias', 'unset', 'set', 'env', 'printenv', 'xargs',
    './', '/', '~/', 'pwd', 'clear', 'exit', 'history', 'jobs', 'fg', 'bg',
    // Windows
    'dir', 'cls', 'type', 'del', 'ren', 'copy', 'move', 'md', 'rd',
    'net', 'ipconfig', 'tasklist', 'taskkill', 'reg', 'sc', 'sfc',
    'chkdsk', 'format', 'diskpart', 'powershell', 'cmd', 'wsl',
  ];
  final lower = trimmed.toLowerCase();
  final words = trimmed.split(RegExp(r'\s+'));
  final firstWord = words.first.toLowerCase();

  // Turkish/English natural language indicators — check FIRST, before command prefix check.
  // This way "ssh kurar mısın" or "docker nasıl kurulur" → AI, not shell.
  const nlWords = [
    'nasıl',
    'nedir',
    'göster',
    'listele',
    'bul',
    'sil',
    'kur',
    'yükle',
    'aç',
    'kapat',
    'başlat',
    'durdur',
    'kontrol',
    'disk',
    'bellek',
    'ağ',
    'dosya',
    'klasör',
    'mısın',
    'mıyım',
    'misin',
    'miyim',
    'eder',
    'yapar',
    'yapabilir',
    'olur',
    'istiyorum',
    'lazım',
    'gerek',
    'yap',
    'çalıştır',
    'incele',
    'bak',
    'ne',
    'how',
    'what',
    'show',
    'list',
    'find',
    'delete',
    'install',
    'open',
    'close',
    'start',
    'stop',
    'check',
    'create',
    'update',
    'help',
    'please',
    'can you',
    'want',
    'need',
    'would',
    'could',
    'should',
    'tell me',
    'explain',
  ];
  for (final w in nlWords) {
    if (lower.contains(w)) return true;
  }

  // If it starts with a known command...
  if (cmdPrefixes.contains(firstWord)) {
    // Single word → shell command (e.g. "ls", "clear", "top")
    if (words.length == 1) return false;
    // Multi-word with shell-like args → shell command (e.g. "ls -la", "cd /tmp")
    final rest = words.sublist(1).join(' ');
    if (RegExp(r'^[-/.]').hasMatch(rest)) return false;  // starts with flag or path
    if (RegExp(r'[|><;&=]').hasMatch(rest)) return false;  // has shell syntax
    // Multi-word with natural text → natural language (e.g. "clear screen", "find the bug")
    return true;
  }
  // Starts with special shell chars
  if (RegExp(r'^[./$~]').hasMatch(trimmed)) return false;
  // Contains pipes, redirects, semicolons — shell syntax
  if (RegExp(r'[|><;&]').hasMatch(trimmed)) return false;
  // Multiple words without command structure — likely natural language
  if (words.length >= 2) return true;
  // Single unknown word — probably a typo or short command
  return false;
}

// ─── Dangerous Command Detection ─────────────────────────────────────

const _dangerousPatterns = [
  'rm -rf',
  'rm -r /',
  'rmdir',
  'mkfs',
  'dd if=',
  'chmod 777',
  'chmod -R 777',
  '> /dev/sd',
  'wget',
  'curl.*| sh',
  'curl.*| bash',
  ':(){',
  'fork bomb',
  'shutdown',
  'reboot',
  'halt',
  'poweroff',
  'kill -9 1',
  'DROP TABLE',
  'DROP DATABASE',
  'DELETE FROM',
  'format c:',
  'del /f /s',
  'rd /s /q',
];

bool isDangerousCommand(String cmd) {
  final lower = cmd.toLowerCase();
  return _dangerousPatterns.any((p) => lower.contains(p));
}

// ─── AI Service ──────────────────────────────────────────────────────

class AiResponse {
  AiResponse({
    required this.command,
    this.explanation,
    this.isMultiStep = false,
    this.steps,
  });
  final String command;
  final String? explanation;
  final bool isMultiStep;
  final List<String>? steps;
}

class AiConversationTurn {
  AiConversationTurn({
    required this.reply,
    this.awaitingAnswer = false,
    this.pendingQuestion,
  });

  final String reply;
  final bool awaitingAnswer;
  final String? pendingQuestion;
}

class AiAgentPlan {
  AiAgentPlan({
    required this.summary,
    required this.steps,
    this.requiresConfirmation = true,
  });

  final String summary;
  final List<String> steps;
  final bool requiresConfirmation;
}

class AiService {
  AiService({
    required this.provider,
    required this.apiKey,
    required this.model,
  });
  final AiProvider provider;
  final String apiKey;
  final String model;

  final _client = HttpClient();

  /// Send a natural language request and get a shell command back.
  Future<AiResponse> ask({
    required String userMessage,
    String? shellName,
    String? currentDirectory,
    String? lastOutput,
    String? osInfo,
  }) async {
    final systemPrompt = _buildSystemPrompt(
      shellName: shellName,
      currentDirectory: currentDirectory,
      lastOutput: lastOutput,
      osInfo: osInfo,
    );

    final responseText = await _callApi(
      systemPrompt,
      userMessage,
      maxOutputTokens: 1024,
    );
    return _parseResponse(responseText);
  }

  Future<AiAgentAction> askAgentAction({
    required String userGoal,
    required AiAgentMode mode,
    required List<AiAgentStepRecord> steps,
    String? shellName,
    String? lastOutput,
    String? osInfo,
    bool watchMode = false,
    String toolbeltProfile = 'auto',
    List<String> memoryNotes = const [],
  }) async {
    final systemPrompt = _buildAgentSystemPrompt(
      userGoal: userGoal,
      mode: mode,
      shellName: shellName,
      lastOutput: lastOutput,
      osInfo: osInfo,
      stepSummary: _buildStepSummary(steps),
      watchMode: watchMode,
      toolbeltProfile: toolbeltProfile,
      memoryNotes: memoryNotes,
    );
    final responseText = await _callApi(
      systemPrompt,
      userGoal,
      maxOutputTokens: _agentMaxTokens(mode),
    );
    return _parseAgentAction(responseText);
  }

  Future<AiAgentPlan> askAgentPlan({
    required String userGoal,
    required AiAgentMode mode,
    String? shellName,
    String? osInfo,
    String? lastOutput,
    String toolbeltProfile = 'auto',
    bool watchMode = false,
    List<String> memoryNotes = const [],
  }) async {
    final prompt = _buildAgentPlanPrompt(
      userGoal: userGoal,
      mode: mode,
      shellName: shellName,
      osInfo: osInfo,
      lastOutput: lastOutput,
      toolbeltProfile: toolbeltProfile,
      watchMode: watchMode,
      memoryNotes: memoryNotes,
    );
    final responseText = await _callApi(prompt, userGoal, maxOutputTokens: 1024);
    return _parseAgentPlan(responseText);
  }

  Future<AiConversationTurn> askConversationTurn({
    required String userMessage,
    required String conversationContext,
    String? shellName,
    String? osInfo,
  }) async {
    final systemPrompt = _buildConversationPrompt(
      shellName: shellName,
      osInfo: osInfo,
      conversationContext: conversationContext,
    );
    final responseText = await _callApi(
      systemPrompt,
      userMessage,
      maxOutputTokens: 1024,
    );
    return _parseConversationTurn(responseText);
  }

  /// Remove ANSI escape codes and control characters from terminal output
  static String sanitizeForApi(String input) => _sanitize(input);
  static String _sanitize(String input) {
    return input
        .replaceAll(RegExp(r'\x1B\[[0-9;]*[a-zA-Z]'), '') // ANSI escape
        .replaceAll(RegExp(r'\x1B\].*?\x07'), '') // OSC sequences
        .replaceAll(
          RegExp(r'[\x00-\x08\x0B\x0C\x0E-\x1F\x7F]'),
          '',
        ) // control chars except \n \r \t
        .trim();
  }

  String _buildSystemPrompt({
    String? shellName,
    String? currentDirectory,
    String? lastOutput,
    String? osInfo,
  }) {
    final buf = StringBuffer();
    buf.writeln('You are a terminal assistant inside LifeOS Gate app.');
    buf.writeln(
      'Your job is to convert natural language requests into shell commands.',
    );
    buf.writeln('ALWAYS respond in this exact JSON format:');
    buf.writeln(
      '{"command": "the shell command", "explanation": "brief explanation in user language"}',
    );
    buf.writeln('For multi-step tasks use:');
    buf.writeln(
      '{"command": "first command", "explanation": "...", "steps": ["cmd1", "cmd2", "cmd3"]}',
    );
    buf.writeln('');
    buf.writeln('Rules:');
    buf.writeln('- Return ONLY valid JSON, no markdown, no extra text');
    buf.writeln(
      '- Use the EXACT syntax for the active shell (PowerShell/CMD use Windows commands, WSL/Bash/Zsh use Linux commands)',
    );
    buf.writeln('- Prefer safe, non-destructive commands');
    buf.writeln(
      '- If the request is unclear, return a command that shows relevant info',
    );
    buf.writeln(
      '- Respond explanation in the same language as the user message',
    );
    buf.writeln('');
    if (osInfo != null) {
      buf.writeln('OS: $osInfo');
      // If osInfo says "Remote" or "Linux" or "SSH", this is a remote Linux server
      final isRemoteLinux =
          osInfo.contains('Remote') ||
          osInfo.contains('Linux') ||
          osInfo.contains('SSH');
      if (isRemoteLinux) {
        buf.writeln(
          'IMPORTANT: This is a REMOTE LINUX SERVER connected via SSH. ALWAYS use Linux/Unix commands (ls, grep, cat, systemctl, apt/pacman/yum, etc.). NEVER use PowerShell or Windows commands.',
        );
      }
    }
    if (shellName != null) {
      buf.writeln('Shell: $shellName');
      final isUnix =
          shellName.contains('bash') ||
          shellName.contains('zsh') ||
          shellName.contains('fish') ||
          shellName.contains('wsl') ||
          shellName.contains('WSL') ||
          shellName.contains('@');
      buf.writeln(
        'Shell type: ${isUnix ? "Unix/Linux (use Linux commands: ls, grep, cat, apt, etc.)" : "Windows (use PowerShell/CMD commands: dir, Get-Process, etc.)"}',
      );
    }
    if (currentDirectory != null)
      buf.writeln('Current directory: $currentDirectory');
    if (lastOutput != null && lastOutput.isNotEmpty) {
      buf.writeln('Last terminal output (last 20 lines):');
      buf.writeln(_sanitize(lastOutput));
    }
    return buf.toString();
  }

  String _buildAgentSystemPrompt({
    required String userGoal,
    required AiAgentMode mode,
    required String stepSummary,
    String? shellName,
    String? lastOutput,
    String? osInfo,
    bool watchMode = false,
    String toolbeltProfile = 'auto',
    List<String> memoryNotes = const [],
  }) {
    final primaryIntent = _extractLatestUserMessageFromGoal(userGoal);
    final buf = StringBuffer();
    buf.writeln('You are an autonomous terminal agent inside LifeOS Gate.');
    buf.writeln(
      'Work in small, safe steps. Prefer observability commands before destructive commands.',
    );
    buf.writeln('You must return ONLY a strict JSON object with this schema:');
    buf.writeln('{');
    buf.writeln(
      '  "action": "reply|run_command|write_script|ask_user|finish",',
    );
    buf.writeln('  "message": "assistant text in user language",');
    buf.writeln(
      '  "command": "single command string if action is run_command",',
    );
    buf.writeln(
      '  "script_path": "path if action is write_script (e.g. ./deploy.sh)",',
    );
    buf.writeln(
      '  "script_content": "full script content if action is write_script",',
    );
    buf.writeln('  "script_language": "bash|sh|powershell|cmd (optional)",');
    buf.writeln(
      '  "validation_command": "optional command to validate script syntax",',
    );
    buf.writeln('  "reason": "short reason for the step",');
    buf.writeln('  "expected_signal": "what success should look like",');
    buf.writeln('  "requires_confirmation": false,');
    buf.writeln('  "done": false');
    buf.writeln('}');
    buf.writeln('');
    buf.writeln('Rules:');
    buf.writeln('- No markdown, no code fences, no extra text.');
    buf.writeln(
      '- message must always be in the same language as User goal (Turkish goal => Turkish message).',
    );
    buf.writeln('- run_command must contain one command only.');
    buf.writeln('- write_script must include script_path and script_content.');
    buf.writeln('- If user intent is unclear, use ask_user.');
    buf.writeln(
      '- For script tasks, proceed incrementally and validate before execution.',
    );
    buf.writeln('- For dangerous operations, set requires_confirmation=true.');
    buf.writeln('- If task is completed, use finish with done=true.');
    buf.writeln(
      '- In chat/explain mode, prefer one diagnostic command at a time and avoid redundant probing commands.',
    );
    buf.writeln(
      '- If the goal is check/list/status/control, stay read-only and do not run install/upgrade/remove/restart commands unless user explicitly asks.',
    );
    buf.writeln(
      '- For explicit action goals (install/upgrade/remove/start/stop), propose one best executable command first. Do not run preliminary check commands unless user asked for check first.',
    );
    buf.writeln(
      '- Do not repeat the same command if previous step already produced the needed signal.',
    );
    buf.writeln(
      '- Use provided OS, shell, and recent terminal context to choose commands. Do not run probing distro/package-manager detection commands unless user explicitly asks.',
    );
    buf.writeln(
      '- Never assume checkupdates or pacman by default; pick commands that match the known environment context.',
    );
    buf.writeln('- Never output bare checkupdates command.');
    buf.writeln(
      '- command must be a clean executable command only (no shell prompt fragments, no mixed text).',
    );
    buf.writeln(
      '- Never concatenate accidental text into command (example bad: "an -Qupacman").',
    );
    buf.writeln(
      '- Use latest_user_message as the PRIMARY intent. Use short_summary/recent_messages only as background context.',
    );
    buf.writeln(
      '- If latest_user_message is not about updates/packages, never return update-check commands (checkupdates, pacman -Qu, pamac checkupdates, apt list --upgradable, dnf/yum check-update).',
    );
    buf.writeln(
      '- Stay strictly goal-focused. If goal changed, adapt immediately.',
    );
    if (watchMode) {
      buf.writeln(
        '- Watch mode is ON: after state-changing command, verify outcome with one focused check command, then summarize naturally.',
      );
    }
    final profile = toolbeltProfile.trim().toLowerCase();
    if (profile == 'build') {
      buf.writeln(
        '- Toolbelt profile=build: prefer build/test/lint/log commands and avoid deploy/destructive operations unless explicitly requested.',
      );
    } else if (profile == 'deploy') {
      buf.writeln(
        '- Toolbelt profile=deploy: prefer release/deploy/service restart checks, but ask confirmation before risky production actions.',
      );
    } else if (profile == 'debug') {
      buf.writeln(
        '- Toolbelt profile=debug: prioritize diagnostics, logs, process/network inspection, minimal mutation.',
      );
    } else if (profile == 'ops') {
      buf.writeln(
        '- Toolbelt profile=ops: prioritize system health, services, resources, networking, and operational safety.',
      );
    }
    switch (mode) {
      case AiAgentMode.chat:
        buf.writeln(
          '- Chat mode: brief answer first; run command only when user asks to execute or confirms.',
        );
        break;
      case AiAgentMode.explain:
        buf.writeln(
          '- Explain mode: prioritize diagnosis and verification commands; do not mutate system state unless explicitly asked.',
        );
        break;
      case AiAgentMode.script:
        buf.writeln(
          '- Script mode: prefer write_script actions with valid script content and validation command.',
        );
        break;
      case AiAgentMode.agent:
        buf.writeln(
          '- Agent mode: behave like CLI operator. For actionable goals, execute concrete commands, read result, and proceed until finished.',
        );
        buf.writeln(
          '- Agent mode: use ask_user only when approval is required or information is genuinely missing.',
        );
        break;
    }
    buf.writeln('');
    buf.writeln('Mode: ${mode.wireName}');
    buf.writeln('Primary user intent: ${_sanitize(primaryIntent)}');
    buf.writeln('Context snapshot: ${_sanitize(userGoal)}');
    if (osInfo != null) {
      buf.writeln('OS: $osInfo');
      final isRemoteLinux =
          osInfo.contains('Remote') ||
          osInfo.contains('Linux') ||
          osInfo.contains('SSH');
      if (isRemoteLinux) {
        buf.writeln(
          'Environment is remote Linux over SSH. Use Linux commands only.',
        );
      }
    }
    if (shellName != null) {
      buf.writeln('Shell: $shellName');
    }
    if (stepSummary.isNotEmpty) {
      buf.writeln('Previous steps summary:');
      buf.writeln(stepSummary);
    }
    if (memoryNotes.isNotEmpty) {
      buf.writeln('User preferences memory (scope-local):');
      for (final note in memoryNotes.take(10)) {
        final clean = _sanitize(note);
        if (clean.trim().isEmpty) continue;
        buf.writeln('- $clean');
      }
    }
    if (lastOutput != null && lastOutput.trim().isNotEmpty) {
      buf.writeln('Recent terminal output:');
      buf.writeln(_sanitize(_tailChars(lastOutput, 1800)));
    }
    return buf.toString();
  }

  String _buildAgentPlanPrompt({
    required String userGoal,
    required AiAgentMode mode,
    String? shellName,
    String? osInfo,
    String? lastOutput,
    String toolbeltProfile = 'auto',
    bool watchMode = false,
    List<String> memoryNotes = const [],
  }) {
    final buf = StringBuffer();
    buf.writeln('You are a planning assistant inside LifeOS Gate.');
    buf.writeln('Prepare a compact execution plan before running commands.');
    buf.writeln('Return ONLY strict JSON in this schema:');
    buf.writeln(
      '{"summary":"short plan summary","steps":["step 1","step 2"],"requires_confirmation":true}',
    );
    buf.writeln('Rules:');
    buf.writeln('- No markdown, no code fences, no extra text.');
    buf.writeln('- Keep steps concrete and command-oriented.');
    buf.writeln('- 2 to 6 steps max.');
    buf.writeln('- Language must follow user language.');
    buf.writeln(
      '- Focus on latest user goal and avoid unrelated update checks.',
    );
    buf.writeln('Mode: ${mode.wireName}');
    buf.writeln('Toolbelt profile: ${toolbeltProfile.trim().toLowerCase()}');
    buf.writeln('Watch mode: ${watchMode ? 'on' : 'off'}');
    buf.writeln('Goal: ${_sanitize(userGoal)}');
    if (osInfo != null && osInfo.trim().isNotEmpty) {
      buf.writeln('OS: ${_sanitize(osInfo)}');
    }
    if (shellName != null && shellName.trim().isNotEmpty) {
      buf.writeln('Shell: ${_sanitize(shellName)}');
    }
    if (memoryNotes.isNotEmpty) {
      buf.writeln('User preferences memory:');
      for (final note in memoryNotes.take(8)) {
        final clean = _sanitize(note);
        if (clean.trim().isNotEmpty) {
          buf.writeln('- $clean');
        }
      }
    }
    if (lastOutput != null && lastOutput.trim().isNotEmpty) {
      buf.writeln('Recent terminal output:');
      buf.writeln(_sanitize(lastOutput));
    }
    return buf.toString();
  }

  String _extractLatestUserMessageFromGoal(String userGoal) {
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

  String _buildConversationPrompt({
    String? shellName,
    String? osInfo,
    required String conversationContext,
  }) {
    final buf = StringBuffer();
    buf.writeln('You are LifeOS Gate Agent Chat assistant.');
    buf.writeln(
      'You must keep conversation context and continue tasks without forgetting prior answers.',
    );
    buf.writeln('Return ONLY JSON with this schema:');
    buf.writeln(
      '{"reply":"assistant reply in user language","awaiting_answer":false,"pending_question":""}',
    );
    buf.writeln('Rules:');
    buf.writeln('- No markdown, no code fences, no extra text.');
    buf.writeln(
      '- reply language must follow user language (Turkish input => Turkish reply).',
    );
    buf.writeln(
      '- If the previous step asked a question and user answered it, continue from that point.',
    );
    buf.writeln(
      '- awaiting_answer=true only when you need user input to proceed.',
    );
    buf.writeln('- pending_question must be empty when awaiting_answer=false.');
    if (osInfo != null && osInfo.trim().isNotEmpty) {
      buf.writeln('OS: ${_sanitize(osInfo)}');
    }
    if (shellName != null && shellName.trim().isNotEmpty) {
      buf.writeln('Shell: ${_sanitize(shellName)}');
    }
    if (conversationContext.trim().isNotEmpty) {
      buf.writeln('Conversation context:');
      buf.writeln(_sanitize(conversationContext));
    }
    return buf.toString();
  }

  String _buildStepSummary(List<AiAgentStepRecord> steps) {
    if (steps.isEmpty) return '';
    final start = steps.length > 5 ? steps.length - 5 : 0;
    final buf = StringBuffer();
    for (int i = start; i < steps.length; i++) {
      final step = steps[i];
      final action = step.action;
      switch (action.type) {
        case AiAgentActionType.runCommand:
          final command = action.command ?? '';
          final exit = step.commandResult?.exitCode;
          final exitLabel = exit == null ? '?' : '$exit';
          final output = step.commandResult?.output ?? '';
          final compact = output.length > 160
              ? '${output.substring(0, 160)}...'
              : output;
          buf.writeln(
            '${step.index}. run_command: $command | exit=$exitLabel | output=$compact',
          );
          break;
        case AiAgentActionType.reply:
        case AiAgentActionType.askUser:
        case AiAgentActionType.finish:
          final msg = (action.message ?? '').trim();
          if (msg.isNotEmpty) {
            final compact = msg.length > 120
                ? '${msg.substring(0, 120)}...'
                : msg;
            buf.writeln('${step.index}. ${action.type.name}: $compact');
          }
          break;
        case AiAgentActionType.writeScript:
          final path = action.scriptPath ?? '';
          final lang = action.scriptLanguage ?? '';
          final exit = step.commandResult?.exitCode;
          final exitLabel = exit == null ? '?' : '$exit';
          final output = step.commandResult?.output ?? '';
          final compact = output.length > 160
              ? '${output.substring(0, 160)}...'
              : output;
          buf.writeln(
            '${step.index}. write_script: path=$path lang=$lang | exit=$exitLabel | output=$compact',
          );
          break;
      }
    }
    return _sanitize(buf.toString());
  }

  // ── Conversation history for multi-turn ──────────────────────
  final List<Map<String, String>> _conversationHistory = [];

  /// Add a message to conversation history for multi-turn support
  void addToHistory(String role, String content) {
    _conversationHistory.add({'role': role, 'content': content});
    // Keep last 20 turns to avoid token overflow
    if (_conversationHistory.length > 20) {
      _conversationHistory.removeRange(0, _conversationHistory.length - 20);
    }
  }

  /// Clear conversation history
  void clearHistory() => _conversationHistory.clear();

  Future<String> _callApi(
    String systemPrompt,
    String userMessage, {
    required int maxOutputTokens,
  }) async {
    switch (provider) {
      case AiProvider.gemini:
        return _callGemini(
          systemPrompt,
          userMessage,
          maxOutputTokens: maxOutputTokens,
        );
      case AiProvider.claude:
        return _callClaude(
          systemPrompt,
          userMessage,
          maxOutputTokens: maxOutputTokens,
        );
      case AiProvider.openai:
      case AiProvider.openrouter:
      case AiProvider.groq:
      case AiProvider.grok:
        return _callOpenAiCompatible(
          systemPrompt,
          userMessage,
          maxOutputTokens: maxOutputTokens,
        );
    }
  }

  Future<String> _callGemini(
    String systemPrompt,
    String userMessage, {
    required int maxOutputTokens,
  }) async {
    final url = Uri.parse(
      '${AiProvider.gemini.baseUrl}/v1beta/models/$model:generateContent?key=$apiKey',
    );
    final cleanSystem = _sanitize(systemPrompt);
    final cleanUser = _sanitize(userMessage);

    // Build multi-turn contents from history
    final contents = <Map<String, dynamic>>[];
    for (final turn in _conversationHistory) {
      final geminiRole = turn['role'] == 'assistant' ? 'model' : 'user';
      contents.add({
        'role': geminiRole,
        'parts': [{'text': turn['content'] ?? ''}],
      });
    }
    // Add current user message
    contents.add({
      'role': 'user',
      'parts': [{'text': cleanUser}],
    });

    final body = jsonEncode({
      // Use proper systemInstruction field instead of hack
      'systemInstruction': {
        'parts': [{'text': cleanSystem}],
      },
      'contents': contents,
      'generationConfig': {
        'temperature': 0.3,
        'maxOutputTokens': maxOutputTokens,
      },
    });
    return _doPost(url, body, {
      'Content-Type': 'application/json',
    }, _extractGemini);
  }

  Future<String> _callClaude(
    String systemPrompt,
    String userMessage, {
    required int maxOutputTokens,
  }) async {
    final url = Uri.parse('${AiProvider.claude.baseUrl}/v1/messages');

    // Build multi-turn messages array
    final messages = <Map<String, String>>[];
    for (final turn in _conversationHistory) {
      messages.add({
        'role': turn['role'] ?? 'user',
        'content': turn['content'] ?? '',
      });
    }
    messages.add({'role': 'user', 'content': userMessage});

    final body = jsonEncode({
      'model': model,
      'max_tokens': maxOutputTokens,
      'system': systemPrompt,
      'messages': messages,
    });
    return _doPost(url, body, {
      'Content-Type': 'application/json',
      'x-api-key': apiKey,
      'anthropic-version': '2023-06-01',
    }, _extractClaude);
  }

  Future<String> _callOpenAiCompatible(
    String systemPrompt,
    String userMessage, {
    required int maxOutputTokens,
  }) async {
    String baseUrl;
    switch (provider) {
      case AiProvider.openai:
        baseUrl = AiProvider.openai.baseUrl;
        break;
      case AiProvider.openrouter:
        baseUrl = AiProvider.openrouter.baseUrl;
        break;
      case AiProvider.groq:
        baseUrl = AiProvider.groq.baseUrl;
        break;
      case AiProvider.grok:
        baseUrl = AiProvider.grok.baseUrl;
        break;
      default:
        baseUrl = AiProvider.openai.baseUrl;
    }
    final url = Uri.parse('$baseUrl/v1/chat/completions');

    // Build multi-turn messages with system prompt
    final messages = <Map<String, String>>[
      {'role': 'system', 'content': systemPrompt},
    ];
    for (final turn in _conversationHistory) {
      messages.add({
        'role': turn['role'] ?? 'user',
        'content': turn['content'] ?? '',
      });
    }
    messages.add({'role': 'user', 'content': userMessage});

    final body = jsonEncode({
      'model': model,
      'max_tokens': maxOutputTokens,
      'temperature': 0.3,
      'messages': messages,
    });
    final headers = <String, String>{
      'Content-Type': 'application/json',
      'Authorization': 'Bearer $apiKey',
    };
    if (provider == AiProvider.openrouter) {
      headers['HTTP-Referer'] = 'https://lifeos.com.tr';
      headers['X-Title'] = 'LifeOS Gate';
    }
    return _doPost(url, body, headers, _extractOpenAi);
  }

  Future<String> _doPost(
    Uri url,
    String body,
    Map<String, String> headers,
    String Function(Map<String, dynamic>) extractor,
  ) async {
    final bodyBytes = utf8.encode(body);
    final request = await _client
        .postUrl(url)
        .timeout(const Duration(seconds: 15));
    request.headers.contentType = ContentType(
      'application',
      'json',
      charset: 'utf-8',
    );
    request.headers.contentLength = bodyBytes.length;
    for (final entry in headers.entries) {
      if (entry.key.toLowerCase() == 'content-type') continue;
      request.headers.set(entry.key, entry.value);
    }
    request.add(bodyBytes);
    final response = await request.close().timeout(const Duration(seconds: 60));
    final responseBody = await response
        .transform(utf8.decoder)
        .join()
        .timeout(const Duration(seconds: 60));
    if (response.statusCode != 200) {
      throw Exception(_friendlyApiError(response.statusCode, responseBody));
    }
    final json = jsonDecode(responseBody) as Map<String, dynamic>;
    return extractor(json);
  }

  /// User-friendly error messages (Turkish/English)
  static String _friendlyApiError(int statusCode, String body) {
    final lower = body.toLowerCase();
    if (statusCode == 401 || lower.contains('invalid_api_key') || lower.contains('unauthorized')) {
      return 'API anahtari gecersiz veya suresi dolmus. Ayarlar > AI Asistan bolumunden kontrol edin.\n'
             'API key is invalid or expired. Check Settings > AI Assistant.';
    }
    if (statusCode == 429 || lower.contains('rate_limit') || lower.contains('resource_exhausted')) {
      return 'Istek limiti asildi. Birkac saniye bekleyip tekrar deneyin veya farkli model secin.\n'
             'Rate limit exceeded. Wait a few seconds or try a different model.';
    }
    if (statusCode == 403) {
      return 'Erisim reddedildi. API anahtarinizin bu modele erisim izni olmadigindan emin olun.\n'
             'Access denied. Ensure your API key has permission for this model.';
    }
    if (statusCode == 404) {
      return 'Model bulunamadi. Secili model gecersiz olabilir, Ayarlar\'dan kontrol edin.\n'
             'Model not found. The selected model may be invalid.';
    }
    if (statusCode >= 500) {
      return 'Sunucu hatasi ($statusCode). Provider gecici olarak kullanilamiyor olabilir.\n'
             'Server error ($statusCode). The provider may be temporarily unavailable.';
    }
    // Truncate long error bodies
    final truncated = body.length > 300 ? '${body.substring(0, 300)}...' : body;
    return 'API hatasi $statusCode: $truncated';
  }

  static String _extractGemini(Map<String, dynamic> json) {
    final candidates = json['candidates'] as List?;
    if (candidates == null || candidates.isEmpty) {
      // Check for blocked content
      final blockReason = json['promptFeedback']?['blockReason'];
      if (blockReason != null) {
        throw Exception('Gemini icerik filtresine takildi: $blockReason\nContent blocked by Gemini safety filter.');
      }
      throw Exception('Gemini yanit dondurmedi.\nNo response from Gemini.');
    }
    final content = candidates[0]['content'] as Map<String, dynamic>;
    final parts = content['parts'] as List;
    return parts[0]['text'] as String;
  }

  static String _extractClaude(Map<String, dynamic> json) {
    final content = json['content'] as List?;
    if (content == null || content.isEmpty) {
      final stopReason = json['stop_reason'];
      throw Exception('Claude yanit dondurmedi (stop: $stopReason).\nNo response from Claude.');
    }
    return content[0]['text'] as String;
  }

  static String _extractOpenAi(Map<String, dynamic> json) {
    final choices = json['choices'] as List?;
    if (choices == null || choices.isEmpty) {
      throw Exception('API yanit dondurmedi.\nNo response from API.');
    }
    final message = choices[0]['message'] as Map<String, dynamic>;
    return message['content'] as String;
  }

  AiResponse _parseResponse(String raw) {
    // Strip markdown code fences if present
    var text = raw.trim();
    if (text.startsWith('```')) {
      text = text
          .replaceFirst(RegExp(r'^```\w*\n?'), '')
          .replaceFirst(RegExp(r'\n?```$'), '')
          .trim();
    }

    try {
      final json = jsonDecode(text) as Map<String, dynamic>;
      final command = json['command'] as String? ?? '';
      final explanation = json['explanation'] as String?;
      final steps = (json['steps'] as List?)?.map((e) => e.toString()).toList();
      return AiResponse(
        command: command,
        explanation: explanation,
        isMultiStep: steps != null && steps.isNotEmpty,
        steps: steps,
      );
    } catch (_) {
      // If JSON parsing fails, treat entire response as a command
      return AiResponse(command: text, explanation: null);
    }
  }

  AiAgentAction _parseAgentAction(String raw) {
    final text = _stripMarkdownFence(raw.trim());
    final json = _tryParseJsonObject(text);
    if (json == null) {
      final loose = _parseLooseAgentAction(text);
      if (loose != null) {
        return loose;
      }
      return AiAgentAction(type: AiAgentActionType.reply, message: text);
    }

    final actionName = (json['action'] ?? json['type'] ?? '')
        .toString()
        .trim()
        .toLowerCase();
    final message =
        (json['message'] ??
                json['reply'] ??
                json['explanation'] ??
                json['reason'])
            ?.toString();
    final command = json['command']?.toString();
    final scriptPath =
        (json['script_path'] ?? json['scriptPath'] ?? json['path'])?.toString();
    final scriptContent =
        (json['script_content'] ??
                json['scriptContent'] ??
                json['content'] ??
                json['script'])
            ?.toString();
    final scriptLanguage =
        (json['script_language'] ?? json['scriptLanguage'] ?? json['language'])
            ?.toString();
    final validationCommand =
        (json['validation_command'] ?? json['validationCommand'])?.toString();
    final done = _parseBool(json['done']);
    final requiresConfirmation =
        _parseBool(json['requires_confirmation']) ||
        _parseBool(json['requiresConfirmation']);
    final reason = json['reason']?.toString();
    final expectedSignal = (json['expected_signal'] ?? json['expectedSignal'])
        ?.toString();

    final actionType = switch (actionName) {
      'run_command' ||
      'runcommand' ||
      'command' => AiAgentActionType.runCommand,
      'write_script' ||
      'writescript' ||
      'script' => AiAgentActionType.writeScript,
      'ask_user' || 'askuser' || 'question' => AiAgentActionType.askUser,
      'finish' ||
      'done' ||
      'complete' ||
      'completed' => AiAgentActionType.finish,
      _ => AiAgentActionType.reply,
    };

    if (actionType == AiAgentActionType.runCommand &&
        (command == null || command.trim().isEmpty)) {
      return AiAgentAction(
        type: AiAgentActionType.askUser,
        message: message ?? 'Command is empty. Please clarify the target.',
      );
    }
    if (actionType == AiAgentActionType.writeScript &&
        ((scriptPath == null || scriptPath.trim().isEmpty) ||
            (scriptContent == null || scriptContent.trim().isEmpty))) {
      return AiAgentAction(
        type: AiAgentActionType.askUser,
        message:
            message ??
            'Script path/content is missing. Please provide script details.',
      );
    }

    return AiAgentAction(
      type: actionType,
      message: message,
      command: command,
      scriptPath: scriptPath,
      scriptContent: scriptContent,
      scriptLanguage: scriptLanguage,
      validationCommand: validationCommand,
      done: done,
      requiresConfirmation: requiresConfirmation,
      reason: reason,
      expectedSignal: expectedSignal,
    );
  }

  AiConversationTurn _parseConversationTurn(String raw) {
    final text = _stripMarkdownFence(raw.trim());
    final json = _tryParseJsonObject(text);
    if (json == null) {
      return AiConversationTurn(
        reply: text,
        awaitingAnswer: _looksQuestion(text),
        pendingQuestion: _looksQuestion(text)
            ? _extractLastQuestion(text)
            : null,
      );
    }

    final reply = (json['reply'] ?? json['message'] ?? json['text'] ?? '')
        .toString()
        .trim();
    final awaitingAnswer =
        _parseBool(json['awaiting_answer']) ||
        _parseBool(json['awaitingAnswer']);
    final pendingQuestion =
        (json['pending_question'] ?? json['pendingQuestion'])
            ?.toString()
            .trim();

    final finalReply = reply.isEmpty ? text : reply;
    return AiConversationTurn(
      reply: finalReply,
      awaitingAnswer: awaitingAnswer || _looksQuestion(finalReply),
      pendingQuestion: pendingQuestion != null && pendingQuestion.isNotEmpty
          ? pendingQuestion
          : (_looksQuestion(finalReply)
                ? _extractLastQuestion(finalReply)
                : null),
    );
  }

  AiAgentPlan _parseAgentPlan(String raw) {
    final text = _stripMarkdownFence(raw.trim());
    final json = _tryParseJsonObject(text);
    if (json == null) {
      final fallback = text.trim();
      if (fallback.isEmpty) {
        return AiAgentPlan(
          summary: 'Plan hazır.',
          steps: const [
            'Hedefi analiz et',
            'Uygun komutu çalıştır',
            'Sonucu doğrula',
          ],
        );
      }
      final lines = fallback
          .split('\n')
          .map((e) => e.trim())
          .where((e) => e.isNotEmpty)
          .toList(growable: false);
      return AiAgentPlan(
        summary: lines.first,
        steps: lines.length > 1 ? lines.sublist(1).take(6).toList() : const [],
      );
    }

    final summary = (json['summary'] ?? json['message'] ?? json['plan'])
        .toString()
        .trim();
    final rawSteps = json['steps'];
    final steps = <String>[];
    if (rawSteps is List) {
      for (final item in rawSteps) {
        final step = item.toString().trim();
        if (step.isNotEmpty) {
          steps.add(step);
        }
        if (steps.length >= 6) {
          break;
        }
      }
    }
    final requiresConfirmation =
        _parseBool(json['requires_confirmation']) ||
        _parseBool(json['requiresConfirmation']) ||
        _parseBool(json['confirm']);

    return AiAgentPlan(
      summary: summary.isEmpty ? 'Plan hazır.' : summary,
      steps: steps,
      requiresConfirmation: requiresConfirmation || steps.isNotEmpty,
    );
  }

  bool _looksQuestion(String text) {
    final t = text.trim();
    if (t.isEmpty) {
      return false;
    }
    return t.contains('?');
  }

  String? _extractLastQuestion(String text) {
    final lines = text
        .split('\n')
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty)
        .toList();
    for (var i = lines.length - 1; i >= 0; i--) {
      if (lines[i].contains('?')) {
        return lines[i];
      }
    }
    return null;
  }

  String _stripMarkdownFence(String text) {
    if (!text.startsWith('```')) {
      return text;
    }
    return text
        .replaceFirst(RegExp(r'^```\w*\n?'), '')
        .replaceFirst(RegExp(r'\n?```$'), '')
        .trim();
  }

  bool _parseBool(dynamic value) {
    if (value == true) {
      return true;
    }
    if (value is String) {
      final lower = value.trim().toLowerCase();
      return lower == 'true' || lower == '1' || lower == 'yes';
    }
    return false;
  }

  Map<String, dynamic>? _tryParseJsonObject(String text) {
    final direct = _decodeJsonMap(text);
    if (direct != null) {
      return direct;
    }
    final extracted = _extractFirstJsonObject(text);
    if (extracted == null) {
      return null;
    }
    return _decodeJsonMap(extracted);
  }

  Map<String, dynamic>? _decodeJsonMap(String text) {
    try {
      final decoded = jsonDecode(text);
      if (decoded is Map<String, dynamic>) {
        return decoded;
      }
      if (decoded is Map) {
        return decoded.map((key, value) => MapEntry(key.toString(), value));
      }
    } catch (_) {
      // Continue with tolerant parse.
    }
    try {
      final normalized = _normalizeLooseJson(text);
      final decoded = jsonDecode(normalized);
      if (decoded is Map<String, dynamic>) {
        return decoded;
      }
      if (decoded is Map) {
        return decoded.map((key, value) => MapEntry(key.toString(), value));
      }
    } catch (_) {
      // ignore
    }
    return null;
  }

  String _normalizeLooseJson(String text) {
    var out = text
        .replaceAll('\u201c', '"')
        .replaceAll('\u201d', '"')
        .replaceAll('\u2018', "'")
        .replaceAll('\u2019', "'");
    out = out.replaceAll(RegExp(r',(\s*[}\]])'), r'$1');
    return out;
  }

  AiAgentAction? _parseLooseAgentAction(String text) {
    final candidate = text.trim();
    if (candidate.isEmpty) {
      return null;
    }
    if (!candidate.contains('action') &&
        !candidate.contains('"type"') &&
        !candidate.contains("'type'")) {
      return null;
    }

    final actionName =
        _extractLooseField(candidate, 'action') ??
        _extractLooseField(candidate, 'type');
    if (actionName == null || actionName.trim().isEmpty) {
      return null;
    }

    final command =
        _extractLooseField(candidate, 'command') ??
        _extractLooseField(candidate, 'cmd');
    final message =
        _extractLooseField(candidate, 'message') ??
        _extractLooseField(candidate, 'reply') ??
        _extractLooseField(candidate, 'explanation') ??
        _extractLooseField(candidate, 'reason');
    final scriptPath =
        _extractLooseField(candidate, 'script_path') ??
        _extractLooseField(candidate, 'scriptPath') ??
        _extractLooseField(candidate, 'path');
    final scriptContent =
        _extractLooseField(candidate, 'script_content') ??
        _extractLooseField(candidate, 'scriptContent') ??
        _extractLooseField(candidate, 'content') ??
        _extractLooseField(candidate, 'script');
    final scriptLanguage =
        _extractLooseField(candidate, 'script_language') ??
        _extractLooseField(candidate, 'scriptLanguage') ??
        _extractLooseField(candidate, 'language');
    final validationCommand =
        _extractLooseField(candidate, 'validation_command') ??
        _extractLooseField(candidate, 'validationCommand');
    final reason = _extractLooseField(candidate, 'reason');
    final expectedSignal =
        _extractLooseField(candidate, 'expected_signal') ??
        _extractLooseField(candidate, 'expectedSignal');
    final done = _parseBool(_extractLooseField(candidate, 'done'));
    final requiresConfirmation =
        _parseBool(_extractLooseField(candidate, 'requires_confirmation')) ||
        _parseBool(_extractLooseField(candidate, 'requiresConfirmation'));

    final actionType = switch (actionName.trim().toLowerCase()) {
      'run_command' ||
      'runcommand' ||
      'command' => AiAgentActionType.runCommand,
      'write_script' ||
      'writescript' ||
      'script' => AiAgentActionType.writeScript,
      'ask_user' || 'askuser' || 'question' => AiAgentActionType.askUser,
      'finish' ||
      'done' ||
      'complete' ||
      'completed' => AiAgentActionType.finish,
      _ => AiAgentActionType.reply,
    };

    if (actionType == AiAgentActionType.runCommand &&
        (command == null || command.trim().isEmpty)) {
      return AiAgentAction(
        type: AiAgentActionType.askUser,
        message: message ?? 'Command is empty. Please clarify the target.',
      );
    }
    if (actionType == AiAgentActionType.writeScript &&
        ((scriptPath == null || scriptPath.trim().isEmpty) ||
            (scriptContent == null || scriptContent.trim().isEmpty))) {
      return AiAgentAction(
        type: AiAgentActionType.askUser,
        message:
            message ??
            'Script path/content is missing. Please provide script details.',
      );
    }

    return AiAgentAction(
      type: actionType,
      message: message,
      command: command,
      scriptPath: scriptPath,
      scriptContent: scriptContent,
      scriptLanguage: scriptLanguage,
      validationCommand: validationCommand,
      done: done,
      requiresConfirmation: requiresConfirmation,
      reason: reason,
      expectedSignal: expectedSignal,
    );
  }

  String? _extractLooseField(String text, String key) {
    final escaped = RegExp.escape(key);
    final regex = RegExp(
      '["\']?$escaped["\']?\\s*:\\s*("([^"\\\\]|\\\\.)*"|\'([^\'\\\\]|\\\\.)*\'|[^,\\n\\r}\\]]+)',
      multiLine: true,
      caseSensitive: false,
    );
    final match = regex.firstMatch(text);
    if (match == null) {
      return null;
    }
    var value = (match.group(1) ?? '').trim();
    if (value.length >= 2 &&
        ((value.startsWith('"') && value.endsWith('"')) ||
            (value.startsWith("'") && value.endsWith("'")))) {
      value = value.substring(1, value.length - 1);
    }
    value = value.replaceAll(r'\"', '"').replaceAll(r"\'", "'");
    final cleaned = value.trim();
    return cleaned.isEmpty ? null : cleaned;
  }

  String? _extractFirstJsonObject(String text) {
    int depth = 0;
    int start = -1;
    var inString = false;
    var escaped = false;

    for (int i = 0; i < text.length; i++) {
      final ch = text[i];
      if (inString) {
        if (escaped) {
          escaped = false;
        } else if (ch == '\\') {
          escaped = true;
        } else if (ch == '"') {
          inString = false;
        }
        continue;
      }

      if (ch == '"') {
        inString = true;
        continue;
      }

      if (ch == '{') {
        if (depth == 0) {
          start = i;
        }
        depth++;
        continue;
      }

      if (ch == '}') {
        if (depth == 0) {
          continue;
        }
        depth--;
        if (depth == 0 && start >= 0) {
          return text.substring(start, i + 1);
        }
      }
    }
    return null;
  }

  int _agentMaxTokens(AiAgentMode mode) {
    switch (mode) {
      case AiAgentMode.chat:
        return 1024;
      case AiAgentMode.explain:
        return 1024;
      case AiAgentMode.script:
        return 2048;
      case AiAgentMode.agent:
        return 1536;
    }
  }

  String _tailChars(String text, int maxChars) {
    if (text.length <= maxChars) {
      return text;
    }
    return text.substring(text.length - maxChars);
  }

  void dispose() {
    _client.close(force: true);
  }
}
