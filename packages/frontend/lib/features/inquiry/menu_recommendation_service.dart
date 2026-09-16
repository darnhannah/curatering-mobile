import 'dart:convert';

import 'package:http/http.dart' as http;

import '../../cms/mobile_ui_config_store.dart';

/// Public menu recommendation via the web API (RunPod Qwen3 proxy).
class MenuRecommendationService {
  MenuRecommendationService._();
  static final MenuRecommendationService instance = MenuRecommendationService._();

  static const Duration _startTimeout = Duration(seconds: 20);
  static const Duration _pollTimeout = Duration(seconds: 20);
  static const Duration _overallTimeout = Duration(seconds: 180);
  static const Duration _pollInterval = Duration(seconds: 2);

  String get _apiBase => resolveCmsApiBase();

  Future<MenuRecommendationResult> recommend({
    required String eventType,
    required String eventTitle,
    required String eventSetting,
    required int guestCount,
    required List<String> allergens,
    required List<Map<String, dynamic>> dishes,
  }) async {
    final uri = Uri.parse('$_apiBase/api/recommend-menu');
    final response = await http
        .post(
          uri,
          headers: const {'Content-Type': 'application/json'},
          body: jsonEncode({
            'eventType': eventType,
            'eventTitle': eventTitle,
            'eventSetting': eventSetting,
            'guestCount': guestCount,
            'allergens': allergens,
            'dishes': dishes,
          }),
        )
        .timeout(_startTimeout);

    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw MenuRecommendationException(
        _errorMessage(response, 'Menu recommendation failed (${response.statusCode})'),
      );
    }

    final data = _decodeMap(response.body);
    final immediate = _tryParseResult(data);
    if (immediate != null) return immediate;

    final jobId = data['jobId']?.toString().trim() ?? '';
    if (jobId.isEmpty) {
      throw MenuRecommendationException('Invalid menu recommendation response');
    }

    return _pollJob(jobId);
  }

  Future<MenuRecommendationResult> _pollJob(String jobId) async {
    final deadline = DateTime.now().add(_overallTimeout);
    final statusUri = Uri.parse(
      '$_apiBase/api/recommend-menu/${Uri.encodeComponent(jobId)}',
    );

    while (DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(_pollInterval);
      final response = await http.get(statusUri).timeout(_pollTimeout);

      if (response.statusCode == 404) {
        throw MenuRecommendationException('Menu recommendation expired. Please try again.');
      }

      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw MenuRecommendationException(
          _errorMessage(response, 'Menu recommendation failed (${response.statusCode})'),
        );
      }

      final data = _decodeMap(response.body);
      final status = data['status']?.toString().toLowerCase() ?? '';
      if (status == 'failed') {
        throw MenuRecommendationException(
          data['error']?.toString() ?? 'Unable to generate menu recommendation',
        );
      }

      final parsed = _tryParseResult(data);
      if (parsed != null) return parsed;

      if (status == 'completed') {
        throw MenuRecommendationException(
          'Menu recommendation returned no dishes. Please try again.',
        );
      }
    }

    throw MenuRecommendationException(
      'Menu recommendation took too long. Please try again in a moment.',
    );
  }

  MenuRecommendationResult? _tryParseResult(Map<String, dynamic> data) {
    final payload = data['result'] is Map
        ? Map<String, dynamic>.from(data['result'] as Map)
        : data;
    final ids = payload['dishIds'];
    if (ids is! List || ids.isEmpty) return null;
    return MenuRecommendationResult.fromJson(payload);
  }

  Map<String, dynamic> _decodeMap(String body) {
    final decoded = jsonDecode(body);
    if (decoded is! Map) {
      throw MenuRecommendationException('Invalid menu recommendation response');
    }
    return Map<String, dynamic>.from(decoded);
  }

  String _errorMessage(http.Response response, String fallback) {
    try {
      final decoded = jsonDecode(response.body);
      if (decoded is Map && decoded['error'] != null) {
        return decoded['error'].toString();
      }
    } catch (_) {}
    return fallback;
  }
}

class MenuRecommendationException implements Exception {
  MenuRecommendationException(this.message);
  final String message;

  @override
  String toString() => message;
}

class MenuRecommendationResult {
  const MenuRecommendationResult({
    required this.dishIds,
    required this.dishes,
    required this.summary,
    required this.notes,
  });

  final List<String> dishIds;
  final List<Map<String, dynamic>> dishes;
  final String summary;
  final List<String> notes;

  factory MenuRecommendationResult.fromJson(Map<String, dynamic> json) {
    final dishes = (json['dishes'] as List? ?? const [])
        .whereType<Map>()
        .map((e) => Map<String, dynamic>.from(e))
        .toList();
    var dishIds = (json['dishIds'] as List? ?? const [])
        .map((e) => e.toString().trim())
        .where((e) => e.isNotEmpty)
        .toList();
    if (dishIds.isEmpty) {
      dishIds = dishes
          .map((d) => (d['id'] ?? d['dishId'] ?? '').toString().trim())
          .where((e) => e.isNotEmpty)
          .toList();
    }
    return MenuRecommendationResult(
      dishIds: dishIds,
      dishes: dishes,
      summary: json['summary']?.toString() ?? '',
      notes: (json['notes'] as List? ?? const []).map((e) => e.toString()).toList(),
    );
  }
}
