import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter/foundation.dart';
import 'package:lifeos_sftp_drive/src/models/connection_profile.dart';

/// Server metrics collected via SSH
class ServerMetrics {
  ServerMetrics({
    this.cpuUsage = 0, this.cpuCores = 1,
    this.memTotal = 0, this.memUsed = 0, this.memFree = 0,
    this.swapTotal = 0, this.swapUsed = 0,
    this.diskTotal = 0, this.diskUsed = 0, this.diskFree = 0, this.diskPath = '/',
    this.disks = const [],
    this.networkRx = 0, this.networkTx = 0,
    this.uptime = '', this.hostname = '', this.os = '', this.kernel = '',
    this.loadAvg = '',
    this.topProcesses = const [],
    this.dockerContainers = const [],
    this.timestamp,
  });

  final double cpuUsage;
  final int cpuCores;
  final int memTotal, memUsed, memFree;
  final int swapTotal, swapUsed;
  final int diskTotal, diskUsed, diskFree;
  final String diskPath;
  final List<DiskInfo> disks;
  final int networkRx, networkTx;
  final String uptime, hostname, os, kernel, loadAvg;
  final List<ProcessInfo> topProcesses;
  final List<DockerContainer> dockerContainers;
  final DateTime? timestamp;

  double get memPercent => memTotal > 0 ? (memUsed / memTotal * 100) : 0;
  double get diskPercent => diskTotal > 0 ? (diskUsed / diskTotal * 100) : 0;
}

class DiskInfo {
  DiskInfo({required this.filesystem, required this.mount, required this.total, required this.used, required this.free, required this.percent});
  final String filesystem, mount;
  final int total, used, free;
  final double percent;
}

class ProcessInfo {
  ProcessInfo({required this.pid, required this.user, required this.cpu, required this.mem, required this.command});
  final String pid, user, command;
  final double cpu, mem;
}

class DockerContainer {
  DockerContainer({required this.id, required this.name, required this.image, required this.status, required this.state, this.ports = ''});
  final String id, name, image, status, state, ports;
  bool get isRunning => state.toLowerCase() == 'running';
}

class ServiceInfo {
  ServiceInfo({required this.name, required this.load, required this.active, required this.sub, this.description = ''});
  final String name, load, active, sub, description;
  bool get isRunning => active == 'active' && sub == 'running';
  bool get isFailed => active == 'failed';
}

class UserInfo {
  UserInfo({required this.name, required this.uid, required this.gid, required this.home, required this.shell});
  final String name, uid, gid, home, shell;
}

class DockerStats {
  DockerStats({required this.cpu, required this.memUsage, required this.memPerc, required this.netIO, required this.blockIO, required this.pids});
  final String cpu, memUsage, memPerc, netIO, blockIO, pids;
}

class DockerImage {
  DockerImage({required this.repo, required this.tag, required this.id, required this.size, required this.created});
  final String repo, tag, id, size, created;
}

class DetectedDatabase {
  DetectedDatabase({required this.type, required this.name, this.isDocker = false, this.containerId});
  final String type; // 'mysql' or 'postgres'
  final String name;
  final bool isDocker;
  final String? containerId;
}

class BackupEntry {
  BackupEntry({required this.size, required this.date, required this.path});
  final String size, date, path;
  String get fileName => path.split('/').last;
}

class DbInfo {
  DbInfo({required this.name, this.sizeMb = 0});
  final String name;
  final double sizeMb;
  String get sizeFormatted => sizeMb < 1 ? '${(sizeMb * 1024).toStringAsFixed(0)} KB' : '${sizeMb.toStringAsFixed(1)} MB';
}

class TableInfo {
  TableInfo({required this.name, this.rows = 0, this.dataMb = 0, this.indexMb = 0, this.engine = ''});
  final String name, engine;
  final int rows;
  final double dataMb, indexMb;
  double get totalMb => dataMb + indexMb;
  String get sizeFormatted => totalMb < 1 ? '${(totalMb * 1024).toStringAsFixed(0)} KB' : '${totalMb.toStringAsFixed(1)} MB';
}

/// Collects server metrics via SSH session
class ServerMonitorService extends ChangeNotifier {
  ServerMonitorService({required this.profile});
  final ConnectionProfile profile;

