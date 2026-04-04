import 'dart:async';
import 'dart:io';

import 'package:dartssh2/dartssh2.dart';
import 'package:fluent_ui/fluent_ui.dart';
import 'package:lifeos_sftp_drive/src/utils/platform_utils.dart' as pu;
import 'package:lifeos_sftp_drive/src/models/connection_profile.dart';
import 'package:lifeos_sftp_drive/src/models/log_entry.dart';
import 'package:lifeos_sftp_drive/src/models/remote_file_entry.dart';
import 'package:lifeos_sftp_drive/src/services/sftp_browser_service.dart';
import 'package:lifeos_sftp_drive/src/state/app_controller.dart';
import 'package:lifeos_sftp_drive/src/ui/theme_tokens.dart';
import 'package:lifeos_sftp_drive/src/ui/widgets/file_editor.dart';

class BrowserView extends StatefulWidget {
  const BrowserView({super.key, required this.appController, this.preferredLeftProfileId, this.preferredRightProfileId});
  final AppController appController;
  final String? preferredLeftProfileId;
  final String? preferredRightProfileId;
  @override State<BrowserView> createState() => _BrowserViewState();
}

class _BrowserViewState extends State<BrowserView> {
  final _service = SftpBrowserService();

  static String _defaultLocalPath() => pu.homePath;

  // Left panel state
  bool _leftIsLocal = true;
  String _leftLocalPath = _defaultLocalPath();
  List<FileSystemEntity> _leftLocalEntries = const [];
  String? _leftRemoteProfileId;
  SftpConnectionSession? _leftRemoteSession;
  String _leftRemotePath = '/';
  List<RemoteFileEntry> _leftRemoteEntries = const [];
  dynamic _leftSelected; // FileSystemEntity or RemoteFileEntry
  bool _leftLoading = false;
  String? _leftError;

  // Right panel state
  bool _rightIsLocal = false;
  String _rightLocalPath = _defaultLocalPath();
  List<FileSystemEntity> _rightLocalEntries = const [];
  String? _rightRemoteProfileId;
  SftpConnectionSession? _rightRemoteSession;
  String _rightRemotePath = '/';
  List<RemoteFileEntry> _rightRemoteEntries = const [];
  dynamic _rightSelected;
  bool _rightLoading = false;
  String? _rightError;

  // Transfer
  String? _statusMsg;
  bool _statusIsError = false;

  @override
  void initState() {
    super.initState();
    _loadLeftLocal();
    _initProfiles();
    widget.appController.addListener(_onAppChanged);
  }

  void _initProfiles() {
    final profiles = widget.appController.connections;
    if (profiles.isNotEmpty && _rightRemoteProfileId == null) {
      _rightRemoteProfileId = widget.preferredLeftProfileId ?? profiles.first.id;
    }
    if (profiles.isNotEmpty && _leftRemoteProfileId == null) {
      _leftRemoteProfileId = profiles.first.id;
    }
  }

