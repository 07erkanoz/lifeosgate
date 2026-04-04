import 'dart:io';
import 'dart:math';

import 'package:fluent_ui/fluent_ui.dart';
import 'package:lifeos_sftp_drive/src/i18n/app_strings.dart';
import 'package:lifeos_sftp_drive/src/models/connection_profile.dart';
import 'package:lifeos_sftp_drive/src/models/log_entry.dart';
import 'package:lifeos_sftp_drive/src/services/server_monitor_service.dart';
import 'package:lifeos_sftp_drive/src/services/sftp_browser_service.dart';
import 'package:lifeos_sftp_drive/src/state/app_controller.dart';
import 'package:lifeos_sftp_drive/src/ui/theme_tokens.dart';

class DashboardView extends StatefulWidget {
  const DashboardView({super.key, required this.appController});
  final AppController appController;
  @override State<DashboardView> createState() => _DashboardViewState();
}

class _DashboardViewState extends State<DashboardView> {
  ServerMonitorService? _monitor;
  String? _selectedProfileId;
  int _activePanel = 0; // 0=overview, 1=services, 2=firewall, 3=logs, 4=cron, 5=users, 6=network, 7=packages, 8=docker, 9=database, 10=backup

  // Panel data (loaded on demand)
  List<ServiceInfo>? _services;
  String? _firewallStatus;
  String? _logContent;
  String? _crontab;
  List<UserInfo>? _users;
  String? _lastLogins;
  String? _networkInfo;
  String? _openPorts;
  String? _routingTable;
  String? _packages;
  String? _upgradable;
  String? _panelError;
  bool _panelLoading = false;
  final _logUnitCtrl = TextEditingController();
  final _pkgSearchCtrl = TextEditingController();
  final _crontabCtrl = TextEditingController();

  // Docker panel state
  List<DockerContainer>? _dockerContainers;
  List<DockerImage>? _dockerImages;

  // Database panel state
  List<DetectedDatabase>? _detectedDbs;
  List<DbInfo>? _dbList;
  List<TableInfo>? _tableList;
  String? _selectedDbName;
  DetectedDatabase? _selectedDb;

  // Backup panel state
  List<BackupEntry>? _backups;

  bool get _isTr => widget.appController.strings.isTr;

  List<({IconData icon, String label})> get _panels {
    final s = widget.appController.strings;
    return [
      (icon: FluentIcons.health, label: s.overview),
      (icon: FluentIcons.settings, label: s.services),
      (icon: FluentIcons.shield, label: s.firewall),
      (icon: FluentIcons.text_document, label: s.dashLogs),
      (icon: FluentIcons.timer, label: s.cron),
      (icon: FluentIcons.people, label: s.users),
      (icon: FluentIcons.globe, label: s.network),
      (icon: FluentIcons.product_catalog, label: s.packages),
      (icon: FluentIcons.devices3, label: s.docker),
      (icon: FluentIcons.database, label: s.database),
      (icon: FluentIcons.cloud_download, label: s.backup),
    ];
  }

  void _switchPanel(int index) {
    setState(() => _activePanel = index);
    _loadPanelData(index);
  }

  Future<void> _loadPanelData(int index) async {
    if (_monitor == null) return;
    setState(() { _panelLoading = true; _panelError = null; });
    try {
      switch (index) {
        case 1: _services = await _monitor!.getServices(); break;
        case 2: _firewallStatus = await _monitor!.getFirewallStatus(); break;
        case 3: _logContent = await _monitor!.getLogs(unit: _logUnitCtrl.text.trim()); break;
        case 4:
          _crontab = await _monitor!.getCrontab();
          _crontabCtrl.text = _crontab ?? '';
          break;
        case 5:
          _users = await _monitor!.getUsers();
          _lastLogins = await _monitor!.getLastLogins();
          break;
        case 6:
          _networkInfo = await _monitor!.getNetworkInterfaces();
          _openPorts = await _monitor!.getOpenPorts();
          _routingTable = await _monitor!.getRoutingTable();
          break;
        case 7:
          _packages = await _monitor!.getInstalledPackages(query: _pkgSearchCtrl.text.trim());
          _upgradable = await _monitor!.getUpgradablePackages();
          break;
        case 8: // Docker
          _dockerContainers = await _monitor!.getDockerContainersAll();
          _dockerImages = await _monitor!.getDockerImages();
          break;
        case 9: // Database
          _detectedDbs = await _monitor!.detectDatabases();
          break;
        case 10: // Backup
          _backups = await _monitor!.listBackups();
          break;
      }
    } catch (e) { _panelError = e.toString(); }
    if (mounted) setState(() => _panelLoading = false);
  }

  @override
  void dispose() {
    _monitor?.dispose();
    _logUnitCtrl.dispose();
    _pkgSearchCtrl.dispose();
    _crontabCtrl.dispose();
    // DB controllers removed — credentials are stored in profile now
    super.dispose();
  }

  void _connectToServer(ConnectionProfile profile) {
    _monitor?.dispose();
    _monitor = ServerMonitorService(profile: profile);
    _monitor!.addListener(() { if (mounted) setState(() {}); });
    _monitor!.connect();
    setState(() => _selectedProfileId = profile.id);
  }

  @override
  Widget build(BuildContext context) {
    final profiles = widget.appController.connections;

    // No server selected yet
    if (_monitor == null || !_monitor!.connected) {
      return _buildServerPicker(profiles);
    }

    final m = _monitor!.metrics;

    return Column(children: [
      // Header
      Container(
        height: 44, padding: const EdgeInsets.symmetric(horizontal: 16),
        decoration: BoxDecoration(border: Border(bottom: BorderSide(color: workbenchDivider, width: 0.5))),
        child: Row(children: [
          Container(width: 10, height: 10, decoration: BoxDecoration(
            color: workbenchSuccess, shape: BoxShape.circle,
            boxShadow: [BoxShadow(color: workbenchSuccess.withValues(alpha: 0.4), blurRadius: 6)],
          )),
          const SizedBox(width: 10),
          Text(m.hostname.isNotEmpty ? m.hostname : 'Server', style: TextStyle(color: workbenchText, fontSize: 14, fontWeight: FontWeight.w600)),
          const SizedBox(width: 10),
          Container(padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
            decoration: BoxDecoration(color: workbenchHover, borderRadius: BorderRadius.circular(4)),
            child: Text(m.os.isNotEmpty ? m.os : m.kernel, style: TextStyle(color: workbenchTextMuted, fontSize: 10))),
          const Spacer(),
          if (m.uptime.isNotEmpty) Text(m.uptime, style: TextStyle(color: workbenchTextFaint, fontSize: 10)),
          const SizedBox(width: 12),
          GestureDetector(
            onTap: () => _monitor?.refresh(),
            child: Icon(FluentIcons.refresh, size: 12, color: workbenchTextMuted)),
          const SizedBox(width: 8),
          GestureDetector(
            onTap: () { _monitor?.dispose(); _monitor = null; setState(() {}); },
            child: Icon(FluentIcons.chrome_close, size: 12, color: workbenchTextMuted)),
        ]),
      ),

      // Tab bar
      Container(
        height: 36, padding: const EdgeInsets.symmetric(horizontal: 8),
        decoration: BoxDecoration(border: Border(bottom: BorderSide(color: workbenchDivider, width: 0.5))),
        child: SingleChildScrollView(scrollDirection: Axis.horizontal, child: Row(children: [
          for (int i = 0; i < _panels.length; i++) _PanelTab(
            icon: _panels[i].icon, label: _panels[i].label,
            active: _activePanel == i, onTap: () => _switchPanel(i),
          ),
        ])),
      ),

      // Panel content
      Expanded(child: _panelLoading
        ? const Center(child: ProgressRing())
        : _activePanel == 0
          ? _buildOverview(m)
          : _activePanel == 1 ? _buildServices()
          : _activePanel == 2 ? _buildFirewall()
          : _activePanel == 3 ? _buildLogs()
          : _activePanel == 4 ? _buildCron()
          : _activePanel == 5 ? _buildUsers()
          : _activePanel == 6 ? _buildNetwork()
          : _activePanel == 7 ? _buildPackages()
          : _activePanel == 8 ? _buildDockerPanel()
          : _activePanel == 9 ? _buildDatabasePanel()
          : _activePanel == 10 ? _buildBackupPanel()
          : const SizedBox(),
      ),
    ]);
  }

