import 'dart:io' show Platform;
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../constants/app_theme.dart';
import '../../providers/auth_provider.dart';
import '../../providers/vpn_provider.dart';
import '../../models/server_model.dart';
import '../../widgets/connect_button.dart';
import '../../widgets/speed_meter.dart';

class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key});

  String get _platform {
    if (kIsWeb) return 'browser';
    if (Platform.isAndroid) return 'android';
    if (Platform.isIOS) return 'ios';
    if (Platform.isWindows) return 'windows';
    if (Platform.isMacOS) return 'macos';
    return 'linux';
  }

  @override
  Widget build(BuildContext context) {
    final vpn = context.watch<VpnProvider>();
    final auth = context.watch<AuthProvider>();

    return Scaffold(
      appBar: AppBar(
        title: const Text('IONE VPN',
            style: TextStyle(fontWeight: FontWeight.w700, letterSpacing: 0.5)),
        actions: [
          IconButton(
            icon: const Icon(Icons.settings_outlined),
            onPressed: () => Navigator.pushNamed(context, '/settings'),
          ),
        ],
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20),
          child: Column(
            children: [
              const SizedBox(height: 16),

              // ── Server selector card ─────────────────────────────────────
              _ServerCard(server: vpn.selectedServer),

              const SizedBox(height: 32),

              _StatusText(status: vpn.status),
              const SizedBox(height: 10),

              if (vpn.status == VpnStatus.connecting ||
                  vpn.status == VpnStatus.disconnecting) ...[
                const SizedBox(
                  width: 180,
                  child: LinearProgressIndicator(minHeight: 4),
                ),
                const SizedBox(height: 14),
              ],

              // ── Connect button ───────────────────────────────────────────
              ConnectButton(
                status: vpn.status,
                onPressed: vpn.isBusy
                    ? null
                    : () async {
                        if (vpn.isConnected) {
                          await vpn.disconnect();
                        } else {
                          await vpn.connect(
                            platform: _platform,
                            deviceName: '${auth.user?.email ?? 'user'}-$_platform',
                          );
                        }
                      },
              ),

              if (vpn.errorMessage != null) ...[
                const SizedBox(height: 16),
                Text(vpn.errorMessage!,
                    style: const TextStyle(color: AppTheme.errorRed),
                    textAlign: TextAlign.center),
              ],

              if (kIsWeb && vpn.hasWebConfig) ...[
                const SizedBox(height: 18),
                _WebConfigCard(vpn: vpn),
              ],

              const SizedBox(height: 32),

              // ── Stats ────────────────────────────────────────────────────
              if (vpn.isConnected) ...[
                SpeedMeter(stats: vpn.stats),
                const SizedBox(height: 20),
                _StatsRow(vpn: vpn),
              ] else ...[
                _IdleInfo(user: auth.user?.email),
              ],

              const Spacer(),

              // ── Bottom actions ───────────────────────────────────────────
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      icon: const Icon(Icons.dns_outlined, size: 18),
                      label: const Text('Servers'),
                      onPressed: () =>
                          Navigator.pushNamed(context, '/servers'),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: OutlinedButton.icon(
                      icon: const Icon(Icons.star_outline, size: 18),
                      label: const Text('Upgrade'),
                      onPressed: () =>
                          Navigator.pushNamed(context, '/subscription'),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 16),
            ],
          ),
        ),
      ),
    );
  }
}

class _StatusText extends StatelessWidget {
  const _StatusText({required this.status});

  final VpnStatus status;

  String get _label {
    return switch (status) {
      VpnStatus.connected => 'Status: Connected',
      VpnStatus.connecting => 'Status: Connecting...',
      VpnStatus.disconnecting => 'Status: Disconnecting...',
      VpnStatus.error => 'Status: Connection Error',
      _ => 'Status: Disconnected',
    };
  }

  Color _color(BuildContext context) {
    return switch (status) {
      VpnStatus.connected => AppTheme.successGreen,
      VpnStatus.connecting || VpnStatus.disconnecting => AppTheme.warningAmber,
      VpnStatus.error => AppTheme.errorRed,
      _ => Theme.of(context).textTheme.bodyMedium?.color ?? Colors.grey,
    };
  }

