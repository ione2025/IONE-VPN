import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'constants/app_theme.dart';
import 'providers/theme_provider.dart';
import 'screens/splash_screen.dart';
import 'screens/auth/login_screen.dart';
import 'screens/home/home_screen.dart';
import 'screens/servers/server_selection_screen.dart';
import 'screens/settings/settings_screen.dart';
import 'screens/subscription/subscription_screen.dart';

class IoneVpnApp extends StatelessWidget {
  const IoneVpnApp({super.key});

  @override
  Widget build(BuildContext context) {
    final themeProvider = context.watch<ThemeProvider>();

    return MaterialApp(
      title: 'IONE VPN',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.light,
      darkTheme: AppTheme.dark,
      themeMode: themeProvider.themeMode,
      initialRoute: '/',
      routes: {
        '/': (_) => const SplashScreen(),
        '/login': (_) => const LoginScreen(),
        '/home': (_) => const HomeScreen(),
        '/servers': (_) => const ServerSelectionScreen(),
        '/settings': (_) => const SettingsScreen(),
        '/subscription': (_) => const SubscriptionScreen(),
      },
      // Redirect unauthenticated access
      onGenerateRoute: (settings) {
        return MaterialPageRoute(builder: (_) => const SplashScreen());
      },
    );
  }
}
