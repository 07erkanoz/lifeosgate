import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter_acrylic/flutter_acrylic.dart' as acrylic;
import 'package:lifeos_sftp_drive/src/services/ai_service.dart';
import 'package:lifeos_sftp_drive/src/state/app_controller.dart';
import 'package:lifeos_sftp_drive/src/ui/terminal_themes.dart';
import 'package:lifeos_sftp_drive/src/ui/theme_tokens.dart';
import 'package:lifeos_sftp_drive/src/utils/platform_utils.dart' as pu;

class SettingsView extends StatelessWidget {
  const SettingsView({super.key, required this.appController});
  final AppController appController;

  static const _fonts = [
    'Cascadia Code',
    'Consolas',
    'JetBrains Mono',
    'Fira Code',
    'Courier New',
    'Menlo',
    'monospace',
  ];

  static const _effectOptions = [
    _EffectOption('none', 'None', 'Opaque background, no transparency'),
    _EffectOption('mica', 'Mica', 'Subtle system wallpaper tint (Win 11)'),
    _EffectOption('acrylic', 'Acrylic', 'Frosted glass blur effect'),
    _EffectOption('transparent', 'Transparent', 'Fully transparent background'),
    _EffectOption('tabbed', 'Tabbed', 'Mica with tabbed style (Win 11)'),
  ];

  static const _sshSessionModeOptions = [
    _SettingOption(
      'off',
      'Off',
      'Always use regular shell sessions, no tmux persistence',
    ),
    _SettingOption(
      'smart',
      'Smart',
      'Use tmux automatically if available, ask once when missing',
    ),
    _SettingOption(
      'always',
      'Always tmux',
      'Prefer tmux for every connection and try to keep sessions persistent',
    ),
  ];

  static const _sshTmuxPolicyOptions = [
    _SettingOption(
      'ask_once',
      'Ask once',
      'Prompt once per host and remember the decision',
    ),
    _SettingOption(
      'never_install',
      'Never install',
      'Only use tmux when already installed on the server',
    ),
    _SettingOption(
      'auto_if_possible',
      'Auto install',
      'Install tmux automatically when permissions allow',
    ),
  ];