  void _onAppChanged() {
    // Profiles may have loaded async — update if needed
    _initProfiles();
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    widget.appController.removeListener(_onAppChanged);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(10),
      child: Column(children: [
        if (_statusMsg != null) _StatusBar(msg: _statusMsg!, isError: _statusIsError, onDismiss: () => setState(() => _statusMsg = null)),
        Expanded(child: Row(children: [
          Expanded(child: _buildPanel(isLeft: true)),
          const SizedBox(width: 8),
          Expanded(child: _buildPanel(isLeft: false)),
        ])),
      ]),
    );
  }

  Widget _buildPanel({required bool isLeft}) {
    final isLocal = isLeft ? _leftIsLocal : _rightIsLocal;
    final loading = isLeft ? _leftLoading : _rightLoading;
    final error = isLeft ? _leftError : _rightError;

    final effectActive = widget.appController.windowEffect != 'none';
    final opacity = widget.appController.windowOpacity;
    final tt = TransparentTheme(effectActive: effectActive, opacity: opacity);

    return Container(
      decoration: BoxDecoration(color: tt.panelAlt, borderRadius: BorderRadius.circular(8)),
      child: Column(children: [
        // Panel header
        _PanelHeader(
          isLocal: isLocal,
          path: isLocal ? (isLeft ? _leftLocalPath : _rightLocalPath) : (isLeft ? _leftRemotePath : _rightRemotePath),
          profiles: widget.appController.connections,
          selectedProfileId: isLeft ? _leftRemoteProfileId : _rightRemoteProfileId,
          isConnected: isLocal ? true : (isLeft ? _leftRemoteSession != null : _rightRemoteSession != null),
          onToggleMode: () => setState(() { if (isLeft) _leftIsLocal = !_leftIsLocal; else _rightIsLocal = !_rightIsLocal; _refreshPanel(isLeft); }),
          onProfileChanged: (v) { setState(() { if (isLeft) _leftRemoteProfileId = v; else _rightRemoteProfileId = v; }); },
          onConnect: () => _connectRemote(isLeft),
          onUp: () => _goUp(isLeft),
          onRefresh: () => _refreshPanel(isLeft),
        ),
        Container(height: 0.5, color: workbenchDivider),
        // Column headers
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
          color: workbenchHover,
          child: Row(children: [
            const SizedBox(width: 21), // icon space
            Expanded(child: Text('Name', style: TextStyle(color: workbenchTextFaint, fontSize: 10, fontWeight: FontWeight.w600))),
            SizedBox(width: 80, child: Text('Date', textAlign: TextAlign.left, style: TextStyle(color: workbenchTextFaint, fontSize: 10, fontWeight: FontWeight.w600))),
            SizedBox(width: 60, child: Text('Size', textAlign: TextAlign.right, style: TextStyle(color: workbenchTextFaint, fontSize: 10, fontWeight: FontWeight.w600))),
          ]),
        ),
        Container(height: 0.5, color: workbenchDivider),
        if (error != null) Container(
          width: double.infinity, padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          color: workbenchDanger.withValues(alpha: 0.08),
          child: Text(error!, style: TextStyle(color: workbenchDanger, fontSize: 11)),
        ),
        // File list
        Expanded(child: loading
          ? const Center(child: ProgressRing())
          : isLocal
            ? _buildLocalList(isLeft)
            : _buildRemoteList(isLeft),
        ),
      ]),
    );
  }

  Widget _buildLocalList(bool isLeft) {
    final entries = isLeft ? _leftLocalEntries : _rightLocalEntries;
    if (entries.isEmpty) return Center(child: Text('Empty', style: TextStyle(color: workbenchTextMuted, fontSize: 12)));
    final selected = isLeft ? _leftSelected : _rightSelected;
    return ListView.builder(
      itemCount: entries.length,
      itemBuilder: (_, i) {
        final e = entries[i];
        final isDir = e is Directory;
        final name = e.uri.pathSegments.where((s) => s.isNotEmpty).lastOrNull ?? e.path;
        int? size; DateTime? modified;
        if (e is File) { try { size = e.lengthSync(); modified = e.lastModifiedSync(); } catch (_) {} }
        if (e is Directory) { try { modified = e.statSync().modified; } catch (_) {} }
        return _FileRow(
          name: name, isDir: isDir, selected: selected == e, size: size, modified: modified, index: i,
          onTap: () => setState(() { if (isLeft) _leftSelected = e; else _rightSelected = e; }),
          onDoubleTap: isDir ? () { if (isLeft) { _leftLocalPath = e.path; _loadLeftLocal(); } else { _rightLocalPath = e.path; _loadRightLocal(); } } : null,
          onContextMenu: (offset) => _showLocalContextMenu(offset, e, isLeft),
        );
      },
    );
  }

  Widget _buildRemoteList(bool isLeft) {
    final session = isLeft ? _leftRemoteSession : _rightRemoteSession;
    final entries = isLeft ? _leftRemoteEntries : _rightRemoteEntries;
    if (session == null) return Center(child: Text('Not connected', style: TextStyle(color: workbenchTextMuted, fontSize: 12)));
    if (entries.isEmpty) return Center(child: Text('Empty', style: TextStyle(color: workbenchTextMuted, fontSize: 12)));
    final selected = isLeft ? _leftSelected : _rightSelected;
    return ListView.builder(
      itemCount: entries.length,
      itemBuilder: (_, i) {
        final e = entries[i];
        return _FileRow(
          name: e.name, isDir: e.isDirectory, selected: selected == e, size: e.isDirectory ? null : e.size, modified: e.modified, permissions: e.permissions, index: i,
          onTap: () => setState(() { if (isLeft) _leftSelected = e; else _rightSelected = e; }),
          onDoubleTap: e.isDirectory ? () async { if (isLeft) { _leftRemotePath = e.path; await _refreshLeftRemote(); } else { _rightRemotePath = e.path; await _refreshRightRemote(); } } : null,
          onContextMenu: (offset) => _showRemoteContextMenu(offset, e, isLeft),
        );
      },
    );
  }

  // ─── Context Menus ─────────────────────────────────────────────────

  void _showLocalContextMenu(Offset pos, FileSystemEntity entity, bool isLeft) {
    final isDir = entity is Directory;
    final name = entity.uri.pathSegments.where((s) => s.isNotEmpty).lastOrNull ?? entity.path;
    _showCtxMenu(pos, [
      if (!isDir) _CItem(FluentIcons.edit_note, 'Edit', () => openLocalFileEditor(context, entity.path)),
      if (!isDir) _CItem(FluentIcons.upload, 'Upload to Remote', () => _uploadFile(entity as File, isLeft)),
      _CItem(FluentIcons.archive, pu.isWindows ? 'Compress (ZIP)' : 'Compress (tar.gz)', () => _compressLocal(entity, isLeft)),
      if (!isDir && name.endsWith('.zip') || name.endsWith('.tar.gz')) _CItem(FluentIcons.open_pane, 'Extract', () => _extractLocal(entity, isLeft)),
      _CItem(FluentIcons.rename, 'Rename', () => _renameLocal(entity, isLeft)),
      _CItem(FluentIcons.new_folder, 'New Folder', () => _newFolderLocal(isLeft)),
      _CItem(FluentIcons.delete, 'Delete', () => _deleteLocal(entity, isLeft), danger: true),
    ]);
  }

  void _showRemoteContextMenu(Offset pos, RemoteFileEntry entry, bool isLeft) {
    final session = isLeft ? _leftRemoteSession : _rightRemoteSession;
    if (session == null) return;
    _showCtxMenu(pos, [
      if (!entry.isDirectory) _CItem(FluentIcons.edit_note, 'Edit', () {
        if (session != null) openRemoteFileEditor(context, session, entry.path);
      }),
      if (!entry.isDirectory) _CItem(FluentIcons.download, 'Download', () => _downloadFile(entry, isLeft)),
      _CItem(FluentIcons.archive, 'Compress (tar.gz)', () => _compressRemote(entry, isLeft)),
      if (entry.name.endsWith('.tar.gz') || entry.name.endsWith('.zip')) _CItem(FluentIcons.open_pane, 'Extract', () => _extractRemote(entry, isLeft)),
      _CItem(FluentIcons.rename, 'Rename', () => _renameRemote(entry, isLeft)),
      _CItem(FluentIcons.new_folder, 'New Folder', () => _newFolderRemote(isLeft)),
      _CItem(FluentIcons.delete, 'Delete', () => _deleteRemote(entry, isLeft), danger: true),
    ]);
  }

  void _showCtxMenu(Offset pos, List<_CItem> items) {
    showBoundedContextMenu(context, pos, (dismiss) => _CtxMenuWidget(items: items, onDone: dismiss), menuWidth: 200, menuHeight: items.length * 34.0);
  }

  // ─── Local operations ──────────────────────────────────────────────

  Future<void> _loadLeftLocal() async {
    setState(() => _leftLoading = true);
    try {
      final list = await Directory(_leftLocalPath).list().toList();
      list.sort((a, b) { final ad = a is Directory; final bd = b is Directory; if (ad != bd) return ad ? -1 : 1; return a.path.toLowerCase().compareTo(b.path.toLowerCase()); });
      _leftLocalEntries = list; _leftSelected = null; _leftError = null;
    } catch (e) { _leftLocalEntries = const []; _leftError = e.toString(); }
    if (mounted) setState(() => _leftLoading = false);
  }

  Future<void> _loadRightLocal() async {
    setState(() => _rightLoading = true);
    try {
      final list = await Directory(_rightLocalPath).list().toList();
      list.sort((a, b) { final ad = a is Directory; final bd = b is Directory; if (ad != bd) return ad ? -1 : 1; return a.path.toLowerCase().compareTo(b.path.toLowerCase()); });
      _rightLocalEntries = list; _rightSelected = null; _rightError = null;
    } catch (e) { _rightLocalEntries = const []; _rightError = e.toString(); }
    if (mounted) setState(() => _rightLoading = false);
  }

  void _deleteLocal(FileSystemEntity entity, bool isLeft) async {
    try {
      await entity.delete(recursive: true);
      _setStatus('Deleted ${entity.uri.pathSegments.last}', false);
      _refreshPanel(isLeft);
    } catch (e) { _setStatus('Delete failed: $e', true); }
  }

  void _renameLocal(FileSystemEntity entity, bool isLeft) async {
    final name = entity.uri.pathSegments.where((s) => s.isNotEmpty).lastOrNull ?? '';
    final newName = await _showInputDialog('Rename', name);
    if (newName == null || newName.isEmpty || newName == name) return;
    try {
      final parent = entity.parent.path;
      await entity.rename('$parent${Platform.pathSeparator}$newName');
      _setStatus('Renamed to $newName', false);
      _refreshPanel(isLeft);
    } catch (e) { _setStatus('Rename failed: $e', true); }
  }

  void _newFolderLocal(bool isLeft) async {
    final name = await _showInputDialog('New Folder', '');
    if (name == null || name.isEmpty) return;
    try {
      final base = isLeft ? _leftLocalPath : _rightLocalPath;
      await Directory('$base${Platform.pathSeparator}$name').create();
      _setStatus('Created folder $name', false);
      _refreshPanel(isLeft);
    } catch (e) { _setStatus('Create folder failed: $e', true); }
  }

  void _compressLocal(FileSystemEntity entity, bool isLeft) async {
    final name = entity.uri.pathSegments.where((s) => s.isNotEmpty).lastOrNull ?? 'archive';
    _setStatus('Compressing $name...', false);
    try {
      final parent = entity.parent.path;
      ProcessResult result;
      if (pu.isWindows) {
        final zipPath = '$parent${Platform.pathSeparator}$name.zip';
        result = await Process.run('powershell', ['-Command', 'Compress-Archive', '-Path', '"${entity.path}"', '-DestinationPath', '"$zipPath"', '-Force']);
      } else {
        // Linux/macOS: use tar
        result = await Process.run('tar', ['-czf', '$name.tar.gz', '-C', parent, name], workingDirectory: parent);
      }
      if (result.exitCode != 0) throw Exception(result.stderr);
      _setStatus(pu.isWindows ? 'Compressed to $name.zip' : 'Compressed to $name.tar.gz', false);
      _refreshPanel(isLeft);
    } catch (e) { _setStatus('Compression failed: $e', true); }
  }

  void _extractLocal(FileSystemEntity entity, bool isLeft) async {
    final name = entity.uri.pathSegments.where((s) => s.isNotEmpty).lastOrNull ?? '';
    _setStatus('Extracting $name...', false);
    try {
      final parent = entity.parent.path;
      ProcessResult result;
      if (pu.isWindows) {
        result = await Process.run('powershell', ['-Command', 'Expand-Archive', '-Path', '"${entity.path}"', '-DestinationPath', '"$parent"', '-Force']);
      } else if (name.endsWith('.tar.gz') || name.endsWith('.tgz')) {
        result = await Process.run('tar', ['-xzf', entity.path, '-C', parent]);
      } else if (name.endsWith('.zip')) {
        result = await Process.run('unzip', ['-o', entity.path, '-d', parent]);
      } else {
        result = await Process.run('tar', ['-xf', entity.path, '-C', parent]);
      }
      if (result.exitCode != 0) throw Exception(result.stderr);
      _setStatus('Extracted $name', false);
      _refreshPanel(isLeft);
    } catch (e) { _setStatus('Extract failed: $e', true); }
  }

  // ─── Remote operations ─────────────────────────────────────────────

  ConnectionProfile? _profileById(String? id) {
    for (final p in widget.appController.connections) { if (p.id == id) return p; }
    return null;
  }

  Future<void> _connectRemote(bool isLeft) async {
    final profileId = isLeft ? _leftRemoteProfileId : _rightRemoteProfileId;
    final profile = _profileById(profileId);
    if (profile == null || profileId == null) return;
    setState(() { if (isLeft) { _leftLoading = true; _leftError = null; } else { _rightLoading = true; _rightError = null; } });
    try {
      // Reuse existing session from AppController pool if available
      SftpConnectionSession? session = widget.appController.getSftpSession(profileId);
      if (session == null) {
        session = await _service.connect(profile);
        widget.appController.setSftpSession(profileId, session);
      }
      final initPath = await _service.resolveInitialPath(session, profile);
      final entries = await _service.listDirectory(session, initPath);
      if (isLeft) { _leftRemoteSession = session; _leftRemotePath = initPath; _leftRemoteEntries = entries; _leftSelected = null; }
      else { _rightRemoteSession = session; _rightRemotePath = initPath; _rightRemoteEntries = entries; _rightSelected = null; }
      widget.appController.addLog('Connected SFTP to ${profile.name}', level: LogLevel.info);
    } catch (e) {
      // Session might be stale, try fresh connection
      if (profileId != null) await widget.appController.closeSftpSession(profileId);
      try {
        final session = await _service.connect(profile);
        widget.appController.setSftpSession(profileId, session);
        final initPath = await _service.resolveInitialPath(session, profile);
        final entries = await _service.listDirectory(session, initPath);
        if (isLeft) { _leftRemoteSession = session; _leftRemotePath = initPath; _leftRemoteEntries = entries; _leftSelected = null; }
        else { _rightRemoteSession = session; _rightRemotePath = initPath; _rightRemoteEntries = entries; _rightSelected = null; }
        widget.appController.addLog('Reconnected SFTP to ${profile.name}', level: LogLevel.info);
      } catch (e2) {
        final err = e2.toString();
        if (isLeft) { _leftRemoteSession = null; _leftRemoteEntries = const []; _leftError = err; }
        else { _rightRemoteSession = null; _rightRemoteEntries = const []; _rightError = err; }
      }
    }
    if (mounted) setState(() { if (isLeft) _leftLoading = false; else _rightLoading = false; });
  }

  Future<void> _refreshLeftRemote() async {
    if (_leftRemoteSession == null) return;
    setState(() { _leftLoading = true; _leftError = null; });
    try { _leftRemoteEntries = await _service.listDirectory(_leftRemoteSession!, _leftRemotePath); } catch (e) { _leftError = e.toString(); }
    if (mounted) setState(() => _leftLoading = false);
  }

  Future<void> _refreshRightRemote() async {
    if (_rightRemoteSession == null) return;
    setState(() { _rightLoading = true; _rightError = null; });
    try { _rightRemoteEntries = await _service.listDirectory(_rightRemoteSession!, _rightRemotePath); } catch (e) { _rightError = e.toString(); }
    if (mounted) setState(() => _rightLoading = false);
  }

  void _deleteRemote(RemoteFileEntry entry, bool isLeft) async {
    final session = isLeft ? _leftRemoteSession : _rightRemoteSession;
    if (session == null) return;
    _setStatus('Deleting ${entry.name}...', false);
    try {
      if (entry.isDirectory) { await _service.deleteDirectory(session, entry.path); }
      else { await _service.deleteFile(session, entry.path); }
      _setStatus('Deleted ${entry.name}', false);
      _refreshPanel(isLeft);
    } catch (e) { _setStatus('Delete failed: $e', true); }
  }

  void _renameRemote(RemoteFileEntry entry, bool isLeft) async {
    final session = isLeft ? _leftRemoteSession : _rightRemoteSession;
    if (session == null) return;
    final newName = await _showInputDialog('Rename', entry.name);
    if (newName == null || newName.isEmpty || newName == entry.name) return;
    try {
      final parentPath = entry.path.substring(0, entry.path.lastIndexOf('/'));
      final newPath = parentPath.isEmpty ? '/$newName' : '$parentPath/$newName';
      await _service.rename(session, entry.path, newPath);
      _setStatus('Renamed to $newName', false);
      _refreshPanel(isLeft);
    } catch (e) { _setStatus('Rename failed: $e', true); }
  }

  void _newFolderRemote(bool isLeft) async {
    final session = isLeft ? _leftRemoteSession : _rightRemoteSession;
    if (session == null) return;
    final name = await _showInputDialog('New Folder', '');
    if (name == null || name.isEmpty) return;
    try {
      final base = isLeft ? _leftRemotePath : _rightRemotePath;
      await _service.createDirectory(session, base.endsWith('/') ? '$base$name' : '$base/$name');
      _setStatus('Created folder $name', false);
      _refreshPanel(isLeft);
    } catch (e) { _setStatus('Create folder failed: $e', true); }
  }

  void _compressRemote(RemoteFileEntry entry, bool isLeft) async {
    final session = isLeft ? _leftRemoteSession : _rightRemoteSession;
    if (session == null) return;
    _setStatus('Compressing ${entry.name} on server...', false);
    try {
      await _service.compressRemote(session, entry.path, entry.name);
      _setStatus('Compressed ${entry.name}.tar.gz', false);
      _refreshPanel(isLeft);
    } catch (e) { _setStatus('Compression failed: $e', true); }
  }

  void _extractRemote(RemoteFileEntry entry, bool isLeft) async {
    final session = isLeft ? _leftRemoteSession : _rightRemoteSession;
    if (session == null) return;
    final base = isLeft ? _leftRemotePath : _rightRemotePath;
    _setStatus('Extracting ${entry.name} on server...', false);
    try {
      await _service.extractRemote(session, entry.path, base);
      _setStatus('Extracted ${entry.name}', false);
      _refreshPanel(isLeft);
    } catch (e) { _setStatus('Extract failed: $e', true); }
  }

  // ─── Transfer ──────────────────────────────────────────────────────

  void _uploadFile(File file, bool isLeft) async {
    final otherIsLocal = isLeft ? _rightIsLocal : _leftIsLocal;
    if (otherIsLocal) { _setStatus('Other panel is local, cannot upload', true); return; }
    final session = isLeft ? _rightRemoteSession : _leftRemoteSession;
    final remotePath = isLeft ? _rightRemotePath : _leftRemotePath;
    if (session == null) { _setStatus('Remote not connected', true); return; }
    final name = file.uri.pathSegments.last;
    final fileSize = await file.length();
    final tp = widget.appController.addTransfer(name, fileSize);
    try {
      final bytes = await file.readAsBytes();
      final target = remotePath.endsWith('/') ? '$remotePath$name' : '$remotePath/$name';
      final rf = await session.sftp.open(target, mode: SftpFileOpenMode.create | SftpFileOpenMode.write | SftpFileOpenMode.truncate);
      await rf.writeBytes(bytes);
      await rf.close();
      widget.appController.updateTransfer(tp, transferred: fileSize, complete: true);
      _refreshPanel(!isLeft);
    } catch (e) {
      widget.appController.updateTransfer(tp, error: true, errorMsg: e.toString());
    }
  }

  void _downloadFile(RemoteFileEntry entry, bool isLeft) async {
    final otherIsLocal = isLeft ? _rightIsLocal : _leftIsLocal;
    if (!otherIsLocal) { _setStatus('Other panel is not local', true); return; }
    final localPath = isLeft ? _rightLocalPath : _leftLocalPath;
    final session = isLeft ? _leftRemoteSession : _rightRemoteSession;
    if (session == null) { _setStatus('Not connected', true); return; }
    final totalSize = entry.size ?? 0;
    final tp = widget.appController.addTransfer(entry.name, totalSize);
    try {
      final rf = await session.sftp.open(entry.path);
      final data = await rf.readBytes();
      await rf.close();
      widget.appController.updateTransfer(tp, transferred: data.length, complete: true);
      await File('$localPath${Platform.pathSeparator}${entry.name}').writeAsBytes(data);
      _refreshPanel(!isLeft);
    } catch (e) {
      widget.appController.updateTransfer(tp, error: true, errorMsg: e.toString());
    }
  }

  // ─── Helpers ───────────────────────────────────────────────────────

  void _goUp(bool isLeft) {
    if (isLeft) {
      if (_leftIsLocal) { final p = Directory(_leftLocalPath).parent; if (p.path != _leftLocalPath) { _leftLocalPath = p.path; _loadLeftLocal(); } }
      else { if (_leftRemotePath != '/') { final idx = _leftRemotePath.lastIndexOf('/'); _leftRemotePath = idx <= 0 ? '/' : _leftRemotePath.substring(0, idx); _refreshLeftRemote(); } }
    } else {
      if (_rightIsLocal) { final p = Directory(_rightLocalPath).parent; if (p.path != _rightLocalPath) { _rightLocalPath = p.path; _loadRightLocal(); } }
      else { if (_rightRemotePath != '/') { final idx = _rightRemotePath.lastIndexOf('/'); _rightRemotePath = idx <= 0 ? '/' : _rightRemotePath.substring(0, idx); _refreshRightRemote(); } }
    }
  }

  void _refreshPanel(bool isLeft) {
    if (isLeft) { _leftIsLocal ? _loadLeftLocal() : _refreshLeftRemote(); }
    else { _rightIsLocal ? _loadRightLocal() : _refreshRightRemote(); }
  }

  void _setStatus(String msg, bool isError) { if (mounted) setState(() { _statusMsg = msg; _statusIsError = isError; }); }

  Future<String?> _showInputDialog(String title, String initial) async {
    final ctrl = TextEditingController(text: initial);
    return showDialog<String>(context: context, builder: (ctx) => ContentDialog(
      title: Text(title),
      content: TextBox(controller: ctrl, autofocus: true),
      actions: [
        Button(onPressed: () => Navigator.pop(ctx), child: Text('Cancel')),
        FilledButton(onPressed: () => Navigator.pop(ctx, ctrl.text.trim()), child: Text('OK')),
      ],
    ));
  }
}