  Widget _buildOverview(ServerMetrics m) {
    final s = widget.appController.strings;
    final ac = widget.appController;
    final alarms = ac.alarmsEnabled;
    final cpuAlarm = alarms && m.cpuUsage >= ac.cpuAlarmThreshold;
    final memAlarm = alarms && m.memPercent >= ac.memAlarmThreshold;
    final diskAlarm = alarms && m.diskPercent >= ac.diskAlarmThreshold;

    return Padding(
      padding: const EdgeInsets.all(12),
      child: ListView(children: [
          // Alarm banner
          if (cpuAlarm || memAlarm || diskAlarm) ...[
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              margin: const EdgeInsets.only(bottom: 10),
              decoration: BoxDecoration(color: workbenchDanger.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(8), border: Border.all(color: workbenchDanger.withValues(alpha: 0.3))),
              child: Row(children: [
                Icon(FluentIcons.warning, size: 14, color: workbenchDanger),
                const SizedBox(width: 8),
                Expanded(child: Text(
                  [
                    if (cpuAlarm) 'CPU ${m.cpuUsage.toStringAsFixed(0)}% (>${ac.cpuAlarmThreshold.round()}%)',
                    if (memAlarm) '${s.memory} ${m.memPercent.toStringAsFixed(0)}% (>${ac.memAlarmThreshold.round()}%)',
                    if (diskAlarm) '${s.disk} ${m.diskPercent.toStringAsFixed(0)}% (>${ac.diskAlarmThreshold.round()}%)',
                  ].join(' | '),
                  style: TextStyle(color: workbenchDanger, fontSize: 11, fontWeight: FontWeight.w600),
                )),
              ]),
            ),
          ],

          // Top cards row
          Row(children: [
            Expanded(child: _GaugeCard(label: 'CPU', value: m.cpuUsage, suffix: '%', color: cpuAlarm ? workbenchDanger : workbenchAccent, icon: FluentIcons.processing_run,
              subtitle: '${m.cpuCores} cores | Load: ${m.loadAvg}')),
            const SizedBox(width: 10),
            Expanded(child: _GaugeCard(label: s.memory, value: m.memPercent, suffix: '%', color: memAlarm ? workbenchDanger : const Color(0xFF61AFEF), icon: FluentIcons.database,
              subtitle: '${_fmtBytes(m.memUsed)} / ${_fmtBytes(m.memTotal)}')),
            const SizedBox(width: 10),
            Expanded(child: _GaugeCard(label: s.disk, value: m.diskPercent, suffix: '%', color: diskAlarm ? workbenchDanger : const Color(0xFF98C379), icon: FluentIcons.hard_drive,
              subtitle: '${_fmtBytes(m.diskUsed)} / ${_fmtBytes(m.diskTotal)}')),
            const SizedBox(width: 10),
            Expanded(child: _InfoCard(label: s.network, icon: FluentIcons.globe, color: const Color(0xFFC678DD), children: [
              Text('↓ ${_fmtBytes(m.networkRx)}', style: TextStyle(color: workbenchSuccess, fontSize: 12)),
              Text('↑ ${_fmtBytes(m.networkTx)}', style: TextStyle(color: workbenchAccent, fontSize: 12)),
            ])),
          ]),
          const SizedBox(height: 12),

          // Charts row
          Row(children: [
            Expanded(child: _MiniChart(label: 'CPU', data: _monitor!.cpuHistory, color: workbenchAccent, maxVal: 100)),
            const SizedBox(width: 10),
            Expanded(child: _MiniChart(label: widget.appController.strings.memory, data: _monitor!.memHistory, color: const Color(0xFF61AFEF), maxVal: 100)),
          ]),
          const SizedBox(height: 12),

          // Disks
          if (m.disks.isNotEmpty) ...[
            _SectionTitle(label: widget.appController.strings.disks),
            const SizedBox(height: 6),
            for (final disk in m.disks) _DiskRow(disk: disk),
            const SizedBox(height: 12),
          ],

          // Top Processes
          if (m.topProcesses.isNotEmpty) ...[
            _SectionTitle(label: '${s.processes} (Top 10)'),
            const SizedBox(height: 6),
            _ProcessHeader(isTr: _isTr),
            for (final p in m.topProcesses) _ProcessRow(process: p),
            const SizedBox(height: 12),
          ],

          // Docker
          if (m.dockerContainers.isNotEmpty) ...[
            _SectionTitle(label: 'Docker'),
            const SizedBox(height: 6),
            for (final c in m.dockerContainers) _DockerRow(container: c, monitor: _monitor!, isTr: _isTr, strings: widget.appController.strings),
            const SizedBox(height: 12),
          ],
        ]),
    );
  }

  // ─── Services Panel ─────────────────────────────────────────
  Widget _buildServices() {
    if (_services == null) return Center(child: Text(widget.appController.strings.loading, style: TextStyle(color: workbenchTextMuted)));
    return ListView(padding: const EdgeInsets.all(12), children: [
      // Header row
      Container(padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4), color: workbenchHover,
        child: Row(children: [
          const SizedBox(width: 14),
          Expanded(flex: 3, child: Text('SERVICE', style: TextStyle(color: workbenchTextFaint, fontSize: 9, fontWeight: FontWeight.w600))),
          SizedBox(width: 60, child: Text('STATE', style: TextStyle(color: workbenchTextFaint, fontSize: 9, fontWeight: FontWeight.w600))),
          SizedBox(width: 120, child: Text('ACTIONS', style: TextStyle(color: workbenchTextFaint, fontSize: 9, fontWeight: FontWeight.w600))),
        ])),
      for (final s in _services!) Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(border: Border(bottom: BorderSide(color: workbenchDivider, width: 0.5))),
        child: Row(children: [
          Container(width: 8, height: 8, decoration: BoxDecoration(color: s.isRunning ? workbenchSuccess : s.isFailed ? workbenchDanger : workbenchTextFaint, shape: BoxShape.circle)),
          const SizedBox(width: 6),
          Expanded(flex: 3, child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(s.name, style: TextStyle(color: workbenchText, fontSize: 12, fontWeight: FontWeight.w500)),
            if (s.description.isNotEmpty) Text(s.description, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(color: workbenchTextFaint, fontSize: 10)),
          ])),
          SizedBox(width: 60, child: Text(s.sub, style: TextStyle(color: s.isRunning ? workbenchSuccess : s.isFailed ? workbenchDanger : workbenchTextMuted, fontSize: 10))),
          SizedBox(width: 200, child: Row(children: [
            _SmallBtn(label: s.isRunning ? widget.appController.strings.stop : widget.appController.strings.start, color: s.isRunning ? workbenchWarning : workbenchSuccess,
              onTap: () async {
                final action = s.isRunning ? 'stop' : 'start';
                final confirmed = await _confirmAction(context, '${s.isRunning ? widget.appController.strings.stop : widget.appController.strings.start} ${s.name}?');
                if (confirmed) { await _monitor?.serviceAction(s.name, action); _loadPanelData(1); }
              }),
            const SizedBox(width: 4),
            _SmallBtn(label: widget.appController.strings.restart, color: workbenchAccent,
              onTap: () async {
                final confirmed = await _confirmAction(context, '${widget.appController.strings.restart} ${s.name}?');
                if (confirmed) { await _monitor?.serviceAction(s.name, 'restart'); _loadPanelData(1); }
              }),
            const SizedBox(width: 4),
            _SmallBtn(label: s.isRunning ? widget.appController.strings.disable : widget.appController.strings.enable,
              color: s.isRunning ? workbenchTextFaint : const Color(0xFF4EC9B0),
              onTap: () async {
                final action = s.isRunning ? 'disable' : 'enable';
                await _monitor?.serviceAction(s.name, action); _loadPanelData(1);
              }),
          ])),
        ]),
      ),
    ]);
  }

  // ─── Firewall Panel ────────────────────────────────────────
  Widget _buildFirewall() {
    return Padding(padding: const EdgeInsets.all(12), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(children: [
        Text(widget.appController.strings.firewallStatus, style: TextStyle(color: workbenchText, fontSize: 13, fontWeight: FontWeight.w600)),
        const Spacer(),
        _SmallBtn(label: _isTr ? 'Yenile' : 'Refresh', color: workbenchAccent, onTap: () => _loadPanelData(2)),
      ]),
      const SizedBox(height: 10),
      Expanded(child: Container(
        width: double.infinity, padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(color: workbenchPanelAlt, borderRadius: BorderRadius.circular(8)),
        child: SelectableText(_firewallStatus ?? (widget.appController.strings.loading),
          style: TextStyle(color: workbenchText, fontSize: 12, fontFamily: 'monospace', height: 1.5)),
      )),
    ]));
  }

  // ─── Logs Panel ────────────────────────────────────────────
  Widget _buildLogs() {
    return Padding(padding: const EdgeInsets.all(12), child: Column(children: [
      Row(children: [
        Expanded(child: SizedBox(height: 30, child: TextBox(
          controller: _logUnitCtrl,
          placeholder: _isTr ? 'Servis adı (ör: nginx, ssh)' : 'Service name (e.g. nginx, ssh)',
          placeholderStyle: TextStyle(color: workbenchTextFaint, fontSize: 11),
          style: TextStyle(color: workbenchText, fontSize: 12),
          decoration: WidgetStateProperty.all(BoxDecoration(color: workbenchPanelAlt, borderRadius: BorderRadius.circular(6))),
          onSubmitted: (_) => _loadPanelData(3),
        ))),
        const SizedBox(width: 8),
        _SmallBtn(label: _isTr ? 'Getir' : 'Fetch', color: workbenchAccent, onTap: () => _loadPanelData(3)),
      ]),
      const SizedBox(height: 10),
      Expanded(child: Container(
        width: double.infinity, padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(color: workbenchEditorBg, borderRadius: BorderRadius.circular(8)),
        child: SelectableText(_logContent ?? '', style: TextStyle(color: workbenchText, fontSize: 11, fontFamily: 'monospace', height: 1.4)),
      )),
    ]));
  }

  // ─── Cron Panel ────────────────────────────────────────────
  Widget _buildCron() {
    return Padding(padding: const EdgeInsets.all(12), child: Column(children: [
      Row(children: [
        Text('Crontab', style: TextStyle(color: workbenchText, fontSize: 13, fontWeight: FontWeight.w600)),
        const Spacer(),
        _SmallBtn(label: _isTr ? 'Kaydet' : 'Save', color: workbenchSuccess,
          onTap: () async { await _monitor?.setCrontab(_crontabCtrl.text); _loadPanelData(4); }),
        const SizedBox(width: 6),
        _SmallBtn(label: _isTr ? 'Yenile' : 'Refresh', color: workbenchAccent, onTap: () => _loadPanelData(4)),
      ]),
      const SizedBox(height: 10),
      Expanded(child: TextBox(
        controller: _crontabCtrl, maxLines: null, expands: true,
        style: TextStyle(color: workbenchText, fontSize: 12, fontFamily: 'monospace', height: 1.5),
        decoration: WidgetStateProperty.all(BoxDecoration(color: workbenchEditorBg, borderRadius: BorderRadius.circular(8))),
      )),
    ]));
  }

  // ─── Users Panel ───────────────────────────────────────────
  Widget _buildUsers() {
    return ListView(padding: const EdgeInsets.all(12), children: [
      Text(_isTr ? 'Kullanıcılar' : 'Users', style: TextStyle(color: workbenchText, fontSize: 13, fontWeight: FontWeight.w600)),
      const SizedBox(height: 8),
      if (_users != null) for (final u in _users!) Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(border: Border(bottom: BorderSide(color: workbenchDivider, width: 0.5))),
        child: Row(children: [
          Icon(FluentIcons.contact, size: 12, color: workbenchAccent),
          const SizedBox(width: 8),
          SizedBox(width: 100, child: Text(u.name, style: TextStyle(color: workbenchText, fontSize: 12, fontWeight: FontWeight.w500))),
          SizedBox(width: 50, child: Text('UID:${u.uid}', style: TextStyle(color: workbenchTextFaint, fontSize: 10))),
          Expanded(child: Text(u.home, style: TextStyle(color: workbenchTextMuted, fontSize: 11))),
          Text(u.shell, style: TextStyle(color: workbenchTextFaint, fontSize: 10)),
        ]),
      ),
      if (_lastLogins != null) ...[
        const SizedBox(height: 16),
        Text(_isTr ? 'Son Girişler' : 'Last Logins', style: TextStyle(color: workbenchText, fontSize: 13, fontWeight: FontWeight.w600)),
        const SizedBox(height: 8),
        Container(padding: EdgeInsets.all(10), decoration: BoxDecoration(color: workbenchPanelAlt, borderRadius: BorderRadius.circular(8)),
          child: SelectableText(_lastLogins!, style: TextStyle(color: workbenchText, fontSize: 11, fontFamily: 'monospace', height: 1.4))),
      ],
    ]);
  }

  // ─── Network Panel ─────────────────────────────────────────
  Widget _buildNetwork() {
    return ListView(padding: const EdgeInsets.all(12), children: [
      _NetSection(title: _isTr ? 'Ağ Arayüzleri' : 'Network Interfaces', content: _networkInfo),
      const SizedBox(height: 12),
      _NetSection(title: _isTr ? 'Açık Portlar' : 'Open Ports', content: _openPorts),
      const SizedBox(height: 12),
      _NetSection(title: _isTr ? 'Yönlendirme Tablosu' : 'Routing Table', content: _routingTable),
    ]);
  }

  // ─── Packages Panel ────────────────────────────────────────
  Widget _buildPackages() {
    return Padding(padding: const EdgeInsets.all(12), child: Column(children: [
      Row(children: [
        Expanded(child: SizedBox(height: 30, child: TextBox(
          controller: _pkgSearchCtrl,
          placeholder: _isTr ? 'Paket ara...' : 'Search packages...',
          placeholderStyle: TextStyle(color: workbenchTextFaint, fontSize: 11),
          style: TextStyle(color: workbenchText, fontSize: 12),
          decoration: WidgetStateProperty.all(BoxDecoration(color: workbenchPanelAlt, borderRadius: BorderRadius.circular(6))),
          onSubmitted: (_) => _loadPanelData(7),
        ))),
        const SizedBox(width: 8),
        _SmallBtn(label: _isTr ? 'Ara' : 'Search', color: workbenchAccent, onTap: () => _loadPanelData(7)),
      ]),
      if (_upgradable != null && _upgradable!.isNotEmpty) ...[
        const SizedBox(height: 10),
        Container(width: double.infinity, padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(color: workbenchWarning.withValues(alpha: 0.08), borderRadius: BorderRadius.circular(6)),
          child: Row(children: [
            Icon(FluentIcons.warning, size: 12, color: workbenchWarning),
            const SizedBox(width: 8),
            Text(_isTr ? 'Güncellenebilir paketler:' : 'Upgradable packages:', style: TextStyle(color: workbenchWarning, fontSize: 11, fontWeight: FontWeight.w600)),
          ])),
        const SizedBox(height: 4),
        Container(padding: EdgeInsets.all(8), decoration: BoxDecoration(color: workbenchPanelAlt, borderRadius: BorderRadius.circular(6)),
          child: SelectableText(_upgradable!, style: TextStyle(color: workbenchText, fontSize: 10, fontFamily: 'monospace'))),
      ],
      const SizedBox(height: 10),
      Expanded(child: Container(
        width: double.infinity, padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(color: workbenchEditorBg, borderRadius: BorderRadius.circular(8)),
        child: SelectableText(_packages ?? '', style: TextStyle(color: workbenchText, fontSize: 11, fontFamily: 'monospace', height: 1.4)),
      )),
    ]));
  }

  Widget _buildServerPicker(List<ConnectionProfile> profiles) {
    return Center(child: Container(
      width: 400,
      padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(color: workbenchPanelAlt, borderRadius: BorderRadius.circular(12), boxShadow: cardShadow),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        Icon(FluentIcons.health, size: 32, color: workbenchAccent),
        const SizedBox(height: 12),
        Text(widget.appController.strings.selectServer, style: TextStyle(color: workbenchText, fontSize: 16, fontWeight: FontWeight.w600)),
        const SizedBox(height: 4),
        Text(_isTr ? 'İzlemek istediğiniz sunucuyu seçin' : 'Choose a server to monitor', style: TextStyle(color: workbenchTextMuted, fontSize: 12)),
        const SizedBox(height: 16),
        if (profiles.isEmpty)
          Text(_isTr ? 'Henüz sunucu eklenmemiş' : 'No servers added yet', style: TextStyle(color: workbenchTextFaint, fontSize: 12))
        else
          ...profiles.map((p) => Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: _ServerPickerRow(profile: p, onTap: () => _connectToServer(p)),
          )),
        if (_monitor?.error != null) ...[
          const SizedBox(height: 12),
          Text(_monitor!.error!, style: TextStyle(color: workbenchDanger, fontSize: 11)),
        ],
        if (_monitor?.loading ?? false) ...[
          const SizedBox(height: 12),
          const ProgressRing(),
        ],
      ]),
    ));
  }

  Future<bool> _confirmAction(BuildContext context, String message) async {
    final s = widget.appController.strings;
    final result = await showDialog<bool>(context: context, builder: (ctx) => ContentDialog(
      title: Text(s.areYouSure),
      content: Text(message, style: const TextStyle(fontSize: 13)),
      actions: [
        Button(onPressed: () => Navigator.pop(ctx, false), child: Text(s.cancel)),
        FilledButton(onPressed: () => Navigator.pop(ctx, true), child: Text(s.confirm)),
      ],
    ));
    return result ?? false;
  }

  // ─── Docker Panel ─────────────────────────────────────────
  // Docker panel state
  String? _dockerLogContainerId;
  String? _dockerLogContent;
  Map<String, DockerStats> _dockerStatsCache = {};

  Widget _buildDockerPanel() {
    final s = widget.appController.strings;
    if (_dockerContainers == null) return Center(child: Text(s.loading, style: TextStyle(color: workbenchTextMuted)));

    final running = _dockerContainers!.where((c) => c.isRunning).length;
    final stopped = _dockerContainers!.length - running;

    return Column(children: [
      // Header
      Padding(padding: const EdgeInsets.fromLTRB(12, 12, 12, 0), child: Row(children: [
        Icon(FluentIcons.devices3, size: 14, color: workbenchAccent),
        const SizedBox(width: 8),
        Text('Docker', style: TextStyle(color: workbenchText, fontSize: 14, fontWeight: FontWeight.w600)),
        const SizedBox(width: 10),
        Container(padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2), decoration: BoxDecoration(color: workbenchSuccess.withValues(alpha: 0.15), borderRadius: BorderRadius.circular(4)),
          child: Text('$running ${_isTr ? "çalışıyor" : "running"}', style: TextStyle(color: workbenchSuccess, fontSize: 9, fontWeight: FontWeight.w600))),
        if (stopped > 0) ...[
          const SizedBox(width: 4),
          Container(padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2), decoration: BoxDecoration(color: workbenchTextFaint.withValues(alpha: 0.15), borderRadius: BorderRadius.circular(4)),
            child: Text('$stopped ${_isTr ? "durmuş" : "stopped"}', style: TextStyle(color: workbenchTextFaint, fontSize: 9, fontWeight: FontWeight.w600))),
        ],
        const Spacer(),
        _SmallBtn(label: s.refresh, color: workbenchAccent, onTap: () { _dockerStatsCache.clear(); _loadPanelData(8); }),
      ])),
      const SizedBox(height: 10),

      // Container cards grid
      Expanded(child: _dockerContainers!.isEmpty
        ? Center(child: Column(mainAxisSize: MainAxisSize.min, children: [
            Icon(FluentIcons.devices3, size: 40, color: workbenchTextFaint),
            const SizedBox(height: 12),
            Text(s.noData, style: TextStyle(color: workbenchTextFaint, fontSize: 13)),
          ]))
        : Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            // Left: container list
            Expanded(child: ListView(padding: const EdgeInsets.fromLTRB(12, 0, 6, 12), children: [
              for (final c in _dockerContainers!) _DockerCard(
                container: c, isTr: _isTr, strings: s,
                stats: _dockerStatsCache[c.id],
                isLogActive: _dockerLogContainerId == c.id,
                onStart: () async { await _monitor?.dockerAction(c.id, 'start'); _loadPanelData(8); },
                onStop: () async { await _monitor?.dockerAction(c.id, 'stop'); _loadPanelData(8); },
                onRestart: () async { await _monitor?.dockerAction(c.id, 'restart'); _loadPanelData(8); },
                onRemove: () async {
                  final confirmed = await _confirmAction(context, '${_isTr ? "Kaldır" : "Remove"}: ${c.name}?');
                  if (confirmed) { await _monitor?.removeDockerContainer(c.id); _loadPanelData(8); }
                },
                onLogs: () async {
                  setState(() { _dockerLogContainerId = c.id; _dockerLogContent = null; });
                  final logs = await _monitor?.getDockerLogs(c.id);
                  if (mounted) setState(() => _dockerLogContent = logs);
                },
                onStats: () async {
                  final stats = await _monitor?.getDockerStats(c.id);
                  if (stats != null && mounted) setState(() => _dockerStatsCache[c.id] = stats);
                },
              ),
              // Images section
              if (_dockerImages != null && _dockerImages!.isNotEmpty) ...[
                const SizedBox(height: 16),
                Text(s.images, style: TextStyle(color: workbenchText, fontSize: 12, fontWeight: FontWeight.w600)),
                const SizedBox(height: 6),
                for (final img in _dockerImages!) Container(
                  margin: const EdgeInsets.only(bottom: 4),
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                  decoration: BoxDecoration(color: workbenchPanelAlt, borderRadius: BorderRadius.circular(6)),
                  child: Row(children: [
                    Icon(FluentIcons.product_variant, size: 10, color: workbenchTextFaint),
                    const SizedBox(width: 6),
                    Expanded(child: Text(img.repo, style: TextStyle(color: workbenchText, fontSize: 10))),
                    Container(padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1), decoration: BoxDecoration(color: workbenchAccent.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(3)),
                      child: Text(img.tag, style: TextStyle(color: workbenchAccent, fontSize: 8, fontWeight: FontWeight.w600))),
                    const SizedBox(width: 8),
                    Text(img.size, style: TextStyle(color: workbenchTextFaint, fontSize: 9)),
                  ]),
                ),
              ],
            ])),

            // Right: log viewer (if active)
            if (_dockerLogContainerId != null) ...[
              const SizedBox(width: 6),
              SizedBox(width: 380, child: Container(
                margin: const EdgeInsets.only(right: 12, bottom: 12),
                decoration: BoxDecoration(color: workbenchEditorBg, borderRadius: BorderRadius.circular(8), border: Border.all(color: workbenchBorder, width: 0.5)),
                child: Column(children: [
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                    decoration: BoxDecoration(border: Border(bottom: BorderSide(color: workbenchDivider, width: 0.5))),
                    child: Row(children: [
                      Icon(FluentIcons.text_document, size: 11, color: const Color(0xFF61AFEF)),
                      const SizedBox(width: 6),
                      Expanded(child: Text('${_dockerContainers!.firstWhereOrNull((c) => c.id == _dockerLogContainerId)?.name ?? ""} logs',
                        style: TextStyle(color: workbenchText, fontSize: 11, fontWeight: FontWeight.w600))),
                      GestureDetector(onTap: () => setState(() { _dockerLogContainerId = null; _dockerLogContent = null; }),
                        child: Icon(FluentIcons.chrome_close, size: 10, color: workbenchTextFaint)),
                    ]),
                  ),
                  Expanded(child: _dockerLogContent == null
                    ? const Center(child: ProgressRing())
                    : SingleChildScrollView(
                        padding: const EdgeInsets.all(8),
                        child: SelectableText(_dockerLogContent!, style: TextStyle(color: workbenchText, fontSize: 10, fontFamily: 'monospace', height: 1.4)),
                      )),
                ]),
              )),
            ],
          ])),
    ]);
  }

  DockerContainer? _findContainer(String id) => _dockerContainers?.firstWhereOrNull((c) => c.id == id);

  // ─── Database Panel — Professional ─────────────────────────
  String get _dbUser {
    final profile = widget.appController.connections.firstWhereOrNull((p) => p.id == _selectedProfileId);
    return profile?.dbUser ?? 'root';
  }
  String get _dbPass {
    final profile = widget.appController.connections.firstWhereOrNull((p) => p.id == _selectedProfileId);
    return profile?.dbPassword ?? '';
  }

  Widget _buildDatabasePanel() {
    final s = widget.appController.strings;
    if (_detectedDbs == null) return Center(child: Text(s.loading, style: TextStyle(color: workbenchTextMuted)));
    return Padding(padding: const EdgeInsets.all(12), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      // Header
      Row(children: [
        Icon(FluentIcons.database, size: 14, color: workbenchAccent),
        const SizedBox(width: 8),
        Text(s.databases, style: TextStyle(color: workbenchText, fontSize: 14, fontWeight: FontWeight.w600)),
        const Spacer(),
        if (_dbPass.isEmpty) ...[
          Icon(FluentIcons.warning, size: 11, color: workbenchWarning),
          const SizedBox(width: 4),
          Text(_isTr ? 'DB şifresi profilde tanımlı değil' : 'DB password not set in profile', style: TextStyle(color: workbenchWarning, fontSize: 10)),
          const SizedBox(width: 8),
        ],
        _SmallBtn(label: s.refresh, color: workbenchAccent, onTap: () => _loadPanelData(9)),
      ]),
      const SizedBox(height: 10),

      if (_detectedDbs!.isEmpty)
        Expanded(child: Center(child: Column(mainAxisSize: MainAxisSize.min, children: [
          Icon(FluentIcons.database, size: 40, color: workbenchTextFaint),
          const SizedBox(height: 12),
          Text(_isTr ? 'Veritabanı bulunamadı' : 'No databases found', style: TextStyle(color: workbenchTextFaint, fontSize: 14)),
          const SizedBox(height: 4),
          Text(_isTr ? 'mysql/psql kurulu değil veya Docker\'da yok' : 'mysql/psql not installed or not in Docker', style: TextStyle(color: workbenchTextFaint, fontSize: 11)),
        ])))
      else ...[
        // DB engine chips
        SizedBox(height: 32, child: ListView(scrollDirection: Axis.horizontal, children: [
          for (final db in _detectedDbs!) Padding(
            padding: const EdgeInsets.only(right: 6),
            child: GestureDetector(
              onTap: () async {
                setState(() { _selectedDb = db; _dbList = null; _tableList = null; _selectedDbName = null; });
                setState(() => _panelLoading = true);
                _dbList = await _monitor?.listDatabaseNames(db, user: _dbUser, password: _dbPass);
                if (mounted) setState(() => _panelLoading = false);
              },
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                decoration: BoxDecoration(
                  color: _selectedDb == db ? workbenchAccent.withValues(alpha: 0.15) : workbenchPanelAlt,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: _selectedDb == db ? workbenchAccent : workbenchBorder, width: 0.5)),
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  Icon(db.isDocker ? FluentIcons.devices3 : FluentIcons.database, size: 11, color: _selectedDb == db ? workbenchAccent : workbenchTextMuted),
                  const SizedBox(width: 6),
                  Text('${db.name} (${db.type})', style: TextStyle(color: _selectedDb == db ? workbenchAccent : workbenchText, fontSize: 11, fontWeight: _selectedDb == db ? FontWeight.w600 : FontWeight.w400)),
                ]),
              ),
            ),
          ),
        ])),
        const SizedBox(height: 10),

        // Two-column layout: databases list | tables list
        if (_selectedDb != null) Expanded(child: Row(children: [
          // Left: Database list
          SizedBox(width: 220, child: Container(
            decoration: BoxDecoration(color: workbenchPanelAlt, borderRadius: BorderRadius.circular(8)),
            child: Column(children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                decoration: BoxDecoration(border: Border(bottom: BorderSide(color: workbenchDivider, width: 0.5))),
                child: Row(children: [
                  Text(s.databases, style: TextStyle(color: workbenchTextMuted, fontSize: 10, fontWeight: FontWeight.w600)),
                  const Spacer(),
                  Text('${_dbList?.length ?? 0}', style: TextStyle(color: workbenchTextFaint, fontSize: 10)),
                ]),
              ),
              Expanded(child: _dbList == null
                ? Center(child: SizedBox(width: 16, height: 16, child: ProgressRing(strokeWidth: 2)))
                : ListView(children: [
                    for (final db in _dbList!) GestureDetector(
                      onTap: () async {
                        setState(() { _selectedDbName = db.name; _tableList = null; });
                        setState(() => _panelLoading = true);
                        _tableList = await _monitor?.listTables(_selectedDb!, user: _dbUser, password: _dbPass, dbName: db.name);
                        if (mounted) setState(() => _panelLoading = false);
                      },
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                        decoration: BoxDecoration(
                          color: _selectedDbName == db.name ? workbenchAccent.withValues(alpha: 0.1) : Colors.transparent,
                          border: Border(bottom: BorderSide(color: workbenchDivider, width: 0.3))),
                        child: Row(children: [
                          Icon(FluentIcons.database, size: 10, color: _selectedDbName == db.name ? workbenchAccent : workbenchTextFaint),
                          const SizedBox(width: 8),
                          Expanded(child: Text(db.name, style: TextStyle(color: workbenchText, fontSize: 11, fontWeight: _selectedDbName == db.name ? FontWeight.w600 : FontWeight.w400))),
                          Text(db.sizeFormatted, style: TextStyle(color: workbenchTextFaint, fontSize: 9)),
                        ]),
                      ),
                    ),
                  ]),
              ),
            ]),
          )),
          const SizedBox(width: 10),

          // Right: Tables + actions
          Expanded(child: _selectedDbName == null
            ? Center(child: Text(_isTr ? 'Bir veritabanı seçin' : 'Select a database', style: TextStyle(color: workbenchTextFaint, fontSize: 12)))
            : Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                // Actions bar
                Row(children: [
                  Icon(FluentIcons.table, size: 12, color: workbenchAccent),
                  const SizedBox(width: 6),
                  Text('$_selectedDbName', style: TextStyle(color: workbenchText, fontSize: 13, fontWeight: FontWeight.w600)),
                  if (_tableList != null) ...[
                    const SizedBox(width: 8),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                      decoration: BoxDecoration(color: workbenchHover, borderRadius: BorderRadius.circular(4)),
                      child: Text('${_tableList!.length} ${_isTr ? "tablo" : "tables"}', style: TextStyle(color: workbenchTextMuted, fontSize: 9)),
                    ),
                  ],
                  const Spacer(),
                  _SmallBtn(label: _isTr ? 'Yedekle (.sql.gz)' : 'Backup (.sql.gz)', color: workbenchSuccess,
                    onTap: () async {
                      final confirmed = await _confirmAction(context, '${s.backupNow}: $_selectedDbName?');
                      if (!confirmed) return;
                      setState(() => _panelLoading = true);
                      final path = await _monitor?.dumpDatabase(_selectedDb!, user: _dbUser, password: _dbPass, dbName: _selectedDbName!);
                      if (mounted) {
                        setState(() => _panelLoading = false);
                        if (path != null && path.isNotEmpty) {
                          widget.appController.addLog('DB backup: $path', level: LogLevel.info);
                          // Refresh backup list
                          _backups = await _monitor?.listBackups();
                          setState(() {});
                          _showBackupSuccess(path);
                        }
                      }
                    }),
                ]),
                const SizedBox(height: 8),

                // Table list
                Expanded(child: Container(
                  decoration: BoxDecoration(color: workbenchPanelAlt, borderRadius: BorderRadius.circular(8)),
                  child: Column(children: [
                    // Header
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                      decoration: BoxDecoration(border: Border(bottom: BorderSide(color: workbenchDivider, width: 0.5))),
                      child: Row(children: [
                        Expanded(flex: 3, child: Text(_isTr ? 'TABLO' : 'TABLE', style: TextStyle(color: workbenchTextFaint, fontSize: 9, fontWeight: FontWeight.w600))),
                        SizedBox(width: 70, child: Text(_isTr ? 'SATIRLAR' : 'ROWS', style: TextStyle(color: workbenchTextFaint, fontSize: 9, fontWeight: FontWeight.w600))),
                        SizedBox(width: 60, child: Text(_isTr ? 'VERİ' : 'DATA', style: TextStyle(color: workbenchTextFaint, fontSize: 9, fontWeight: FontWeight.w600))),
                        SizedBox(width: 60, child: Text('INDEX', style: TextStyle(color: workbenchTextFaint, fontSize: 9, fontWeight: FontWeight.w600))),
                        SizedBox(width: 50, child: Text('ENGINE', style: TextStyle(color: workbenchTextFaint, fontSize: 9, fontWeight: FontWeight.w600))),
                      ]),
                    ),
                    // Rows
                    Expanded(child: _tableList == null
                      ? Center(child: SizedBox(width: 16, height: 16, child: ProgressRing(strokeWidth: 2)))
                      : _tableList!.isEmpty
                        ? Center(child: Text(s.noData, style: TextStyle(color: workbenchTextFaint, fontSize: 11)))
                        : ListView(children: [
                            for (final t in _tableList!) Container(
                              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                              decoration: BoxDecoration(border: Border(bottom: BorderSide(color: workbenchDivider, width: 0.3))),
                              child: Row(children: [
                                Expanded(flex: 3, child: Text(t.name, style: TextStyle(color: workbenchText, fontSize: 11))),
                                SizedBox(width: 70, child: Text('${t.rows}', style: TextStyle(color: workbenchTextMuted, fontSize: 10, fontFamily: 'monospace'))),
                                SizedBox(width: 60, child: Text(t.dataMb > 0 ? '${t.dataMb.toStringAsFixed(1)}M' : '-', style: TextStyle(color: workbenchTextFaint, fontSize: 10, fontFamily: 'monospace'))),
                                SizedBox(width: 60, child: Text(t.indexMb > 0 ? '${t.indexMb.toStringAsFixed(1)}M' : '-', style: TextStyle(color: workbenchTextFaint, fontSize: 10, fontFamily: 'monospace'))),
                                SizedBox(width: 50, child: Text(t.engine, style: TextStyle(color: workbenchTextFaint, fontSize: 9))),
                              ]),
                            ),
                          ]),
                    ),
                  ]),
                )),
              ]),
          ),
        ])) else Expanded(child: Center(child: Text(_isTr ? 'Bir veritabanı motoru seçin' : 'Select a database engine', style: TextStyle(color: workbenchTextFaint)))),
      ],
    ]));
  }

  void _showBackupSuccess(String path) {
    final s = widget.appController.strings;
    showDialog(context: context, builder: (ctx) => ContentDialog(
      title: Text(s.operationSuccess),
      content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(_isTr ? 'Yedek oluşturuldu:' : 'Backup created:', style: TextStyle(color: workbenchTextMuted, fontSize: 12)),
        const SizedBox(height: 6),
        Container(
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(color: workbenchPanelAlt, borderRadius: BorderRadius.circular(6)),
          child: SelectableText(path, style: TextStyle(color: workbenchAccent, fontSize: 12, fontFamily: 'monospace')),
        ),
        const SizedBox(height: 8),
        Text(_isTr ? 'Yedekleme sekmesinden indirme yapabilirsiniz.' : 'You can download from the Backup tab.', style: TextStyle(color: workbenchTextFaint, fontSize: 11)),
      ]),
      actions: [FilledButton(onPressed: () => Navigator.pop(ctx), child: Text('OK'))],
    ));
  }

  // ─── Backup Panel ───────────────────────────────────────────
  Widget _buildBackupPanel() {
    final s = widget.appController.strings;
    if (_backups == null) return Center(child: Text(s.loading, style: TextStyle(color: workbenchTextMuted)));
    return Padding(padding: const EdgeInsets.all(12), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(children: [
        Icon(FluentIcons.cloud_download, size: 14, color: workbenchAccent),
        const SizedBox(width: 8),
        Text(s.backup, style: TextStyle(color: workbenchText, fontSize: 14, fontWeight: FontWeight.w600)),
        const SizedBox(width: 8),
        if (_backups!.isNotEmpty) Container(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
          decoration: BoxDecoration(color: workbenchHover, borderRadius: BorderRadius.circular(4)),
          child: Text('${_backups!.length}', style: TextStyle(color: workbenchTextMuted, fontSize: 9)),
        ),
        const Spacer(),
        _SmallBtn(label: _isTr ? 'Zamanlı Yedek' : 'Schedule', color: const Color(0xFF4EC9B0), onTap: () => _showScheduleBackupDialog()),
        const SizedBox(width: 6),
        _SmallBtn(label: s.refresh, color: workbenchAccent, onTap: () => _loadPanelData(10)),
      ]),
      const SizedBox(height: 4),
      Text(_isTr ? 'Sunucudaki /tmp dizinindeki yedekleri gösterir' : 'Shows backups in /tmp directory on the server',
        style: TextStyle(color: workbenchTextFaint, fontSize: 10)),
      const SizedBox(height: 10),
      if (_backups!.isEmpty)
        Expanded(child: Center(child: Column(mainAxisSize: MainAxisSize.min, children: [
          Icon(FluentIcons.cloud_download, size: 40, color: workbenchTextFaint),
          const SizedBox(height: 12),
          Text(_isTr ? 'Yedek dosyası bulunamadı' : 'No backup files found', style: TextStyle(color: workbenchTextFaint, fontSize: 13)),
        ])))
      else Expanded(child: ListView(children: [
        Container(padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4), color: workbenchHover,
          child: Row(children: [
            Expanded(flex: 3, child: Text(_isTr ? 'DOSYA' : 'FILE', style: TextStyle(color: workbenchTextFaint, fontSize: 9, fontWeight: FontWeight.w600))),
            SizedBox(width: 70, child: Text(_isTr ? 'BOYUT' : 'SIZE', style: TextStyle(color: workbenchTextFaint, fontSize: 9, fontWeight: FontWeight.w600))),
            SizedBox(width: 130, child: Text(_isTr ? 'TARİH' : 'DATE', style: TextStyle(color: workbenchTextFaint, fontSize: 9, fontWeight: FontWeight.w600))),
            SizedBox(width: 120, child: Text(_isTr ? 'İŞLEMLER' : 'ACTIONS', style: TextStyle(color: workbenchTextFaint, fontSize: 9, fontWeight: FontWeight.w600))),
          ])),
        for (final b in _backups!) Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          decoration: BoxDecoration(border: Border(bottom: BorderSide(color: workbenchDivider, width: 0.5))),
          child: Row(children: [
            Expanded(flex: 3, child: Row(children: [
              Icon(b.fileName.endsWith('.gz') ? FluentIcons.archive : FluentIcons.database, size: 11, color: workbenchAccent),
              const SizedBox(width: 6),
              Expanded(child: Text(b.fileName, style: TextStyle(color: workbenchText, fontSize: 11), overflow: TextOverflow.ellipsis)),
            ])),
            SizedBox(width: 70, child: Text(b.size, style: TextStyle(color: workbenchTextMuted, fontSize: 10))),
            SizedBox(width: 130, child: Text(b.date, style: TextStyle(color: workbenchTextFaint, fontSize: 10))),
            SizedBox(width: 120, child: Row(children: [
              _SmallBtn(label: _isTr ? 'İndir' : 'Download', color: workbenchSuccess,
                onTap: () => _downloadBackup(b)),
              const SizedBox(width: 4),
              _SmallBtn(label: _isTr ? 'Sil' : 'Delete', color: workbenchDanger,
                onTap: () async {
                  final confirmed = await _confirmAction(context, '${_isTr ? "Sil" : "Delete"}: ${b.fileName}?');
                  if (!confirmed) return;
                  await _monitor?.deleteBackup(b.path);
                  _loadPanelData(10);
                }),
            ])),
          ]),
        ),
      ])),
    ]));
  }

  Future<void> _downloadBackup(BackupEntry backup) async {
    final profile = widget.appController.connections.firstWhereOrNull((p) => p.id == _selectedProfileId);
    if (profile == null || _monitor == null) return;

    try {
      // Get or create SFTP session
      var session = widget.appController.getSftpSession(profile.id);
      if (session == null) {
        final sftpService = SftpBrowserService();
        session = await sftpService.connect(profile);
        widget.appController.setSftpSession(profile.id, session);
      }

      // Choose local download path
      final home = Platform.environment['USERPROFILE'] ?? Platform.environment['HOME'] ?? '.';
      final downloadDir = Directory('$home${Platform.pathSeparator}Downloads');
      if (!downloadDir.existsSync()) downloadDir.createSync(recursive: true);
      final localPath = '${downloadDir.path}${Platform.pathSeparator}${backup.fileName}';
      final localFile = File(localPath);

      // Track progress
      final tp = widget.appController.addTransfer(backup.fileName, 0);

      widget.appController.addLog('Downloading ${backup.fileName}...', level: LogLevel.info);

      // Download via SFTP
      final remoteFile = await session.sftp.open(backup.path);
      final stat = await remoteFile.stat();
      final totalBytes = stat.size ?? 0;
      tp.transferredBytes = 0;
      widget.appController.updateTransfer(tp, transferred: 0);

      final sink = localFile.openWrite();
      int downloaded = 0;
      await for (final chunk in remoteFile.read()) {
        sink.add(chunk);
        downloaded += chunk.length;
        if (totalBytes > 0) {
          widget.appController.updateTransfer(tp, transferred: downloaded);
        }
      }
      await sink.close();

      widget.appController.updateTransfer(tp, transferred: totalBytes > 0 ? totalBytes : downloaded, complete: true);
      widget.appController.addLog('Downloaded ${backup.fileName} → $localPath', level: LogLevel.info);

      if (mounted) {
        showDialog(context: context, builder: (ctx) => ContentDialog(
          title: Text(widget.appController.strings.operationSuccess),
          content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(_isTr ? 'İndirilen dosya:' : 'Downloaded to:', style: TextStyle(color: workbenchTextMuted, fontSize: 12)),
            const SizedBox(height: 6),
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(color: workbenchPanelAlt, borderRadius: BorderRadius.circular(6)),
              child: SelectableText(localPath, style: TextStyle(color: workbenchSuccess, fontSize: 11, fontFamily: 'monospace')),
            ),
          ]),
          actions: [FilledButton(onPressed: () => Navigator.pop(ctx), child: Text('OK'))],
        ));
      }
    } catch (e) {
      widget.appController.addLog('Download failed: $e', level: LogLevel.error);
      if (mounted) {
        showDialog(context: context, builder: (ctx) => ContentDialog(
          title: Text(widget.appController.strings.operationFailed),
          content: SelectableText('$e', style: TextStyle(color: workbenchDanger, fontSize: 11)),
          actions: [Button(onPressed: () => Navigator.pop(ctx), child: Text('OK'))],
        ));
      }
    }
  }

  void _showScheduleBackupDialog() {
    if (_detectedDbs == null || _detectedDbs!.isEmpty) {
      // Load DBs first
      _loadPanelData(9).then((_) {
        if (mounted && _detectedDbs != null && _detectedDbs!.isNotEmpty) _showScheduleBackupDialog();
        else if (mounted) {
          showDialog(context: context, builder: (ctx) => ContentDialog(
            title: Text(_isTr ? 'Veritabanı bulunamadı' : 'No databases found'),
            content: Text(_isTr ? 'Önce Veritabanı sekmesinden DB\'leri kontrol edin.' : 'Check databases from the Database tab first.'),
            actions: [Button(onPressed: () => Navigator.pop(ctx), child: Text('OK'))],
          ));
        }
      });
      return;
    }

    final dbNameCtrl = TextEditingController();
    String cronTime = '0 2 * * *'; // default: every day at 2 AM
    String selectedPreset = 'daily_2am';
    DetectedDatabase selectedDb = _detectedDbs!.first;

    final presets = {
      'daily_2am': (_isTr ? 'Her gün 02:00' : 'Daily at 02:00', '0 2 * * *'),
      'daily_4am': (_isTr ? 'Her gün 04:00' : 'Daily at 04:00', '0 4 * * *'),
      'weekly': (_isTr ? 'Haftalık (Pazar 03:00)' : 'Weekly (Sunday 03:00)', '0 3 * * 0'),
      'every_6h': (_isTr ? 'Her 6 saatte' : 'Every 6 hours', '0 */6 * * *'),
      'every_12h': (_isTr ? 'Her 12 saatte' : 'Every 12 hours', '0 */12 * * *'),
      'custom': (_isTr ? 'Özel (cron)' : 'Custom (cron)', cronTime),
    };

    showDialog(context: context, builder: (ctx) => StatefulBuilder(builder: (ctx, setDialogState) {
      return ContentDialog(
        title: Text(_isTr ? 'Zamanlı Yedekleme Ayarla' : 'Schedule Backup'),
        content: SizedBox(width: 450, child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          // DB selection
          Text(_isTr ? 'Veritabanı Motoru' : 'Database Engine', style: TextStyle(color: workbenchTextMuted, fontSize: 11)),
          const SizedBox(height: 4),
          ComboBox<DetectedDatabase>(
            value: selectedDb, isExpanded: true,
            items: _detectedDbs!.map((db) => ComboBoxItem(value: db, child: Text('${db.name} (${db.type})', style: const TextStyle(fontSize: 12)))).toList(),
            onChanged: (v) { if (v != null) setDialogState(() => selectedDb = v); },
          ),
          const SizedBox(height: 10),
          Text(_isTr ? 'Veritabanı Adı' : 'Database Name', style: TextStyle(color: workbenchTextMuted, fontSize: 11)),
          const SizedBox(height: 4),
          TextBox(controller: dbNameCtrl, placeholder: 'mydb', style: const TextStyle(fontSize: 12)),
          const SizedBox(height: 10),
          Text(_isTr ? 'Zamanlama' : 'Schedule', style: TextStyle(color: workbenchTextMuted, fontSize: 11)),
          const SizedBox(height: 4),
          ComboBox<String>(
            value: selectedPreset, isExpanded: true,
            items: presets.entries.map((e) => ComboBoxItem(value: e.key, child: Text('${e.value.$1}  (${e.value.$2})', style: const TextStyle(fontSize: 12)))).toList(),
            onChanged: (v) { if (v != null) setDialogState(() { selectedPreset = v; cronTime = presets[v]!.$2; }); },
          ),
          if (selectedPreset == 'custom') ...[
            const SizedBox(height: 6),
            TextBox(
              placeholder: '0 2 * * *',
              onChanged: (v) => cronTime = v,
              style: TextStyle(color: workbenchText, fontSize: 12, fontFamily: 'monospace'),
            ),
          ],
          const SizedBox(height: 8),
          Text(_isTr ? 'Yedekler /tmp dizinine .sql.gz olarak kaydedilir.' : 'Backups saved as .sql.gz in /tmp directory.',
            style: TextStyle(color: workbenchTextFaint, fontSize: 10)),
        ])),
        actions: [
          Button(onPressed: () => Navigator.pop(ctx), child: Text(widget.appController.strings.cancel)),
          FilledButton(
            onPressed: () async {
              if (dbNameCtrl.text.trim().isEmpty) return;
              Navigator.pop(ctx);
              // Build the crontab command
              final dbName = dbNameCtrl.text.trim();
              final prefix = selectedDb.isDocker ? 'docker exec ${selectedDb.containerId} ' : '';
              String dumpCmd;
              if (selectedDb.type == 'mysql') {
                final auth = _dbPass.isNotEmpty ? "-u$_dbUser -p'$_dbPass'" : "-u$_dbUser";
                dumpCmd = "${prefix}mysqldump $auth $dbName | gzip > /tmp/${dbName}_\$(date +\\%Y-\\%m-\\%dT\\%H-\\%M-\\%S).sql.gz";
              } else {
                final auth = _dbUser.isNotEmpty ? '-U $_dbUser' : '';
                dumpCmd = "${prefix}pg_dump $auth $dbName | gzip > /tmp/${dbName}_\$(date +\\%Y-\\%m-\\%dT\\%H-\\%M-\\%S).sql.gz";
              }
              final cronLine = '$cronTime $dumpCmd # lifeos-backup-$dbName';

              // Append to crontab
              final result = await _monitor?.exec("(crontab -l 2>/dev/null | grep -v 'lifeos-backup-$dbName'; echo '$cronLine') | crontab -");
              widget.appController.addLog('Scheduled backup: $dbName ($cronTime)', level: LogLevel.info);

              if (mounted) {
                showDialog(context: context, builder: (ctx2) => ContentDialog(
                  title: Text(widget.appController.strings.operationSuccess),
                  content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(_isTr ? 'Zamanlı yedekleme eklendi:' : 'Scheduled backup added:', style: TextStyle(color: workbenchTextMuted, fontSize: 12)),
                    const SizedBox(height: 6),
                    Container(
                      padding: const EdgeInsets.all(8),
                      decoration: BoxDecoration(color: workbenchPanelAlt, borderRadius: BorderRadius.circular(6)),
                      child: SelectableText(cronLine, style: TextStyle(color: workbenchAccent, fontSize: 10, fontFamily: 'monospace')),
                    ),
                  ]),
                  actions: [FilledButton(onPressed: () => Navigator.pop(ctx2), child: Text('OK'))],
                ));
              }
            },
            child: Text(_isTr ? 'Zamanla' : 'Schedule'),
          ),
        ],
      );
    }));
  }

  static String _fmtBytes(int b) {
    if (b < 1024) return '$b B';
    if (b < 1048576) return '${(b / 1024).toStringAsFixed(0)} KB';
    if (b < 1073741824) return '${(b / 1048576).toStringAsFixed(1)} MB';
    return '${(b / 1073741824).toStringAsFixed(1)} GB';
  }
}

