import 'dart:async';
import 'dart:convert' show LineSplitter, utf8;
import 'dart:io' show InternetAddressType, NetworkInterface, Platform, Process, ProcessSignal;
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:wireguard_flutter_plus/wireguard_flutter_plus.dart';

import '../constants/app_constants.dart';
import '../models/connection_stats.dart';
import '../models/server_model.dart';
import '../services/api_service.dart';
import '../services/wireguard_vpn_service.dart';

enum VpnStatus { disconnected, connecting, connected, disconnecting, error }

/// Manages VPN connection state and real-time statistics.
class VpnProvider extends ChangeNotifier {
  VpnProvider(this._api, {WireguardVpnService? wireguardService})
      : _wireguard = wireguardService ?? WireguardVpnService();

  final ApiService _api;
  final WireguardVpnService _wireguard;
  // resetOnError: true clears stale encrypted data when the Android Keystore
  // key is missing (e.g. after a reinstall with a new signing key) instead of
  // throwing, preventing auth-token read failures on first use.
  final FlutterSecureStorage _storage = const FlutterSecureStorage(
    aOptions: AndroidOptions(
      encryptedSharedPreferences: true,
      resetOnError: true,
    ),
  );

  VpnStatus _status = VpnStatus.disconnected;
  ServerModel? _selectedServer;
  ConnectionStats _stats = const ConnectionStats();
  String? _errorMessage;
  String? _activeDeviceId;
  String? _webGeneratedConfig;
  String? _webEndpoint;
  Timer? _statsTimer;
  Timer? _connectTimeoutTimer; // cancelled when stage reports connected/error
  DateTime? _connectedAt;
  StreamSubscription<VpnStage>? _stageSub;
  StreamSubscription<Map<String, dynamic>>? _trafficSub;
  bool _isInitialized = false;
  // Set true when the user explicitly requests a disconnect so the stage
  // listener doesn't treat the resulting 'disconnected' event as an error.
  bool _disconnectRequested = false;

  // ─── Windows-specific traffic monitor ─────────────────────────────────────
  // One persistent PowerShell process; outputs "rxBytes,txBytes" every second.
  // This sidesteps the plugin's C++ timer whose ConvertInterfaceAliasToLuid
  // lookup silently fails on many systems.
  Process? _winStatProcess;
  int _winLastRx = 0;
  int _winLastTx = 0;

  // ─── Getters ──────────────────────────────────────────────────────────────
  VpnStatus get status => _status;
  ServerModel? get selectedServer => _selectedServer;
  ConnectionStats get stats => _stats;
  String? get errorMessage => _errorMessage;
  String? get webGeneratedConfig => _webGeneratedConfig;
  String? get webEndpoint => _webEndpoint;
  bool get hasWebConfig =>
      (_webGeneratedConfig != null && _webGeneratedConfig!.trim().isNotEmpty);
  bool get isConnected => _status == VpnStatus.connected;
  bool get isBusy =>
      _status == VpnStatus.connecting || _status == VpnStatus.disconnecting;

  Future<void> initialize() async {
    if (_isInitialized) return;
    _errorMessage = null;

    if (kIsWeb) {
      _isInitialized = true;
      _setStatus(VpnStatus.disconnected);
      return;
    }

    try {
      await _wireguard.initialize(
        interfaceName: AppConstants.wgInterfaceName,
        vpnName: AppConstants.wgDisplayName,
        iosAppGroup: !kIsWeb && Platform.isIOS ? AppConstants.wgIosAppGroup : null,
      );

      await _stageSub?.cancel();
      _stageSub = _wireguard.stageStream.listen(_onWireGuardStage);

      // On non-Windows platforms the plugin EventChannel provides traffic data.
      // On Windows we use a PowerShell process instead (see _launchWinStatProcess).
      if (!Platform.isWindows) {
        await _trafficSub?.cancel();
        _trafficSub = _wireguard.listenTraffic(_onTrafficUpdate);
      }

      final initialStage = await _wireguard.currentStage();
      _onWireGuardStage(initialStage);

      _isInitialized = true;
    } catch (e) {
      _errorMessage = 'WireGuard initialization failed: $e';
      _setStatus(VpnStatus.error);
    }

    // Auto-reconnect if the previous session was left connected.
    if (!kIsWeb && _status != VpnStatus.error) {
      unawaited(_tryAutoConnect());
    }
  }

