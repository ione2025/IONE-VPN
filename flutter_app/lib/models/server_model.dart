/// Represents a VPN server location.
class ServerModel {
  final String id;
  final String name;
  final String region;
  final String country; // ISO 3166-1 alpha-2
  final String flag;
  final String ip;
  final int wgPort;
  final int ping; // ms
  final int load; // 0-100
  final bool isOnline;
  final bool isPremiumOnly;
  final double? score; // recommendation score

  const ServerModel({
    required this.id,
    required this.name,
    required this.region,
    required this.country,
    required this.flag,
    required this.ip,
    required this.wgPort,
    required this.ping,
    required this.load,
    required this.isOnline,
    required this.isPremiumOnly,
    this.score,
  });

  factory ServerModel.fromJson(Map<String, dynamic> json) {
    return ServerModel(
      id: json['id'] as String,
      name: json['name'] as String,
      region: json['region'] as String,
      country: json['country'] as String,
      flag: json['flag'] as String? ?? '🌐',
      ip: json['ip'] as String,
      wgPort: json['wgPort'] as int? ?? 51820,
      ping: json['ping'] as int? ?? 999,
      load: json['load'] as int? ?? 0,
      isOnline: json['isOnline'] as bool? ?? false,
      isPremiumOnly: json['isPremiumOnly'] as bool? ?? false,
      score: (json['score'] as num?)?.toDouble(),
    );
  }

  String get pingLabel => ping >= 999 ? 'N/A' : '${ping}ms';
  String get loadLabel => '$load%';
}
