import 'package:flutter/widgets.dart';
import 'package:xterm/xterm.dart';

class TerminalColorScheme {
  const TerminalColorScheme({
    required this.name,
    required this.background,
    required this.foreground,
    required this.cursor,
    required this.selection,
    required this.black,
    required this.red,
    required this.green,
    required this.yellow,
    required this.blue,
    required this.magenta,
    required this.cyan,
    required this.white,
    required this.brightBlack,
    required this.brightRed,
    required this.brightGreen,
    required this.brightYellow,
    required this.brightBlue,
    required this.brightMagenta,
    required this.brightCyan,
    required this.brightWhite,
  });

  final String name;
  final Color background, foreground, cursor, selection;
  final Color black, red, green, yellow, blue, magenta, cyan, white;
  final Color brightBlack, brightRed, brightGreen, brightYellow, brightBlue, brightMagenta, brightCyan, brightWhite;

  TerminalTheme toTheme({Color? backgroundOverride}) => TerminalTheme(
    cursor: cursor, selection: selection,
    foreground: foreground, background: backgroundOverride ?? background,
    black: black, red: red, green: green, yellow: yellow,
    blue: blue, magenta: magenta, cyan: cyan, white: white,
    brightBlack: brightBlack, brightRed: brightRed, brightGreen: brightGreen, brightYellow: brightYellow,
    brightBlue: brightBlue, brightMagenta: brightMagenta, brightCyan: brightCyan, brightWhite: brightWhite,
    searchHitBackground: yellow, searchHitBackgroundCurrent: green, searchHitForeground: black,
  );
}

// ─── Theme Definitions ───────────────────────────────────────────────

const terminalSchemes = <String, TerminalColorScheme>{
  'LifeOS Gate': _lifeos,
  'Dracula': _dracula,
  'Monokai': _monokai,
  'Nord': _nord,
  'Solarized Dark': _solarizedDark,
  'One Dark': _oneDark,
  'Tokyo Night': _tokyoNight,
  'Catppuccin Mocha': _catppuccin,
  'Gruvbox Dark': _gruvbox,
  // Light themes
  'LifeOS Light': _lifeosLight,
  'Solarized Light': _solarizedLight,
  'GitHub Light': _githubLight,
  'One Light': _oneLight,
  'Catppuccin Latte': _catppuccinLatte,
};

const _lifeos = TerminalColorScheme(
  name: 'LifeOS Gate',
  background: Color(0xFF232322), foreground: Color(0xFFFFFFFF),
  cursor: Color(0xFFFFFFFF), selection: Color(0x40FFFFFF),
  black: Color(0xFF232322), red: Color(0xFFFF6B6B), green: Color(0xFF5AF78E), yellow: Color(0xFFF3F99D),
  blue: Color(0xFF57C7FF), magenta: Color(0xFFFF6AC1), cyan: Color(0xFF9AEDFE), white: Color(0xFFFFFFFF),
  brightBlack: Color(0xFF666666), brightRed: Color(0xFFFF6B6B), brightGreen: Color(0xFF5AF78E), brightYellow: Color(0xFFF3F99D),
  brightBlue: Color(0xFF57C7FF), brightMagenta: Color(0xFFFF6AC1), brightCyan: Color(0xFF9AEDFE), brightWhite: Color(0xFFFFFFFF),
);

const _dracula = TerminalColorScheme(
  name: 'Dracula',
  background: Color(0xFF282A36), foreground: Color(0xFFF8F8F2),
  cursor: Color(0xFFF8F8F2), selection: Color(0x4044475A),
  black: Color(0xFF21222C), red: Color(0xFFFF5555), green: Color(0xFF50FA7B), yellow: Color(0xFFF1FA8C),
  blue: Color(0xFFBD93F9), magenta: Color(0xFFFF79C6), cyan: Color(0xFF8BE9FD), white: Color(0xFFF8F8F2),
  brightBlack: Color(0xFF6272A4), brightRed: Color(0xFFFF6E6E), brightGreen: Color(0xFF69FF94), brightYellow: Color(0xFFFFFFA5),
  brightBlue: Color(0xFFD6ACFF), brightMagenta: Color(0xFFFF92DF), brightCyan: Color(0xFFA4FFFF), brightWhite: Color(0xFFFFFFFF),
);

