import 'dart:convert';
import 'dart:io';

import 'package:dartssh2/dartssh2.dart';
import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter/services.dart';
import 'package:lifeos_sftp_drive/src/services/sftp_browser_service.dart';
import 'package:lifeos_sftp_drive/src/ui/theme_tokens.dart';

/// Built-in text editor for local and remote files.
/// Supports syntax highlighting for common file types.
class FileEditorView extends StatefulWidget {
  const FileEditorView({
    super.key,
    required this.fileName,
    required this.initialContent,
    required this.onSave,
    this.readOnly = false,
  });

  final String fileName;
  final String initialContent;
  final Future<void> Function(String content) onSave;
  final bool readOnly;

  @override
  State<FileEditorView> createState() => _FileEditorViewState();
}

class _FileEditorViewState extends State<FileEditorView> {
  late final TextEditingController _ctrl;
  late final ScrollController _scrollCtrl;
  late final FocusNode _focusNode;
  bool _modified = false;
  bool _saving = false;
  String? _error;
  int _lineCount = 1;
  int _cursorLine = 1;
  int _cursorCol = 1;

  @override
  void initState() {
    super.initState();
    _ctrl = TextEditingController(text: widget.initialContent);
    _scrollCtrl = ScrollController();
    _focusNode = FocusNode();
    _lineCount = '\n'.allMatches(widget.initialContent).length + 1;
    _ctrl.addListener(_onTextChanged);
  }

