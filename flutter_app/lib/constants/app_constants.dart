/// App-wide constants for IONE VPN.
class AppConstants {
  AppConstants._();

  // ─── API ──────────────────────────────────────────────────────────────────
  /// Base URL of the IONE VPN backend running on your DigitalOcean droplet.
  ///
  /// After deploying the backend (see SETUP.md):
  ///   - Without TLS:  'http://<DROPLET_IP>/api/v1'
  ///   - With TLS:     'https://yourdomain.com/api/v1'
  ///
  /// Change this before building the app.
  static const String apiBaseUrl = 'http://YOUR_DROPLET_IP/api/v1';

  static const Duration connectTimeout = Duration(seconds: 15);
  static const Duration receiveTimeout = Duration(seconds: 30);

  // ─── Subscription ─────────────────────────────────────────────────────────
  static const int freeMaxDevices = 1;
  static const int premiumMaxDevices = 10;

  // ─── WireGuard ────────────────────────────────────────────────────────────
  static const int wgPort = 51820;

  // ─── UI ───────────────────────────────────────────────────────────────────
  static const String appName = 'IONE VPN';
  static const String appTagline = 'Secure. Fast. Private.';

  // ─── Secure storage keys ──────────────────────────────────────────────────
  static const String keyAccessToken = 'ione_access_token';
  static const String keyRefreshToken = 'ione_refresh_token';
  static const String keyActiveDeviceId = 'ione_active_device_id';
}