// ─── Panel Header ────────────────────────────────────────────────────

class _PanelHeader extends StatelessWidget {
  const _PanelHeader({required this.isLocal, required this.path, required this.profiles, required this.selectedProfileId, required this.isConnected, required this.onToggleMode, required this.onProfileChanged, required this.onConnect, required this.onUp, required this.onRefresh});
  final bool isLocal; final String path; final List<ConnectionProfile> profiles; final String? selectedProfileId; final bool isConnected;
  final VoidCallback onToggleMode; final ValueChanged<String?> onProfileChanged; final VoidCallback onConnect; final VoidCallback onUp; final VoidCallback onRefresh;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      child: Column(children: [
        Row(children: [
          // Mode toggle
          GestureDetector(
            onTap: onToggleMode,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(color: isLocal ? workbenchSuccess.withValues(alpha: 0.15) : workbenchAccent.withValues(alpha: 0.15), borderRadius: BorderRadius.circular(4)),
              child: Text(isLocal ? 'LOCAL' : 'REMOTE', style: TextStyle(color: isLocal ? workbenchSuccess : workbenchAccent, fontSize: 10, fontWeight: FontWeight.w700, letterSpacing: 0.5)),
            ),
          ),
          const SizedBox(width: 8),
          if (!isLocal) ...[
            Expanded(child: ComboBox<String>(
              value: selectedProfileId, isExpanded: true,
              items: profiles.map((p) => ComboBoxItem<String>(value: p.id, child: Text(p.name, style: const TextStyle(fontSize: 11)))).toList(),
              onChanged: onProfileChanged,
            )),
            const SizedBox(width: 6),
            GestureDetector(onTap: onConnect, child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(color: workbenchAccent, borderRadius: BorderRadius.circular(4)),
              child: Text(isConnected ? 'Refresh' : 'Connect', style: const TextStyle(color: Colors.white, fontSize: 10, fontWeight: FontWeight.w600)),
            )),
          ] else
            Expanded(child: Text(path, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(color: workbenchTextFaint, fontSize: 11))),
          const SizedBox(width: 6),
          GestureDetector(onTap: onUp, child: Icon(FluentIcons.up, size: 12, color: workbenchTextMuted)),
          const SizedBox(width: 6),
          GestureDetector(onTap: onRefresh, child: Icon(FluentIcons.refresh, size: 12, color: workbenchTextMuted)),
        ]),
        if (!isLocal) Padding(
          padding: const EdgeInsets.only(top: 4),
          child: Row(children: [Expanded(child: Text(path, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(color: workbenchTextFaint, fontSize: 11)))]),
        ),
      ]),
    );
  }
}

