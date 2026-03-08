/// Authenticated user model.
class UserModel {
  final String id;
  final String email;
  final String role;
  final SubscriptionModel subscription;

  const UserModel({
    required this.id,
    required this.email,
    required this.role,
    required this.subscription,
  });

  factory UserModel.fromJson(Map<String, dynamic> json) {
    return UserModel(
      id: json['id'] as String,
      email: json['email'] as String,
      role: json['role'] as String? ?? 'user',
      subscription: SubscriptionModel.fromJson(
        json['subscription'] as Map<String, dynamic>? ?? {},
      ),
    );
  }

  bool get isPremium => subscription.tier != 'free';
}

class SubscriptionModel {
  final String tier;
  final int maxDevices;
  final bool unlimitedBandwidth;
  final bool allServers;
  final DateTime? expiresAt;

  const SubscriptionModel({
    required this.tier,
    required this.maxDevices,
    required this.unlimitedBandwidth,
    required this.allServers,
    this.expiresAt,
  });

  factory SubscriptionModel.fromJson(Map<String, dynamic> json) {
    return SubscriptionModel(
      tier: json['tier'] as String? ?? 'free',
      maxDevices: json['maxDevices'] as int? ?? 1,
      unlimitedBandwidth: json['unlimitedBandwidth'] as bool? ?? false,
      allServers: json['allServers'] as bool? ?? false,
      expiresAt: json['expiresAt'] != null
          ? DateTime.tryParse(json['expiresAt'] as String)
          : null,
    );
  }
}
