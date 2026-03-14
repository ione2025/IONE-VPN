import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../services/api_service.dart';

class AdminPanelScreen extends StatefulWidget {
  const AdminPanelScreen({super.key});

  @override
  State<AdminPanelScreen> createState() => _AdminPanelScreenState();
}

class _AdminPanelScreenState extends State<AdminPanelScreen> {
  bool _loading = true;
  String? _error;
  Map<String, dynamic>? _dashboard;
  List<Map<String, dynamic>> _users = const [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });

    try {
      final api = context.read<ApiService>();
      final results = await Future.wait([
        api.getAdminDashboard(),
        api.getAdminUsers(includeDevices: true),
      ]);

      final dashboard = results[0];
      final usersPayload = results[1];
      final usersRaw = usersPayload['users'] as List<dynamic>? ?? const [];

      setState(() {
        _dashboard = dashboard;
        _users = usersRaw
            .whereType<Map>()
            .map((u) => Map<String, dynamic>.from(u))
            .toList();
        _loading = false;
      });
    } catch (e) {
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  Future<void> _changeTier(String userId, String email, String tier) async {
    final api = context.read<ApiService>();
    try {
      await api.updateUserSubscription(userId: userId, tier: tier);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Updated $email to $tier tier')),
      );
      await _load();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Failed to update tier: $e')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Admin Panel'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: _loading ? null : _load,
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Text(
                      _error!,
                      textAlign: TextAlign.center,
                    ),
                  ),
                )
              : RefreshIndicator(
                  onRefresh: _load,
                  child: ListView(
                    padding: const EdgeInsets.all(16),
                    children: [
                      _DashboardCard(data: _dashboard ?? const {}),
                      const SizedBox(height: 16),
                      Text(
                        'Users and Devices',
                        style: Theme.of(context).textTheme.titleLarge,
                      ),
                      const SizedBox(height: 10),
                      ..._users.map((u) => _UserCard(
                            user: u,
                            onChangeTier: (tier) => _changeTier(
                              (u['id'] ?? '').toString(),
                              (u['email'] ?? '').toString(),
                              tier,
                            ),
                          )),
                    ],
                  ),
                ),
    );
  }
}

class _DashboardCard extends StatelessWidget {
  const _DashboardCard({required this.data});

  final Map<String, dynamic> data;

  @override
  Widget build(BuildContext context) {
    Widget stat(String label, dynamic value) {
      return Expanded(
        child: Column(
          children: [
            Text(
              '$value',
              style: Theme.of(context)
                  .textTheme
                  .headlineSmall
                  ?.copyWith(fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 4),
            Text(label, textAlign: TextAlign.center),
          ],
        ),
      );
    }

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          children: [
            Row(
              children: [
                stat('Total Users', data['totalUsers'] ?? 0),
                stat('Free', data['freeUsers'] ?? 0),
                stat('Premium', data['premiumUsers'] ?? 0),
                stat('Ultra', data['ultraUsers'] ?? 0),
              ],
            ),
            const SizedBox(height: 12),
            Text('Active Devices: ${data['activeDevices'] ?? 0}'),
          ],
        ),
      ),
    );
  }
}

class _UserCard extends StatelessWidget {
  const _UserCard({
    required this.user,
    required this.onChangeTier,
  });

  final Map<String, dynamic> user;
  final void Function(String tier) onChangeTier;

  @override
  Widget build(BuildContext context) {
    final subscription = (user['subscription'] as Map?)?.cast<String, dynamic>() ?? const {};
    final tier = (subscription['tier'] ?? 'free').toString();
    final maxDevices = (subscription['maxDevices'] ?? 1).toString();
    final devicesRaw = user['devices'] as List<dynamic>? ?? const [];

    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              (user['email'] ?? 'Unknown').toString(),
              style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 6),
            Text('Tier: $tier | Devices: ${user['activeDeviceCount'] ?? 0}/$maxDevices'),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                OutlinedButton(
                  onPressed: tier == 'free' ? null : () => onChangeTier('free'),
                  child: const Text('Set Free'),
                ),
                OutlinedButton(
                  onPressed: tier == 'premium' ? null : () => onChangeTier('premium'),
                  child: const Text('Set Premium'),
                ),
                OutlinedButton(
                  onPressed: tier == 'ultra' ? null : () => onChangeTier('ultra'),
                  child: const Text('Set Ultra'),
                ),
              ],
            ),
            const SizedBox(height: 8),
            if (devicesRaw.isEmpty)
              const Text('No active devices')
            else
              ...devicesRaw.whereType<Map>().map((d) {
                final m = d.cast<String, dynamic>();
                return Padding(
                  padding: const EdgeInsets.only(bottom: 4),
                  child: Text(
                    '- ${(m['name'] ?? 'Device')} | ${(m['platform'] ?? 'unknown')} | ${(m['protocol'] ?? 'wireguard')} | ${(m['assignedIp'] ?? '-')}',
                  ),
                );
              }),
          ],
        ),
      ),
    );
  }
}