// ─── Gauge Card ──────────────────────────────────────────────────────

class _GaugeCard extends StatelessWidget {
  const _GaugeCard({required this.label, required this.value, required this.suffix, required this.color, required this.icon, required this.subtitle});
  final String label, suffix, subtitle; final double value; final Color color; final IconData icon;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(color: workbenchPanelAlt, borderRadius: BorderRadius.circular(10), boxShadow: cardShadow),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Icon(icon, size: 13, color: color),
          const SizedBox(width: 6),
          Text(label, style: TextStyle(color: workbenchTextMuted, fontSize: 11, fontWeight: FontWeight.w600)),
        ]),
        const SizedBox(height: 10),
        Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
          Text('${value.toStringAsFixed(1)}', style: TextStyle(color: color, fontSize: 28, fontWeight: FontWeight.w700, height: 1)),
          Padding(padding: const EdgeInsets.only(bottom: 3), child: Text(suffix, style: TextStyle(color: color.withValues(alpha: 0.6), fontSize: 14))),
        ]),
        const SizedBox(height: 8),
        // Progress bar
        ClipRRect(
          borderRadius: BorderRadius.circular(3),
          child: SizedBox(height: 4, child: LinearProgressIndicator(
            value: (value / 100).clamp(0, 1), backgroundColor: workbenchBorder,
            valueColor: AlwaysStoppedAnimation(value > 90 ? workbenchDanger : value > 70 ? workbenchWarning : color),
          )),
        ),
        const SizedBox(height: 6),
        Text(subtitle, style: TextStyle(color: workbenchTextFaint, fontSize: 10)),
      ]),
    );
  }
}