// ─── Status Bar ──────────────────────────────────────────────────────

class _StatusBar extends StatelessWidget {
  const _StatusBar({required this.msg, required this.isError, required this.onDismiss});
  final String msg; final bool isError; final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(color: isError ? workbenchDanger.withValues(alpha: 0.1) : workbenchSuccess.withValues(alpha: 0.1), borderRadius: BorderRadius.circular(6)),
        child: Row(children: [
          Icon(isError ? FluentIcons.error_badge : FluentIcons.accept, size: 12, color: isError ? workbenchDanger : workbenchSuccess),
          const SizedBox(width: 8),
          Expanded(child: Text(msg, style: TextStyle(color: workbenchText, fontSize: 11))),
          GestureDetector(onTap: onDismiss, child: Icon(FluentIcons.chrome_close, size: 8, color: workbenchTextFaint)),
        ]),
      ),
    );
  }
}

// ─── Context Menu ────────────────────────────────────────────────────

class _CItem {
  _CItem(this.icon, this.label, this.onTap, {this.danger = false});
  final IconData icon; final String label; final VoidCallback onTap; final bool danger;
}

class _CtxMenuWidget extends StatelessWidget {
  const _CtxMenuWidget({required this.items, required this.onDone});
  final List<_CItem> items; final VoidCallback onDone;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 200,
      decoration: BoxDecoration(color: workbenchMenuBg, borderRadius: BorderRadius.circular(8), border: Border.all(color: workbenchBorder, width: 0.5), boxShadow: [BoxShadow(color: workbenchBorder, blurRadius: 20)]),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        for (final item in items) _CtxRow(item: item, onDone: onDone),
      ]),
    );
  }
}

