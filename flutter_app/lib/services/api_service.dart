import 'package:dio/dio.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../constants/app_constants.dart';

/// Centralised HTTP client for all IONE VPN API calls.
///
/// Automatically attaches the Bearer token and handles 401 token refresh.
class ApiService {
  late final Dio _dio;
  final FlutterSecureStorage _storage = const FlutterSecureStorage(
    aOptions: AndroidOptions(
      encryptedSharedPreferences: true,
      resetOnError: true,
    ),
  );

  ApiService() {
    _dio = Dio(BaseOptions(
      baseUrl: AppConstants.apiBaseUrl,
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
    if (err.response?.statusCode == 401) {
      // Attempt silent token refresh
      try {
        final refreshToken =
            await _storage.read(key: AppConstants.keyRefreshToken);
        if (refreshToken == null) return handler.next(err);

        final refreshResp = await Dio().post(
          '${AppConstants.apiBaseUrl}/auth/refresh',
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
