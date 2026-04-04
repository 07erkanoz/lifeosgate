import 'dart:async';
import 'dart:io';

import 'package:dartssh2/dartssh2.dart';
import 'package:fluent_ui/fluent_ui.dart';
import 'package:lifeos_sftp_drive/src/models/connection_profile.dart';
import 'package:lifeos_sftp_drive/src/models/log_entry.dart';
import 'package:lifeos_sftp_drive/src/services/linux_mount_service.dart';
import 'package:lifeos_sftp_drive/src/services/windows_mount_service.dart';
import 'package:lifeos_sftp_drive/src/state/app_controller.dart';
import 'package:lifeos_sftp_drive/src/utils/platform_utils.dart' as pu;
import 'package:lifeos_sftp_drive/src/ui/theme_tokens.dart';
import 'package:lifeos_sftp_drive/src/services/ssh_config_import.dart';
import 'package:lifeos_sftp_drive/src/ui/widgets/connection_dialog.dart';

class VaultsWorkbenchView extends StatefulWidget {
  const VaultsWorkbenchView({
    super.key,
    required this.appController,
    required this.selectedProfileId,
    required this.onProfileSelected,
    required this.onOpenTerminal,
    required this.onOpenSftp,
  });

  final AppController appController;
  final String? selectedProfileId;
  final ValueChanged<String?> onProfileSelected;
  final ValueChanged<ConnectionProfile> onOpenTerminal;
  final ValueChanged<ConnectionProfile> onOpenSftp;

  @override
  State<VaultsWorkbenchView> createState() => _VaultsWorkbenchViewState();
}

class _VaultsWorkbenchViewState extends State<VaultsWorkbenchView> {
  final _searchCtrl = TextEditingController();
  final _winMountService = WindowsMountService();
  final _linuxMountService = LinuxMountService();

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.appController.strings;
    final profiles = _filtered(widget.appController.connections);
    final selected =
        profiles.firstWhereOrNull((p) => p.id == widget.selectedProfileId) ??
        (profiles.isEmpty ? null : profiles.first);
    final isMobile = pu.isMobile;
    final searchBox = Container(
      height: 36,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: BoxDecoration(
        color: workbenchPanelAlt,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        children: [
          Icon(FluentIcons.search, size: 13, color: workbenchTextMuted),
          const SizedBox(width: 8),
          Expanded(
            child: TextBox(
              controller: _searchCtrl,
              onChanged: (_) => setState(() {}),
              style: TextStyle(color: workbenchText, fontSize: 13),
              placeholder: s.hostSearchPlaceholder,
              placeholderStyle: TextStyle(
                color: workbenchTextFaint,
                fontSize: 13,
              ),
              decoration: WidgetStateProperty.all(
                BoxDecoration(color: Color(0x00000000)),
              ),
            ),
          ),
        ],
      ),
    );