// ─── Info Card ───────────────────────────────────────────────────────

class _InfoCard extends StatelessWidget {
  const _InfoCard({required this.label, required this.icon, required this.color, required this.children});
  final String label; final IconData icon; final Color color; final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(color: workbenchPanelAlt, borderRadius: BorderRadius.circular(10), boxShadow: cardShadow),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [Icon(icon, size: 13, color: color), const SizedBox(width: 6),
          Text(label, style: TextStyle(color: workbenchTextMuted, fontSize: 11, fontWeight: FontWeight.w600))]),
        const SizedBox(height: 14),
        ...children,
      ]),
    );
  }
}

// ─── Mini Chart ──────────────────────────────────────────────────────

class _MiniChart extends StatelessWidget {
  const _MiniChart({required this.label, required this.data, required this.color, required this.maxVal});
  final String label; final List<double> data; final Color color; final double maxVal;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 100, padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(color: workbenchPanelAlt, borderRadius: BorderRadius.circular(10), boxShadow: cardShadow),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Text(label, style: TextStyle(color: workbenchTextMuted, fontSize: 10, fontWeight: FontWeight.w600)),
          const Spacer(),
          if (data.isNotEmpty) Text('${data.last.toStringAsFixed(1)}%', style: TextStyle(color: color, fontSize: 11, fontWeight: FontWeight.w700)),
        ]),
        const SizedBox(height: 8),
        Expanded(child: CustomPaint(size: Size.infinite, painter: _ChartPainter(data: data, color: color, maxVal: maxVal))),
      ]),
    );
  }
}

