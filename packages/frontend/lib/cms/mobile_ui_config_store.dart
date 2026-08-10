import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import 'mobile_ui_models.dart';

/// Public website CMS host that publishes `mobileUi` (not the mobile order API).
const String kDefaultCmsApiBase = 'https://curatering.up.railway.app';

String resolveCmsApiBase() {
  const env = String.fromEnvironment('CMS_API_BASE', defaultValue: '');
  if (env.trim().isNotEmpty) return env.trim().replaceAll(RegExp(r'/+$'), '');
  return kDefaultCmsApiBase;
}

String normalizeCmsApiBase(String raw) => raw.trim().replaceAll(RegExp(r'/+$'), '');

/// Fetches + caches published mobile UI layouts from the web Website CMS.
class MobileUiConfigStore extends ChangeNotifier {
  MobileUiConfigStore._();
  static final MobileUiConfigStore instance = MobileUiConfigStore._();

  static const _cacheKey = 'mobile_ui_config_v1';
  static const _cacheAtKey = 'mobile_ui_config_v1_at';
  static const _ttl = Duration(minutes: 5);

  MobileUiConfig config = MobileUiConfig();
  bool loaded = false;
  bool loading = false;
  String? lastError;
  DateTime? loadedAt;
  String cmsApiBase = resolveCmsApiBase();

  bool screenHasBlocks(String screenId) => config.screen(screenId).blocks.isNotEmpty;

  List<MobileUiBlock> blocksFor(String screenId) => config.screen(screenId).blocks;

  String mediaPublicUrl(String mediaId) {
    final base = normalizeCmsApiBase(cmsApiBase);
    return '$base/api/website-media/$mediaId/public';
  }

  Future<void> ensureLoaded({bool force = false}) async {
    if (loading) return;
    if (!force && loaded && loadedAt != null && DateTime.now().difference(loadedAt!) < _ttl) {
      return;
    }
    loading = true;
    lastError = null;
    notifyListeners();
    try {
      if (!loaded) await _hydrateFromCache();
      final uri = Uri.parse('${normalizeCmsApiBase(cmsApiBase)}/api/website-content');
      final res = await http.get(uri).timeout(const Duration(seconds: 20));
      if (res.statusCode != 200) {
        lastError = 'CMS HTTP ${res.statusCode}';
        loaded = true;
        return;
      }
      final body = jsonDecode(res.body);
      Map<String, dynamic>? map;
      if (body is Map<String, dynamic>) {
        map = body;
      } else if (body is Map) {
        map = Map<String, dynamic>.from(body);
      }
      dynamic mobileRaw;
      if (map != null) {
        if (map['mobileUi'] != null) {
          mobileRaw = map['mobileUi'];
        } else if (map['content'] is Map) {
          final content = Map<String, dynamic>.from(map['content'] as Map);
          mobileRaw = content['mobileUi'];
        }
      }
      config = mobileRaw == null ? MobileUiConfig() : MobileUiConfig.fromJson(mobileRaw);
      loadedAt = DateTime.now();
      loaded = true;
      await _persistCache();
    } catch (e) {
      lastError = '$e';
      if (!loaded) {
        await _hydrateFromCache();
        loaded = true;
      }
      debugPrint('MobileUiConfigStore: $e');
    } finally {
      loading = false;
      notifyListeners();
    }
  }

  Future<void> _hydrateFromCache() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_cacheKey);
      if (raw == null || raw.isEmpty) return;
      final decoded = jsonDecode(raw);
      config = MobileUiConfig.fromJson(decoded);
      final at = prefs.getString(_cacheAtKey);
      if (at != null) loadedAt = DateTime.tryParse(at);
    } catch (_) {}
  }

  Future<void> _persistCache() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_cacheKey, jsonEncode(config.toJson()));
      await prefs.setString(_cacheAtKey, DateTime.now().toIso8601String());
    } catch (_) {}
  }
}
