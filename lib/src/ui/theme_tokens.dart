import 'package:flutter/widgets.dart';
import 'package:lifeos_sftp_drive/src/ui/app_theme.dart';
import 'package:xterm/xterm.dart';

// ─── LifeOS Gate – Theme-aware color getters ─────────────────────
// These read from the active AppTheme so all views auto-switch dark/light.
// No view code changes needed — just use workbenchXxx as before.

AppTheme _t = AppTheme.dark; // default, updated by setActiveTheme()

/// Call from app.dart whenever the theme changes
void setActiveTheme(AppTheme theme) => _t = theme;

Color get workbenchBg => _t.bg;
Color get workbenchTopBar => _t.topBar;
Color get workbenchPanel => _t.panel;
Color get workbenchPanelAlt => _t.panelAlt;
Color get workbenchSidebar => _t.bg;
Color get workbenchBorder => _t.border;
Color get workbenchDivider => _t.divider;
Color get workbenchHover => _t.hover;

Color get workbenchAccent => _t.accent;
Color get workbenchAccentSoft => _t.accentSoft;
Color get workbenchSuccess => _t.success;
Color get workbenchDanger => _t.danger;
Color get workbenchWarning => _t.warning;

Color get workbenchText => _t.text;
Color get workbenchTextMuted => _t.textMuted;
Color get workbenchTextFaint => _t.textFaint;
Color get workbenchEditorBg => _t.editorBg;
Color get workbenchEditorGutter => _t.editorGutter;
Color get workbenchMenuBg => _t.menuBg;

const workbenchRadius = Radius.circular(10);

// ─── Shadows (theme-aware) ───────────────────────────────────────────
List<BoxShadow> get cardShadow => _t.isDark
  ? const [BoxShadow(color: Color(0x30000000), blurRadius: 12, offset: Offset(0, 4)), BoxShadow(color: Color(0x10000000), blurRadius: 4, offset: Offset(0, 1))]
  : const [BoxShadow(color: Color(0x18000000), blurRadius: 8, offset: Offset(0, 2)), BoxShadow(color: Color(0x08000000), blurRadius: 3, offset: Offset(0, 1))];
List<BoxShadow> get panelShadow => _t.isDark
  ? const [BoxShadow(color: Color(0x40000000), blurRadius: 20, offset: Offset(0, 6))]
  : const [BoxShadow(color: Color(0x20000000), blurRadius: 12, offset: Offset(0, 3))];
List<BoxShadow> get menuShadow => _t.isDark
  ? const [BoxShadow(color: Color(0x60000000), blurRadius: 24, offset: Offset(0, 8))]
  : const [BoxShadow(color: Color(0x30000000), blurRadius: 16, offset: Offset(0, 4))];

/// Shows a context menu that stays within the window bounds.
/// Only one menu can be open at a time — opening a new one closes the previous.
OverlayEntry? _activeContextMenu;

void showBoundedContextMenu(BuildContext context, Offset globalPos, Widget Function(VoidCallback dismiss) builder, {double menuWidth = 220, double menuHeight = 300}) {
  // Close previous menu if still open
  _activeContextMenu?.remove();
  _activeContextMenu = null;

  final overlay = Overlay.of(context);
  final screen = MediaQuery.of(context).size;
  late OverlayEntry entry;

  double dx = globalPos.dx;
  double dy = globalPos.dy;

  if (dx + menuWidth > screen.width) dx = screen.width - menuWidth - 8;
  if (dy + menuHeight > screen.height) dy = screen.height - menuHeight - 8;
  if (dx < 8) dx = 8;
  if (dy < 8) dy = 8;

  void dismiss() {
    entry.remove();
    if (_activeContextMenu == entry) _activeContextMenu = null;
  }

  entry = OverlayEntry(builder: (_) => GestureDetector(
    behavior: HitTestBehavior.translucent,
    onTap: dismiss,
    onSecondaryTap: dismiss,
    child: Stack(children: [Positioned(left: dx, top: dy, child: builder(dismiss))]),
  ));
  _activeContextMenu = entry;
  overlay.insert(entry);
}

const hostIconOrange = Color(0xFFED6B2F);
const hostIconBlue = Color(0xFF4285F4);
const hostIconTeal = Color(0xFF00BFA5);
const hostIconPurple = Color(0xFF9575CD);