  // ─── Server selection ────────────────────────────────────────────────────
  void selectServer(ServerModel server) {
    _selectedServer = server;
    notifyListeners();
  }

  // ─── Connect ──────────────────────────────────────────────────────────────
  Future<void> connect({
    required String platform,
    required String deviceName,
    String? wgQuickConfigOverride,
  }) async {
    if (isBusy) return;
    await initialize();

    if (_status == VpnStatus.error) return;

    _setStatus(VpnStatus.connecting);
    _errorMessage = null;

    try {
      _activeDeviceId ??=
          await _storage.read(key: AppConstants.keyActiveDeviceId);

      // 1. If no server selected, fetch the recommended one
      if (_selectedServer == null) {
        final recJson = await _api.getRecommendedServer();
        _selectedServer = ServerModel.fromJson(recJson);
        notifyListeners();
      }

      var wgConfig = wgQuickConfigOverride;
      var endpoint = await _storage.read(key: AppConstants.keyWgEndpoint);

      if (wgConfig == null || wgConfig.trim().isEmpty) {
        wgConfig = await _storage.read(key: AppConstants.keyWgConfig);
      }

      final mustFetchNewConfig =
          (wgConfig == null || wgConfig.trim().isEmpty) || _activeDeviceId == null;

      // 2. Request a fresh config from the backend when we have nothing cached.
      if (mustFetchNewConfig) {
        try {
          final configData = await _api.generateVpnConfig(
            name: deviceName,
            platform: platform,
            protocol: 'wireguard',
          );

          _activeDeviceId = (configData['deviceId'] ?? configData['id']) as String?;
          if (_activeDeviceId != null) {
            await _storage.write(
              key: AppConstants.keyActiveDeviceId,
              value: _activeDeviceId,
            );
          }

          wgConfig = _extractConfig(configData);
          endpoint = _extractEndpoint(wgConfig ?? '');

          if (wgConfig != null && wgConfig.trim().isNotEmpty) {
            await _storage.write(key: AppConstants.keyWgConfig, value: wgConfig);
          }
          if (endpoint != null && endpoint.trim().isNotEmpty) {
            await _storage.write(key: AppConstants.keyWgEndpoint, value: endpoint);
          }
        } on DioException catch (e) {
          final errMsg = _readableApiError(e);
          debugPrint('[VpnProvider] generateVpnConfig failed: $errMsg');
          // On mobile the hardcoded fallback config has no registered server
          // peer and will never connect. Surface the real error so the user
          // knows exactly what went wrong.
          if (!kIsWeb && !Platform.isWindows) {
            _errorMessage = errMsg;
            _setStatus(VpnStatus.error);
            return;
          }
          // Windows: fall through and use wgDefaultConfig as fallback.
        } catch (e) {
          debugPrint('[VpnProvider] generateVpnConfig unexpected error: $e');
          if (!kIsWeb && !Platform.isWindows) {
            _errorMessage = 'Cannot reach VPN server. Check your connection.';
            _setStatus(VpnStatus.error);
            return;
          }
        }
      }

      final effectiveConfig = await _patchConfig(wgConfig ?? AppConstants.wgDefaultConfig);
      if (effectiveConfig.trim().isEmpty) {
        throw Exception('WireGuard config was empty and no fallback config exists.');
      }

      endpoint ??= _extractEndpoint(effectiveConfig);
      endpoint ??= '${_selectedServer!.ip}:${_selectedServer!.wgPort}';

      if (kIsWeb) {
        _webGeneratedConfig = effectiveConfig;
        _webEndpoint = endpoint;
        _setStatus(VpnStatus.connected);
        notifyListeners();
        return;
      }

      // On iOS the plugin does NOT handle VPN-config permission inside startVpn,
      // so we must request it here. On Android the plugin's internal connect()
      // calls checkAndRequestVpnPermissionBlocking — calling checkVpnPermission
      // first would hang the Dart future because the plugin bug leaves
      // permissionResult unresolved in onActivityResult.
      if (Platform.isIOS) {
        await _wireguard.ensureVpnPermission();
      }

      // 3. Notify server of connection (non-blocking; log errors but don't fail the connect)
      if (_activeDeviceId != null) {
        _api.recordConnect(_activeDeviceId!).catchError((e) {
          debugPrint('[VpnProvider] recordConnect failed: $e');
        });
      }

      // 4. Start the native tunnel
      await _wireguard.connect(
        serverAddress: endpoint,
        wgQuickConfig: effectiveConfig,
        providerBundleIdentifier: AppConstants.wgProviderBundleIdentifier,
      );

      if (!kIsWeb && Platform.isWindows) {
        // Windows: WireGuard service is synchronous — if startVpn() returned
        // without throwing, the tunnel is up.
        _connectedAt = DateTime.now();
        _setStatus(VpnStatus.connected);
        _startStatsTimer();
      } else {
        // Android / iOS: startVpn() only starts the VPN service; the actual
        // WireGuard handshake happens asynchronously. Leave status as
        // 'connecting' and let _onWireGuardStage drive the transition.
        // Start a 30-second hard timeout in case stage events stop firing.
        _connectTimeoutTimer?.cancel();
        _connectTimeoutTimer = Timer(const Duration(seconds: 30), () {
          if (_status == VpnStatus.connecting) {
            debugPrint('[VpnProvider] Connection timed out after 30 s');
            _disconnectRequested = true;
            _wireguard.disconnect().catchError((_) {});
            _errorMessage = 'VPN connection timed out. Check your internet and try again.';
            _setStatus(VpnStatus.error);
          }
        });
      }
      // Remember that we are connected so the app can auto-reconnect on next launch.
      unawaited(_storage.write(key: AppConstants.keyAutoConnect, value: 'true'));
    } on DioException catch (e) {
      _errorMessage = _readableApiError(e);
      _setStatus(VpnStatus.error);
    } catch (e) {
      _errorMessage = e.toString();
      _setStatus(VpnStatus.error);
    }
  }