  void _applyWindowEffect(String effect, double opacity) async {
    if (!pu.isWindows) return; // Only Windows uses flutter_acrylic
    try {
      switch (effect) {
        case 'mica':
          await acrylic.Window.setEffect(
            effect: acrylic.WindowEffect.mica,
            dark: true,
          );
          break;
        case 'acrylic':
          await acrylic.Window.setEffect(
            effect: acrylic.WindowEffect.acrylic,
            dark: true,
            color: const Color(0x00000000),
          );
          break;
        case 'transparent':
          await acrylic.Window.setEffect(
            effect: acrylic.WindowEffect.transparent,
            dark: true,
          );
          break;
        case 'tabbed':
          await acrylic.Window.setEffect(
            effect: acrylic.WindowEffect.tabbed,
            dark: true,
          );
          break;
        default:
          await acrylic.Window.setEffect(
            effect: acrylic.WindowEffect.disabled,
            dark: true,
          );
      }
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    final s = appController.strings;
    return AnimatedBuilder(
      animation: appController,
      builder: (context, _) => Padding(
        padding: const EdgeInsets.all(20),
        child: ListView(
          children: [
            Text(
              s.settings,
              style: TextStyle(
                color: workbenchText,
                fontSize: 18,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 20),

            // App Theme section
            _Section(
              title: s.isTr ? 'Uygulama Teması' : 'App Theme',
              children: [
                _SettingRow(
                  label: s.isTr ? 'Tema' : 'Theme',
                  child: SizedBox(
                    width: 200,
                    child: ComboBox<String>(
                      value: appController.appThemeMode,
                      isExpanded: true,
                      items: [
                        ComboBoxItem(
                          value: 'dark',
                          child: Row(
                            children: [
                              Container(
                                width: 16,
                                height: 16,
                                margin: const EdgeInsets.only(right: 8),
                                decoration: BoxDecoration(
                                  color: workbenchBg,
                                  borderRadius: BorderRadius.circular(3),
                                  border: Border.all(
                                    color: workbenchBorder,
                                    width: 0.5,
                                  ),
                                ),
                              ),
                              Text(
                                s.isTr ? 'Karanlık' : 'Dark',
                                style: const TextStyle(fontSize: 12),
                              ),
                            ],
                          ),
                        ),
                        ComboBoxItem(
                          value: 'light',
                          child: Row(
                            children: [
                              Container(
                                width: 16,
                                height: 16,
                                margin: const EdgeInsets.only(right: 8),
                                decoration: BoxDecoration(
                                  color: const Color(0xFFF5F3F0),
                                  borderRadius: BorderRadius.circular(3),
                                  border: Border.all(
                                    color: const Color(0xFFE2DDD8),
                                    width: 0.5,
                                  ),
                                ),
                              ),
                              Text(
                                s.isTr ? 'Aydınlık' : 'Light',
                                style: const TextStyle(fontSize: 12),
                              ),
                            ],
                          ),
                        ),
                      ],
                      onChanged: (v) {
                        if (v != null) appController.setAppThemeMode(v);
                      },
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 20),

            // Window Effect section
            _Section(
              title: s.isTr ? 'Pencere Efekti' : 'Window Effect',
              children: [
                _SettingRow(
                  label: s.isTr ? 'Efekt Tipi' : 'Effect Type',
                  child: SizedBox(
                    width: 200,
                    child: ComboBox<String>(
                      value: appController.windowEffect,
                      isExpanded: true,
                      items: _effectOptions
                          .map(
                            (e) => ComboBoxItem(
                              value: e.value,
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Text(
                                    e.label,
                                    style: const TextStyle(fontSize: 12),
                                  ),
                                  Text(
                                    e.description,
                                    style: TextStyle(
                                      fontSize: 9,
                                      color: workbenchTextFaint,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          )
                          .toList(),
                      onChanged: (v) {
                        if (v != null) {
                          appController.setWindowEffect(v);
                          _applyWindowEffect(v, appController.windowOpacity);
                        }
                      },
                    ),
                  ),
                ),
                const SizedBox(height: 14),
                _SettingRow(
                  label:
                      '${s.isTr ? "Saydamlık" : "Opacity"} (${(appController.windowOpacity * 100).round()}%)',
                  child: SizedBox(
                    width: 200,
                    child: Slider(
                      value: appController.windowOpacity,
                      min: 0.3,
                      max: 1.0,
                      divisions: 14,
                      onChanged: (v) {
                        appController.setWindowOpacity(v);
                        _applyWindowEffect(appController.windowEffect, v);
                      },
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  pu.isLinux
                      ? (s.isTr
                            ? 'Not: Linux\'ta tüm efektler saydam (transparent) olarak uygulanır. Kompozitör desteği gerekir.'
                            : 'Note: On Linux all effects map to transparent. Compositor support required.')
                      : (s.isTr
                            ? 'Not: Mica ve Tabbed efektler sadece Windows 11\'de çalışır.'
                            : 'Note: Mica and Tabbed effects only work on Windows 11.'),
                  style: TextStyle(color: workbenchTextFaint, fontSize: 10),
                ),
              ],
            ),
            const SizedBox(height: 20),

            // Terminal section
            _Section(
              title: 'Terminal',
              children: [
                Builder(
                  builder: (_) {
                    final shells = pu.detectAvailableShells();
                    final currentShell = appController.terminalShell;
                    // Ensure selected value exists in the list
                    final validValue =
                        (currentShell == 'auto' ||
                            shells.any((s) => s.id == currentShell))
                        ? currentShell
                        : 'auto';
                    return _SettingRow(
                      label: 'Shell',
                      child: SizedBox(
                        width: 250,
                        child: ComboBox<String>(
                          value: validValue,
                          isExpanded: true,
                          items: [
                            ComboBoxItem(
                              value: 'auto',
                              child: Text(
                                s.isTr
                                    ? 'Otomatik (${shells.isNotEmpty ? shells.first.name : "?"})'
                                    : 'Auto (${shells.isNotEmpty ? shells.first.name : "?"})',
                                style: const TextStyle(fontSize: 12),
                              ),
                            ),
                            for (final sh in shells)
                              ComboBoxItem(
                                value: sh.id,
                                child: Row(
                                  children: [
                                    Icon(
                                      sh.isUnix
                                          ? FluentIcons.command_prompt
                                          : FluentIcons.command_prompt,
                                      size: 11,
                                      color: sh.isUnix
                                          ? const Color(0xFF4EC9B0)
                                          : workbenchTextMuted,
                                    ),
                                    const SizedBox(width: 8),
                                    Text(
                                      sh.name,
                                      style: const TextStyle(fontSize: 12),
                                    ),
                                    if (sh.isUnix) ...[
                                      const SizedBox(width: 6),
                                      Container(
                                        padding: const EdgeInsets.symmetric(
                                          horizontal: 4,
                                          vertical: 1,
                                        ),
                                        decoration: BoxDecoration(
                                          color: const Color(
                                            0xFF4EC9B0,
                                          ).withValues(alpha: 0.15),
                                          borderRadius: BorderRadius.circular(
                                            3,
                                          ),
                                        ),
                                        child: const Text(
                                          'unix',
                                          style: TextStyle(
                                            fontSize: 8,
                                            color: Color(0xFF4EC9B0),
                                            fontWeight: FontWeight.w600,
                                          ),
                                        ),
                                      ),
                                    ],
                                  ],
                                ),
                              ),
                          ],
                          onChanged: (v) {
                            if (v != null) appController.setTerminalShell(v);
                          },
                        ),
                      ),
                    );
                  },
                ),
                const SizedBox(height: 4),
                Text(
                  s.isTr
                      ? 'Not: Shell değişikliği yeni açılan terminallere uygulanır.'
                      : 'Note: Shell changes apply to newly opened terminals.',
                  style: TextStyle(color: workbenchTextFaint, fontSize: 10),
                ),
                const SizedBox(height: 16),
                _SettingRow(
                  label: s.isTr ? 'SSH Oturum Modu' : 'SSH Session Mode',
                  child: SizedBox(
                    width: 250,
                    child: ComboBox<String>(
                      value: appController.sshSessionMode,
                      isExpanded: true,
                      items: _sshSessionModeOptions
                          .map(
                            (e) => ComboBoxItem(
                              value: e.value,
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Text(
                                    e.label,
                                    style: const TextStyle(fontSize: 12),
                                  ),
                                  Text(
                                    e.description,
                                    style: TextStyle(
                                      fontSize: 9,
                                      color: workbenchTextFaint,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          )
                          .toList(),
                      onChanged: (v) {
                        if (v != null) appController.setSshSessionMode(v);
                      },
                    ),
                  ),
                ),
                const SizedBox(height: 10),
                _SettingRow(
                  label: s.isTr
                      ? 'Bağlantı kopunca otomatik yeniden bağlan'
                      : 'Auto reconnect on disconnect',
                  child: ToggleSwitch(
                    checked: appController.sshAutoReconnect,
                    onChanged: appController.setSshAutoReconnect,
                  ),
                ),
                const SizedBox(height: 10),
                _SettingRow(
                  label:
                      '${s.isTr ? "Maksimum yeniden bağlanma denemesi" : "Max reconnect attempts"} (${appController.sshReconnectMaxAttempts})',
                  child: SizedBox(
                    width: 250,
                    child: Slider(
                      value: appController.sshReconnectMaxAttempts.toDouble(),
                      min: 1,
                      max: 30,
                      divisions: 29,
                      onChanged: (v) =>
                          appController.setSshReconnectMaxAttempts(v.round()),
                    ),
                  ),
                ),
                const SizedBox(height: 10),
                _SettingRow(
                  label: s.isTr
                      ? 'tmux kurulum politikası'
                      : 'tmux install policy',
                  child: SizedBox(
                    width: 250,
                    child: ComboBox<String>(
                      value: appController.sshTmuxInstallPolicy,
                      isExpanded: true,
                      items: _sshTmuxPolicyOptions
                          .map(
                            (e) => ComboBoxItem(
                              value: e.value,
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Text(
                                    e.label,
                                    style: const TextStyle(fontSize: 12),
                                  ),
                                  Text(
                                    e.description,
                                    style: TextStyle(
                                      fontSize: 9,
                                      color: workbenchTextFaint,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          )
                          .toList(),
                      onChanged: (v) {
                        if (v != null) appController.setSshTmuxInstallPolicy(v);
                      },
                    ),
                  ),
                ),
                const SizedBox(height: 10),
                _SettingRow(
                  label: s.isTr
                      ? 'Time-Machine oturum kaydı'
                      : 'Time-Machine session log',
                  child: ToggleSwitch(
                    checked: appController.sshTimeMachineEnabled,
                    onChanged: appController.setSshTimeMachineEnabled,
                  ),
                ),
                const SizedBox(height: 10),
                _SettingRow(
                  label:
                      '${s.isTr ? "Maksimum oturum olayı" : "Max session events"} (${appController.sshTimeMachineMaxEvents})',
                  child: SizedBox(
                    width: 250,
                    child: Slider(
                      value: appController.sshTimeMachineMaxEvents.toDouble(),
                      min: 500,
                      max: 20000,
                      divisions: 39,
                      onChanged: appController.sshTimeMachineEnabled
                          ? (v) => appController.setSshTimeMachineMaxEvents(
                              v.round(),
                            )
                          : null,
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Button(
                      onPressed: appController.sshTmuxHostDecisions.isEmpty
                          ? null
                          : appController.clearTmuxHostDecisions,
                      child: Text(
                        s.isTr
                            ? 'Kayıtlı tmux kararlarını temizle'
                            : 'Clear saved tmux decisions',
                      ),
                    ),
                    const SizedBox(width: 10),
                    Text(
                      '${appController.sshTmuxHostDecisions.length} ${s.isTr ? "host" : "hosts"}',
                      style: TextStyle(color: workbenchTextFaint, fontSize: 10),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                Text(
                  s.isTr
                      ? 'Not: Smart modda tmux eksikse sadece bir kez sorulur ve host bazında hatırlanır.'
                      : 'Note: In Smart mode, tmux is asked only once when missing and remembered per host.',
                  style: TextStyle(color: workbenchTextFaint, fontSize: 10),
                ),
                const SizedBox(height: 12),
                _SettingRow(
                  label: s.isTr ? 'Renk Şeması' : 'Color Scheme',
                  child: SizedBox(
                    width: 200,
                    child: ComboBox<String>(
                      value: appController.terminalTheme,
                      isExpanded: true,
                      items: terminalSchemes.keys.map((name) {
                        final scheme = terminalSchemes[name]!;
                        return ComboBoxItem(
                          value: name,
                          child: Row(
                            children: [
                              // Color preview dots
                              Container(
                                width: 12,
                                height: 12,
                                margin: const EdgeInsets.only(right: 8),
                                decoration: BoxDecoration(
                                  color: scheme.background,
                                  borderRadius: BorderRadius.circular(2),
                                  border: Border.all(
                                    color: workbenchBorder,
                                    width: 0.5,
                                  ),
                                ),
                              ),
                              Text(name, style: const TextStyle(fontSize: 12)),
                            ],
                          ),
                        );
                      }).toList(),
                      onChanged: (v) {
                        if (v != null) appController.setTerminalTheme(v);
                      },
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                _SettingRow(
                  label: s.isTr ? 'Yazı Tipi' : 'Font Family',
                  child: SizedBox(
                    width: 200,
                    child: ComboBox<String>(
                      value: appController.terminalFontFamily,
                      isExpanded: true,
                      items: _fonts
                          .map(
                            (f) => ComboBoxItem(
                              value: f,
                              child: Text(
                                f,
                                style: TextStyle(fontFamily: f, fontSize: 13),
                              ),
                            ),
                          )
                          .toList(),
                      onChanged: (v) {
                        if (v != null) appController.setTerminalFontFamily(v);
                      },
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                _SettingRow(
                  label:
                      '${s.isTr ? "Yazı Boyutu" : "Font Size"} (${appController.terminalFontSize.round()}px)',
                  child: SizedBox(
                    width: 200,
                    child: Slider(
                      value: appController.terminalFontSize,
                      min: 10,
                      max: 24,
                      divisions: 14,
                      onChanged: appController.setTerminalFontSize,
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                _SettingRow(
                  label:
                      '${s.isTr ? "Satır Yüksekliği" : "Line Height"} (${appController.terminalLineHeight.toStringAsFixed(2)})',
                  child: SizedBox(
                    width: 200,
                    child: Slider(
                      value: appController.terminalLineHeight,
                      min: 1.0,
                      max: 2.0,
                      divisions: 20,
                      onChanged: appController.setTerminalLineHeight,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 20),

            // Alarm Thresholds section
            _Section(
              title: s.isTr ? 'Alarm Eşikleri' : 'Alarm Thresholds',
              children: [
                _SettingRow(
                  label: s.isTr ? 'Alarmları Etkinleştir' : 'Enable Alarms',
                  child: ToggleSwitch(
                    checked: appController.alarmsEnabled,
                    onChanged: appController.setAlarmsEnabled,
                  ),
                ),
                const SizedBox(height: 12),
                _SettingRow(
                  label: 'CPU (${appController.cpuAlarmThreshold.round()}%)',
                  child: SizedBox(
                    width: 200,
                    child: Slider(
                      value: appController.cpuAlarmThreshold,
                      min: 50,
                      max: 100,
                      divisions: 10,
                      onChanged: appController.setCpuAlarmThreshold,
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                _SettingRow(
                  label:
                      '${s.isTr ? "Bellek" : "Memory"} (${appController.memAlarmThreshold.round()}%)',
                  child: SizedBox(
                    width: 200,
                    child: Slider(
                      value: appController.memAlarmThreshold,
                      min: 50,
                      max: 100,
                      divisions: 10,
                      onChanged: appController.setMemAlarmThreshold,
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                _SettingRow(
                  label:
                      '${s.isTr ? "Disk" : "Disk"} (${appController.diskAlarmThreshold.round()}%)',
                  child: SizedBox(
                    width: 200,
                    child: Slider(
                      value: appController.diskAlarmThreshold,
                      min: 50,
                      max: 100,
                      divisions: 10,
                      onChanged: appController.setDiskAlarmThreshold,
                    ),
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  s.isTr
                      ? 'Not: Eşik aşıldığında monitörde kırmızı uyarı gösterilir.'
                      : 'Note: A red alert will appear in the monitor when thresholds are exceeded.',
                  style: TextStyle(color: workbenchTextFaint, fontSize: 10),
                ),
              ],
            ),
            const SizedBox(height: 20),

            // AI Assistant section
            _Section(
              title: s.isTr ? 'AI Asistan' : 'AI Assistant',
              children: [
                _SettingRow(
                  label: 'Provider',
                  child: SizedBox(
                    width: 200,
                    child: ComboBox<String>(
                      value: appController.aiProvider,
                      isExpanded: true,
                      items: AiProvider.values
                          .map(
                            (p) => ComboBoxItem(
                              value: p.name,
                              child: Text(
                                p.label,
                                style: const TextStyle(fontSize: 12),
                              ),
                            ),
                          )
                          .toList(),
                      onChanged: (v) {
                        if (v != null) {
                          appController.setAiProvider(v);
                          final provider = AiProvider.values.firstWhere(
                            (p) => p.name == v,
                          );
                          final models = modelsForProvider(provider);
                          if (models.isNotEmpty)
                            appController.setAiModel(models.first.id);
                        }
                      },
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                _SettingRow(
                  label: s.isTr ? 'Model' : 'Model',
                  child: SizedBox(
                    width: 200,
                    child: Builder(
                      builder: (_) {
                        final provider = AiProvider.values.firstWhere(
                          (p) => p.name == appController.aiProvider,
                          orElse: () => AiProvider.gemini,
                        );
                        final models = modelsForProvider(provider);
                        final currentValid = models.any(
                          (m) => m.id == appController.aiModel,
                        );
                        return ComboBox<String>(
                          value: currentValid
                              ? appController.aiModel
                              : (models.isNotEmpty ? models.first.id : null),
                          isExpanded: true,
                          items: models
                              .map(
                                (m) => ComboBoxItem(
                                  value: m.id,
                                  child: Row(
                                    children: [
                                      Expanded(
                                        child: Text(
                                          m.name,
                                          style: const TextStyle(fontSize: 12),
                                        ),
                                      ),
                                      if (m.isFree)
                                        Container(
                                          padding: const EdgeInsets.symmetric(
                                            horizontal: 4,
                                            vertical: 1,
                                          ),
                                          decoration: BoxDecoration(
                                            color: workbenchSuccess.withValues(
                                              alpha: 0.15,
                                            ),
                                            borderRadius: BorderRadius.circular(
                                              3,
                                            ),
                                          ),
                                          child: Text(
                                            'FREE',
                                            style: TextStyle(
                                              color: workbenchSuccess,
                                              fontSize: 8,
                                              fontWeight: FontWeight.w700,
                                            ),
                                          ),
                                        ),
                                    ],
                                  ),
                                ),
                              )
                              .toList(),
                          onChanged: (v) {
                            if (v != null) appController.setAiModel(v);
                          },
                        );
                      },
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                _SettingRow(
                  label: s.isTr
                      ? 'API Key (provider bazlı)'
                      : 'API Key (per provider)',
                  child: SizedBox(
                    width: 280,
                    child: TextFormBox(
                      key: ValueKey('ai-key-${appController.aiProvider}'),
                      initialValue: appController.aiApiKey,
                      placeholder: s.isTr
                          ? 'API anahtarınızı girin...'
                          : 'Enter your API key...',
                      obscureText: true,
                      style: TextStyle(color: workbenchText, fontSize: 12),
                      onChanged: (v) => appController.setAiApiKey(v),
                    ),
                  ),
                ),
                if (appController.aiApiKey.trim().isEmpty) ...[
                  const SizedBox(height: 8),
                  Text(
                    s.isTr
                        ? 'Not: Anahtar seçili provider için saklanır. Provider değiştirince kendi anahtarı otomatik yüklenir.'
                        : 'Note: The key is stored per provider. When you switch provider, its own key is loaded automatically.',
                    style: TextStyle(color: workbenchTextFaint, fontSize: 10),
                  ),
                ],
                const SizedBox(height: 12),
                _SettingRow(
                  label: s.isTr
                      ? 'Güvenli komutları otomatik çalıştır'
                      : 'Auto-execute safe commands',
                  child: ToggleSwitch(
                    checked: appController.aiAutoExecute,
                    onChanged: appController.setAiAutoExecute,
                  ),
                ),
                const SizedBox(height: 8),
                _SettingRow(
                  label: s.isTr
                      ? 'Tehlikeli komutlarda onay iste'
                      : 'Confirm dangerous commands',
                  child: ToggleSwitch(
                    checked: appController.aiDangerConfirm,
                    onChanged: appController.setAiDangerConfirm,
                  ),
                ),
                const SizedBox(height: 8),
                _SettingRow(
                  label: s.isTr
                      ? 'Akıllı algılama (# gerekmez)'
                      : 'Smart detect (no # needed)',
                  child: ToggleSwitch(
                    checked: appController.aiSmartDetect,
                    onChanged: appController.setAiSmartDetect,
                  ),
                ),
                const SizedBox(height: 8),
                _SettingRow(
                  label: s.isTr
                      ? 'AI panel komut kartları'
                      : 'AI panel command cards',
                  child: SizedBox(
                    width: 220,
                    child: ComboBox<String>(
                      value: appController.aiPanelCommandCardMode,
                      isExpanded: true,
                      items: [
                        ComboBoxItem(
                          value: 'off',
                          child: Text(
                            s.isTr ? 'Kapalı' : 'Off',
                            style: const TextStyle(fontSize: 12),
                          ),
                        ),
                        ComboBoxItem(
                          value: 'error_only',
                          child: Text(
                            s.isTr ? 'Sadece hata olunca' : 'Only on error',
                            style: const TextStyle(fontSize: 12),
                          ),
                        ),
                      ],
                      onChanged: (v) {
                        if (v != null) {
                          appController.setAiPanelCommandCardMode(v);
                        }
                      },
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                _SettingRow(
                  label: s.isTr
                      ? 'Watch Mode (doğrulama döngüsü)'
                      : 'Watch mode (verification loop)',
                  child: ToggleSwitch(
                    checked: appController.aiWatchMode,
                    onChanged: appController.setAiWatchMode,
                  ),
                ),
                const SizedBox(height: 8),
                _SettingRow(
                  label: s.isTr
                      ? 'Plan + Onay katmanı'
                      : 'Plan + approval layer',
                  child: ToggleSwitch(
                    checked: appController.aiPlanApproval,
                    onChanged: appController.setAiPlanApproval,
                  ),
                ),
                const SizedBox(height: 8),
                _SettingRow(
                  label: s.isTr ? 'Toolbelt profili' : 'Toolbelt profile',
                  child: SizedBox(
                    width: 220,
                    child: ComboBox<String>(
                      value: appController.aiToolbeltProfile,
                      isExpanded: true,
                      items: [
                        ComboBoxItem(
                          value: 'auto',
                          child: Text(
                            s.isTr ? 'Otomatik' : 'Auto',
                            style: const TextStyle(fontSize: 12),
                          ),
                        ),
                        ComboBoxItem(
                          value: 'build',
                          child: Text(
                            s.isTr ? 'Build' : 'Build',
                            style: const TextStyle(fontSize: 12),
                          ),
                        ),
                        ComboBoxItem(
                          value: 'deploy',
                          child: Text(
                            s.isTr ? 'Deploy' : 'Deploy',
                            style: const TextStyle(fontSize: 12),
                          ),
                        ),
                        ComboBoxItem(
                          value: 'debug',
                          child: Text(
                            s.isTr ? 'Debug' : 'Debug',
                            style: const TextStyle(fontSize: 12),
                          ),
                        ),
                        ComboBoxItem(
                          value: 'ops',
                          child: Text(
                            s.isTr ? 'Ops' : 'Ops',
                            style: const TextStyle(fontSize: 12),
                          ),
                        ),
                      ],
                      onChanged: (v) {
                        if (v != null) {
                          appController.setAiToolbeltProfile(v);
                        }
                      },
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                _SettingRow(
                  label: s.isTr ? 'Agent Sayfası (CLI)' : 'Agent Page (CLI)',
                  child: ToggleSwitch(
                    checked: appController.agentPageEnabled,
                    onChanged: appController.setAgentPageEnabled,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  s.isTr
                      ? '# ile veya akıllı algılama açıksa doğal dille komut yazabilirsiniz.\nÖrnek: disk kullanımını göster'
                      : 'Use # prefix or enable smart detect to write in natural language.\nExample: show disk usage',
                  style: TextStyle(
                    color: workbenchTextFaint,
                    fontSize: 10,
                    height: 1.4,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 20),

            // Desktop section (hidden on mobile)
            if (pu.isDesktop) ...[
              _Section(
                title: s.desktopBehavior,
                children: [
                  _SettingRow(
                    label: s.hideToTrayOnClose,
                    child: ToggleSwitch(
                      checked: appController.minimizeToTray,
                      onChanged: appController.setMinimizeToTray,
                    ),
                  ),
                  const SizedBox(height: 10),
                  _SettingRow(
                    label: s.launchAtStartup,
                    child: ToggleSwitch(
                      checked: appController.launchAtStartup,
                      onChanged: appController.setLaunchAtStartup,
                    ),
                  ),
                  if (pu.isLinux) ...[
                    const SizedBox(height: 10),
                    _SettingRow(
                      label: s.isTr
                          ? 'Terminal uygulaması olarak tanıt'
                          : 'Register as terminal app',
                      child: ToggleSwitch(
                        checked: appController.linuxRegisterAsTerminal,
                        onChanged: appController.setLinuxRegisterAsTerminal,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      s.isTr
                          ? 'Not: Bu seçenek LifeOS Gate için bir TerminalEmulator masaüstü girdisi oluşturur. Varsayılan terminal seçimi masaüstü ortamına göre ayrıca yapılır.'
                          : 'Note: This creates a TerminalEmulator desktop entry for LifeOS Gate. Choosing it as the default terminal still depends on your desktop environment.',
                      style: TextStyle(color: workbenchTextFaint, fontSize: 10),
                    ),
                  ],
                ],
              ),
              const SizedBox(height: 20),
            ],

            // About section
            _Section(
              title: s.isTr ? 'Hakkında' : 'About',
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Container(
                      width: 48,
                      height: 48,
                      decoration: BoxDecoration(
                        color: workbenchAccent,
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: const Center(
                        child: Text(
                          'L',
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 22,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'LifeOS Gate',
                            style: TextStyle(
                              color: workbenchText,
                              fontSize: 16,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            s.isTr
                                ? 'LifeOS uygulama ailesinin bir parçasıdır.'
                                : 'Part of the LifeOS application family.',
                            style: TextStyle(
                              color: workbenchTextMuted,
                              fontSize: 12,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            'v1.0.0',
                            style: TextStyle(
                              color: workbenchTextFaint,
                              fontSize: 11,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                Container(height: 0.5, color: workbenchBorder),
                const SizedBox(height: 12),
                _AboutRow(
                  label: s.isTr ? 'Geliştirici' : 'Developer',
                  value: 'Erkan ÖZ',
                ),
                const SizedBox(height: 8),
                _AboutRow(label: 'Web', value: 'lifeos.com.tr'),
                const SizedBox(height: 8),
                _AboutRow(
                  label: s.isTr ? 'Kişisel Site' : 'Personal',
                  value: 'erkanoz.com',
                ),
                const SizedBox(height: 8),
                _AboutRow(
                  label: s.isTr ? 'Lisans' : 'License',
                  value: 'MIT License',
                ),
                const SizedBox(height: 12),
                Container(height: 0.5, color: workbenchBorder),
                const SizedBox(height: 10),
                Text(
                  s.isTr
                      ? 'Bu yazılım MIT Lisansı altında dağıtılmaktadır. Kaynak kodu serbestçe kullanılabilir, değiştirilebilir ve dağıtılabilir.'
                      : 'This software is distributed under the MIT License. Source code can be freely used, modified, and distributed.',
                  style: TextStyle(
                    color: workbenchTextFaint,
                    fontSize: 10,
                    height: 1.4,
                  ),
                ),
                const SizedBox(height: 12),
                Container(height: 0.5, color: workbenchBorder),
                const SizedBox(height: 10),
                Text(
                  s.isTr ? 'Kullanılan Teknolojiler' : 'Technologies Used',
                  style: TextStyle(
                    color: workbenchTextMuted,
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  s.isTr
                      ? '• Windows sürücü bağlama: SSHFS-Win + WinFsp (github.com/winfsp/sshfs-win)\n'
                            '• Linux sürücü bağlama: FUSE / sshfs\n'
                            '• SSH/SFTP bağlantısı: dartssh2 (Dart SSH protokolü)\n'
                            '• Terminal emülatörü: xterm.dart\n'
                            '• Arayüz: Flutter + Fluent UI\n'
                            '• Pencere efektleri: flutter_acrylic (Mica/Acrylic)'
                      : '• Windows drive mount: SSHFS-Win + WinFsp (github.com/winfsp/sshfs-win)\n'
                            '• Linux drive mount: FUSE / sshfs\n'
                            '• SSH/SFTP connection: dartssh2 (Dart SSH protocol)\n'
                            '• Terminal emulator: xterm.dart\n'
                            '• UI framework: Flutter + Fluent UI\n'
                            '• Window effects: flutter_acrylic (Mica/Acrylic)',
                  style: TextStyle(
                    color: workbenchTextFaint,
                    fontSize: 10,
                    height: 1.5,
                  ),
                ),
                const SizedBox(height: 12),
                Text(
                  '© 2026 Erkan ÖZ. All rights reserved.',
                  style: TextStyle(color: workbenchTextFaint, fontSize: 10),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _EffectOption {
  const _EffectOption(this.value, this.label, this.description);
  final String value;
  final String label;
  final String description;
}

class _SettingOption {
  const _SettingOption(this.value, this.label, this.description);
  final String value;
  final String label;
  final String description;
}

class _Section extends StatelessWidget {
  const _Section({required this.title, required this.children});
  final String title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: workbenchPanelAlt,
        borderRadius: BorderRadius.circular(10),
        boxShadow: cardShadow,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: TextStyle(
              color: workbenchText,
              fontSize: 14,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 14),
          ...children,
        ],
      ),
    );
  }
}

class _SettingRow extends StatelessWidget {
  const _SettingRow({required this.label, required this.child});
  final String label;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final compact = pu.isMobile || MediaQuery.sizeOf(context).width < 760;
    if (compact) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: TextStyle(color: workbenchTextMuted, fontSize: 13),
          ),
          const SizedBox(height: 8),
          Align(alignment: Alignment.centerLeft, child: child),
        ],
      );
    }
    return Row(
      children: [
        Expanded(
          child: Text(
            label,
            style: TextStyle(color: workbenchTextMuted, fontSize: 13),
          ),
        ),
        child,
      ],
    );
  }
}

class _AboutRow extends StatelessWidget {
  const _AboutRow({required this.label, required this.value});
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        SizedBox(
          width: 100,
          child: Text(
            label,
            style: TextStyle(color: workbenchTextFaint, fontSize: 12),
          ),
        ),
        Text(
          value,
          style: TextStyle(
            color: workbenchText,
            fontSize: 12,
            fontWeight: FontWeight.w500,
          ),
        ),
      ],
    );
  }
}
