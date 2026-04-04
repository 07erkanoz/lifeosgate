import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter/material.dart' show DefaultMaterialLocalizations;
import 'package:flutter/widgets.dart' show DefaultWidgetsLocalizations;
import 'package:lifeos_sftp_drive/src/desktop/desktop_shell_controller.dart';
import 'package:lifeos_sftp_drive/src/state/app_controller.dart';
import 'package:lifeos_sftp_drive/src/ui/app_theme.dart';
import 'package:lifeos_sftp_drive/src/ui/home_page.dart';
import 'package:lifeos_sftp_drive/src/ui/theme_tokens.dart';
import 'package:lifeos_sftp_drive/src/utils/platform_utils.dart' as pu;

class LifeOsSftpDriveApp extends StatefulWidget {
  const LifeOsSftpDriveApp({super.key, required this.appController});
  final AppController appController;

  @override
  State<LifeOsSftpDriveApp> createState() => _LifeOsSftpDriveAppState();
}

class _LifeOsSftpDriveAppState extends State<LifeOsSftpDriveApp> {
  DesktopShellController? _desktopShellController;

  AppController get _appController => widget.appController;

  @override
  void initState() {
    super.initState();
    if (pu.isDesktop) {
      _desktopShellController = DesktopShellController(_appController);
      _desktopShellController!.start();
    }
  }

  @override
  void dispose() {
    _desktopShellController?.dispose();
    _appController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _appController,
      builder: (context, _) {
        final isDark = _appController.isDarkMode;
        final appTheme = isDark ? AppTheme.dark : AppTheme.light;
        setActiveTheme(appTheme);
        final accent = const Color(0xFFE86A5E).toAccentColor();
        final useTransparent = pu.isDesktop && _appController.windowEffect != 'none';
        final opacity = _appController.windowOpacity;
        final bgColor = useTransparent
            ? (isDark ? Color.fromRGBO(35, 35, 34, opacity) : Color.fromRGBO(245, 243, 240, opacity))
            : appTheme.bg;

        final themeData = FluentThemeData(
          brightness: isDark ? Brightness.dark : Brightness.light,
          accentColor: accent,
          scaffoldBackgroundColor: bgColor,
          visualDensity: VisualDensity.compact,
          fontFamily: pu.platformFontFamily,
        );

        Widget app = AppTheme.provider(
          theme: appTheme,
          child: FluentApp(
            debugShowCheckedModeBanner: false,
            title: 'LifeOS Gate',
            themeMode: isDark ? ThemeMode.dark : ThemeMode.light,
            color: accent,
            localizationsDelegates: const [
              DefaultMaterialLocalizations.delegate,
              DefaultWidgetsLocalizations.delegate,
            ],
            theme: themeData,
            darkTheme: themeData,
            home: HomePage(appController: _appController),
          ),
        );
        // On Windows, disable the accessibility tree entirely to prevent
        // AXTree crashes caused by window_manager/flutter_acrylic modifying
        // the native window during state transitions (maximize, fullscreen, etc.).
        if (pu.isWindows) {
          app = ExcludeSemantics(child: app);
        }
        return app;
      },
    );
  }
}
