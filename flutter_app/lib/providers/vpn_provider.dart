import 'dart:async';
import 'dart:convert' show LineSplitter, utf8;
import 'dart:io' show Platform, Process, ProcessSignal;
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
  String? _assignedIp;
  String? _webGeneratedConfig;
  String? _webEndpoint;
  Timer? _statsTimer;
  Timer? _serverStatsTimer;
  Timer? _healthTimer;
  Timer? _connectTimeoutTimer; // cancelled when stage reports connected/error
  DateTime? _connectedAt;
  StreamSubscription<VpnStage>? _stageSub;
  StreamSubscription<Map<String, dynamic>>? _trafficSub;
  bool _isInitialized = false;
  // Set true when the user explicitly requests a disconnect so the stage
  // listener doesn't treat the resulting 'disconnected' event as an error.
  bool _disconnectRequested = false;
  DateTime? _lastTrafficUpdateAt;
  int? _lastServerRx;
  int? _lastServerTx;
  DateTime? _lastSelfHealAt;
  bool _isSelfHealing = false;

  // ─── Windows-specific traffic monitor ─────────────────────────────────────
  // One persistent PowerShell process; outputs "rxBytes,txBytes" every second.
  // This sidesteps the plugin's C++ timer whose ConvertInterfaceAliasToLuid
  // lookup silently fails on many systems.
  Process? _winStatProcess;
  int _winLastRx = 0;
  int _winLastTx = 0;
  bool _killSwitchEnabled = false;

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
  bool get killSwitchEnabled => _killSwitchEnabled;

  // ─── Kill switch ──────────────────────────────────────────────────────────
  /// Toggle the kill switch preference.
  ///
  /// Kill switch works at the WireGuard config level:
  /// • AllowedIPs = 0.0.0.0/0, ::/0 forces ALL traffic through the tunnel.
  ///   If the tunnel drops, the OS has no route for internet traffic → no leak.
  /// • When disabled, a split-tunnel route can be used if needed.
  ///
  /// Note: WireGuard inherently acts as a kill switch when AllowedIPs covers
  /// all addresses (our default). This flag additionally controls whether the
  /// app enforces blocking DNS on Windows when disconnected.
  Future<void> toggleKillSwitch() async {
    _killSwitchEnabled = !_killSwitchEnabled;
    await _storage.write(
      key: AppConstants.keyKillSwitch,
      value: _killSwitchEnabled ? 'true' : 'false',
    );
    notifyListeners();
    debugPrint('[VpnProvider] Kill switch: ${_killSwitchEnabled ? 'ON' : 'OFF'}');
  }

  Future<void> _loadKillSwitchPreference() async {
    final stored = await _storage.read(key: AppConstants.keyKillSwitch);
    _killSwitchEnabled = stored == 'true';
  }

  Future<void> initialize() async {
    if (_isInitialized) return;
    _errorMessage = null;

    await _applyConfigRevisionIfNeeded();
    await _loadKillSwitchPreference();

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
    bool forceRefreshConfig = false,
    bool preferFreshConfig = false,
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

      await _storage.write(key: AppConstants.keyLastPlatform, value: platform);
      await _storage.write(key: AppConstants.keyLastDeviceName, value: deviceName);

      var wgConfig = wgQuickConfigOverride;
      var endpoint = await _storage.read(key: AppConstants.keyWgEndpoint);

      if (wgConfig == null || wgConfig.trim().isEmpty) {
        wgConfig = await _storage.read(key: AppConstants.keyWgConfig);
      }

      final hadCachedConfig = wgConfig != null && wgConfig.trim().isNotEmpty;

      // Reuse cached config by default to keep a stable key pair per device.
      // Refresh when explicitly forced/requested, missing, or stale.
      final mustFetchNewConfig = wgQuickConfigOverride == null &&
          (forceRefreshConfig ||
            preferFreshConfig ||
            !hadCachedConfig ||
            await _isCachedConfigStale());

      // 2. Request a fresh config from the backend.
      // If that fails, keep using the last known-good config so existing users
      // can still connect across Android/iOS/Windows during transient API issues.
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
            await _storage.write(
              key: AppConstants.keyWgConfigUpdatedAt,
              value: DateTime.now().toUtc().toIso8601String(),
            );
          }
          if (endpoint != null && endpoint.trim().isNotEmpty) {
            await _storage.write(key: AppConstants.keyWgEndpoint, value: endpoint);
          }
        } on DioException catch (e) {
          final errMsg = _readableApiError(e);
          debugPrint('[VpnProvider] generateVpnConfig failed: $errMsg');
          // If we have a cached config, proceed with it as fallback.
          if (!hadCachedConfig) {
            _errorMessage = errMsg;
            _setStatus(VpnStatus.error);
            return;
          }
          _errorMessage = null;
        } catch (e) {
          debugPrint('[VpnProvider] generateVpnConfig unexpected error: $e');
          if (!hadCachedConfig) {
            _errorMessage = 'Cannot reach VPN server. Check your connection.';
            _setStatus(VpnStatus.error);
            return;
          }
          _errorMessage = null;
        }
      }

      if (wgConfig == null || wgConfig.trim().isEmpty) {
        throw Exception('WireGuard config missing. Please try again.');
      }

      final endpointFromConfig = _extractEndpoint(wgConfig);
      final endpointFromServer = '${_selectedServer!.ip}:${_selectedServer!.wgPort}';
      String resolvedEndpoint = endpointFromConfig?.trim().isNotEmpty == true
          ? endpointFromConfig!
          : endpoint?.trim().isNotEmpty == true
              ? endpoint!
              : endpointFromServer.trim().isNotEmpty
                  ? endpointFromServer
                  : '';

      // Port-mismatch guard: if the resolved endpoint uses a stale port
      // (e.g. a cached config from before a server port change), override with
      // the authoritative constant so WireGuard can reach the server.
      final expectedPort = AppConstants.wgPort.toString();
      if (resolvedEndpoint.isNotEmpty &&
          resolvedEndpoint.split(':').last != expectedPort) {
        resolvedEndpoint = AppConstants.wgServerEndpoint;
      }
      if (resolvedEndpoint.isEmpty) {
        resolvedEndpoint = AppConstants.wgServerEndpoint;
      }

      if (resolvedEndpoint.isEmpty) {
        throw Exception('No WireGuard endpoint available. Please refresh servers and try again.');
      }

      await _storage.write(key: AppConstants.keyWgEndpoint, value: resolvedEndpoint);

      final effectiveConfig = await _patchConfig(
        wgConfig,
        forcedEndpoint: resolvedEndpoint,
      );
      if (effectiveConfig.trim().isEmpty) {
        throw Exception('WireGuard config was empty and no fallback config exists.');
      }
      _assignedIp = _extractInterfaceAddress(effectiveConfig);

      if (kIsWeb) {
        _webGeneratedConfig = effectiveConfig;
        _webEndpoint = resolvedEndpoint;
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
        serverAddress: resolvedEndpoint,
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
      _stopServerStatsFallback();
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
      _startServerStatsFallback();
    }
    _startHealthMonitor();
  }

  void _stopStatsTimer() {
    _statsTimer?.cancel();
    _statsTimer = null;
    _stopWinStatProcess();
    _stopServerStatsFallback();
    _stopHealthMonitor();
  }

  void _startHealthMonitor() {
    _healthTimer?.cancel();
    _healthTimer = Timer.periodic(const Duration(seconds: 20), (_) {
      unawaited(_checkTunnelHealth());
    });
  }

  void _stopHealthMonitor() {
    _healthTimer?.cancel();
    _healthTimer = null;
  }

  Future<void> _checkTunnelHealth() async {
    if (!isConnected || _connectedAt == null || _isSelfHealing) return;

    // Give fresh sessions time to establish traffic before evaluating health.
    if (DateTime.now().difference(_connectedAt!).inSeconds < 30) return;

    final myIp = _assignedIp;
    if (myIp == null || myIp.isEmpty) return;

    try {
      final status = await _api.getVpnStatus();
      final peersRaw = status['peerStats'];
      if (peersRaw is! List) return;

      Map<String, dynamic>? myPeer;
      for (final item in peersRaw) {
        if (item is! Map) continue;
        final p = item.cast<String, dynamic>();
        final allowed = (p['allowedIps'] ?? '').toString();
        if (allowed.contains(myIp)) {
          myPeer = p;
          break;
        }
      }

      if (myPeer == null) {
        await _selfHealReconnect('peer not found on server');
        return;
      }

      final handshakeRaw = myPeer['lastHandshake'];
      DateTime? handshakeAt;
      if (handshakeRaw is String && handshakeRaw.trim().isNotEmpty) {
        handshakeAt = DateTime.tryParse(handshakeRaw)?.toUtc();
      }

      final staleHandshake = handshakeAt == null ||
          DateTime.now().toUtc().difference(handshakeAt).inMinutes >= 3;
      if (staleHandshake) {
        await _selfHealReconnect('stale handshake');
      }
    } catch (_) {
      // Ignore transient health-check failures.
    }
  }

  Future<void> _selfHealReconnect(String reason) async {
    if (_isSelfHealing) return;
    final last = _lastSelfHealAt;
    if (last != null && DateTime.now().difference(last).inMinutes < 5) {
      return;
    }

    _isSelfHealing = true;
    _lastSelfHealAt = DateTime.now();
    debugPrint('[VpnProvider] Self-heal reconnect triggered: $reason');

    try {
      final storedPlatform = await _storage.read(key: AppConstants.keyLastPlatform);
      final storedDeviceName = await _storage.read(key: AppConstants.keyLastDeviceName);
      final platform = storedPlatform ??
          (Platform.isWindows ? 'windows' : Platform.isAndroid ? 'android' : 'ios');
      final deviceName = storedDeviceName ?? 'auto-$platform';

      await disconnect();
      await connect(
        platform: platform,
        deviceName: deviceName,
        forceRefreshConfig: true,
        preferFreshConfig: true,
      );
    } catch (e) {
      debugPrint('[VpnProvider] Self-heal reconnect failed: $e');
    } finally {
      _isSelfHealing = false;
    }
  }

  void _startServerStatsFallback() {
    _serverStatsTimer?.cancel();
    _lastServerRx = null;
    _lastServerTx = null;

    _serverStatsTimer = Timer.periodic(const Duration(seconds: 1), (_) async {
      if (!isConnected || _connectedAt == null) return;

      // If native traffic callbacks are active, prefer them.
      final lastNative = _lastTrafficUpdateAt;
      if (lastNative != null && DateTime.now().difference(lastNative).inSeconds < 3) {
        return;
      }

      final myIp = _assignedIp;
      if (myIp == null || myIp.isEmpty) return;

      try {
        final status = await _api.getVpnStatus();
        final peersRaw = status['peerStats'];
        if (peersRaw is! List) return;

        Map<String, dynamic>? myPeer;
        for (final item in peersRaw) {
          if (item is! Map) continue;
          final p = item.cast<String, dynamic>();
          final allowed = (p['allowedIps'] ?? '').toString();
          if (allowed.contains(myIp)) {
            myPeer = p;
            break;
          }
        }

        if (myPeer == null) return;

        final rx = (myPeer['rxBytes'] as num?)?.toInt() ?? 0;
        final tx = (myPeer['txBytes'] as num?)?.toInt() ?? 0;

        double dlKbps = 0;
        double ulKbps = 0;
        if (_lastServerRx != null && _lastServerTx != null) {
          dlKbps = ((rx - _lastServerRx!).clamp(0, 1 << 30)) / 1024.0;
          ulKbps = ((tx - _lastServerTx!).clamp(0, 1 << 30)) / 1024.0;
        }
        _lastServerRx = rx;
        _lastServerTx = tx;

        _stats = ConnectionStats(
          uploadSpeedKbps: ulKbps,
          downloadSpeedKbps: dlKbps,
          totalUploadBytes: tx,
          totalDownloadBytes: rx,
          sessionDuration: DateTime.now().difference(_connectedAt!),
        );
        notifyListeners();
      } catch (_) {
        // Ignore fallback polling errors; native traffic stream may still work.
      }
    });
  }

  void _stopServerStatsFallback() {
    _serverStatsTimer?.cancel();
    _serverStatsTimer = null;
    _lastServerRx = null;
    _lastServerTx = null;
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

    final platform = await _storage.read(key: AppConstants.keyLastPlatform) ??
      (Platform.isWindows ? 'windows' : Platform.isAndroid ? 'android' : 'ios');
    final deviceName =
      await _storage.read(key: AppConstants.keyLastDeviceName) ?? 'auto-$platform';
    await connect(
      platform: platform,
      deviceName: deviceName,
      preferFreshConfig: false,
    );
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

    _lastTrafficUpdateAt = DateTime.now();

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

  /// Patches an AmneziaWG config to:
  ///  1. Enforce MTU = 1420 (optimal for most ISPs; reduces crypto overhead vs 1280).
  ///  2. Force IPv4-only full tunnel (AllowedIPs = 0.0.0.0/0).
  ///     IPv6 is disabled on the server to prevent GFW de-anonymisation.
  ///  3. Override the Endpoint if forcedEndpoint is provided.
  ///  4. Inject AWG obfuscation parameters from AppConstants if missing.
  ///     On Windows the standard wireguard.dll tunnel driver rejects unknown
  ///     keys (Jc/Jmin/Jmax/S1/S2/H1-H4) with error code 0, so they are
  ///     stripped entirely — all params are 0 anyway (vanilla WG behaviour).
  ///  5. Ensure DNS is present.
  Future<String> _patchConfig(
    String config, {
    String? forcedEndpoint,
  }) async {
    // Windows uses the standard WireGuard tunnel driver which rejects AWG keys.
    final injectAwgParams = !kIsWeb && !Platform.isWindows;

    // ── Patch the config lines ─────────────────────────────────────────────
    final lines = config.split('\n');
    final result = <String>[];
    bool mtuInserted = false;
    bool awgParamsInserted = false;
    bool inInterface = false;
    bool hasDns = false;

    // AWG param keys — always stripped, re-injected canonically on non-Windows.
    const awgKeys = {'jc', 'jmin', 'jmax', 's1', 's2', 'h1', 'h2', 'h3', 'h4'};

    for (var line in lines) {
      final trimmed = line.trim().toLowerCase();

      if (trimmed.startsWith('[interface]')) inInterface = true;
      if (trimmed.startsWith('[peer]')) {
        // Before closing [Interface], inject AWG params on non-Windows.
        if (injectAwgParams && !awgParamsInserted) {
          result.addAll(_awgParamLines());
          awgParamsInserted = true;
        }
        inInterface = false;
      }

      // Remove existing MTU — we enforce 1420.
      if (inInterface && trimmed.startsWith('mtu')) continue;

      // Always strip existing AWG param lines; re-inject below on non-Windows.
      if (inInterface && awgKeys.any((k) => trimmed.startsWith('$k '))) continue;

      // IPv4-only full tunnel: GFW can use IPv6 to de-anonymise VPN users.
      // Server has IPv6 disabled; ::/0 would cause a route blackhole.
      if (!inInterface && trimmed.startsWith('allowedips')) {
        result.add('AllowedIPs = 0.0.0.0/0');
        continue;
      }

      if (inInterface && trimmed.startsWith('dns')) hasDns = true;

      if (!inInterface && trimmed.startsWith('endpoint') && forcedEndpoint != null) {
        result.add('Endpoint = $forcedEndpoint');
        continue;
      }

      result.add(line);

      // Inject MTU = 1420 right after [Interface] header.
      if (trimmed.startsWith('[interface]') && !mtuInserted) {
        result.add('MTU = 1420');
        mtuInserted = true;
      }
    }

    // Edge case: config has no [Peer] section yet — inject AWG params at end.
    if (injectAwgParams && !awgParamsInserted) {
      result.addAll(_awgParamLines());
    }

    if (!hasDns) {
      final idx = result.indexWhere(
        (l) => l.trim().toLowerCase().startsWith('[interface]'),
      );
      if (idx >= 0) result.insert(idx + 1, 'DNS = 1.1.1.1, 8.8.8.8');
    }

    return result.join('\n');
  }

  /// Returns the canonical AmneziaWG obfuscation parameter lines.
  /// Values come from AppConstants which mirror the server's awg0.conf.
  /// NOT used on Windows (standard wireguard.dll rejects these keys).
  List<String> _awgParamLines() => [
    'Jc = ${AppConstants.awgJc}',
    'Jmin = ${AppConstants.awgJmin}',
    'Jmax = ${AppConstants.awgJmax}',
    'S1 = ${AppConstants.awgS1}',
    'S2 = ${AppConstants.awgS2}',
    'H1 = ${AppConstants.awgH1}',
    'H2 = ${AppConstants.awgH2}',
    'H3 = ${AppConstants.awgH3}',
    'H4 = ${AppConstants.awgH4}',
  ];

  Future<bool> _isCachedConfigStale() async {
    final raw = await _storage.read(key: AppConstants.keyWgConfigUpdatedAt);
    if (raw == null || raw.trim().isEmpty) return true;
    final parsed = DateTime.tryParse(raw);
    if (parsed == null) return true;
    return DateTime.now().toUtc().difference(parsed.toUtc()).inDays >= 3;
  }

  Future<void> _applyConfigRevisionIfNeeded() async {
    final stored = await _storage.read(key: AppConstants.keyWgConfigRevision);
    if (stored == AppConstants.wgConfigRevisionValue) return;

    await Future.wait([
      _storage.delete(key: AppConstants.keyWgConfig),
      _storage.delete(key: AppConstants.keyWgEndpoint),
      _storage.delete(key: AppConstants.keyWgConfigUpdatedAt),
      _storage.delete(key: AppConstants.keyActiveDeviceId),
      _storage.write(
        key: AppConstants.keyWgConfigRevision,
        value: AppConstants.wgConfigRevisionValue,
      ),
    ]);
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

  String? _extractInterfaceAddress(String wgConfig) {
    bool inInterface = false;
    for (final rawLine in wgConfig.split('\n')) {
      final line = rawLine.trim();
      final lower = line.toLowerCase();
      if (lower.startsWith('[interface]')) {
        inInterface = true;
        continue;
      }
      if (lower.startsWith('[peer]')) {
        inInterface = false;
        continue;
      }
      if (inInterface && lower.startsWith('address')) {
        final rhs = line.split('=').skip(1).join('=').trim();
        return rhs.split(',').first.trim();
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
    _serverStatsTimer?.cancel();
    _healthTimer?.cancel();
    _connectTimeoutTimer?.cancel();
    _stageSub?.cancel();
    _trafficSub?.cancel();
    _stopWinStatProcess();
    unawaited(_wireguard.dispose());
    super.dispose();
  }
}
