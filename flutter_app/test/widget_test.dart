import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:ione_vpn/app.dart';
import 'package:ione_vpn/providers/auth_provider.dart';
import 'package:ione_vpn/providers/theme_provider.dart';
import 'package:ione_vpn/providers/vpn_provider.dart';
import 'package:ione_vpn/services/api_service.dart';

void main() {
  testWidgets('app bootstrap smoke test', (WidgetTester tester) async {
    final apiService = ApiService();

    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider(create: (_) => ThemeProvider()),
          ChangeNotifierProvider(create: (_) => AuthProvider(apiService)),
          ChangeNotifierProvider(create: (_) => VpnProvider(apiService)),
        ],
        child: const IoneVpnApp(),
      ),
    );

    await tester.pump();

    expect(find.byType(IoneVpnApp), findsOneWidget);
  });
}