  SSHClient? _client;
  ServerMetrics _metrics = ServerMetrics();
  Timer? _pollTimer;
  bool _connected = false;
  bool _loading = false;
  String? _error;

  ServerMetrics get metrics => _metrics;
  bool get connected => _connected;
  bool get loading => _loading;
  String? get error => _error;

  // History for charts (last 60 data points = ~5 minutes at 5s interval)
  final List<double> cpuHistory = [];
  final List<double> memHistory = [];
  final List<int> netRxHistory = [];
  final List<int> netTxHistory = [];
  static const maxHistory = 60;

  Future<void> connect() async {
    _loading = true;
    _error = null;
    notifyListeners();

    try {
      final socket = await SSHSocket.connect(profile.host, profile.port,
        timeout: const Duration(seconds: 10));

      // Support both password and private key authentication
      final keyPath = profile.privateKeyPath?.trim();
      final hasKey = keyPath != null && keyPath.isNotEmpty;
      List<SSHKeyPair>? identities;
      if (hasKey) {
        try {
          final keyFile = await File(keyPath).readAsString();
          identities = SSHKeyPair.fromPem(keyFile);
        } catch (_) {}
      }

      _client = SSHClient(socket,
        username: profile.username,
        onPasswordRequest: () => profile.password,
        identities: identities ?? [],
      );
      _connected = true;
      _loading = false;
      notifyListeners();

      // Initial fetch
      await refresh();

      // Start polling every 5 seconds
      _pollTimer = Timer.periodic(const Duration(seconds: 5), (_) => refresh());
    } catch (e) {
      _error = e.toString();
      _connected = false;
      _loading = false;
      notifyListeners();
    }
  }

  Future<void> disconnect() async {
    _pollTimer?.cancel();
    _client?.close();
    _client = null;
    _connected = false;
    notifyListeners();
  }

  Future<String> _exec(String command) async {
    if (_client == null) return '';
    try {
      final result = await _client!.run(command).timeout(const Duration(seconds: 8));
      return utf8.decode(result, allowMalformed: true).trim();
    } catch (_) {
      return '';
    }
  }

  Future<void> refresh() async {
    if (_client == null) return;

    try {
      // Run all commands in parallel
      final results = await Future.wait([
        _exec("top -bn1 | head -5"),                           // 0: cpu + load
        _exec("free -b"),                                        // 1: memory
        _exec("df -B1 /"),                                       // 2: disk root
        _exec("df -B1 --output=source,target,size,used,avail,pcent 2>/dev/null | tail -n +2"), // 3: all disks
        _exec("cat /proc/net/dev | grep -v lo | tail -1"),       // 4: network
        _exec("hostname"),                                       // 5: hostname
        _exec("uptime -p 2>/dev/null || uptime"),                // 6: uptime
        _exec("uname -r"),                                       // 7: kernel
        _exec("cat /etc/os-release 2>/dev/null | grep PRETTY_NAME | cut -d'\"' -f2"), // 8: os
        _exec("ps aux --sort=-%cpu | head -11 | tail -10"),      // 9: top processes
        _exec("docker ps --format '{{.ID}}\\t{{.Names}}\\t{{.Image}}\\t{{.Status}}\\t{{.State}}\\t{{.Ports}}' 2>/dev/null"), // 10: docker
        _exec("nproc"),                                          // 11: cpu cores
      ]);

      final cpu = _parseCpu(results[0]);
      final mem = _parseMem(results[1]);
      final disk = _parseDisk(results[2]);
      final disks = _parseAllDisks(results[3]);
      final net = _parseNet(results[4]);
      final procs = _parseProcesses(results[9]);
      final docker = _parseDocker(results[10]);
      final cores = int.tryParse(results[11]) ?? 1;
      final loadAvg = _parseLoadAvg(results[0]);

      _metrics = ServerMetrics(
        cpuUsage: cpu, cpuCores: cores,
        memTotal: mem[0], memUsed: mem[1], memFree: mem[2],
        swapTotal: mem[3], swapUsed: mem[4],
        diskTotal: disk[0], diskUsed: disk[1], diskFree: disk[2],
        disks: disks,
        networkRx: net[0], networkTx: net[1],
        hostname: results[5], uptime: results[6],
        kernel: results[7], os: results[8],
        loadAvg: loadAvg,
        topProcesses: procs,
        dockerContainers: docker,
        timestamp: DateTime.now(),
      );

      // Update history
      cpuHistory.add(cpu);
      memHistory.add(_metrics.memPercent);
      netRxHistory.add(net[0]);
      netTxHistory.add(net[1]);
      if (cpuHistory.length > maxHistory) cpuHistory.removeAt(0);
      if (memHistory.length > maxHistory) memHistory.removeAt(0);
      if (netRxHistory.length > maxHistory) netRxHistory.removeAt(0);
      if (netTxHistory.length > maxHistory) netTxHistory.removeAt(0);

      _error = null;
      notifyListeners();
    } catch (e) {
      _error = e.toString();
      notifyListeners();
    }
  }

