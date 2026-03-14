import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../services/api_service.dart';

// ─── Colour palette ──────────────────────────────────────────────────────────
const _kFree = Color(0xFF6B7280);
const _kPremium = Color(0xFF3B82F6);
const _kUltra = Color(0xFFF59E0B);
const _kGreen = Color(0xFF10B981);
const _kYellow = Color(0xFFF59E0B);
const _kRed = Color(0xFFEF4444);

// ─── Entry point ─────────────────────────────────────────────────────────────

class AdminPanelScreen extends StatefulWidget {
  const AdminPanelScreen({super.key});

  @override
  State<AdminPanelScreen> createState() => _AdminPanelScreenState();
}

class _AdminPanelScreenState extends State<AdminPanelScreen>
    with SingleTickerProviderStateMixin {
  late final TabController _tabs;

  // Shared data
  Map<String, dynamic> _dashboard = {};
  List<Map<String, dynamic>> _users = [];
  List<Map<String, dynamic>> _peers = [];

  bool _loadingDashboard = true;
  bool _loadingUsers = true;
  bool _loadingPeers = false;

  String? _dashboardError;
  String? _usersError;
  String? _peersError;

  String _userSearch = '';
  String _userTierFilter = 'all';

  Timer? _peerRefreshTimer;

  @override
  void initState() {
    super.initState();
    _tabs = TabController(length: 4, vsync: this);
    _tabs.addListener(() {
      // Start/stop auto-refresh on the peers tab
      if (_tabs.index == 2 && !_tabs.indexIsChanging) {
        _loadPeers();
        _peerRefreshTimer ??= Timer.periodic(
          const Duration(seconds: 10),
          (_) => _loadPeers(),
        );
      } else if (_tabs.index != 2) {
        _peerRefreshTimer?.cancel();
        _peerRefreshTimer = null;
      }
    });
    _loadDashboard();
    _loadUsers();
  }

  @override
  void dispose() {
    _tabs.dispose();
    _peerRefreshTimer?.cancel();
    super.dispose();
  }

  // ─── Data loading ─────────────────────────────────────────────────────────

  Future<void> _loadDashboard() async {
    setState(() {
      _loadingDashboard = true;
      _dashboardError = null;
    });
    try {
      final data = await context.read<ApiService>().getAdminDashboard();
      if (mounted) setState(() => _dashboard = data);
    } catch (e) {
      if (mounted) setState(() => _dashboardError = e.toString());
    } finally {
      if (mounted) setState(() => _loadingDashboard = false);
    }
  }

  Future<void> _loadUsers() async {
    setState(() {
      _loadingUsers = true;
      _usersError = null;
    });
    try {
      final payload = await context
          .read<ApiService>()
          .getAdminUsers(includeDevices: true, limit: 200);
      final raw = (payload['users'] as List?)?.whereType<Map>() ?? [];
      if (mounted) {
        setState(() => _users =
            raw.map((u) => Map<String, dynamic>.from(u)).toList());
      }
    } catch (e) {
      if (mounted) setState(() => _usersError = e.toString());
    } finally {
      if (mounted) setState(() => _loadingUsers = false);
    }
  }

  Future<void> _loadPeers() async {
    setState(() {
      _loadingPeers = true;
      _peersError = null;
    });
    try {
      final raw = await context.read<ApiService>().getAdminWgPeers();
      if (mounted) {
        setState(() =>
            _peers = raw.whereType<Map>().map((p) => Map<String, dynamic>.from(p)).toList());
      }
    } catch (e) {
      if (mounted) setState(() => _peersError = e.toString());
    } finally {
      if (mounted) setState(() => _loadingPeers = false);
    }
  }

  // ─── User actions ─────────────────────────────────────────────────────────

  Future<void> _setTier(String userId, String email, String tier) async {
    try {
      await context
          .read<ApiService>()
          .updateUserSubscription(userId: userId, tier: tier);
      _snack('$email → $tier', success: true);
      _loadUsers();
      _loadDashboard();
    } catch (e) {
      _snack('Failed: $e');
    }
  }

  Future<void> _toggleStatus(String userId, String email, bool isActive) async {
    final action = isActive ? 'Suspend' : 'Activate';
    final confirmed = await _confirm('$action $email?',
        '$action this user\'s account?');
    if (!confirmed) return;
    try {
      await context.read<ApiService>().toggleUserStatus(userId);
      _snack('$email ${isActive ? 'suspended' : 'activated'}', success: true);
      _loadUsers();
    } catch (e) {
      _snack('Failed: $e');
    }
  }

  Future<void> _revokeDevices(String userId, String email) async {
    final confirmed =
        await _confirm('Revoke all devices?', 'This will disconnect $email from all active sessions.');
    if (!confirmed) return;
    try {
      await context.read<ApiService>().revokeAllUserDevices(userId);
      _snack('All devices revoked for $email', success: true);
      _loadUsers();
    } catch (e) {
      _snack('Failed: $e');
    }
  }

  Future<void> _deleteUser(String userId, String email) async {
    final confirmed =
        await _confirm('Delete $email?', 'This will permanently delete the user account and all devices. This cannot be undone.');
    if (!confirmed) return;
    try {
      await context.read<ApiService>().deleteUser(userId);
      _snack('User $email deleted', success: true);
      _loadUsers();
      _loadDashboard();
    } catch (e) {
      _snack('Failed: $e');
    }
  }

  // ─── Helpers ──────────────────────────────────────────────────────────────

  void _snack(String msg, {bool success = false}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(msg),
      backgroundColor: success ? _kGreen : _kRed,
      behavior: SnackBarBehavior.floating,
    ));
  }

  Future<bool> _confirm(String title, String body) async {
    return await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: Text(title),
            content: Text(body),
            actions: [
              TextButton(
                  onPressed: () => Navigator.pop(ctx, false),
                  child: const Text('Cancel')),
              FilledButton(
                  onPressed: () => Navigator.pop(ctx, true),
                  child: const Text('Confirm')),
            ],
          ),
        ) ??
        false;
  }

  List<Map<String, dynamic>> get _filteredUsers {
    return _users.where((u) {
      final email = (u['email'] ?? '').toString().toLowerCase();
      final tier = ((u['subscription'] as Map?)?['tier'] ?? 'free').toString();
      final matchSearch = _userSearch.isEmpty ||
          email.contains(_userSearch.toLowerCase());
      final matchTier =
          _userTierFilter == 'all' || tier == _userTierFilter;
      return matchSearch && matchTier;
    }).toList();
  }

  // ─── Build ────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Admin Panel',
            style: TextStyle(fontWeight: FontWeight.w700)),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh_rounded),
            tooltip: 'Refresh',
            onPressed: () {
              _loadDashboard();
              _loadUsers();
              if (_tabs.index == 2) _loadPeers();
            },
          ),
        ],
        bottom: TabBar(
          controller: _tabs,
          isScrollable: true,
          tabAlignment: TabAlignment.start,
          tabs: const [
            Tab(icon: Icon(Icons.dashboard_outlined), text: 'Overview'),
            Tab(icon: Icon(Icons.people_outline), text: 'Users'),
            Tab(icon: Icon(Icons.device_hub_outlined), text: 'Live Peers'),
            Tab(icon: Icon(Icons.dns_outlined), text: 'Servers'),
          ],
        ),
      ),
      body: TabBarView(
        controller: _tabs,
        children: [
          _OverviewTab(
            dashboard: _dashboard,
            loading: _loadingDashboard,
            error: _dashboardError,
            onRefresh: _loadDashboard,
          ),
          _UsersTab(
            users: _filteredUsers,
            loading: _loadingUsers,
            error: _usersError,
            search: _userSearch,
            tierFilter: _userTierFilter,
            onSearchChanged: (v) => setState(() => _userSearch = v),
            onTierFilterChanged: (v) =>
                setState(() => _userTierFilter = v ?? 'all'),
            onSetTier: _setTier,
            onToggleStatus: _toggleStatus,
            onRevokeDevices: _revokeDevices,
            onDeleteUser: _deleteUser,
            onRefresh: _loadUsers,
          ),
          _PeersTab(
            peers: _peers,
            loading: _loadingPeers,
            error: _peersError,
            onRefresh: _loadPeers,
          ),
          _ServersTab(
            dashboard: _dashboard,
            loading: _loadingDashboard,
            error: _dashboardError,
            onRefresh: _loadDashboard,
          ),
        ],
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════════
// TAB 1 – OVERVIEW
// ═══════════════════════════════════════════════════════════════════════════

class _OverviewTab extends StatelessWidget {
  const _OverviewTab({
    required this.dashboard,
    required this.loading,
    required this.error,
    required this.onRefresh,
  });

  final Map<String, dynamic> dashboard;
  final bool loading;
  final String? error;
  final VoidCallback onRefresh;

  @override
  Widget build(BuildContext context) {
    if (loading) return const Center(child: CircularProgressIndicator());
    if (error != null) return _ErrorState(error: error!, onRetry: onRefresh);

    final totalUsers = dashboard['totalUsers'] ?? 0;
    final freeUsers = dashboard['freeUsers'] ?? 0;
    final premiumUsers = dashboard['premiumUsers'] ?? 0;
    final ultraUsers = dashboard['ultraUsers'] ?? 0;
    final activeDevices = dashboard['activeDevices'] ?? 0;

    return RefreshIndicator(
      onRefresh: () async => onRefresh(),
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          // ── User stats ─────────────────────────────────────────────────
          Text('User Statistics',
              style: Theme.of(context)
                  .textTheme
                  .titleMedium
                  ?.copyWith(fontWeight: FontWeight.w700)),
          const SizedBox(height: 12),
          Row(children: [
            _StatCard('Total Users', '$totalUsers', Icons.group_outlined,
                color: Colors.blueAccent),
            const SizedBox(width: 12),
            _StatCard('Active Devices', '$activeDevices',
                Icons.devices_outlined,
                color: _kGreen),
          ]),
          const SizedBox(height: 12),
          Row(children: [
            _StatCard('Free', '$freeUsers', Icons.person_outline,
                color: _kFree),
            const SizedBox(width: 12),
            _StatCard('Premium', '$premiumUsers', Icons.workspace_premium_outlined,
                color: _kPremium),
            const SizedBox(width: 12),
            _StatCard('Ultra', '$ultraUsers', Icons.bolt_outlined,
                color: _kUltra),
          ]),
          const SizedBox(height: 24),

          // ── Plan distribution ──────────────────────────────────────────
          Text('Plan Distribution',
              style: Theme.of(context)
                  .textTheme
                  .titleMedium
                  ?.copyWith(fontWeight: FontWeight.w700)),
          const SizedBox(height: 12),
          if (totalUsers > 0)
            _PlanDistributionBar(
              free: freeUsers,
              premium: premiumUsers,
              ultra: ultraUsers,
              total: totalUsers,
            ),
          const SizedBox(height: 24),

          // ── Server health ──────────────────────────────────────────────
          Text('Server Health',
              style: Theme.of(context)
                  .textTheme
                  .titleMedium
                  ?.copyWith(fontWeight: FontWeight.w700)),
          const SizedBox(height: 12),
          _ServerHealthSummary(serverStats: dashboard['serverStats']),
        ],
      ),
    );
  }
}

