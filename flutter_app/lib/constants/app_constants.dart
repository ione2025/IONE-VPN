/// App-wide constants for IONE VPN.
class AppConstants {
  AppConstants._();

  // ─── API ──────────────────────────────────────────────────────────────────
  /// Base URL of the IONE VPN backend running on your DigitalOcean droplet.
  ///
  /// After deploying the backend (see SETUP.md):
  ///   - Without TLS:  'http://178.128.107.176/api/v1'
  ///   - With TLS:     'https://178.128.107.176/api/v1'
  ///
  /// Change this before building the app.
  static const String apiBaseUrl = 'http://178.128.107.176:3000/api/v1';

  static const Duration connectTimeout = Duration(seconds: 15);
  static const Duration receiveTimeout = Duration(seconds: 30);

  // ─── Subscription ─────────────────────────────────────────────────────────
  static const int freeMaxDevices = 1;
  static const int premiumMaxDevices = 10;
  static const int ultraMaxDevices = 50;

  // ─── WireGuard ────────────────────────────────────────────────────────────
  static const int wgPort = 51820;
  static const String wgServerEndpoint = '178.128.107.176:51820';
  static const String wgInterfaceName = 'ionewg0';
  static const String wgDisplayName = 'IONE VPN';
  static const String wgProviderBundleIdentifier = 'com.ione.vpn.WGExtension';
  static const String wgIosAppGroup = 'group.com.ione.vpn';
  static const String wgDefaultConfig = '''[Interface]
PrivateKey = wHOG6h9nB4/xrdwCl6Dez2iwvQu3KrzfjsLPdkAx5Xc=
Address = 10.8.0.2/32
DNS = 8.8.8.8, 1.1.1.1

[Peer]
PublicKey = Om7Yz8ElALCIfzF6PwMMCjuiwL+MOCMo/8vPW5LuCG4=
AllowedIPs = 0.0.0.0/0, ::/0
Endpoint = 178.128.107.176:51820
PersistentKeepalive = 25
''';

  // ─── UI ───────────────────────────────────────────────────────────────────
  static const String appName = 'IONE VPN';
  static const String appTagline = 'Secure. Fast. Private.';

  // ─── Secure storage keys ──────────────────────────────────────────────────
  static const String keyAccessToken = 'ione_access_token';
  static const String keyRefreshToken = 'ione_refresh_token';
  static const String keyActiveDeviceId = 'ione_active_device_id';
  static const String keyWgConfig = 'ione_wg_quick_config';
  static const String keyWgEndpoint = 'ione_wg_endpoint';
  /// Set to 'true' while the user is connected; drives auto-reconnect on launch.
  static const String keyAutoConnect = 'ione_auto_connect';
}