  /// Execute a docker command
  Future<String> dockerCommand(String cmd) async {
    return _exec('docker $cmd');
  }

  /// Execute arbitrary command
  Future<String> exec(String cmd) => _exec(cmd);

  // ─── Docker Management ─────────────────────────────────────────
  Future<List<DockerContainer>> getDockerContainersAll() async {
    final out = await _exec("docker ps -a --format '{{.ID}}\\t{{.Names}}\\t{{.Image}}\\t{{.Status}}\\t{{.State}}\\t{{.Ports}}' 2>/dev/null");
    return _parseDocker(out);
  }

  Future<String> dockerAction(String containerId, String action) =>
    _exec('docker $action $containerId');

  Future<String> removeDockerContainer(String containerId) =>
    _exec('docker rm -f $containerId 2>&1');

  Future<String> removeDockerImage(String imageId) =>
    _exec('docker rmi $imageId 2>&1');

  Future<String> getDockerLogs(String containerId, {int lines = 100}) =>
    _exec('docker logs --tail $lines $containerId 2>&1');

  Future<DockerStats?> getDockerStats(String containerId) async {
    final out = await _exec("docker stats --no-stream --format '{{.CPUPerc}}\\t{{.MemUsage}}\\t{{.MemPerc}}\\t{{.NetIO}}\\t{{.BlockIO}}\\t{{.PIDs}}' $containerId 2>/dev/null");
    if (out.isEmpty) return null;
    final parts = out.split('\t');
    if (parts.length < 6) return null;
    return DockerStats(cpu: parts[0], memUsage: parts[1], memPerc: parts[2], netIO: parts[3], blockIO: parts[4], pids: parts[5]);
  }

  Future<List<DockerImage>> getDockerImages() async {
    final out = await _exec("docker images --format '{{.Repository}}\\t{{.Tag}}\\t{{.ID}}\\t{{.Size}}\\t{{.CreatedSince}}' 2>/dev/null");
    if (out.isEmpty) return [];
    return out.split('\n').where((l) => l.trim().isNotEmpty).map((line) {
      final p = line.split('\t');
      if (p.length < 5) return null;
      return DockerImage(repo: p[0], tag: p[1], id: p[2], size: p[3], created: p[4]);
    }).whereType<DockerImage>().toList();
  }

  Future<List<String>> getDockerComposeProjects() async {
    final out = await _exec("docker compose ls --format '{{.Name}}\\t{{.Status}}\\t{{.ConfigFiles}}' 2>/dev/null");
    if (out.isEmpty) return [];
    return out.split('\n').where((l) => l.trim().isNotEmpty).toList();
  }

  Future<String> dockerComposeAction(String projectDir, String action) =>
    _exec('cd $projectDir && docker compose $action 2>&1');

  // ─── Database Detection ────────────────────────────────────────
  Future<List<DetectedDatabase>> detectDatabases() async {
    final dbs = <DetectedDatabase>[];
    // Check native installs
    final mysqlCheck = await _exec('which mysql 2>/dev/null');
    if (mysqlCheck.isNotEmpty) dbs.add(DetectedDatabase(type: 'mysql', name: 'MySQL/MariaDB', isDocker: false));
    final psqlCheck = await _exec('which psql 2>/dev/null');
    if (psqlCheck.isNotEmpty) dbs.add(DetectedDatabase(type: 'postgres', name: 'PostgreSQL', isDocker: false));
    // Check Docker containers
    final dockerOut = await _exec("docker ps --format '{{.Names}}\\t{{.Image}}' 2>/dev/null");
    for (final line in dockerOut.split('\n')) {
      final p = line.split('\t');
      if (p.length < 2) continue;
      final img = p[1].toLowerCase();
      if (img.contains('mysql') || img.contains('mariadb')) {
        dbs.add(DetectedDatabase(type: 'mysql', name: p[0], isDocker: true, containerId: p[0]));
      } else if (img.contains('postgres')) {
        dbs.add(DetectedDatabase(type: 'postgres', name: p[0], isDocker: true, containerId: p[0]));
      }
    }
    return dbs;
  }

