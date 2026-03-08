/// Real-time connection statistics shown on the home dashboard.
class ConnectionStats {
  final double uploadSpeedKbps;
  final double downloadSpeedKbps;
  final int totalUploadBytes;
  final int totalDownloadBytes;
  final Duration sessionDuration;

  const ConnectionStats({
    this.uploadSpeedKbps = 0,
    this.downloadSpeedKbps = 0,
    this.totalUploadBytes = 0,
    this.totalDownloadBytes = 0,
    this.sessionDuration = Duration.zero,
  });

  String get uploadSpeedLabel => _formatSpeed(uploadSpeedKbps);
  String get downloadSpeedLabel => _formatSpeed(downloadSpeedKbps);
  String get totalUploadLabel => _formatBytes(totalUploadBytes);
  String get totalDownloadLabel => _formatBytes(totalDownloadBytes);

  String get sessionDurationLabel {
    final h = sessionDuration.inHours.toString().padLeft(2, '0');
    final m = (sessionDuration.inMinutes % 60).toString().padLeft(2, '0');
    final s = (sessionDuration.inSeconds % 60).toString().padLeft(2, '0');
    return '$h:$m:$s';
  }

  static String _formatSpeed(double kbps) {
    if (kbps >= 1024) return '${(kbps / 1024).toStringAsFixed(1)} MB/s';
    return '${kbps.toStringAsFixed(0)} KB/s';
  }

  static String _formatBytes(int bytes) {
    if (bytes >= 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
    }
    if (bytes >= 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(bytes / 1024).toStringAsFixed(0)} KB';
  }
}