    if (selected != null && selected.id != widget.selectedProfileId) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        widget.onProfileSelected(selected.id);
      });
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Top row: search + buttons
          if (isMobile) ...[
            Row(
              children: [
                Expanded(child: searchBox),
                const SizedBox(width: 10),
                _Btn(
                  icon: FluentIcons.server,
                  label: s.newConnection.toUpperCase(),
                  accent: true,
                  onPressed: () =>
                      showConnectionDialog(context, widget.appController),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              s.isTr
                  ? 'İpucu: Sunucuya dokununca SSH terminali açılır.'
                  : 'Tip: Tap a server to open SSH terminal.',
              style: TextStyle(color: workbenchTextFaint, fontSize: 11),
            ),
          ] else
            Row(
              children: [
                Expanded(child: searchBox),
                const SizedBox(width: 10),
                _Btn(
                  icon: FluentIcons.server,
                  label: s.newConnection.toUpperCase(),
                  accent: true,
                  onPressed: () =>
                      showConnectionDialog(context, widget.appController),
                ),
                const SizedBox(width: 6),
                _Btn(
                  icon: FluentIcons.command_prompt,
                  label: s.openTerminal.toUpperCase(),
                  onPressed: selected == null
                      ? null
                      : () => widget.onOpenTerminal(selected),
                ),
                const SizedBox(width: 6),
                _Btn(
                  icon: FluentIcons.permissions,
                  label: 'SSH KEY',
                  onPressed: () => _showSshKeyGenerator(context, s),
                ),
                const SizedBox(width: 6),
                _Btn(
                  icon: FluentIcons.download,
                  label: 'SSH CONFIG',
                  onPressed: () => _importSshConfig(context, s),
                ),
              ],
            ),
          const SizedBox(height: 16),
          // Section label
          Text(
            s.hosts,
            style: TextStyle(
              color: workbenchTextFaint,
              fontSize: 11,
              fontWeight: FontWeight.w600,
              letterSpacing: 0.6,
            ),
          ),
          const SizedBox(height: 10),
          // Grid
          Expanded(
            child: profiles.isEmpty
                ? Center(
                    child: Text(
                      s.noHostsYet,
                      style: TextStyle(color: workbenchTextMuted, fontSize: 14),
                    ),
                  )
                : LayoutBuilder(
                    builder: (ctx, c) {
                      final cols = c.maxWidth > 900
                          ? 4
                          : c.maxWidth > 600
                          ? 3
                          : c.maxWidth > 350
                          ? 2
                          : 1;
                      return GridView.builder(
                        itemCount: profiles.length,
                        gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                          crossAxisCount: cols,
                          mainAxisSpacing: 12,
                          crossAxisSpacing: 12,
                          childAspectRatio: 2.8,
                        ),
                        itemBuilder: (_, i) {
                          final p = profiles[i];
                          return _HostCard(
                            profile: p,
                            index: i,
                            selected: p.id == selected?.id,
                            onTap: () {
                              widget.onProfileSelected(p.id);
                              if (pu.isMobile) widget.onOpenTerminal(p);
                            },
                            onDoubleTap: pu.isMobile
                                ? null
                                : () => widget.onOpenTerminal(p),
                            onContextMenu: (offset) =>
                                _showContextMenu(context, offset, p),
                            onLongPress: pu.isMobile
                                ? (offset) =>
                                      _showContextMenu(context, offset, p)
                                : null,
                          );
                        },
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }

  void _showContextMenu(
    BuildContext context,
    Offset globalPosition,
    ConnectionProfile profile,
  ) {
    final s = widget.appController.strings;
    final items = <_CtxItem>[
      _CtxItem(
        icon: FluentIcons.command_prompt,
        label: s.openTerminal,
        onTap: () {
          widget.onOpenTerminal(profile);
        },
      ),
      if (!pu.isMobile)
        _CtxItem(
          icon: FluentIcons.open_folder_horizontal,
          label: s.openSftp,
          onTap: () {
            widget.onOpenSftp(profile);
          },
        ),
      if (pu.isDesktop)
        if (!profile.mounted)
          _CtxItem(
            icon: FluentIcons.plug_connected,
            label: s.mountAsDrive,
            onTap: () {
              _mountProfile(profile);
            },
          )
        else
          _CtxItem(
            icon: FluentIcons.plug_disconnected,
            label: s.unmountDrive,
            onTap: () {
              _unmountProfile(profile);
            },
          ),
      _CtxItem(
        icon: FluentIcons.edit,
        label: s.update,
        onTap: () {
          showConnectionDialog(context, widget.appController, initial: profile);
        },
      ),
      _CtxItem(
        icon: FluentIcons.delete,
        label: 'Delete',
        danger: true,
        onTap: () {
          widget.appController.removeConnection(profile.id);
          widget.onProfileSelected(null);
        },
      ),
    ];

    showBoundedContextMenu(
      context,
      globalPosition,
      (dismiss) => _ContextMenu(
        items: items
            .map(
              (item) => _CtxItem(
                icon: item.icon,
                label: item.label,
                danger: item.danger,
                onTap: () {
                  dismiss();
                  item.onTap();
                },
              ),
            )
            .toList(),
      ),
      menuWidth: 200,
      menuHeight: (items.length * 34 + 12).toDouble(),
    );
  }

  Future<void> _importSshConfig(BuildContext context, dynamic s) async {
    final imported = await SshConfigImport.importFromDefault();
    if (!context.mounted) return;
    if (imported.isEmpty) {
      showDialog(
        context: context,
        builder: (ctx) => ContentDialog(
          title: Text(s.isTr ? 'SSH Config' : 'SSH Config'),
          content: Text(
            s.isTr
                ? '~/.ssh/config dosyası bulunamadı veya boş.'
                : '~/.ssh/config file not found or empty.',
          ),
          actions: [
            Button(onPressed: () => Navigator.pop(ctx), child: Text('OK')),
          ],
        ),
      );
      return;
    }
    for (final p in imported) {
      widget.appController.addConnection(
        name: p.name,
        host: p.host,
        port: p.port,
        username: p.username,
        remotePath: p.remotePath,
        privateKeyPath: p.privateKeyPath,
      );
    }
    if (context.mounted) {
      showDialog(
        context: context,
        builder: (ctx) => ContentDialog(
          title: Text(s.isTr ? 'İçe Aktarıldı' : 'Imported'),
          content: Text(
            s.isTr
                ? '${imported.length} sunucu eklendi.'
                : '${imported.length} servers added.',
          ),
          actions: [
            FilledButton(
              onPressed: () => Navigator.pop(ctx),
              child: Text('OK'),
            ),
          ],
        ),
      );
    }
  }

  Future<void> _mountProfile(ConnectionProfile profile) async {
    try {
      MountResult result;
      if (pu.isWindows) {
        result = await _winMountService.mount(profile);
      } else if (pu.isLinux) {
        result = await _linuxMountService.mount(profile);
      } else {
        throw Exception('Mount not supported on this platform');
      }
      widget.appController.markMounted(
        profile.id,
        source: ActionSource.ui,
        driveLetter: result.driveLetter,
      );
      widget.appController.addLog(
        'Mounted ${profile.name} → ${result.driveLetter}',
        level: LogLevel.info,
      );
    } catch (e) {
      widget.appController.addLog('Mount failed: $e', level: LogLevel.error);
      if (mounted) {
        final s = widget.appController.strings;
        showDialog(
          context: context,
          builder: (ctx) => ContentDialog(
            title: Text(s.isTr ? 'Bağlama Hatası' : 'Mount Error'),
            content: SelectableText('$e', style: const TextStyle(fontSize: 12)),
            actions: [
              FilledButton(
                onPressed: () => Navigator.pop(ctx),
                child: Text('OK'),
              ),
            ],
          ),
        );
      }
    }
  }

  Future<void> _unmountProfile(ConnectionProfile profile) async {
    try {
      final mountPoint =
          profile.mountedDriveLetter ?? profile.preferredDriveLetter;
      if (mountPoint == null || mountPoint.isEmpty) return;
      if (pu.isWindows) {
        await _winMountService.unmount(mountPoint);
      } else if (pu.isLinux) {
        await _linuxMountService.unmount(mountPoint);
      }
      widget.appController.markUnmounted(profile.id, source: ActionSource.ui);
      widget.appController.addLog(
        'Unmounted ${profile.name}',
        level: LogLevel.info,
      );
    } catch (e) {
      widget.appController.addLog('Unmount failed: $e', level: LogLevel.error);
      if (mounted) {
        showDialog(
          context: context,
          builder: (ctx) => ContentDialog(
            title: Text('Unmount Error'),
            content: SelectableText('$e', style: const TextStyle(fontSize: 12)),
            actions: [
              FilledButton(
                onPressed: () => Navigator.pop(ctx),
                child: Text('OK'),
              ),
            ],
          ),
        );
      }
    }
  }

  void _showSshKeyGenerator(BuildContext context, dynamic s) {
    final nameCtrl = TextEditingController(text: 'id_ed25519');
    final commentCtrl = TextEditingController(text: 'lifeos-gate');
    String keyType = 'ed25519';
    String? result;
    String? pubKey;
    String? generatedKeyPath;
    bool generating = false;
    bool deploying = false;

    // Find ssh-keygen path (Windows may need explicit path)
    String sshKeygenPath = 'ssh-keygen';
    if (Platform.isWindows) {
      const candidates = [
        r'C:\Windows\System32\OpenSSH\ssh-keygen.exe',
        r'C:\Program Files\Git\usr\bin\ssh-keygen.exe',
        r'C:\Program Files (x86)\Git\usr\bin\ssh-keygen.exe',
      ];
      for (final c in candidates) {
        if (File(c).existsSync()) {
          sshKeygenPath = c;
          break;
        }
      }
    }

    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) {
          return ContentDialog(
            title: Text(s.isTr ? 'SSH Key Oluştur' : 'Generate SSH Key'),
            content: SizedBox(
              width: 500,
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                s.isTr ? 'Dosya Adı' : 'File Name',
                                style: TextStyle(
                                  color: workbenchTextMuted,
                                  fontSize: 12,
                                ),
                              ),
                              const SizedBox(height: 4),
                              TextBox(
                                controller: nameCtrl,
                                style: const TextStyle(fontSize: 13),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(width: 12),
                        Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              s.isTr ? 'Tür' : 'Type',
                              style: TextStyle(
                                color: workbenchTextMuted,
                                fontSize: 12,
                              ),
                            ),
                            const SizedBox(height: 4),
                            ComboBox<String>(
                              value: keyType,
                              items: [
                                ComboBoxItem(
                                  value: 'ed25519',
                                  child: Text(
                                    'Ed25519 (${s.isTr ? "Önerilen" : "Recommended"})',
                                    style: const TextStyle(fontSize: 12),
                                  ),
                                ),
                                const ComboBoxItem(
                                  value: 'rsa',
                                  child: Text(
                                    'RSA 4096',
                                    style: TextStyle(fontSize: 12),
                                  ),
                                ),
                                const ComboBoxItem(
                                  value: 'ecdsa',
                                  child: Text(
                                    'ECDSA',
                                    style: TextStyle(fontSize: 12),
                                  ),
                                ),
                              ],
                              onChanged: (v) {
                                if (v != null)
                                  setDialogState(() => keyType = v);
                              },
                            ),
                          ],
                        ),
                      ],
                    ),
                    const SizedBox(height: 10),
                    Text(
                      s.isTr ? 'Yorum' : 'Comment',
                      style: TextStyle(color: workbenchTextMuted, fontSize: 12),
                    ),
                    const SizedBox(height: 4),
                    TextBox(
                      controller: commentCtrl,
                      style: const TextStyle(fontSize: 13),
                    ),
                    const SizedBox(height: 12),
                    Text(
                      '${s.isTr ? "Konum" : "Location"}: ${pu.homePath}${Platform.pathSeparator}.ssh${Platform.pathSeparator}${nameCtrl.text}',
                      style: TextStyle(color: workbenchTextFaint, fontSize: 11),
                    ),
                    if (generating || deploying) ...[
                      const SizedBox(height: 12),
                      Row(
                        children: [
                          const SizedBox(
                            width: 16,
                            height: 16,
                            child: ProgressRing(strokeWidth: 2),
                          ),
                          const SizedBox(width: 8),
                          Text(
                            deploying
                                ? (s.isTr
                                      ? 'Sunucuya yükleniyor...'
                                      : 'Deploying to server...')
                                : (s.isTr
                                      ? 'Oluşturuluyor...'
                                      : 'Generating...'),
                            style: TextStyle(
                              color: workbenchTextMuted,
                              fontSize: 11,
                            ),
                          ),
                        ],
                      ),
                    ],
                    if (result != null) ...[
                      const SizedBox(height: 12),
                      Container(
                        padding: const EdgeInsets.all(8),
                        decoration: BoxDecoration(
                          color: result!.startsWith('Error')
                              ? workbenchDanger.withValues(alpha: 0.08)
                              : workbenchSuccess.withValues(alpha: 0.08),
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: Text(
                          result!,
                          style: TextStyle(
                            color: result!.startsWith('Error')
                                ? workbenchDanger
                                : workbenchSuccess,
                            fontSize: 11,
                          ),
                        ),
                      ),
                    ],
                    if (pubKey != null) ...[
                      const SizedBox(height: 8),
                      Text(
                        s.isTr
                            ? 'Public Key (sunucuya ekleyin):'
                            : 'Public Key (add to server):',
                        style: TextStyle(
                          color: workbenchTextMuted,
                          fontSize: 11,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Container(
                        padding: const EdgeInsets.all(8),
                        decoration: BoxDecoration(
                          color: workbenchPanelAlt,
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: SelectableText(
                          pubKey!,
                          style: TextStyle(
                            color: workbenchText,
                            fontSize: 10,
                            fontFamily: 'monospace',
                          ),
                        ),
                      ),
                      const SizedBox(height: 8),
                      // Deploy to selected server button
                      if (widget.appController.connections.isNotEmpty) ...[
                        Text(
                          s.isTr
                              ? 'Sunucuya otomatik yükle:'
                              : 'Auto-deploy to server:',
                          style: TextStyle(
                            color: workbenchTextMuted,
                            fontSize: 11,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Wrap(
                          spacing: 6,
                          runSpacing: 4,
                          children: [
                            for (final p in widget.appController.connections)
                              _Btn(
                                icon: FluentIcons.upload,
                                label: p.name,
                                accent: false,
                                onPressed: deploying
                                    ? null
                                    : () async {
                                        setDialogState(() {
                                          deploying = true;
                                        });
                                        try {
                                          final socket =
                                              await SSHSocket.connect(
                                                p.host,
                                                p.port,
                                                timeout: const Duration(
                                                  seconds: 10,
                                                ),
                                              );
                                          final client = SSHClient(
                                            socket,
                                            username: p.username,
                                            onPasswordRequest: () => p.password,
                                          );
                                          await client.run(
                                            'mkdir -p ~/.ssh && chmod 700 ~/.ssh',
                                          );
                                          // Append public key (avoid duplicates)
                                          final escaped = pubKey!.replaceAll(
                                            "'",
                                            "'\\''",
                                          );
                                          await client.run(
                                            "grep -qF '$escaped' ~/.ssh/authorized_keys 2>/dev/null || echo '$escaped' >> ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys",
                                          );
                                          client.close();
                                          // Auto-set private key path on the profile
                                          if (generatedKeyPath != null) {
                                            widget.appController
                                                .updateConnection(
                                                  id: p.id,
                                                  name: p.name,
                                                  host: p.host,
                                                  port: p.port,
                                                  username: p.username,
                                                  remotePath: p.remotePath,
                                                  password: p.password,
                                                  privateKeyPath:
                                                      generatedKeyPath,
                                                  group: p.group,
                                                  color: p.color,
                                                  startupCommands:
                                                      p.startupCommands,
                                                  notes: p.notes,
                                                );
                                          }
                                          setDialogState(() {
                                            deploying = false;
                                            result = s.isTr
                                                ? 'Key ${p.name} sunucusuna yüklendi ve profil güncellendi!'
                                                : 'Key deployed to ${p.name} and profile updated!';
                                          });
                                        } catch (e) {
                                          setDialogState(() {
                                            deploying = false;
                                            result = 'Error: $e';
                                          });
                                        }
                                      },
                              ),
                          ],
                        ),
                      ],
                    ],
                  ],
                ),
              ),
            ),
            actions: [
              Button(
                onPressed: () => Navigator.pop(ctx),
                child: Text(s.isTr ? 'Kapat' : 'Close'),
              ),
              FilledButton(
                onPressed: generating
                    ? null
                    : () async {
                        setDialogState(() {
                          generating = true;
                          result = null;
                          pubKey = null;
                          generatedKeyPath = null;
                        });
                        try {
                          final sshDir =
                              '${pu.homePath}${Platform.pathSeparator}.ssh';
                          final keyPath =
                              '$sshDir${Platform.pathSeparator}${nameCtrl.text.trim()}';
                          await Directory(sshDir).create(recursive: true);

                          final exists = await File(keyPath).exists();
                          if (exists) {
                            await File(keyPath).delete();
                            final pubFile = File('$keyPath.pub');
                            if (await pubFile.exists()) await pubFile.delete();
                          }

                          final args = <String>['-q', '-t', keyType];
                          if (keyType == 'rsa') args.addAll(['-b', '4096']);
                          args.addAll([
                            '-C',
                            commentCtrl.text.trim(),
                            '-f',
                            keyPath,
                            '-N',
                            '',
                          ]);
                          final proc = await Process.run(sshKeygenPath, args);
                          if (proc.exitCode == 0) {
                            final pub = await File(
                              '$keyPath.pub',
                            ).readAsString();
                            setDialogState(() {
                              generatedKeyPath = keyPath;
                              result = s.isTr
                                  ? '${exists ? "Key yeniden oluşturuldu" : "Key oluşturuldu"}: $keyPath'
                                  : '${exists ? "Key regenerated" : "Key generated"}: $keyPath';
                              pubKey = pub.trim();
                              generating = false;
                            });
                          } else {
                            final errMsg = (proc.stderr as String).trim();
                            setDialogState(() {
                              result =
                                  'Error: ${errMsg.isNotEmpty ? errMsg : proc.stdout}';
                              generating = false;
                            });
                          }
                        } catch (e) {
                          setDialogState(() {
                            result = 'Error: $e';
                            generating = false;
                          });
                        }
                      },
                child: Text(s.isTr ? 'Oluştur' : 'Generate'),
              ),
            ],
          );
        },
      ),
    );
  }

  List<ConnectionProfile> _filtered(List<ConnectionProfile> src) {
    final q = _searchCtrl.text.trim().toLowerCase();
    if (q.isEmpty) return src;
    return src
        .where(
          (p) =>
              p.name.toLowerCase().contains(q) ||
              p.host.toLowerCase().contains(q) ||
              p.username.toLowerCase().contains(q),
        )
        .toList();
  }
}

