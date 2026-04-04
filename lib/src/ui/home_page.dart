import 'dart:async';

import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter/services.dart'
    show
        KeyDownEvent,
        LogicalKeySet,
        LogicalKeyboardKey,
        SystemMouseCursor,
        SystemMouseCursors;
import 'package:lifeos_sftp_drive/src/i18n/app_strings.dart';
import 'package:lifeos_sftp_drive/src/models/connection_profile.dart';
import 'package:lifeos_sftp_drive/src/models/log_entry.dart';
import 'package:lifeos_sftp_drive/src/state/app_controller.dart';
import 'package:lifeos_sftp_drive/src/services/android_reconnect_notification_service.dart';
import 'package:lifeos_sftp_drive/src/terminal/local_terminal_controller.dart';
import 'package:lifeos_sftp_drive/src/terminal/ssh_terminal_controller.dart';
import 'package:lifeos_sftp_drive/src/ui/app_theme.dart';
import 'package:lifeos_sftp_drive/src/ui/theme_tokens.dart';
import 'package:lifeos_sftp_drive/src/ui/views/browser_view.dart';
import 'package:lifeos_sftp_drive/src/ui/views/dashboard_view.dart';
import 'package:lifeos_sftp_drive/src/ui/views/agent_workbench_view.dart';
import 'package:lifeos_sftp_drive/src/ui/views/local_terminal_view.dart';
import 'package:lifeos_sftp_drive/src/ui/views/settings_view.dart';
import 'package:lifeos_sftp_drive/src/ui/views/terminal_workbench_view.dart';
import 'package:lifeos_sftp_drive/src/ui/views/vaults_workbench_view.dart';
import 'package:lifeos_sftp_drive/src/ui/widgets/connection_dialog.dart';
import 'package:lifeos_sftp_drive/src/utils/platform_utils.dart' as pu;
import 'package:window_manager/window_manager.dart';

