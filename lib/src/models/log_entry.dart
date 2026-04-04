enum LogLevel { info, warning, error }

class LogEntry {
  const LogEntry({
    required this.time,
    required this.level,
    required this.message,
  });

  final DateTime time;
  final LogLevel level;
  final String message;
}