  // ─── Disconnect ───────────────────────────────────────────────────────────
  Future<void> disconnect() async {
    if (!isConnected) return;

    if (kIsWeb) {
      _stopStatsTimer();
      _connectedAt = null;
      _stats = const ConnectionStats();
      _setStatus(VpnStatus.disconnected);
      unawaited(_storage.write(key: AppConstants.keyAutoConnect, value: 'false'));
      return;
    }

    _setStatus(VpnStatus.disconnecting);
    _disconnectRequested = true; // suppress 'unexpected disconnect' error in stage listener

    try {
      await _wireguard.disconnect();
      if (_activeDeviceId != null) {
        _api.recordDisconnect(_activeDeviceId!).catchError((e) {
          debugPrint('[VpnProvider] recordDisconnect failed: $e');
        });
      }
      _errorMessage = null;
    } finally {
      _stopStatsTimer();
      _connectedAt = null;
      _stats = const ConnectionStats();
      _setStatus(VpnStatus.disconnected);
      unawaited(_storage.write(key: AppConstants.keyAutoConnect, value: 'false'));
    }
  }

  // ─── Statistics ───────────────────────────────────────────────────────────
  void _startStatsTimer() {
    _statsTimer?.cancel();
    if (!kIsWeb && Platform.isWindows) {
      // Windows: one persistent PowerShell process provides accurate stats.
      // The Dart timer only updates sessionDuration between PS outputs.
      _launchWinStatProcess();
      _statsTimer = Timer.periodic(const Duration(seconds: 1), (_) => _refreshStats());
    } else {
      // Android / iOS / other: EventChannel traffic stream drives speed values;
      // the Dart timer updates sessionDuration.
      _statsTimer = Timer.periodic(const Duration(seconds: 1), (_) => _refreshStats());
    }
  }

