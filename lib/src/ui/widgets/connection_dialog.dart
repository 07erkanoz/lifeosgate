import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter/material.dart' show Material;
import 'package:lifeos_sftp_drive/src/utils/platform_utils.dart' as pu;
import 'package:lifeos_sftp_drive/src/models/connection_profile.dart';
import 'package:lifeos_sftp_drive/src/state/app_controller.dart';
import 'package:lifeos_sftp_drive/src/ui/theme_tokens.dart';

Future<void> showConnectionDialog(
  BuildContext context,
  AppController appController, {
  ConnectionProfile? initial,
}) async {
  final s = appController.strings;
  final isEdit = initial != null;
  final formKey = GlobalKey<FormState>();
  final nameCtrl = TextEditingController(text: initial?.name ?? '');
  final hostCtrl = TextEditingController(text: initial?.host ?? '');
  final userCtrl = TextEditingController(text: initial?.username ?? '');
  final pathCtrl = TextEditingController(text: initial?.remotePath ?? '');
  final passwordCtrl = TextEditingController(text: initial?.password ?? '');
  final keyPathCtrl = TextEditingController(
    text: initial?.privateKeyPath ?? '',
  );
  final driveCtrl = TextEditingController(
    text: initial?.preferredDriveLetter ?? '',
  );
  final portCtrl = TextEditingController(text: '${initial?.port ?? 22}');
  final groupCtrl = TextEditingController(text: initial?.group ?? '');
  final notesCtrl = TextEditingController(text: initial?.notes ?? '');
  final startupCtrl = TextEditingController(
    text: initial?.startupCommands.join('\n') ?? '',
  );
  final initialHostKey = initial == null
      ? ''
      : '${initial.username}@${initial.host}:${initial.port}';
  final initialTmuxSessions = initial == null
      ? const <String>['main']
      : appController.getSshNamedSessionsForHost(initialHostKey);
  final initialActiveTmuxSession = initial == null
      ? 'main'
      : appController.getSshActiveSessionNameForHost(initialHostKey);
  final tmuxSessionsCtrl = TextEditingController(
    text: initialTmuxSessions.join(', '),
  );
  final tmuxActiveCtrl = TextEditingController(text: initialActiveTmuxSession);
  var tmuxEnabled = initial?.tmuxEnabled ?? true;
  final dbUserCtrl = TextEditingController(text: initial?.dbUser ?? 'root');
  final dbPassCtrl = TextEditingController(text: initial?.dbPassword ?? '');

  await showDialog<void>(
    context: context,
    barrierDismissible: true,
    builder: (context) {
      return StatefulBuilder(
        builder: (context, setDialogState) {
          return Center(
            child: Container(
              width: 520,
              constraints: const BoxConstraints(maxHeight: 640),
              decoration: BoxDecoration(
                color: workbenchPanelAlt,
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: workbenchBorder),
                boxShadow: panelShadow,
              ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(14),
                child: Material(
                  color: Colors.transparent,
                  child: Form(
                    key: formKey,
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Container(
                          padding: const EdgeInsets.fromLTRB(24, 20, 16, 16),
                          decoration: BoxDecoration(
                            border: Border(
                              bottom: BorderSide(color: workbenchDivider),
                            ),
                          ),
                          child: Row(
                            children: [
                              Container(
                                width: 36,
                                height: 36,
                                decoration: BoxDecoration(
                                  color: workbenchAccent,
                                  borderRadius: BorderRadius.circular(9),
                                ),
                                child: const Icon(
                                  FluentIcons.server,
                                  color: Colors.white,
                                  size: 16,
                                ),
                              ),
                              const SizedBox(width: 14),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      isEdit ? 'Edit Host' : 'New Host',
                                      style: TextStyle(
                                        color: workbenchText,
                                        fontSize: 17,
                                        fontWeight: FontWeight.w600,
                                      ),
                                    ),
                                    const SizedBox(height: 2),
                                    Text(
                                      isEdit
                                          ? 'Update SSH connection details'
                                          : 'Add a new SSH connection',
                                      style: TextStyle(
                                        color: workbenchTextMuted,
                                        fontSize: 12,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                              GestureDetector(
                                onTap: () => Navigator.pop(context),
                                child: Container(
                                  width: 32,
                                  height: 32,
                                  decoration: BoxDecoration(
                                    color: workbenchHover,
                                    borderRadius: BorderRadius.circular(8),
                                  ),
                                  child: Icon(
                                    FluentIcons.chrome_close,
                                    size: 10,
                                    color: workbenchTextMuted,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                        Flexible(
                          child: SingleChildScrollView(
                            padding: const EdgeInsets.fromLTRB(24, 18, 24, 8),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                _DialogField(
                                  label: 'Label',
                                  hint: 'My Server',
                                  controller: nameCtrl,
                                  validator: (v) =>
                                      (v == null || v.trim().isEmpty)
                                      ? s.requiredField
                                      : null,
                                ),
                                const SizedBox(height: 14),
                                Row(
                                  children: [
                                    Expanded(
                                      flex: 3,
                                      child: _DialogField(
                                        label: 'Hostname / IP',
                                        hint: '192.168.1.100',
                                        controller: hostCtrl,
                                        validator: (v) =>
                                            (v == null || v.trim().isEmpty)
                                            ? s.requiredField
                                            : null,
                                      ),
                                    ),
                                    const SizedBox(width: 12),
                                    SizedBox(
                                      width: 90,
                                      child: _DialogField(
                                        label: 'Port',
                                        hint: '22',
                                        controller: portCtrl,
                                        validator: (v) {
                                          final port = int.tryParse(
                                            (v ?? '').trim(),
                                          );
                                          if (port == null ||
                                              port < 1 ||
                                              port > 65535) {
                                            return s.invalidPort;
                                          }
                                          return null;
                                        },
                                      ),
                                    ),
                                  ],
                                ),
                                const SizedBox(height: 14),
                                _DialogField(
                                  label: 'Username',
                                  hint: 'root',
                                  controller: userCtrl,
                                  validator: (v) =>
                                      (v == null || v.trim().isEmpty)
                                      ? s.requiredField
                                      : null,
                                ),
                                const SizedBox(height: 14),
                                _DialogField(
                                  label: 'Password',
                                  hint: 'Leave empty if using key',
                                  controller: passwordCtrl,
                                  obscure: true,
                                ),
                                const SizedBox(height: 14),
                                _DialogField(
                                  label: 'SSH Key Path',
                                  hint: pu.isWindows
                                      ? r'C:\Users\you\.ssh\id_rsa'
                                      : '~/.ssh/id_rsa',
                                  controller: keyPathCtrl,
                                ),
                                const SizedBox(height: 14),
                                Row(
                                  children: [
                                    Expanded(
                                      child: _DialogField(
                                        label: 'Startup Directory',
                                        hint: '/home/user',
                                        controller: pathCtrl,
                                      ),
                                    ),
                                    const SizedBox(width: 12),
                                    SizedBox(
                                      width: 100,
                                      child: _DialogField(
                                        label: 'Drive',
                                        hint: 'Z',
                                        controller: driveCtrl,
                                      ),
                                    ),
                                  ],
                                ),
                                const SizedBox(height: 14),
                                _DialogField(
                                  label: s.isTr ? 'Grup' : 'Group',
                                  hint: 'Production, Staging, Dev...',
                                  controller: groupCtrl,
                                ),
                                const SizedBox(height: 14),
                                _DialogField(
                                  label: s.isTr
                                      ? 'Başlangıç Komutları (satır başı)'
                                      : 'Startup Commands (one per line)',
                                  hint: 'cd /var/www\nls -la',
                                  controller: startupCtrl,
                                ),
                                const SizedBox(height: 14),
                                Container(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 12,
                                    vertical: 10,
                                  ),
                                  decoration: BoxDecoration(
                                    color: workbenchEditorBg,
                                    borderRadius: BorderRadius.circular(8),
                                    border: Border.all(color: workbenchBorder),
                                  ),
                                  child: Row(
                                    children: [
                                      Expanded(
                                        child: Column(
                                          crossAxisAlignment:
                                              CrossAxisAlignment.start,
                                          children: [
                                            Text(
                                              s.isTr
                                                  ? 'tmux Kalıcı Oturum'
                                                  : 'tmux Persistent Session',
                                              style: TextStyle(
                                                color: workbenchText,
                                                fontSize: 12,
                                                fontWeight: FontWeight.w600,
                                              ),
                                            ),
                                            const SizedBox(height: 2),
                                            Text(
                                              s.isTr
                                                  ? 'Bu host için tmux tabanlı kalıcı oturum kullan'
                                                  : 'Use tmux-based persistent session for this host',
                                              style: TextStyle(
                                                color: workbenchTextMuted,
                                                fontSize: 11,
                                              ),
                                            ),
                                          ],
                                        ),
                                      ),
                                      const SizedBox(width: 12),
                                      ToggleSwitch(
                                        checked: tmuxEnabled,
                                        onChanged: (value) {
                                          setDialogState(() {
                                            tmuxEnabled = value;
                                          });
                                        },
                                      ),
                                    ],
                                  ),
                                ),
                                if (tmuxEnabled) ...[
                                  const SizedBox(height: 14),
                                  _DialogField(
                                    label: s.isTr
                                        ? 'tmux Oturumları (virgülle)'
                                        : 'tmux Sessions (comma separated)',
                                    hint: 'main, prod, debug',
                                    controller: tmuxSessionsCtrl,
                                  ),
                                  const SizedBox(height: 14),
                                  _DialogField(
                                    label: s.isTr
                                        ? 'Aktif tmux Oturumu'
                                        : 'Active tmux Session',
                                    hint: 'main',
                                    controller: tmuxActiveCtrl,
                                  ),
                                ],
                                const SizedBox(height: 14),
                                _DialogField(
                                  label: s.isTr ? 'Notlar' : 'Notes',
                                  hint: s.isTr
                                      ? 'Sunucu hakkında notlar...'
                                      : 'Notes about this server...',
                                  controller: notesCtrl,
                                ),
                                const SizedBox(height: 14),
                                Row(
                                  children: [
                                    Expanded(
                                      child: _DialogField(
                                        label: s.isTr
                                            ? 'DB Kullanıcı'
                                            : 'DB User',
                                        hint: 'root',
                                        controller: dbUserCtrl,
                                      ),
                                    ),
                                    const SizedBox(width: 10),
                                    Expanded(
                                      child: _DialogField(
                                        label: s.isTr
                                            ? 'DB Parola'
                                            : 'DB Password',
                                        hint: s.isTr
                                            ? 'Veritabanı parolası'
                                            : 'Database password',
                                        controller: dbPassCtrl,
                                        obscure: true,
                                      ),
                                    ),
                                  ],
                                ),
                              ],
                            ),
                          ),
                        ),
                        Container(
                          padding: const EdgeInsets.fromLTRB(24, 14, 24, 18),
                          decoration: BoxDecoration(
                            border: Border(
                              top: BorderSide(color: workbenchDivider),
                            ),
                          ),
                          child: Row(
                            children: [
                              Icon(
                                FluentIcons.info,
                                size: 12,
                                color: workbenchTextFaint,
                              ),
                              const SizedBox(width: 8),
                              Expanded(
                                child: Text(
                                  s.authenticationHint,
                                  style: TextStyle(
                                    color: workbenchTextFaint,
                                    fontSize: 11,
                                  ),
                                ),
                              ),
                              const SizedBox(width: 16),
                              GestureDetector(
                                onTap: () => Navigator.pop(context),
                                child: Container(
                                  height: 36,
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 20,
                                  ),
                                  decoration: BoxDecoration(
                                    color: workbenchHover,
                                    borderRadius: BorderRadius.circular(8),
                                  ),
                                  child: Center(
                                    child: Text(
                                      s.cancel,
                                      style: TextStyle(
                                        color: workbenchTextMuted,
                                        fontSize: 13,
                                        fontWeight: FontWeight.w500,
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                              const SizedBox(width: 10),
                              GestureDetector(
                                onTap: () {
                                  if (formKey.currentState?.validate() !=
                                      true) {
                                    return;
                                  }
                                  final port = int.parse(portCtrl.text.trim());
                                  final hostKey =
                                      '${userCtrl.text.trim()}@${hostCtrl.text.trim()}:$port';
                                  final tmuxSessions = tmuxSessionsCtrl.text
                                      .split(RegExp(r'[,\n]'))
                                      .map((e) => e.trim())
                                      .where((e) => e.isNotEmpty)
                                      .toList();
                                  if (tmuxSessions.isEmpty) {
                                    tmuxSessions.add('main');
                                  }
                                  var activeTmuxSession = tmuxActiveCtrl.text
                                      .trim();
                                  if (activeTmuxSession.isEmpty) {
                                    activeTmuxSession = tmuxSessions.first;
                                  }
                                  if (!tmuxSessions.contains(
                                    activeTmuxSession,
                                  )) {
                                    tmuxSessions.add(activeTmuxSession);
                                  }
                                  final startupCmds =
                                      startupCtrl.text.trim().isEmpty
                                      ? <String>[]
                                      : startupCtrl.text
                                            .trim()
                                            .split('\n')
                                            .where((l) => l.trim().isNotEmpty)
                                            .toList();

                                  if (isEdit) {
                                    appController.updateConnection(
                                      id: initial.id,
                                      name: nameCtrl.text.trim(),
                                      host: hostCtrl.text.trim(),
                                      port: port,
                                      username: userCtrl.text.trim(),
                                      remotePath: pathCtrl.text.trim(),
                                      password: passwordCtrl.text,
                                      privateKeyPath:
                                          keyPathCtrl.text.trim().isEmpty
                                          ? null
                                          : keyPathCtrl.text.trim(),
                                      preferredDriveLetter:
                                          driveCtrl.text.trim().isEmpty
                                          ? null
                                          : driveCtrl.text.trim().toUpperCase(),
                                      group: groupCtrl.text.trim().isEmpty
                                          ? null
                                          : groupCtrl.text.trim(),
                                      startupCommands: startupCmds,
                                      notes: notesCtrl.text.trim(),
                                      tmuxEnabled: tmuxEnabled,
                                      dbUser: dbUserCtrl.text.trim().isEmpty
                                          ? null
                                          : dbUserCtrl.text.trim(),
                                      dbPassword: dbPassCtrl.text.isEmpty
                                          ? null
                                          : dbPassCtrl.text,
                                    );
                                  } else {
                                    appController.addConnection(
                                      name: nameCtrl.text.trim(),
                                      host: hostCtrl.text.trim(),
                                      port: port,
                                      username: userCtrl.text.trim(),
                                      remotePath: pathCtrl.text.trim(),
                                      password: passwordCtrl.text,
                                      privateKeyPath:
                                          keyPathCtrl.text.trim().isEmpty
                                          ? null
                                          : keyPathCtrl.text.trim(),
                                      preferredDriveLetter:
                                          driveCtrl.text.trim().isEmpty
                                          ? null
                                          : driveCtrl.text.trim().toUpperCase(),
                                      group: groupCtrl.text.trim().isEmpty
                                          ? null
                                          : groupCtrl.text.trim(),
                                      startupCommands: startupCmds,
                                      notes: notesCtrl.text.trim(),
                                      tmuxEnabled: tmuxEnabled,
                                      dbUser: dbUserCtrl.text.trim().isEmpty
                                          ? null
                                          : dbUserCtrl.text.trim(),
                                      dbPassword: dbPassCtrl.text.isEmpty
                                          ? null
                                          : dbPassCtrl.text,
                                    );
                                  }

                                  if (tmuxEnabled) {
                                    appController.clearTmuxHostDecision(
                                      hostKey,
                                    );
                                    appController.setSshNamedSessionsForHost(
                                      hostKey,
                                      tmuxSessions,
                                    );
                                    appController
                                        .setSshActiveSessionNameForHost(
                                          hostKey,
                                          activeTmuxSession,
                                        );
                                  }
                                  Navigator.pop(context);
                                },
                                child: Container(
                                  height: 36,
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 24,
                                  ),
                                  decoration: BoxDecoration(
                                    color: workbenchAccent,
                                    borderRadius: BorderRadius.circular(8),
                                  ),
                                  child: Center(
                                    child: Text(
                                      isEdit ? s.update : s.save,
                                      style: const TextStyle(
                                        color: Colors.white,
                                        fontSize: 13,
                                        fontWeight: FontWeight.w600,
                                      ),
                                    ),
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
        },
      );
    },
  );
}

class _DialogField extends StatelessWidget {
  const _DialogField({
    required this.label,
    required this.hint,
    required this.controller,
    this.validator,
    this.obscure = false,
  });

  final String label;
  final String hint;
  final TextEditingController controller;
  final String? Function(String?)? validator;
  final bool obscure;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: TextStyle(
            color: workbenchTextMuted,
            fontSize: 12,
            fontWeight: FontWeight.w500,
          ),
        ),
        SizedBox(height: 6),
        TextFormBox(
          controller: controller,
          placeholder: hint,
          obscureText: obscure,
          style: TextStyle(color: workbenchText, fontSize: 14),
          validator: validator,
          decoration: WidgetStateProperty.resolveWith((states) {
            return BoxDecoration(
              color: workbenchEditorBg,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(
                color: states.contains(WidgetState.focused)
                    ? workbenchAccent
                    : workbenchBorder,
                width: states.contains(WidgetState.focused) ? 1.5 : 0.5,
              ),
            );
          }),
        ),
      ],
    );
  }
}
