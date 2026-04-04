import 'dart:io';

/// Platform detection utilities — single source of truth.
/// Use these instead of Platform.isXxx checks scattered everywhere.
final bool isDesktop = Platform.isWindows || Platform.isLinux || Platform.isMacOS;
final bool isMobile = Platform.isAndroid || Platform.isIOS;
final bool isWindows = Platform.isWindows;
final bool isLinux = Platform.isLinux;
final bool isMacOS = Platform.isMacOS;
final bool isAndroid = Platform.isAndroid;
final bool isIOS = Platform.isIOS;

/// Returns platform-appropriate home directory.
String get homePath {
  if (Platform.isWindows) return Platform.environment['USERPROFILE'] ?? 'C:\\';
  return Platform.environment['HOME'] ?? '/';
}

/// Returns platform-appropriate font family.
String get platformFontFamily {
  if (Platform.isWindows) return 'Segoe UI Variable Text';
  if (Platform.isMacOS || Platform.isIOS) return '.AppleSystemUIFont';
  return 'sans-serif';
}

/// Shell info for terminal selection.
class ShellInfo {
  const ShellInfo(this.id, this.name, this.path, {this.isUnix = false});
  final String id;   // e.g. 'powershell', 'wsl', 'gitbash'
  final String name;  // display name
  final String path;  // executable path
  final bool isUnix;  // true = uses Linux commands (WSL, Git Bash, bash, zsh)
}

/// Detects available shells on the current platform.
List<ShellInfo> detectAvailableShells() {
  if (Platform.isWindows) {
    final shells = <ShellInfo>[];
    // PowerShell (always available)
    // Use plain exe names for flutter_pty compatibility (backslash mangling).
    const psCheck = r'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe';
    if (File(psCheck).existsSync()) {
      shells.add(const ShellInfo('powershell', 'PowerShell', 'powershell.exe'));
    }
    // PowerShell 7+
    const pwshCheck = r'C:\Program Files\PowerShell\7\pwsh.exe';
    if (File(pwshCheck).existsSync()) {
      shells.add(const ShellInfo('pwsh7', 'PowerShell 7', 'pwsh.exe'));
    }
    // CMD
    shells.add(const ShellInfo('cmd', 'CMD', 'cmd.exe'));
    // WSL — detect the default distro name.
    // Use plain 'wsl.exe' (on PATH) instead of the full path because
    // flutter_pty's build_command() mangles backslashes on Windows.
    const wslCheck = r'C:\Windows\System32\wsl.exe';
    if (File(wslCheck).existsSync()) {
      String distroName = 'Linux';
      try {
        final result = Process.runSync('wsl', ['--list', '--quiet']);
        final lines = result.stdout.toString().replaceAll('\x00', '').split('\n').where((l) => l.trim().isNotEmpty).toList();
        if (lines.isNotEmpty) distroName = lines.first.trim();
      } catch (_) {}
      shells.add(ShellInfo('wsl', 'WSL Bash ($distroName)', 'wsl.exe', isUnix: true));
    }
    // Git Bash — must use full path (not on default PATH), but with forward
    // slashes to avoid flutter_pty backslash mangling.
    const gitBash = r'C:\Program Files\Git\bin\bash.exe';
    const gitBash86 = r'C:\Program Files (x86)\Git\bin\bash.exe';
    if (File(gitBash).existsSync()) {
      shells.add(const ShellInfo('gitbash', 'Git Bash', 'C:/Program Files/Git/bin/bash.exe', isUnix: true));
    } else if (File(gitBash86).existsSync()) {
      shells.add(const ShellInfo('gitbash', 'Git Bash', 'C:/Program Files (x86)/Git/bin/bash.exe', isUnix: true));
    }
    return shells;
  }

  // Linux / macOS
  final shells = <ShellInfo>[];
  final defaultShell = Platform.environment['SHELL'] ?? '/bin/bash';
  final defaultName = defaultShell.split('/').last;
  shells.add(ShellInfo(defaultName, defaultName, defaultShell, isUnix: true));

  for (final s in ['/bin/bash', '/bin/zsh', '/usr/bin/fish']) {
    if (File(s).existsSync() && s != defaultShell) {
      shells.add(ShellInfo(s.split('/').last, s.split('/').last, s, isUnix: true));
    }
  }
  return shells;
}
