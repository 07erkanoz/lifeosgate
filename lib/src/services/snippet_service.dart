import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

class Snippet {
  Snippet({required this.id, required this.name, required this.command, this.description = '', this.category = 'General', this.platform = 'all'});
  final String id;
  String name;
  String command;
  String description;
  String category;
  String platform; // 'all', 'linux', 'arch', 'debian', 'rhel', 'windows', 'macos'

  Map<String, dynamic> toJson() => {'id': id, 'name': name, 'command': command, 'description': description, 'category': category, 'platform': platform};

  factory Snippet.fromJson(Map<String, dynamic> json) => Snippet(
    id: json['id'] as String, name: json['name'] as String, command: json['command'] as String,
    description: (json['description'] as String?) ?? '', category: (json['category'] as String?) ?? 'General',
    platform: (json['platform'] as String?) ?? 'all',
  );
}

class SnippetService {
  final List<Snippet> _snippets = [];
  List<Snippet> get snippets => List.unmodifiable(_snippets);

  static final defaultSnippets = [
    // ─── System (multi-distro) ─────────────────────────────
    Snippet(id: 'd1', name: 'System Update (Debian/Ubuntu)', command: 'sudo apt update && sudo apt upgrade -y', category: 'System', platform: 'debian', description: 'apt paket güncelleme'),
    Snippet(id: 'd2', name: 'System Update (Arch)', command: 'sudo pacman -Syu --noconfirm', category: 'System', platform: 'arch', description: 'pacman tam sistem güncelleme'),
    Snippet(id: 'd3', name: 'System Update (RHEL/CentOS)', command: 'sudo dnf update -y', category: 'System', platform: 'rhel', description: 'dnf paket güncelleme'),
    Snippet(id: 'd4', name: 'System Update (openSUSE)', command: 'sudo zypper update -y', category: 'System', platform: 'linux', description: 'zypper güncelleme'),

    // ─── Package Install ───────────────────────────────────
    Snippet(id: 'd5', name: 'Install Package (Debian)', command: 'sudo apt install -y ', category: 'Packages', platform: 'debian', description: 'Paket adını sonuna yazın'),
    Snippet(id: 'd6', name: 'Install Package (Arch)', command: 'sudo pacman -S --noconfirm ', category: 'Packages', platform: 'arch', description: 'Paket adını sonuna yazın'),
    Snippet(id: 'd7', name: 'Install from AUR (Arch)', command: 'yay -S --noconfirm ', category: 'Packages', platform: 'arch', description: 'AUR paketi (yay gerekli)'),
    Snippet(id: 'd8', name: 'Install Package (RHEL)', command: 'sudo dnf install -y ', category: 'Packages', platform: 'rhel'),
    Snippet(id: 'd9', name: 'Search Package (Debian)', command: 'apt search ', category: 'Packages', platform: 'debian'),
    Snippet(id: 'd10', name: 'Search Package (Arch)', command: 'pacman -Ss ', category: 'Packages', platform: 'arch'),
    Snippet(id: 'd11', name: 'List Installed (Arch)', command: 'pacman -Qe', category: 'Packages', platform: 'arch', description: 'Açıkça yüklenmiş paketler'),
    Snippet(id: 'd12', name: 'Orphan Cleanup (Arch)', command: 'sudo pacman -Rns \$(pacman -Qdtq) 2>/dev/null || echo "No orphans"', category: 'Packages', platform: 'arch', description: 'Yetim paketleri temizle'),

    // ─── Monitoring ────────────────────────────────────────
    Snippet(id: 'd20', name: 'Disk Usage', command: 'df -h', category: 'Monitoring', platform: 'all'),
    Snippet(id: 'd21', name: 'Memory Usage', command: 'free -h', category: 'Monitoring', platform: 'linux'),
    Snippet(id: 'd22', name: 'Top CPU Processes', command: 'ps aux --sort=-%cpu | head -15', category: 'Monitoring', platform: 'linux'),
    Snippet(id: 'd23', name: 'Top Memory Processes', command: 'ps aux --sort=-%mem | head -15', category: 'Monitoring', platform: 'linux'),
    Snippet(id: 'd24', name: 'System Info', command: 'uname -a && cat /etc/os-release 2>/dev/null | head -5', category: 'Monitoring', platform: 'linux'),
    Snippet(id: 'd25', name: 'Uptime & Load', command: 'uptime', category: 'Monitoring', platform: 'linux'),
    Snippet(id: 'd26', name: 'Find Large Files (>100MB)', command: 'find / -type f -size +100M 2>/dev/null | head -20', category: 'Monitoring', platform: 'linux'),
    Snippet(id: 'd27', name: 'Journal Errors (Last Hour)', command: 'journalctl --since "1 hour ago" -p err --no-pager', category: 'Monitoring', platform: 'linux'),

    // ─── Network ───────────────────────────────────────────
    Snippet(id: 'd30', name: 'Open Ports', command: 'ss -tulnp', category: 'Network', platform: 'linux'),
    Snippet(id: 'd31', name: 'Network Interfaces', command: 'ip addr show', category: 'Network', platform: 'linux'),
    Snippet(id: 'd32', name: 'Routing Table', command: 'ip route', category: 'Network', platform: 'linux'),
    Snippet(id: 'd33', name: 'DNS Config', command: 'cat /etc/resolv.conf', category: 'Network', platform: 'linux'),
    Snippet(id: 'd34', name: 'Active Connections', command: 'ss -tp', category: 'Network', platform: 'linux'),
    Snippet(id: 'd35', name: 'Firewall Status (ufw)', command: 'sudo ufw status verbose', category: 'Network', platform: 'debian'),
    Snippet(id: 'd36', name: 'Firewall Status (iptables)', command: 'sudo iptables -L -n --line-numbers', category: 'Network', platform: 'linux'),
    Snippet(id: 'd37', name: 'Firewall Status (firewalld)', command: 'sudo firewall-cmd --list-all', category: 'Network', platform: 'rhel'),

    // ─── Services ──────────────────────────────────────────
    Snippet(id: 'd40', name: 'List Running Services', command: 'systemctl list-units --type=service --state=running', category: 'Services', platform: 'linux'),
    Snippet(id: 'd41', name: 'Failed Services', command: 'systemctl --failed', category: 'Services', platform: 'linux'),
    Snippet(id: 'd42', name: 'Restart Nginx', command: 'sudo systemctl restart nginx && sudo systemctl status nginx', category: 'Services', platform: 'linux'),
    Snippet(id: 'd43', name: 'Restart Apache', command: 'sudo systemctl restart apache2 && sudo systemctl status apache2', category: 'Services', platform: 'linux'),
    Snippet(id: 'd44', name: 'Restart MySQL', command: 'sudo systemctl restart mysql && sudo systemctl status mysql', category: 'Services', platform: 'linux'),
    Snippet(id: 'd45', name: 'Restart PostgreSQL', command: 'sudo systemctl restart postgresql && sudo systemctl status postgresql', category: 'Services', platform: 'linux'),

    // ─── Docker ────────────────────────────────────────────
    Snippet(id: 'd50', name: 'Docker Containers', command: 'docker ps -a', category: 'Docker', platform: 'all'),
    Snippet(id: 'd51', name: 'Docker Images', command: 'docker images', category: 'Docker', platform: 'all'),
    Snippet(id: 'd52', name: 'Docker Cleanup', command: 'docker system prune -af && docker volume prune -f', category: 'Docker', platform: 'all', description: 'Kullanılmayan tüm kaynakları temizle'),
    Snippet(id: 'd53', name: 'Docker Compose Up', command: 'docker compose up -d', category: 'Docker', platform: 'all'),
    Snippet(id: 'd54', name: 'Docker Compose Down', command: 'docker compose down', category: 'Docker', platform: 'all'),
    Snippet(id: 'd55', name: 'Docker Logs (Follow)', command: 'docker logs -f --tail 50 ', category: 'Docker', platform: 'all', description: 'Container adını sonuna yazın'),
    Snippet(id: 'd56', name: 'Docker Stats', command: 'docker stats --no-stream', category: 'Docker', platform: 'all'),

    // ─── Git ───────────────────────────────────────────────
    Snippet(id: 'd60', name: 'Git Status', command: 'git status', category: 'Git', platform: 'all'),
    Snippet(id: 'd61', name: 'Git Pull', command: 'git pull', category: 'Git', platform: 'all'),
    Snippet(id: 'd62', name: 'Git Log (Pretty)', command: 'git log --oneline --graph --decorate -20', category: 'Git', platform: 'all'),
    Snippet(id: 'd63', name: 'Git Stash & Pull', command: 'git stash && git pull && git stash pop', category: 'Git', platform: 'all'),
    Snippet(id: 'd64', name: 'Git Branch List', command: 'git branch -a', category: 'Git', platform: 'all'),

    // ─── Backup ────────────────────────────────────────────
    Snippet(id: 'd70', name: 'Backup Directory (tar.gz)', command: 'tar -czf backup_\$(date +%Y%m%d_%H%M).tar.gz ', category: 'Backup', platform: 'linux', description: 'Dizin yolunu sonuna yazın'),
    Snippet(id: 'd71', name: 'MySQL Dump', command: 'mysqldump -u root -p --all-databases > all_db_\$(date +%Y%m%d).sql', category: 'Backup', platform: 'linux'),
    Snippet(id: 'd72', name: 'PostgreSQL Dump', command: 'pg_dumpall -U postgres > all_db_\$(date +%Y%m%d).sql', category: 'Backup', platform: 'linux'),
    Snippet(id: 'd73', name: 'Rsync Backup', command: 'rsync -avz --progress ', category: 'Backup', platform: 'linux', description: 'kaynak hedef yollarını yazın'),

    // ─── Security ──────────────────────────────────────────
    Snippet(id: 'd80', name: 'Last Logins', command: 'last -20', category: 'Security', platform: 'linux'),
    Snippet(id: 'd81', name: 'Failed Login Attempts', command: 'journalctl -u sshd --since "24 hours ago" | grep "Failed" | tail -20', category: 'Security', platform: 'linux'),
    Snippet(id: 'd82', name: 'Open SSH Sessions', command: 'who', category: 'Security', platform: 'linux'),
    Snippet(id: 'd83', name: 'Sudo Log', command: 'journalctl -u sudo --no-pager -n 30', category: 'Security', platform: 'linux'),

    // ─── Logs ──────────────────────────────────────────────
    Snippet(id: 'd90', name: 'System Log (Last 50)', command: 'journalctl --no-pager -n 50', category: 'Logs', platform: 'linux'),
    Snippet(id: 'd91', name: 'Nginx Access Log', command: 'tail -50 /var/log/nginx/access.log', category: 'Logs', platform: 'linux'),
    Snippet(id: 'd92', name: 'Nginx Error Log', command: 'tail -50 /var/log/nginx/error.log', category: 'Logs', platform: 'linux'),
    Snippet(id: 'd93', name: 'Apache Access Log', command: 'tail -50 /var/log/apache2/access.log', category: 'Logs', platform: 'linux'),
    Snippet(id: 'd94', name: 'Auth Log', command: 'tail -50 /var/log/auth.log 2>/dev/null || journalctl -u sshd -n 50', category: 'Logs', platform: 'linux'),
    Snippet(id: 'd95', name: 'Kernel Messages', command: 'dmesg | tail -30', category: 'Logs', platform: 'linux'),

    // ─── Windows PowerShell ────────────────────────────────
    Snippet(id: 'w1', name: 'System Info', command: 'Get-ComputerInfo | Select-Object CsName, OsName, OsVersion, CsTotalPhysicalMemory', category: 'System', platform: 'windows'),
    Snippet(id: 'w2', name: 'Disk Usage', command: 'Get-PSDrive -PSProvider FileSystem | Format-Table Name, Used, Free, @{n="Size";e={\$_.Used+\$_.Free}} -AutoSize', category: 'System', platform: 'windows'),
    Snippet(id: 'w3', name: 'Running Processes (Top CPU)', command: 'Get-Process | Sort-Object CPU -Descending | Select-Object -First 15 Name, CPU, WorkingSet64, Id', category: 'Monitoring', platform: 'windows'),
    Snippet(id: 'w4', name: 'Running Services', command: 'Get-Service | Where-Object {\$_.Status -eq "Running"} | Format-Table Name, DisplayName -AutoSize', category: 'Services', platform: 'windows'),
    Snippet(id: 'w5', name: 'Stopped Services', command: 'Get-Service | Where-Object {\$_.Status -eq "Stopped"} | Format-Table Name, DisplayName -AutoSize', category: 'Services', platform: 'windows'),
    Snippet(id: 'w6', name: 'Network Adapters', command: 'Get-NetAdapter | Format-Table Name, Status, LinkSpeed, MacAddress -AutoSize', category: 'Network', platform: 'windows'),
    Snippet(id: 'w7', name: 'IP Configuration', command: 'Get-NetIPAddress | Where-Object {\$_.AddressFamily -eq "IPv4"} | Format-Table InterfaceAlias, IPAddress, PrefixLength', category: 'Network', platform: 'windows'),
    Snippet(id: 'w8', name: 'Open Ports', command: 'Get-NetTCPConnection -State Listen | Format-Table LocalPort, OwningProcess -AutoSize', category: 'Network', platform: 'windows'),
    Snippet(id: 'w9', name: 'Firewall Rules', command: 'Get-NetFirewallRule -Enabled True | Select-Object -First 20 DisplayName, Direction, Action | Format-Table', category: 'Network', platform: 'windows'),
    Snippet(id: 'w10', name: 'Event Log Errors', command: 'Get-EventLog -LogName System -EntryType Error -Newest 20 | Format-Table TimeGenerated, Source, Message -AutoSize', category: 'Logs', platform: 'windows'),
    Snippet(id: 'w11', name: 'Installed Programs', command: 'Get-ItemProperty HKLM:\\Software\\Microsoft\\Windows\\CurrentVersion\\Uninstall\\* | Select-Object DisplayName, DisplayVersion | Sort-Object DisplayName | Format-Table -AutoSize', category: 'Packages', platform: 'windows'),
    Snippet(id: 'w12', name: 'Windows Update', command: 'Install-Module PSWindowsUpdate -Force; Get-WindowsUpdate', category: 'System', platform: 'windows'),
    Snippet(id: 'w13', name: 'Task Scheduler List', command: 'Get-ScheduledTask | Where-Object {\$_.State -eq "Ready"} | Select-Object TaskName, TaskPath | Format-Table -AutoSize', category: 'System', platform: 'windows'),
    Snippet(id: 'w14', name: 'IIS Sites', command: 'Get-IISSite | Format-Table Name, State, Bindings -AutoSize', category: 'Services', platform: 'windows'),

    // ─── macOS ─────────────────────────────────────────────
    Snippet(id: 'm1', name: 'System Update (macOS)', command: 'softwareupdate --list', category: 'System', platform: 'macos'),
    Snippet(id: 'm2', name: 'Homebrew Update', command: 'brew update && brew upgrade', category: 'Packages', platform: 'macos'),
    Snippet(id: 'm3', name: 'Homebrew Cleanup', command: 'brew cleanup --prune=all', category: 'Packages', platform: 'macos'),
  ];