class _StatCard extends StatelessWidget {
  const _StatCard(this.label, this.value, this.icon, {required this.color});

  final String label;
  final String value;
  final IconData icon;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Card(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(icon, color: color, size: 22),
              const SizedBox(height: 10),
              Text(value,
                  style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                      fontWeight: FontWeight.w800, color: color)),
              const SizedBox(height: 2),
              Text(label,
                  style: Theme.of(context)
                      .textTheme
                      .bodySmall
                      ?.copyWith(color: Colors.grey)),
            ],
          ),
        ),
      ),
    );
  }
}

class _PlanDistributionBar extends StatelessWidget {
  const _PlanDistributionBar({
    required this.free,
    required this.premium,
    required this.ultra,
    required this.total,
  });

  final int free;
  final int premium;
  final int ultra;
  final int total;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(6),
              child: Row(
                children: [
                  _Bar(flex: free, color: _kFree),
                  _Bar(flex: premium, color: _kPremium),
                  _Bar(flex: ultra, color: _kUltra),
                ],
              ),
            ),
            const SizedBox(height: 10),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceAround,
              children: [
                _Legend('Free', free, _kFree),
                _Legend('Premium', premium, _kPremium),
                _Legend('Ultra', ultra, _kUltra),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _Bar({required int flex, required Color color}) {
    if (flex == 0) return const SizedBox.shrink();
    return Expanded(flex: flex, child: Container(height: 16, color: color));
  }

  Widget _Legend(String label, int count, Color color) {
    return Row(children: [
      Container(
          width: 10, height: 10, decoration: BoxDecoration(color: color, shape: BoxShape.circle)),
      const SizedBox(width: 6),
      Text('$label ($count)'),
    ]);
  }
}

