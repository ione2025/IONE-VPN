import 'package:flutter/foundation.dart';

import '../models/user_model.dart';
import '../services/api_service.dart';

enum AuthStatus { unknown, authenticated, unauthenticated }

/// Manages user authentication state for the entire app.
class AuthProvider extends ChangeNotifier {
  AuthProvider(this._api) {
    _checkStoredSession();
  }

  final ApiService _api;

  AuthStatus _status = AuthStatus.unknown;
  UserModel? _user;
  String? _errorMessage;

  // ─── Getters ──────────────────────────────────────────────────────────────
  AuthStatus get status => _status;
  UserModel? get user => _user;
  String? get errorMessage => _errorMessage;
  bool get isAuthenticated => _status == AuthStatus.authenticated;

  // ─── Initialise from stored token ────────────────────────────────────────
  Future<void> _checkStoredSession() async {
    try {
      final hasToken = await _api.hasStoredToken();
      if (!hasToken) {
        _status = AuthStatus.unauthenticated;
        notifyListeners();
        return;
      }
      final data = await _api.getMe();
      _user = UserModel.fromJson(data['user'] as Map<String, dynamic>);
      _status = AuthStatus.authenticated;
    } catch (_) {
      _status = AuthStatus.unauthenticated;
    }
    notifyListeners();
  }

  // ─── Register ─────────────────────────────────────────────────────────────
  Future<bool> register(String email, String password) async {
    _errorMessage = null;
    try {
      final data = await _api.register(email, password);
      final tokens = data['tokens'] as Map<String, dynamic>;
      await _api.saveTokens(
        tokens['access'] as String,
        tokens['refresh'] as String,
      );
      _user = UserModel.fromJson(data['user'] as Map<String, dynamic>);
      _status = AuthStatus.authenticated;
      notifyListeners();
      return true;
    } catch (e) {
      _errorMessage = _extractError(e);
      notifyListeners();
      return false;
    }
  }

  // ─── Login ────────────────────────────────────────────────────────────────
  Future<bool> login(String email, String password) async {
    _errorMessage = null;
    try {
      final data = await _api.login(email, password);
      final tokens = data['tokens'] as Map<String, dynamic>;
      await _api.saveTokens(
        tokens['access'] as String,
        tokens['refresh'] as String,
      );
      _user = UserModel.fromJson(data['user'] as Map<String, dynamic>);
      _status = AuthStatus.authenticated;
      notifyListeners();
      return true;
    } catch (e) {
      _errorMessage = _extractError(e);
      notifyListeners();
      return false;
    }
  }

  // ─── Logout ───────────────────────────────────────────────────────────────
  Future<void> logout() async {
    await _api.clearTokens();
    _user = null;
    _status = AuthStatus.unauthenticated;
    notifyListeners();
  }

  // ─── Refresh user data ────────────────────────────────────────────────────
  Future<void> refreshUser() async {
    try {
      final data = await _api.getMe();
      _user = UserModel.fromJson(data['user'] as Map<String, dynamic>);
      notifyListeners();
    } catch (_) {}
  }

  // ─── Helpers ──────────────────────────────────────────────────────────────
  String _extractError(dynamic e) {
    // DioException carries server error messages
    try {
      final resp = (e as dynamic).response;
      return resp?.data?['message'] as String? ?? e.toString();
    } catch (_) {
      return e.toString();
    }
  }
}