class _CtxRow extends StatefulWidget {
  const _CtxRow({required this.item, required this.onDone});
  final _CItem item; final VoidCallback onDone;
  @override State<_CtxRow> createState() => _CtxRowState();
}

class _CtxRowState extends State<_CtxRow> {
  bool _h = false;
  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      onEnter: (_) => setState(() => _h = true),
      onExit: (_) => setState(() => _h = false),
      child: GestureDetector(
        onTap: () { widget.onDone(); widget.item.onTap(); },
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
          decoration: BoxDecoration(color: _h ? workbenchHover : Colors.transparent, borderRadius: BorderRadius.circular(4)),
          child: Row(children: [
            Icon(widget.item.icon, size: 12, color: widget.item.danger ? workbenchDanger : workbenchTextMuted),
            const SizedBox(width: 8),
            Text(widget.item.label, style: TextStyle(color: widget.item.danger ? workbenchDanger : workbenchText, fontSize: 12)),
          ]),
        ),
      ),
    );
  }
}

// ─── File Row ────────────────────────────────────────────────────────

class _FileRow extends StatefulWidget {
  const _FileRow({required this.name, required this.isDir, required this.selected, this.size, this.modified, this.permissions, required this.onTap, this.onDoubleTap, this.onContextMenu, this.index = 0});
  final String name; final bool isDir; final bool selected; final int? size; final DateTime? modified; final String? permissions;
  final VoidCallback onTap; final VoidCallback? onDoubleTap; final void Function(Offset)? onContextMenu; final int index;
  @override State<_FileRow> createState() => _FileRowState();
}