const _monokai = TerminalColorScheme(
  name: 'Monokai',
  background: Color(0xFF272822), foreground: Color(0xFFF8F8F2),
  cursor: Color(0xFFF8F8F0), selection: Color(0x4049483E),
  black: Color(0xFF272822), red: Color(0xFFF92672), green: Color(0xFFA6E22E), yellow: Color(0xFFF4BF75),
  blue: Color(0xFF66D9EF), magenta: Color(0xFFAE81FF), cyan: Color(0xFFA1EFE4), white: Color(0xFFF8F8F2),
  brightBlack: Color(0xFF75715E), brightRed: Color(0xFFF92672), brightGreen: Color(0xFFA6E22E), brightYellow: Color(0xFFF4BF75),
  brightBlue: Color(0xFF66D9EF), brightMagenta: Color(0xFFAE81FF), brightCyan: Color(0xFFA1EFE4), brightWhite: Color(0xFFF9F8F5),
);

const _nord = TerminalColorScheme(
  name: 'Nord',
  background: Color(0xFF2E3440), foreground: Color(0xFFD8DEE9),
  cursor: Color(0xFFD8DEE9), selection: Color(0x404C566A),
  black: Color(0xFF3B4252), red: Color(0xFFBF616A), green: Color(0xFFA3BE8C), yellow: Color(0xFFEBCB8B),
  blue: Color(0xFF81A1C1), magenta: Color(0xFFB48EAD), cyan: Color(0xFF88C0D0), white: Color(0xFFE5E9F0),
  brightBlack: Color(0xFF4C566A), brightRed: Color(0xFFBF616A), brightGreen: Color(0xFFA3BE8C), brightYellow: Color(0xFFEBCB8B),
  brightBlue: Color(0xFF81A1C1), brightMagenta: Color(0xFFB48EAD), brightCyan: Color(0xFF8FBCBB), brightWhite: Color(0xFFECEFF4),
);

const _solarizedDark = TerminalColorScheme(
  name: 'Solarized Dark',
  background: Color(0xFF002B36), foreground: Color(0xFF839496),
  cursor: Color(0xFF839496), selection: Color(0x40073642),
  black: Color(0xFF073642), red: Color(0xFFDC322F), green: Color(0xFF859900), yellow: Color(0xFFB58900),
  blue: Color(0xFF268BD2), magenta: Color(0xFFD33682), cyan: Color(0xFF2AA198), white: Color(0xFFEEE8D5),
  brightBlack: Color(0xFF586E75), brightRed: Color(0xFFCB4B16), brightGreen: Color(0xFF586E75), brightYellow: Color(0xFF657B83),
  brightBlue: Color(0xFF839496), brightMagenta: Color(0xFF6C71C4), brightCyan: Color(0xFF93A1A1), brightWhite: Color(0xFFFDF6E3),
);

const _oneDark = TerminalColorScheme(
  name: 'One Dark',
  background: Color(0xFF282C34), foreground: Color(0xFFABB2BF),
  cursor: Color(0xFF528BFF), selection: Color(0x403E4451),
  black: Color(0xFF282C34), red: Color(0xFFE06C75), green: Color(0xFF98C379), yellow: Color(0xFFE5C07B),
  blue: Color(0xFF61AFEF), magenta: Color(0xFFC678DD), cyan: Color(0xFF56B6C2), white: Color(0xFFABB2BF),
  brightBlack: Color(0xFF5C6370), brightRed: Color(0xFFE06C75), brightGreen: Color(0xFF98C379), brightYellow: Color(0xFFE5C07B),
  brightBlue: Color(0xFF61AFEF), brightMagenta: Color(0xFFC678DD), brightCyan: Color(0xFF56B6C2), brightWhite: Color(0xFFFFFFFF),
);