class _ServerHealthSummary extends StatelessWidget {
  const _ServerHealthSummary({required this.serverStats});

  final dynamic serverStats;

  @override
  Widget build(BuildContext context) {
    final servers = serverStats is List
        ? (serverStats as List)
            .whereType<Map>()
            .map((s) => Map<String, dynamic>.from(s))
            .toList()
        : <Map<String, dynamic>>[];

    if (servers.isEmpty) {
      return const Card(
        child: Padding(
          padding: EdgeInsets.all(14),
          child: Text('No server data available'),
        ),
      );
    }

    return Column(
      children: servers.map((s) => _ServerHealthCard(server: s)).toList(),
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════════
// TAB 2 – USERS
// ═══════════════════════════════════════════════════════════════════════════

class _UsersTab extends StatelessWidget {
  const _UsersTab({
    required this.users,
    required this.loading,
    required this.error,
    required this.search,
    required this.tierFilter,
    required this.onSearchChanged,
    required this.onTierFilterChanged,
    required this.onSetTier,
    required this.onToggleStatus,
    required this.onRevokeDevices,
    required this.onDeleteUser,
    required this.onRefresh,
  });

  final List<Map<String, dynamic>> users;
  final bool loading;
  final String? error;
  final String search;
  final String tierFilter;
  final ValueChanged<String> onSearchChanged;
  final ValueChanged<String?> onTierFilterChanged;
  final Future<void> Function(String id, String email, String tier) onSetTier;
  final Future<void> Function(String id, String email, bool isActive) onToggleStatus;
  final Future<void> Function(String id, String email) onRevokeDevices;
  final Future<void> Function(String id, String email) onDeleteUser;
  final Future<void> Function() onRefresh;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        // ── Search + filter bar ──────────────────────────────────────────
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 12, 12, 6),
          child: Row(
            children: [
              Expanded(
                child: TextField(
                  decoration: const InputDecoration(
                    hintText: 'Search by email…',
                    prefixIcon: Icon(Icons.search, size: 20),
                    isDense: true,
                    border: OutlineInputBorder(),
                    contentPadding: EdgeInsets.symmetric(vertical: 10),
                  ),
                  onChanged: onSearchChanged,
                ),
              ),
              const SizedBox(width: 10),
              DropdownButton<String>(
                value: tierFilter,
                underline: const SizedBox.shrink(),
                isDense: true,
                items: const [
                  DropdownMenuItem(value: 'all', child: Text('All tiers')),
                  DropdownMenuItem(value: 'free', child: Text('Free')),
                  DropdownMenuItem(value: 'premium', child: Text('Premium')),
                  DropdownMenuItem(value: 'ultra', child: Text('Ultra')),
                ],
                onChanged: onTierFilterChanged,
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Align(
            alignment: Alignment.centerLeft,
            child: Text('${users.length} user(s)',
                style: Theme.of(context).textTheme.bodySmall),
          ),
        ),
        const SizedBox(height: 6),

        // ── List ─────────────────────────────────────────────────────────
        Expanded(
          child: loading
              ? const Center(child: CircularProgressIndicator())
              : error != null
                  ? _ErrorState(error: error!, onRetry: onRefresh)
                  : users.isEmpty
                      ? const Center(child: Text('No users found'))
                      : RefreshIndicator(
                          onRefresh: onRefresh,
                          child: ListView.separated(
                            padding: const EdgeInsets.fromLTRB(12, 0, 12, 16),
                            itemCount: users.length,
                            separatorBuilder: (_, __) =>
                                const SizedBox(height: 8),
                            itemBuilder: (context, i) => _UserTile(
                              user: users[i],
                              onSetTier: (tier) => onSetTier(
                                _id(users[i]),
                                (users[i]['email'] ?? '').toString(),
                                tier,
                              ),
                              onToggleStatus: () => onToggleStatus(
                                _id(users[i]),
                                (users[i]['email'] ?? '').toString(),
                                users[i]['isActive'] == true,
                              ),
                              onRevokeDevices: () => onRevokeDevices(
                                _id(users[i]),
                                (users[i]['email'] ?? '').toString(),
                              ),
                              onDeleteUser: () => onDeleteUser(
                                _id(users[i]),
                                (users[i]['email'] ?? '').toString(),
                              ),
                            ),
                          ),
                        ),
        ),
      ],
    );
  }

  String _id(Map<String, dynamic> u) =>
      (u['id'] ?? u['_id'] ?? '').toString();
}

class _UserTile extends StatelessWidget {
  const _UserTile({
    required this.user,
    required this.onSetTier,
    required this.onToggleStatus,
    required this.onRevokeDevices,
    required this.onDeleteUser,
  });

