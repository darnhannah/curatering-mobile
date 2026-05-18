import 'dart:convert';

import 'package:http/http.dart' as http;

import 'api_config.dart';
import '../seating/seating_plan.dart';

class EventsFeatureApi {
  EventsFeatureApi({required this.apiBase});

  final String apiBase;

  Uri _uri(String path, [Map<String, String>? query]) {
    final base = featureApiBase(apiBase);
    return Uri.parse('$base$path').replace(queryParameters: query);
  }

  Future<List<Map<String, dynamic>>> listAiGenerations(String userEmail) async {
    final res = await http.get(_uri('/api/mobile/ai-generations', {'user_email': userEmail}));
    if (res.statusCode != 200) return [];
    final body = jsonDecode(res.body);
    if (body is! List) return [];
    return body.whereType<Map<String, dynamic>>().map((e) => Map<String, dynamic>.from(e)).toList();
  }

  Future<Map<String, dynamic>> getThemeDesign({
    required String orderId,
    required String orderKind,
    required String userEmail,
    String? cashierEmail,
    String? cashierPassword,
  }) async {
    final res = await http.get(
      _uri('/api/mobile/events/$orderId/theme-design', {
        'order_kind': orderKind,
        'user_email': userEmail,
      }),
    );
    if (res.statusCode != 200) {
      throw Exception(_errorFromBody(res.body) ?? 'Could not load theme design');
    }
    return jsonDecode(res.body) as Map<String, dynamic>;
  }

  Future<void> saveThemeDesign({
    required String orderId,
    required String orderKind,
    required Map<String, dynamic> themeDesign,
    required String userEmail,
    String? cashierEmail,
    String? cashierPassword,
  }) async {
    final res = await http.put(
      _uri('/api/mobile/events/$orderId/theme-design'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({
        'order_kind': orderKind,
        'user_email': userEmail,
        if (cashierEmail != null) 'cashier_email': cashierEmail,
        if (cashierPassword != null) 'cashier_password': cashierPassword,
        'theme_design': themeDesign,
      }),
    );
    if (res.statusCode != 200) {
      throw Exception(_errorFromBody(res.body) ?? 'Could not save theme design');
    }
  }

  Future<SeatingPlanData> getSeatingPlan({
    required String orderId,
    required String orderKind,
    required String userEmail,
    String? cashierEmail,
    String? cashierPassword,
  }) async {
    final res = await http.get(
      _uri('/api/mobile/events/$orderId/seating-plan', {
        'order_kind': orderKind,
        'user_email': userEmail,
      }),
    );
    if (res.statusCode != 200) {
      throw Exception(_errorFromBody(res.body) ?? 'Could not load seating plan');
    }
    final body = jsonDecode(res.body) as Map<String, dynamic>;
    return SeatingPlanData.fromJson(body['seating_plan']);
  }

  Future<void> saveSeatingPlan({
    required String orderId,
    required String orderKind,
    required SeatingPlanData plan,
    required String userEmail,
    String? cashierEmail,
    String? cashierPassword,
  }) async {
    final res = await http.put(
      _uri('/api/mobile/events/$orderId/seating-plan'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({
        'order_kind': orderKind,
        'user_email': userEmail,
        if (cashierEmail != null) 'cashier_email': cashierEmail,
        if (cashierPassword != null) 'cashier_password': cashierPassword,
        'seating_plan': plan.toJson(),
      }),
    );
    if (res.statusCode != 200) {
      throw Exception(_errorFromBody(res.body) ?? 'Could not save seating plan');
    }
  }

  String? _errorFromBody(String body) {
    try {
      final j = jsonDecode(body);
      if (j is Map && j['error'] != null) return '${j['error']}';
    } catch (_) {}
    return null;
  }
}
