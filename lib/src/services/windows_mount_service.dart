import 'dart:io';

import 'package:lifeos_sftp_drive/src/models/connection_profile.dart';

enum MountFailureCode {
  dependenciesMissing,
  missingCredentials,
  privateKeyNotFound,
  credentialsInvalid,
  cancelled,
  conflict,
  pathUnavailable,
  unexpected,
}

class MountServiceException implements Exception {
  const MountServiceException(this.code, {this.details, this.exitCode});

  final MountFailureCode code;
  final String? details;
  final int? exitCode;

  @override
  String toString() => details == null ? code.name : '${code.name}: $details';
}

class MountResult {
  const MountResult({required this.driveLetter, required this.command});

  final String driveLetter;
  final String command;
}

class WindowsMountService {
  bool get isSupported => Platform.isWindows;

  Future<bool> isAvailable() async {
    if (!isSupported) {
      return false;
    }
    return _resolveSshfsWinExecutable() != null && _hasWinFsp();
  }

  Future<MountResult> mount(ConnectionProfile profile) async {
    if (!await isAvailable()) {
      throw const MountServiceException(MountFailureCode.dependenciesMissing);
    }

    final password = profile.password.trim();
    final keyPath = profile.privateKeyPath?.trim();
    final hasKey = keyPath != null && keyPath.isNotEmpty;
    if (password.isEmpty && !hasKey) {
      throw const MountServiceException(MountFailureCode.missingCredentials);
    }

    if (hasKey && !File(keyPath).existsSync()) {
      throw MountServiceException(
        MountFailureCode.privateKeyNotFound,
        details: keyPath,
      );
    }

    final driveLetter =
        _normalizeDriveLetter(profile.preferredDriveLetter) ??
        _findFreeDriveLetter();

    if (hasKey) {
      return _mountWithPrivateKey(profile, driveLetter, keyPath);
    }
    return _mountWithPassword(profile, driveLetter, password);
  }

  Future<void> unmount(String driveLetter) async {
    final normalized = _normalizeDriveLetter(driveLetter);
    if (normalized == null) {
      throw const MountServiceException(MountFailureCode.unexpected);
    }

    final args = <String>['use', '$normalized:', '/delete', '/y'];
    final result = await Process.run('net', args);
    if (result.exitCode != 0) {
      throw _mapProcessFailure(result);
    }
  }

  Future<MountResult> _mountWithPassword(
    ConnectionProfile profile,
    String driveLetter,
    String password,
  ) async {
    final uncPath = _buildUncPath(profile, useKeyAuth: false);
    final args = <String>[
      'use',
      '$driveLetter:',
      uncPath,
      password,
      '/persistent:no',
    ];

    final result = await Process.run('net', args);
    if (result.exitCode != 0) {
      throw _mapProcessFailure(result);
    }

    return MountResult(
      driveLetter: driveLetter,
      command: 'net ${args.join(' ')}',
    );
  }

  Future<MountResult> _mountWithPrivateKey(
    ConnectionProfile profile,
    String driveLetter,
    String keyPath,
  ) async {
    final executable = _resolveSshfsWinExecutable();
    if (executable == null) {
      throw const MountServiceException(MountFailureCode.dependenciesMissing);
    }

    final uncPath = _buildUncPath(profile, useKeyAuth: true);
    final args = <String>[
      'svc',
      uncPath,
      '$driveLetter:',
      '',
      'IdentityFile=$keyPath',
    ];

    final result = await Process.run(executable.path, args);
    if (result.exitCode != 0) {
      throw _mapProcessFailure(result);
    }

    return MountResult(
      driveLetter: driveLetter,
      command: '"${executable.path}" ${args.join(' ')}',
    );
  }

