import 'package:fluent_ui/fluent_ui.dart';
import 'package:lifeos_sftp_drive/src/ui/theme_tokens.dart';

/// Inline diff viewer for Edit tool — shows old_string vs new_string.
class AgentDiffViewer extends StatelessWidget {
  const AgentDiffViewer({
    super.key,
    required this.oldText,
    required this.newText,
    this.filePath,
    this.fontSize = 12.0,
  });

  final String oldText;
  final String newText;
  final String? filePath;
  final double fontSize;

  @override
  Widget build(BuildContext context) {
    final oldLines = oldText.split('\n');
    final newLines = newText.split('\n');

    return Container(
      decoration: BoxDecoration(
        color: workbenchEditorBg,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: workbenchBorder.withValues(alpha: 0.5)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (filePath != null)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              decoration: BoxDecoration(
                border: Border(bottom: BorderSide(color: workbenchBorder.withValues(alpha: 0.3))),
              ),
              child: Text(
                filePath!,
                style: TextStyle(
                  fontFamily: 'JetBrains Mono',
                  fontSize: fontSize - 1,
                  color: workbenchTextMuted,
                ),
                overflow: TextOverflow.ellipsis,
              ),
            ),
          Padding(
            padding: const EdgeInsets.all(8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (final line in oldLines)
                  _DiffLine(text: line, type: _DiffType.removed, fontSize: fontSize),
                for (final line in newLines)
                  _DiffLine(text: line, type: _DiffType.added, fontSize: fontSize),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

enum _DiffType { removed, added, context }

class _DiffLine extends StatelessWidget {
  const _DiffLine({required this.text, required this.type, this.fontSize = 12});
  final String text;
  final _DiffType type;
  final double fontSize;

  @override
  Widget build(BuildContext context) {
    final Color bg;
    final Color textColor;
    final String prefix;
    switch (type) {
      case _DiffType.removed:
        bg = const Color(0x20F44336);
        textColor = const Color(0xFFEF9A9A);
        prefix = '- ';
      case _DiffType.added:
        bg = const Color(0x2066BB6A);
        textColor = const Color(0xFFA5D6A7);
        prefix = '+ ';
      case _DiffType.context:
        bg = Colors.transparent;
        textColor = workbenchTextMuted;
        prefix = '  ';
    }

    return Container(
      width: double.infinity,
      color: bg,
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 1),
      child: Text(
        '$prefix$text',
        style: TextStyle(
          fontFamily: 'JetBrains Mono',
          fontSize: fontSize,
          color: textColor,
          height: 1.5,
        ),
      ),
    );
  }
}
