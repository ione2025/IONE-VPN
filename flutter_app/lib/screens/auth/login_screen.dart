import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../constants/app_theme.dart';
import '../../providers/auth_provider.dart';

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _formKey = GlobalKey<FormState>();
  final _emailCtrl = TextEditingController();
  final _passCtrl = TextEditingController();
  bool _obscurePass = true;
  bool _obscureResetPass = true;
  bool _loading = false;
  bool _isRegisterMode = false;

  @override
  void dispose() {
    _emailCtrl.dispose();
    _passCtrl.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() => _loading = true);

    final auth = context.read<AuthProvider>();
    final ok = _isRegisterMode
        ? await auth.register(_emailCtrl.text.trim(), _passCtrl.text)
        : await auth.login(_emailCtrl.text.trim(), _passCtrl.text);

    if (!mounted) return;
    setState(() => _loading = false);

    if (ok) {
      Navigator.pushReplacementNamed(context, '/home');
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(auth.errorMessage ?? 'An error occurred'),
          backgroundColor: AppTheme.errorRed,
        ),
      );
    }
  }

  Future<void> _showForgotPasswordDialog() async {
    final auth = context.read<AuthProvider>();
    final messenger = ScaffoldMessenger.of(context);
    final navigator = Navigator.of(context);
    final emailCtrl = TextEditingController(text: _emailCtrl.text.trim());
    final tokenCtrl = TextEditingController();
    final newPassCtrl = TextEditingController();
    bool loading = false;
    String? localError;

    await showDialog<void>(
      context: context,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setLocalState) {
            Future<void> requestToken() async {
              final email = emailCtrl.text.trim();
              if (email.isEmpty || !email.contains('@')) {
                setLocalState(() => localError = 'Enter a valid email');
                return;
              }

              setLocalState(() {
                loading = true;
                localError = null;
              });

              final token = await auth.forgotPassword(email);

              if (!mounted) return;

              setLocalState(() {
                loading = false;
                // In production token is sent via configured channel.
                // In test/dev it may be returned directly to simplify QA.
                if (token != null && token.isNotEmpty) {
                  tokenCtrl.text = token;
                }
              });

              messenger.showSnackBar(
                const SnackBar(
                  content: Text('Reset instructions sent. Enter token and new password.'),
                ),
              );
            }

            Future<void> submitReset() async {
              final token = tokenCtrl.text.trim();
              final newPassword = newPassCtrl.text;

              if (token.length < 16) {
                setLocalState(() => localError = 'Enter a valid reset token');
                return;
              }
              if (newPassword.length < 8) {
                setLocalState(() => localError = 'New password must be at least 8 characters');
                return;
              }

              setLocalState(() {
                loading = true;
                localError = null;
              });

              final ok = await auth.resetPassword(
                token: token,
                newPassword: newPassword,
              );

              if (!mounted) return;

              setLocalState(() => loading = false);

              if (ok) {
                if (mounted) {
                  navigator.pop();
                  messenger.showSnackBar(
                    const SnackBar(content: Text('Password reset successful. Please sign in.')),
                  );
                }
              } else {
                setLocalState(() => localError = auth.errorMessage ?? 'Password reset failed');
              }
            }

            return AlertDialog(
              title: const Text('Forgot Password'),
              content: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    TextField(
                      controller: emailCtrl,
                      keyboardType: TextInputType.emailAddress,
                      decoration: const InputDecoration(
                        labelText: 'Email',
                      ),
                    ),
                    const SizedBox(height: 10),
                    TextField(
                      controller: tokenCtrl,
                      decoration: const InputDecoration(
                        labelText: 'Reset token',
                      ),
                    ),
                    const SizedBox(height: 10),
                    TextField(
                      controller: newPassCtrl,
                      obscureText: _obscureResetPass,
                      decoration: InputDecoration(
                        labelText: 'New password',
                        suffixIcon: IconButton(
                          icon: Icon(_obscureResetPass
                              ? Icons.visibility_outlined
                              : Icons.visibility_off_outlined),
                          onPressed: () {
                            setState(() => _obscureResetPass = !_obscureResetPass);
                            setLocalState(() {});
                          },
                        ),
                      ),
                    ),
                    if (localError != null) ...[
                      const SizedBox(height: 10),
                      Text(
                        localError!,
                        style: const TextStyle(color: AppTheme.errorRed),
                      ),
                    ],
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: loading ? null : () => Navigator.of(context).pop(),
                  child: const Text('Close'),
                ),
                TextButton(
                  onPressed: loading ? null : requestToken,
                  child: const Text('Send Token'),
                ),
                ElevatedButton(
                  onPressed: loading ? null : submitReset,
                  child: loading
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Text('Reset Password'),
                ),
              ],
            );
          },
        );
      },
    );

    emailCtrl.dispose();
    tokenCtrl.dispose();
    newPassCtrl.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 40),
          child: Form(
            key: _formKey,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Logo
                Center(
                  child: Container(
                    width: 72,
                    height: 72,
                    decoration: BoxDecoration(
                      gradient: const LinearGradient(
                        colors: [AppTheme.primaryBlue, AppTheme.accentCyan],
                      ),
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child:
                        const Icon(Icons.shield, color: Colors.white, size: 38),
                  ),
                ),
                const SizedBox(height: 32),
                Text(
                  _isRegisterMode ? 'Create account' : 'Welcome back',
                  style: Theme.of(context).textTheme.headlineMedium,
                ),
                const SizedBox(height: 6),
                Text(
                  _isRegisterMode
                      ? 'Sign up to start using IONE VPN'
                      : 'Sign in to continue',
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
                const SizedBox(height: 36),

                // Email
                TextFormField(
                  controller: _emailCtrl,
                  keyboardType: TextInputType.emailAddress,
                  textInputAction: TextInputAction.next,
                  decoration: const InputDecoration(
                    labelText: 'Email address',
                    prefixIcon: Icon(Icons.email_outlined),
                  ),
                  validator: (v) {
                    if (v == null || v.isEmpty) return 'Email is required';
                    if (!v.contains('@')) return 'Enter a valid email';
                    return null;
                  },
                ),
                const SizedBox(height: 16),

                // Password
                TextFormField(
                  controller: _passCtrl,
                  obscureText: _obscurePass,
                  textInputAction: TextInputAction.done,
                  onFieldSubmitted: (_) => _submit(),
                  decoration: InputDecoration(
                    labelText: 'Password',
                    prefixIcon: const Icon(Icons.lock_outline),
                    suffixIcon: IconButton(
                      icon: Icon(_obscurePass
                          ? Icons.visibility_outlined
                          : Icons.visibility_off_outlined),
                      onPressed: () =>
                          setState(() => _obscurePass = !_obscurePass),
                    ),
                  ),
                  validator: (v) {
                    if (v == null || v.isEmpty) return 'Password is required';
                    if (v.length < 8) return 'Minimum 8 characters';
                    return null;
                  },
                ),
                const SizedBox(height: 32),

                // Submit button
                ElevatedButton(
                  onPressed: _loading ? null : _submit,
                  child: _loading
                      ? const SizedBox(
                          height: 22,
                          width: 22,
                          child: CircularProgressIndicator(
                              color: Colors.white, strokeWidth: 2.5),
                        )
                      : Text(_isRegisterMode ? 'Create Account' : 'Sign In'),
                ),
                const SizedBox(height: 20),

                // Toggle mode
                Center(
                  child: TextButton(
                    onPressed: () =>
                        setState(() => _isRegisterMode = !_isRegisterMode),
                    child: Text(
                      _isRegisterMode
                          ? 'Already have an account? Sign in'
                          : "Don't have an account? Register",
                    ),
                  ),
                ),

                if (!_isRegisterMode) ...[
                  const SizedBox(height: 8),
                  Center(
                    child: TextButton(
                      onPressed: _showForgotPasswordDialog,
                      child: const Text('Forgot password?'),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}
