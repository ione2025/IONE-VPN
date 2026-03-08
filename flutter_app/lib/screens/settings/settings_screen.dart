import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../providers/auth_provider.dart';
import '../../providers/theme_provider.dart';
import '../../constants/app_theme.dart';

class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final auth = context.watch<AuthProvider>();
    final themeProvider = context.watch<ThemeProvider>();

    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListView(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        children: [
          // ── Account ────────────────────────────────────────────────────
          _Section(title: 'Account', children: [
            _InfoTile(label: 'Email', value: auth.user?.email ?? '—'),
            _InfoTile(
              label: 'Subscription',
              value: auth.user?.subscription.tier.toUpperCase() ?? 'FREE',
            ),
            ListTile(
              leading: const Icon(Icons.star_outline),
              title: const Text('Upgrade Plan'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => Navigator.pushNamed(context, '/subscription'),
            ),
          ]),

          // ── VPN ────────────────────────────────────────────────────────
          _Section(title: 'VPN', children: [
            _ProtocolTile(),
            _KillSwitchTile(),
            _DnsTile(),
          ]),

          // ── Appearance ─────────────────────────────────────────────────
          _Section(title: 'Appearance', children: [
            SwitchListTile(
              secondary: const Icon(Icons.dark_mode_outlined),
              title: const Text('Dark Mode'),
              value: themeProvider.isDark,
              onChanged: (_) => themeProvider.toggle(),
            ),
          ]),

          // ── About ──────────────────────────────────────────────────────
          _Section(title: 'About', children: [
            const _InfoTile(label: 'App', value: 'IONE VPN'),
            const _InfoTile(label: 'Version', value: '1.0.0'),
            const _InfoTile(label: 'Privacy Policy', value: 'Zero-log policy'),
          ]),

          // ── Logout ─────────────────────────────────────────────────────
          const SizedBox(height: 8),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: ElevatedButton(
              style: ElevatedButton.styleFrom(
                  backgroundColor: AppTheme.errorRed),
              onPressed: () async {
                final confirmed = await showDialog<bool>(
                  context: context,
                  builder: (ctx) => AlertDialog(
                    title: const Text('Sign out'),
                    content:
                        const Text('Are you sure you want to sign out?'),
                    actions: [
                      TextButton(
                          onPressed: () => Navigator.pop(ctx, false),
                          child: const Text('Cancel')),
                      TextButton(
                          onPressed: () => Navigator.pop(ctx, true),
                          child: const Text('Sign out')),
                    ],
                  ),
                );
                if (confirmed == true && context.mounted) {
                  await context.read<AuthProvider>().logout();
                  Navigator.pushNamedAndRemoveUntil(
                      context, '/login', (_) => false);
                }
              },
              child: const Text('Sign Out'),
            ),
          ),
          const SizedBox(height: 24),
        ],
      ),
    );
  }
}

// ─── Protocol tile ────────────────────────────────────────────────────────────
class _ProtocolTile extends StatefulWidget {
  const _ProtocolTile({super.key});

  @override
  State<_ProtocolTile> createState() => _ProtocolTileState();
}

class _ProtocolTileState extends State<_ProtocolTile> {
  String _protocol = 'Auto (WireGuard)';

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: const Icon(Icons.compare_arrows_outlined),
      title: const Text('Protocol'),
      trailing: DropdownButton<String>(
        value: _protocol,
        underline: const SizedBox(),
        items: const [
          DropdownMenuItem(value: 'Auto (WireGuard)', child: Text('Auto')),
          DropdownMenuItem(value: 'wireguard', child: Text('WireGuard')),
          DropdownMenuItem(value: 'openvpn', child: Text('OpenVPN')),
        ],
        onChanged: (v) => setState(() => _protocol = v!),
      ),
    );
  }
}

// ─── Kill switch tile ─────────────────────────────────────────────────────────
class _KillSwitchTile extends StatefulWidget {
  const _KillSwitchTile({super.key});

  @override
  State<_KillSwitchTile> createState() => _KillSwitchTileState();
}

class _KillSwitchTileState extends State<_KillSwitchTile> {
  bool _enabled = true;

  @override
  Widget build(BuildContext context) {
    return SwitchListTile(
      secondary: const Icon(Icons.block_outlined),
      title: const Text('Kill Switch'),
      subtitle: const Text('Block internet if VPN drops'),
      value: _enabled,
      onChanged: (v) => setState(() => _enabled = v),
    );
  }
}

// ─── DNS tile ─────────────────────────────────────────────────────────────────
class _DnsTile extends StatefulWidget {
  const _DnsTile({super.key});

  @override
  State<_DnsTile> createState() => _DnsTileState();
}

class _DnsTileState extends State<_DnsTile> {
  String _dns = 'Automatic (1.1.1.1)';

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: const Icon(Icons.dns_outlined),
      title: const Text('DNS'),
      trailing: DropdownButton<String>(
        value: _dns,
        underline: const SizedBox(),
        items: const [
          DropdownMenuItem(
              value: 'Automatic (1.1.1.1)', child: Text('Automatic')),
          DropdownMenuItem(
              value: 'AdBlock (1.1.1.2)', child: Text('Ad-block DNS')),
          DropdownMenuItem(value: 'Custom', child: Text('Custom')),
        ],
        onChanged: (v) => setState(() => _dns = v!),
      ),
    );
  }
}

// ─── Helpers ──────────────────────────────────────────────────────────────────
class _Section extends StatelessWidget {
  const _Section({required this.title, required this.children});
  final String title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(4, 20, 0, 8),
          child: Text(
            title.toUpperCase(),
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 1,
                ),
          ),
        ),
        Card(
          margin: EdgeInsets.zero,
          child: Column(children: children),
        ),
      ],
    );
  }
}

class _InfoTile extends StatelessWidget {
  const _InfoTile({required this.label, required this.value});
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      title: Text(label),
      trailing: Text(value,
          style: Theme.of(context).textTheme.bodyMedium),
    );
  }
}
