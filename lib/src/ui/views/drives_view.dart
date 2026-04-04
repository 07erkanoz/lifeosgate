import 'package:fluent_ui/fluent_ui.dart';
import 'package:lifeos_sftp_drive/src/i18n/app_strings.dart';
import 'package:lifeos_sftp_drive/src/models/connection_profile.dart';
import 'package:lifeos_sftp_drive/src/models/log_entry.dart';
import 'package:lifeos_sftp_drive/src/services/windows_mount_service.dart';
import 'package:lifeos_sftp_drive/src/state/app_controller.dart';
import 'package:lifeos_sftp_drive/src/ui/theme_tokens.dart';
import 'package:lifeos_sftp_drive/src/ui/widgets/connection_dialog.dart';

enum _ConnectionFilter { all, mounted, inactive }

class DrivesView extends StatefulWidget {
  const DrivesView({super.key, required this.appController});

  final AppController appController;

  @override
  State<DrivesView> createState() => _DrivesViewState();
}

class _DrivesViewState extends State<DrivesView> {
  final _searchCtrl = TextEditingController();
  final _mountService = WindowsMountService();
  _ConnectionFilter _filter = _ConnectionFilter.all;
  String? _selectedId;
  bool _mountBusy = false;
  String? _mountStatus;
  bool _mountStatusIsError = false;

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
        profiles.firstWhereOrNull((item) => item.id == _selectedId) ??
        (profiles.isEmpty ? null : profiles.first);
    _selectedId = selected?.id;

    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        children: [
          // Summary
          Row(
            children: [
              _StatCard(
                label: s.profiles,
                value: '${widget.appController.connections.length}',
                icon: FluentIcons.plug_connected,
              ),
              const SizedBox(width: 8),
              _StatCard(
                label: s.mounted,
                value: '${widget.appController.mountedCount}',
                icon: FluentIcons.accept,
                color: workbenchAccent,
              ),
              const SizedBox(width: 8),
              _StatCard(
                label: s.inactive,
                value: '${widget.appController.connections.length - widget.appController.mountedCount}',
                icon: FluentIcons.pause,
              ),
            ],
          ),
          const SizedBox(height: 14),
          // Search & filter
          Row(
            children: [
              Expanded(
                child: Container(
                  height: 36,
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  decoration: BoxDecoration(
                    color: workbenchPanel,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: workbenchBorder, width: 0.5),
                  ),
                  child: Row(
                    children: [
                      Icon(FluentIcons.search, size: 12, color: workbenchTextMuted),
                      const SizedBox(width: 8),
                      Expanded(
                        child: TextBox(
                          controller: _searchCtrl,
                          onChanged: (_) => setState(() {}),
                          style: TextStyle(color: workbenchText, fontSize: 12),
                          placeholder: '${s.search}...',
                          placeholderStyle: TextStyle(color: workbenchTextFaint, fontSize: 12),
                          decoration: WidgetStateProperty.all(BoxDecoration(color: Color(0x00000000))),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(width: 10),
              SizedBox(
                width: 140,
                child: ComboBox<_ConnectionFilter>(
                  value: _filter,
                  isExpanded: true,
                  items: [
                    ComboBoxItem(value: _ConnectionFilter.all, child: Text(s.all)),
                    ComboBoxItem(value: _ConnectionFilter.mounted, child: Text(s.mounted)),
                    ComboBoxItem(value: _ConnectionFilter.inactive, child: Text(s.inactive)),
                  ],
                  onChanged: (value) { if (value != null) setState(() => _filter = value); },
                ),
              ),
              const SizedBox(width: 10),
              _DriveActionBtn(
                label: s.newConnection,
                icon: FluentIcons.add,
                onPressed: () => showConnectionDialog(context, widget.appController),
              ),
              const SizedBox(width: 6),
              _DriveActionBtn(
                label: s.mountAll,
                icon: FluentIcons.plug_connected,
                onPressed: widget.appController.connections.isEmpty ? null : _mountAllProfiles,
              ),
            ],
          ),
          const SizedBox(height: 12),
          if (_mountStatus != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                decoration: BoxDecoration(
                  color: _mountStatusIsError ? workbenchDanger.withValues(alpha: 0.1) : workbenchAccent.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: _mountStatusIsError ? workbenchDanger : workbenchAccent, width: 0.5),
                ),
                child: Row(
                  children: [
                    Icon(_mountStatusIsError ? FluentIcons.error_badge : FluentIcons.accept, size: 13, color: _mountStatusIsError ? workbenchDanger : workbenchAccent),
                    const SizedBox(width: 10),
                    Expanded(child: Text(_mountStatus!, style: TextStyle(color: workbenchText, fontSize: 12))),
                  ],
                ),
              ),
            ),
          // Profile list
          Expanded(
            child: Container(
              decoration: BoxDecoration(
                color: workbenchPanel,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: workbenchBorder, width: 0.5),
              ),
              child: profiles.isEmpty
                  ? Center(
                      child: Text(
                        widget.appController.connections.isEmpty ? s.createFirstProfile : s.noMatchingConnection,
                        style: TextStyle(color: workbenchTextMuted, fontSize: 13),
                      ),
                    )
                  : ListView.separated(
                      padding: const EdgeInsets.all(6),
                      itemCount: profiles.length,
                      separatorBuilder: (context, index) => const SizedBox(height: 2),
                      itemBuilder: (context, index) {
                        final profile = profiles[index];
                        return _ProfileRow(
                          strings: s,
                          profile: profile,
                          selected: profile.id == selected?.id,
                          onSelected: () => setState(() => _selectedId = profile.id),
                          onMount: () => _mountProfile(profile),
                          onUnmount: () => _unmountProfile(profile),
                          onEdit: () => showConnectionDialog(context, widget.appController, initial: profile),
                          onDelete: () {
                            widget.appController.removeConnection(profile.id);
                            setState(() { if (_selectedId == profile.id) _selectedId = null; });
                          },
                        );
                      },
                    ),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _mountProfile(ConnectionProfile? profile) async {
    if (profile == null || _mountBusy) return;
    setState(() { _mountBusy = true; _mountStatus = null; });
    try {
      final result = await _mountService.mount(profile);
      widget.appController.markMounted(profile.id, source: ActionSource.ui, driveLetter: result.driveLetter);
      _mountStatus = widget.appController.strings.mountedSuccess(profile.name, result.driveLetter);
      _mountStatusIsError = false;
    } catch (error) {
      _mountStatus = _describeMountError(profile, error);
      _mountStatusIsError = true;
      widget.appController.addLog('Mount failed for ${profile.name}: ${error is MountServiceException ? error.details ?? error.code.name : error}', level: LogLevel.error);
    } finally { if (mounted) setState(() => _mountBusy = false); }
  }

  Future<void> _mountAllProfiles() async {
    for (final profile in widget.appController.connections) { await _mountProfile(profile); }
  }

  Future<void> _unmountProfile(ConnectionProfile? profile) async {
    if (profile == null || _mountBusy) return;
    setState(() { _mountBusy = true; _mountStatus = null; });
    try {
      final driveLetter = profile.mountedDriveLetter ?? profile.preferredDriveLetter;
      if (driveLetter == null || driveLetter.isEmpty) {
        _mountStatus = widget.appController.strings.driveLetterUnknownError(profile.name);
        _mountStatusIsError = true;
        return;
      }
      await _mountService.unmount(driveLetter);
      widget.appController.markUnmounted(profile.id, source: ActionSource.ui);
      _mountStatus = widget.appController.strings.unmountedSuccess(profile.name);
      _mountStatusIsError = false;
    } catch (error) {
      _mountStatus = _describeMountError(profile, error);
      _mountStatusIsError = true;
      widget.appController.addLog('Unmount failed for ${profile.name}: ${error is MountServiceException ? error.details ?? error.code.name : error}', level: LogLevel.error);
    } finally { if (mounted) setState(() => _mountBusy = false); }
  }

  List<ConnectionProfile> _filtered(List<ConnectionProfile> source) {
    final query = _searchCtrl.text.trim().toLowerCase();
    return source.where((item) {
      final filterMatch = switch (_filter) { _ConnectionFilter.all => true, _ConnectionFilter.mounted => item.mounted, _ConnectionFilter.inactive => !item.mounted };
      final queryMatch = query.isEmpty || item.name.toLowerCase().contains(query) || item.host.toLowerCase().contains(query) || item.username.toLowerCase().contains(query);
      return filterMatch && queryMatch;
    }).toList();
  }

  String _describeMountError(ConnectionProfile profile, Object error) {
    final s = widget.appController.strings;
    if (error is MountServiceException) {
      return switch (error.code) {
        MountFailureCode.dependenciesMissing => s.mountDependenciesMissingError,
        MountFailureCode.missingCredentials => s.missingCredentialsError,
        MountFailureCode.privateKeyNotFound => s.privateKeyNotFoundError(error.details ?? '-'),
        MountFailureCode.credentialsInvalid => s.mountCredentialsInvalidError(profile.name),
        MountFailureCode.cancelled => s.mountCancelledError(profile.name),
        MountFailureCode.conflict => s.mountConflictError(profile.name),
        MountFailureCode.pathUnavailable => s.mountPathUnavailableError(profile.name),
        MountFailureCode.unexpected => s.unexpectedMountError(error.details ?? error.toString()),
      };
    }
    return s.unexpectedMountError(error.toString());
  }
}

// ─── Stat Card ───────────────────────────────────────────────────────

class _StatCard extends StatelessWidget {
  const _StatCard({required this.label, required this.value, required this.icon, this.color});
  final String label;
  final String value;
  final IconData icon;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        decoration: BoxDecoration(
          color: workbenchPanel,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: workbenchBorder, width: 0.5),
        ),
        child: Row(
          children: [
            Icon(icon, size: 16, color: color ?? workbenchTextMuted),
            const SizedBox(width: 12),
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(label, style: TextStyle(color: workbenchTextMuted, fontSize: 11)),
                const SizedBox(height: 2),
                Text(value, style: TextStyle(color: color ?? workbenchText, fontSize: 20, fontWeight: FontWeight.w700)),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

// ─── Profile Row ─────────────────────────────────────────────────────

class _ProfileRow extends StatefulWidget {
  const _ProfileRow({
    required this.strings,
    required this.profile,
    required this.selected,
    required this.onSelected,
    required this.onMount,
    required this.onUnmount,
    required this.onEdit,
    required this.onDelete,
  });

  final AppStrings strings;
  final ConnectionProfile profile;
  final bool selected;
  final VoidCallback onSelected;
  final Future<void> Function() onMount;
  final Future<void> Function() onUnmount;
  final VoidCallback onEdit;
  final VoidCallback onDelete;

  @override
  State<_ProfileRow> createState() => _ProfileRowState();
}

class _ProfileRowState extends State<_ProfileRow> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        onTap: widget.onSelected,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          decoration: BoxDecoration(
            color: widget.selected ? workbenchAccent.withValues(alpha: 0.1) : _hovered ? workbenchHover : Colors.transparent,
            borderRadius: BorderRadius.circular(8),
          ),
          child: Row(
            children: [
              Container(
                width: 8, height: 8,
                decoration: BoxDecoration(
                  color: widget.profile.mounted ? workbenchAccent : workbenchTextFaint,
                  shape: BoxShape.circle,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(widget.profile.name, style: TextStyle(color: workbenchText, fontSize: 13, fontWeight: FontWeight.w500)),
                    const SizedBox(height: 2),
                    Text(
                      '${widget.profile.username}@${widget.profile.host}:${widget.profile.port}${widget.profile.mountedDriveLetter == null ? "" : " \u2022 ${widget.profile.mountedDriveLetter}:"}',
                      style: TextStyle(color: workbenchTextMuted, fontSize: 11),
                    ),
                  ],
                ),
              ),
              if (_hovered || widget.selected) ...[
                if (widget.profile.mounted)
                  _MiniBtn(label: widget.strings.unmountDrive, onPressed: () async => widget.onUnmount())
                else
                  _MiniBtn(label: widget.strings.mountAsDrive, accent: true, onPressed: () async => widget.onMount()),
                const SizedBox(width: 6),
                _MiniIconBtn(icon: FluentIcons.edit, onPressed: widget.onEdit),
                const SizedBox(width: 4),
                _MiniIconBtn(icon: FluentIcons.delete, onPressed: widget.onDelete),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _MiniBtn extends StatelessWidget {
  const _MiniBtn({required this.label, this.accent = false, this.onPressed});
  final String label;
  final bool accent;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onPressed,
      child: Container(
        height: 24,
        padding: const EdgeInsets.symmetric(horizontal: 10),
        decoration: BoxDecoration(
          color: accent ? workbenchAccent : workbenchPanelAlt,
          borderRadius: BorderRadius.circular(5),
        ),
        child: Center(
          child: Text(label, style: TextStyle(color: accent ? Colors.white : workbenchText, fontSize: 10, fontWeight: FontWeight.w600)),
        ),
      ),
    );
  }
}

class _MiniIconBtn extends StatelessWidget {
  const _MiniIconBtn({required this.icon, required this.onPressed});
  final IconData icon;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onPressed,
      child: Container(
        width: 24, height: 24,
        decoration: BoxDecoration(color: workbenchPanelAlt, borderRadius: BorderRadius.circular(5)),
        child: Icon(icon, size: 11, color: workbenchTextMuted),
      ),
    );
  }
}

class _DriveActionBtn extends StatefulWidget {
  const _DriveActionBtn({required this.label, required this.icon, this.onPressed});
  final String label;
  final IconData icon;
  final VoidCallback? onPressed;

  @override
  State<_DriveActionBtn> createState() => _DriveActionBtnState();
}

class _DriveActionBtnState extends State<_DriveActionBtn> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        onTap: widget.onPressed,
        child: Container(
          height: 36,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          decoration: BoxDecoration(
            color: _hovered && widget.onPressed != null ? workbenchHover : workbenchPanel,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: workbenchBorder, width: 0.5),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(widget.icon, size: 11, color: widget.onPressed != null ? workbenchTextMuted : workbenchTextFaint),
              const SizedBox(width: 7),
              Text(widget.label, style: TextStyle(color: widget.onPressed != null ? workbenchText : workbenchTextFaint, fontSize: 12, fontWeight: FontWeight.w500)),
            ],
          ),
        ),
      ),
    );
  }
}

extension _IterableExt<T> on Iterable<T> {
  T? firstWhereOrNull(bool Function(T item) test) {
    for (final item in this) { if (test(item)) return item; }
    return null;
  }
}
