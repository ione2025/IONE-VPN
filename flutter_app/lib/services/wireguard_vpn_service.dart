import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show debugPrint, kIsWeb;
import 'package:flutter/services.dart';
import 'package:wireguard_flutter_plus/wireguard_flutter_plus.dart';

import '../constants/app_constants.dart';

/// Thin abstraction over wireguard_flutter so providers/UI can remain clean.
class WireguardVpnService {
  WireguardVpnService();

  // late final = lazily initialized on first access. WireGuardFlutter.instance
  // throws UnsupportedError on web, so this must never be touched on web.
  // VpnProvider already guards every call-site with `if (kIsWeb) return;`.
  late final _wireguard = WireGuardFlutter.instance;
  final StreamController<VpnStage> _stageController =
      StreamController<VpnStage>.broadcast();

  StreamSubscription<VpnStage>? _stageSubscription;
  StreamSubscription<Map<String, dynamic>>? _trafficSubscription;
  bool _initialized = false;

  Stream<VpnStage> get stageStream => _stageController.stream;
  Stream<Map<String, dynamic>> get trafficStream => _wireguard.trafficSnapshot;

  Future<void> initialize({
    required String interfaceName,
    String? vpnName,
    String? iosAppGroup,
  }) async {
    if (_initialized) return;

    await _wireguard.initialize(
      interfaceName: interfaceName,
      vpnName: vpnName,
      iosAppGroup: iosAppGroup,
    );

    _stageSubscription?.cancel();
    _stageSubscription = _wireguard.vpnStageSnapshot.listen(
      _stageController.add,
      onError: _stageController.addError,
    );

    _initialized = true;

    try {
      await _wireguard.refreshStage();
    } on MissingPluginException {
      // refreshStage is not implemented on Windows desktop; safe to ignore.
    }
    try {
      final stage = await _wireguard.stage();
      _stageController.add(stage);
    } on MissingPluginException {
      _stageController.add(VpnStage.disconnected);
    }
  }

  /// Returns true if VPN usage is permitted on this device.
  /// On Windows the plugin does not implement this check (the app runs as
  /// Administrator via UAC manifest), so we skip the native call entirely.
  Future<bool> checkVpnPermission() async {
    if (!kIsWeb && Platform.isWindows) return true;
    try {
      return await _wireguard.checkVpnPermission();
    } on MissingPluginException {
      return true;
    }
  }

  Future<void> ensureVpnPermission() async {
    final allowed = await checkVpnPermission();
    if (!allowed) {
      throw StateError(
        'VPN permission denied. Approve the Android VPN dialog and retry.',
      );
    }
  }

  StreamSubscription<Map<String, dynamic>> listenTraffic(
    void Function(Map<String, dynamic>) onData,
  ) {
    _trafficSubscription?.cancel();
    _trafficSubscription = trafficStream.listen(
      onData,
      onError: (e) =>
          debugPrint('[WireguardVpnService] traffic stream error: $e'),
    );
    return _trafficSubscription!;
  }

  Future<void> connect({
    required String serverAddress,
    required String wgQuickConfig,
    required String providerBundleIdentifier,
  }) async {
    await _wireguard.startVpn(
      serverAddress: serverAddress,
      wgQuickConfig: wgQuickConfig,
      providerBundleIdentifier: providerBundleIdentifier,
    );
  }

  Future<void> connectWithDefaultConfig() async {
    await ensureVpnPermission();
    await connect(
      serverAddress: AppConstants.wgServerEndpoint,
      wgQuickConfig: AppConstants.wgDefaultConfig,
      providerBundleIdentifier: AppConstants.wgProviderBundleIdentifier,
    );
  }

  Future<void> disconnect() => _wireguard.stopVpn();

  Future<VpnStage> currentStage() async {
    try {
      return await _wireguard.stage();
    } on MissingPluginException {
      return VpnStage.disconnected;
    }
  }

  Future<void> dispose() async {
    await _trafficSubscription?.cancel();
    await _stageSubscription?.cancel();
    await _stageController.close();
  }
}
