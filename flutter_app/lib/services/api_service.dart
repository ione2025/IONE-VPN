import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../constants/app_constants.dart';

/// Centralised HTTP client for all IONE VPN API calls.
///
/// Automatically attaches the Bearer token and handles 401 token refresh.
class ApiService {
  late final Dio _dio;
  late final List<String> _baseUrlCandidates;
  int _activeBaseUrlIndex = 0;
  final FlutterSecureStorage _storage = const FlutterSecureStorage(
    aOptions: AndroidOptions(
      encryptedSharedPreferences: true,
      resetOnError: true,
    ),
  );

  ApiService() {
    _baseUrlCandidates = [
      AppConstants.apiBaseUrl,
      ...AppConstants.apiBaseUrlFallbacks,
    ];

    _dio = Dio(BaseOptions(
      baseUrl: _baseUrlCandidates.first,
      connectTimeout: AppConstants.connectTimeout,
      receiveTimeout: AppConstants.receiveTimeout,
      headers: {'Content-Type': 'application/json'},
    ));

    _dio.interceptors.add(InterceptorsWrapper(
      onRequest: _attachToken,
      onError: _handleAuthError,
    ));
  }

  // ─── Interceptors ─────────────────────────────────────────────────────────

  Future<void> _attachToken(
    RequestOptions options,
    RequestInterceptorHandler handler,
  ) async {
    final token = await _storage.read(key: AppConstants.keyAccessToken);
    if (token != null) {
      options.headers['Authorization'] = 'Bearer $token';
    }
    handler.next(options);
  }

  Future<void> _handleAuthError(
    DioException err,
    ErrorInterceptorHandler handler,
  ) async {
    final shouldTryFailover =
        (_isNetworkConnectionError(err) || _isLikelyPath404(err)) &&
        err.requestOptions.extra['didBaseUrlFailover'] != true;

    if (shouldTryFailover) {
      final recovered = await _retryWithBaseUrlFailover(err.requestOptions);
      if (recovered != null) {
        return handler.resolve(recovered);
      }
    }

    if (err.response?.statusCode == 401) {
      // Attempt silent token refresh
      try {
        final refreshToken =
            await _storage.read(key: AppConstants.keyRefreshToken);
        if (refreshToken == null) return handler.next(err);

        final refreshResp = await Dio().post(
          '${_dio.options.baseUrl}/auth/refresh',
          data: {'refreshToken': refreshToken},
        );
        final newToken = refreshResp.data['tokens']['access'] as String;
        await _storage.write(key: AppConstants.keyAccessToken, value: newToken);

        // Retry original request
        err.requestOptions.headers['Authorization'] = 'Bearer $newToken';
        final retried = await _dio.fetch(err.requestOptions);
        return handler.resolve(retried);
      } catch (_) {
        // Refresh failed – caller will handle as 401
      }
    }
    handler.next(err);
  }

  bool _isNetworkConnectionError(DioException err) {
    if (err.type == DioExceptionType.connectionError) return true;
    final error = err.error;
    return error is SocketException;
  }

  bool _isLikelyPath404(DioException err) {
    if (err.response?.statusCode != 404) return false;
    final path = err.requestOptions.path;
    return path.startsWith('/auth/') || path == '/auth/login' || path == '/auth/register';
  }

  Future<Response<dynamic>?> _retryWithBaseUrlFailover(RequestOptions original) async {
    for (var i = 0; i < _baseUrlCandidates.length; i++) {
      if (i == _activeBaseUrlIndex) continue;

      final candidate = _baseUrlCandidates[i];
      try {
        final token = await _storage.read(key: AppConstants.keyAccessToken);
        final retryClient = Dio(BaseOptions(
          baseUrl: candidate,
          connectTimeout: AppConstants.connectTimeout,
          receiveTimeout: AppConstants.receiveTimeout,
          headers: {
            'Content-Type': 'application/json',
            ...original.headers,
            if (token != null) 'Authorization': 'Bearer $token',
          },
        ));

        final response = await retryClient.request<dynamic>(
          original.path,
          data: original.data,
          queryParameters: original.queryParameters,
          options: Options(
            method: original.method,
            responseType: original.responseType,
            contentType: original.contentType,
            sendTimeout: original.sendTimeout,
            receiveTimeout: original.receiveTimeout,
            validateStatus: original.validateStatus,
            extra: {
              ...original.extra,
              'didBaseUrlFailover': true,
            },
          ),
        );

        _activeBaseUrlIndex = i;
        _dio.options.baseUrl = candidate;
        return response;
      } catch (_) {
        // Try next candidate.
      }
    }
    return null;
  }

  // ─── Auth ─────────────────────────────────────────────────────────────────

  Future<Map<String, dynamic>> register(String email, String password) async {
    final resp = await _dio.post('/auth/register', data: {
      'email': email,
      'password': password,
    });
    return resp.data as Map<String, dynamic>;
  }

