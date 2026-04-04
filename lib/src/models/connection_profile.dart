class ConnectionProfile {
  const ConnectionProfile({
    required this.id,
    required this.name,
    required this.host,
    required this.port,
    required this.username,
    required this.remotePath,
    this.password = '',
    this.privateKeyPath,
    this.preferredDriveLetter,
    this.mountedDriveLetter,
    this.mounted = false,
    this.group,
    this.color,
    this.startupCommands = const [],
    this.notes = '',
    this.tmuxEnabled = true,
    this.dbUser,
    this.dbPassword,
  });

  final String id;
  final String name;
  final String host;
  final int port;
  final String username;
  final String remotePath;
  final String password;
  final String? privateKeyPath;
  final String? preferredDriveLetter;
  final String? mountedDriveLetter;
  final bool mounted;
  final String? group;
  final String? color;
  final List<String> startupCommands;
  final String notes;
  final bool tmuxEnabled;
  final String? dbUser;
  final String? dbPassword;

  ConnectionProfile copyWith({
    String? name,
    String? host,
    int? port,
    String? username,
    String? remotePath,
    String? password,
    String? privateKeyPath,
    String? preferredDriveLetter,
    String? mountedDriveLetter,
    bool? mounted,
    String? group,
    String? color,
    List<String>? startupCommands,
    String? notes,
    bool? tmuxEnabled,
    String? dbUser,
    String? dbPassword,
  }) {
    return ConnectionProfile(
      id: id,
      name: name ?? this.name,
      host: host ?? this.host,
      port: port ?? this.port,
      username: username ?? this.username,
      remotePath: remotePath ?? this.remotePath,
      password: password ?? this.password,
      privateKeyPath: privateKeyPath ?? this.privateKeyPath,
      preferredDriveLetter: preferredDriveLetter ?? this.preferredDriveLetter,
      mountedDriveLetter: mountedDriveLetter ?? this.mountedDriveLetter,
      mounted: mounted ?? this.mounted,
      group: group ?? this.group,
      color: color ?? this.color,
      startupCommands: startupCommands ?? this.startupCommands,
      notes: notes ?? this.notes,
      tmuxEnabled: tmuxEnabled ?? this.tmuxEnabled,
      dbUser: dbUser ?? this.dbUser,
      dbPassword: dbPassword ?? this.dbPassword,
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'host': host,
    'port': port,
    'username': username,
    'remotePath': remotePath,
    'password': password,
    'privateKeyPath': privateKeyPath,
    'preferredDriveLetter': preferredDriveLetter,
    if (group != null) 'group': group,
    if (color != null) 'color': color,
    if (startupCommands.isNotEmpty) 'startupCommands': startupCommands,
    if (notes.isNotEmpty) 'notes': notes,
    if (!tmuxEnabled) 'tmuxEnabled': false,
    if (dbUser != null && dbUser!.isNotEmpty) 'dbUser': dbUser,
    if (dbPassword != null && dbPassword!.isNotEmpty) 'dbPassword': dbPassword,
  };

  factory ConnectionProfile.fromJson(Map<String, dynamic> json) {
    return ConnectionProfile(
      id: json['id'] as String,
      name: json['name'] as String,
      host: json['host'] as String,
      port: json['port'] as int,
      username: json['username'] as String,
      remotePath: (json['remotePath'] as String?) ?? '',
      password: (json['password'] as String?) ?? '',
      privateKeyPath: json['privateKeyPath'] as String?,
      preferredDriveLetter: json['preferredDriveLetter'] as String?,
      group: json['group'] as String?,
      color: json['color'] as String?,
      startupCommands:
          (json['startupCommands'] as List?)
              ?.map((e) => e.toString())
              .toList() ??
          const [],
      notes: (json['notes'] as String?) ?? '',
      tmuxEnabled: (json['tmuxEnabled'] as bool?) ?? true,
      dbUser: json['dbUser'] as String?,
      dbPassword: json['dbPassword'] as String?,
    );
  }
}
