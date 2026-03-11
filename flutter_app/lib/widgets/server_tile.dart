import 'package:flutter/material.dart';

import '../constants/app_theme.dart';
import '../models/server_model.dart';

/// A single row in the server selection list.
class ServerTile extends StatelessWidget {
  const ServerTile({
    super.key,
    required this.server,
    required this.isSelected,
    required this.onTap,
    this.badge,
  });

  final ServerModel server;
  final bool isSelected;
  final VoidCallback onTap;
  final String? badge;

  @override
  Widget build(BuildContext context) {
    final pingColor = server.ping < 80
        ? AppTheme.successGreen
        : server.ping < 180
            ? AppTheme.warningAmber
            : AppTheme.errorRed;

    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: isSelected
            ? const BorderSide(color: AppTheme.primaryBlue, width: 2)
            : BorderSide.none,
      ),
      child: ListTile(
        onTap: server.isOnline ? onTap : null,
        contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
        leading: Stack(
          alignment: Alignment.bottomRight,
          children: [
            Text(server.flag, style: const TextStyle(fontSize: 30)),
            if (!server.isOnline)
              Container(
                padding: const EdgeInsets.all(2),
                decoration: const BoxDecoration(
                  color: AppTheme.errorRed,
                  shape: BoxShape.circle,
                ),
                child: const Icon(Icons.close, color: Colors.white, size: 10),
              ),
          ],
        ),
        title: Row(
          children: [
            Flexible(
              child: Text(server.name,
                  style: const TextStyle(fontWeight: FontWeight.w600),
                  overflow: TextOverflow.ellipsis),
            ),
            if (badge != null) ...[
              const SizedBox(width: 6),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                decoration: BoxDecoration(
                  color: AppTheme.primaryBlue.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Text(badge!,
                    style: const TextStyle(
                        fontSize: 11,
                        color: AppTheme.primaryBlue,
                        fontWeight: FontWeight.w600)),
              ),
            ],
          ],
        ),
        subtitle: Text(
          server.isOnline ? 'Load ${server.loadLabel}' : 'Offline',
          style: TextStyle(
            color: server.isOnline ? null : AppTheme.errorRed,
          ),
        ),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              server.pingLabel,
              style: TextStyle(
                  color: pingColor,
                  fontWeight: FontWeight.w600,
                  fontSize: 13),
            ),
            const SizedBox(width: 8),
            if (isSelected)
              const Icon(Icons.check_circle, color: AppTheme.primaryBlue)
            else
              const Icon(Icons.chevron_right, color: Colors.grey),
          ],
        ),
      ),
    );
  }
}