  /// List database names
  Future<List<DbInfo>> listDatabaseNames(DetectedDatabase db, {String user = 'root', String password = ''}) async {
    final prefix = db.isDocker ? 'docker exec ${db.containerId} ' : '';
    if (db.type == 'mysql') {
      final auth = password.isNotEmpty ? "-u$user -p'$password'" : "-u$user";
      final out = await _exec("${prefix}mysql $auth -N -e \"SELECT schema_name, ROUND(SUM(data_length+index_length)/1024/1024,1) AS size_mb FROM information_schema.SCHEMATA LEFT JOIN information_schema.TABLES ON table_schema=schema_name GROUP BY schema_name ORDER BY schema_name;\" 2>/dev/null");
      if (out.isEmpty) return [];
      return out.split('\n').where((l) => l.trim().isNotEmpty).map((l) {
        final p = l.split('\t');
        return DbInfo(name: p[0].trim(), sizeMb: p.length > 1 ? (double.tryParse(p[1].trim()) ?? 0) : 0);
      }).where((d) => !const ['information_schema', 'performance_schema', 'sys'].contains(d.name)).toList();
    } else {
      final auth = user.isNotEmpty ? '-U $user' : '';
      final out = await _exec("${prefix}psql $auth -t -A -c \"SELECT datname, pg_database_size(datname)/1024/1024 FROM pg_database WHERE datistemplate=false ORDER BY datname;\" 2>/dev/null");
      if (out.isEmpty) return [];
      return out.split('\n').where((l) => l.trim().isNotEmpty).map((l) {
        final p = l.split('|');
        return DbInfo(name: p[0].trim(), sizeMb: p.length > 1 ? (double.tryParse(p[1].trim()) ?? 0) : 0);
      }).toList();
    }
  }

  /// List tables with sizes for a database
  Future<List<TableInfo>> listTables(DetectedDatabase db, {String user = 'root', String password = '', required String dbName}) async {
    final prefix = db.isDocker ? 'docker exec ${db.containerId} ' : '';
    if (db.type == 'mysql') {
      final auth = password.isNotEmpty ? "-u$user -p'$password'" : "-u$user";
      final out = await _exec("${prefix}mysql $auth $dbName -N -e \"SELECT table_name, table_rows, ROUND(data_length/1024/1024,2), ROUND(index_length/1024/1024,2), engine FROM information_schema.TABLES WHERE table_schema='$dbName' ORDER BY data_length DESC;\" 2>/dev/null");
      if (out.isEmpty) return [];
      return out.split('\n').where((l) => l.trim().isNotEmpty).map((l) {
        final p = l.split('\t');
        if (p.length < 5) return null;
        return TableInfo(name: p[0].trim(), rows: int.tryParse(p[1].trim()) ?? 0, dataMb: double.tryParse(p[2].trim()) ?? 0, indexMb: double.tryParse(p[3].trim()) ?? 0, engine: p[4].trim());
      }).whereType<TableInfo>().toList();
    } else {
      final auth = user.isNotEmpty ? '-U $user' : '';
      final out = await _exec("${prefix}psql $auth -d $dbName -t -A -c \"SELECT tablename, n_live_tup, pg_total_relation_size(quote_ident(tablename))/1024/1024 FROM pg_stat_user_tables ORDER BY pg_total_relation_size(quote_ident(tablename)) DESC;\" 2>/dev/null");
      if (out.isEmpty) return [];
      return out.split('\n').where((l) => l.trim().isNotEmpty).map((l) {
        final p = l.split('|');
        if (p.length < 3) return null;
        return TableInfo(name: p[0].trim(), rows: int.tryParse(p[1].trim()) ?? 0, dataMb: double.tryParse(p[2].trim()) ?? 0, indexMb: 0, engine: 'postgres');
      }).whereType<TableInfo>().toList();
    }
  }

