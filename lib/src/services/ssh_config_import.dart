import 'dart:io';

import 'package:lifeos_sftp_drive/src/models/connection_profile.dart';

/// Parse ~/.ssh/config and import as ConnectionProfile list
class SshConfigImport {
  /// Parse an SSH config file content
  static List<ConnectionProfile> parse(String content) {
    final profiles = <ConnectionProfile>[];
    String? currentHost;
    String? hostname;
    int port = 22;
    String? user;
    String? identityFile;

    for (final rawLine in content.split('\n')) {
      final line = rawLine.trim();
      if (line.isEmpty || line.startsWith('#')) continue;

      final parts = line.split(RegExp(r'\s+'));
      if (parts.length < 2) continue;

      final key = parts[0].toLowerCase();
      final value = parts.sublist(1).join(' ');

      if (key == 'host') {
        // Save previous host
        if (currentHost != null && currentHost != '*') {
          profiles.add(_buildProfile(currentHost, hostname ?? currentHost, port, user ?? 'root', identityFile));
        }
        currentHost = value;
        hostname = null;
        port = 22;
        user = null;
        identityFile = null;
      } else if (key == 'hostname') {
        hostname = value;
      } else if (key == 'port') {
        port = int.tryParse(value) ?? 22;
      } else if (key == 'user') {
        user = value;
      } else if (key == 'identityfile') {
        identityFile = value.replaceFirst('~', Platform.environment['HOME'] ?? Platform.environment['USERPROFILE'] ?? '/root');
      }
    }

    // Save last host
    if (currentHost != null && currentHost != '*') {
      profiles.add(_buildProfile(currentHost, hostname ?? currentHost, port, user ?? 'root', identityFile));
    }

    return profiles;
  }

  static ConnectionProfile _buildProfile(String name, String host, int port, String user, String? keyPath) {
    return ConnectionProfile(
      id: DateTime.now().microsecondsSinceEpoch.toString(),
      name: name,
      host: host,
      port: port,
      username: user,
      remotePath: '/',
      privateKeyPath: keyPath,
    );
  }

  /// Read and parse the default SSH config file
  static Future<List<ConnectionProfile>> importFromDefault() async {
    final home = Platform.environment['HOME'] ?? Platform.environment['USERPROFILE'] ?? '/root';
    final configFile = File('$home${Platform.pathSeparator}.ssh${Platform.pathSeparator}config');
    if (!await configFile.exists()) return [];
    final content = await configFile.readAsString();
    return parse(content);
  }
}