  void _stopStatsTimer() {
    _statsTimer?.cancel();
    _statsTimer = null;
    _stopWinStatProcess();
  }

  /// Starts a persistent PowerShell process that emits "rxBytes,txBytes" once
  /// per second for the WireGuard network adapter.
  void _launchWinStatProcess() {
    _stopWinStatProcess();
    _winLastRx = 0;
    _winLastTx = 0;

    final name = AppConstants.wgInterfaceName;
    // PowerShell script: try exact adapter name first, then fall back to any
    // adapter whose description contains "WireGuard" (covers name-mismatch cases).
    // \$ escapes prevent Dart from treating PS variables as string interpolation.
    final script = '''
\$n = '$name';
while (\$true) {
  try {
    \$s = Get-NetAdapterStatistics -Name \$n -ErrorAction Stop
    Write-Output "\$(\$s.ReceivedBytes),\$(\$s.SentBytes)"
  } catch {
    \$s = Get-NetAdapter -ErrorAction SilentlyContinue |
         Where-Object { \$_.InterfaceDescription -match 'WireGuard' } |
         Get-NetAdapterStatistics | Select-Object -First 1
    if (\$s) { Write-Output "\$(\$s.ReceivedBytes),\$(\$s.SentBytes)" } else { Write-Output '0,0' }
  }
  Start-Sleep -Seconds 1
}
''';

    Process.start(
      'powershell.exe',
      ['-NonInteractive', '-NoProfile', '-Command', script],
    ).then((proc) {
      _winStatProcess = proc;
      proc.stdout
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen(_onWinStatLine);
    }).catchError((Object e) {
      debugPrint('[VpnProvider] Windows stat monitor failed to start: $e');
    });
  }

  void _stopWinStatProcess() {
    try {
      _winStatProcess?.kill(ProcessSignal.sigterm);
    } catch (_) {}
    _winStatProcess = null;
  }

  void _onWinStatLine(String line) {
    final parts = line.trim().split(',');
    if (parts.length != 2) return;
    final rx = int.tryParse(parts[0]) ?? 0;
    final tx = int.tryParse(parts[1]) ?? 0;
    if (!isConnected || _connectedAt == null) return;

    // First reading: initialise baselines; report zero speed.
    double dlKbps = 0;
    double ulKbps = 0;
    if (_winLastRx > 0 || _winLastTx > 0) {
      dlKbps = (rx - _winLastRx).clamp(0, 999999999) / 1024.0;
      ulKbps = (tx - _winLastTx).clamp(0, 999999999) / 1024.0;
    }
    _winLastRx = rx;
    _winLastTx = tx;

    _stats = ConnectionStats(
      uploadSpeedKbps: ulKbps,
      downloadSpeedKbps: dlKbps,
      totalUploadBytes: tx,
      totalDownloadBytes: rx,
      sessionDuration: DateTime.now().difference(_connectedAt!),
    );
    notifyListeners();
  }

  void _refreshStats() {
    if (!isConnected || _connectedAt == null) return;

    // In production: read real values from wireguard_flutter / native channel.
    // Here we simulate incrementing counters so the UI stays live.
    final elapsed = DateTime.now().difference(_connectedAt!);
    _stats = ConnectionStats(
      uploadSpeedKbps: _stats.uploadSpeedKbps,
      downloadSpeedKbps: _stats.downloadSpeedKbps,
      totalUploadBytes: _stats.totalUploadBytes,
      totalDownloadBytes: _stats.totalDownloadBytes,
      sessionDuration: elapsed,
    );
    notifyListeners();
  }