class _FileRowState extends State<_FileRow> {
  bool _h = false;
  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      onEnter: (_) => setState(() => _h = true),
      onExit: (_) => setState(() => _h = false),
      child: GestureDetector(
        onTap: widget.onTap,
        onDoubleTap: widget.onDoubleTap,
        onSecondaryTapUp: widget.onContextMenu != null ? (d) => widget.onContextMenu!(d.globalPosition) : null,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
          color: widget.selected ? workbenchAccent.withValues(alpha: 0.12) : _h ? workbenchHover : widget.index.isOdd ? workbenchHover : Colors.transparent,
          child: Row(children: [
            Icon(widget.isDir ? FluentIcons.fabric_folder_fill : _fileIcon(widget.name), size: 13, color: widget.isDir ? workbenchWarning : _fileColor(widget.name)),
            const SizedBox(width: 8),
            Expanded(child: Text(widget.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(color: workbenchText, fontSize: 12, fontWeight: widget.isDir ? FontWeight.w500 : FontWeight.w400))),
            if (widget.permissions != null) Padding(
              padding: const EdgeInsets.only(right: 10),
              child: Text(widget.permissions!, style: TextStyle(color: workbenchTextFaint, fontSize: 9, fontFamily: 'monospace')),
            ),
            if (widget.modified != null) Padding(
              padding: const EdgeInsets.only(right: 10),
              child: Text(_fmtDate(widget.modified!), style: TextStyle(color: workbenchTextFaint, fontSize: 10)),
            ),
            SizedBox(width: 60, child: Text(widget.size != null ? _fmt(widget.size!) : widget.isDir ? '<DIR>' : '', textAlign: TextAlign.right, style: TextStyle(color: workbenchTextFaint, fontSize: 10))),
          ]),
        ),
      ),
    );
  }
  String _fmt(int b) { if (b < 1024) return '$b B'; if (b < 1048576) return '${(b / 1024).toStringAsFixed(1)} KB'; if (b < 1073741824) return '${(b / 1048576).toStringAsFixed(1)} MB'; return '${(b / 1073741824).toStringAsFixed(1)} GB'; }
  String _fmtDate(DateTime d) => '${d.day.toString().padLeft(2, '0')}/${d.month.toString().padLeft(2, '0')} ${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';

  static IconData _fileIcon(String name) {
    final ext = name.split('.').last.toLowerCase();
    const map = {
      'sh': FluentIcons.command_prompt, 'py': FluentIcons.code, 'js': FluentIcons.code, 'ts': FluentIcons.code,
      'dart': FluentIcons.code, 'java': FluentIcons.code, 'go': FluentIcons.code, 'rs': FluentIcons.code,
      'html': FluentIcons.globe, 'css': FluentIcons.color, 'json': FluentIcons.code, 'yaml': FluentIcons.settings,
      'yml': FluentIcons.settings, 'xml': FluentIcons.code, 'md': FluentIcons.text_document,
      'txt': FluentIcons.text_document, 'log': FluentIcons.text_document,
      'png': FluentIcons.photo2, 'jpg': FluentIcons.photo2, 'gif': FluentIcons.photo2, 'svg': FluentIcons.photo2,
      'zip': FluentIcons.archive, 'tar': FluentIcons.archive, 'gz': FluentIcons.archive,
      'pdf': FluentIcons.pdf, 'doc': FluentIcons.text_document, 'docx': FluentIcons.text_document,
    };
    return map[ext] ?? FluentIcons.page;
  }

  static Color _fileColor(String name) {
    final ext = name.split('.').last.toLowerCase();
    const codeExts = {'sh', 'py', 'js', 'ts', 'dart', 'java', 'go', 'rs', 'c', 'cpp', 'rb', 'html', 'css', 'json', 'yaml', 'yml', 'xml'};
    const mediaExts = {'png', 'jpg', 'gif', 'svg', 'mp4', 'mp3'};
    const archiveExts = {'zip', 'tar', 'gz', 'rar', '7z'};
    if (codeExts.contains(ext)) return const Color(0xFF61AFEF);
    if (mediaExts.contains(ext)) return const Color(0xFF98C379);
    if (archiveExts.contains(ext)) return const Color(0xFFE5C07B);
    return workbenchTextMuted;
  }
}
