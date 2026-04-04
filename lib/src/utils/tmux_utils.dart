import 'dart:convert';

import 'package:dartssh2/dartssh2.dart';

/// Shared tmux utilities used by both terminal controller and agent CLI.
/// Prefix convention:
///   - Terminal sessions: `lifeos_{hostToken}_{namedToken}`
///   - Agent CLI sessions: `lifeos_cli_{providerToken}_{hostToken}`
class TmuxUtils {
  TmuxUtils._();

  // ── SSH command helpers ─────────────────────────────────────

  static Future<String> runCommandText(
    SSHClient client,
    String command, {
    Duration timeout = const Duration(seconds: 10),
  }) async {
    try {
      final result = await client.run(command).timeout(timeout);
      return utf8.decode(result, allowMalformed: true).trim();
    } catch (_) {
      return '';
    }
  }

  static Future<bool> hasTmux(SSHClient client) async {
    final result = await runCommandText(
      client,
      'command -v tmux >/dev/null 2>&1 && echo yes || echo no',
    );
    return result.trim().toLowerCase() == 'yes';
  }

  static Future<bool> hasTmuxSession(
    SSHClient client,
    String sessionName,
  ) async {
    final sessionQuoted = shellQuote(sessionName);
    final result = await runCommandText(
      client,
      'tmux has-session -t $sessionQuoted >/dev/null 2>&1 && echo yes || echo no',
    );
    return result.trim().toLowerCase() == 'yes';
  }

  static Future<String> detectPackageManager(SSHClient client) async {
    const managers = ['apt-get', 'dnf', 'yum', 'pacman', 'zypper', 'apk'];
    for (final manager in managers) {
      final result = await runCommandText(
        client,
        'command -v $manager >/dev/null 2>&1 && echo yes || echo no',
      );
      if (result.trim().toLowerCase() == 'yes') {
        return manager;
      }
    }
    return 'unknown';
  }

  /// Install tmux using the detected package manager.
  /// Returns true if tmux is available after installation.
  static Future<bool> installTmux(SSHClient client) async {
    final packageManager = await detectPackageManager(client);
    if (packageManager == 'unknown') return false;

    final isRoot =
        (await runCommandText(client, 'id -u')).trim() == '0';
    final canSudo =
        (await runCommandText(
          client,
          'sudo -n true >/dev/null 2>&1 && echo yes || echo no',
        )).trim().toLowerCase() ==
        'yes';

    if (!isRoot && !canSudo) return false;

    final prefix = isRoot ? '' : 'sudo -n ';
    final command = switch (packageManager) {
      'apt-get' => '${prefix}apt-get install -y tmux',
      'dnf' => '${prefix}dnf install -y tmux',
      'yum' => '${prefix}yum install -y tmux',
      'pacman' => '${prefix}pacman -Sy --noconfirm tmux',
      'zypper' => '${prefix}zypper --non-interactive install tmux',
      'apk' => '${prefix}apk add tmux',
      _ => '',
    };

    if (command.isEmpty) return false;

    await runCommandText(client, command, timeout: const Duration(minutes: 2));
    return await hasTmux(client);
  }

  // ── String utilities ────────────────────────────────────────

  static String shellQuote(String input) {
    final escaped = input.replaceAll("'", "'\"'\"'");
    return "'$escaped'";
  }

  static String normalizeTmuxToken(String value) {
    final normalized = value
        .trim()
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9_]'), '_')
        .replaceAll(RegExp(r'_+'), '_');
    if (normalized.isEmpty) return 'main';
    return normalized;
  }

  static String stableHash(String value) {
    var hash = 0x811c9dc5;
    for (final byte in utf8.encode(value)) {
      hash ^= byte;
      hash = (hash * 0x01000193) & 0xffffffff;
    }
    return hash.toRadixString(16).padLeft(8, '0');
  }

  // ── Session naming ──────────────────────────────────────────

  /// Build agent CLI tmux session name.
  /// Format: `lifeos_cli_{providerToken}_{hostToken}`
  static String buildAgentSessionName({
    required String providerId,
    required String username,
    required String host,
    required int port,
  }) {
    final providerToken = normalizeTmuxToken(providerId);
    final hostToken = normalizeTmuxToken('${username}_${host}_$port');
    final raw = 'lifeos_cli_${providerToken}_$hostToken';
    if (raw.length <= 72) return raw;

    final provShort =
        providerToken.length > 10 ? providerToken.substring(0, 10) : providerToken;
    final hostShort =
        hostToken.length > 20 ? hostToken.substring(0, 20) : hostToken;
    final h = stableHash('$providerToken:$hostToken');
    return 'lifeos_cli_${provShort}_${hostShort}_${h.substring(0, 8)}';
  }

  /// Build terminal tmux session name (existing convention).
  static String buildTerminalSessionName({
    required String username,
    required String host,
    required int port,
    required String namedSession,
  }) {
    final hostToken = normalizeTmuxToken('${username}_${host}_$port');
    final namedToken = normalizeTmuxToken(namedSession);
    final raw = 'lifeos_${hostToken}_$namedToken';
    if (raw.length <= 72) return raw;

    final hostShort =
        hostToken.length > 20 ? hostToken.substring(0, 20) : hostToken;
    final namedShort =
        namedToken.length > 16 ? namedToken.substring(0, 16) : namedToken;
    final h = stableHash('$hostToken:$namedToken');
    return 'lifeos_${hostShort}_${namedShort}_${h.substring(0, 8)}';
  }

  /// Host key for tmux decision tracking.
  static String tmuxHostKey({
    required String username,
    required String host,
    required int port,
  }) =>
      '$username@$host:$port';

  /// Configure a tmux session (disable status bar, titles).
  static Future<void> configureTmuxSession(
    SSHClient client,
    String sessionName,
  ) async {
    final sq = shellQuote(sessionName);
    await runCommandText(client, 'tmux set -t $sq status off >/dev/null 2>&1 || true');
    await runCommandText(client, 'tmux set -t $sq set-titles off >/dev/null 2>&1 || true');
  }
}