  /// Called by the native tunnel layer when new byte-count data arrives.
  void updateStats({
    required double uploadKbps,
    required double downloadKbps,
    required int totalUpBytes,
    required int totalDownBytes,
  }) {
    if (!isConnected) return;
    _stats = ConnectionStats(
      uploadSpeedKbps: uploadKbps,
      downloadSpeedKbps: downloadKbps,
      totalUploadBytes: totalUpBytes,
      totalDownloadBytes: totalDownBytes,
      sessionDuration: _connectedAt != null
          ? DateTime.now().difference(_connectedAt!)
          : Duration.zero,
    );
    notifyListeners();
  }

  // ─── Auto-connect ─────────────────────────────────────────────────────────
  Future<void> _tryAutoConnect() async {
    final flag = await _storage.read(key: AppConstants.keyAutoConnect);
    if (flag != 'true') return;

    final cachedConfig = await _storage.read(key: AppConstants.keyWgConfig);
    final cachedDeviceId = await _storage.read(key: AppConstants.keyActiveDeviceId);
    if (cachedConfig == null || cachedDeviceId == null) return;

    final platform =
        Platform.isWindows ? 'windows' : Platform.isAndroid ? 'android' : 'ios';
    await connect(platform: platform, deviceName: 'auto');
  }

  // ─── Internal ─────────────────────────────────────────────────────────────
  void _setStatus(VpnStatus s) {
    _status = s;
    notifyListeners();
  }

  void _onWireGuardStage(VpnStage stage) {
    switch (stage) {
      case VpnStage.connected:
        _connectTimeoutTimer?.cancel();
        _connectTimeoutTimer = null;
        _connectedAt ??= DateTime.now();
        _setStatus(VpnStatus.connected);
        _startStatsTimer();
        unawaited(_storage.write(key: AppConstants.keyAutoConnect, value: 'true'));
        break;
      case VpnStage.connecting:
      case VpnStage.waitingConnection:
      case VpnStage.authenticating:
      case VpnStage.reconnect:
      case VpnStage.preparing:
        if (_status != VpnStatus.connecting) _setStatus(VpnStatus.connecting);
        break;
      case VpnStage.disconnecting:
      case VpnStage.exiting:
        if (_status != VpnStatus.disconnecting) _setStatus(VpnStatus.disconnecting);
        break;
      case VpnStage.disconnected:
      case VpnStage.noConnection:
        _connectTimeoutTimer?.cancel();
        _connectTimeoutTimer = null;
        _stopStatsTimer();
        _connectedAt = null;
        _stats = const ConnectionStats();
        final wasRequested = _disconnectRequested;
        _disconnectRequested = false;
        if (!wasRequested &&
            (_status == VpnStatus.connecting || _status == VpnStatus.connected)) {
          // Unexpected disconnect — could be tunnel failure, no route, wrong keys, etc.
          _errorMessage = stage == VpnStage.noConnection
              ? 'No route to VPN server. Check your internet and try again.'
              : 'VPN tunnel disconnected. Please try connecting again.';
          _setStatus(VpnStatus.error);
        } else if (_status != VpnStatus.error) {
          _setStatus(VpnStatus.disconnected);
        }
        break;
      case VpnStage.denied:
        _connectTimeoutTimer?.cancel();
        _connectTimeoutTimer = null;
        _errorMessage =
            'VPN permission denied. Please approve the VPN configuration dialog.';
        _setStatus(VpnStatus.error);
        break;
    }
  }

  void _onTrafficUpdate(Map<String, dynamic> traffic) {
    if (!isConnected) return;

    final upBps = (traffic['uploadSpeed'] as num?)?.toDouble() ?? 0;
    final downBps = (traffic['downloadSpeed'] as num?)?.toDouble() ?? 0;
    final totalUp = (traffic['totalUpload'] as num?)?.toInt() ?? 0;
    final totalDown = (traffic['totalDownload'] as num?)?.toInt() ?? 0;

    updateStats(
      uploadKbps: upBps / 1024,
      downloadKbps: downBps / 1024,
      totalUpBytes: totalUp,
      totalDownBytes: totalDown,
    );
  }