  Future<void> load() async {
    try {
      final dir = await getApplicationSupportDirectory();
      final file = File('${dir.path}${Platform.pathSeparator}snippets.json');
      if (await file.exists()) {
        final list = (jsonDecode(await file.readAsString()) as List).cast<Map<String, dynamic>>();
        _snippets.addAll(list.map((e) => Snippet.fromJson(e)));
      }
      if (_snippets.isEmpty) {
        _snippets.addAll(defaultSnippets);
        await save();
      }
    } catch (_) {
      if (_snippets.isEmpty) _snippets.addAll(defaultSnippets);
    }
  }

  Future<void> save() async {
    try {
      final dir = await getApplicationSupportDirectory();
      final file = File('${dir.path}${Platform.pathSeparator}snippets.json');
      await file.writeAsString(jsonEncode(_snippets.map((e) => e.toJson()).toList()));
    } catch (_) {}
  }

  void add(Snippet snippet) { _snippets.add(snippet); save(); }
  void remove(String id) { _snippets.removeWhere((s) => s.id == id); save(); }
  void update(Snippet snippet) {
    final idx = _snippets.indexWhere((s) => s.id == snippet.id);
    if (idx != -1) { _snippets[idx] = snippet; save(); }
  }

  List<String> get categories => _snippets.map((s) => s.category).toSet().toList()..sort();
  List<String> get platforms => _snippets.map((s) => s.platform).toSet().toList()..sort();
  List<Snippet> byCategory(String cat) => _snippets.where((s) => s.category == cat).toList();
  List<Snippet> byPlatform(String plat) => _snippets.where((s) => s.platform == plat || s.platform == 'all').toList();
  List<Snippet> search(String query, {String? platformFilter}) {
    final q = query.toLowerCase();
    var result = _snippets.where((s) => s.name.toLowerCase().contains(q) || s.command.toLowerCase().contains(q) || s.description.toLowerCase().contains(q));
    if (platformFilter != null && platformFilter != 'all') {
      result = result.where((s) => s.platform == platformFilter || s.platform == 'all' || s.platform == 'linux');
    }
    return result.toList();
  }
}