class _ChartPainter extends CustomPainter {
  _ChartPainter({required this.data, required this.color, required this.maxVal});
  final List<double> data; final Color color; final double maxVal;

  @override
  void paint(Canvas canvas, Size size) {
    if (data.length < 2) return;
    final paint = Paint()..color = color..strokeWidth = 1.5..style = PaintingStyle.stroke..strokeCap = StrokeCap.round;
    final fillPaint = Paint()..shader = LinearGradient(
      begin: Alignment.topCenter, end: Alignment.bottomCenter,
      colors: [color.withValues(alpha: 0.3), color.withValues(alpha: 0.0)],
    ).createShader(Rect.fromLTWH(0, 0, size.width, size.height));

    final path = Path();
    final fillPath = Path();
    final step = size.width / (ServerMonitorService.maxHistory - 1);
    final startIdx = ServerMonitorService.maxHistory - data.length;

    for (int i = 0; i < data.length; i++) {
      final x = (startIdx + i) * step;
      final y = size.height - (data[i] / maxVal * size.height).clamp(0, size.height);
      if (i == 0) { path.moveTo(x, y); fillPath.moveTo(x, size.height); fillPath.lineTo(x, y); }
      else { path.lineTo(x, y); fillPath.lineTo(x, y); }
    }
    fillPath.lineTo((startIdx + data.length - 1) * step, size.height);
    fillPath.close();

    canvas.drawPath(fillPath, fillPaint);
    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(covariant _ChartPainter old) => true;
}

// ─── Section Title ───────────────────────────────────────────────────

class _SectionTitle extends StatelessWidget {
  const _SectionTitle({required this.label});
  final String label;
  @override
  Widget build(BuildContext context) {
    return Text(label, style: TextStyle(color: workbenchTextMuted, fontSize: 11, fontWeight: FontWeight.w600, letterSpacing: 0.5));
  }
}

// ─── Disk Row ────────────────────────────────────────────────────────

class _DiskRow extends StatelessWidget {
  const _DiskRow({required this.disk});
  final DiskInfo disk;