  MountServiceException _mapProcessFailure(ProcessResult result) {
    final output = '${result.stdout}\n${result.stderr}'.toLowerCase();
    if (_containsAny(output, const [
      'system error 1223',
      'cancelled by the user',
      'canceled by the user',
      'iptal edildi',
    ])) {
      return MountServiceException(
        MountFailureCode.cancelled,
        details: _compactOutput(result),
        exitCode: result.exitCode,
      );
    }
    if (_containsAny(output, const [
      'system error 86',
      '1326',
      'password is invalid',
      'logon failure',
      'parola geçersiz',
      'kimlik doğrulama başarısız',
    ])) {
      return MountServiceException(
        MountFailureCode.credentialsInvalid,
        details: _compactOutput(result),
        exitCode: result.exitCode,
      );
    }
    if (_containsAny(output, const [
      'system error 1219',
      'multiple connections to a server or shared resource by the same user',
    ])) {
      return MountServiceException(
        MountFailureCode.conflict,
        details: _compactOutput(result),
        exitCode: result.exitCode,
      );
    }
    if (_containsAny(output, const [
      'system error 67',
      'system error 53',
      'network name cannot be found',
      'network path was not found',
      'cannot find',
      'yol bulunamadı',
      'ağ adı bulunamadı',
    ])) {
      return MountServiceException(
        MountFailureCode.pathUnavailable,
        details: _compactOutput(result),
        exitCode: result.exitCode,
      );
    }
    return MountServiceException(
      MountFailureCode.unexpected,
      details: _compactOutput(result),
      exitCode: result.exitCode,
    );
  }

  String _buildUncPath(ConnectionProfile profile, {required bool useKeyAuth}) {
    final hasAbsolutePath = profile.remotePath.startsWith('/');
    final prefix = switch ((hasAbsolutePath, useKeyAuth)) {
      (true, true) => 'sshfs.kr',
      (true, false) => 'sshfs.r',
      (false, true) => 'sshfs.k',
      (false, false) => 'sshfs',
    };

    final portSuffix = profile.port == 22 ? '' : '!${profile.port}';
    final pathSuffix = profile.remotePath == '/' || profile.remotePath.isEmpty
        ? ''
        : '\\${profile.remotePath.replaceAll('/', '\\').replaceFirst(RegExp(r'^\\+'), '')}';

    return r'\\'
        '$prefix\\${profile.username}@${profile.host}$portSuffix$pathSuffix';
  }

  File? _resolveSshfsWinExecutable() {
    // Check bundled (next to exe) first, then system-installed
    final exeDir = File(Platform.resolvedExecutable).parent.path;
    final candidates = <String>[
      '$exeDir\\sshfs-win\\bin\\sshfs-win.exe',
      '$exeDir\\tools\\sshfs-win\\bin\\sshfs-win.exe',
      r'C:\Program Files\SSHFS-Win\bin\sshfs-win.exe',
      r'C:\Program Files (x86)\SSHFS-Win\bin\sshfs-win.exe',
    ];

    for (final path in candidates) {
      final file = File(path);
      if (file.existsSync()) {
        return file;
      }
    }
    return null;
  }

  bool _hasWinFsp() {
    return Directory(r'C:\Program Files\WinFsp').existsSync() ||
        Directory(r'C:\Program Files (x86)\WinFsp').existsSync();
  }

  String? _normalizeDriveLetter(String? value) {
    final trimmed = value?.trim().replaceAll(':', '').toUpperCase();
    if (trimmed == null || trimmed.isEmpty) {
      return null;
    }
    if (!RegExp(r'^[A-Z]$').hasMatch(trimmed)) {
      return null;
    }
    return trimmed;
  }

  String _findFreeDriveLetter() {
    const candidates = <String>[
      'Z',
      'Y',
      'X',
      'W',
      'V',
      'U',
      'T',
      'S',
      'R',
      'Q',
      'P',
      'O',
      'N',
      'M',
    ];

    for (final letter in candidates) {
      if (!Directory('$letter:\\').existsSync()) {
        return letter;
      }
    }
    throw const MountServiceException(MountFailureCode.unexpected);
  }

  String _compactOutput(ProcessResult result) {
    final merged = '${result.stdout}\n${result.stderr}'
        .replaceAll('\r', '\n')
        .split('\n')
        .map((line) => line.trim())
        .where((line) => line.isNotEmpty)
        .join(' ');
    return merged.length > 300 ? '${merged.substring(0, 300)}...' : merged;
  }

  bool _containsAny(String haystack, List<String> needles) {
    for (final needle in needles) {
      if (haystack.contains(needle)) {
        return true;
      }
    }
    return false;
  }
}