const _hostIconColors = [hostIconOrange, hostIconBlue, hostIconTeal, hostIconPurple];
Color hostIconColorFor(int index) => _hostIconColors[index % _hostIconColors.length];

// ─── Transparency-aware colors ───────────────────────────────────────

/// Call once from a widget that knows the current effect settings.
/// Returns opacity-adjusted background colors.
class TransparentTheme {
  TransparentTheme({required bool effectActive, required double opacity})
    : bg = effectActive
        ? (_t.isDark ? Color.fromRGBO(35, 35, 34, opacity * 0.85) : Color.fromRGBO(245, 243, 240, opacity * 0.85))
        : workbenchBg,
      panelAlt = effectActive
        ? (_t.isDark ? Color.fromRGBO(44, 44, 43, opacity * 0.8) : Color.fromRGBO(255, 255, 255, opacity * 0.8))
        : workbenchPanelAlt,
      sidebar = effectActive
        ? (_t.isDark ? Color.fromRGBO(35, 35, 34, opacity * 0.7) : Color.fromRGBO(240, 238, 235, opacity * 0.7))
        : workbenchSidebar,
      terminalBg = effectActive
        ? (_t.isDark ? Color.fromRGBO(35, 35, 34, opacity * 0.75) : Color.fromRGBO(250, 248, 245, opacity * 0.75))
        : (_t.isDark ? const Color(0xFF232322) : const Color(0xFFF5F3F0)),
      hover = effectActive
        ? (_t.isDark ? Color.fromRGBO(47, 47, 46, opacity * 0.6) : Color.fromRGBO(230, 228, 225, opacity * 0.6))
        : workbenchHover;

  final Color bg;
  final Color panelAlt;
  final Color sidebar;
  final Color terminalBg;
  final Color hover;
}

TerminalTheme buildTerminalTheme({Color? background}) => TerminalTheme(
  cursor: const Color(0xFFFFFFFF),
  selection: const Color(0x40FFFFFF),
  foreground: const Color(0xFFFFFFFF),
  background: background ?? const Color(0xFF232322),
  black: const Color(0xFF232322),
  red: const Color(0xFFFF6B6B),
  green: const Color(0xFF5AF78E),
  yellow: const Color(0xFFF3F99D),
  blue: const Color(0xFF57C7FF),
  magenta: const Color(0xFFFF6AC1),
  cyan: const Color(0xFF9AEDFE),
  white: const Color(0xFFFFFFFF),
  brightBlack: const Color(0xFF666666),
  brightRed: const Color(0xFFFF6B6B),
  brightGreen: const Color(0xFF5AF78E),
  brightYellow: const Color(0xFFF3F99D),
  brightBlue: const Color(0xFF57C7FF),
  brightMagenta: const Color(0xFFFF6AC1),
  brightCyan: const Color(0xFF9AEDFE),
  brightWhite: const Color(0xFFFFFFFF),
  searchHitBackground: const Color(0xFFF3F99D),
  searchHitBackgroundCurrent: const Color(0xFF4DB88A),
  searchHitForeground: const Color(0xFF232322),
);

// Keep backward compat
const terminalTheme = TerminalTheme(
  cursor: Color(0xFFFFFFFF),
  selection: Color(0x40FFFFFF),
  foreground: Color(0xFFFFFFFF),
  background: Color(0xFF232322),
  black: Color(0xFF232322),
  red: Color(0xFFFF6B6B),
  green: Color(0xFF5AF78E),
  yellow: Color(0xFFF3F99D),
  blue: Color(0xFF57C7FF),
  magenta: Color(0xFFFF6AC1),
  cyan: Color(0xFF9AEDFE),
  white: Color(0xFFFFFFFF),
  brightBlack: Color(0xFF666666),
  brightRed: Color(0xFFFF6B6B),
  brightGreen: Color(0xFF5AF78E),
  brightYellow: Color(0xFFF3F99D),
  brightBlue: Color(0xFF57C7FF),
  brightMagenta: Color(0xFFFF6AC1),
  brightCyan: Color(0xFF9AEDFE),
  brightWhite: Color(0xFFFFFFFF),
  searchHitBackground: Color(0xFFF3F99D),
  searchHitBackgroundCurrent: Color(0xFF4DB88A),
  searchHitForeground: Color(0xFF232322),
);
