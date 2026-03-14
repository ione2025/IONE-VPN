import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../constants/app_constants.dart';

import '../../constants/app_theme.dart';

class SubscriptionScreen extends StatelessWidget {
  const SubscriptionScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Choose a Plan')),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(20),
        child: Column(
          children: [
            const SizedBox(height: 8),
            Text(
              'Unlock the full power of IONE VPN',
              style: Theme.of(context).textTheme.headlineMedium,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 8),
            Text(
              'Choose your tier and pay by scanning the QR code',
              style: Theme.of(context).textTheme.bodyMedium,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 32),

            // Free plan
            _PlanCard(
              title: 'Free',
              price: '\$0',
              period: 'forever',
              features: const [
                '1 active device per account',
                'Basic server access',
                'Standard bandwidth',
                'WireGuard protocol',
              ],
              isCurrent: true,
              onSelect: null,
            ),
            const SizedBox(height: 16),

            // Premium
            _PlanCard(
              title: 'Premium',
              price: '\$30',
              period: 'per month',
              features: const [
                '10 active devices',
                'Unlimited bandwidth',
                'All server locations',
              ],
              highlight: true,
              onSelect: () => _showPaymentDialog(context, 'premium', 30),
            ),
            const SizedBox(height: 16),

            // Ultra
            _PlanCard(
              title: 'Ultra',
              price: '\$50',
              period: 'per month',
              features: const [
                '50 active devices',
                'Unlimited bandwidth',
                'All server locations',
                'Highest priority support',
              ],
              onSelect: () => _showPaymentDialog(context, 'ultra', 50),
            ),

            const SizedBox(height: 28),
            Text(
              'After payment, your tier can be activated from the admin panel.',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodyMedium,
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _showPaymentDialog(BuildContext context, String tier, int amount) async {
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        title: Text('Upgrade to ${tier[0].toUpperCase()}${tier.substring(1)}'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('Price: \$$amount per month'),
              const SizedBox(height: 10),
              const Text('Scan this QR code in Alipay to pay:'),
              const SizedBox(height: 12),
              ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: Image.asset(
                  'assets/images/alipay_qr.png',
                  width: 260,
                  height: 380,
                  fit: BoxFit.cover,
                  errorBuilder: (_, __, ___) => Container(
                    width: 260,
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      border: Border.all(color: AppTheme.primaryBlue),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: const Text(
                      'QR image not found at assets/images/alipay_qr.png.\nAdd your provided QR image to that path.',
                      textAlign: TextAlign.center,
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 10),
              Text(
                'Tier limits:\nFree ${AppConstants.freeMaxDevices} device\nPremium ${AppConstants.premiumMaxDevices} devices\nUltra ${AppConstants.ultraMaxDevices} devices',
                textAlign: TextAlign.center,
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () async {
              await Clipboard.setData(ClipboardData(
                text: 'Upgrade request: tier=$tier, amount=\$$amount/month',
              ));
              if (!context.mounted) return;
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('Upgrade request copied')),
              );
            },
            child: const Text('Copy Request'),
          ),
          TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('OK')),
        ],
      ),
    );
  }
}

class _PlanCard extends StatelessWidget {
  const _PlanCard({
    required this.title,
    required this.price,
    required this.period,
    required this.features,
    this.highlight = false,
    this.isCurrent = false,
    required this.onSelect,
  });

  final String title;
  final String price;
  final String period;
  final List<String> features;
  final bool highlight;
  final bool isCurrent;
  final VoidCallback? onSelect;

  @override
  Widget build(BuildContext context) {
    return Card(
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: highlight
            ? const BorderSide(color: AppTheme.primaryBlue, width: 2)
            : BorderSide.none,
      ),
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text(title,
                    style: Theme.of(context)
                        .textTheme
                        .titleLarge
                        ?.copyWith(fontWeight: FontWeight.w700)),
                const Spacer(),
              ],
            ),
            const SizedBox(height: 8),
            RichText(
              text: TextSpan(children: [
                TextSpan(
                    text: price,
                    style: Theme.of(context)
                        .textTheme
                        .headlineLarge
                        ?.copyWith(fontSize: 28)),
                TextSpan(
                    text: ' / $period',
                    style: Theme.of(context).textTheme.bodyMedium),
              ]),
            ),
            const Divider(height: 24),
            ...features.map(
              (f) => Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Row(
                  children: [
                    const Icon(Icons.check_circle,
                        color: AppTheme.successGreen, size: 18),
                    const SizedBox(width: 8),
                    Text(f),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 16),
            SizedBox(
              width: double.infinity,
              child: isCurrent
                  ? OutlinedButton(
                      onPressed: null,
                      child: const Text('Current Plan'),
                    )
                  : ElevatedButton(
                      onPressed: onSelect,
                      child: const Text('Select Plan'),
                    ),
            ),
          ],
        ),
      ),
    );
  }
}
