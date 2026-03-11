import 'package:flutter/material.dart';

import '../constants/app_theme.dart';
import '../models/connection_stats.dart';

/// Displays real-time upload/download speed as a simple visual meter.
class SpeedMeter extends StatelessWidget {
  const SpeedMeter({super.key, required this.stats});
  final ConnectionStats stats;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: _SpeedGauge(
            icon: Icons.arrow_upward_rounded,
            label: 'Upload',
            value: stats.uploadSpeedLabel,
            color: AppTheme.accentCyan,
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: _SpeedGauge(
            icon: Icons.arrow_downward_rounded,
            label: 'Download',
            value: stats.downloadSpeedLabel,
            color: AppTheme.successGreen,
          ),
        ),
      ],
    );
  }
}

class _SpeedGauge extends StatelessWidget {
  const _SpeedGauge({
    required this.icon,
    required this.label,
    required this.value,
    required this.color,
  });

  final IconData icon;
  final String label;
  final String value;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 14),
        child: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: color.withValues(alpha: 0.15),
                shape: BoxShape.circle,
              ),
              child: Icon(icon, color: color, size: 18),
            ),
            const SizedBox(width: 10),
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(value,
                    style: Theme.of(context)
                        .textTheme
                        .titleLarge
                        ?.copyWith(fontSize: 16)),
                Text(label, style: Theme.of(context).textTheme.bodyMedium),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