  final Map<String, dynamic> user;
  final void Function(String tier) onSetTier;
  final VoidCallback onToggleStatus;
  final VoidCallback onRevokeDevices;
  final VoidCallback onDeleteUser;

  @override
  Widget build(BuildContext context) {
    final sub = (user['subscription'] as Map?)?.cast<String, dynamic>() ?? {};
    final tier = (sub['tier'] ?? 'free').toString();
    final maxDevices = (sub['maxDevices'] ?? 1) as int? ?? 1;
    final activeCount = (user['activeDeviceCount'] ?? 0) as int? ?? 0;
    final isActive = user['isActive'] != false;
    final devices = (user['devices'] as List?)?.whereType<Map>().toList() ?? [];
    final email = (user['email'] ?? 'Unknown').toString();

    Color tierColor;
    if (tier == 'ultra') {
      tierColor = _kUltra;
    } else if (tier == 'premium') {
      tierColor = _kPremium;
    } else {
      tierColor = _kFree;
    }

    return Card(
      child: ExpansionTile(
        leading: CircleAvatar(
          backgroundColor: tierColor.withOpacity(0.15),
          child: Text(
            email.isNotEmpty ? email[0].toUpperCase() : '?',
            style: TextStyle(color: tierColor, fontWeight: FontWeight.w700),
          ),
        ),
        title: Text(
          email,
          style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14),
          overflow: TextOverflow.ellipsis,
        ),
        subtitle: Row(
          children: [
            _TierBadge(tier: tier),
            const SizedBox(width: 8),
            Icon(
              isActive ? Icons.circle : Icons.block_outlined,
              size: 12,
              color: isActive ? _kGreen : _kRed,
            ),
            const SizedBox(width: 4),
            Text(
              isActive ? 'Active' : 'Suspended',
              style: TextStyle(
                  fontSize: 11,
                  color: isActive ? _kGreen : _kRed),
            ),
            const SizedBox(width: 8),
            Icon(Icons.devices_outlined, size: 12, color: Colors.grey),
            const SizedBox(width: 4),
            Text('$activeCount/$maxDevices',
                style: const TextStyle(fontSize: 11, color: Colors.grey)),
          ],
        ),
        children: [
          Padding(
            padding:
                const EdgeInsets.fromLTRB(16, 0, 16, 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Devices list
                if (devices.isEmpty)
                  const Text('No active devices',
                      style: TextStyle(color: Colors.grey, fontSize: 13))
                else
                  ...devices.map((d) {
                    final m = d.cast<String, dynamic>();
                    return _DeviceRow(device: m);
                  }),

                const Divider(height: 20),

                // Actions
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    _TierButton('Free', 'free', tier, _kFree, onSetTier),
                    _TierButton('Premium', 'premium', tier, _kPremium, onSetTier),
                    _TierButton('Ultra', 'ultra', tier, _kUltra, onSetTier),
                    OutlinedButton.icon(
                      icon: Icon(
                        isActive ? Icons.block_outlined : Icons.check_circle_outline,
                        size: 16,
                      ),
                      label: Text(isActive ? 'Suspend' : 'Activate',
                          style: const TextStyle(fontSize: 13)),
                      style: OutlinedButton.styleFrom(
                          foregroundColor:
                              isActive ? _kRed : _kGreen),
                      onPressed: onToggleStatus,
                    ),
                    OutlinedButton.icon(
                      icon: const Icon(Icons.phonelink_erase_outlined, size: 16),
                      label: const Text('Revoke Devices',
                          style: TextStyle(fontSize: 13)),
                      style: OutlinedButton.styleFrom(foregroundColor: _kRed),
                      onPressed: onRevokeDevices,
                    ),
                    OutlinedButton.icon(
                      icon: const Icon(Icons.delete_forever_outlined, size: 16),
                      label: const Text('Delete User',
                          style: TextStyle(fontSize: 13)),
                      style: OutlinedButton.styleFrom(foregroundColor: _kRed),
                      onPressed: onDeleteUser,
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _TierButton(String label, String value, String current, Color color,
      void Function(String) onSetTier) {
    final isCurrent = current == value;
    return FilledButton(
      style: FilledButton.styleFrom(
        backgroundColor: isCurrent ? color : color.withOpacity(0.12),
        foregroundColor: isCurrent ? Colors.white : color,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        minimumSize: Size.zero,
        textStyle: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
      ),
      onPressed: isCurrent ? null : () => onSetTier(value),
      child: Text(label),
    );
  }
}

class _DeviceRow extends StatelessWidget {
  const _DeviceRow({required this.device});

  final Map<String, dynamic> device;

  @override
  Widget build(BuildContext context) {
    final name = (device['name'] ?? 'Device').toString();
    final platform = (device['platform'] ?? 'unknown').toString();
    final protocol = (device['protocol'] ?? 'wireguard').toString();
    final ip = (device['assignedIp'] ?? '—').toString();

    IconData platformIcon = Icons.device_unknown_outlined;
    if (platform == 'android') platformIcon = Icons.android;
    if (platform == 'ios') platformIcon = Icons.apple;
    if (platform == 'windows') platformIcon = Icons.laptop_windows_outlined;
    if (platform == 'macos') platformIcon = Icons.laptop_mac_outlined;
    if (platform == 'browser') platformIcon = Icons.public_outlined;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Icon(platformIcon, size: 16, color: Colors.grey),
          const SizedBox(width: 8),
          Expanded(
              child: Text(name,
                  style: const TextStyle(fontSize: 13),
                  overflow: TextOverflow.ellipsis)),
          const SizedBox(width: 6),
          _ProtocolChip(protocol),
          const SizedBox(width: 6),
          Text(ip,
              style: const TextStyle(
                  fontSize: 12,
                  fontFamily: 'monospace',
                  color: Colors.grey)),
        ],
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════════
// TAB 3 – LIVE PEERS
// ═══════════════════════════════════════════════════════════════════════════

class _PeersTab extends StatelessWidget {
  const _PeersTab({
    required this.peers,
    required this.loading,
    required this.error,
    required this.onRefresh,
  });

  final List<Map<String, dynamic>> peers;
  final bool loading;
  final String? error;
  final Future<void> Function() onRefresh;

  @override
  Widget build(BuildContext context) {
    if (loading && peers.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }
    if (error != null && peers.isEmpty) {
      return _ErrorState(error: error!, onRetry: onRefresh);
    }

    return RefreshIndicator(
      onRefresh: onRefresh,
      child: ListView(
        padding: const EdgeInsets.all(12),
        children: [
          // Header
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: Row(
              children: [
                Text('${peers.length} active peer(s)',
                    style: Theme.of(context).textTheme.bodySmall),
                const SizedBox(width: 8),
                if (loading)
                  const SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(strokeWidth: 2)),
              ],
            ),
          ),

          if (peers.isEmpty)
            const Center(
                child: Padding(
              padding: EdgeInsets.all(32),
              child: Text('No active WireGuard peers',
                  style: TextStyle(color: Colors.grey)),
            ))
          else
            ...peers.map((p) => _Peer(peer: p)),
        ],
      ),
    );
  }
}

class _Peer extends StatelessWidget {
  const _Peer({required this.peer});

  final Map<String, dynamic> peer;

  @override
  Widget build(BuildContext context) {
    final pubKey = (peer['publicKey'] ?? '').toString();
    final allowedIps = (peer['allowedIps'] ?? '—').toString();
    final handshakeRaw = peer['lastHandshake'];
    final rxBytes = (peer['rxBytes'] ?? 0) as int? ?? 0;
    final txBytes = (peer['txBytes'] ?? 0) as int? ?? 0;

    DateTime? handshakeAt;
    String handshakeLabel = 'Never';
    if (handshakeRaw != null && handshakeRaw.toString().isNotEmpty) {
      handshakeAt = DateTime.tryParse(handshakeRaw.toString())?.toLocal();
      if (handshakeAt != null) {
        final diff = DateTime.now().difference(handshakeAt);
        if (diff.inSeconds < 60) {
          handshakeLabel = '${diff.inSeconds}s ago';
        } else if (diff.inMinutes < 60) {
          handshakeLabel = '${diff.inMinutes}m ago';
        } else {
          handshakeLabel = '${diff.inHours}h ago';
        }
      }
    }

    Color handshakeColor = _kRed;
    if (handshakeAt != null) {
      final ageMin = DateTime.now().difference(handshakeAt).inMinutes;
      if (ageMin < 3) {
        handshakeColor = _kGreen;
      } else if (ageMin < 10) {
        handshakeColor = _kYellow;
      }
    }

    final shortKey = pubKey.length > 12
        ? '${pubKey.substring(0, 6)}…${pubKey.substring(pubKey.length - 6)}'
        : pubKey;

    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.circle, size: 10, color: handshakeColor),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(allowedIps,
                      style: const TextStyle(
                          fontFamily: 'monospace',
                          fontWeight: FontWeight.w600,
                          fontSize: 14)),
                ),
                Text(shortKey,
                    style: const TextStyle(
                        fontSize: 11,
                        color: Colors.grey,
                        fontFamily: 'monospace')),
              ],
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Icon(Icons.handshake_outlined, size: 14, color: Colors.grey),
                const SizedBox(width: 4),
                Text('Handshake: ',
                    style: const TextStyle(fontSize: 12, color: Colors.grey)),
                Text(handshakeLabel,
                    style: TextStyle(
                        fontSize: 12,
                        color: handshakeColor,
                        fontWeight: FontWeight.w600)),
                const Spacer(),
                Icon(Icons.arrow_downward_rounded, size: 14, color: _kGreen),
                const SizedBox(width: 2),
                Text(_fmtBytes(rxBytes),
                    style: const TextStyle(fontSize: 12)),
                const SizedBox(width: 12),
                Icon(Icons.arrow_upward_rounded, size: 14, color: _kPremium),
                const SizedBox(width: 2),
                Text(_fmtBytes(txBytes),
                    style: const TextStyle(fontSize: 12)),
              ],
            ),
          ],
        ),
      ),
    );
  }

  String _fmtBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1048576) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1073741824) {
      return '${(bytes / 1048576).toStringAsFixed(1)} MB';
    }
    return '${(bytes / 1073741824).toStringAsFixed(2)} GB';
  }
}