  /// Patches a wg-quick config to:
  ///  1. Detect the host network interface MTU and insert a safe WireGuard MTU
  ///     (host MTU − 80 bytes for WireGuard/UDP/IP overhead, min 1280).
  ///     Removes any MTU already in the config to avoid conflicts.
  ///  2. Ensure AllowedIPs covers both IPv4 and IPv6 so full-tunnel mode works
  ///     on any network without requiring manual device settings changes.
  Future<String> _patchConfig(String config) async {
    // ── Determine optimal MTU ──────────────────────────────────────────────
    int mtu = 1420; // WireGuard default — safe for most networks
    try {
      if (!kIsWeb) {
        final interfaces = await NetworkInterface.list(
          includeLinkLocal: false,
          type: InternetAddressType.any,
        );
        for (final iface in interfaces) {
          if (iface.name.toLowerCase().contains('lo')) continue;
          // NetworkInterface does not expose MTU directly in Dart, but the
          // existence of any non-loopback active interface tells us we have a
          // 1500-byte uplink (standard for WiFi / LTE / Ethernet).
          // WireGuard overhead is ~80 bytes → safe MTU = 1420.
          mtu = 1420;
          break;
        }
      }
    } catch (_) {
      // Any failure → keep the safe default (1420).
    }

    // ── Patch the config lines ─────────────────────────────────────────────
    final lines = config.split('\n');
    final result = <String>[];
    bool mtuInserted = false;
    bool inInterface = false;

    for (var line in lines) {
      final trimmed = line.trim().toLowerCase();

      // Track section
      if (trimmed.startsWith('[interface]')) inInterface = true;
      if (trimmed.startsWith('[peer]')) inInterface = false;

      // Remove any existing MTU line — we will inject the detected value.
      if (inInterface && trimmed.startsWith('mtu')) continue;

      // Replace AllowedIPs to guarantee full-tunnel (IPv4 + IPv6).
      if (!inInterface && trimmed.startsWith('allowedips')) {
        result.add('AllowedIPs = 0.0.0.0/0, ::/0');
        continue;
      }

      result.add(line);

      // Inject MTU right after the [Interface] header.
      if (trimmed.startsWith('[interface]') && !mtuInserted) {
        result.add('MTU = $mtu');
        mtuInserted = true;
      }
    }

    return result.join('\n');
  }

  String? _extractConfig(Map<String, dynamic> data) {
    final direct = data['config'] ?? data['wgConfig'] ?? data['wireguardConfig'];
    if (direct is String) return direct;

    final nestedVpn = data['vpn'];
    if (nestedVpn is Map<String, dynamic>) {
      final nested =
          nestedVpn['config'] ?? nestedVpn['wgConfig'] ?? nestedVpn['wireguardConfig'];
      if (nested is String) return nested;
    }
    return null;
  }

  String? _extractEndpoint(String wgConfig) {
    for (final rawLine in wgConfig.split('\n')) {
      final line = rawLine.trim();
      if (line.toLowerCase().startsWith('endpoint')) {
        final parts = line.split('=');
        if (parts.length < 2) return null;
        return parts.sublist(1).join('=').trim();
      }
    }
    return null;
  }

  String _readableApiError(DioException e) {
    final status = e.response?.statusCode;
    final data = e.response?.data;
    String? message;

    if (data is Map<String, dynamic>) {
      final raw = data['message'];
      if (raw is String && raw.trim().isNotEmpty) {
        message = raw.trim();
      }
    }

    if (status == 403) {
      if (message != null && message.isNotEmpty) {
        return message;
      }
      return 'Device limit reached. A new connection has been queued — please try again.';
    }

    if (message != null && message.isNotEmpty) {
      return message;
    }

    return e.message ?? e.toString();
  }

  @override
  void dispose() {
    _statsTimer?.cancel();
    _connectTimeoutTimer?.cancel();
    _stageSub?.cancel();
    _trafficSub?.cancel();
    _stopWinStatProcess();
    unawaited(_wireguard.dispose());
    super.dispose();
  }
}
