class RemoteFileEntry {
  const RemoteFileEntry({
    required this.name,
    required this.path,
    required this.isDirectory,
    this.size,
    this.longName,
    this.modified,
    this.permissions,
  });

  final String name;
  final String path;
  final bool isDirectory;
  final int? size;
  final String? longName;
  final DateTime? modified;
  final String? permissions;
}