// ═══════════════════════════════════════════════════════════════════════════
// TAB 4 – SERVERS
// ═══════════════════════════════════════════════════════════════════════════

class _ServersTab extends StatelessWidget {
  const _ServersTab({
    required this.dashboard,
    required this.loading,
    required this.error,
    required this.onRefresh,
  });

  final Map<String, dynamic> dashboard;
  final bool loading;
  final String? error;
  final VoidCallback onRefresh;

  @override
  Widget build(BuildContext context) {
    if (loading) return const Center(child: CircularProgressIndicator());
    if (error != null) return _ErrorState(error: error!, onRetry: onRefresh);

    final serverStats = dashboard['serverStats'];
    final servers = serverStats is List
        ? serverStats
            .whereType<Map>()
            .map((s) => Map<String, dynamic>.from(s))
            .toList()
        : <Map<String, dynamic>>[];

    return RefreshIndicator(
      onRefresh: () async => onRefresh(),
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: servers.isEmpty
            ? [const Center(child: Text('No server data'))]
            : servers.map((s) => _ServerHealthCard(server: s)).toList(),
      ),
    );
  }
}

class _ServerHealthCard extends StatelessWidget {
  const _ServerHealthCard({required this.server});

  final Map<String, dynamic> server;

  @override
  Widget build(BuildContext context) {
    final name = (server['name'] ?? 'Server').toString();
    final region = (server['region'] ?? '').toString();
    final flag = (server['flag'] ?? '🌍').toString();
    final ip = (server['ip'] ?? '').toString();
    final isOnline = server['isOnline'] == true;
    final ping = (server['ping'] ?? 999) as num;
    final load = ((server['load'] ?? 0) as num).toDouble().clamp(0.0, 100.0);

    Color pingColor = _kGreen;
    if (ping > 100) pingColor = _kYellow;
    if (ping >= 999) pingColor = _kRed;

    Color loadColor = _kGreen;
    if (load > 60) loadColor = _kYellow;
    if (load > 85) loadColor = _kRed;

    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text(flag, style: const TextStyle(fontSize: 22)),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(name,
                          style: const TextStyle(
                              fontWeight: FontWeight.w700, fontSize: 15)),
                      Text(region,
                          style: const TextStyle(
                              color: Colors.grey, fontSize: 13)),
                    ],
                  ),
                ),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                  decoration: BoxDecoration(
                    color:
                        (isOnline ? _kGreen : _kRed).withOpacity(0.12),
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Row(
                    children: [
                      Icon(Icons.circle,
                          size: 8,
                          color: isOnline ? _kGreen : _kRed),
                      const SizedBox(width: 4),
                      Text(isOnline ? 'Online' : 'Offline',
                          style: TextStyle(
                              fontSize: 12,
                              color: isOnline ? _kGreen : _kRed,
                              fontWeight: FontWeight.w600)),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 14),
            Text(ip,
                style: const TextStyle(
                    fontFamily: 'monospace',
                    fontSize: 12,
                    color: Colors.grey)),
            const SizedBox(height: 14),

            // Ping
            Row(children: [
              Icon(Icons.network_ping_outlined, size: 16, color: pingColor),
              const SizedBox(width: 6),
              Text('Ping: ',
                  style: const TextStyle(fontSize: 13, color: Colors.grey)),
              Text(
                ping >= 999 ? '—' : '${ping.round()} ms',
                style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                    color: pingColor),
              ),
            ]),
            const SizedBox(height: 10),

            // Load
            Row(children: [
              Icon(Icons.memory_outlined, size: 16, color: loadColor),
              const SizedBox(width: 6),
              Text('Load: ',
                  style: const TextStyle(fontSize: 13, color: Colors.grey)),
              Text(
                '${load.round()}%',
                style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                    color: loadColor),
              ),
            ]),
            const SizedBox(height: 6),
            ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: LinearProgressIndicator(
                value: load / 100,
                backgroundColor: Colors.grey.withOpacity(0.15),
                valueColor: AlwaysStoppedAnimation<Color>(loadColor),
                minHeight: 8,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════════
// Shared widgets
// ═══════════════════════════════════════════════════════════════════════════

class _TierBadge extends StatelessWidget {
  const _TierBadge({required this.tier});

  final String tier;

  @override
  Widget build(BuildContext context) {
    Color color;
    if (tier == 'ultra') {
      color = _kUltra;
    } else if (tier == 'premium') {
      color = _kPremium;
    } else {
      color = _kFree;
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
          color: color.withOpacity(0.12),
          borderRadius: BorderRadius.circular(4)),
      child: Text(
        tier.toUpperCase(),
        style: TextStyle(
            fontSize: 10, fontWeight: FontWeight.w700, color: color),
      ),
    );
  }
}

class _ProtocolChip extends StatelessWidget {
  const _ProtocolChip(this.protocol);

  final String protocol;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
      decoration: BoxDecoration(
          color: Colors.blue.withOpacity(0.1),
          borderRadius: BorderRadius.circular(4)),
      child: Text(
        protocol.toUpperCase(),
        style: const TextStyle(
            fontSize: 9, color: Colors.blue, fontWeight: FontWeight.w700),
      ),
    );
  }
}

class _ErrorState extends StatelessWidget {
  const _ErrorState({required this.error, required this.onRetry});

  final String error;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.error_outline, size: 48, color: _kRed),
            const SizedBox(height: 14),
            Text(error, textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.grey)),
            const SizedBox(height: 16),
            FilledButton.icon(
              icon: const Icon(Icons.refresh),
              label: const Text('Retry'),
              onPressed: onRetry,
            ),
          ],
        ),
      ),
    );
  }
}