// ─── Context Menu ────────────────────────────────────────────────────

class _CtxItem {
  const _CtxItem({
    required this.icon,
    required this.label,
    required this.onTap,
    this.danger = false,
  });
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final bool danger;
}

class _ContextMenu extends StatelessWidget {
  const _ContextMenu({required this.items});
  final List<_CtxItem> items;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 200,
      decoration: BoxDecoration(
        color: workbenchMenuBg,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: workbenchBorder, width: 0.5),
        boxShadow: const [
          BoxShadow(color: Color(0x60000000), blurRadius: 20, spreadRadius: 2),
        ],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [for (final item in items) _ContextMenuItem(item: item)],
      ),
    );
  }
}

class _ContextMenuItem extends StatefulWidget {
  const _ContextMenuItem({required this.item});
  final _CtxItem item;
  @override
  State<_ContextMenuItem> createState() => _ContextMenuItemState();
}

class _ContextMenuItemState extends State<_ContextMenuItem> {
  bool _h = false;
  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      onEnter: (_) => setState(() => _h = true),
      onExit: (_) => setState(() => _h = false),
      child: GestureDetector(
        onTap: widget.item.onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(
            color: _h ? workbenchHover : Colors.transparent,
            borderRadius: BorderRadius.circular(6),
          ),
          child: Row(
            children: [
              Icon(
                widget.item.icon,
                size: 13,
                color: widget.item.danger
                    ? workbenchDanger
                    : workbenchTextMuted,
              ),
              const SizedBox(width: 10),
              Text(
                widget.item.label,
                style: TextStyle(
                  color: widget.item.danger ? workbenchDanger : workbenchText,
                  fontSize: 12,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ─── Host Card ───────────────────────────────────────────────────────

class _HostCard extends StatefulWidget {
  const _HostCard({
    required this.profile,
    required this.index,
    required this.selected,
    required this.onTap,
    this.onDoubleTap,
    this.onContextMenu,
    this.onLongPress,
  });
  final ConnectionProfile profile;
  final int index;
  final bool selected;
  final VoidCallback onTap;
  final VoidCallback? onDoubleTap;
  final void Function(Offset)? onContextMenu;
  final void Function(Offset)? onLongPress;
  @override
  State<_HostCard> createState() => _HostCardState();
}

class _HostCardState extends State<_HostCard> {
  bool _h = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      onEnter: (_) => setState(() => _h = true),
      onExit: (_) => setState(() => _h = false),
      child: GestureDetector(
        onTap: widget.onTap,
        onDoubleTap: widget.onDoubleTap,
        onSecondaryTapUp: widget.onContextMenu == null
            ? null
            : (d) => widget.onContextMenu!(d.globalPosition),
        onLongPressStart: widget.onLongPress == null
            ? null
            : (d) => widget.onLongPress!(d.globalPosition),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          decoration: BoxDecoration(
            color: _h ? workbenchHover : workbenchPanelAlt,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(
              color: widget.selected ? workbenchAccent : Colors.transparent,
              width: widget.selected ? 1.5 : 0,
            ),
            boxShadow: cardShadow,
          ),
          child: Row(
            children: [
              Container(
                width: 36,
                height: 36,
                decoration: BoxDecoration(
                  color: hostIconColorFor(widget.index),
                  borderRadius: BorderRadius.circular(9),
                ),
                child: const Icon(
                  FluentIcons.server,
                  color: Colors.white,
                  size: 14,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Text(
                      widget.profile.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: workbenchText,
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Row(
                      children: [
                        Text(
                          'ssh, ${widget.profile.username}',
                          style: TextStyle(
                            color: workbenchTextMuted,
                            fontSize: 12,
                          ),
                        ),
                        if (widget.profile.group != null) ...[
                          const SizedBox(width: 6),
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 5,
                              vertical: 1,
                            ),
                            decoration: BoxDecoration(
                              color: workbenchAccent.withValues(alpha: 0.12),
                              borderRadius: BorderRadius.circular(3),
                            ),
                            child: Text(
                              widget.profile.group!,
                              style: TextStyle(
                                color: workbenchAccent,
                                fontSize: 9,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                        ],
                      ],
                    ),
                  ],
                ),
              ),
              if (widget.profile.mounted)
                Container(
                  width: 8,
                  height: 8,
                  decoration: BoxDecoration(
                    color: workbenchSuccess,
                    shape: BoxShape.circle,
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

// ─── Button ──────────────────────────────────────────────────────────

class _Btn extends StatefulWidget {
  const _Btn({
    required this.icon,
    required this.label,
    this.accent = false,
    this.onPressed,
  });
  final IconData icon;
  final String label;
  final bool accent;
  final VoidCallback? onPressed;
  @override
  State<_Btn> createState() => _BtnState();
}

class _BtnState extends State<_Btn> {
  bool _h = false;
  @override
  Widget build(BuildContext context) {
    final en = widget.onPressed != null;
    final bg = widget.accent ? workbenchAccent : workbenchPanelAlt;
    return MouseRegion(
      onEnter: (_) => setState(() => _h = true),
      onExit: (_) => setState(() => _h = false),
      child: GestureDetector(
        onTap: widget.onPressed,
        child: Container(
          height: 36,
          padding: const EdgeInsets.symmetric(horizontal: 14),
          decoration: BoxDecoration(
            color: _h && en ? Color.lerp(bg, Colors.white, 0.08)! : bg,
            borderRadius: BorderRadius.circular(8),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                widget.icon,
                size: 12,
                color: en ? Colors.white : workbenchTextFaint,
              ),
              const SizedBox(width: 8),
              Text(
                widget.label,
                style: TextStyle(
                  color: en ? Colors.white : workbenchTextFaint,
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  letterSpacing: 0.3,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

extension _IterableExt<T> on Iterable<T> {
  T? firstWhereOrNull(bool Function(T) test) {
    for (final item in this) {
      if (test(item)) return item;
    }
    return null;
  }
}