  /// Dump database compressed
  Future<String> dumpDatabase(DetectedDatabase db, {String user = 'root', String password = '', required String dbName, String outputPath = '/tmp'}) async {
    final timestamp = DateTime.now().toIso8601String().replaceAll(':', '-').split('.').first;
    final fileName = '${dbName}_$timestamp.sql.gz';
    final fullPath = '$outputPath/$fileName';
    final prefix = db.isDocker ? 'docker exec ${db.containerId} ' : '';
    if (db.type == 'mysql') {
      final auth = password.isNotEmpty ? "-u$user -p'$password'" : "-u$user";
      await _exec("${prefix}mysqldump $auth $dbName 2>/dev/null | gzip > $fullPath");
    } else {
      final auth = user.isNotEmpty ? '-U $user' : '';
      await _exec("${prefix}pg_dump $auth $dbName 2>/dev/null | gzip > $fullPath");
    }
    // Verify file exists and has content
    final check = await _exec("ls -lh $fullPath 2>/dev/null");
    if (check.isEmpty) return '';
    return fullPath;
  }

  /// Restore database from file
  Future<String> restoreDatabase(DetectedDatabase db, {String user = 'root', String password = '', required String dbName, required String filePath}) async {
    final prefix = db.isDocker ? 'docker exec -i ${db.containerId} ' : '';
    final isGz = filePath.endsWith('.gz');
    if (db.type == 'mysql') {
      final auth = password.isNotEmpty ? "-u$user -p'$password'" : "-u$user";
      if (isGz) return _exec("zcat $filePath | ${prefix}mysql $auth $dbName 2>&1");
      return _exec("${prefix}mysql $auth $dbName < $filePath 2>&1");
    } else {
      final auth = user.isNotEmpty ? '-U $user' : '';
      if (isGz) return _exec("zcat $filePath | ${prefix}psql $auth $dbName 2>&1");
      return _exec("${prefix}psql $auth $dbName < $filePath 2>&1");
    }
  }

  // ─── Backup ────────────────────────────────────────────────────
  Future<List<BackupEntry>> listBackups({String path = '/tmp'}) async {
    final out = await _exec("find $path -maxdepth 1 \\( -name '*.sql' -o -name '*.sql.gz' -o -name '*.tar.gz' \\) -printf '%s\\t%T+\\t%p\\n' 2>/dev/null | sort -t'\t' -k2 -r | head -30");
    if (out.isEmpty) return [];
    return out.split('\n').where((l) => l.trim().isNotEmpty).map((line) {
      final p = line.split('\t');
      if (p.length < 3) return null;
      final bytes = int.tryParse(p[0]) ?? 0;
      final date = p[1].split('.').first.replaceAll('T', ' ');
      return BackupEntry(size: _fmtBytesStatic(bytes), date: date, path: p[2]);
    }).whereType<BackupEntry>().toList();
  }

  Future<String> deleteBackup(String path) => _exec('rm -f $path 2>&1');

  static String _fmtBytesStatic(int b) {
    if (b < 1024) return '$b B';
    if (b < 1048576) return '${(b / 1024).toStringAsFixed(0)} KB';
    if (b < 1073741824) return '${(b / 1048576).toStringAsFixed(1)} MB';
    return '${(b / 1073741824).toStringAsFixed(1)} GB';
  }

  // ─── Service Management ─────────────────────────────────────────
  Future<List<ServiceInfo>> getServices() async {
    final out = await _exec("systemctl list-units --type=service --all --no-pager --plain --no-legend | head -50");
    return out.split('\n').where((l) => l.trim().isNotEmpty).map((line) {
      final parts = line.trim().split(RegExp(r'\s+'));
      if (parts.length < 4) return null;
      return ServiceInfo(name: parts[0].replaceAll('.service', ''), load: parts[1], active: parts[2], sub: parts[3], description: parts.length > 4 ? parts.sublist(4).join(' ') : '');
    }).whereType<ServiceInfo>().toList();
  }

  Future<String> serviceAction(String name, String action) => _exec('sudo systemctl $action $name');

