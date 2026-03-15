/// App-wide constants for IONE VPN.
class AppConstants {
  AppConstants._();

  // ─── API ──────────────────────────────────────────────────────────────────
  /// Base URL of the IONE VPN backend running on your DigitalOcean droplet.
  ///
  /// After deploying the backend (see SETUP.md):
  ///   - Without TLS:  'http://129.212.208.167/api/v1'
  ///   - With TLS:     'https://129.212.208.167/api/v1'
  ///
  /// Change this before building the app.
  static const String apiBaseUrl = 'http://129.212.208.167:3000/api/v1';
  static const List<String> apiBaseUrlFallbacks = [
    'http://129.212.208.167:3000/api',
    'http://129.212.208.167:3000',
    'http://129.212.208.167/api/v1',
    'http://129.212.208.167/api',
    'http://129.212.208.167',
    'https://129.212.208.167/api/v1',
    'https://129.212.208.167/api',
    'https://129.212.208.167',
  ];

  static const Duration connectTimeout = Duration(seconds: 15);
  static const Duration receiveTimeout = Duration(seconds: 30);

  // ─── Subscription ─────────────────────────────────────────────────────────
  static const int freeMaxDevices = 1;
  static const int premiumMaxDevices = 10;
  static const int ultraMaxDevices = 50;

  // ─── AmneziaWG ────────────────────────────────────────────────────────────
  /// UDP port 443 – disguised as QUIC/HTTPS, bypasses GFW and DPI firewalls.
  static const int wgPort = 443;
  static const String wgServerEndpoint = '129.212.208.167:443';
  /// Interface name used by the wireguard_flutter_plus plugin.
  static const String wgInterfaceName = 'ioneawg0';
  static const String wgDisplayName = 'IONE VPN';
  static const String wgProviderBundleIdentifier = 'com.ione.vpn.WGExtension';
  static const String wgIosAppGroup = 'group.com.ione.vpn';

  // ── AmneziaWG obfuscation parameters ──────────────────────────────────────
  // MUST match server /etc/amnezia/amneziawg/awg0.conf [Interface] section.
  // All-zero = vanilla WireGuard speed; no junk overhead visible to DPI.
  // To unblock in actively-filtered networks: set awgS1=16, then awgJc=1.
  static const int awgJc   = 0;
  static const int awgJmin = 0;
  static const int awgJmax = 0;
  static const int awgS1   = 0;
  static const int awgS2   = 0;
  static const int awgH1   = 1;
  static const int awgH2   = 2;
  static const int awgH3   = 3;
  static const int awgH4   = 4;

  /// Fallback config used only when the backend cannot be reached on first launch.
  /// Replace keys/IP with real values from: cat /etc/amnezia/amneziawg/publickey
  static const String wgDefaultConfig = '''[Interface]
PrivateKey = wHOG6h9nB4/xrdwCl6Dez2iwvQu3KrzfjsLPdkAx5Xc=
Address = 10.9.9.2/32
DNS = 1.1.1.1, 8.8.8.8
MTU = 1280
Jc = 0
Jmin = 0
Jmax = 0
S1 = 0
S2 = 0
H1 = 1
H2 = 2
H3 = 3
H4 = 4

[Peer]
PublicKey = utWpkSYJk6pJyyWNeMy0o3KOVXGGVT1EdLplDK3bEw0=
PresharedKey =
AllowedIPs = 0.0.0.0/0
Endpoint = 129.212.208.167:443
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
  static const String keyWgConfigUpdatedAt = 'ione_wg_config_updated_at';
  static const String keyWgConfigRevision = 'ione_wg_config_revision';
  static const String keyLastPlatform = 'ione_last_platform';
  static const String keyLastDeviceName = 'ione_last_device_name';
  // Bump this value whenever server-side WireGuard baseline changes (for
  // example after restoring a known-good droplet snapshot). The app will clear
  // cached tunnel config once so the next connect fetches a fresh profile.
  static const String wgConfigRevisionValue = 'amneziawg-2026-03-16-v7';
  /// Set to 'true' while the user is connected; drives auto-reconnect on launch.
  static const String keyAutoConnect = 'ione_auto_connect';
  /// Kill switch preference ('true' | 'false').
  static const String keyKillSwitch = 'ione_kill_switch';
}
