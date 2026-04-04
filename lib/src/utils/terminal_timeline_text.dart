class TerminalTimelineText {
  TerminalTimelineText._();

  static final RegExp _ansiCsi = RegExp(r'\x1B\[[0-?]*[ -/]*[@-~]');
  static final RegExp _ansiOsc = RegExp(r'\x1B\][^\x1B\x07]*(?:\x07|\x1B\\)');
  static final RegExp _ansiSingle = RegExp(r'\x1B[@-_]');
  static final RegExp _controlChars = RegExp(
    r'[\x00-\x08\x0B\x0C\x0E-\x1F\x7F]',
  );
  static final RegExp _multiSpaces = RegExp(r'[ \t]{2,}');
  static final RegExp _multiBreaks = RegExp(r'\n{3,}');
  static final RegExp _allBreaks = RegExp(r'[\r\n]+');

  static String sanitizeOutput(String input) {
    var value = _stripAnsiAndNoise(input).replaceAll('\r', '');
    value = value.replaceAll(_multiBreaks, '\n\n');
    return value.trimRight();
  }

  static String sanitizeMessage(String input) {
    var value = _stripAnsiAndNoise(input).replaceAll('\r', '');
    value = value.replaceAll(_multiBreaks, '\n\n');
    return value.trim();
  }

  static String sanitizeCommand(String input) {
    final value = sanitizeMessage(
      input,
    ).replaceAll(_allBreaks, ' ').replaceAll(_multiSpaces, ' ').trim();
    return value;
  }

  static String _stripAnsiAndNoise(String input) {
    return input
        .replaceAll('\uFFFD', '')
        .replaceAll(_ansiOsc, '')
        .replaceAll(_ansiCsi, '')
        .replaceAll(_ansiSingle, '')
        .replaceAll(_controlChars, '');
  }
}