  // ─── Firewall ───────────────────────────────────────────────────
  Future<String> getFirewallStatus() async {
    final ufw = await _exec('sudo ufw status numbered 2>/dev/null');
    if (ufw.isNotEmpty && !ufw.contains('not found')) return ufw;
    return _exec('sudo iptables -L -n --line-numbers 2>/dev/null');
  }

  Future<String> firewallAllow(String port) => _exec('sudo ufw allow $port 2>/dev/null || sudo iptables -A INPUT -p tcp --dport $port -j ACCEPT');
  Future<String> firewallDeny(String port) => _exec('sudo ufw deny $port 2>/dev/null');
  Future<String> firewallDelete(String ruleNum) => _exec('sudo ufw delete $ruleNum 2>/dev/null');

  // ─── Logs ───────────────────────────────────────────────────────
  Future<String> getLogs({String unit = '', int lines = 50}) async {
    if (unit.isNotEmpty) return _exec('journalctl -u $unit --no-pager -n $lines 2>/dev/null || tail -$lines /var/log/syslog');
    return _exec('journalctl --no-pager -n $lines 2>/dev/null || tail -$lines /var/log/syslog');
  }

  // ─── Cron Jobs ──────────────────────────────────────────────────
  Future<String> getCrontab() => _exec('crontab -l 2>/dev/null');
  Future<String> setCrontab(String content) async {
    // Write to temp file then install
    await _exec('echo ${_shellEscape(content)} > /tmp/.lifeos_crontab');
    return _exec('crontab /tmp/.lifeos_crontab && rm /tmp/.lifeos_crontab');
  }

  // ─── Users ──────────────────────────────────────────────────────
  Future<List<UserInfo>> getUsers() async {
    final out = await _exec("cat /etc/passwd | grep -v nologin | grep -v false | awk -F: '{print \$1\"\\t\"\$3\"\\t\"\$4\"\\t\"\$6\"\\t\"\$7}'");
    return out.split('\n').where((l) => l.trim().isNotEmpty).map((line) {
      final parts = line.split('\t');
      if (parts.length < 5) return null;
      return UserInfo(name: parts[0], uid: parts[1], gid: parts[2], home: parts[3], shell: parts[4]);
    }).whereType<UserInfo>().toList();
  }

  Future<String> getLastLogins() => _exec('last -10 2>/dev/null');

  // ─── Network ────────────────────────────────────────────────────
  Future<String> getNetworkInterfaces() => _exec('ip addr show 2>/dev/null || ifconfig');
  Future<String> getOpenPorts() => _exec('ss -tulnp 2>/dev/null || netstat -tulnp');
  Future<String> getRoutingTable() => _exec('ip route 2>/dev/null || route -n');
  Future<String> getDnsConfig() => _exec('cat /etc/resolv.conf');

  // ─── Packages ───────────────────────────────────────────────────
  Future<String> getPackageManager() async {
    final apt = await _exec('which apt 2>/dev/null');
    if (apt.isNotEmpty) return 'apt';
    final yum = await _exec('which yum 2>/dev/null');
    if (yum.isNotEmpty) return 'yum';
    final dnf = await _exec('which dnf 2>/dev/null');
    if (dnf.isNotEmpty) return 'dnf';
    final pacman = await _exec('which pacman 2>/dev/null');
    if (pacman.isNotEmpty) return 'pacman';
    return 'unknown';
  }

  Future<String> getInstalledPackages({String query = ''}) async {
    final pm = await getPackageManager();
    switch (pm) {
      case 'apt': return _exec('dpkg -l ${query.isNotEmpty ? "| grep $query" : ""} | head -30');
      case 'yum': case 'dnf': return _exec('$pm list installed ${query.isNotEmpty ? "| grep $query" : ""} | head -30');
      case 'pacman': return _exec('pacman -Q ${query.isNotEmpty ? "| grep $query" : ""} | head -30');
      default: return 'Package manager not found';
    }
  }

  Future<String> getUpgradablePackages() async {
    final pm = await getPackageManager();
    switch (pm) {
      case 'apt': return _exec('apt list --upgradable 2>/dev/null | tail -n +2');
      case 'yum': case 'dnf': return _exec('$pm check-update 2>/dev/null | head -20');
      case 'pacman': return _exec('pacman -Qu 2>/dev/null');
      default: return '';
    }
  }