const _tokyoNight = TerminalColorScheme(
  name: 'Tokyo Night',
  background: Color(0xFF1A1B26), foreground: Color(0xFFC0CAF5),
  cursor: Color(0xFFC0CAF5), selection: Color(0x40283457),
  black: Color(0xFF15161E), red: Color(0xFFF7768E), green: Color(0xFF9ECE6A), yellow: Color(0xFFE0AF68),
  blue: Color(0xFF7AA2F7), magenta: Color(0xFFBB9AF7), cyan: Color(0xFF7DCFFF), white: Color(0xFFA9B1D6),
  brightBlack: Color(0xFF414868), brightRed: Color(0xFFF7768E), brightGreen: Color(0xFF9ECE6A), brightYellow: Color(0xFFE0AF68),
  brightBlue: Color(0xFF7AA2F7), brightMagenta: Color(0xFFBB9AF7), brightCyan: Color(0xFF7DCFFF), brightWhite: Color(0xFFC0CAF5),
);

const _catppuccin = TerminalColorScheme(
  name: 'Catppuccin Mocha',
  background: Color(0xFF1E1E2E), foreground: Color(0xFFCDD6F4),
  cursor: Color(0xFFF5E0DC), selection: Color(0x40585B70),
  black: Color(0xFF45475A), red: Color(0xFFF38BA8), green: Color(0xFFA6E3A1), yellow: Color(0xFFF9E2AF),
  blue: Color(0xFF89B4FA), magenta: Color(0xFFF5C2E7), cyan: Color(0xFF94E2D5), white: Color(0xFFBAC2DE),
  brightBlack: Color(0xFF585B70), brightRed: Color(0xFFF38BA8), brightGreen: Color(0xFFA6E3A1), brightYellow: Color(0xFFF9E2AF),
  brightBlue: Color(0xFF89B4FA), brightMagenta: Color(0xFFF5C2E7), brightCyan: Color(0xFF94E2D5), brightWhite: Color(0xFFA6ADC8),
);

const _gruvbox = TerminalColorScheme(
  name: 'Gruvbox Dark',
  background: Color(0xFF282828), foreground: Color(0xFFEBDBB2),
  cursor: Color(0xFFEBDBB2), selection: Color(0x403C3836),
  black: Color(0xFF282828), red: Color(0xFFCC241D), green: Color(0xFF98971A), yellow: Color(0xFFD79921),
  blue: Color(0xFF458588), magenta: Color(0xFFB16286), cyan: Color(0xFF689D6A), white: Color(0xFFA89984),
  brightBlack: Color(0xFF928374), brightRed: Color(0xFFFB4934), brightGreen: Color(0xFFB8BB26), brightYellow: Color(0xFFFABD2F),
  brightBlue: Color(0xFF83A598), brightMagenta: Color(0xFFD3869B), brightCyan: Color(0xFF8EC07C), brightWhite: Color(0xFFEBDBB2),
);

// ─── Light Themes ────────────────────────────────────────────────────

const _lifeosLight = TerminalColorScheme(
  name: 'LifeOS Light',
  background: Color(0xFFFCFBFA), foreground: Color(0xFF2C2C2C),
  cursor: Color(0xFF2C2C2C), selection: Color(0x30E86A5E),
  black: Color(0xFF2C2C2C), red: Color(0xFFD94452), green: Color(0xFF3BA676), yellow: Color(0xFFCB8A14),
  blue: Color(0xFF2B6CB0), magenta: Color(0xFF9B59B6), cyan: Color(0xFF1ABC9C), white: Color(0xFFF5F3F0),
  brightBlack: Color(0xFF7A7572), brightRed: Color(0xFFE74C3C), brightGreen: Color(0xFF27AE60), brightYellow: Color(0xFFE67E22),
  brightBlue: Color(0xFF3498DB), brightMagenta: Color(0xFFAF7AC5), brightCyan: Color(0xFF1ABC9C), brightWhite: Color(0xFFFFFFFF),
);

