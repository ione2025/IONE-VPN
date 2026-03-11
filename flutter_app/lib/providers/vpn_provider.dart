import 'dart:async';
import 'dart:io' show Platform;
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
  final FlutterSecureStorage _storage = const FlutterSecureStorage();

  VpnStatus _status = VpnStatus.disconnected;
  ServerModel? _selectedServer;
  ConnectionStats _stats = const ConnectionStats();
  String? _errorMessage;
  String? _activeDeviceId;
  String? _webGeneratedConfig;
  String? _webEndpoint;
  Timer? _statsTimer;
  DateTime? _connectedAt;
  StreamSubscription<VpnStage>? _stageSub;
  StreamSubscription<Map<String, dynamic>>? _trafficSub;
  bool _isInitialized = false;

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
      await _trafficSub?.cancel();
      _trafficSub = _wireguard.listenTraffic(_onTrafficUpdate);

      final initialStage = await _wireguard.currentStage();
      _onWireGuardStage(initialStage);

      _isInitialized = true;
    } catch (e) {
      _errorMessage = 'WireGuard initialization failed: $e';
      _setStatus(VpnStatus.error);
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

      // 2. Request backend config only when we don't have a usable cached profile.
      if (mustFetchNewConfig) {
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
      }

      final effectiveConfig = wgConfig ?? AppConstants.wgDefaultConfig;
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

      await _wireguard.ensureVpnPermission();

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

      _connectedAt = DateTime.now();
      _setStatus(VpnStatus.connected);
      _startStatsTimer();
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
      return;
    }

    _setStatus(VpnStatus.disconnecting);

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
    }
  }

  // ─── Statistics ───────────────────────────────────────────────────────────
  void _startStatsTimer() {
    _statsTimer?.cancel();
    _statsTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      _refreshStats();
    });
  }

  void _stopStatsTimer() {
    _statsTimer?.cancel();
    _statsTimer = null;
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

  // ─── Internal ─────────────────────────────────────────────────────────────
  void _setStatus(VpnStatus s) {
    _status = s;
    notifyListeners();
  }

  void _onWireGuardStage(VpnStage stage) {
    switch (stage) {
      case VpnStage.connected:
        _connectedAt ??= DateTime.now();
        _setStatus(VpnStatus.connected);
        _startStatsTimer();
        break;
      case VpnStage.connecting:
      case VpnStage.waitingConnection:
      case VpnStage.authenticating:
      case VpnStage.reconnect:
      case VpnStage.preparing:
        _setStatus(VpnStatus.connecting);
        break;
      case VpnStage.disconnecting:
      case VpnStage.exiting:
        _setStatus(VpnStatus.disconnecting);
        break;
      case VpnStage.disconnected:
      case VpnStage.noConnection:
        _stopStatsTimer();
        _connectedAt = null;
        _stats = const ConnectionStats();
        if (_status != VpnStatus.error) {
          _setStatus(VpnStatus.disconnected);
        }
        break;
      case VpnStage.denied:
        _errorMessage =
            'WireGuard permission denied. Run as Administrator on Windows, and approve VPN configuration on Android/iOS.';
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
        return 'Access denied (403): $message';
      }
      return 'Access denied (403): your account may have reached device/subscription limits.';
    }

    if (message != null && message.isNotEmpty) {
      return message;
    }

    return e.message ?? e.toString();
  }

  @override
  void dispose() {
    _statsTimer?.cancel();
    _stageSub?.cancel();
    _trafficSub?.cancel();
    unawaited(_wireguard.dispose());
    super.dispose();
  }
}
