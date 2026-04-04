import 'dart:async';
import 'dart:io';

import 'package:lifeos_sftp_drive/src/models/connection_profile.dart';
import 'package:lifeos_sftp_drive/src/services/windows_mount_service.dart';

/// Linux mount service using sshfs (FUSE).
class LinuxMountService {
  bool get isSupported => Platform.isLinux;

  Future<bool> isSshfsAvailable() async {
    if (!isSupported) return false;
    final result = await Process.run('which', ['sshfs']);
    return result.exitCode == 0;
  }

  Future<bool> isSshpassAvailable() async {
    final result = await Process.run('which', ['sshpass']);
    return result.exitCode == 0;
  }

  /// Mount a remote path via sshfs.
  Future<MountResult> mount(ConnectionProfile profile) async {
    if (!await isSshfsAvailable()) {
      throw const MountServiceException(
        MountFailureCode.dependenciesMissing,
        details:
            'sshfs not installed. Install with: sudo pacman -S sshfs (Arch) or sudo apt install sshfs (Debian)',
      );
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

    // Create mount point
    final mountDir = _resolveMountPoint(profile);

    // If already mounted and working, just return
    if (await isMounted(mountDir)) {
      return MountResult(driveLetter: mountDir, command: 'already mounted');
    }

    // Cleanup stale/broken mount if exists (I/O error state)
    await _cleanupStaleMount(mountDir);
    await Directory(mountDir).create(recursive: true);

    final remote =
        '${profile.username}@${profile.host}:${profile.remotePath.isEmpty ? '/' : profile.remotePath}';

    final sshOpts = <String>[
      '-o',
      'port=${profile.port}',
      '-o',
      'StrictHostKeyChecking=no',
      '-o',
      'UserKnownHostsFile=/dev/null',
      '-o',
      'reconnect',
      '-o',
      'ServerAliveInterval=15',
    ];

    if (hasKey) {
      sshOpts.addAll(['-o', 'IdentityFile=$keyPath']);
    }

    // sshfs daemon mode doesn't work reliably from Process.run
    // Use -f (foreground) with nohup via bash to keep it alive
    final escapedPw = password.replaceAll("'", "'\\''");
    String cmd;
    if (hasKey) {
      cmd = 'sshfs $remote $mountDir ${sshOpts.join(' ')} -f';
    } else if (await isSshpassAvailable()) {
      cmd =
          "sshpass -p '$escapedPw' sshfs $remote $mountDir ${sshOpts.join(' ')} -f";
    } else {
      cmd =
          "echo '$escapedPw' | sshfs $remote $mountDir ${sshOpts.join(' ')} -o password_stdin -f";
    }

    // nohup + & keeps sshfs running after Process.start returns
    final proc = await Process.start('bash', [
      '-c',
      'nohup $cmd > /dev/null 2>&1 &',
    ]);
    await proc.exitCode;

    // Wait for mount to establish (up to 5 seconds)
    bool mounted = false;
    for (int i = 0; i < 15; i++) {
      await Future.delayed(const Duration(milliseconds: 300));
      if (await isMounted(mountDir)) {
        mounted = true;
        break;
      }
    }

    if (!mounted) {
      await _cleanupStaleMount(mountDir);
      throw MountServiceException(
        MountFailureCode.unexpected,
        details:
            'sshfs could not mount. Check credentials and network.\nCommand: $cmd',
      );
    }

    return MountResult(
      driveLetter: mountDir,
      command: 'sshfs $remote $mountDir',
    );
  }

  Future<void> unmount(String mountPoint) async {
    // Try fusermount first (FUSE), then umount
    var result = await Process.run('fusermount', ['-u', mountPoint]);
    if (result.exitCode != 0) {
      // Force unmount
      result = await Process.run('fusermount', ['-uz', mountPoint]);
    }
    if (result.exitCode != 0) {
      result = await Process.run('umount', ['-l', mountPoint]);
    }
    if (result.exitCode != 0) {
      throw MountServiceException(
        MountFailureCode.unexpected,
        details: '${result.stderr}'.trim(),
        exitCode: result.exitCode,
      );
    }
    // Clean up empty mount dir
    try {
      final dir = Directory(mountPoint);
      if (await dir.exists()) await dir.delete();
    } catch (_) {}
  }

  /// Check if a path is currently mounted
  Future<bool> isMounted(String mountPoint) async {
    Process? proc;
    try {
      proc = await Process.start('mountpoint', ['-q', mountPoint]);
      final exitCode = await proc.exitCode.timeout(
        const Duration(milliseconds: 1200),
      );
      return exitCode == 0;
    } on TimeoutException {
      proc?.kill(ProcessSignal.sigkill);
      return false;
    } catch (_) {
      return false;
    }
  }

  /// Cleanup a stale/broken mount point
  Future<void> _cleanupStaleMount(String mountDir) async {
    try {
      // Force unmount (handles stale FUSE mounts with I/O errors)
      await Process.run('fusermount', ['-uz', mountDir]);
    } catch (_) {}
    try {
      // rm -rf handles directories that Dart's Directory.delete can't (I/O errors)
      await Process.run('rm', ['-rf', mountDir]);
    } catch (_) {}
  }

  String _resolveMountPoint(ConnectionProfile profile) {
    final home = Platform.environment['HOME'] ?? '/tmp';
    final safeName = profile.name.replaceAll(RegExp(r'[^a-zA-Z0-9_-]'), '_');
    return '$home/.local/share/lifeos-sftp/mounts/$safeName';
  }

  /// Get mount point path for a profile (without mounting)
  String getMountPoint(ConnectionProfile profile) =>
      _resolveMountPoint(profile);
}