  Future<String> installPackage(String name) async {
    final pm = await getPackageManager();
    switch (pm) {
      case 'apt': return _exec('sudo apt install -y $name');
      case 'yum': return _exec('sudo yum install -y $name');
      case 'dnf': return _exec('sudo dnf install -y $name');
      case 'pacman': return _exec('sudo pacman -S --noconfirm $name');
      default: return 'Unknown package manager';
    }
  }

  String _shellEscape(String s) => "'${s.replaceAll("'", "'\\''")}'";


  double _parseCpu(String top) {
    // Parse: %Cpu(s):  5.3 us,  1.2 sy, ...
    final match = RegExp(r'(\d+\.?\d*)\s*us').firstMatch(top);
    if (match != null) return double.tryParse(match.group(1)!) ?? 0;
    return 0;
  }

  String _parseLoadAvg(String top) {
    final match = RegExp(r'load average:\s*(.+)').firstMatch(top);
    return match?.group(1)?.trim() ?? '';
  }

  List<int> _parseMem(String free) {
    // Parse free -b output
    final lines = free.split('\n');
    int total = 0, used = 0, freeMem = 0, swapTotal = 0, swapUsed = 0;
    for (final line in lines) {
      final parts = line.trim().split(RegExp(r'\s+'));
      if (line.startsWith('Mem:') && parts.length >= 4) {
        total = int.tryParse(parts[1]) ?? 0;
        used = int.tryParse(parts[2]) ?? 0;
        freeMem = int.tryParse(parts[3]) ?? 0;
      } else if (line.startsWith('Swap:') && parts.length >= 3) {
        swapTotal = int.tryParse(parts[1]) ?? 0;
        swapUsed = int.tryParse(parts[2]) ?? 0;
      }
    }
    return [total, used, freeMem, swapTotal, swapUsed];
  }

  List<int> _parseDisk(String df) {
    final lines = df.split('\n');
    if (lines.length < 2) return [0, 0, 0];
    final parts = lines[1].trim().split(RegExp(r'\s+'));
    if (parts.length < 4) return [0, 0, 0];
    return [int.tryParse(parts[1]) ?? 0, int.tryParse(parts[2]) ?? 0, int.tryParse(parts[3]) ?? 0];
  }

  List<DiskInfo> _parseAllDisks(String df) {
    final disks = <DiskInfo>[];
    for (final line in df.split('\n')) {
      final parts = line.trim().split(RegExp(r'\s+'));
      if (parts.length < 6) continue;
      if (parts[0].startsWith('tmpfs') || parts[0].startsWith('devtmpfs') || parts[0] == 'overlay') continue;
      final pct = double.tryParse(parts[5].replaceAll('%', '')) ?? 0;
      disks.add(DiskInfo(
        filesystem: parts[0], mount: parts[1],
        total: int.tryParse(parts[2]) ?? 0,
        used: int.tryParse(parts[3]) ?? 0,
        free: int.tryParse(parts[4]) ?? 0,
        percent: pct,
      ));
    }
    return disks;
  }

  List<int> _parseNet(String line) {
    final parts = line.trim().split(RegExp(r'\s+'));
    if (parts.length < 10) return [0, 0];
    return [int.tryParse(parts[1]) ?? 0, int.tryParse(parts[9]) ?? 0];
  }

  List<ProcessInfo> _parseProcesses(String ps) {
    final procs = <ProcessInfo>[];
    for (final line in ps.split('\n')) {
      final parts = line.trim().split(RegExp(r'\s+'));
      if (parts.length < 11) continue;
      procs.add(ProcessInfo(
        user: parts[0], pid: parts[1],
        cpu: double.tryParse(parts[2]) ?? 0,
        mem: double.tryParse(parts[3]) ?? 0,
        command: parts.sublist(10).join(' '),
      ));
    }
    return procs;
  }

  List<DockerContainer> _parseDocker(String output) {
    if (output.isEmpty) return [];
    final containers = <DockerContainer>[];
    for (final line in output.split('\n')) {
      final parts = line.split('\t');
      if (parts.length < 5) continue;
      containers.add(DockerContainer(
        id: parts[0], name: parts[1], image: parts[2],
        status: parts[3], state: parts[4],
        ports: parts.length > 5 ? parts[5] : '',
      ));
    }
    return containers;
  }

  @override
  void dispose() {
    disconnect();
    super.dispose();
  }
}