  Future<Map<String, dynamic>> login(String email, String password) async {
    final resp = await _dio.post('/auth/login', data: {
      'email': email,
      'password': password,
    });
    return resp.data as Map<String, dynamic>;
  }

  Future<Map<String, dynamic>> forgotPassword(String email) async {
    final resp = await _dio.post('/auth/forgot-password', data: {
      'email': email,
    });
    return resp.data as Map<String, dynamic>;
  }

  Future<void> resetPassword(String token, String newPassword) async {
    await _dio.post('/auth/reset-password', data: {
      'token': token,
      'newPassword': newPassword,
    });
  }

  Future<Map<String, dynamic>> getMe() async {
    final resp = await _dio.get('/auth/me');
    return resp.data as Map<String, dynamic>;
  }

  Future<void> changePassword(String current, String newPass) async {
    await _dio.patch('/auth/change-password', data: {
      'currentPassword': current,
      'newPassword': newPass,
    });
  }

  // ─── VPN ──────────────────────────────────────────────────────────────────

  Future<Map<String, dynamic>> generateVpnConfig({
    required String name,
    required String platform,
    String protocol = 'wireguard',
  }) async {
    final resp = await _dio.post('/vpn/config', data: {
      'name': name,
      'platform': platform,
      'protocol': protocol,
    });
    return resp.data as Map<String, dynamic>;
  }

  Future<void> recordConnect(String deviceId) async {
    await _dio.post('/vpn/connect', data: {'deviceId': deviceId});
  }

  Future<void> recordDisconnect(String deviceId) async {
    await _dio.post('/vpn/disconnect', data: {'deviceId': deviceId});
  }

  Future<Map<String, dynamic>> getVpnStatus() async {
    final resp = await _dio.get('/vpn/status');
    return resp.data as Map<String, dynamic>;
  }

  // ─── Servers ──────────────────────────────────────────────────────────────

  Future<List<dynamic>> getServers() async {
    final resp = await _dio.get('/servers');
    return resp.data['servers'] as List;
  }

  Future<Map<String, dynamic>> getRecommendedServer({String? region}) async {
    final resp = await _dio.get('/servers/recommend',
        queryParameters: region != null ? {'region': region} : null);
    return resp.data['recommended'] as Map<String, dynamic>;
  }

  // ─── Devices ──────────────────────────────────────────────────────────────

  Future<List<dynamic>> getDevices() async {
    final resp = await _dio.get('/devices');
    return resp.data['devices'] as List;
  }

  Future<void> revokeDevice(String deviceId) async {
    await _dio.delete('/devices/$deviceId');
  }

  // ─── Admin ────────────────────────────────────────────────────────────────

  Future<Map<String, dynamic>> getAdminDashboard() async {
    final resp = await _dio.get('/admin/dashboard');
    return resp.data as Map<String, dynamic>;
  }

  Future<Map<String, dynamic>> getAdminUsers({
    int page = 1,
    int limit = 50,
    bool includeDevices = true,
  }) async {
    final resp = await _dio.get('/admin/users', queryParameters: {
      'page': page,
      'limit': limit,
      'includeDevices': includeDevices,
    });
    return resp.data as Map<String, dynamic>;
  }

  Future<Map<String, dynamic>> updateUserSubscription({
    required String userId,
    required String tier,
  }) async {
    final resp = await _dio.patch('/admin/users/$userId/subscription', data: {
      'tier': tier,
    });
    return resp.data as Map<String, dynamic>;
  }

  Future<Map<String, dynamic>> toggleUserStatus(String userId) async {
    final resp = await _dio.patch('/admin/users/$userId/toggle-status');
    return resp.data as Map<String, dynamic>;
  }

  Future<List<dynamic>> getAdminWgPeers() async {
    final resp = await _dio.get('/admin/wg-peers');
    return resp.data['peers'] as List? ?? const [];
  }

  Future<void> revokeAllUserDevices(String userId) async {
    await _dio.delete('/admin/users/$userId/devices');
  }

  Future<void> deleteUser(String userId) async {
    await _dio.delete('/admin/users/$userId');
  }

  // ─── Token storage helpers ────────────────────────────────────────────────

  Future<void> saveTokens(String access, String refresh) async {
    await Future.wait([
      _storage.write(key: AppConstants.keyAccessToken, value: access),
      _storage.write(key: AppConstants.keyRefreshToken, value: refresh),
    ]);
  }

  Future<void> clearTokens() async {
    await Future.wait([
      _storage.delete(key: AppConstants.keyAccessToken),
      _storage.delete(key: AppConstants.keyRefreshToken),
      _storage.delete(key: AppConstants.keyActiveDeviceId),
    ]);
  }

  Future<bool> hasStoredToken() async {
    final token = await _storage.read(key: AppConstants.keyAccessToken);
    return token != null;
  }
}
