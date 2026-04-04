import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';
import 'package:lifeos_sftp_drive/src/models/connection_profile.dart';
import 'package:lifeos_sftp_drive/src/models/remote_file_entry.dart';

enum SftpFailureCode {
  missingCredentials,
  privateKeyNotFound,
  invalidPrivateKey,
  authenticationFailed,
  hostUnreachable,
  unexpected,
}

class SftpServiceException implements Exception {
  const SftpServiceException(this.code, {this.details, this.path});

  final SftpFailureCode code;
  final String? details;
  final String? path;

  @override
  String toString() => details ?? code.name;
}

class SftpConnectionSession {
  SftpConnectionSession({required this.client, required this.sftp});

  final SSHClient client;
  final SftpClient sftp;

  Future<void> close() async {
    client.close();
    await client.done.catchError((_) {});
  }
}

class SftpBrowserService {
  Future<SftpConnectionSession> connect(ConnectionProfile profile) async {
    if (profile.password.trim().isEmpty &&
        (profile.privateKeyPath == null ||
            profile.privateKeyPath!.trim().isEmpty)) {
      throw const SftpServiceException(SftpFailureCode.missingCredentials);
    }

    final SSHSocket socket;
    try {
      socket = await SSHSocket.connect(profile.host, profile.port);
    } on SocketException catch (error) {
      throw SftpServiceException(
        SftpFailureCode.hostUnreachable,
        details: error.message,
      );
    }

    final identities = await _loadIdentities(profile);
    try {
      final client = SSHClient(
        socket,
        username: profile.username,
        identities: identities.isEmpty ? null : identities,
        onPasswordRequest: profile.password.isEmpty
            ? null
            : () => profile.password,
      );

      final sftp = await client.sftp();
      return SftpConnectionSession(client: client, sftp: sftp);
    } on SSHAuthFailError {
      throw const SftpServiceException(SftpFailureCode.authenticationFailed);
    } catch (error) {
      throw SftpServiceException(
        SftpFailureCode.unexpected,
        details: error.toString(),
      );
    }
  }

  Future<List<RemoteFileEntry>> listDirectory(
    SftpConnectionSession session,
    String path,
  ) async {
    final items = await session.sftp.listdir(path);
    return items
        .where((item) => item.filename != '.' && item.filename != '..')
        .map((item) {
          final childPath = _join(path, item.filename);
          // Extract permissions from longname (e.g. "drwxr-xr-x ...")
          String? perms;
          if (item.longname.length > 10) {
            perms = item.longname.substring(0, 10);
          }
          // Extract modified date from attr
          DateTime? modified;
          try { if (item.attr.modifyTime != null) modified = DateTime.fromMillisecondsSinceEpoch(item.attr.modifyTime! * 1000); } catch (_) {}
          return RemoteFileEntry(
            name: item.filename,
            path: childPath,
            isDirectory: item.attr.isDirectory,
            size: item.attr.size,
            longName: item.longname,
            modified: modified,
            permissions: perms,
          );
        })
        .toList()
      ..sort((a, b) {
        if (a.isDirectory != b.isDirectory) {
          return a.isDirectory ? -1 : 1;
        }
        return a.name.toLowerCase().compareTo(b.name.toLowerCase());
      });
  }

  Future<String> resolveInitialPath(
    SftpConnectionSession session,
    ConnectionProfile profile,
  ) async {
    return session.sftp.absolute(
      profile.remotePath.isEmpty ? '.' : profile.remotePath,
    );
  }

  Future<void> copyFileBetweenServers({
    required SftpConnectionSession sourceSession,
    required RemoteFileEntry sourceFile,
    required SftpConnectionSession targetSession,
    required String targetDirectory,
  }) async {
    final tempFile = File(
      '${Directory.systemTemp.path}\\lifeos_sftp_${DateTime.now().microsecondsSinceEpoch}_${sourceFile.name}',
    );

    final output = tempFile.openWrite();
    try {
      await sourceSession.sftp.download(
        sourceFile.path,
        output,
        closeDestination: true,
      );

      final targetPath = _join(targetDirectory, sourceFile.name);
      final remote = await targetSession.sftp.open(
        targetPath,
        mode:
            SftpFileOpenMode.create |
            SftpFileOpenMode.truncate |
            SftpFileOpenMode.write,
      );
      try {
        final uploader = await remote.write(
          tempFile.openRead().cast<Uint8List>(),
        );
        await uploader.done;
      } finally {
        await remote.close();
      }
    } finally {
      if (await tempFile.exists()) {
        await tempFile.delete();
      }
    }
  }

  Future<List<SSHKeyPair>> _loadIdentities(ConnectionProfile profile) async {
    final keyPath = profile.privateKeyPath;
    if (keyPath == null || keyPath.trim().isEmpty) {
      return const [];
    }
    final file = File(keyPath);
    if (!await file.exists()) {
      throw SftpServiceException(
        SftpFailureCode.privateKeyNotFound,
        path: keyPath,
      );
    }
    final pem = await file.readAsString();
    try {
      return SSHKeyPair.fromPem(pem);
    } catch (_) {
      throw const SftpServiceException(SftpFailureCode.invalidPrivateKey);
    }
  }

  // ─── File operations ──────────────────────────────────────────────

  Future<void> deleteFile(SftpConnectionSession session, String path) async {
    await session.sftp.remove(path);
  }

  Future<void> deleteDirectory(SftpConnectionSession session, String path) async {
    // Recursively delete contents first
    final items = await session.sftp.listdir(path);
    for (final item in items) {
      if (item.filename == '.' || item.filename == '..') continue;
      final childPath = _join(path, item.filename);
      if (item.attr.isDirectory) {
        await deleteDirectory(session, childPath);
      } else {
        await session.sftp.remove(childPath);
      }
    }
    await session.sftp.rmdir(path);
  }

  Future<void> rename(SftpConnectionSession session, String oldPath, String newPath) async {
    await session.sftp.rename(oldPath, newPath);
  }

  Future<void> createDirectory(SftpConnectionSession session, String path) async {
    await session.sftp.mkdir(path);
  }

  /// Compress files on the remote server using tar/zip via SSH exec
  Future<String> compressRemote(SftpConnectionSession session, String dirPath, String name) async {
    final archiveName = '$name.tar.gz';
    final archivePath = _join(_parent(dirPath), archiveName);
    final parentDir = _parent(dirPath);
    await session.client.run('cd "$parentDir" && tar czf "$archivePath" "$name"');
    return archivePath;
  }

  /// Extract archive on the remote server
  Future<void> extractRemote(SftpConnectionSession session, String archivePath, String targetDir) async {
    await session.client.run('cd "$targetDir" && tar xzf "$archivePath"');
  }

  String _parent(String path) {
    if (path == '/' || path.isEmpty) return '/';
    final n = path.endsWith('/') && path.length > 1 ? path.substring(0, path.length - 1) : path;
    final idx = n.lastIndexOf('/');
    return idx <= 0 ? '/' : n.substring(0, idx);
  }

  String _join(String base, String child) {
    if (base == '/' || base.isEmpty) {
      return '/$child';
    }
    return '$base/$child';
  }
}
