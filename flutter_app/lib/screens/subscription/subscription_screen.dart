import 'package:flutter/material.dart';

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
              'Unlimited bandwidth · 10 devices · All servers',
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
                '1 device',
                'Singapore server only',
                '10 GB / month bandwidth',
                'WireGuard protocol',
              ],
              isCurrent: true,
              onSelect: null,
            ),
            const SizedBox(height: 16),

            // Monthly
            _PlanCard(
              title: 'Monthly VIP',
              price: '\$5.99',
              period: 'per month',
              features: const [
                'Up to 10 devices',
                'All server locations',
                'Unlimited bandwidth',
                'All protocols',
                'Priority support',
              ],
              highlight: false,
              onSelect: () => _showComingSoon(context),
            ),
            const SizedBox(height: 16),

            // Quarterly
            _PlanCard(
              title: 'Quarterly VIP',
              price: '\$14.99',
              period: 'every 3 months',
              savingBadge: 'Save 17%',
              features: const [
                'Everything in Monthly',
                '3-month commitment',
                'Lower per-month cost',
              ],
              highlight: true,
              onSelect: () => _showComingSoon(context),
            ),
            const SizedBox(height: 16),

            // Yearly
            _PlanCard(
              title: 'Yearly VIP',
              price: '\$39.99',
              period: 'per year',
              savingBadge: 'Save 44%',
              features: const [
                'Everything in Monthly',
                'Best value',
                'Annual billing',
              ],
              onSelect: () => _showComingSoon(context),
            ),

            const SizedBox(height: 28),
            Text(
              'Payments processed securely via Stripe.\nCancel anytime.',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodyMedium,
            ),
          ],
        ),
      ),
    );
  }

  void _showComingSoon(BuildContext context) {
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Coming Soon'),
        content:
            const Text('Payment integration will be available in the next release.'),
        actions: [
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
    this.savingBadge,
    this.highlight = false,
    this.isCurrent = false,
    required this.onSelect,
  });

  final String title;
  final String price;
  final String period;
  final List<String> features;
  final String? savingBadge;
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
                if (savingBadge != null)
                  Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                    decoration: BoxDecoration(
                      color: AppTheme.successGreen.withOpacity(0.15),
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: Text(
                      savingBadge!,
                      style: const TextStyle(
                          color: AppTheme.successGreen,
                          fontWeight: FontWeight.w600,
                          fontSize: 12),
                    ),
                  ),
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