  @override
  Widget build(BuildContext context) {
    return Text(
      _label,
      style: Theme.of(context).textTheme.titleMedium?.copyWith(
            fontWeight: FontWeight.w600,
            color: _color(context),
          ),
      textAlign: TextAlign.center,
    );
  }
}

// ─── Server card ──────────────────────────────────────────────────────────────
class _ServerCard extends StatelessWidget {
  const _ServerCard({required this.server});
  final ServerModel? server;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () => Navigator.pushNamed(context, '/servers'),
      child: Card(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          child: Row(
            children: [
              Text(server?.flag ?? '🌐', style: const TextStyle(fontSize: 28)),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      server?.name ?? 'Auto-select',
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                    if (server != null)
                      Text(
                        '${server!.pingLabel}  •  Load ${server!.loadLabel}',
                        style: Theme.of(context).textTheme.bodyMedium,
                      ),
                  ],
                ),
              ),
              const Icon(Icons.chevron_right_rounded),
            ],
          ),
        ),
      ),
    );
  }
}

// ─── Stats row ────────────────────────────────────────────────────────────────
class _StatsRow extends StatelessWidget {
  const _StatsRow({required this.vpn});
  final VpnProvider vpn;

  @override
  Widget build(BuildContext context) {
    final s = vpn.stats;
    return Row(
      children: [
        _Stat(label: 'Duration', value: s.sessionDurationLabel),
        _Stat(label: 'Downloaded', value: s.totalDownloadLabel),
        _Stat(label: 'Uploaded', value: s.totalUploadLabel),
      ],
    );
  }
}

class _Stat extends StatelessWidget {
  const _Stat({required this.label, required this.value});
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Column(
        children: [
          Text(value,
              style: const TextStyle(
                  fontSize: 15, fontWeight: FontWeight.w600)),
          const SizedBox(height: 2),
          Text(label,
              style: Theme.of(context).textTheme.bodyMedium,
              textAlign: TextAlign.center),
        ],
      ),
    );
  }
}

// ─── Idle info ────────────────────────────────────────────────────────────────
class _IdleInfo extends StatelessWidget {
  const _IdleInfo({required this.user});
  final String? user;

  @override
  Widget build(BuildContext context) {
    final subtitle = kIsWeb
        ? 'Tap connect to generate WireGuard config for this browser session'
        : (user != null ? 'Tap connect to secure $user' : 'Tap connect to start');

    return Column(
      children: [
        Icon(Icons.lock_open_outlined,
          size: 48, color: AppTheme.errorRed.withValues(alpha: 0.7)),
        const SizedBox(height: 12),
        Text('Not protected',
            style: Theme.of(context)
                .textTheme
                .titleLarge
                ?.copyWith(color: AppTheme.errorRed)),
        const SizedBox(height: 6),
        Text(
          subtitle,
          style: Theme.of(context).textTheme.bodyMedium,
          textAlign: TextAlign.center,
        ),
      ],
    );
  }
}

class _WebConfigCard extends StatelessWidget {
  const _WebConfigCard({required this.vpn});

  final VpnProvider vpn;

  @override
  Widget build(BuildContext context) {
    final endpoint = vpn.webEndpoint ?? 'Unknown endpoint';
    final config = vpn.webGeneratedConfig ?? '';

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Web Mode: Config Ready',
              style: Theme.of(context)
                  .textTheme
                  .titleMedium
                  ?.copyWith(fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 8),
            Text(
              'Browsers cannot create system VPN tunnels. Use this config in the WireGuard desktop/mobile app.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 8),
            Text('Endpoint: $endpoint', style: Theme.of(context).textTheme.bodySmall),
            const SizedBox(height: 10),
            SelectableText(
              config,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    fontFamily: 'monospace',
                    height: 1.35,
                  ),
            ),
            const SizedBox(height: 10),
            Align(
              alignment: Alignment.centerRight,
              child: OutlinedButton.icon(
                onPressed: () async {
                  await Clipboard.setData(ClipboardData(text: config));
                  if (context.mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('WireGuard config copied')),
                    );
                  }
                },
                icon: const Icon(Icons.copy_rounded, size: 16),
                label: const Text('Copy Config'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
