import 'package:flutter/widgets.dart';

/// Application-wide theme that provides colors for both dark and light modes.
/// Access via `AppTheme.of(context)` or `AppTheme.dark` / `AppTheme.light`.
class AppTheme {
  const AppTheme({
    required this.isDark,
    required this.bg,
    required this.topBar,
    required this.panel,
    required this.panelAlt,
    required this.border,
    required this.divider,
    required this.hover,
    required this.accent,
    required this.accentSoft,
    required this.success,
    required this.danger,
    required this.warning,
    required this.text,
    required this.textMuted,
    required this.textFaint,
    required this.editorBg,
    required this.editorGutter,
    required this.cardShadow,
    required this.menuBg,
  });

  final bool isDark;
  final Color bg, topBar, panel, panelAlt, border, divider, hover;
  final Color accent, accentSoft, success, danger, warning;
  final Color text, textMuted, textFaint;
  final Color editorBg, editorGutter, menuBg;
  final List<BoxShadow> cardShadow;

  // ─── Dark Theme ────────────────────────────────────────────────
  static const dark = AppTheme(
    isDark: true,
    bg: Color(0xFF232322),
    topBar: Color(0xFF232322),
    panel: Color(0xFF232322),
    panelAlt: Color(0xD02C2C2B),
    border: Color(0xFF3A3A38),
    divider: Color(0xFF2C2C2B),
    hover: Color(0xC02F2F2E),
    accent: Color(0xFFE86A5E),
    accentSoft: Color(0x40E86A5E),
    success: Color(0xFF4DB88A),
    danger: Color(0xFFE06C75),
    warning: Color(0xFFE5C07B),
    text: Color(0xFFFFFFFF),
    textMuted: Color(0xFFAAAAAA),
    textFaint: Color(0xFF666666),
    editorBg: Color(0xFF1A1B22),
    editorGutter: Color(0xFF16171D),
    menuBg: Color(0xFF2C2C2B),
    cardShadow: [
      BoxShadow(color: Color(0x30000000), blurRadius: 12, offset: Offset(0, 4)),
      BoxShadow(color: Color(0x10000000), blurRadius: 4, offset: Offset(0, 1)),
    ],
  );

  // ─── Light Theme ───────────────────────────────────────────────
  // Mat, pürüzsüz, göz yormayan sıcak tonlar
  static const light = AppTheme(
    isDark: false,
    bg: Color(0xFFF5F3F0),          // warm off-white
    topBar: Color(0xFFFFFFFF),
    panel: Color(0xFFF5F3F0),
    panelAlt: Color(0xFFFFFFFF),
    border: Color(0xFFE2DDD8),       // warm gray border
    divider: Color(0xFFEBE7E3),
    hover: Color(0xFFEDE9E5),
    accent: Color(0xFFE86A5E),       // same accent
    accentSoft: Color(0x20E86A5E),
    success: Color(0xFF3BA676),
    danger: Color(0xFFD94452),
    warning: Color(0xFFCB8A14),
    text: Color(0xFF2C2C2C),         // dark charcoal text
    textMuted: Color(0xFF7A7572),    // warm muted
    textFaint: Color(0xFFB0AAA4),    // warm faint
    editorBg: Color(0xFFFCFBFA),
    editorGutter: Color(0xFFF2EFEC),
    menuBg: Color(0xFFFFFFFF),
    cardShadow: [
      BoxShadow(color: Color(0x15000000), blurRadius: 12, offset: Offset(0, 4)),
      BoxShadow(color: Color(0x08000000), blurRadius: 4, offset: Offset(0, 1)),
    ],
  );

  /// Provide theme via InheritedWidget
  static AppTheme of(BuildContext context) {
    final inherited = context.dependOnInheritedWidgetOfExactType<_AppThemeInherited>();
    return inherited?.theme ?? dark;
  }

  static Widget provider({required AppTheme theme, required Widget child}) {
    return _AppThemeInherited(theme: theme, child: child);
  }
}

class _AppThemeInherited extends InheritedWidget {
  const _AppThemeInherited({required this.theme, required super.child});
  final AppTheme theme;

  @override
  bool updateShouldNotify(_AppThemeInherited old) => theme.isDark != old.theme.isDark;
}