  @override
  Widget build(BuildContext context) {
    final color = disk.percent > 90 ? workbenchDanger : disk.percent > 70 ? workbenchWarning : workbenchSuccess;
    return Container(
      margin: const EdgeInsets.only(bottom: 4),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(color: workbenchPanelAlt, borderRadius: BorderRadius.circular(6)),
      child: Row(children: [
        SizedBox(width: 120, child: Text(disk.mount, style: TextStyle(color: workbenchText, fontSize: 11))),
        Expanded(child: ClipRRect(borderRadius: BorderRadius.circular(2),
          child: SizedBox(height: 4, child: LinearProgressIndicator(value: disk.percent / 100, backgroundColor: workbenchBorder, valueColor: AlwaysStoppedAnimation(color))))),
        const SizedBox(width: 10),
        Text('${disk.percent.toStringAsFixed(0)}%', style: TextStyle(color: color, fontSize: 11, fontWeight: FontWeight.w600)),
      ]),
    );
  }
}

// ─── Process Row ─────────────────────────────────────────────────────

class _ProcessHeader extends StatelessWidget {
  const _ProcessHeader({required this.isTr});
  final bool isTr;
  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4), color: workbenchHover,
      child: Row(children: [
        SizedBox(width: 50, child: Text('PID', style: TextStyle(color: workbenchTextFaint, fontSize: 9, fontWeight: FontWeight.w600))),
        SizedBox(width: 70, child: Text('USER', style: TextStyle(color: workbenchTextFaint, fontSize: 9, fontWeight: FontWeight.w600))),
        SizedBox(width: 50, child: Text('CPU%', style: TextStyle(color: workbenchTextFaint, fontSize: 9, fontWeight: FontWeight.w600))),
        SizedBox(width: 50, child: Text('MEM%', style: TextStyle(color: workbenchTextFaint, fontSize: 9, fontWeight: FontWeight.w600))),
        Expanded(child: Text(isTr ? 'KOMUT' : 'COMMAND', style: TextStyle(color: workbenchTextFaint, fontSize: 9, fontWeight: FontWeight.w600))),
      ]),
    );
  }
}

