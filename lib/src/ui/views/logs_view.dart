import 'package:fluent_ui/fluent_ui.dart';
import 'package:lifeos_sftp_drive/src/models/log_entry.dart';
import 'package:lifeos_sftp_drive/src/state/app_controller.dart';
import 'package:lifeos_sftp_drive/src/ui/theme_tokens.dart';

class LogsView extends StatelessWidget {
  const LogsView({super.key, required this.appController});

  final AppController appController;

  @override
  Widget build(BuildContext context) {
    final s = appController.strings;
    final logs = appController.logs;

    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(
                s.logs,
                style: const TextStyle(
                  color: workbenchText,
                  fontSize: 20,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const Spacer(),
              if (logs.isNotEmpty)
                GestureDetector(
                  onTap: appController.clearLogs,
                  child: Container(
                    height: 28,
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    decoration: BoxDecoration(
                      color: workbenchPanel,
                      borderRadius: BorderRadius.circular(6),
                      border: Border.all(color: workbenchBorder, width: 0.5),
                    ),
                    child: Center(
                      child: Text(
                        s.clear,
                        style: const TextStyle(
                          color: workbenchTextMuted,
                          fontSize: 11,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 14),
          Expanded(
            child: logs.isEmpty
                ? Center(
                    child: Text(
                      s.noLogEntries,
                      style: const TextStyle(
                        color: workbenchTextMuted,
                        fontSize: 13,
                      ),
                    ),
                  )
                : ListView.separated(
                    itemCount: logs.length,
                    separatorBuilder: (_, _) => const SizedBox(height: 4),
                    itemBuilder: (context, index) {
                      final item = logs[logs.length - 1 - index];
                      final color = switch (item.level) {
                        LogLevel.info => workbenchAccent,
                        LogLevel.warning => workbenchWarning,
                        LogLevel.error => workbenchDanger,
                      };
                      return Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 14,
                          vertical: 8,
                        ),
                        decoration: BoxDecoration(
                          color: workbenchPanel,
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(
                            color: workbenchBorder,
                            width: 0.5,
                          ),
                        ),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Container(
                              width: 7,
                              height: 7,
                              margin: const EdgeInsets.only(top: 5),
                              decoration: BoxDecoration(
                                color: color,
                                shape: BoxShape.circle,
                              ),
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    item.message,
                                    style: const TextStyle(
                                      color: workbenchText,
                                      fontSize: 12,
                                    ),
                                  ),
                                  const SizedBox(height: 3),
                                  Text(
                                    _format(item.time),
                                    style: const TextStyle(
                                      color: workbenchTextFaint,
                                      fontSize: 10,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}

String _format(DateTime value) {
  final hh = value.hour.toString().padLeft(2, '0');
  final mm = value.minute.toString().padLeft(2, '0');
  final ss = value.second.toString().padLeft(2, '0');
  final dd = value.day.toString().padLeft(2, '0');
  final mo = value.month.toString().padLeft(2, '0');
  return '${value.year}-$mo-$dd $hh:$mm:$ss';
}