  @override
  void dispose() {
    _ctrl.removeListener(_onTextChanged);
    _ctrl.dispose();
    _scrollCtrl.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  void _onTextChanged() {
    final text = _ctrl.text;
    final newLineCount = '\n'.allMatches(text).length + 1;
    final pos = _ctrl.selection.baseOffset;
    int line = 1, col = 1;
    if (pos >= 0 && pos <= text.length) {
      line = '\n'.allMatches(text.substring(0, pos)).length + 1;
      final lastNewline = text.lastIndexOf('\n', pos > 0 ? pos - 1 : 0);
      col = pos - (lastNewline == -1 ? 0 : lastNewline + 1) + 1;
    }

    if (newLineCount != _lineCount || line != _cursorLine || col != _cursorCol) {
      setState(() {
        _lineCount = newLineCount;
        _cursorLine = line;
        _cursorCol = col;
        _modified = _ctrl.text != widget.initialContent;
      });
    } else if (!_modified && _ctrl.text != widget.initialContent) {
      setState(() => _modified = true);
    }
  }

  Future<void> _save() async {
    if (_saving) return;
    setState(() { _saving = true; _error = null; });
    try {
      await widget.onSave(_ctrl.text);
      setState(() { _modified = false; _saving = false; });
    } catch (e) {
      setState(() { _error = e.toString(); _saving = false; });
    }
  }

  String get _fileType {
    final ext = widget.fileName.split('.').last.toLowerCase();
    const typeMap = {
      'sh': 'Shell', 'bash': 'Shell', 'zsh': 'Shell',
      'py': 'Python', 'js': 'JavaScript', 'ts': 'TypeScript',
      'dart': 'Dart', 'rs': 'Rust', 'go': 'Go', 'rb': 'Ruby',
      'java': 'Java', 'kt': 'Kotlin', 'swift': 'Swift',
      'c': 'C', 'cpp': 'C++', 'h': 'C Header',
      'html': 'HTML', 'css': 'CSS', 'scss': 'SCSS',
      'json': 'JSON', 'yaml': 'YAML', 'yml': 'YAML',
      'xml': 'XML', 'toml': 'TOML', 'ini': 'INI',
      'md': 'Markdown', 'txt': 'Text',
      'sql': 'SQL', 'dockerfile': 'Dockerfile',
      'conf': 'Config', 'cfg': 'Config', 'env': 'Env',
      'log': 'Log', 'csv': 'CSV',
    };
    return typeMap[ext] ?? 'Text';
  }

  @override
  Widget build(BuildContext context) {
    return Column(children: [
      // ─── Editor Header ──────────────────────────────────────
      Container(
        height: 40, padding: const EdgeInsets.symmetric(horizontal: 14),
        decoration: BoxDecoration(border: Border(bottom: BorderSide(color: workbenchDivider, width: 0.5))),
        child: Row(children: [
          Icon(FluentIcons.edit_note, size: 13, color: workbenchAccent),
          const SizedBox(width: 8),
          Expanded(child: Row(children: [
            Text(widget.fileName, style: TextStyle(color: workbenchText, fontSize: 13, fontWeight: FontWeight.w600)),
            if (_modified) ...[
              const SizedBox(width: 6),
              Container(width: 8, height: 8, decoration: BoxDecoration(color: workbenchWarning, shape: BoxShape.circle)),
            ],
          ])),
          // File type badge
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
            decoration: BoxDecoration(color: workbenchHover, borderRadius: BorderRadius.circular(4)),
            child: Text(_fileType, style: TextStyle(color: workbenchTextMuted, fontSize: 10)),
          ),
          const SizedBox(width: 8),
          // Cursor position
          Text('Ln $_cursorLine, Col $_cursorCol', style: TextStyle(color: workbenchTextFaint, fontSize: 10)),
          const SizedBox(width: 8),
          Text('$_lineCount lines', style: TextStyle(color: workbenchTextFaint, fontSize: 10)),
          const SizedBox(width: 12),
          // Save button
          if (!widget.readOnly)
            GestureDetector(
              onTap: _modified ? _save : null,
              child: Container(
                height: 28, padding: const EdgeInsets.symmetric(horizontal: 14),
                decoration: BoxDecoration(
                  color: _modified ? workbenchAccent : workbenchHover,
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Center(child: _saving
                  ? const SizedBox(width: 12, height: 12, child: ProgressRing(strokeWidth: 2))
                  : Row(mainAxisSize: MainAxisSize.min, children: [
                      Icon(FluentIcons.save, size: 11, color: _modified ? Colors.white : workbenchTextFaint),
                      const SizedBox(width: 5),
                      Text('Ctrl+S', style: TextStyle(color: _modified ? Colors.white : workbenchTextFaint, fontSize: 10, fontWeight: FontWeight.w500)),
                    ]),
                ),
              ),
            ),
        ]),
      ),

      // ─── Error Bar ──────────────────────────────────────────
      if (_error != null) Container(
        width: double.infinity, padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
        color: workbenchDanger.withValues(alpha: 0.08),
        child: Row(children: [
          Icon(FluentIcons.error_badge, size: 11, color: workbenchDanger),
          const SizedBox(width: 8),
          Expanded(child: Text(_error!, style: TextStyle(color: workbenchDanger, fontSize: 11))),
          GestureDetector(onTap: () => setState(() => _error = null), child: Icon(FluentIcons.chrome_close, size: 9, color: workbenchTextFaint)),
        ]),
      ),

      // ─── Editor Body ────────────────────────────────────────
      Expanded(
        child: Shortcuts(
          shortcuts: {LogicalKeySet(LogicalKeyboardKey.control, LogicalKeyboardKey.keyS): const _SaveIntent()},
          child: Actions(
            actions: {_SaveIntent: CallbackAction<_SaveIntent>(onInvoke: (_) { _save(); return null; })},
            child: Container(
              color: workbenchEditorBg,
              child: Row(children: [
                // Line numbers gutter
                Container(
                  width: 48, padding: const EdgeInsets.only(top: 10),
                  color: workbenchEditorGutter,
                  child: ListView.builder(
                    controller: _scrollCtrl,
                    itemCount: _lineCount,
                    itemExtent: 20,
                    itemBuilder: (_, i) => Container(
                      height: 20, alignment: Alignment.centerRight,
                      padding: const EdgeInsets.only(right: 10),
                      child: Text('${i + 1}', style: TextStyle(
                        color: (i + 1) == _cursorLine ? workbenchText : workbenchTextFaint,
                        fontSize: 12, fontFamily: 'monospace',
                      )),
                    ),
                  ),
                ),
                Container(width: 1, color: workbenchBorder),
                // Text editor
                Expanded(
                  child: TextBox(
                    controller: _ctrl,
                    focusNode: _focusNode,
                    maxLines: null,
                    expands: true,
                    readOnly: widget.readOnly,
                    style: TextStyle(color: workbenchText, fontSize: 13, fontFamily: 'monospace', height: 1.54),
                    padding: const EdgeInsets.all(10),
                    decoration: WidgetStateProperty.all(BoxDecoration(color: workbenchEditorBg)),
                  ),
                ),
              ]),
            ),
          ),
        ),
      ),

      // ─── Status Bar ─────────────────────────────────────────
      Container(
        height: 24, padding: const EdgeInsets.symmetric(horizontal: 14),
        decoration: BoxDecoration(
          color: workbenchEditorGutter,
          border: Border(top: BorderSide(color: workbenchDivider, width: 0.5)),
        ),
        child: Row(children: [
          Text(widget.readOnly ? 'READ ONLY' : (_modified ? 'MODIFIED' : 'SAVED'),
            style: TextStyle(color: _modified ? workbenchWarning : workbenchSuccess, fontSize: 9, fontWeight: FontWeight.w600)),
          const Spacer(),
          Text('UTF-8', style: TextStyle(color: workbenchTextFaint, fontSize: 9)),
          const SizedBox(width: 12),
          Text(_fileType, style: TextStyle(color: workbenchTextFaint, fontSize: 9)),
        ]),
      ),
    ]);
  }
}

class _SaveIntent extends Intent {
  const _SaveIntent();
}

// ─── Helper: Open file in editor ─────────────────────────────────────

/// Opens a local file in the editor
Future<void> openLocalFileEditor(BuildContext context, String filePath) async {
  final file = File(filePath);
  final fileName = filePath.split(Platform.pathSeparator).last;
  try {
    final content = await file.readAsString();
    if (!context.mounted) return;
    await showDialog(
      context: context,
      builder: (ctx) => _EditorDialog(
        fileName: fileName,
        initialContent: content,
        onSave: (newContent) => file.writeAsString(newContent),
      ),
    );
  } catch (e) {
    if (!context.mounted) return;
    await showDialog(context: context, builder: (ctx) => ContentDialog(
      title: Text('Error'),
      content: Text('Cannot open file: $e'),
      actions: [Button(onPressed: () => Navigator.pop(ctx), child: Text('OK'))],
    ));
  }
}

/// Opens a remote file in the editor via SFTP
Future<void> openRemoteFileEditor(BuildContext context, SftpConnectionSession session, String remotePath) async {
  final fileName = remotePath.split('/').last;
  try {
    final rf = await session.sftp.open(remotePath);
    final data = await rf.readBytes();
    await rf.close();
    final content = utf8.decode(data, allowMalformed: true);
    if (!context.mounted) return;
    await showDialog(
      context: context,
      builder: (ctx) => _EditorDialog(
        fileName: fileName,
        initialContent: content,
        onSave: (newContent) async {
          final wf = await session.sftp.open(remotePath, mode: SftpFileOpenMode.create | SftpFileOpenMode.write | SftpFileOpenMode.truncate);
          await wf.writeBytes(utf8.encode(newContent));
          await wf.close();
        },
      ),
    );
  } catch (e) {
    if (!context.mounted) return;
    await showDialog(context: context, builder: (ctx) => ContentDialog(
      title: Text('Error'),
      content: Text('Cannot open remote file: $e'),
      actions: [Button(onPressed: () => Navigator.pop(ctx), child: Text('OK'))],
    ));
  }
}

class _EditorDialog extends StatelessWidget {
  const _EditorDialog({required this.fileName, required this.initialContent, required this.onSave});
  final String fileName; final String initialContent; final Future<void> Function(String) onSave;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Container(
        width: MediaQuery.of(context).size.width * 0.85,
        height: MediaQuery.of(context).size.height * 0.85,
        decoration: BoxDecoration(
          color: workbenchEditorBg,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: workbenchBorder, width: 1),
          boxShadow: const [BoxShadow(color: Color(0x80000000), blurRadius: 40)],
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(12),
          child: Column(children: [
            // Dialog top bar with close
            Container(
              height: 36, padding: const EdgeInsets.symmetric(horizontal: 12),
              decoration: BoxDecoration(color: workbenchEditorGutter),
              child: Row(children: [
                const Spacer(),
                GestureDetector(
                  onTap: () => Navigator.pop(context),
                  child: Container(
                    width: 24, height: 24,
                    decoration: BoxDecoration(color: workbenchHover, borderRadius: BorderRadius.circular(4)),
                    child: Icon(FluentIcons.chrome_close, size: 10, color: workbenchTextMuted),
                  ),
                ),
              ]),
            ),
            Expanded(child: FileEditorView(
              fileName: fileName,
              initialContent: initialContent,
              onSave: onSave,
            )),
          ]),
        ),
      ),
    );
  }
}