class _ProcessRow extends StatelessWidget {
  const _ProcessRow({required this.process});
  final ProcessInfo process;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      child: Row(children: [
        SizedBox(width: 50, child: Text(process.pid, style: TextStyle(color: workbenchTextFaint, fontSize: 10))),
        SizedBox(width: 70, child: Text(process.user, style: TextStyle(color: workbenchTextMuted, fontSize: 10))),
        SizedBox(width: 50, child: Text('${process.cpu}', style: TextStyle(color: process.cpu > 50 ? workbenchDanger : workbenchText, fontSize: 10))),
        SizedBox(width: 50, child: Text('${process.mem}', style: TextStyle(color: process.mem > 50 ? workbenchDanger : workbenchText, fontSize: 10))),
        Expanded(child: Text(process.command, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(color: workbenchText, fontSize: 10))),
      ]),
    );
  }
}

// ─── Docker Row ──────────────────────────────────────────────────────

class _DockerCard extends StatelessWidget {
  const _DockerCard({
    required this.container, required this.isTr, required this.strings,
    this.stats, this.isLogActive = false,
    required this.onStart, required this.onStop, required this.onRestart,
    required this.onRemove, required this.onLogs, required this.onStats,
  });
  final DockerContainer container; final bool isTr; final AppStrings strings;
  final DockerStats? stats; final bool isLogActive;
  final VoidCallback onStart, onStop, onRestart, onRemove, onLogs, onStats;

