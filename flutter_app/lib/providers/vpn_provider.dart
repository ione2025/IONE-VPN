import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../constants/app_constants.dart';
import '../models/connection_stats.dart';
import '../models/server_model.dart';
import '../services/api_service.dart';

enum VpnStatus { disconnected, connecting, connected, disconnecting, error }

/// Manages VPN connection state and real-time statistics.
class VpnProvider extends ChangeNotifier {
  VpnProvider(this._api);

  final ApiService _api;
  final FlutterSecureStorage _storage = const FlutterSecureStorage();

  VpnStatus _status = VpnStatus.disconnected;
  ServerModel? _selectedServer;
  ConnectionStats _stats = const ConnectionStats();
  String? _errorMessage;
  String? _activeDeviceId;
  Timer? _statsTimer;
  DateTime? _connectedAt;

  // ─── Getters ──────────────────────────────────────────────────────────────
  VpnStatus get status => _status;
  ServerModel? get selectedServer => _selectedServer;
  ConnectionStats get stats => _stats;
  String? get errorMessage => _errorMessage;
  bool get isConnected => _status == VpnStatus.connected;
  bool get isBusy =>
      _status == VpnStatus.connecting || _status == VpnStatus.disconnecting;

  // ─── Server selection ────────────────────────────────────────────────────
  void selectServer(ServerModel server) {
    _selectedServer = server;
    notifyListeners();
  }

  // ─── Connect ──────────────────────────────────────────────────────────────
  Future<void> connect({
    required String platform,
    required String deviceName,
  }) async {
    if (isBusy) return;
    _setStatus(VpnStatus.connecting);
    _errorMessage = null;

    try {
      // 1. If no server selected, fetch the recommended one
      if (_selectedServer == null) {
        final recJson = await _api.getRecommendedServer();
        _selectedServer = ServerModel.fromJson(recJson);
        notifyListeners();
      }

      // 2. Check for a stored device config or generate a new one
      _activeDeviceId =
          await _storage.read(key: AppConstants.keyActiveDeviceId);

      if (_activeDeviceId == null) {
        final configData = await _api.generateVpnConfig(
          name: deviceName,
          platform: platform,
          protocol: 'wireguard',
        );
        _activeDeviceId = configData['deviceId'] as String;
        await _storage.write(
          key: AppConstants.keyActiveDeviceId,
          value: _activeDeviceId,
        );

        // TODO: Pass configData['config'] to the native WireGuard tunnel.
        // On Windows/macOS/Linux use wireguard_flutter or process_run to
        // invoke `wg-quick up` with the written config file.
        // On Android/iOS use VpnService / NetworkExtension.
      }

      // 3. Notify server of connection (non-blocking; log errors but don't fail the connect)
      _api.recordConnect(_activeDeviceId!).catchError((e) {
        debugPrint('[VpnProvider] recordConnect failed: $e');
      });

      // 4. Start the native tunnel
      // await WireGuardFlutter.instance.startVpn(serverAddress: ...);
      // (Platform-specific – see SETUP.md for native integration details)

      _connectedAt = DateTime.now();
      _setStatus(VpnStatus.connected);
      _startStatsTimer();
    } catch (e) {
      _errorMessage = e.toString();
      _setStatus(VpnStatus.error);
    }
  }

  // ─── Disconnect ───────────────────────────────────────────────────────────
  Future<void> disconnect() async {
    if (!isConnected) return;
    _setStatus(VpnStatus.disconnecting);

    try {
      // await WireGuardFlutter.instance.stopVpn();
      if (_activeDeviceId != null) {
        _api.recordDisconnect(_activeDeviceId!).catchError((e) {
          debugPrint('[VpnProvider] recordDisconnect failed: $e');
        });
      }
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

  @override
  void dispose() {
    _statsTimer?.cancel();
    super.dispose();
  }
}