class HomePage extends StatefulWidget {
  const HomePage({super.key, required this.appController});
  final AppController appController;
  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> with WindowListener {
  late List<_Tab> _tabs;
  bool _showPalette = false;
  final _paletteCtrl = TextEditingController();
  final _paletteFocus = FocusNode();
  StreamSubscription<ReconnectNotificationCommand>? _reconnectCommandSub;

  static const _defaultTerminalId = 'local-default';

  void _initTabs() {
    final s = widget.appController.strings;
    _tabs = [
      // Local terminal first only on desktop (Android has no local shell)
      if (pu.isDesktop)
        _Tab(
          id: _defaultTerminalId,
          kind: _TabKind.localTerminal,
          title: 'Terminal',
          closable: false,
          icon: FluentIcons.command_prompt,
        ),
      _Tab(
        id: 'vaults',
        kind: _TabKind.vaults,
        title: s.isTr ? 'Sunucular' : 'Servers',
        closable: false,
        icon: FluentIcons.server,
      ),
      if (pu.isDesktop)
        _Tab(
          id: 'sftp',
          kind: _TabKind.sftp,
          title: 'SFTP',
          closable: false,
          icon: FluentIcons.open_folder_horizontal,
        ),
      if (pu.isDesktop)
        _Tab(
          id: 'monitor',
          kind: _TabKind.monitor,
          title: 'Monitor',
          closable: false,
          icon: FluentIcons.health,
        ),
      if (widget.appController.agentPageEnabled)
        _Tab(
          id: 'agent',
          kind: _TabKind.agent,
          title: s.isTr ? 'Agent' : 'Agent',
          closable: false,
          icon: FluentIcons.robot,
        ),
    ];
  }

  final Map<String, SshTerminalController> _terminalControllers = {};
  final Map<String, LocalTerminalController> _localTerminalControllers = {};

  // Stable keys to prevent widget rebuilds on window resize/maximize
  final _browserKey = GlobalKey();
  final _vaultsKey = GlobalKey();
  final _settingsKey = GlobalKey();
  final _monitorKey = GlobalKey();
  final _agentKey = GlobalKey();
  final Map<String, GlobalKey> _terminalKeys = {};

  String _activeTabId = pu.isDesktop ? _defaultTerminalId : 'vaults';
  String? _selectedProfileId;

  @override
  void initState() {
    super.initState();
    _initTabs();
    // Auto-start the default local terminal (desktop only)
    if (pu.isDesktop) {
      final defaultTermCtrl = LocalTerminalController(
        shellId: widget.appController.terminalShell,
        appController: widget.appController,
      );
      _localTerminalControllers[_defaultTerminalId] = defaultTermCtrl;
      // Delay terminal start to avoid accessibility bridge crashes on Windows
      Future.delayed(const Duration(milliseconds: 500), () {
        if (mounted) defaultTermCtrl.start();
      });
    }
    widget.appController.addListener(_onLocaleChange);
    if (pu.isDesktop) {
      windowManager.addListener(this);
      _checkMaximized();
    }
    if (pu.isAndroid) {
      unawaited(_initReconnectNotifications());
    }
  }

  void _onLocaleChange() {
    final s = widget.appController.strings;
    final vaultsIdx = _tabs.indexWhere((t) => t.id == 'vaults');
    if (vaultsIdx != -1) {
      _tabs[vaultsIdx] = _Tab(
        id: 'vaults',
        kind: _TabKind.vaults,
        title: s.isTr ? 'Sunucular' : 'Servers',
        closable: false,
        icon: FluentIcons.server,
      );
    }
    final agentIdx = _tabs.indexWhere((t) => t.id == 'agent');
    if (agentIdx != -1) {
      _tabs[agentIdx] = _Tab(
        id: 'agent',
        kind: _TabKind.agent,
        title: s.isTr ? 'Agent' : 'Agent',
        closable: false,
        icon: FluentIcons.robot,
      );
    }
    _syncAgentTab();
    setState(() {});
  }

  void _syncAgentTab() {
    final hasAgent = _tabs.any((t) => t.id == 'agent');
    final shouldHaveAgent = widget.appController.agentPageEnabled;
    if (shouldHaveAgent && !hasAgent) {
      final insertIndex = _tabs.indexWhere((t) => t.id == 'monitor');
      final nextTab = _Tab(
        id: 'agent',
        kind: _TabKind.agent,
        title: widget.appController.strings.isTr ? 'Agent' : 'Agent',
        closable: false,
        icon: FluentIcons.robot,
      );
      if (insertIndex == -1) {
        _tabs.add(nextTab);
      } else {
        _tabs.insert(insertIndex + 1, nextTab);
      }
      return;
    }
    if (!shouldHaveAgent && hasAgent) {
      _tabs.removeWhere((t) => t.id == 'agent');
      if (_activeTabId == 'agent') {
        _activeTabId = pu.isDesktop ? _defaultTerminalId : 'vaults';
      }
    }
  }

  @override
  void dispose() {
    _reconnectCommandSub?.cancel();
    if (pu.isAndroid) {
      unawaited(AndroidReconnectNotificationService.instance.cancelAll());
    }
    _paletteCtrl.dispose();
    _paletteFocus.dispose();
    if (pu.isDesktop) windowManager.removeListener(this);
    widget.appController.removeListener(_onLocaleChange);
    for (final c in _terminalControllers.values) c.disposeController();
    for (final c in _localTerminalControllers.values) c.disposeController();
    super.dispose();
  }

  Future<void> _initReconnectNotifications() async {
    await AndroidReconnectNotificationService.instance.ensureInitialized();
    if (!mounted) return;
    _reconnectCommandSub = AndroidReconnectNotificationService.instance.commands
        .listen(_handleReconnectNotificationCommand);
  }

  void _handleReconnectNotificationCommand(
    ReconnectNotificationCommand command,
  ) {
    final controller = _terminalControllers[command.tabId];
    if (controller == null) {
      return;
    }

    if (mounted && _activeTabId != command.tabId) {
      setState(() {
        _activeTabId = command.tabId;
        _selectedProfileId = controller.profile.id;
      });
    }

    final resume =
        command.action == ReconnectNotificationAction.resumeLastSession;
    unawaited(controller.reconnectFromNotification(resumeLastSession: resume));
  }

  @override
  void onWindowMaximize() => _checkMaximized();
  @override
  void onWindowUnmaximize() => _checkMaximized();
  @override
  void onWindowEnterFullScreen() => _checkMaximized();
  @override
  void onWindowLeaveFullScreen() => _checkMaximized();

  bool _isMaximized = false;

  void _checkMaximized() async {
    if (!pu.isDesktop || !mounted) return;
    try {
      // Small delay to let the window finish its state transition
      await Future.delayed(const Duration(milliseconds: 100));
      if (!mounted) return;
      final maximized = await windowManager.isMaximized();
      final fullScreen = await windowManager.isFullScreen();
      final shouldBeSquare = maximized || fullScreen;
      if (shouldBeSquare != _isMaximized && mounted) {
        setState(() => _isMaximized = shouldBeSquare);
      }
    } catch (_) {}
  }

  void _handleMobileBackPressed() {
    if (!pu.isMobile) {
      return;
    }
    if (_showPalette) {
      setState(() => _showPalette = false);
      return;
    }

    if (_activeTabId != 'vaults') {
      setState(() => _activeTabId = 'vaults');
      return;
    }
  }

  List<_PaletteCommand> _getPaletteCommands() {
    final s = widget.appController.strings;
    final isTr = s.isTr;
    return [
      _PaletteCommand(
        isTr ? 'Yeni Yerel Terminal' : 'New Local Terminal',
        FluentIcons.command_prompt,
        () {
          if (pu.isDesktop) _openLocalTerminalTab();
        },
      ),
      _PaletteCommand(
        isTr ? 'Sunucular' : 'Servers',
        FluentIcons.server,
        () => setState(() => _activeTabId = 'vaults'),
      ),
      if (pu.isDesktop)
        _PaletteCommand(
          'SFTP',
          FluentIcons.open_folder_horizontal,
          () => setState(() => _activeTabId = 'sftp'),
        ),
      if (pu.isDesktop)
        _PaletteCommand(
          'Monitor',
          FluentIcons.health,
          () => setState(() => _activeTabId = 'monitor'),
        ),
      if (widget.appController.agentPageEnabled)
        _PaletteCommand(
          isTr ? 'Agent' : 'Agent',
          FluentIcons.robot,
          () => setState(() => _activeTabId = 'agent'),
        ),
      _PaletteCommand(
        isTr ? 'Ayarlar' : 'Settings',
        FluentIcons.settings,
        () => setState(() => _activeTabId = 'settings'),
      ),
      _PaletteCommand(
        isTr ? 'Yeni Sunucu Ekle' : 'Add New Host',
        FluentIcons.add,
        () => showConnectionDialog(context, widget.appController),
      ),
      for (final p in widget.appController.connections)
        _PaletteCommand(
          'SSH: ${p.name}',
          FluentIcons.plug_connected,
          () => _openTerminalTab(p),
        ),
    ];
  }

  void _togglePalette() {
    setState(() {
      _showPalette = !_showPalette;
      if (_showPalette) {
        _paletteCtrl.clear();
        WidgetsBinding.instance.addPostFrameCallback(
          (_) => _paletteFocus.requestFocus(),
        );
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final t = AppTheme.of(context);
    final isDark = widget.appController.isDarkMode;
    final useTransparent =
        pu.isDesktop && widget.appController.windowEffect != 'none';
    final opacity = widget.appController.windowOpacity;
    final bgColor = useTransparent
        ? (isDark
              ? Color.fromRGBO(35, 35, 34, opacity)
              : Color.fromRGBO(245, 243, 240, opacity))
        : t.bg;

    // Keyboard shortcuts wrapper
    Widget wrapWithShortcuts(Widget child) {
      return Shortcuts(
        shortcuts: {
          LogicalKeySet(LogicalKeyboardKey.control, LogicalKeyboardKey.keyP):
              const _TogglePaletteIntent(),
        },
        child: Actions(
          actions: {
            _TogglePaletteIntent: CallbackAction<_TogglePaletteIntent>(
              onInvoke: (_) {
                _togglePalette();
                return null;
              },
            ),
          },
          child: Focus(autofocus: true, child: child),
        ),
      );
    }

    Widget addPaletteOverlay(Widget child) {
      if (!_showPalette) return child;
      return Stack(
        children: [
          child,
          _CommandPalette(
            controller: _paletteCtrl,
            focusNode: _paletteFocus,
            commands: _getPaletteCommands(),
            onDismiss: () => setState(() => _showPalette = false),
          ),
        ],
      );
    }

    // Mobile: simple layout without window chrome
    if (pu.isMobile) {
      return PopScope(
        canPop: false,
        onPopInvokedWithResult: (didPop, result) {
          if (didPop) return;
          _handleMobileBackPressed();
        },
        child: wrapWithShortcuts(
          addPaletteOverlay(
            DecoratedBox(
              decoration: BoxDecoration(color: bgColor),
              child: SafeArea(
                child: Column(
                  children: [
                    _TopBar(
                      appController: widget.appController,
                      tabs: _tabs,
                      activeTabId: _activeTabId,
                      onTabSelected: (id) => setState(() => _activeTabId = id),
                      onTabClosed: _closeTab,
                      onAddPressed: _handleAddPressed,
                    ),
                    Expanded(
                      child: Stack(
                        children: [
                          _buildBody(),
                          Positioned(
                            right: 16,
                            bottom: 16,
                            child: AnimatedBuilder(
                              animation: widget.appController,
                              builder: (_, __) => _TransferOverlay(
                                appController: widget.appController,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
    }

    // Desktop: rounded corners + resize edges
    final radius = _isMaximized ? 0.0 : 12.0;

    final content = ClipRRect(
      borderRadius: BorderRadius.circular(radius),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: bgColor,
          borderRadius: BorderRadius.circular(radius),
          border: _isMaximized ? null : Border.all(color: t.border, width: 1),
        ),
        child: Column(
          children: [
            _TopBar(
              appController: widget.appController,
              tabs: _tabs,
              activeTabId: _activeTabId,
              onTabSelected: (id) => setState(() => _activeTabId = id),
              onTabClosed: _closeTab,
              onAddPressed: _handleAddPressed,
            ),
            Expanded(
              child: Stack(
                children: [
                  _buildBody(),
                  Positioned(
                    right: 16,
                    bottom: 16,
                    child: AnimatedBuilder(
                      animation: widget.appController,
                      builder: (_, __) =>
                          _TransferOverlay(appController: widget.appController),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );

    if (_isMaximized || !pu.isLinux)
      return wrapWithShortcuts(addPaletteOverlay(content));

    const e = 8.0;
    const c = 16.0;
    return wrapWithShortcuts(
      addPaletteOverlay(
        Stack(
          children: [
            Positioned.fill(
              child: Padding(padding: const EdgeInsets.all(e), child: content),
            ),
            _ResizeEdge(
              left: c,
              right: c,
              top: 0,
              height: e,
              cursor: SystemMouseCursors.resizeUp,
              edge: ResizeEdge.top,
            ),
            _ResizeEdge(
              left: c,
              right: c,
              bottom: 0,
              height: e,
              cursor: SystemMouseCursors.resizeDown,
              edge: ResizeEdge.bottom,
            ),
            _ResizeEdge(
              left: 0,
              top: c,
              bottom: c,
              width: e,
              cursor: SystemMouseCursors.resizeLeft,
              edge: ResizeEdge.left,
            ),
            _ResizeEdge(
              right: 0,
              top: c,
              bottom: c,
              width: e,
              cursor: SystemMouseCursors.resizeRight,
              edge: ResizeEdge.right,
            ),
            _ResizeEdge(
              left: 0,
              top: 0,
              width: c,
              height: c,
              cursor: SystemMouseCursors.resizeUpLeft,
              edge: ResizeEdge.topLeft,
            ),
            _ResizeEdge(
              right: 0,
              top: 0,
              width: c,
              height: c,
              cursor: SystemMouseCursors.resizeUpRight,
              edge: ResizeEdge.topRight,
            ),
            _ResizeEdge(
              left: 0,
              bottom: 0,
              width: c,
              height: c,
              cursor: SystemMouseCursors.resizeDownLeft,
              edge: ResizeEdge.bottomLeft,
            ),
            _ResizeEdge(
              right: 0,
              bottom: 0,
              width: c,
              height: c,
              cursor: SystemMouseCursors.resizeDownRight,
              edge: ResizeEdge.bottomRight,
            ),
          ],
        ),
      ),
    );
  }

  GlobalKey _termKeyFor(String tabId) =>
      _terminalKeys.putIfAbsent(tabId, () => GlobalKey());

  Widget _buildBody() {
    // Use stable GlobalKeys so widgets survive rebuilds (window resize, maximize, etc.)
    final allViews = <String, Widget>{};

    allViews['vaults'] = VaultsWorkbenchView(
      key: _vaultsKey,
      appController: widget.appController,
      selectedProfileId: _selectedProfileId,
      onProfileSelected: (v) => setState(() => _selectedProfileId = v),
      onOpenTerminal: _openTerminalTab,
      onOpenSftp: (p) => setState(() {
        _selectedProfileId = p.id;
        _activeTabId = 'sftp';
      }),
    );
    if (pu.isDesktop) {
      allViews['sftp'] = BrowserView(
        key: _browserKey,
        appController: widget.appController,
        preferredLeftProfileId: _selectedProfileId,
      );
    }
    allViews['settings'] = SettingsView(
      key: _settingsKey,
      appController: widget.appController,
    );
    if (pu.isDesktop) {
      allViews['monitor'] = DashboardView(
        key: _monitorKey,
        appController: widget.appController,
      );
    }
    allViews['agent'] = AgentWorkbenchView(
      key: _agentKey,
      appController: widget.appController,
      onSendLocalTerminalCommand: _sendCommandToLocalTerminalFromAgent,
      onSendSshTerminalCommand: _sendCommandToSshTerminalFromAgent,
    );

    for (final tab in _tabs) {
      if (tab.kind == _TabKind.terminal &&
          _terminalControllers.containsKey(tab.id)) {
        allViews[tab.id] = TerminalWorkbenchView(
          key: _termKeyFor(tab.id),
          controller: _terminalControllers[tab.id]!,
          appController: widget.appController,
        );
      }
      if (tab.kind == _TabKind.localTerminal &&
          _localTerminalControllers.containsKey(tab.id)) {
        allViews[tab.id] = LocalTerminalView(
          key: _termKeyFor(tab.id),
          controller: _localTerminalControllers[tab.id]!,
          appController: widget.appController,
        );
      }
    }

    final keys = allViews.keys.toList();
    int activeIndex = keys.indexOf(_activeTabId);
    if (activeIndex < 0) activeIndex = 0;

    return IndexedStack(
      index: activeIndex,
      children: keys.map((k) => allViews[k]!).toList(),
    );
  }

  Future<void> _handleAddPressed() async {
    if (!mounted) return;
    final s = widget.appController.strings;
    final overlay = Overlay.of(context);
    late OverlayEntry entry;
    entry = OverlayEntry(
      builder: (_) => GestureDetector(
        behavior: HitTestBehavior.translucent,
        onTap: () => entry.remove(),
        child: Stack(
          children: [
            Positioned(
              right: pu.isMobile ? 12 : 160,
              top: 44,
              child: Container(
                width: 220,
                decoration: BoxDecoration(
                  color: workbenchMenuBg,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: workbenchBorder, width: 0.5),
                  boxShadow: menuShadow,
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (pu.isDesktop)
                      _AddMenuItem(
                        icon: FluentIcons.command_prompt,
                        label: s.isTr ? 'Yerel Terminal' : 'Local Terminal',
                        onTap: () {
                          entry.remove();
                          _openLocalTerminalTab();
                        },
                      ),
                    _AddMenuItem(
                      icon: FluentIcons.plug_connected,
                      label: s.isTr ? 'SSH Terminal' : 'SSH Terminal',
                      onTap: () async {
                        entry.remove();
                        final selected = _selectedProfile();
                        if (selected != null) {
                          await _openTerminalTab(selected);
                          return;
                        }
                        if (mounted)
                          await showConnectionDialog(
                            context,
                            widget.appController,
                          );
                      },
                    ),
                    Container(
                      height: 0.5,
                      margin: EdgeInsets.symmetric(horizontal: 8),
                      color: workbenchBorder,
                    ),
                    _AddMenuItem(
                      icon: FluentIcons.add,
                      label: s.isTr ? 'Yeni Sunucu Ekle' : 'Add New Host',
                      onTap: () async {
                        entry.remove();
                        if (mounted)
                          await showConnectionDialog(
                            context,
                            widget.appController,
                          );
                      },
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
    overlay.insert(entry);
  }

  Future<void> _openTerminalTab(ConnectionProfile profile) async {
    final existing = _tabs.where((t) => t.profileId == profile.id).toList();
    if (existing.isNotEmpty) {
      setState(() => _activeTabId = existing.first.id);
      return;
    }

    final tabId = 'terminal-${DateTime.now().microsecondsSinceEpoch}';
    late final SshTerminalController controller;
    controller = SshTerminalController(
      profile: profile,
      strings: widget.appController.strings,
      appController: widget.appController,
      onTmuxInstallPrompt: _promptTmuxInstall,
      onReconnectAttentionChanged: (requiresAttention) {
        _onReconnectAttentionChanged(
          tabId: tabId,
          controller: controller,
          requiresAttention: requiresAttention,
        );
      },
    );
    _terminalControllers[tabId] = controller;

    setState(() {
      _tabs.add(
        _Tab(
          id: tabId,
          kind: _TabKind.terminal,
          title: profile.name,
          closable: true,
          icon: FluentIcons.command_prompt,
          profileId: profile.id,
        ),
      );
      _selectedProfileId = profile.id;
      _activeTabId = tabId;
    });

    widget.appController.addLog(
      'Opening terminal for ${profile.name}',
      level: LogLevel.info,
    );
    await controller.connect();
  }

  void _onReconnectAttentionChanged({
    required String tabId,
    required SshTerminalController controller,
    required bool requiresAttention,
  }) {
    if (!pu.isAndroid) return;

    if (!requiresAttention) {
      unawaited(
        AndroidReconnectNotificationService.instance.cancelForTab(tabId),
      );
      return;
    }

    final label = '${controller.profile.username}@${controller.profile.host}';
    unawaited(
      AndroidReconnectNotificationService.instance.showReconnectActions(
        tabId: tabId,
        hostLabel: label,
        isTr: widget.appController.strings.isTr,
      ),
    );
  }

  Future<TmuxInstallPromptResult> _promptTmuxInstall(
    TmuxInstallPrompt prompt,
  ) async {
    if (!mounted) {
      return const TmuxInstallPromptResult(choice: TmuxInstallChoice.skipOnce);
    }

    final strings = widget.appController.strings;
    var rememberChoice = true;
    final tmuxInstalled = prompt.tmuxAlreadyInstalled;

    final result = await showDialog<TmuxInstallPromptResult>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => ContentDialog(
          title: Text(
            tmuxInstalled
                ? (strings.isTr
                      ? 'Kalıcı oturum etkinleştirilsin mi?'
                      : 'Enable persistent session?')
                : (strings.isTr
                      ? 'tmux kurulumu gerekli'
                      : 'tmux installation needed'),
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                tmuxInstalled
                    ? (strings.isTr
                          ? '${prompt.profile.name} sunucusunda tmux zaten kurulu. Kalıcı oturum için otomatik tmux kullanılsın mı?'
                          : 'tmux is already installed on ${prompt.profile.name}. Use it automatically for persistent sessions?')
                    : (strings.isTr
                          ? '${prompt.profile.name} sunucusunda kalici oturum icin tmux kurulmasi gerekiyor.'
                          : 'tmux is required for persistent sessions on ${prompt.profile.name}.'),
                style: const TextStyle(fontSize: 12),
              ),
              const SizedBox(height: 8),
              Text(
                'Host: ${prompt.profile.username}@${prompt.profile.host}:${prompt.profile.port}',
                style: const TextStyle(fontSize: 11),
              ),
              if (prompt.distroName.trim().isNotEmpty) ...[
                const SizedBox(height: 2),
                Text(
                  'OS: ${prompt.distroName}',
                  style: const TextStyle(fontSize: 11),
                ),
              ],
              if (prompt.packageManager != 'unknown') ...[
                const SizedBox(height: 2),
                Text(
                  'PM: ${prompt.packageManager}',
                  style: const TextStyle(fontSize: 11),
                ),
              ],
              const SizedBox(height: 10),
              Checkbox(
                checked: rememberChoice,
                onChanged: (v) =>
                    setDialogState(() => rememberChoice = v ?? false),
                content: Text(
                  strings.isTr
                      ? 'Bu host icin kararimi hatirla'
                      : 'Remember my choice for this host',
                  style: const TextStyle(fontSize: 11),
                ),
              ),
            ],
          ),
          actions: [
            Button(
              onPressed: () => Navigator.pop(
                ctx,
                TmuxInstallPromptResult(
                  choice: TmuxInstallChoice.denyInstall,
                  rememberChoice: rememberChoice,
                ),
              ),
              child: Text(strings.isTr ? 'Hayir' : 'No'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(
                ctx,
                TmuxInstallPromptResult(
                  choice: TmuxInstallChoice.allowInstall,
                  rememberChoice: rememberChoice,
                ),
              ),
              child: Text(
                tmuxInstalled
                    ? (strings.isTr ? 'Etkinleştir' : 'Enable')
                    : (strings.isTr ? 'Kur' : 'Install'),
              ),
            ),
          ],
        ),
      ),
    );

    return result ??
        const TmuxInstallPromptResult(choice: TmuxInstallChoice.skipOnce);
  }

  void _openLocalTerminalTab() {
    if (!pu.isDesktop) return; // Local terminal not available on mobile
    final tabId = 'local-${DateTime.now().microsecondsSinceEpoch}';
    final controller = LocalTerminalController(
      shellId: widget.appController.terminalShell,
      appController: widget.appController,
    );
    _localTerminalControllers[tabId] = controller;
    final s = widget.appController.strings;

    setState(() {
      _tabs.add(
        _Tab(
          id: tabId,
          kind: _TabKind.localTerminal,
          title: s.isTr ? 'Yerel Terminal' : 'Local Terminal',
          closable: true,
          icon: FluentIcons.command_prompt,
        ),
      );
      _activeTabId = tabId;
    });

    widget.appController.addLog('Opened local terminal', level: LogLevel.info);
    controller.start();
  }

  Future<void> _sendCommandToLocalTerminalFromAgent(String command) async {
    if (!pu.isDesktop) return;
    final trimmed = command.trim();
    if (trimmed.isEmpty) return;

    var controller = _localTerminalControllers[_defaultTerminalId];
    if (controller == null) {
      controller = LocalTerminalController(
        shellId: widget.appController.terminalShell,
        appController: widget.appController,
      );
      _localTerminalControllers[_defaultTerminalId] = controller;
    }
    if (!controller.running) {
      await controller.start();
    }
    if (!mounted) return;
    setState(() => _activeTabId = _defaultTerminalId);
    controller.sendCommand(trimmed, source: 'agent_cli');
  }

  Future<void> _sendCommandToSshTerminalFromAgent(
    ConnectionProfile profile,
    String command,
  ) async {
    final trimmed = command.trim();
    if (trimmed.isEmpty) return;

    await _openTerminalTab(profile);
    String? targetTabId;
    SshTerminalController? controller;
    for (final tab in _tabs) {
      if (tab.profileId == profile.id) {
        targetTabId = tab.id;
        controller = _terminalControllers[tab.id];
        break;
      }
    }
    if (controller == null || targetTabId == null) return;
    if (!controller.connected && !controller.connecting) {
      await controller.connect();
    }
    if (!mounted) return;
    setState(() => _activeTabId = targetTabId!);
    controller.sendCommand(trimmed, source: 'agent_cli');
  }

  void _closeTab(String id) {
    if (id == 'vaults' || id == 'sftp') return;
    if (pu.isAndroid) {
      unawaited(AndroidReconnectNotificationService.instance.cancelForTab(id));
    }
    final sshCtrl = _terminalControllers.remove(id);
    sshCtrl?.disposeController();
    final localCtrl = _localTerminalControllers.remove(id);
    localCtrl?.disposeController();
    final idx = _tabs.indexWhere((t) => t.id == id);
    if (idx == -1) return;
    setState(() {
      _tabs.removeAt(idx);
      if (_activeTabId == id)
        _activeTabId = idx > 0 ? _tabs[idx - 1].id : 'vaults';
    });
  }

  ConnectionProfile? _selectedProfile() {
    for (final p in widget.appController.connections) {
      if (p.id == _selectedProfileId) return p;
    }
    return widget.appController.connections.isEmpty
        ? null
        : widget.appController.connections.first;
  }
}

// ─── Top Bar ─────────────────────────────────────────────────────────

class _TopBar extends StatelessWidget {
  const _TopBar({
    required this.appController,
    required this.tabs,
    required this.activeTabId,
    required this.onTabSelected,
    required this.onTabClosed,
    required this.onAddPressed,
  });
  final AppController appController;
  final List<_Tab> tabs;
  final String activeTabId;
  final ValueChanged<String> onTabSelected;
  final ValueChanged<String> onTabClosed;
  final Future<void> Function() onAddPressed;

  @override
  Widget build(BuildContext context) {
    final t = AppTheme.of(context);
    final isMobile = pu.isMobile;
    return Container(
      height: isMobile ? 56 : 44,
      padding: EdgeInsets.symmetric(horizontal: isMobile ? 10 : 14),
      decoration: BoxDecoration(color: t.topBar),
      child: Row(
        children: [
          Container(
            width: isMobile ? 34 : 26,
            height: isMobile ? 34 : 26,
            decoration: BoxDecoration(
              color: t.panel,
              borderRadius: BorderRadius.circular(isMobile ? 8 : 6),
              border: Border.all(color: t.border, width: 0.6),
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(isMobile ? 8 : 6),
              child: Image.asset(
                'assets/tray_icon.png',
                fit: BoxFit.cover,
                errorBuilder: (_, __, ___) => Center(
                  child: Text(
                    'G',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: isMobile ? 15 : 13,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(width: 8),
          Text(
            'LifeOS Gate',
            style: TextStyle(
              color: t.text,
              fontSize: isMobile ? 11 : 10,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.1,
            ),
          ),
          SizedBox(width: isMobile ? 8 : 12),
          Expanded(
            child: Stack(
              children: [
                if (pu.isDesktop)
                  const Positioned.fill(
                    child: DragToMoveArea(child: SizedBox.expand()),
                  ),
                SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Row(
                    children: [
                      for (final tab in tabs) ...[
                        _TabChip(
                          tab: tab,
                          active: tab.id == activeTabId,
                          onPressed: () => onTabSelected(tab.id),
                          onClosed: tab.closable
                              ? () => onTabClosed(tab.id)
                              : null,
                        ),
                        const SizedBox(width: 2),
                      ],
                      _AddBtn(onPressed: onAddPressed),
                    ],
                  ),
                ),
              ],
            ),
          ),
          SizedBox(width: isMobile ? 8 : 10),
          GestureDetector(
            onTap: () => onTabSelected('settings'),
            child: Icon(
              FluentIcons.settings,
              size: isMobile ? 18 : 14,
              color: activeTabId == 'settings' ? t.text : t.textFaint,
            ),
          ),
          SizedBox(width: isMobile ? 8 : 10),
          AnimatedBuilder(
            animation: appController,
            builder: (_, _c) => _LangToggle(appController: appController),
          ),
          if (pu.isDesktop) ...[
            const SizedBox(width: 6),
            const _WindowButtons(),
          ],
        ],
      ),
    );
  }
}

class _LangToggle extends StatelessWidget {
  const _LangToggle({required this.appController});
  final AppController appController;

  @override
  Widget build(BuildContext context) {
    final isTr = appController.locale == AppLocale.tr;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        _LangBtn(
          label: 'TR',
          active: isTr,
          onTap: () => appController.setLocale(AppLocale.tr),
        ),
        const SizedBox(width: 2),
        _LangBtn(
          label: 'EN',
          active: !isTr,
          onTap: () => appController.setLocale(AppLocale.en),
        ),
      ],
    );
  }
}

class _LangBtn extends StatelessWidget {
  const _LangBtn({
    required this.label,
    required this.active,
    required this.onTap,
  });
  final String label;
  final bool active;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final isMobile = pu.isMobile;
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: EdgeInsets.symmetric(
          horizontal: isMobile ? 10 : 8,
          vertical: isMobile ? 6 : 4,
        ),
        decoration: BoxDecoration(
          color: active ? workbenchAccent : Colors.transparent,
          borderRadius: BorderRadius.circular(4),
        ),
        child: Text(
          label,
          style: TextStyle(
            color: active ? Colors.white : workbenchTextFaint,
            fontSize: isMobile ? 11 : 10,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
    );
  }
}

class _TabChip extends StatefulWidget {
  const _TabChip({
    required this.tab,
    required this.active,
    required this.onPressed,
    this.onClosed,
  });
  final _Tab tab;
  final bool active;
  final VoidCallback onPressed;
  final VoidCallback? onClosed;
  @override
  State<_TabChip> createState() => _TabChipState();
}

class _TabChipState extends State<_TabChip> {
  bool _h = false;
  @override
  Widget build(BuildContext context) {
    final t = AppTheme.of(context);
    final isMobile = pu.isMobile;
    return MouseRegion(
      onEnter: (_) => setState(() => _h = true),
      onExit: (_) => setState(() => _h = false),
      child: GestureDetector(
        onTap: widget.onPressed,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              height: isMobile ? 38 : 30,
              padding: EdgeInsets.symmetric(horizontal: isMobile ? 14 : 10),
              decoration: BoxDecoration(
                color: widget.active
                    ? t.panelAlt
                    : _h
                    ? t.hover
                    : Colors.transparent,
                borderRadius: BorderRadius.circular(6),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    widget.tab.icon,
                    size: isMobile ? 14 : 11,
                    color: widget.active ? t.accent : t.textMuted,
                  ),
                  SizedBox(width: isMobile ? 8 : 6),
                  Text(
                    widget.tab.title,
                    style: TextStyle(
                      color: widget.active ? t.text : t.textMuted,
                      fontSize: isMobile ? 13 : 12,
                      fontWeight: widget.active
                          ? FontWeight.w600
                          : FontWeight.w400,
                    ),
                  ),
                  if (widget.onClosed != null) ...[
                    SizedBox(width: isMobile ? 8 : 6),
                    GestureDetector(
                      onTap: widget.onClosed,
                      child: Icon(
                        FluentIcons.chrome_close,
                        size: isMobile ? 11 : 8,
                        color: _h ? t.text : t.textFaint,
                      ),
                    ),
                  ],
                ],
              ),
            ),
            AnimatedContainer(
              duration: const Duration(milliseconds: 150),
              height: 2,
              width: widget.active ? (isMobile ? 30 : 24) : 0,
              margin: EdgeInsets.only(top: isMobile ? 3 : 2),
              decoration: BoxDecoration(
                color: widget.active ? t.accent : Colors.transparent,
                borderRadius: BorderRadius.circular(1),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _AddBtn extends StatefulWidget {
  const _AddBtn({required this.onPressed});
  final Future<void> Function() onPressed;
  @override
  State<_AddBtn> createState() => _AddBtnState();
}

class _AddBtnState extends State<_AddBtn> {
  bool _h = false;
  @override
  Widget build(BuildContext context) {
    final isMobile = pu.isMobile;
    return MouseRegion(
      onEnter: (_) => setState(() => _h = true),
      onExit: (_) => setState(() => _h = false),
      child: GestureDetector(
        onTap: () => widget.onPressed(),
        child: Container(
          width: isMobile ? 34 : 26,
          height: isMobile ? 34 : 26,
          decoration: BoxDecoration(
            color: _h ? workbenchHover : Colors.transparent,
            borderRadius: BorderRadius.circular(isMobile ? 8 : 5),
          ),
          child: Icon(
            FluentIcons.add,
            size: isMobile ? 13 : 10,
            color: workbenchTextMuted,
          ),
        ),
      ),
    );
  }
}

class _WindowButtons extends StatelessWidget {
  const _WindowButtons();
  @override
  Widget build(BuildContext context) {
    if (!pu.isDesktop) return const SizedBox.shrink();
    final t = AppTheme.of(context);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        _WinBtn(
          icon: FluentIcons.chrome_minimize,
          onTap: () => windowManager.minimize(),
          hoverColor: t.hover,
          iconColor: t.textMuted,
        ),
        _WinBtn(
          icon: FluentIcons.checkbox,
          onTap: () async {
            if (await windowManager.isMaximized()) {
              await windowManager.unmaximize();
            } else {
              await windowManager.maximize();
            }
          },
          hoverColor: t.hover,
          iconColor: t.textMuted,
        ),
        _WinBtn(
          icon: FluentIcons.chrome_close,
          onTap: () => windowManager.close(),
          hoverColor: const Color(0xFFE81123),
          iconColor: t.textMuted,
          hoverIconColor: Colors.white,
        ),
      ],
    );
  }
}

class _WinBtn extends StatefulWidget {
  const _WinBtn({
    required this.icon,
    required this.onTap,
    required this.hoverColor,
    required this.iconColor,
    this.hoverIconColor,
  });
  final IconData icon;
  final VoidCallback onTap;
  final Color hoverColor;
  final Color iconColor;
  final Color? hoverIconColor;
  @override
  State<_WinBtn> createState() => _WinBtnState();
}

class _WinBtnState extends State<_WinBtn> {
  bool _h = false;
  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      onEnter: (_) => setState(() => _h = true),
      onExit: (_) => setState(() => _h = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: Container(
          width: 46,
          height: 32,
          color: _h ? widget.hoverColor : Colors.transparent,
          child: Center(
            child: Icon(
              widget.icon,
              size: 10,
              color: _h && widget.hoverIconColor != null
                  ? widget.hoverIconColor
                  : widget.iconColor,
            ),
          ),
        ),
      ),
    );
  }
}

class _ResizeEdge extends StatelessWidget {
  const _ResizeEdge({
    this.left,
    this.top,
    this.right,
    this.bottom,
    this.width,
    this.height,
    required this.cursor,
    required this.edge,
  });
  final double? left, top, right, bottom, width, height;
  final SystemMouseCursor cursor;
  final ResizeEdge edge;

  @override
  Widget build(BuildContext context) {
    return Positioned(
      left: left,
      top: top,
      right: right,
      bottom: bottom,
      width: width,
      height: height,
      child: MouseRegion(
        cursor: cursor,
        child: GestureDetector(
          behavior: HitTestBehavior.translucent,
          onPanStart: (_) => windowManager.startResizing(edge),
        ),
      ),
    );
  }
}

enum _TabKind {
  vaults,
  sftp,
  terminal,
  localTerminal,
  settings,
  monitor,
  agent,
}

class _Tab {
  _Tab({
    required this.id,
    required this.kind,
    required this.title,
    required this.closable,
    required this.icon,
    this.profileId,
  });
  final String id;
  final _TabKind kind;
  String title;
  final bool closable;
  final IconData icon;
  final String? profileId;
}

class _AddMenuItem extends StatefulWidget {
  const _AddMenuItem({
    required this.icon,
    required this.label,
    required this.onTap,
  });
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  @override
  State<_AddMenuItem> createState() => _AddMenuItemState();
}

class _AddMenuItemState extends State<_AddMenuItem> {
  bool _h = false;
  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      onEnter: (_) => setState(() => _h = true),
      onExit: (_) => setState(() => _h = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(
            color: _h ? workbenchHover : Colors.transparent,
            borderRadius: BorderRadius.circular(4),
          ),
          child: Row(
            children: [
              Icon(widget.icon, size: 12, color: workbenchTextMuted),
              const SizedBox(width: 8),
              Text(
                widget.label,
                style: TextStyle(color: workbenchText, fontSize: 12),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ─── Transfer Progress Overlay ──────────────────────────────────────

class _TransferOverlay extends StatelessWidget {
  const _TransferOverlay({required this.appController});
  final AppController appController;

  @override
  Widget build(BuildContext context) {
    final transfers = appController.activeTransfers;
    if (transfers.isEmpty) return const SizedBox.shrink();
    return Container(
      width: 320,
      constraints: const BoxConstraints(maxHeight: 300),
      decoration: BoxDecoration(
        color: workbenchEditorBg,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: workbenchBorder, width: 0.5),
        boxShadow: panelShadow,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 10, 10, 6),
            child: Row(
              children: [
                Icon(FluentIcons.download, size: 12, color: workbenchAccent),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Transfers',
                    style: TextStyle(
                      color: workbenchText,
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                if (transfers.any((t) => t.isComplete || t.isError))
                  GestureDetector(
                    onTap: appController.clearCompletedTransfers,
                    child: Text(
                      'Clear',
                      style: TextStyle(color: workbenchAccent, fontSize: 10),
                    ),
                  ),
              ],
            ),
          ),
          Container(height: 0.5, color: workbenchBorder),
          Flexible(
            child: ListView.builder(
              shrinkWrap: true,
              itemCount: transfers.length,
              padding: const EdgeInsets.all(6),
              itemBuilder: (_, i) => _TransferRow(
                transfer: transfers[i],
                onDismiss: () => appController.removeTransfer(transfers[i]),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _TransferRow extends StatelessWidget {
  const _TransferRow({required this.transfer, required this.onDismiss});
  final TransferProgress transfer;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    final color = transfer.isError
        ? workbenchDanger
        : transfer.isComplete
        ? workbenchSuccess
        : workbenchAccent;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Container(
        padding: const EdgeInsets.all(8),
        decoration: BoxDecoration(
          color: workbenchHover,
          borderRadius: BorderRadius.circular(6),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  transfer.isError
                      ? FluentIcons.error_badge
                      : transfer.isComplete
                      ? FluentIcons.accept
                      : FluentIcons.download,
                  size: 11,
                  color: color,
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    transfer.fileName,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(color: workbenchText, fontSize: 11),
                  ),
                ),
                if (transfer.isComplete || transfer.isError)
                  GestureDetector(
                    onTap: onDismiss,
                    child: Icon(
                      FluentIcons.chrome_close,
                      size: 8,
                      color: workbenchTextFaint,
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 4),
            SizedBox(
              height: 3,
              child: ProgressBar(
                value: (transfer.isComplete ? 1.0 : transfer.progress) * 100,
                backgroundColor: workbenchBorder,
                activeColor: color,
              ),
            ),
            const SizedBox(height: 2),
            Text(
              transfer.isError
                  ? (transfer.errorMsg ?? 'Error')
                  : transfer.isComplete
                  ? 'Completed'
                  : '${_fmt(transfer.transferredBytes)} / ${_fmt(transfer.totalBytes)}',
              style: TextStyle(color: color, fontSize: 9),
            ),
          ],
        ),
      ),
    );
  }

  String _fmt(int b) {
    if (b < 1024) return '$b B';
    if (b < 1048576) return '${(b / 1024).toStringAsFixed(1)} KB';
    if (b < 1073741824) return '${(b / 1048576).toStringAsFixed(1)} MB';
    return '${(b / 1073741824).toStringAsFixed(1)} GB';
  }
}

// ─── Command Palette ────────────────────────────────────────────────

class _TogglePaletteIntent extends Intent {
  const _TogglePaletteIntent();
}

class _PaletteCommand {
  _PaletteCommand(this.label, this.icon, this.action);
  final String label;
  final IconData icon;
  final VoidCallback action;
}

class _CommandPalette extends StatefulWidget {
  const _CommandPalette({
    required this.controller,
    required this.focusNode,
    required this.commands,
    required this.onDismiss,
  });
  final TextEditingController controller;
  final FocusNode focusNode;
  final List<_PaletteCommand> commands;
  final VoidCallback onDismiss;
  @override
  State<_CommandPalette> createState() => _CommandPaletteState();
}

class _CommandPaletteState extends State<_CommandPalette> {
  int _selectedIndex = 0;

  List<_PaletteCommand> get _filtered {
    final q = widget.controller.text.toLowerCase().trim();
    if (q.isEmpty) return widget.commands;
    return widget.commands
        .where((c) => c.label.toLowerCase().contains(q))
        .toList();
  }

  void _execute(int index) {
    final cmds = _filtered;
    if (index >= 0 && index < cmds.length) {
      widget.onDismiss();
      cmds[index].action();
    }
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onTap: widget.onDismiss,
      child: Container(
        color: const Color(0x80000000),
        child: Align(
          alignment: const Alignment(0, -0.3),
          child: GestureDetector(
            onTap: () {}, // prevent dismiss when tapping inside
            child: Container(
              width: 480,
              constraints: const BoxConstraints(maxHeight: 400),
              decoration: BoxDecoration(
                color: workbenchEditorBg,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(
                  color: workbenchAccent.withValues(alpha: 0.3),
                  width: 1,
                ),
                boxShadow: const [
                  BoxShadow(
                    color: Color(0x80000000),
                    blurRadius: 40,
                    offset: Offset(0, 10),
                  ),
                ],
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // Search input
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 12,
                    ),
                    child: Row(
                      children: [
                        Icon(
                          FluentIcons.search,
                          size: 14,
                          color: workbenchAccent,
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: KeyboardListener(
                            focusNode: FocusNode(),
                            onKeyEvent: (event) {
                              if (event is! KeyDownEvent) return;
                              final cmds = _filtered;
                              if (event.logicalKey ==
                                  LogicalKeyboardKey.arrowDown) {
                                setState(
                                  () => _selectedIndex = (_selectedIndex + 1)
                                      .clamp(0, cmds.length - 1),
                                );
                              } else if (event.logicalKey ==
                                  LogicalKeyboardKey.arrowUp) {
                                setState(
                                  () => _selectedIndex = (_selectedIndex - 1)
                                      .clamp(0, cmds.length - 1),
                                );
                              } else if (event.logicalKey ==
                                  LogicalKeyboardKey.enter) {
                                _execute(_selectedIndex);
                              } else if (event.logicalKey ==
                                  LogicalKeyboardKey.escape) {
                                widget.onDismiss();
                              }
                            },
                            child: TextBox(
                              controller: widget.controller,
                              focusNode: widget.focusNode,
                              autofocus: true,
                              placeholder: 'Type a command...',
                              placeholderStyle: TextStyle(
                                color: workbenchTextFaint,
                                fontSize: 14,
                              ),
                              style: TextStyle(
                                color: workbenchText,
                                fontSize: 14,
                              ),
                              decoration: WidgetStateProperty.all(
                                BoxDecoration(color: Colors.transparent),
                              ),
                              onChanged: (_) =>
                                  setState(() => _selectedIndex = 0),
                              onSubmitted: (_) => _execute(_selectedIndex),
                            ),
                          ),
                        ),
                        const SizedBox(width: 10),
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 6,
                            vertical: 2,
                          ),
                          decoration: BoxDecoration(
                            color: workbenchHover,
                            borderRadius: BorderRadius.circular(4),
                          ),
                          child: Text(
                            'Ctrl+P',
                            style: TextStyle(
                              color: workbenchTextFaint,
                              fontSize: 10,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  Container(height: 0.5, color: workbenchBorder),
                  // Results
                  Flexible(
                    child: Builder(
                      builder: (_) {
                        final cmds = _filtered;
                        if (cmds.isEmpty) {
                          return Padding(
                            padding: const EdgeInsets.all(20),
                            child: Text(
                              'No matching commands',
                              style: TextStyle(
                                color: workbenchTextMuted,
                                fontSize: 12,
                              ),
                            ),
                          );
                        }
                        return ListView.builder(
                          shrinkWrap: true,
                          itemCount: cmds.length,
                          padding: const EdgeInsets.symmetric(vertical: 4),
                          itemBuilder: (_, i) => _PaletteRow(
                            command: cmds[i],
                            selected: i == _selectedIndex,
                            onTap: () => _execute(i),
                            onHover: () => setState(() => _selectedIndex = i),
                          ),
                        );
                      },
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _PaletteRow extends StatelessWidget {
  const _PaletteRow({
    required this.command,
    required this.selected,
    required this.onTap,
    required this.onHover,
  });
  final _PaletteCommand command;
  final bool selected;
  final VoidCallback onTap;
  final VoidCallback onHover;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      onEnter: (_) => onHover(),
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          margin: const EdgeInsets.symmetric(horizontal: 4),
          decoration: BoxDecoration(
            color: selected
                ? workbenchAccent.withValues(alpha: 0.12)
                : Colors.transparent,
            borderRadius: BorderRadius.circular(6),
          ),
          child: Row(
            children: [
              Icon(
                command.icon,
                size: 14,
                color: selected ? workbenchAccent : workbenchTextMuted,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  command.label,
                  style: TextStyle(
                    color: selected ? workbenchText : workbenchTextMuted,
                    fontSize: 13,
                    fontWeight: selected ? FontWeight.w500 : FontWeight.w400,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