  @override
  Widget build(BuildContext context) {
    final isUp = container.isRunning;
    final statusColor = isUp ? workbenchSuccess : workbenchTextFaint;
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: workbenchPanelAlt,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: isLogActive ? const Color(0xFF61AFEF).withValues(alpha: 0.4) : workbenchBorder, width: 0.5),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        // Top: name + status badge + ports
        Row(children: [
          Container(width: 8, height: 8, decoration: BoxDecoration(color: statusColor, shape: BoxShape.circle,
            boxShadow: isUp ? [BoxShadow(color: workbenchSuccess.withValues(alpha: 0.4), blurRadius: 4)] : null)),
          const SizedBox(width: 8),
          Expanded(child: Text(container.name, style: TextStyle(color: workbenchText, fontSize: 13, fontWeight: FontWeight.w600))),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
            decoration: BoxDecoration(color: statusColor.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(4)),
            child: Text(isUp ? (isTr ? 'Çalışıyor' : 'Running') : (isTr ? 'Durdu' : 'Stopped'),
              style: TextStyle(color: statusColor, fontSize: 9, fontWeight: FontWeight.w600)),
          ),
        ]),
        const SizedBox(height: 6),
        // Image + status detail
        Row(children: [
          Icon(FluentIcons.product_variant, size: 10, color: workbenchTextFaint),
          const SizedBox(width: 4),
          Expanded(child: Text(container.image, style: TextStyle(color: workbenchTextMuted, fontSize: 10))),
          if (container.ports.isNotEmpty) ...[
            Icon(FluentIcons.plug_connected, size: 9, color: workbenchTextFaint),
            const SizedBox(width: 3),
            Text(container.ports.length > 30 ? '${container.ports.substring(0, 30)}...' : container.ports,
              style: TextStyle(color: workbenchTextFaint, fontSize: 9)),
          ],
        ]),
        // Inline stats (if loaded)
        if (stats != null) ...[
          const SizedBox(height: 8),
          Container(
            padding: const EdgeInsets.all(6),
            decoration: BoxDecoration(color: workbenchEditorBg, borderRadius: BorderRadius.circular(6)),
            child: Row(children: [
              _MiniStat('CPU', stats!.cpu, workbenchAccent),
              _MiniStat(isTr ? 'RAM' : 'MEM', stats!.memPerc, const Color(0xFF61AFEF)),
              _MiniStat('NET', stats!.netIO, const Color(0xFFC678DD)),
              _MiniStat('PID', stats!.pids, workbenchTextMuted),
            ]),
          ),
        ],
        const SizedBox(height: 8),
        // Action buttons
        Row(children: [
          if (isUp) _DockerBtn(label: strings.stop, color: workbenchWarning, onTap: onStop)
          else _DockerBtn(label: strings.start, color: workbenchSuccess, onTap: onStart),
          const SizedBox(width: 4),
          _DockerBtn(label: strings.restart, color: workbenchAccent, onTap: onRestart),
          const SizedBox(width: 4),
          _DockerBtn(label: 'Logs', color: const Color(0xFF61AFEF), onTap: onLogs),
          const SizedBox(width: 4),
          _DockerBtn(label: 'Stats', color: const Color(0xFFC678DD), onTap: onStats),
          const Spacer(),
          _DockerBtn(label: isTr ? 'Kaldır' : 'Remove', color: workbenchDanger, onTap: onRemove),
        ]),
      ]),
    );
  }
}

class _MiniStat extends StatelessWidget {
  const _MiniStat(this.label, this.value, this.color);
  final String label, value; final Color color;
  @override
  Widget build(BuildContext context) {
    return Expanded(child: Row(mainAxisSize: MainAxisSize.min, children: [
      Text('$label ', style: TextStyle(color: workbenchTextFaint, fontSize: 8, fontWeight: FontWeight.w600)),
      Flexible(child: Text(value, style: TextStyle(color: color, fontSize: 9, fontFamily: 'monospace'), overflow: TextOverflow.ellipsis)),
    ]));
  }
}

// Kept for Overview panel docker rows
class _DockerRow extends StatelessWidget {
  const _DockerRow({required this.container, required this.monitor, required this.isTr, required this.strings});
  final DockerContainer container; final ServerMonitorService monitor; final bool isTr; final AppStrings strings;
  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 4),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(color: workbenchPanelAlt, borderRadius: BorderRadius.circular(6)),
      child: Row(children: [
        Container(width: 8, height: 8, decoration: BoxDecoration(color: container.isRunning ? workbenchSuccess : workbenchTextFaint, shape: BoxShape.circle)),
        const SizedBox(width: 8),
        Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(container.name, style: TextStyle(color: workbenchText, fontSize: 12, fontWeight: FontWeight.w500)),
          Text('${container.image} | ${container.status}', style: TextStyle(color: workbenchTextMuted, fontSize: 10)),
        ])),
        const SizedBox(width: 8),
        if (container.isRunning) _DockerBtn(label: strings.stop, color: workbenchWarning,
          onTap: () => monitor.dockerCommand('stop ${container.id}'))
        else _DockerBtn(label: strings.start, color: workbenchSuccess,
          onTap: () => monitor.dockerCommand('start ${container.id}')),
        const SizedBox(width: 4),
        _DockerBtn(label: strings.restart, color: workbenchAccent,
          onTap: () => monitor.dockerCommand('restart ${container.id}')),
      ]),
    );
  }
}

class _DockerBtn extends StatelessWidget {
  const _DockerBtn({required this.label, required this.color, required this.onTap});
  final String label; final Color color; final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(onTap: onTap, child: Container(
      height: 24, padding: const EdgeInsets.symmetric(horizontal: 8),
      decoration: BoxDecoration(color: color.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(4)),
      child: Center(child: Text(label, style: TextStyle(color: color, fontSize: 10, fontWeight: FontWeight.w600))),
    ));
  }
}

// ─── Server Picker Row ───────────────────────────────────────────────

class _ServerPickerRow extends StatefulWidget {
  const _ServerPickerRow({required this.profile, required this.onTap});
  final ConnectionProfile profile; final VoidCallback onTap;
  @override State<_ServerPickerRow> createState() => _ServerPickerRowState();
}

class _ServerPickerRowState extends State<_ServerPickerRow> {
  bool _h = false;
  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      onEnter: (_) => setState(() => _h = true),
      onExit: (_) => setState(() => _h = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          decoration: BoxDecoration(color: _h ? workbenchHover : Colors.transparent, borderRadius: BorderRadius.circular(8), border: Border.all(color: workbenchBorder, width: 0.5)),
          child: Row(children: [
            Icon(FluentIcons.server, size: 14, color: workbenchAccent),
            const SizedBox(width: 10),
            Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(widget.profile.name, style: TextStyle(color: workbenchText, fontSize: 13, fontWeight: FontWeight.w500)),
              Text('${widget.profile.username}@${widget.profile.host}', style: TextStyle(color: workbenchTextMuted, fontSize: 11)),
            ])),
            Icon(FluentIcons.chevron_right, size: 12, color: _h ? workbenchAccent : workbenchTextFaint),
          ]),
        ),
      ),
    );
  }
}

class LinearProgressIndicator extends StatelessWidget {
  const LinearProgressIndicator({super.key, required this.value, required this.backgroundColor, required this.valueColor});
  final double value; final Color backgroundColor; final AlwaysStoppedAnimation<Color> valueColor;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (_, c) => Stack(children: [
      Container(width: c.maxWidth, color: backgroundColor),
      Container(width: c.maxWidth * value.clamp(0, 1), color: valueColor.value),
    ]));
  }
}

// ─── Panel Tab ───────────────────────────────────────────────────────

class _PanelTab extends StatefulWidget {
  const _PanelTab({required this.icon, required this.label, required this.active, required this.onTap});
  final IconData icon; final String label; final bool active; final VoidCallback onTap;
  @override State<_PanelTab> createState() => _PanelTabState();
}

class _PanelTabState extends State<_PanelTab> {
  bool _h = false;
  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      onEnter: (_) => setState(() => _h = true),
      onExit: (_) => setState(() => _h = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          margin: const EdgeInsets.symmetric(horizontal: 2),
          decoration: BoxDecoration(
            color: widget.active ? workbenchAccent.withValues(alpha: 0.12) : _h ? workbenchHover : Colors.transparent,
            borderRadius: BorderRadius.circular(6),
            border: Border(bottom: BorderSide(color: widget.active ? workbenchAccent : Colors.transparent, width: 2)),
          ),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Icon(widget.icon, size: 11, color: widget.active ? workbenchAccent : workbenchTextMuted),
            const SizedBox(width: 5),
            Text(widget.label, style: TextStyle(color: widget.active ? workbenchText : workbenchTextMuted, fontSize: 11, fontWeight: widget.active ? FontWeight.w600 : FontWeight.w400)),
          ]),
        ),
      ),
    );
  }
}

// ─── Small Button ────────────────────────────────────────────────────

class _SmallBtn extends StatelessWidget {
  const _SmallBtn({required this.label, required this.color, required this.onTap});
  final String label; final Color color; final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(onTap: onTap, child: Container(
      height: 24, padding: const EdgeInsets.symmetric(horizontal: 8),
      decoration: BoxDecoration(color: color.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(4)),
      child: Center(child: Text(label, style: TextStyle(color: color, fontSize: 10, fontWeight: FontWeight.w600))),
    ));
  }
}

// ─── Network Section ─────────────────────────────────────────────────

class _StatRow extends StatelessWidget {
  const _StatRow(this.label, this.value);
  final String label, value;
  @override
  Widget build(BuildContext context) {
    return Padding(padding: const EdgeInsets.symmetric(vertical: 3), child: Row(children: [
      SizedBox(width: 80, child: Text(label, style: TextStyle(color: workbenchTextMuted, fontSize: 12))),
      Expanded(child: Text(value, style: TextStyle(color: workbenchText, fontSize: 12, fontFamily: 'monospace'))),
    ]));
  }
}

class _NetSection extends StatelessWidget {
  const _NetSection({required this.title, required this.content});
  final String title; final String? content;

  @override
  Widget build(BuildContext context) {
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(title, style: TextStyle(color: workbenchText, fontSize: 13, fontWeight: FontWeight.w600)),
      const SizedBox(height: 6),
      Container(
        width: double.infinity, padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(color: workbenchPanelAlt, borderRadius: BorderRadius.circular(8)),
        child: SelectableText(content ?? '', style: TextStyle(color: workbenchText, fontSize: 11, fontFamily: 'monospace', height: 1.4)),
      ),
    ]);
  }
}

extension _ListExt<T> on List<T> {
  T? firstWhereOrNull(bool Function(T) test) {
    for (final e in this) { if (test(e)) return e; }
    return null;
  }
}
