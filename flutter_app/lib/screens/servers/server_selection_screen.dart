import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../constants/app_theme.dart';
import '../../models/server_model.dart';
import '../../providers/vpn_provider.dart';
import '../../services/api_service.dart';
import '../../widgets/server_tile.dart';

class ServerSelectionScreen extends StatefulWidget {
  const ServerSelectionScreen({super.key});

  @override
  State<ServerSelectionScreen> createState() => _ServerSelectionScreenState();
}

class _ServerSelectionScreenState extends State<ServerSelectionScreen> {
  List<ServerModel> _servers = [];
  ServerModel? _recommended;
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _loadServers();
  }

  Future<void> _loadServers() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final api = context.read<ApiService>();
      final results = await Future.wait([
        api.getServers(),
        api.getRecommendedServer(),
      ]);
      final serverList = (results[0] as List)
          .map((j) => ServerModel.fromJson(j as Map<String, dynamic>))
          .toList();
      final recJson = results[1] as Map<String, dynamic>;
      setState(() {
        _servers = serverList;
        _recommended = ServerModel.fromJson(recJson);
        _loading = false;
      });
    } catch (e) {
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  void _select(ServerModel server) {
    context.read<VpnProvider>().selectServer(server);
    Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final selected = context.watch<VpnProvider>().selectedServer;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Select Server'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: _loadServers,
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.error_outline,
                          color: AppTheme.errorRed, size: 48),
                      const SizedBox(height: 12),
                      Text(_error!),
                      const SizedBox(height: 16),
                      ElevatedButton(
                          onPressed: _loadServers,
                          child: const Text('Retry')),
                    ],
                  ),
                )
              : ListView(
                  padding: const EdgeInsets.all(16),
                  children: [
                    if (_recommended != null) ...[
                      _SectionHeader(title: 'Recommended'),
                      ServerTile(
                        server: _recommended!,
                        isSelected: selected?.id == _recommended!.id,
                        badge: '⚡ Best',
                        onTap: () => _select(_recommended!),
                      ),
                      const SizedBox(height: 20),
                    ],
                    _SectionHeader(title: 'All Servers'),
                    ..._servers.map(
                      (s) => ServerTile(
                        server: s,
                        isSelected: selected?.id == s.id,
                        onTap: () => _select(s),
                      ),
                    ),
                  ],
                ),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader({required this.title});
  final String title;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Text(
        title.toUpperCase(),
        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
              fontSize: 11,
              fontWeight: FontWeight.w700,
              letterSpacing: 1,
            ),
      ),
    );
  }
}