const _solarizedLight = TerminalColorScheme(
  name: 'Solarized Light',
  background: Color(0xFFFDF6E3), foreground: Color(0xFF657B83),
  cursor: Color(0xFF657B83), selection: Color(0x30268BD2),
  black: Color(0xFF073642), red: Color(0xFFDC322F), green: Color(0xFF859900), yellow: Color(0xFFB58900),
  blue: Color(0xFF268BD2), magenta: Color(0xFFD33682), cyan: Color(0xFF2AA198), white: Color(0xFFEEE8D5),
  brightBlack: Color(0xFF586E75), brightRed: Color(0xFFCB4B16), brightGreen: Color(0xFF586E75), brightYellow: Color(0xFF657B83),
  brightBlue: Color(0xFF839496), brightMagenta: Color(0xFF6C71C4), brightCyan: Color(0xFF93A1A1), brightWhite: Color(0xFFFDF6E3),
);

const _githubLight = TerminalColorScheme(
  name: 'GitHub Light',
  background: Color(0xFFFFFFFF), foreground: Color(0xFF24292E),
  cursor: Color(0xFF24292E), selection: Color(0x300366D6),
  black: Color(0xFF24292E), red: Color(0xFFD73A49), green: Color(0xFF22863A), yellow: Color(0xFFB08800),
  blue: Color(0xFF0366D6), magenta: Color(0xFF6F42C1), cyan: Color(0xFF1B7C83), white: Color(0xFFF6F8FA),
  brightBlack: Color(0xFF586069), brightRed: Color(0xFFCB2431), brightGreen: Color(0xFF28A745), brightYellow: Color(0xFFDBAB09),
  brightBlue: Color(0xFF2188FF), brightMagenta: Color(0xFF8A63D2), brightCyan: Color(0xFF3192AA), brightWhite: Color(0xFFFFFFFF),
);

const _oneLight = TerminalColorScheme(
  name: 'One Light',
  background: Color(0xFFFAFAFA), foreground: Color(0xFF383A42),
  cursor: Color(0xFF526FFF), selection: Color(0x30526FFF),
  black: Color(0xFF383A42), red: Color(0xFFE45649), green: Color(0xFF50A14F), yellow: Color(0xFFC18401),
  blue: Color(0xFF4078F2), magenta: Color(0xFFA626A4), cyan: Color(0xFF0184BC), white: Color(0xFFA0A1A7),
  brightBlack: Color(0xFF696C77), brightRed: Color(0xFFE45649), brightGreen: Color(0xFF50A14F), brightYellow: Color(0xFFC18401),
  brightBlue: Color(0xFF4078F2), brightMagenta: Color(0xFFA626A4), brightCyan: Color(0xFF0184BC), brightWhite: Color(0xFFFFFFFF),
);

const _catppuccinLatte = TerminalColorScheme(
  name: 'Catppuccin Latte',
  background: Color(0xFFEFF1F5), foreground: Color(0xFF4C4F69),
  cursor: Color(0xFFDC8A78), selection: Color(0x30DC8A78),
  black: Color(0xFF5C5F77), red: Color(0xFFD20F39), green: Color(0xFF40A02B), yellow: Color(0xFFDF8E1D),
  blue: Color(0xFF1E66F5), magenta: Color(0xFFEA76CB), cyan: Color(0xFF179299), white: Color(0xFFACB0BE),
  brightBlack: Color(0xFF6C6F85), brightRed: Color(0xFFD20F39), brightGreen: Color(0xFF40A02B), brightYellow: Color(0xFFDF8E1D),
  brightBlue: Color(0xFF1E66F5), brightMagenta: Color(0xFFEA76CB), brightCyan: Color(0xFF179299), brightWhite: Color(0xFFDCE0E8),
);
