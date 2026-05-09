import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:http/http.dart' as http;
import 'package:image_picker/image_picker.dart';
import 'package:intl/intl.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:pdf/pdf.dart' as pdf;
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';
import 'package:url_launcher/url_launcher.dart';

import 'customer_local_notifications.dart';

/// Optional logical flavor at Dart level (`customer` / `staff`).
const String kAppFlavor = String.fromEnvironment('APP_FLAVOR', defaultValue: 'customer');
/// When `true`, login hides sign-up for staff/POS builds.
const bool kPosLoginBuild = bool.fromEnvironment('POS_LOGIN', defaultValue: false) || kAppFlavor == 'staff';

/// Paths declared under `flutter.assets` in pubspec.yaml.
class AppBrandAssets {
  AppBrandAssets._();
  static const String logo = 'assets/images/macrinasLogo.png';
  static const String logoDashboard = 'assets/images/macrinasLogo3.png';
  /// Login / welcome hero (customer).
  static const String logoLogin = 'assets/images/macrinasLogo2.png';
  static const String qrCode = 'assets/images/QRCode_Curatering.jpg';
}

Future<void> runCurateringApp({bool forcePosLogin = false}) async {
  WidgetsFlutterBinding.ensureInitialized();
  await initCustomerLocalNotifications();
  final prefs = await SharedPreferences.getInstance();
  final savedThemeMode = prefs.getString('theme_mode');
  runApp(CurateringApp(savedThemeMode: savedThemeMode, forcePosLogin: forcePosLogin));
}

Future<void> main() async {
  await runCurateringApp();
}

ThemeData buildAppLightTheme() {
  return ThemeData(
    useMaterial3: true,
    brightness: Brightness.light,
    scaffoldBackgroundColor: AppColors.canvas,
    colorScheme: ColorScheme.fromSeed(seedColor: AppColors.brand, brightness: Brightness.light),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: Colors.white,
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(10),
      ),
    ),
  );
}

ThemeData buildAppDarkTheme() {
  return ThemeData(
    useMaterial3: true,
    brightness: Brightness.dark,
    scaffoldBackgroundColor: const Color(0xFF1A1A1A),
    colorScheme: ColorScheme.fromSeed(seedColor: AppColors.brand, brightness: Brightness.dark),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: const Color(0xFF2C2C2C),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(10),
      ),
    ),
  );
}

class _SessionExpiredDialog extends StatefulWidget {
  const _SessionExpiredDialog({required this.onFinished});
  final VoidCallback onFinished;

  @override
  State<_SessionExpiredDialog> createState() => _SessionExpiredDialogState();
}

class _SessionExpiredDialogState extends State<_SessionExpiredDialog> {
  static const int _initialCountdown = 5;
  int _remaining = _initialCountdown;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      if (_remaining <= 1) {
        _timer?.cancel();
        widget.onFinished();
        return;
      }
      setState(() => _remaining--);
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Session expired'),
      content: Text(
        'Your token has expired. Please log in again.\n\n'
        'Returning to sign-in in $_remaining…',
      ),
      actions: [
        TextButton(
          onPressed: () {
            _timer?.cancel();
            widget.onFinished();
          },
          child: const Text('OK'),
        ),
      ],
    );
  }
}

class CurateringApp extends StatefulWidget {
  const CurateringApp({super.key, this.savedThemeMode, this.forcePosLogin = false});

  /// `'light'` / `'dark'` from [SharedPreferences]; default is light.
  final String? savedThemeMode;
  final bool forcePosLogin;

  @override
  State<CurateringApp> createState() => _CurateringAppState();
}

class _CurateringAppState extends State<CurateringApp> with WidgetsBindingObserver {
  late final AppState appState;
  final GlobalKey<NavigatorState> _rootNavKey = GlobalKey<NavigatorState>();
  Timer? _backgroundLogoutTimer;
  Timer? _inactivityLogoutTimer;
  static const Duration _inactivityLogoutAfter = Duration(minutes: 10);
  /// Customer-only: prompt when payment confirmation still pending after 10 minutes.
  Timer? _paymentStallTimer;
  String? _paymentWatchEmail;
  final Set<String> _stallPromptedOrderNos = <String>{};
  Timer? _customerNotifPollTimer;
  Timer? _realtimeSyncTimer;
  final Set<String> _lastAttentionOrderSnapshot = <String>{};

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    appState = AppState(savedThemeMode: widget.savedThemeMode);
    _armInactivityLogoutTimer();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _backgroundLogoutTimer?.cancel();
    _inactivityLogoutTimer?.cancel();
    _paymentStallTimer?.cancel();
    _customerNotifPollTimer?.cancel();
    _realtimeSyncTimer?.cancel();
    super.dispose();
  }

  void _armInactivityLogoutTimer() {
    _inactivityLogoutTimer?.cancel();
    _inactivityLogoutTimer = Timer(_inactivityLogoutAfter, _logoutForInactivity);
  }

  void _onUserActivity() {
    if (appState.userEmail != null) {
      _armInactivityLogoutTimer();
    }
  }

  void _logoutForInactivity() {
    if (!mounted || appState.userEmail == null) return;
    _showSessionExpiredOnRoot();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _backgroundLogoutTimer?.cancel();
      _backgroundLogoutTimer = null;
      _onUserActivity();
      if (appState.userEmail != null && appState.userRole == 'customer') {
        _pollCustomerAttentionNotifications();
      }
      return;
    }
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.inactive ||
        state == AppLifecycleState.detached) {
      _backgroundLogoutTimer?.cancel();
      _backgroundLogoutTimer = Timer(_inactivityLogoutAfter, _logoutForInactivity);
    }
  }

  Future<void> _pollCustomerAttentionNotifications() async {
    if (appState.userEmail == null || appState.userRole != 'customer') return;
    await appState.loadNotifications(force: true);
    if (!mounted) return;
    final next = appState.orderNosWithUnreadAttention;
    if (_lastAttentionOrderSnapshot.isEmpty) {
      _lastAttentionOrderSnapshot.addAll(next);
      return;
    }
    for (final id in next) {
      if (!_lastAttentionOrderSnapshot.contains(id)) {
        await showCashierReviewReminderIfNew(id);
      }
    }
    _lastAttentionOrderSnapshot
      ..clear()
      ..addAll(next);
  }

  void _showSessionExpiredOnRoot() {
    final navCtx = _rootNavKey.currentContext;
    if (navCtx == null) return;
    showDialog<void>(
      context: navCtx,
      barrierDismissible: false,
      builder: (ctx) => _SessionExpiredDialog(
        onFinished: () {
          if (Navigator.of(ctx).canPop()) {
            Navigator.of(ctx).pop();
          }
          final nav = _rootNavKey.currentState;
          while (nav != null && nav.canPop()) {
            nav.pop();
          }
          appState.logout();
        },
      ),
    );
  }

  void _tickPaymentStallWatchdog() {
    if (!mounted || appState.userEmail == null || appState.userRole != 'customer') return;
    final now = DateTime.now();
    for (final o in appState.orders) {
      if (!customerOrderPendingTab(o)) continue;
      if (now.difference(o.createdAt) <= const Duration(minutes: 10)) continue;
      if (_stallPromptedOrderNos.contains(o.orderNo)) continue;
      _stallPromptedOrderNos.add(o.orderNo);
      final navCtx = _rootNavKey.currentContext;
      if (navCtx == null || !navCtx.mounted) return;
      showDialog<void>(
        context: navCtx,
        barrierDismissible: false,
        builder: (ctx) => AlertDialog(
          title: Text(o.orderNo),
          content: const Text(
            'This order is still waiting for payment confirmation after 10 minutes. '
            'Would you like to cancel it, or keep waiting? You can follow up from My Orders.',
          ),
          actions: [
            TextButton(
              onPressed: () {
                Navigator.of(ctx).pop();
                showDialog<void>(
                  context: navCtx,
                  builder: (confirmCtx) => AlertDialog(
                    title: const Text('Cancel order?'),
                    content: Text(
                      'Cancel ${o.orderNo}? It will move to Cancelled orders.',
                    ),
                    actions: [
                      TextButton(onPressed: () => Navigator.of(confirmCtx).pop(), child: const Text('No')),
                      FilledButton(
                        onPressed: () async {
                          Navigator.of(confirmCtx).pop();
                          final err = await appState.cancelOrderAsCustomer(orderId: o.id);
                          if (!navCtx.mounted) return;
                          if (err != null) {
                            ScaffoldMessenger.of(navCtx).showSnackBar(SnackBar(content: Text(err)));
                          } else {
                            ScaffoldMessenger.of(navCtx).showSnackBar(
                              SnackBar(content: Text('${o.orderNo} cancelled')),
                            );
                          }
                        },
                        child: const Text('Yes, cancel'),
                      ),
                    ],
                  ),
                );
              },
              child: const Text('Cancel order'),
            ),
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('Keep waiting'),
            ),
          ],
        ),
      );
      break;
    }
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: appState,
      builder: (context, _) {
        final email = appState.userEmail;
        if (email == null) {
          _backgroundLogoutTimer?.cancel();
          _backgroundLogoutTimer = null;
          _inactivityLogoutTimer?.cancel();
        } else if (_inactivityLogoutTimer == null || !_inactivityLogoutTimer!.isActive) {
          _armInactivityLogoutTimer();
        }

        if (email == null) {
          _paymentStallTimer?.cancel();
          _paymentStallTimer = null;
          _paymentWatchEmail = null;
          _stallPromptedOrderNos.clear();
          _customerNotifPollTimer?.cancel();
          _customerNotifPollTimer = null;
          _realtimeSyncTimer?.cancel();
          _realtimeSyncTimer = null;
          _lastAttentionOrderSnapshot.clear();
        } else if (appState.userRole == 'customer' && email != _paymentWatchEmail) {
          _paymentWatchEmail = email;
          _paymentStallTimer?.cancel();
          _stallPromptedOrderNos.clear();
          _paymentStallTimer = Timer.periodic(const Duration(seconds: 40), (_) => _tickPaymentStallWatchdog());
          _customerNotifPollTimer?.cancel();
          _lastAttentionOrderSnapshot.clear();
          _customerNotifPollTimer = Timer.periodic(const Duration(seconds: 90), (_) => _pollCustomerAttentionNotifications());
          WidgetsBinding.instance.addPostFrameCallback((_) => _pollCustomerAttentionNotifications());
        }
        if (email != null && (_realtimeSyncTimer == null || !_realtimeSyncTimer!.isActive)) {
          _realtimeSyncTimer?.cancel();
          _realtimeSyncTimer = Timer.periodic(const Duration(seconds: 6), (_) => appState.pollRealtimeSync());
        }

        return MaterialApp(
          key: ValueKey(appState.authSessionKey),
          navigatorKey: _rootNavKey,
          debugShowCheckedModeBanner: false,
          title: widget.forcePosLogin
              ? "Macrina's Kitchen and Catering Management"
              : "Macrina's Kitchen and Catering",
          theme: buildAppLightTheme(),
          darkTheme: buildAppDarkTheme(),
          themeMode: appState.themeMode,
          builder: (context, child) => Listener(
            behavior: HitTestBehavior.translucent,
            onPointerDown: (_) => _onUserActivity(),
            onPointerMove: (_) => _onUserActivity(),
            onPointerSignal: (_) => _onUserActivity(),
            child: child ?? const SizedBox.shrink(),
          ),
          home: appState.userEmail == null
              ? AuthScreen(
                  key: ValueKey(appState.authSessionKey),
                  state: appState,
                  cashierMode: widget.forcePosLogin || kPosLoginBuild,
                )
              : _PostLoginWelcomeScope(
                  state: appState,
                  child: appState.isCashier
                      ? PosShellScreen(state: appState)
                      : appState.isManagerOrSupervisor
                          ? ManagerDashboardScreen(state: appState)
                          : CustomerDashboardScreen(state: appState),
                ),
        );
      },
    );
  }
}

class _PostLoginWelcomeScope extends StatefulWidget {
  const _PostLoginWelcomeScope({required this.state, required this.child});
  final AppState state;
  final Widget child;

  @override
  State<_PostLoginWelcomeScope> createState() => _PostLoginWelcomeScopeState();
}

class _PostLoginWelcomeScopeState extends State<_PostLoginWelcomeScope> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _maybeShowWelcome());
  }

  @override
  void didUpdateWidget(covariant _PostLoginWelcomeScope oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.state.userEmail != widget.state.userEmail) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _maybeShowWelcome());
    }
  }

  void _maybeShowWelcome() {
    final s = widget.state;
    if (!s.showLoginWelcomeDialog || !mounted) return;
    s.clearLoginWelcomeFlag();
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Signed in'),
        content: Text(
          s.isCashier
              ? "You've successfully signed in as cashier. A login notice was sent to your email."
              : "You've successfully signed in. A login notice was sent to your email.",
        ),
        actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('OK'))],
      ),
    );
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

const Duration _apiTimeout = Duration(seconds: 30);
/// Manager catering list can return many rows; allow a longer read than generic APIs.
const Duration _managerCateringListTimeout = Duration(seconds: 120);

/// Local Node backend is HTTP-only; [https] to these hosts breaks TLS handshakes.
bool _devBackendHttpHost(String host) {
  final h = host.toLowerCase();
  if (h == 'localhost' || h == '127.0.0.1' || h == '10.0.2.2') return true;
  if (h.startsWith('192.168.')) return true;
  return false;
}

/// Postgres / JSON sometimes returns numbers as strings — never cast blindly with `as num`.
int jsonToInt(dynamic v, [int fallback = 0]) {
  if (v == null) return fallback;
  if (v is int) return v;
  if (v is num) return v.toInt();
  return int.tryParse(v.toString().trim()) ?? fallback;
}

double jsonToDouble(dynamic v, [double fallback = 0]) {
  if (v == null) return fallback;
  if (v is double) return v;
  if (v is int) return v.toDouble();
  if (v is num) return v.toDouble();
  return double.tryParse(v.toString().trim()) ?? fallback;
}

bool jsonToBool(dynamic v) {
  if (v == null) return false;
  if (v is bool) return v;
  final s = v.toString().toLowerCase().trim();
  return s == 'true' || s == 't' || s == '1' || s == 'yes';
}

DateTime jsonToDateTime(dynamic v, DateTime fallback) {
  if (v == null) return fallback;
  try {
    return DateTime.parse(v.toString());
  } catch (_) {
    return fallback;
  }
}

DateTime? jsonTryDateTime(dynamic v) {
  if (v == null) return null;
  try {
    return DateTime.parse(v.toString());
  } catch (_) {
    return null;
  }
}

String formatDateTimeLocal(DateTime dt) {
  final l = dt.toLocal();
  return '${l.year}-${l.month.toString().padLeft(2, '0')}-${l.day.toString().padLeft(2, '0')} '
      '${l.hour.toString().padLeft(2, '0')}:${l.minute.toString().padLeft(2, '0')}';
}

String managerEventSettingDisplayLabel(String raw) {
  final t = raw.trim().toLowerCase();
  if (t == 'closed') return 'Closed space';
  if (t == 'open') return 'Open space';
  if (t.isEmpty) return '';
  return raw.trim();
}

String managerStageListTimestampLabel(String stage) {
  switch (stage) {
    case 'for_processing':
      return 'In For Processing since';
    case 'for_post_analysis':
      return 'In For Full Payment since';
    case 'completed':
      return 'Last updated';
    default:
      return 'Stage entered';
  }
}

dynamic _unwrapCateringMenuItem(dynamic m) {
  var cur = m;
  for (var i = 0; i < 8; i++) {
    if (cur is String) {
      final t = cur.trim();
      if (t.startsWith('[')) {
        try {
          cur = jsonDecode(t);
          continue;
        } catch (_) {}
      }
      if (t.startsWith('{')) {
        try {
          cur = jsonDecode(t);
          continue;
        } catch (_) {}
      }
      return t;
    }
    if (cur is List) {
      if (cur.isEmpty) return '';
      cur = cur.first;
      continue;
    }
    break;
  }
  return cur;
}

String dishNameFromCateringMenuEntry(dynamic m) {
  dynamic cur = m;
  for (var depth = 0; depth < 14; depth++) {
    final u = _unwrapCateringMenuItem(cur);
    if (u is Map) {
      final n = '${u['name'] ?? u['item_name'] ?? u['dish'] ?? u['dishName'] ?? ''}'.trim();
      if (n.isNotEmpty) return n;
    }
    var raw = u.toString().trim();
    if (raw.isEmpty) return '';
    if (raw.startsWith('[') || (raw.startsWith('{') && raw.contains('"name"'))) {
      try {
        final j = jsonDecode(raw);
        cur = j;
        continue;
      } catch (_) {}
    }
    if (raw.startsWith('"') && raw.endsWith('"') && raw.length >= 2) {
      cur = raw.substring(1, raw.length - 1);
      continue;
    }
    final lb = raw.indexOf('{');
    if (lb != -1 && raw.contains('"name"')) {
      try {
        cur = jsonDecode(raw.substring(lb));
        continue;
      } catch (_) {}
    }
    if (raw.startsWith('[')) {
      raw = raw.replaceAll('[', '').replaceAll(']', '').trim();
    }
    return raw;
  }
  return '$m'.trim();
}

/// Normalizes `selected_dishes` / `menu` from API (list, JSON string, or mixed).
List<String> inquirySelectedDishLabels(dynamic sd) {
  if (sd == null) return [];
  if (sd is Map) {
    final one = dishNameFromCateringMenuEntry(sd);
    return one.isEmpty ? [] : [one];
  }
  if (sd is List) {
    final list = normalizeCateringMenuList(List<dynamic>.from(sd));
    return list.map(dishNameFromCateringMenuEntry).where((s) => s.trim().isNotEmpty).toList();
  }
  if (sd is String) {
    final t = sd.trim();
    if (t.isEmpty) return [];
    try {
      final j = jsonDecode(t);
      return inquirySelectedDishLabels(j);
    } catch (_) {
      return [dishNameFromCateringMenuEntry(t)];
    }
  }
  return [dishNameFromCateringMenuEntry(sd)];
}

String? imageBase64FromCateringMenuEntry(dynamic m) {
  final u = _unwrapCateringMenuItem(m);
  if (u is Map) {
    final img = u['image_base64'];
    if (img != null && '$img'.trim().isNotEmpty) return '$img';
  }
  return null;
}

List<dynamic> normalizeCateringMenuList(List<dynamic> menu) {
  if (menu.length == 1 && menu.first is String) {
    final t = (menu.first as String).trim();
    if (t.startsWith('[')) {
      try {
        final j = jsonDecode(t);
        if (j is List<dynamic>) return j;
      } catch (_) {}
    }
  }
  return menu;
}

String formatScheduleSlotLine(dynamic s) {
  if (s is String) {
    final t = s.trim();
    if (t.startsWith('[') || t.startsWith('{')) {
      try {
        return formatScheduleSlotLine(jsonDecode(t));
      } catch (_) {}
    }
    return t;
  }
  if (s is Map) {
    final label = s['label'];
    if (label != null && '$label'.trim().isNotEmpty) return '$label'.trim();
    final date = s['date'];
    final from = s['from'];
    final to = s['to'];
    if (date != null && from != null && to != null) return '$date  $from – $to';
    if (date != null) return '$date';
  }
  if (s is List) {
    return s.map((e) => formatScheduleSlotLine(e)).where((x) => x.trim().isNotEmpty).join('\n');
  }
  return s.toString();
}

/// OpenStreetMap Nominatim requires a descriptive User-Agent.
const String kNominatimUserAgent = 'CurateringMobile/1.0 (support@macrina.local)';

/// Single API root for release apps — **no UI**. Configure one of:
/// - `flutter build ... --dart-define=DEFAULT_API_BASE=https://api.example.com` (recommended for CI/release)
/// - Set [kProductionApiBase] below for a fixed URL in source (optional)
/// - `flutter run ... --dart-define=API_BASE=http://192.168.x.x:8080` for local dev only
///
/// Resolution order: `API_BASE` → `DEFAULT_API_BASE` → [kProductionApiBase] → localhost (dev/emulator).
const String kProductionApiBase = '';

String resolveInitialApiBase() {
  const env = String.fromEnvironment('API_BASE', defaultValue: '');
  if (env.isNotEmpty) {
    return normalizeApiBase(env);
  }
  const bakedDefault = String.fromEnvironment('DEFAULT_API_BASE', defaultValue: '');
  if (bakedDefault.isNotEmpty) {
    return normalizeApiBase(bakedDefault);
  }
  final fixed = kProductionApiBase.trim();
  if (fixed.isNotEmpty) {
    return normalizeApiBase(fixed);
  }
  return 'http://localhost:8080';
}

String normalizeApiBase(String raw) {
  var v = raw.trim().replaceAll(RegExp(r'/+$'), '');
  final uri = Uri.tryParse(v);
  if (uri != null &&
      uri.hasScheme &&
      uri.scheme == 'https' &&
      _devBackendHttpHost(uri.host)) {
    return uri.replace(scheme: 'http').toString();
  }
  return v;
}

String describeApiNetworkError(Object error, String apiBase) {
  final base = normalizeApiBase(apiBase);
  if (error is TimeoutException) {
    return 'Request timed out — is the backend running at $base?';
  }
  final s = error.toString();
  if (s.contains('SocketException') ||
      s.contains('ClientException') ||
      s.contains('Failed host lookup') ||
      s.contains('Connection refused')) {
    var extra = '';
    if (base.contains('localhost') || base.contains('127.0.0.1')) {
      extra =
          ' On a real phone, do not use localhost — use your PC Wi-Fi IP, e.g. http://192.168.1.50:8080.';
    }
    if (base.contains('10.0.2.2')) {
      extra =
          ' 10.0.2.2 only works on Android emulator. On a physical phone use your PC IP (ipconfig IPv4), e.g. http://192.168.1.50:8080.';
    }
    return 'Cannot reach server at $base — check API URL.$extra';
  }
  return 'Something went wrong: $error';
}

void appSnack(BuildContext context, String message) {
  if (!context.mounted) return;
  ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
}

const int kMinCateringOnlyPax = 10;
const int kMinCateringEventPax = 50;
const double kPesosPerPax = 500;
/// Catering/event loyalty (matches backend `loyalty-calculation` thresholds).
const double kCateringLoyaltyMinOrderTotal = 500;
const int kCateringLoyaltyPointsAward = 8;

class AppColors {
  static const brand = Color(0xFFFFC233);
  static const canvas = Color(0xFFF1F1F1);
  static const accent = Color(0xFFEE4B3C);
  static const border = Color(0xFF9B8F82);
  static const success = Color(0xFF2FCB76);
  static const ink = Color(0xFF201B16);
}

/// Customer inquiry + manager new-event dropdown (display labels).
const List<String> kMobileEventTypeChoices = [
  'Birthday',
  'Wedding',
  'Baptism',
  'Corporate',
  'Sports',
  'Government',
  'Social event',
  'Reunion',
  'Gala',
  'Other',
];

class MenuItemData {
  const MenuItemData({
    required this.id,
    required this.name,
    required this.description,
    required this.price,
    required this.dips,
    this.ingredients = const [],
    this.category = '',
    this.dishType = '',
    this.imageBase64,
  });

  final String id;
  final String name;
  final String description;
  final double price;
  final List<String> dips;
  final List<String> ingredients;
  final String category;
  /// From `menu_dishes.type` when exposed by the API (`dish_type`).
  final String dishType;
  final String? imageBase64;

  /// Matches customer Restaurant tab: tag `restaurant` or subcategories (rice meals, silog, pasta, etc.).
  bool get isRestaurantDish {
    final c = category.toLowerCase().trim();
    if (c == 'catering' || c.isEmpty) return false;
    if (c == 'restaurant' || c == 'others') return true;
    if (c.contains('rice')) return true;
    if (c.contains('silog')) return true;
    if (c.contains('pasta')) return true;
    if (c.contains('sandwich')) return true;
    if (c.contains('drink') || c.contains('beverage')) return true;
    return false;
  }

  /// Bucket for filtering when `dish_type` is empty (legacy heuristic from category).
  String get restaurantMenuBucket {
    final t = dishType.trim().toLowerCase();
    if (t == 'other' || t == 'special') return 'others';
    if (t.isNotEmpty) return t;
    final c = category.toLowerCase().trim();
    if (c.contains('drink') || c.contains('beverage')) return 'drinks';
    if (c.contains('sandwich')) return 'sandwiches';
    if (c.contains('pasta')) return 'pasta';
    if (c.contains('silog')) return 'silog meals';
    if (c.contains('rice')) return 'rice meals';
    return 'others';
  }

  /// Stable section key for chips and grouping (lowercase).
  String get restaurantSectionKey => restaurantMenuBucket;

  /// Heading text when grouping by type (preserve DB casing when type is set).
  String get restaurantSectionLabel {
    final tl = dishType.trim().toLowerCase();
    if (tl == 'restaurant') return 'Menu';
    if (tl == 'other' || tl == 'special') return 'Others';
    final t = dishType.trim();
    if (t.isNotEmpty) return t;
    switch (restaurantMenuBucket) {
      case 'rice meals':
        return 'Rice meals';
      case 'silog meals':
        return 'Silog meals';
      case 'pasta':
        return 'Pasta';
      case 'sandwiches':
        return 'Sandwiches';
      case 'drinks':
        return 'Drinks';
      default:
        return 'Others';
    }
  }

  bool get isCateringDish {
    final c = category.toLowerCase().trim();
    return c == 'catering' || c.isEmpty;
  }
}

class CartItem {
  CartItem({
    required this.menu,
    this.dip = '',
    this.qty = 1,
  });

  final MenuItemData menu;
  String dip;
  int qty;
}

class ProfileData {
  ProfileData({
    this.fullName = '',
    this.contactNumber = '',
    this.deliveryAddress = '',
    this.deliveryMapConfirmed = false,
    this.deliveryLat,
    this.deliveryLng,
    this.loyaltyPoints = 0,
    this.loyaltyPointsRestaurant = 0,
    this.loyaltyPointsCatering = 0,
    this.deliveryAddresses = const [],
  });

  String fullName;
  String contactNumber;
  String deliveryAddress;
  bool deliveryMapConfirmed;
  double? deliveryLat;
  double? deliveryLng;
  int loyaltyPoints;
  int loyaltyPointsRestaurant;
  int loyaltyPointsCatering;
  List<String> deliveryAddresses;
}

class LoyaltyHistoryItem {
  LoyaltyHistoryItem({
    required this.orderNo,
    required this.pointsDelta,
    required this.createdAt,
    this.source = 'restaurant',
  });
  final String orderNo;
  final int pointsDelta;
  final DateTime createdAt;
  /// `restaurant` (mobile/POS) vs `catering` (completed events).
  final String source;
}

class OrderLineItem {
  OrderLineItem({
    required this.itemName,
    required this.dip,
    required this.qty,
    required this.price,
  });

  final String itemName;
  final String dip;
  final int qty;
  final double price;
}

/// Builds line items from API `items` or fallback JSON snapshot on the order row.
List<OrderLineItem> orderLinesFromApiMap(Map<String, dynamic> map) {
  final out = <OrderLineItem>[];
  void addFrom(dynamic raw) {
    if (raw == null || raw is! List) return;
    for (final e in raw) {
      if (e is! Map) continue;
      final m = Map<String, dynamic>.from(e);
      out.add(
        OrderLineItem(
          itemName: '${m['item_name'] ?? m['itemName'] ?? ''}',
          dip: '${m['dip'] ?? ''}',
          qty: jsonToInt(m['qty'], 0),
          price: jsonToDouble(m['price']),
        ),
      );
    }
  }

  addFrom(map['items']);
  if (out.isEmpty) {
    addFrom(map['order_lines_snapshot']);
  }
  return out;
}

class OrderData {
  OrderData({
    required this.id,
    required this.orderNo,
    required this.status,
    required this.total,
    required this.createdAt,
    this.updatedAt,
    this.paymentUploaded = false,
    this.paymentProofBase64,
    this.lines = const [],
    this.userEmail,
    this.note = '',
    this.paymentMode = '',
    this.deliveryName = '',
    this.deliveryContact = '',
    this.deliveryAddress = '',
    this.deliveryTime = '',
    this.orderSource = 'MOBILE_APP',
    this.posCustomerLabel = '',
    this.cashierAmountReceived,
    this.cashierChange,
    this.fulfillmentStage = 'PENDING_CASHIER',
    this.deliveryTrackingUrl = '',
    this.supplementalPaymentProofBase64,
    this.cashierSecondaryAmountReceived,
    this.balanceProofPendingReview = false,
    this.customerDisplayName,
    this.loyaltyPointsEarned = 0,
  });

  final int id;
  final String orderNo;
  final String status;
  final double total;
  final DateTime createdAt;
  /// Last server update (e.g. walk-in claimed).
  final DateTime? updatedAt;
  final bool paymentUploaded;
  /// Raw proof image from API (same field stored by backend); may be large.
  final String? paymentProofBase64;
  final List<OrderLineItem> lines;
  final String? userEmail;
  final String note;
  final String paymentMode;
  final String deliveryName;
  final String deliveryContact;
  final String deliveryAddress;
  final String deliveryTime;
  final String orderSource;
  final String posCustomerLabel;
  final double? cashierAmountReceived;
  final double? cashierChange;
  /// Backend: PENDING_CASHIER | IN_PREPARATION | OUT_FOR_DELIVERY | DELIVERED
  final String fulfillmentStage;
  final String deliveryTrackingUrl;
  /// Additional GCash proof after insufficient payment (backend).
  final String? supplementalPaymentProofBase64;
  final double? cashierSecondaryAmountReceived;
  /// Cashier must review supplemental proof + enter amount.
  final bool balanceProofPendingReview;
  /// Resolved customer name for cashier lists (from customer_profiles join).
  final String? customerDisplayName;
  /// Points earned for this order once confirmed (floor of total); from API `loyalty_points_earned`.
  final int loyaltyPointsEarned;
}

OrderData orderDataFromApiMap(Map<String, dynamic> map, List<OrderLineItem> lines) {
  final proofRaw = map['payment_proof'];
  final proofStr = proofRaw != null ? '$proofRaw'.trim() : '';
  final supRaw = map['supplemental_payment_proof'];
  final supStr = supRaw != null ? '$supRaw'.trim() : '';
  return OrderData(
    id: jsonToInt(map['id']),
    orderNo: '${map['order_no']}',
    status: '${map['status']}',
    total: jsonToDouble(map['total']),
    createdAt: jsonToDateTime(map['created_at'], DateTime.now()),
    updatedAt: map['updated_at'] != null ? jsonToDateTime(map['updated_at'], DateTime.now()) : null,
    paymentUploaded: jsonToBool(map['payment_uploaded']),
    paymentProofBase64: proofStr.isNotEmpty ? proofStr : null,
    lines: lines,
    userEmail: map['user_email'] != null && '${map['user_email']}'.trim().isNotEmpty ? '${map['user_email']}' : null,
    note: '${map['note'] ?? ''}',
    paymentMode: '${map['payment_mode'] ?? ''}',
    deliveryName: '${map['delivery_name'] ?? ''}',
    deliveryContact: '${map['delivery_contact'] ?? ''}',
    deliveryAddress: '${map['delivery_address'] ?? ''}',
    deliveryTime: '${map['delivery_time'] ?? ''}',
    orderSource: '${map['order_source'] ?? 'MOBILE_APP'}',
    posCustomerLabel: '${map['pos_customer_label'] ?? ''}',
    cashierAmountReceived: map['cashier_amount_received'] != null ? jsonToDouble(map['cashier_amount_received']) : null,
    cashierChange: map['cashier_change'] != null ? jsonToDouble(map['cashier_change']) : null,
    fulfillmentStage: '${map['fulfillment_stage'] ?? 'PENDING_CASHIER'}'.trim(),
    deliveryTrackingUrl: '${map['delivery_tracking_url'] ?? ''}'.trim(),
    supplementalPaymentProofBase64: supStr.isNotEmpty ? supStr : null,
    cashierSecondaryAmountReceived:
        map['cashier_secondary_amount_received'] != null ? jsonToDouble(map['cashier_secondary_amount_received']) : null,
    balanceProofPendingReview: jsonToBool(map['balance_proof_pending_review']),
    customerDisplayName: () {
      final v = map['customer_display_name'];
      if (v == null) return null;
      final s = '$v'.trim();
      return s.isEmpty ? null : s;
    }(),
    loyaltyPointsEarned: jsonToInt(map['loyalty_points_earned']),
  );
}

String cashierCustomerLabel(OrderData o) {
  final n = o.customerDisplayName?.trim();
  if (n != null && n.isNotEmpty) return n;
  final dn = o.deliveryName.trim();
  if (dn.isNotEmpty) return dn;
  return o.userEmail ?? '—';
}

bool orderLooksCompleted(OrderData o) {
  if (o.fulfillmentStage.toUpperCase() == 'DELIVERED') return true;
  final u = o.status.toUpperCase();
  return u.contains('COMPLETE') ||
      u.contains('DELIVERED') ||
      u.contains('DONE') ||
      u.contains('CLOSED');
}

bool customerOrderCancelled(OrderData o) {
  final u = o.status.toUpperCase();
  return u.contains('CANCEL');
}

bool customerOrderPendingTab(OrderData o) {
  if (customerOrderCancelled(o)) return false;
  if (orderLooksCompleted(o)) return false;
  final u = o.status.toUpperCase();
  return u.contains('WAITING FOR PAYMENT CONFIRMATION') ||
      u.contains('WAITING FOR BALANCE PAYMENT CONFIRMATION') ||
      u.contains('WAITING FOR ORDER CONFIRMATION') ||
      u.contains('WAITING FOR ORDER') ||
      u.contains('PAYMENT INSUFFICIENT') ||
      u.contains('INSUFFICIENT');
}

bool customerOrderConfirmedTab(OrderData o) {
  if (orderLooksCompleted(o) || customerOrderCancelled(o)) return false;
  return !customerOrderPendingTab(o);
}

String fulfillmentStageReadable(String stage) {
  switch (stage.toUpperCase()) {
    case 'PENDING_CASHIER':
      return 'Pending cashier review';
    case 'IN_PREPARATION':
      return 'Preparing your order';
    case 'OUT_FOR_DELIVERY':
      return 'Out for delivery';
    case 'DELIVERED':
      return 'Delivered';
    default:
      return stage;
  }
}

String statusReadable(String status) {
  final up = status.toUpperCase();
  if (up.contains('WAITING FOR BALANCE PAYMENT CONFIRMATION')) return 'WAITING FOR BALANCE PAYMENT CONFIRMATION';
  if (up.contains('WAITING FOR ORDER CONFIRMATION')) return 'WAITING FOR PAYMENT CONFIRMATION';
  if (up.contains('ORDER CONFIRMED')) return status.replaceAll(RegExp('ORDER CONFIRMED', caseSensitive: false), 'PAYMENT CONFIRMED');
  if (up.contains('PAYMENT INSUFFICIENT')) {
    return 'PAYMENT INSUFFICIENT - PAY REMAINDER';
  }
  return status;
}

String statusReadableForOrder(OrderData o) {
  final up = o.status.toUpperCase();
  final hasBalanceProof = (o.supplementalPaymentProofBase64?.trim().isNotEmpty ?? false) || o.balanceProofPendingReview;
  if (hasBalanceProof && up.contains('WAITING FOR PAYMENT CONFIRMATION')) {
    return 'WAITING FOR BALANCE PAYMENT CONFIRMATION';
  }
  return statusReadable(o.status);
}

String inquiryStatusReadable(String status) {
  final s = status.trim();
  if (s.isEmpty) return s;
  final low = s.toLowerCase();
  switch (low) {
    case 'new_event':
      return 'New Event';
    case 'online_inquiries':
      return 'Online Inquiries';
    case 'for_processing':
      return 'For Processing';
    case 'for_post_analysis':
      return 'For Full Payment';
    default:
      return s
          .replaceAll('_', ' ')
          .split(' ')
          .where((w) => w.trim().isNotEmpty)
          .map((w) => '${w[0].toUpperCase()}${w.substring(1).toLowerCase()}')
          .join(' ');
  }
}

void showProofFullScreen(BuildContext context, Uint8List bytes, {String title = 'Payment proof'}) {
  showDialog<void>(
    context: context,
    builder: (ctx) => Dialog(
      insetPadding: const EdgeInsets.all(12),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ListTile(
            title: Text(title),
            trailing: IconButton(onPressed: () => Navigator.pop(ctx), icon: const Icon(Icons.close)),
          ),
          Flexible(
            child: InteractiveViewer(
              minScale: 0.6,
              maxScale: 4,
              child: Image.memory(bytes, fit: BoxFit.contain),
            ),
          ),
        ],
      ),
    ),
  );
}

class InquiryRecord {
  InquiryRecord({
    required this.id,
    required this.inquiryNo,
    required this.inquiryType,
    required this.eventTitle,
    required this.eventType,
    required this.customer,
    required this.contactPerson,
    required this.contactNumber,
    required this.inquiryEmail,
    required this.dateOfEvent,
    required this.note,
    required this.curateOwnMenu,
    required this.selectedSetMenu,
    required this.selectedDishes,
    required this.includeEventTheme,
    required this.guestCount,
    required this.menuSuggestionNote,
    required this.themeSuggestionNote,
    required this.estimatedTotal,
    required this.status,
    required this.createdAt,
    this.eventCity = '',
    this.eventSetting = '',
    this.serviceIncluded = '',
    this.formalityLevel = '',
    this.foodTastingRequested = false,
    this.loyaltyPointsEarned = 0,
    this.transactionNo = '',
    this.downPaymentAmount = 0,
    this.fullPaymentAmount = 0,
  });

  final int id;
  final String inquiryNo;
  /// From `event_orders` / `catering_orders` when set.
  final String transactionNo;
  final String inquiryType;
  final String eventTitle;
  final String eventType;
  final String customer;
  final String contactPerson;
  final String contactNumber;
  final String inquiryEmail;
  final String dateOfEvent;
  final String note;
  final bool curateOwnMenu;
  final String selectedSetMenu;
  final List<String> selectedDishes;
  final bool includeEventTheme;
  final int guestCount;
  final String menuSuggestionNote;
  final String themeSuggestionNote;
  final double estimatedTotal;
  final String status;
  final DateTime createdAt;
  final String eventCity;
  final String eventSetting;
  final String serviceIncluded;
  final String formalityLevel;
  final bool foodTastingRequested;
  /// Estimated loyalty points for completed catering/event (matches backend floor of total cost).
  final int loyaltyPointsEarned;
  /// From catering/event order row after down payment is recorded.
  final double downPaymentAmount;
  /// From catering/event order row (full payment toward balance).
  final double fullPaymentAmount;

  bool get isCompletedBooking {
    final s = status.trim().toLowerCase().replaceAll(RegExp(r'\s+'), '_').replaceAll('-', '_');
    return s == 'completed';
  }

  /// Primary label for lists (prefer DB transaction number).
  String get displayTransactionRef =>
      transactionNo.trim().isNotEmpty ? transactionNo.trim() : inquiryNo;

  bool get isWaiting {
    final s = status.trim().toLowerCase().replaceAll(RegExp(r'\s+'), '_').replaceAll('-', '_');
    const waiting = {
      'submitted',
      'pending',
      'online_inquiries',
      'online_inquiry',
      'new_event',
    };
    return waiting.contains(s);
  }
}

class SubmitOrderResult {
  SubmitOrderResult({this.order, this.error});
  final OrderData? order;
  final String? error;
}

class SetMenuData {
  SetMenuData({
    required this.name,
    required this.description,
    required this.dishes,
  });

  final String name;
  final String description;
  final List<String> dishes;
}

class CateringEventRecord {
  CateringEventRecord({
    required this.id,
    required this.orderKind,
    required this.status,
    required this.source,
    required this.customerName,
    required this.contactPerson,
    required this.contactNumber,
    required this.emailAddress,
    required this.address,
    required this.guestCount,
    required this.totalCost,
    required this.eventTitle,
    required this.eventType,
    required this.createdAt,
    required this.updatedAt,
    this.stageEnteredAt,
    this.transactionNo = '',
    this.paymentMethod = 'cash',
    this.costBreakdown = const [],
    this.laborCost = 0,
    this.travelCost = 0,
    this.additionalCosts = const [],
    this.downPaymentAmount = 0,
    this.downPaymentStatus = '',
    this.fullPaymentAmount = 0,
    this.fullPaymentStatus = '',
    this.postAnalysis = const {},
    this.checklist = const [],
    this.scheduleSlots = const [],
    this.menu = const [],
    this.themeDesign = const {},
    this.serviceIncluded = '',
    this.formalityLevel = '',
    this.eventSetting = '',
    this.schedulePreview = '',
    this.processingScheduleOverlaps = 0,
    this.cateringLoyaltyPointsEarned = 0,
  });
  final String id;
  final String orderKind;
  final String status;
  final String source;
  final String customerName;
  final String contactPerson;
  final String contactNumber;
  final String emailAddress;
  final String address;
  final int guestCount;
  final double totalCost;
  final String eventTitle;
  final String eventType;
  final DateTime createdAt;
  final DateTime updatedAt;
  final DateTime? stageEnteredAt;
  final String transactionNo;
  final String paymentMethod;
  final List<dynamic> costBreakdown;
  final double laborCost;
  final double travelCost;
  final List<dynamic> additionalCosts;
  final double downPaymentAmount;
  final String downPaymentStatus;
  final double fullPaymentAmount;
  final String fullPaymentStatus;
  final Map<String, dynamic> postAnalysis;
  final List<dynamic> checklist;
  final List<dynamic> scheduleSlots;
  final List<dynamic> menu;
  final Map<String, dynamic> themeDesign;
  final String serviceIncluded;
  final String formalityLevel;
  /// From `theme_design.event_setting` when list uses `summary: true`.
  final String eventSetting;
  /// Short date/time line from first `schedule_slots` entry (list summary).
  final String schedulePreview;
  /// For `for_processing` list: how many *other* active orders overlap this event's schedule.
  final int processingScheduleOverlaps;

  /// Points applied when this catering/event order is completed (from `points_earned` in DB).
  final int cateringLoyaltyPointsEarned;

  int get cateringLoyaltyEligiblePointsIfCompleted =>
      totalCost >= kCateringLoyaltyMinOrderTotal ? kCateringLoyaltyPointsAward : 0;

  factory CateringEventRecord.fromApiMap(Map<String, dynamic> m) {
    return CateringEventRecord(
      id: '${m['id']}',
      orderKind: '${m['order_kind'] ?? 'event'}',
      status: '${m['status'] ?? ''}',
      source: '${m['source'] ?? ''}',
      customerName: '${m['customer_name'] ?? ''}',
      contactPerson: '${m['contact_person'] ?? ''}',
      contactNumber: '${m['contact_number'] ?? ''}',
      emailAddress: '${m['email_address'] ?? ''}',
      address: '${m['address'] ?? ''}',
      guestCount: jsonToInt(m['guest_count']),
      totalCost: jsonToDouble(m['total_cost']),
      eventTitle: '${m['event_title'] ?? ''}',
      eventType: '${m['event_type'] ?? ''}',
      createdAt: jsonToDateTime(m['created_at'], DateTime.now()),
      updatedAt: jsonToDateTime(m['updated_at'], DateTime.now()),
      stageEnteredAt: jsonTryDateTime(m['stage_entered_at']),
      transactionNo: '${m['transaction_no'] ?? ''}',
      paymentMethod: '${m['payment_method'] ?? 'cash'}',
      costBreakdown: (m['cost_breakdown'] is List) ? (m['cost_breakdown'] as List<dynamic>) : const [],
      laborCost: jsonToDouble(m['labor_cost']),
      travelCost: jsonToDouble(m['travel_cost']),
      additionalCosts: (m['additional_costs'] is List) ? (m['additional_costs'] as List<dynamic>) : const [],
      downPaymentAmount: jsonToDouble(m['down_payment_amount']),
      downPaymentStatus: '${m['down_payment_status'] ?? ''}',
      fullPaymentAmount: jsonToDouble(m['full_payment_amount']),
      fullPaymentStatus: '${m['full_payment_status'] ?? ''}',
      postAnalysis: () {
        final pa = m['post_analysis'];
        if (pa is Map<String, dynamic>) return pa;
        if (pa is Map) return Map<String, dynamic>.from(pa.map((k, v) => MapEntry('$k', v)));
        return const <String, dynamic>{};
      }(),
      checklist: (m['checklist'] is List) ? (m['checklist'] as List<dynamic>) : const [],
      scheduleSlots: () {
        final raw = m['schedule_slots'];
        if (raw is List) return List<dynamic>.from(raw);
        if (raw is Map) return [raw];
        if (raw is String && raw.trim().isNotEmpty) {
          try {
            final j = jsonDecode(raw);
            if (j is List) return List<dynamic>.from(j);
            if (j is Map) return [j];
          } catch (_) {}
        }
        return <dynamic>[];
      }(),
      menu: () {
        final raw = m['menu'];
        if (raw is List) return List<dynamic>.from(raw);
        if (raw is String && raw.trim().startsWith('[')) {
          try {
            final j = jsonDecode(raw);
            if (j is List) return List<dynamic>.from(j);
          } catch (_) {}
        }
        return <dynamic>[];
      }(),
      themeDesign: () {
        final raw = m['theme_design'];
        if (raw is Map<String, dynamic>) return raw;
        if (raw is Map) {
          return Map<String, dynamic>.from(
            raw.map((key, value) => MapEntry(key.toString(), value)),
          );
        }
        if (raw is String && raw.trim().startsWith('{')) {
          try {
            final j = jsonDecode(raw);
            if (j is Map<String, dynamic>) return j;
            if (j is Map) {
              return Map<String, dynamic>.from(
                j.map((key, value) => MapEntry(key.toString(), value)),
              );
            }
          } catch (_) {}
        }
        return <String, dynamic>{};
      }(),
      serviceIncluded: '${m['service_included'] ?? ''}',
      formalityLevel: '${m['formality_level'] ?? ''}',
      eventSetting: '${m['event_setting'] ?? ''}',
      schedulePreview: '${m['schedule_preview'] ?? ''}',
      processingScheduleOverlaps: jsonToInt(m['processing_schedule_overlaps']),
      cateringLoyaltyPointsEarned: jsonToInt(m['points_earned']),
    );
  }
}

/// Full payment treated as confirmed when the manager sets [manager_full_payment_confirmed] or legacy cashier amounts match [totalComputed].
bool cateringFullPaymentConfirmed(CateringEventRecord r, double totalComputed) {
  if (r.postAnalysis['manager_full_payment_confirmed'] == true) return true;
  final fullPaymentStatus = r.fullPaymentStatus.trim().toLowerCase();
  final hasAmt = r.fullPaymentAmount > 0 && r.fullPaymentAmount >= totalComputed * 0.99;
  return hasAmt && (fullPaymentStatus.isEmpty || fullPaymentStatus == 'paid');
}

class AppState extends ChangeNotifier {
  AppState({String? savedThemeMode})
      : apiBase = resolveInitialApiBase(),
        themeMode = savedThemeMode == 'dark' ? ThemeMode.dark : ThemeMode.light;

  String apiBase;
  ThemeMode themeMode;
  String? userEmail;
  String loginPassword = '';
  ProfileData profile = ProfileData();
  final List<MenuItemData> menu = [];
  final List<CartItem> tray = [];
  final List<OrderData> orders = [];
  final List<InquiryRecord> inquiries = [];
  final List<SetMenuData> setMenus = [];
  String checkoutNote = '';
  /// Persists chosen delivery line for checkout when navigating away from [CheckoutScreen].
  String? checkoutSelectedAddress;
  /// Delivery schedule chosen at checkout ("NOW" or formatted datetime).
  String checkoutDeliveryTime = 'NOW';
  /// `customer`, `cashier`, `manager`, or `supervisor` from login API.
  String userRole = 'customer';
  String cashierDisplayName = '';
  final List<OrderData> cashierOnlineOrders = [];
  final List<OrderData> cashierOrderHistory = [];
  final List<OrderData> cashierWalkInPreparing = [];
  final List<OrderData> cashierWalkInComplete = [];
  final List<CateringEventRecord> managerCateringRows = [];
  final List<LoyaltyHistoryItem> loyaltyHistory = [];
  bool showLoginWelcomeDialog = false;
  /// Bumped on [logout] so [AuthScreen] state resets (fixes staff re-login without app restart).
  int authSessionKey = 0;
  int unreadNotificationsCount = 0;
  final Set<String> orderNosWithUnreadAttention = <String>{};
  final Set<String> _readAttentionOrderNos = <String>{};
  DateTime? _menuLoadedAt;
  Map<String, String>? _lastRealtimeStamps;
  bool _realtimePollInFlight = false;
  String _lastTrayServerStamp = '';
  String _lastRealtimeServerTime = '';
  DateTime? _ordersLoadedAt;
  DateTime? _inquiriesLoadedAt;
  DateTime? _profileLoadedAt;
  DateTime? _notificationsLoadedAt;
  final Set<String> _managerCateringInFlightStages = <String>{};
  final Map<String, DateTime> _managerCateringLoadedAt = <String, DateTime>{};
  String _managerActiveStage = 'new_event';
  bool _loadOrdersInFlight = false;
  bool _loadInquiriesInFlight = false;
  bool _loadProfileInFlight = false;
  bool _loadNotificationsInFlight = false;
  bool _loadCashierOnlineOrdersInFlight = false;
  bool _loadCashierWalkInQueuesInFlight = false;
  bool _loadCashierOrderHistoryInFlight = false;
  DateTime? _cashierOnlineOrdersLoadedAt;
  DateTime? _cashierWalkInQueuesLoadedAt;
  DateTime? _cashierOrderHistoryLoadedAt;
  bool _loadSetMenusInFlight = false;
  bool _loadLoyaltyHistoryInFlight = false;
  bool _loadMenuInFlight = false;
  DateTime? _setMenusLoadedAt;
  DateTime? _loyaltyHistoryLoadedAt;
  bool get hasCashierAttentionBadge => cashierOnlineOrders.any((o) => o.balanceProofPendingReview);
  bool get hasManagerAttentionBadge =>
      managerCateringRows.any((r) => r.status == 'new_event' || r.status == 'online_inquiries');
  bool get hasAnyAttentionBadge =>
      unreadNotificationsCount > 0 || hasCashierAttentionBadge || hasManagerAttentionBadge;

  bool get isCashier => userRole == 'cashier';
  bool get isManager => userRole == 'manager';
  bool get isManagerOrSupervisor => userRole == 'manager' || userRole == 'supervisor';

  String get managerActiveStage => _managerActiveStage;
  void setManagerActiveStage(String stage) {
    final next = stage.trim().toLowerCase();
    if (next.isEmpty || next == _managerActiveStage) return;
    _managerActiveStage = next;
  }

  void setThemeMode(ThemeMode mode) {
    if (themeMode == mode) return;
    themeMode = mode;
    notifyListeners();
    SharedPreferences.getInstance().then(
      (p) => p.setString('theme_mode', mode == ThemeMode.dark ? 'dark' : 'light'),
    );
  }

  void clearLoginWelcomeFlag() {
    showLoginWelcomeDialog = false;
  }

  /// Returns null on success, or an error message.
  Future<String?> login(String email, String password) async {
    try {
      final res = await http
          .post(
            _uri('/api/mobile/auth/login'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({'email': email.trim(), 'password': password}),
          )
          .timeout(_apiTimeout);
      if (res.statusCode != 200) {
        try {
          final err = jsonDecode(res.body) as Map<String, dynamic>;
          return '${err['error'] ?? 'Login failed'}';
        } catch (_) {
          return 'Login failed (${res.statusCode})';
        }
      }
      final bodyMap = jsonDecode(res.body) as Map<String, dynamic>;
      userEmail = email.trim().toLowerCase();
      loginPassword = password;
      userRole = '${bodyMap['role'] ?? 'customer'}'.trim().toLowerCase();
      cashierDisplayName = '${bodyMap['display_name'] ?? ''}'.trim();
      if (isCashier) {
        await loadMenu(force: true);
        await loadCashierOnlineOrders(force: true);
        await loadCashierWalkInQueues(force: true);
      } else if (isManagerOrSupervisor) {
        await Future.wait([
          loadMenu(force: true),
          loadSetMenus(force: true),
          loadManagerCateringByStage('new_event', force: true),
        ]);
      } else {
        await Future.wait([
          loadMenu(force: true),
          loadSetMenus(force: true),
          loadProfile(force: true),
          loadOrders(force: true),
          loadInquiries(force: true),
        ]);
        await _restoreReadAttentionOrderNos();
        await restoreCustomerDraftAfterLogin();
        await loadNotifications(force: true);
      }
      await bootstrapRealtimeSync();
      showLoginWelcomeDialog = true;
      notifyListeners();
      return null;
    } catch (e) {
      return describeApiNetworkError(e, normalizeApiBase(apiBase));
    }
  }

  /// Returns null on success.
  /// How many proposed windows overlap active For Processing orders (public API).
  Future<int> countCateringScheduleConflicts(List<Map<String, String>> windows) async {
    try {
      final res = await http
          .post(
            _uri('/api/mobile/catering/schedule-conflicts'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({'windows': windows}),
          )
          .timeout(_apiTimeout);
      if (res.statusCode != 200) return 0;
      final decoded = jsonDecode(res.body);
      if (decoded is! Map) return 0;
      final raw = decoded['conflict_window_count'];
      if (raw is int) return raw;
      if (raw is num) return raw.toInt();
      return 0;
    } catch (_) {
      return 0;
    }
  }

  Future<String?> requestSignupOtp(String email) async {
    try {
      final res = await http
          .post(
            _uri('/api/mobile/auth/signup/request-otp'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({'email': email.trim()}),
          )
          .timeout(_apiTimeout);
      if (res.statusCode != 200) {
        try {
          final err = jsonDecode(res.body) as Map<String, dynamic>;
          return '${err['error'] ?? 'Could not send code'}';
        } catch (_) {
          return 'Could not send code (${res.statusCode})';
        }
      }
      return null;
    } catch (e) {
      return describeApiNetworkError(e, normalizeApiBase(apiBase));
    }
  }

  /// Returns null on success.
  Future<String?> completeSignup({
    required String email,
    required String otp,
    required String password,
  }) async {
    try {
      final res = await http
          .post(
            _uri('/api/mobile/auth/signup/complete'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({
              'email': email.trim(),
              'otp': otp.trim(),
              'password': password,
            }),
          )
          .timeout(_apiTimeout);
      if (res.statusCode != 200) {
        try {
          final err = jsonDecode(res.body) as Map<String, dynamic>;
          return '${err['error'] ?? 'Signup failed'}';
        } catch (_) {
          return 'Signup failed (${res.statusCode})';
        }
      }
      return await login(email, password);
    } catch (e) {
      return describeApiNetworkError(e, normalizeApiBase(apiBase));
    }
  }

  Future<String?> requestPasswordReset({
    required String identity,
    required String channel,
    required String role,
  }) async {
    try {
      final res = await http
          .post(
            _uri('/api/mobile/auth/request-password-reset'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({
              'identity': identity.trim(),
              'channel': channel,
              'role': role,
            }),
          )
          .timeout(_apiTimeout);
      if (res.statusCode != 200) {
        try {
          final err = jsonDecode(res.body) as Map<String, dynamic>;
          return '${err['error'] ?? 'Could not request password reset'}';
        } catch (_) {
          return 'Could not request password reset (${res.statusCode})';
        }
      }
      return null;
    } catch (e) {
      return describeApiNetworkError(e, normalizeApiBase(apiBase));
    }
  }

  Future<String?> resetPasswordWithOtp({
    required String identity,
    required String otp,
    required String password,
    required String role,
  }) async {
    try {
      final res = await http
          .post(
            _uri('/api/mobile/auth/reset-password'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({
              'identity': identity.trim(),
              'otp': otp.trim(),
              'password': password,
              'role': role,
            }),
          )
          .timeout(_apiTimeout);
      if (res.statusCode != 200) {
        try {
          final err = jsonDecode(res.body) as Map<String, dynamic>;
          return '${err['error'] ?? 'Password reset failed'}';
        } catch (_) {
          return 'Password reset failed (${res.statusCode})';
        }
      }
      return null;
    } catch (e) {
      return describeApiNetworkError(e, normalizeApiBase(apiBase));
    }
  }

  Future<void> clearPersistedCustomerDraft() async {
    final e = userEmail?.toLowerCase();
    if (e == null) return;
    final p = await SharedPreferences.getInstance();
    await p.remove('customer_tray_v1_$e');
    await p.remove('customer_checkout_note_v1_$e');
    await p.remove('customer_checkout_addr_v1_$e');
    await p.remove('customer_checkout_time_v1_$e');
  }

  Future<void> restoreCustomerDraftAfterLogin() async {
    if (userEmail == null || userRole != 'customer') return;
    final prefs = await SharedPreferences.getInstance();
    final k = userEmail!.toLowerCase();
    checkoutNote = prefs.getString('customer_checkout_note_v1_$k') ?? checkoutNote;
    checkoutSelectedAddress = prefs.getString('customer_checkout_addr_v1_$k');
    checkoutDeliveryTime = prefs.getString('customer_checkout_time_v1_$k') ?? checkoutDeliveryTime;
    final raw = prefs.getString('customer_tray_v1_$k');
    if (raw != null && raw.isNotEmpty) {
      try {
        final list = jsonDecode(raw) as List<dynamic>;
        _applyTrayLinesSnapshot(list);
      } catch (_) {}
    } else {
      tray.clear();
    }
    await pullCustomerTrayDraftFromServer();
    notifyListeners();
  }

  Future<void> _persistCustomerTraySnapshot() async {
    if (userEmail == null || userRole != 'customer') return;
    final prefs = await SharedPreferences.getInstance();
    final k = userEmail!.toLowerCase();
    final lines = tray
        .map(
          (e) => <String, dynamic>{
            'id': e.menu.id,
            'dip': e.dip,
            'qty': e.qty,
          },
        )
        .toList();
    await prefs.setString('customer_tray_v1_$k', jsonEncode(lines));
    unawaited(_pushCustomerTrayDraftToServer(lines));
  }

  Future<void> _restoreReadAttentionOrderNos() async {
    if (userEmail == null || userRole != 'customer') return;
    try {
      final prefs = await SharedPreferences.getInstance();
      final key = userEmail!.toLowerCase();
      final saved = prefs.getStringList('customer_read_attention_orders_v1_$key') ?? const <String>[];
      _readAttentionOrderNos
        ..clear()
        ..addAll(saved.map((e) => e.trim()).where((e) => e.isNotEmpty));
    } catch (_) {}
  }

  Future<void> _persistReadAttentionOrderNos() async {
    if (userEmail == null || userRole != 'customer') return;
    try {
      final prefs = await SharedPreferences.getInstance();
      final key = userEmail!.toLowerCase();
      final list = _readAttentionOrderNos.toList()..sort();
      await prefs.setStringList('customer_read_attention_orders_v1_$key', list);
    } catch (_) {}
  }

  void _applyTrayLinesSnapshot(List<dynamic> list) {
    tray.clear();
    for (final e in list) {
      if (e is! Map) continue;
      final id = '${e['id']}';
      final dip = '${e['dip'] ?? ''}';
      final qty = jsonToInt(e['qty']);
      MenuItemData? foundItem;
      for (final x in menu) {
        if (x.id == id) {
          foundItem = x;
          break;
        }
      }
      if (foundItem != null && qty > 0) {
        tray.add(CartItem(menu: foundItem, dip: dip, qty: qty));
      }
    }
  }

  Future<void> _pushCustomerTrayDraftToServer(List<Map<String, dynamic>> lines) async {
    final email = userEmail;
    if (email == null || userRole != 'customer') return;
    try {
      final res = await http
          .put(
            _uri('/api/mobile/customer/tray-draft'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({'user_email': email, 'tray_lines': lines}),
          )
          .timeout(_apiTimeout);
      if (res.statusCode != 200) return;
      final body = jsonDecode(res.body);
      if (body is Map<String, dynamic>) {
        _lastTrayServerStamp = '${body['updated_at'] ?? ''}';
      }
    } catch (_) {}
  }

  Future<void> pullCustomerTrayDraftFromServer() async {
    final email = userEmail;
    if (email == null || userRole != 'customer') return;
    try {
      final res =
          await http.get(_uri('/api/mobile/customer/tray-draft', {'user_email': email})).timeout(_apiTimeout);
      if (res.statusCode != 200) return;
      final body = jsonDecode(res.body);
      if (body is! Map<String, dynamic>) return;
      final trayLines = body['tray_lines'];
      final updatedAt = '${body['updated_at'] ?? ''}';
      if (trayLines is! List) return;
      _applyTrayLinesSnapshot(trayLines);
      final prefs = await SharedPreferences.getInstance();
      final k = email.toLowerCase();
      await prefs.setString('customer_tray_v1_$k', jsonEncode(trayLines));
      _lastTrayServerStamp = updatedAt;
      notifyListeners();
    } catch (_) {}
  }

  void updateCheckoutDraftNote(String v) {
    checkoutNote = v;
    notifyListeners();
    final em = userEmail?.toLowerCase();
    if (userRole != 'customer' || em == null) return;
    SharedPreferences.getInstance().then((p) => p.setString('customer_checkout_note_v1_$em', v));
  }

  void updateCheckoutDraftAddress(String? v) {
    checkoutSelectedAddress = v;
    notifyListeners();
    final em = userEmail?.toLowerCase();
    if (userRole != 'customer' || em == null) return;
    SharedPreferences.getInstance().then((p) {
      if (v == null || v.trim().isEmpty) {
        p.remove('customer_checkout_addr_v1_$em');
      } else {
        p.setString('customer_checkout_addr_v1_$em', v.trim());
      }
    });
  }

  void updateCheckoutDraftDeliveryTime(String v) {
    checkoutDeliveryTime = v.trim().isEmpty ? 'NOW' : v.trim();
    notifyListeners();
    final em = userEmail?.toLowerCase();
    if (userRole != 'customer' || em == null) return;
    SharedPreferences.getInstance().then((p) => p.setString('customer_checkout_time_v1_$em', checkoutDeliveryTime));
  }

  Future<String?> cancelOrderAsCustomer({required int orderId}) async {
    if (userEmail == null) return 'Not signed in';
    try {
      final res = await http
          .patch(
            _uri('/api/mobile/orders/$orderId/cancel-customer'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({'user_email': userEmail}),
          )
          .timeout(_apiTimeout);
      if (res.statusCode != 200) {
        try {
          final err = jsonDecode(res.body) as Map<String, dynamic>;
          return '${err['error'] ?? 'Could not cancel'}';
        } catch (_) {
          return 'Could not cancel (${res.statusCode})';
        }
      }
      await loadOrders(force: true);
      notifyListeners();
      return null;
    } catch (e) {
      return describeApiNetworkError(e, normalizeApiBase(apiBase));
    }
  }

  Future<String?> cancelInquiryAsCustomer({required int inquiryId}) async {
    if (userEmail == null) return 'Not signed in';
    try {
      final res = await http
          .patch(
            _uri('/api/mobile/inquiries/$inquiryId/cancel-customer'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({'user_email': userEmail}),
          )
          .timeout(_apiTimeout);
      if (res.statusCode != 200) {
        try {
          final err = jsonDecode(res.body) as Map<String, dynamic>;
          return '${err['error'] ?? 'Could not cancel inquiry'}';
        } catch (_) {
          return 'Could not cancel inquiry (${res.statusCode})';
        }
      }
      await loadInquiries(force: true);
      notifyListeners();
      return null;
    } catch (e) {
      return describeApiNetworkError(e, normalizeApiBase(apiBase));
    }
  }

  void markOrderAttentionRead(String orderNo) {
    final key = orderNo.trim();
    if (key.isEmpty) return;
    _readAttentionOrderNos.add(key);
    unawaited(_persistReadAttentionOrderNos());
    if (orderNosWithUnreadAttention.remove(key)) {
      if (unreadNotificationsCount > 0) unreadNotificationsCount--;
      notifyListeners();
    }
  }

  void logout() {
    final persistedEmail = userEmail?.toLowerCase();
    authSessionKey++;
    unreadNotificationsCount = 0;
    orderNosWithUnreadAttention.clear();
    userEmail = null;
    loginPassword = '';
    userRole = 'customer';
    cashierDisplayName = '';
    cashierOnlineOrders.clear();
    cashierOrderHistory.clear();
    cashierWalkInPreparing.clear();
    cashierWalkInComplete.clear();
    managerCateringRows.clear();
    loyaltyHistory.clear();
    showLoginWelcomeDialog = false;
    profile = ProfileData();
    menu.clear();
    tray.clear();
    orders.clear();
    inquiries.clear();
    setMenus.clear();
    checkoutNote = '';
    checkoutSelectedAddress = null;
    checkoutDeliveryTime = 'NOW';
    _lastRealtimeStamps = null;
    _realtimePollInFlight = false;
    _lastTrayServerStamp = '';
    _lastRealtimeServerTime = '';
    _ordersLoadedAt = null;
    _inquiriesLoadedAt = null;
    _profileLoadedAt = null;
    _notificationsLoadedAt = null;
    _managerCateringLoadedAt.clear();
    _managerCateringInFlightStages.clear();
    _managerActiveStage = 'new_event';
    _loadOrdersInFlight = false;
    _loadInquiriesInFlight = false;
    _loadProfileInFlight = false;
    _loadNotificationsInFlight = false;
    _loadCashierOnlineOrdersInFlight = false;
    _loadCashierWalkInQueuesInFlight = false;
    _loadCashierOrderHistoryInFlight = false;
    _cashierOnlineOrdersLoadedAt = null;
    _cashierWalkInQueuesLoadedAt = null;
    _cashierOrderHistoryLoadedAt = null;
    _loadSetMenusInFlight = false;
    _loadLoyaltyHistoryInFlight = false;
    _loadMenuInFlight = false;
    _readAttentionOrderNos.clear();
    _setMenusLoadedAt = null;
    _loyaltyHistoryLoadedAt = null;
    if (persistedEmail != null) {
      SharedPreferences.getInstance().then((p) async {
        await p.remove('customer_tray_v1_$persistedEmail');
        await p.remove('customer_checkout_note_v1_$persistedEmail');
        await p.remove('customer_checkout_addr_v1_$persistedEmail');
        await p.remove('customer_checkout_time_v1_$persistedEmail');
      });
    }
    clearCustomerNotificationDedupe();
    notifyListeners();
  }

  Uri _uri(String path, [Map<String, String>? query]) =>
      Uri.parse('${normalizeApiBase(apiBase)}$path').replace(queryParameters: query);

  Future<Map<String, String>?> _fetchRealtimeStamps() async {
    if (userEmail == null) return null;
    try {
      final res = await http
          .get(_uri('/api/mobile/realtime/sync-stamps', {'user_email': userEmail!, 'role': userRole}))
          .timeout(_apiTimeout);
      if (res.statusCode != 200) return null;
      final body = jsonDecode(res.body);
      if (body is! Map<String, dynamic>) return null;
      return <String, String>{
        'server_time': '${body['server_time'] ?? ''}',
        'menu': '${body['menu'] ?? ''}',
        'restaurant_orders': '${body['restaurant_orders'] ?? ''}',
        'profile': '${body['profile'] ?? ''}',
        'notifications': '${body['notifications'] ?? ''}',
        'inquiries': '${body['inquiries'] ?? ''}',
        'manager_catering': '${body['manager_catering'] ?? ''}',
        'loyalty': '${body['loyalty'] ?? ''}',
        'tray': '${body['tray'] ?? ''}',
      };
    } catch (_) {
      return null;
    }
  }

  Future<Map<String, dynamic>?> _fetchRealtimeDeltas(String sinceIso) async {
    if (userEmail == null || sinceIso.trim().isEmpty) return null;
    try {
      final res = await http
          .get(_uri('/api/mobile/realtime/deltas', {'user_email': userEmail!, 'role': userRole, 'since': sinceIso}))
          .timeout(_apiTimeout);
      if (res.statusCode != 200) return null;
      final body = jsonDecode(res.body);
      if (body is! Map<String, dynamic>) return null;
      return body;
    } catch (_) {
      return null;
    }
  }

  Future<void> bootstrapRealtimeSync() async {
    _lastRealtimeStamps = await _fetchRealtimeStamps();
    _lastRealtimeServerTime = _lastRealtimeStamps?['server_time'] ?? '';
  }

  bool _stampChanged(Map<String, String> previous, Map<String, String> next, String key) {
    return (previous[key] ?? '') != (next[key] ?? '');
  }

  Future<void> pollRealtimeSync() async {
    if (userEmail == null || _realtimePollInFlight) return;
    _realtimePollInFlight = true;
    try {
      final next = await _fetchRealtimeStamps();
      if (next == null) return;
      final previous = _lastRealtimeStamps;
      _lastRealtimeStamps = next;
      if (previous == null) return;
      final delta = await _fetchRealtimeDeltas(_lastRealtimeServerTime);
      _lastRealtimeServerTime = next['server_time'] ?? '';
      final jobs = <Future<void>>[];
      if (_stampChanged(previous, next, 'menu')) {
        final allow = delta == null || delta['menu_changed'] == true;
        if (allow) jobs.add(loadMenu(force: true));
      }
      if (isCashier) {
        if (_stampChanged(previous, next, 'restaurant_orders')) {
          final orderIds = delta?['restaurant_order_ids'];
          final allow = delta == null || (orderIds is List && orderIds.isNotEmpty);
          if (allow) {
            jobs.add(loadCashierOnlineOrders(force: true));
            jobs.add(loadCashierWalkInQueues(force: true));
          }
        }
      } else if (isManagerOrSupervisor) {
        if (_stampChanged(previous, next, 'manager_catering') ||
            _stampChanged(previous, next, 'restaurant_orders')) {
          final changedCateringInquiryIds = delta?['catering_inquiry_ids'];
          final changedEventInquiryIds = delta?['event_inquiry_ids'];
          final changedInquiryIds = delta?['inquiry_ids'];
          final changedOrderIds = delta?['restaurant_order_ids'];
          final allow = delta == null ||
              (changedCateringInquiryIds is List && changedCateringInquiryIds.isNotEmpty) ||
              (changedEventInquiryIds is List && changedEventInquiryIds.isNotEmpty) ||
              (changedInquiryIds is List && changedInquiryIds.isNotEmpty) ||
              (changedOrderIds is List && changedOrderIds.isNotEmpty);
          if (allow) {
            jobs.add(loadManagerCateringByStage(managerActiveStage, force: true));
          }
        }
      } else {
        if (_stampChanged(previous, next, 'restaurant_orders')) {
          final orderIds = delta?['restaurant_order_ids'];
          final allow = delta == null || (orderIds is List && orderIds.isNotEmpty);
          if (allow) jobs.add(loadOrders(force: true));
        }
        if (_stampChanged(previous, next, 'inquiries')) {
          final inquiryIds = delta?['inquiry_ids'];
          final allow = delta == null || (inquiryIds is List && inquiryIds.isNotEmpty);
          if (allow) jobs.add(loadInquiries(force: true));
        }
        if (_stampChanged(previous, next, 'tray') && next['tray'] != _lastTrayServerStamp) {
          jobs.add(pullCustomerTrayDraftFromServer());
        }
        if (_stampChanged(previous, next, 'profile') || _stampChanged(previous, next, 'loyalty')) {
          final profileChanged = delta?['profile_changed'] == true;
          final loyaltyChanged = delta?['loyalty_changed'] == true;
          final allow = delta == null || profileChanged || loyaltyChanged;
          if (allow) jobs.add(loadProfile(force: true));
        }
        if (_stampChanged(previous, next, 'notifications')) {
          final notifIds = delta?['notification_ids'];
          final allow = delta == null || (notifIds is List && notifIds.isNotEmpty);
          if (allow) jobs.add(loadNotifications(force: true));
        }
      }
      if (jobs.isNotEmpty) {
        await Future.wait(jobs);
      }
    } finally {
      _realtimePollInFlight = false;
    }
  }

  Future<void> loadMenu({bool force = false}) async {
    if (_loadMenuInFlight) return;
    if (!force && _menuLoadedAt != null) {
      final age = DateTime.now().difference(_menuLoadedAt!);
      if (age < const Duration(seconds: 20) && menu.isNotEmpty) return;
    }
    _loadMenuInFlight = true;
    try {
      final res = await http.get(_uri('/api/mobile/menu'));
      if (res.statusCode != 200) return;
      final List<dynamic> body = jsonDecode(res.body) as List<dynamic>;
      menu
        ..clear()
        ..addAll(
          body.map((e) {
            final map = e as Map<String, dynamic>;
            final dipValues = map['dips'] is List ? (map['dips'] as List<dynamic>).map((d) => '$d').toList() : <String>[];
            final ingValues =
                map['ingredients'] is List ? (map['ingredients'] as List<dynamic>).map((d) => '$d').toList() : <String>[];
            return MenuItemData(
              id: '${map['id']}',
              name: '${map['name']}',
              description: '${map['description']}',
              price: jsonToDouble(map['price']),
              dips: dipValues,
              ingredients: ingValues,
              category: '${map['category'] ?? ''}',
              dishType: '${map['dish_type'] ?? ''}',
              imageBase64: map['image_base64'] != null ? '${map['image_base64']}' : null,
            );
          }),
        );
      _menuLoadedAt = DateTime.now();
      notifyListeners();
    } finally {
      _loadMenuInFlight = false;
    }
  }

  Future<void> loadSetMenus({bool force = false}) async {
    if (_loadSetMenusInFlight) return;
    if (!force && _setMenusLoadedAt != null && DateTime.now().difference(_setMenusLoadedAt!) < const Duration(seconds: 8)) {
      return;
    }
    _loadSetMenusInFlight = true;
    try {
      final res = await http.get(_uri('/api/mobile/set-menus'));
      if (res.statusCode != 200) return;
      final List<dynamic> body = jsonDecode(res.body) as List<dynamic>;
      setMenus
        ..clear()
        ..addAll(
          body.map((e) {
            final map = e as Map<String, dynamic>;
            final dishes = map['dishes'] is List
                ? (map['dishes'] as List<dynamic>).map((d) => '$d').toList()
                : <String>[];
            return SetMenuData(
              name: '${map['name']}',
              description: '${map['description'] ?? ''}',
              dishes: dishes,
            );
          }),
        );
      _setMenusLoadedAt = DateTime.now();
      notifyListeners();
    } finally {
      _loadSetMenusInFlight = false;
    }
  }

  Future<void> loadProfile({bool force = false}) async {
    if (userEmail == null || _loadProfileInFlight) return;
    if (!force && _profileLoadedAt != null && DateTime.now().difference(_profileLoadedAt!) < const Duration(seconds: 4)) {
      return;
    }
    _loadProfileInFlight = true;
    try {
      final res = await http.get(_uri('/api/mobile/profile', {'user_email': userEmail!}));
      if (res.statusCode != 200) return;
      final map = jsonDecode(res.body) as Map<String, dynamic>;
    final addrList = <String>[];
    final rawAddrs = map['delivery_addresses'];
    if (rawAddrs is List) {
      for (final e in rawAddrs) {
        final s = '$e'.trim();
        if (s.isNotEmpty) addrList.add(s);
      }
    }
      profile = ProfileData(
      fullName: '${map['full_name'] ?? ''}',
      contactNumber: '${map['contact_number'] ?? ''}',
      deliveryAddress: '${map['delivery_address'] ?? ''}',
      deliveryMapConfirmed: jsonToBool(map['delivery_map_confirmed']),
      deliveryLat: map['delivery_lat'] != null ? jsonToDouble(map['delivery_lat']) : null,
      deliveryLng: map['delivery_lng'] != null ? jsonToDouble(map['delivery_lng']) : null,
      loyaltyPoints: jsonToInt(map['loyalty_points']),
      loyaltyPointsRestaurant: jsonToInt(map['loyalty_points_restaurant']),
      loyaltyPointsCatering: jsonToInt(map['loyalty_points_catering']),
      deliveryAddresses: addrList,
    );
      _profileLoadedAt = DateTime.now();
      await loadLoyaltyHistory(force: true);
      notifyListeners();
    } finally {
      _loadProfileInFlight = false;
    }
  }

  Future<void> loadLoyaltyHistory({bool force = false}) async {
    if (userEmail == null || _loadLoyaltyHistoryInFlight) return;
    if (!force &&
        _loyaltyHistoryLoadedAt != null &&
        DateTime.now().difference(_loyaltyHistoryLoadedAt!) < const Duration(seconds: 6)) {
      return;
    }
    _loadLoyaltyHistoryInFlight = true;
    try {
      final res = await http.get(_uri('/api/mobile/loyalty-history', {'user_email': userEmail!}));
      if (res.statusCode != 200) return;
      final body = jsonDecode(res.body);
      if (body is! List) return;
      loyaltyHistory
        ..clear()
        ..addAll(
          body.whereType<Map<String, dynamic>>().map(
            (m) => LoyaltyHistoryItem(
              orderNo: '${m['order_no'] ?? ''}',
              pointsDelta: jsonToInt(m['points_delta']),
              createdAt: jsonToDateTime(m['created_at'], DateTime.now()),
              source: '${m['source'] ?? 'restaurant'}'.toLowerCase().contains('catering') ? 'catering' : 'restaurant',
            ),
          ),
        );
      _loyaltyHistoryLoadedAt = DateTime.now();
      notifyListeners();
    } finally {
      _loadLoyaltyHistoryInFlight = false;
    }
  }

  Future<void> saveProfile(ProfileData updated) async {
    if (userEmail == null) return;
    final res = await http.put(
      _uri('/api/mobile/profile'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({
        'user_email': userEmail,
        'full_name': updated.fullName,
        'contact_number': updated.contactNumber,
        'delivery_address': updated.deliveryAddress,
        'delivery_map_confirmed': updated.deliveryMapConfirmed,
        if (updated.deliveryLat != null) 'delivery_lat': updated.deliveryLat,
        if (updated.deliveryLng != null) 'delivery_lng': updated.deliveryLng,
        'delivery_addresses': updated.deliveryAddresses,
      }),
    );
    if (res.statusCode == 200) {
      profile = ProfileData(
        fullName: updated.fullName,
        contactNumber: updated.contactNumber,
        deliveryAddress: updated.deliveryAddress,
        deliveryMapConfirmed: updated.deliveryMapConfirmed,
        deliveryLat: updated.deliveryLat,
        deliveryLng: updated.deliveryLng,
        loyaltyPoints: profile.loyaltyPoints,
        loyaltyPointsRestaurant: profile.loyaltyPointsRestaurant,
        loyaltyPointsCatering: profile.loyaltyPointsCatering,
        deliveryAddresses: updated.deliveryAddresses,
      );
      notifyListeners();
    }
  }

  void addToTray(MenuItemData menuItem, {String dip = ''}) {
    final existing = tray.where((e) => e.menu.id == menuItem.id && e.dip == dip).toList();
    if (existing.isEmpty) {
      tray.add(CartItem(menu: menuItem, dip: dip, qty: 1));
    } else {
      existing.first.qty += 1;
    }
    notifyListeners();
    _persistCustomerTraySnapshot().catchError((_) {});
  }

  void changeQty(CartItem item, int delta) {
    item.qty += delta;
    if (item.qty <= 0) {
      tray.remove(item);
    }
    notifyListeners();
    _persistCustomerTraySnapshot().catchError((_) {});
  }

  void clearTray() {
    tray.clear();
    notifyListeners();
    _persistCustomerTraySnapshot().catchError((_) {});
  }

  double get subtotal => tray.fold<double>(0, (sum, i) => sum + (i.qty * i.menu.price));

  Future<SubmitOrderResult> submitOrder({bool clearCheckoutDraft = true}) async {
    if (userEmail == null || tray.isEmpty) {
      return SubmitOrderResult(error: 'Missing profile or empty tray');
    }
    try {
      final res = await http
          .post(
            _uri('/api/mobile/orders'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({
              'user_email': userEmail,
              'note': checkoutNote,
              'delivery_name': profile.fullName,
              'delivery_contact': profile.contactNumber,
              'delivery_address': profile.deliveryAddress,
              'delivery_time': checkoutDeliveryTime,
              'items': tray
                  .map(
                    (e) => {
                      'item_name': e.menu.name,
                      'dip': e.dip,
                      'qty': e.qty,
                      'price': e.menu.price,
                    },
                  )
                  .toList(),
            }),
          )
          .timeout(_apiTimeout);
      if (res.statusCode != 201) {
        String msg = 'Could not place order';
        try {
          final err = jsonDecode(res.body) as Map<String, dynamic>;
          msg = '${err['error'] ?? msg}';
        } catch (_) {
          msg = '$msg (${res.statusCode})';
        }
        return SubmitOrderResult(error: msg);
      }
      final map = jsonDecode(res.body) as Map<String, dynamic>;
      final noteSnap = checkoutNote;
      final linesFromTray = tray
          .map(
            (e) => OrderLineItem(
              itemName: e.menu.name,
              dip: e.dip,
              qty: e.qty,
              price: e.menu.price,
            ),
          )
          .toList();
      final order = OrderData(
        id: jsonToInt(map['id']),
        orderNo: '${map['order_no']}',
        status: 'WAITING FOR PAYMENT CONFIRMATION',
        total: jsonToDouble(map['total']),
        createdAt: DateTime.now(),
        paymentUploaded: false,
        lines: linesFromTray,
        userEmail: userEmail,
        note: noteSnap,
        paymentMode: 'GCASH ONLY',
        deliveryName: profile.fullName,
        deliveryContact: profile.contactNumber,
        deliveryAddress: profile.deliveryAddress,
        deliveryTime: checkoutDeliveryTime,
        orderSource: 'MOBILE_APP',
        fulfillmentStage: 'PENDING_CASHIER',
        customerDisplayName: profile.fullName.trim().isNotEmpty ? profile.fullName.trim() : null,
        loyaltyPointsEarned: 0,
      );
      if (!clearCheckoutDraft) {
        try {
          await loadOrders(force: true);
        } catch (_) {
          orders.insert(0, order);
        }
        notifyListeners();
        return SubmitOrderResult(order: order);
      }
      checkoutNote = '';
      tray.clear();
      notifyListeners();
      await clearPersistedCustomerDraft();
      try {
        await loadOrders(force: true);
      } catch (_) {
        orders.insert(0, order);
      }
      notifyListeners();
      return SubmitOrderResult(order: order);
    } catch (e) {
      final msg = e is TypeError ? 'Unexpected response from server (invalid number). Try again or update the app.' : describeApiNetworkError(e, normalizeApiBase(apiBase));
      return SubmitOrderResult(error: msg);
    }
  }

  Future<String?> uploadPaymentProof(int orderId, XFile file) async {
    try {
      final encoded = base64Encode(await file.readAsBytes());
      final res = await http.patch(
        _uri('/api/mobile/orders/$orderId/payment'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'payment_proof': encoded}),
      );
      if (res.statusCode != 200) {
        try {
          final err = jsonDecode(res.body) as Map<String, dynamic>;
          return '${err['error'] ?? 'Could not upload payment proof'}';
        } catch (_) {
          return 'Could not upload payment proof (${res.statusCode})';
        }
      }
      await loadOrders(force: true);
      return null;
    } catch (e) {
      return describeApiNetworkError(e, normalizeApiBase(apiBase));
    }
  }

  Future<void> clearCheckoutAfterSuccessfulOrderAndPayment() async {
    checkoutNote = '';
    checkoutDeliveryTime = 'NOW';
    tray.clear();
    notifyListeners();
    await clearPersistedCustomerDraft();
  }

  Future<void> loadOrders({bool force = false}) async {
    if (userEmail == null || _loadOrdersInFlight) return;
    if (!force && _ordersLoadedAt != null && DateTime.now().difference(_ordersLoadedAt!) < const Duration(seconds: 4)) {
      return;
    }
    _loadOrdersInFlight = true;
    try {
      final res = await http.get(_uri('/api/mobile/orders', {'user_email': userEmail!}));
      if (res.statusCode != 200) return;
      final List<dynamic> body = jsonDecode(res.body) as List<dynamic>;
    final parsed = <OrderData>[];
    for (final e in body) {
      try {
        final map = e as Map<String, dynamic>;
        final lines = orderLinesFromApiMap(map);
        parsed.add(orderDataFromApiMap(map, lines));
      } catch (_) {}
    }
      orders
        ..clear()
        ..addAll(parsed);
      _ordersLoadedAt = DateTime.now();
      notifyListeners();
      if (!isCashier && !isManagerOrSupervisor) {
        await loadNotifications(force: true);
      }
    } finally {
      _loadOrdersInFlight = false;
    }
  }

  Future<String?> submitInquiry(Map<String, dynamic> payload) async {
    if (userEmail == null) return 'Not signed in';
    try {
      final res = await http
          .post(
            _uri('/api/mobile/inquiries'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({...payload, 'user_email': userEmail}),
          )
          .timeout(_apiTimeout);
      if (res.statusCode != 201) {
        try {
          final err = jsonDecode(res.body) as Map<String, dynamic>;
          return '${err['error'] ?? 'Inquiry failed'}';
        } catch (_) {
          return 'Inquiry failed (${res.statusCode})';
        }
      }
      await loadInquiries(force: true);
      notifyListeners();
      return null;
    } catch (e) {
      return describeApiNetworkError(e, normalizeApiBase(apiBase));
    }
  }

  Future<void> loadManagerCateringByStage(String stage, {bool force = false}) async {
    if (userEmail == null || !isManagerOrSupervisor) return;
    if (_managerCateringInFlightStages.contains(stage)) return;
    final loadedAt = _managerCateringLoadedAt[stage];
    if (!force && loadedAt != null && DateTime.now().difference(loadedAt) < const Duration(seconds: 5)) {
      return;
    }
    _managerCateringInFlightStages.add(stage);
    try {
      final res = await http
          .post(
            _uri('/api/mobile/pos/catering/list'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({
              'cashier_email': userEmail,
              'cashier_password': loginPassword,
              'stage': stage,
              'summary': true,
            }),
          )
          .timeout(_managerCateringListTimeout);
      if (res.statusCode != 200) return;
      final body = jsonDecode(res.body);
      if (body is! List) return;
      managerCateringRows
        ..clear()
        ..addAll(
          body.whereType<Map<String, dynamic>>().map(CateringEventRecord.fromApiMap),
        );
      _managerCateringLoadedAt[stage] = DateTime.now();
      notifyListeners();
    } catch (_) {
    } finally {
      _managerCateringInFlightStages.remove(stage);
    }
  }

  /// Full catering/event row for manager detail (list uses [loadManagerCateringByStage] with summary strips).
  Future<CateringEventRecord?> loadManagerCateringItem({required String id, required String orderKind}) async {
    if (userEmail == null || !isManagerOrSupervisor) return null;
    try {
      final res = await http
          .post(
            _uri('/api/mobile/pos/catering/item'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({
              'cashier_email': userEmail,
              'cashier_password': loginPassword,
              'id': id,
              'order_kind': orderKind,
            }),
          )
          .timeout(_managerCateringListTimeout);
      if (res.statusCode != 200) return null;
      final body = jsonDecode(res.body);
      if (body is! Map<String, dynamic>) return null;
      return CateringEventRecord.fromApiMap(body);
    } catch (_) {
      return null;
    }
  }

  Future<String?> managerCreateNewEvent({
    required String orderKind,
    required String eventTitle,
    required String eventType,
    required String customerName,
    required String contactPerson,
    required String contactNumber,
    required String emailAddress,
    required String address,
    required int guestCount,
    required String paymentMethod,
    required List<Map<String, dynamic>> costBreakdown,
    required int laborMaleCount,
    required int laborFemaleCount,
    required double laborManualException,
    required double travelCost,
    double? manualTotalCost,
    List<dynamic> scheduleSlots = const [],
    List<dynamic> menu = const [],
    Map<String, dynamic> themeDesign = const {},
    String formalityLevel = '',
  }) async {
    if (userEmail == null || !isManagerOrSupervisor) return 'Not signed in';
    try {
      final res = await http
          .post(
            _uri('/api/mobile/pos/catering/new-event'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({
              'cashier_email': userEmail,
              'cashier_password': loginPassword,
              'order_kind': orderKind,
              'event_title': eventTitle,
              'event_type': eventType,
              'customer_name': customerName,
              'contact_person': contactPerson,
              'contact_number': contactNumber,
              'email_address': emailAddress,
              'address': address,
              'guest_count': guestCount,
              'payment_method': paymentMethod,
              'cost_breakdown': costBreakdown,
              'labor_male_count': laborMaleCount,
              'labor_female_count': laborFemaleCount,
              'labor_manual_exception': laborManualException,
              'travel_cost': travelCost,
              if (manualTotalCost != null) 'manual_total_cost': manualTotalCost,
              'schedule_slots': scheduleSlots,
              'menu': menu,
              'theme_design': themeDesign,
              'formality_level': formalityLevel,
            }),
          )
          .timeout(_apiTimeout);
      if (res.statusCode != 201) {
        try {
          final body = jsonDecode(res.body);
          if (body is Map && body['error'] != null) {
            return '${body['error']}';
          }
        } catch (_) {}
        return 'Could not create event (${res.statusCode})';
      }
      return null;
    } catch (e) {
      return describeApiNetworkError(e, normalizeApiBase(apiBase));
    }
  }

  Future<String?> managerAdvanceCateringStage({
    required String id,
    required String orderKind,
    required String status,
    double? downPaymentAmount,
    double? fullPaymentAmount,
    Map<String, dynamic>? postAnalysis,
    List<dynamic>? checklist,
    List<String>? actualEventImages,
    List<Map<String, dynamic>>? additionalCosts,
    double? laborCost,
    double? travelCost,
    double? totalCost,
    List<Map<String, dynamic>>? costBreakdown,
    Map<String, dynamic>? themeDesign,
    List<dynamic>? menu,
  }) async {
    if (userEmail == null || !isManagerOrSupervisor) return 'Not signed in';
    try {
      final res = await http
          .patch(
            _uri('/api/mobile/pos/catering/$id/stage'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({
              'cashier_email': userEmail,
              'cashier_password': loginPassword,
              'order_kind': orderKind,
              'status': status,
              if (downPaymentAmount != null) 'down_payment_amount': downPaymentAmount,
              if (fullPaymentAmount != null) 'full_payment_amount': fullPaymentAmount,
              if (postAnalysis != null) 'post_analysis': postAnalysis,
              if (checklist != null) 'checklist': checklist,
              if (actualEventImages != null) 'actual_event_images': actualEventImages,
              if (additionalCosts != null) 'additional_costs': additionalCosts,
              if (laborCost != null) 'labor_cost': laborCost,
              if (travelCost != null) 'travel_cost': travelCost,
              if (totalCost != null) 'total_cost': totalCost,
              if (costBreakdown != null) 'cost_breakdown': costBreakdown,
              if (themeDesign != null) 'theme_design': themeDesign,
              if (menu != null) 'menu': menu,
            }),
          )
          .timeout(_apiTimeout);
      if (res.statusCode != 200) return 'Could not update stage';
      return null;
    } catch (e) {
      return describeApiNetworkError(e, normalizeApiBase(apiBase));
    }
  }

  /// Persist catering record while still in New Event / Online Inquiries (no stage transition).
  Future<String?> managerSaveCateringDraft({
    required String id,
    required String orderKind,
    required Map<String, dynamic> draft,
  }) async {
    if (userEmail == null || !isManagerOrSupervisor) return 'Not signed in';
    try {
      final res = await http
          .patch(
            _uri('/api/mobile/pos/catering/$id/draft'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({
              'cashier_email': userEmail,
              'cashier_password': loginPassword,
              'order_kind': orderKind,
              ...draft,
            }),
          )
          .timeout(_apiTimeout);
      if (res.statusCode != 200) {
        try {
          final err = jsonDecode(res.body) as Map<String, dynamic>;
          return '${err['error'] ?? 'Could not save'}';
        } catch (_) {
          return 'Could not save (${res.statusCode})';
        }
      }
      return null;
    } catch (e) {
      return describeApiNetworkError(e, normalizeApiBase(apiBase));
    }
  }

  /// Merge keys into `post_analysis` (e.g. manager payment confirmations). Manager-only for payment flags on server.
  Future<String?> managerPatchCateringPostAnalysis({
    required String id,
    required String orderKind,
    required Map<String, dynamic> patch,
  }) async {
    if (userEmail == null || !isManagerOrSupervisor) return 'Not signed in';
    try {
      final res = await http
          .patch(
            _uri('/api/mobile/pos/catering/$id/post-analysis-patch'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({
              'cashier_email': userEmail,
              'cashier_password': loginPassword,
              'order_kind': orderKind,
              'patch': patch,
            }),
          )
          .timeout(_apiTimeout);
      if (res.statusCode != 200) return 'Could not update record';
      return null;
    } catch (e) {
      return describeApiNetworkError(e, normalizeApiBase(apiBase));
    }
  }

  /// Migrates the row between `catering_orders` and `event_orders` (draft stages only; server-enforced).
  Future<String?> managerSwitchCateringOrderKind({
    required String id,
    required String fromKind,
    required String toKind,
  }) async {
    if (userEmail == null || !isManagerOrSupervisor) return 'Not signed in';
    try {
      final res = await http
          .post(
            _uri('/api/mobile/pos/catering/$id/switch-order-kind'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({
              'cashier_email': userEmail,
              'cashier_password': loginPassword,
              'from_order_kind': fromKind,
              'to_order_kind': toKind,
            }),
          )
          .timeout(_apiTimeout);
      if (res.statusCode != 200) {
        try {
          final err = jsonDecode(res.body) as Map<String, dynamic>;
          return '${err['error'] ?? 'Could not switch inquiry type'}';
        } catch (_) {
          return 'Could not switch inquiry type (${res.statusCode})';
        }
      }
      return null;
    } catch (e) {
      return describeApiNetworkError(e, normalizeApiBase(apiBase));
    }
  }

  Future<Map<String, dynamic>?> managerInvoicePreview({
    required String id,
    required String orderKind,
  }) async {
    try {
      final res = await http
          .get(
            _uri('/api/mobile/pos/catering/$id/invoice-preview', {'order_kind': orderKind}),
          )
          .timeout(_apiTimeout);
      if (res.statusCode != 200) return null;
      final b = jsonDecode(res.body);
      return b is Map<String, dynamic> ? b : null;
    } catch (_) {
      return null;
    }
  }

  Future<void> loadNotifications({bool force = false}) async {
    if (userEmail == null || isCashier || isManagerOrSupervisor || _loadNotificationsInFlight) return;
    if (!force &&
        _notificationsLoadedAt != null &&
        DateTime.now().difference(_notificationsLoadedAt!) < const Duration(seconds: 4)) {
      return;
    }
    _loadNotificationsInFlight = true;
    try {
      final res = await http.get(_uri('/api/mobile/notifications', {'user_email': userEmail!})).timeout(_apiTimeout);
      if (res.statusCode != 200) return;
      final map = jsonDecode(res.body);
      if (map is! Map<String, dynamic>) return;
      unreadNotificationsCount = jsonToInt(map['unread_count']);
      orderNosWithUnreadAttention.clear();
      final raw = map['notifications'];
      if (raw is List) {
        final re = RegExp(r'\[([^\]]+)\]');
        for (final e in raw) {
          if (e is! Map<String, dynamic>) continue;
          if (e['is_read'] == true) continue;
          final msg = '${e['message'] ?? ''}';
          final m = re.firstMatch(msg);
          final id = m?.group(1)?.trim();
          if (id != null &&
              id.isNotEmpty &&
              !_readAttentionOrderNos.contains(id)) {
            orderNosWithUnreadAttention.add(id);
          }
        }
      }
      _notificationsLoadedAt = DateTime.now();
      notifyListeners();
    } catch (_) {
    } finally {
      _loadNotificationsInFlight = false;
    }
  }

  Future<void> markAllNotificationsRead() async {
    if (userEmail == null) return;
    try {
      await http
          .patch(
            _uri('/api/mobile/notifications/read-all'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({'user_email': userEmail}),
          )
          .timeout(_apiTimeout);
      await loadNotifications(force: true);
    } catch (_) {}
  }

  Future<String?> submitHelpRequest({
    required String area,
    required String problem,
    required String desiredOutcome,
  }) async {
    if (userEmail == null) return 'Not signed in';
    try {
      final res = await http
          .post(
            _uri('/api/mobile/help'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({
              'user_email': userEmail,
              'area': area,
              'problem': problem,
              'desired_outcome': desiredOutcome,
            }),
          )
          .timeout(_apiTimeout);
      if (res.statusCode != 201) {
        try {
          final err = jsonDecode(res.body) as Map<String, dynamic>;
          return '${err['error'] ?? 'Could not send help request'}';
        } catch (_) {
          return 'Could not send (${res.statusCode})';
        }
      }
      return null;
    } catch (e) {
      return describeApiNetworkError(e, normalizeApiBase(apiBase));
    }
  }

  Future<void> loadInquiries({bool force = false}) async {
    if (userEmail == null || _loadInquiriesInFlight) return;
    if (!force && _inquiriesLoadedAt != null && DateTime.now().difference(_inquiriesLoadedAt!) < const Duration(seconds: 4)) {
      return;
    }
    _loadInquiriesInFlight = true;
    try {
      final res = await http.get(_uri('/api/mobile/inquiries', {'user_email': userEmail!}));
      if (res.statusCode != 200) return;
      final List<dynamic> body = jsonDecode(res.body) as List<dynamic>;
    final parsed = <InquiryRecord>[];
    for (final e in body) {
      try {
        final map = e as Map<String, dynamic>;
        final dishes = inquirySelectedDishLabels(map['selected_dishes']);
        parsed.add(
          InquiryRecord(
            id: jsonToInt(map['id']),
            inquiryNo: '${map['inquiry_no']}',
            inquiryType: '${map['inquiry_type']}',
            eventTitle: '${map['event_title']}',
            eventType: '${map['event_type']}',
            customer: '${map['customer']}',
            contactPerson: '${map['contact_person']}',
            contactNumber: '${map['contact_number']}',
            inquiryEmail: '${map['inquiry_email']}',
            dateOfEvent: '${map['date_of_event']}',
            note: '${map['note']}',
            curateOwnMenu: jsonToBool(map['curate_own_menu']),
            selectedSetMenu: '${map['selected_set_menu']}',
            selectedDishes: dishes,
            includeEventTheme: jsonToBool(map['include_event_theme']),
            guestCount: jsonToInt(map['guest_count']),
            menuSuggestionNote: '${map['menu_suggestion_note'] ?? ''}',
            themeSuggestionNote: '${map['theme_suggestion_note'] ?? ''}',
            estimatedTotal: jsonToDouble(map['estimated_total']),
            status: '${map['status']}',
            createdAt: jsonToDateTime(map['created_at'], DateTime.now()),
            eventCity: '${map['event_city'] ?? ''}',
            eventSetting: '${map['event_setting'] ?? ''}',
            serviceIncluded: '${map['service_included'] ?? ''}',
            formalityLevel: '${map['formality_level'] ?? ''}',
            foodTastingRequested: jsonToBool(map['food_tasting_requested']),
            loyaltyPointsEarned: jsonToInt(map['loyalty_points_earned']),
            transactionNo: '${map['transaction_no'] ?? ''}',
            downPaymentAmount: jsonToDouble(map['down_payment_amount']),
            fullPaymentAmount: jsonToDouble(map['full_payment_amount']),
          ),
        );
      } catch (_) {}
    }
      inquiries
        ..clear()
        ..addAll(parsed);
      _inquiriesLoadedAt = DateTime.now();
      notifyListeners();
    } finally {
      _loadInquiriesInFlight = false;
    }
  }

  Future<void> loadCashierOnlineOrders({bool force = false}) async {
    if (userEmail == null || !isCashier || _loadCashierOnlineOrdersInFlight) return;
    if (!force &&
        _cashierOnlineOrdersLoadedAt != null &&
        DateTime.now().difference(_cashierOnlineOrdersLoadedAt!) < const Duration(seconds: 4)) {
      return;
    }
    _loadCashierOnlineOrdersInFlight = true;
    try {
      final res = await http
          .post(
            _uri('/api/mobile/pos/online-orders/list'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({
              'cashier_email': userEmail,
              'cashier_password': loginPassword,
            }),
          )
          .timeout(_apiTimeout);
      if (res.statusCode != 200) return;
      final List<dynamic> body = jsonDecode(res.body) as List<dynamic>;
      cashierOnlineOrders
        ..clear()
        ..addAll(
          body.map((e) {
            final map = e as Map<String, dynamic>;
            return orderDataFromApiMap(map, orderLinesFromApiMap(map));
          }),
        );
      _cashierOnlineOrdersLoadedAt = DateTime.now();
      notifyListeners();
    } catch (_) {
    } finally {
      _loadCashierOnlineOrdersInFlight = false;
    }
  }

  Future<void> loadCashierOrderHistory({bool force = false}) async {
    if (userEmail == null || !isCashier || _loadCashierOrderHistoryInFlight) return;
    if (!force &&
        _cashierOrderHistoryLoadedAt != null &&
        DateTime.now().difference(_cashierOrderHistoryLoadedAt!) < const Duration(seconds: 4)) {
      return;
    }
    _loadCashierOrderHistoryInFlight = true;
    try {
      final res = await http
          .post(
            _uri('/api/mobile/pos/order-history'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({
              'cashier_email': userEmail,
              'cashier_password': loginPassword,
            }),
          )
          .timeout(_apiTimeout);
      if (res.statusCode != 200) return;
      final List<dynamic> body = jsonDecode(res.body) as List<dynamic>;
      cashierOrderHistory
        ..clear()
        ..addAll(
          body.map((e) {
            final map = e as Map<String, dynamic>;
            return orderDataFromApiMap(map, orderLinesFromApiMap(map));
          }),
        );
      _cashierOrderHistoryLoadedAt = DateTime.now();
      notifyListeners();
    } catch (_) {
    } finally {
      _loadCashierOrderHistoryInFlight = false;
    }
  }

  Future<void> loadCashierWalkInQueues({bool force = false}) async {
    if (userEmail == null || !isCashier || _loadCashierWalkInQueuesInFlight) return;
    if (!force &&
        _cashierWalkInQueuesLoadedAt != null &&
        DateTime.now().difference(_cashierWalkInQueuesLoadedAt!) < const Duration(seconds: 4)) {
      return;
    }
    _loadCashierWalkInQueuesInFlight = true;
    try {
      Future<List<OrderData>> fetch(String filter) async {
        final res = await http
            .post(
              _uri('/api/mobile/pos/walkin-queue'),
              headers: {'Content-Type': 'application/json'},
              body: jsonEncode({
                'cashier_email': userEmail,
                'cashier_password': loginPassword,
                'filter': filter,
              }),
            )
            .timeout(_apiTimeout);
        if (res.statusCode != 200) return [];
        final List<dynamic> body = jsonDecode(res.body) as List<dynamic>;
        return body.map((e) {
          final map = e as Map<String, dynamic>;
          return orderDataFromApiMap(map, orderLinesFromApiMap(map));
        }).toList();
      }

      cashierWalkInPreparing
        ..clear()
        ..addAll(await fetch('preparing'));
      cashierWalkInComplete
        ..clear()
        ..addAll(await fetch('claimed'));
      _cashierWalkInQueuesLoadedAt = DateTime.now();
      notifyListeners();
    } catch (_) {
    } finally {
      _loadCashierWalkInQueuesInFlight = false;
    }
  }

  Future<String?> claimWalkInOrder(int orderId) async {
    if (userEmail == null || !isCashier) return 'Not signed in';
    try {
      final res = await http
          .patch(
            _uri('/api/mobile/pos/walkin-orders/$orderId/claim'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({
              'cashier_email': userEmail,
              'cashier_password': loginPassword,
            }),
          )
          .timeout(_apiTimeout);
      if (res.statusCode != 200) {
        try {
          final err = jsonDecode(res.body) as Map<String, dynamic>;
          return '${err['error'] ?? 'Could not update order'}';
        } catch (_) {
          return 'Could not update (${res.statusCode})';
        }
      }
      await loadCashierWalkInQueues(force: true);
      await loadCashierOrderHistory(force: true);
      notifyListeners();
      return null;
    } catch (e) {
      return describeApiNetworkError(e, normalizeApiBase(apiBase));
    }
  }

  Future<String?> cashierPatchFulfillment({
    required int orderId,
    required String fulfillmentStage,
    String deliveryTrackingUrl = '',
  }) async {
    if (userEmail == null || !isCashier) return 'Not signed in';
    try {
      final res = await http
          .patch(
            _uri('/api/mobile/pos/online-orders/$orderId/fulfillment'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({
              'cashier_email': userEmail,
              'cashier_password': loginPassword,
              'fulfillment_stage': fulfillmentStage,
              'delivery_tracking_url': deliveryTrackingUrl,
            }),
          )
          .timeout(_apiTimeout);
      if (res.statusCode != 200) {
        try {
          final err = jsonDecode(res.body) as Map<String, dynamic>;
          return '${err['error'] ?? 'Update failed'}';
        } catch (_) {
          return 'Update failed (${res.statusCode})';
        }
      }
      await loadCashierOnlineOrders(force: true);
      notifyListeners();
      return null;
    } catch (e) {
      return describeApiNetworkError(e, normalizeApiBase(apiBase));
    }
  }

  Future<String?> cashierReviewOrder({
    required int orderId,
    required String action,
    double? amountReceived,
    double? supplementalAmountReceived,
  }) async {
    if (userEmail == null || !isCashier) return 'Not signed in';
    try {
      final body = <String, dynamic>{
        'cashier_email': userEmail,
        'cashier_password': loginPassword,
        'action': action,
      };
      if (amountReceived != null) body['amount_received'] = amountReceived;
      if (supplementalAmountReceived != null) body['supplemental_amount_received'] = supplementalAmountReceived;
      final res = await http
          .patch(
            _uri('/api/mobile/pos/online-orders/$orderId/review'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode(body),
          )
          .timeout(_apiTimeout);
      if (res.statusCode != 200) {
        try {
          final err = jsonDecode(res.body) as Map<String, dynamic>;
          return '${err['error'] ?? 'Update failed'}';
        } catch (_) {
          return 'Update failed (${res.statusCode})';
        }
      }
      await loadCashierOnlineOrders(force: true);
      notifyListeners();
      return null;
    } catch (e) {
      return describeApiNetworkError(e, normalizeApiBase(apiBase));
    }
  }

  Future<String?> cashierRemindInsufficientOrder({required int orderId}) async {
    if (userEmail == null || !isCashier) return 'Not signed in';
    try {
      final res = await http
          .post(
            _uri('/api/mobile/pos/online-orders/$orderId/remind-balance'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({
              'cashier_email': userEmail,
              'cashier_password': loginPassword,
            }),
          )
          .timeout(_apiTimeout);
      if (res.statusCode != 200) {
        try {
          final err = jsonDecode(res.body) as Map<String, dynamic>;
          return '${err['error'] ?? 'Could not send follow-up'}';
        } catch (_) {
          return 'Could not send follow-up (${res.statusCode})';
        }
      }
      return null;
    } catch (e) {
      return describeApiNetworkError(e, normalizeApiBase(apiBase));
    }
  }

  Future<String?> submitPosWalkInOrder({
    required String paymentMethod,
    required double amountReceived,
    String note = '',
    String posCustomerLabel = '',
    String paymentProofBase64 = '',
  }) async {
    if (userEmail == null || !isCashier) return 'Not signed in';
    if (tray.isEmpty) return 'Tray is empty';
    try {
      final res = await http
          .post(
            _uri('/api/mobile/pos/walkin-order'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({
              'cashier_email': userEmail,
              'cashier_password': loginPassword,
              'payment_method': paymentMethod,
              'amount_received': amountReceived,
              'note': note,
              'pos_customer_label': posCustomerLabel,
              if (paymentProofBase64.isNotEmpty) 'payment_proof': paymentProofBase64,
              'items': tray
                  .map(
                    (e) => {
                      'item_name': e.menu.name,
                      'dip': e.dip,
                      'qty': e.qty,
                      'price': e.menu.price,
                    },
                  )
                  .toList(),
            }),
          )
          .timeout(_apiTimeout);
      if (res.statusCode != 201) {
        try {
          final err = jsonDecode(res.body) as Map<String, dynamic>;
          return '${err['error'] ?? 'Could not submit order'}';
        } catch (_) {
          return 'Could not submit (${res.statusCode})';
        }
      }
      clearTray();
      return null;
    } catch (e) {
      return describeApiNetworkError(e, normalizeApiBase(apiBase));
    }
  }
}

class AuthScreen extends StatefulWidget {
  const AuthScreen({super.key, required this.state, this.cashierMode = false});
  final AppState state;
  final bool cashierMode;

  @override
  State<AuthScreen> createState() => _AuthScreenState();
}

class _AuthScreenState extends State<AuthScreen> {
  final emailController = TextEditingController();
  final passwordController = TextEditingController();
  final confirmPasswordController = TextEditingController();
  final otpController = TextEditingController();
  final forgotIdentityController = TextEditingController();
  final forgotOtpController = TextEditingController();
  final forgotNewPasswordController = TextEditingController();
  final forgotConfirmPasswordController = TextEditingController();
  bool signupMode = false;
  bool otpSent = false;
  bool forgotRequested = false;
  String forgotChannel = 'email';
  bool busy = false;

  @override
  void dispose() {
    emailController.dispose();
    passwordController.dispose();
    confirmPasswordController.dispose();
    otpController.dispose();
    forgotIdentityController.dispose();
    forgotOtpController.dispose();
    forgotNewPasswordController.dispose();
    forgotConfirmPasswordController.dispose();
    super.dispose();
  }

  Future<void> _toast(String msg) async {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF242424),
      body: SafeArea(
        child: Stack(
          children: [
            Column(
              children: [
            const SizedBox(height: 50),
            const Text(
              'WELCOME',
              style: TextStyle(fontSize: 26, fontWeight: FontWeight.w800, color: Colors.white),
            ),
            const SizedBox(height: 30),
            SizedBox(
              height: 104,
              width: 104,
              child: Image.asset(AppBrandAssets.logoLogin, fit: BoxFit.contain),
            ),
            const SizedBox(height: 24),
            Expanded(
              child: Container(
                width: double.infinity,
                padding: const EdgeInsets.all(20),
                decoration: const BoxDecoration(
                  color: AppColors.brand,
                  borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
                ),
                child: SingleChildScrollView(
                  child: Column(
                    children: [
                      Text(
                        signupMode ? 'SIGN UP' : 'LOG IN',
                        style: const TextStyle(fontSize: 24, fontWeight: FontWeight.w800),
                      ),
                      const SizedBox(height: 16),
                      _LabeledInput(label: 'EMAIL ADDRESS', controller: emailController),
                      const SizedBox(height: 10),
                      if (!signupMode)
                        _LabeledInput(label: 'PASSWORD', controller: passwordController, obscure: true),
                      if (!widget.cashierMode && signupMode) ...[
                        const SizedBox(height: 10),
                        FilledButton(
                          onPressed: busy
                              ? null
                              : () async {
                                  setState(() => busy = true);
                                  try {
                                    final err = await widget.state.requestSignupOtp(emailController.text);
                                    if (!mounted) return;
                                    if (err != null) {
                                      await _toast(err);
                                      return;
                                    }
                                    setState(() => otpSent = true);
                                    await _toast('Check your email for the OTP code.');
                                  } finally {
                                    if (mounted) setState(() => busy = false);
                                  }
                                },
                          style: FilledButton.styleFrom(
                            backgroundColor: Colors.white,
                            foregroundColor: AppColors.ink,
                            side: const BorderSide(color: AppColors.ink),
                          ),
                          child: const Text('SEND OTP TO EMAIL'),
                        ),
                        if (otpSent) ...[
                          const SizedBox(height: 14),
                          _LabeledInput(label: 'OTP CODE', controller: otpController),
                          const SizedBox(height: 10),
                          _LabeledInput(label: 'PASSWORD (min 8)', controller: passwordController, obscure: true),
                          const SizedBox(height: 10),
                          _LabeledInput(label: 'CONFIRM PASSWORD', controller: confirmPasswordController, obscure: true),
                          const SizedBox(height: 14),
                          FilledButton(
                            onPressed: busy
                                ? null
                                : () async {
                                    if (passwordController.text != confirmPasswordController.text) {
                                      await _toast('Passwords do not match');
                                      return;
                                    }
                                    setState(() => busy = true);
                                    try {
                                      final err = await widget.state.completeSignup(
                                        email: emailController.text,
                                        otp: otpController.text,
                                        password: passwordController.text,
                                      );
                                      if (!mounted) return;
                                      if (err != null) await _toast(err);
                                    } finally {
                                      if (mounted) setState(() => busy = false);
                                    }
                                  },
                            style: FilledButton.styleFrom(
                              backgroundColor: Colors.white,
                              foregroundColor: AppColors.ink,
                              side: const BorderSide(color: AppColors.ink),
                            ),
                            child: const Text('CREATE ACCOUNT'),
                          ),
                        ],
                      ],
                      if (!signupMode) ...[
                        const SizedBox(height: 18),
                        FilledButton(
                          onPressed: busy
                              ? null
                              : () async {
                                  setState(() => busy = true);
                                  try {
                                    final err = await widget.state.login(
                                      emailController.text,
                                      passwordController.text,
                                    );
                                    if (!mounted) return;
                                    if (err != null) await _toast(err);
                                  } finally {
                                    if (mounted) setState(() => busy = false);
                                  }
                                },
                          style: FilledButton.styleFrom(
                            backgroundColor: Colors.white,
                            foregroundColor: AppColors.ink,
                            side: const BorderSide(color: AppColors.ink),
                          ),
                          child: const Text('LOG IN'),
                        ),
                        const SizedBox(height: 8),
                        TextButton(
                          onPressed: busy
                              ? null
                              : () async {
                                  await showDialog<void>(
                                    context: context,
                                    builder: (ctx) => StatefulBuilder(
                                      builder: (ctx, setDialogState) => AlertDialog(
                                        title: const Text('Forgot password'),
                                        content: SingleChildScrollView(
                                          child: Column(
                                            mainAxisSize: MainAxisSize.min,
                                            crossAxisAlignment: CrossAxisAlignment.stretch,
                                            children: [
                                              TextField(
                                                controller: forgotIdentityController,
                                                decoration: InputDecoration(
                                                  labelText: widget.cashierMode ? 'Email' : 'Email or phone',
                                                ),
                                              ),
                                              const SizedBox(height: 8),
                                              if (!widget.cashierMode)
                                                DropdownButtonFormField<String>(
                                                  value: forgotChannel,
                                                  decoration: const InputDecoration(labelText: 'Notification channel'),
                                                  items: const [
                                                    DropdownMenuItem(value: 'email', child: Text('Email')),
                                                    DropdownMenuItem(value: 'phone', child: Text('Phone')),
                                                  ],
                                                  onChanged: (v) => setDialogState(() => forgotChannel = v ?? 'email'),
                                                ),
                                              const SizedBox(height: 10),
                                              FilledButton(
                                                onPressed: () async {
                                                  final identity = forgotIdentityController.text.trim();
                                                  if (identity.isEmpty) {
                                                    await _toast('Enter your account email/phone');
                                                    return;
                                                  }
                                                  final err = await widget.state.requestPasswordReset(
                                                    identity: identity,
                                                    channel: widget.cashierMode ? 'email' : forgotChannel,
                                                    role: widget.cashierMode ? 'cashier' : 'customer',
                                                  );
                                                  if (err != null) {
                                                    await _toast(err);
                                                    return;
                                                  }
                                                  setDialogState(() => forgotRequested = true);
                                                  await _toast(
                                                    (widget.cashierMode || forgotChannel == 'email')
                                                        ? 'Reset OTP sent. Check your email.'
                                                        : 'Reset request submitted. Check your phone notifications.',
                                                  );
                                                },
                                                child: const Text('REQUEST RESET OTP'),
                                              ),
                                              if (forgotRequested) ...[
                                                const SizedBox(height: 10),
                                                TextField(
                                                  controller: forgotOtpController,
                                                  decoration: const InputDecoration(labelText: 'Reset OTP'),
                                                ),
                                                const SizedBox(height: 8),
                                                TextField(
                                                  controller: forgotNewPasswordController,
                                                  obscureText: true,
                                                  decoration: const InputDecoration(labelText: 'New password (min 8)'),
                                                ),
                                                const SizedBox(height: 8),
                                                TextField(
                                                  controller: forgotConfirmPasswordController,
                                                  obscureText: true,
                                                  decoration: const InputDecoration(labelText: 'Confirm new password'),
                                                ),
                                                const SizedBox(height: 10),
                                                FilledButton(
                                                  onPressed: () async {
                                                    if (forgotNewPasswordController.text != forgotConfirmPasswordController.text) {
                                                      await _toast('Passwords do not match');
                                                      return;
                                                    }
                                                    final err = await widget.state.resetPasswordWithOtp(
                                                      identity: forgotIdentityController.text,
                                                      otp: forgotOtpController.text,
                                                      password: forgotNewPasswordController.text,
                                                      role: widget.cashierMode ? 'cashier' : 'customer',
                                                    );
                                                    if (err != null) {
                                                      await _toast(err);
                                                      return;
                                                    }
                                                    if (context.mounted) Navigator.pop(ctx);
                                                    await _toast('Password reset successful. Log in with your new password.');
                                                  },
                                                  child: const Text('RESET PASSWORD'),
                                                ),
                                              ],
                                            ],
                                          ),
                                        ),
                                        actions: [
                                          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Close')),
                                        ],
                                      ),
                                    ),
                                  );
                                },
                          child: const Text('FORGOT PASSWORD?'),
                        ),
                      ],
                      if (!widget.cashierMode)
                        TextButton(
                          onPressed: busy
                              ? null
                              : () => setState(() {
                                    signupMode = !signupMode;
                                    otpSent = false;
                                    otpController.clear();
                                    confirmPasswordController.clear();
                                  }),
                          child: Text(
                            signupMode ? 'ALREADY HAVE AN ACCOUNT? LOG IN' : "DON'T HAVE AN ACCOUNT? SIGN UP",
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ),
              ],
            ),
            if (busy)
              Positioned.fill(
                child: ColoredBox(
                  color: Colors.black54,
                  child: Center(
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: const Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2.4)),
                          SizedBox(width: 12),
                          Text('Logging in...'),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _LabeledInput extends StatelessWidget {
  const _LabeledInput({required this.label, required this.controller, this.obscure = false});
  final String label;
  final TextEditingController controller;
  final bool obscure;
  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        SizedBox(width: 130, child: Text(label, style: const TextStyle(fontWeight: FontWeight.w700))),
        Expanded(child: TextField(controller: controller, obscureText: obscure)),
      ],
    );
  }
}

const double _tabletBreakpoint = 900;

/// Wider layouts show more dish cards per row (customer menu + cashier POS).
int restaurantGridCrossAxisCount(double width) {
  if (width >= 1100) return 5;
  if (width >= 850) return 4;
  if (width >= 600) return 3;
  return 2;
}

Widget _adaptiveScaffoldBody(BuildContext context, Widget body) {
  final width = MediaQuery.sizeOf(context).width;
  if (width < _tabletBreakpoint) return body;
  final maxWidth = width >= 1400 ? 1200.0 : 1000.0;
  return Align(
    alignment: Alignment.topCenter,
    child: ConstrainedBox(
      constraints: BoxConstraints(maxWidth: maxWidth),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 24),
        child: body,
      ),
    ),
  );
}

class AppScaffold extends StatelessWidget {
  const AppScaffold({
    super.key,
    required this.state,
    required this.title,
    required this.body,
    this.showTrayShortcut = true,
    this.forceDrawerLeading = false,
    this.actions,
    this.onBackPressed,
  });

  final AppState state;
  final String title;
  final Widget body;
  final bool showTrayShortcut;
  /// When true (e.g. restaurant menu root), always show the drawer menu icon instead of a back arrow.
  final bool forceDrawerLeading;
  final List<Widget>? actions;
  final VoidCallback? onBackPressed;

  @override
  Widget build(BuildContext context) {
    final isCustomer = state.userRole == 'customer';
    final keepHamburger = isCustomer && title != 'CHECKOUT' && title != 'PAYMENT';
    final headerBg = isCustomer ? const Color(0xFF242424) : AppColors.brand;
    final headerFg = isCustomer ? const Color(0xFFFFC024) : Theme.of(context).colorScheme.onPrimary;
    final qty = state.tray.fold<int>(0, (s, e) => s + e.qty);
    final pendingAttentionExists = state.orders.isEmpty
        ? state.orderNosWithUnreadAttention.isNotEmpty
        : state.orders
            .where((o) => customerOrderPendingTab(o))
            .any((o) => state.orderNosWithUnreadAttention.contains(o.orderNo));
    final showAttentionDot = isCustomer ? pendingAttentionExists : (state.unreadNotificationsCount > 0 || pendingAttentionExists);
    return Scaffold(
      appBar: AppBar(
        foregroundColor: headerFg,
        iconTheme: IconThemeData(color: headerFg),
        leading: (forceDrawerLeading || keepHamburger) && state.userEmail != null
            ? Builder(
                builder: (context) {
                  return Stack(
                    clipBehavior: Clip.none,
                    alignment: Alignment.center,
                    children: [
                      IconButton(
                        icon: const Icon(Icons.menu),
                        onPressed: () => Scaffold.of(context).openDrawer(),
                      ),
                      if (showAttentionDot)
                        Positioned(
                          right: 6,
                          top: 6,
                          child: Container(
                            width: 10,
                            height: 10,
                            decoration: const BoxDecoration(color: Colors.red, shape: BoxShape.circle),
                          ),
                        ),
                    ],
                  );
                },
              )
            : Navigator.of(context).canPop()
                ? IconButton(
                    icon: const Icon(Icons.arrow_back),
                    onPressed: () async {
                      if (onBackPressed != null) {
                        onBackPressed!();
                        return;
                      }
                      final nav = Navigator.of(context);
                      await nav.maybePop();
                    },
                  )
                : Builder(
                    builder: (context) {
                      return Stack(
                        clipBehavior: Clip.none,
                        alignment: Alignment.center,
                        children: [
                          IconButton(
                            icon: const Icon(Icons.menu),
                            onPressed: () => Scaffold.of(context).openDrawer(),
                          ),
                          if (showAttentionDot)
                            Positioned(
                              right: 6,
                              top: 6,
                              child: Container(
                                width: 10,
                                height: 10,
                                decoration: const BoxDecoration(color: Colors.red, shape: BoxShape.circle),
                              ),
                            ),
                        ],
                      );
                    },
                  ),
        backgroundColor: headerBg,
        title: Text(
          title,
          style: TextStyle(fontWeight: FontWeight.w800, color: headerFg),
        ),
        centerTitle: true,
        actions: [
          if (showTrayShortcut && state.userEmail != null)
            IconButton(
              tooltip: 'Your tray',
              onPressed: () {
                Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => TrayScreen(state: state)));
              },
              icon: Badge(
                isLabelVisible: qty > 0,
                label: Text('$qty'),
                child: Icon(Icons.shopping_cart_outlined, color: headerFg),
              ),
            ),
          ...?actions,
        ],
      ),
      drawer: AppDrawer(state: state),
      body: _adaptiveScaffoldBody(context, body),
    );
  }
}

class AppDrawer extends StatelessWidget {
  const AppDrawer({super.key, required this.state});
  final AppState state;

  void open(BuildContext context, Widget screen) {
    Navigator.of(context).pushReplacement(MaterialPageRoute<void>(builder: (_) => screen));
  }

  @override
  Widget build(BuildContext context) {
    final isCustomer = state.userRole == 'customer';
    final drawerHeaderBg = isCustomer ? const Color(0xFF242424) : AppColors.brand;
    final drawerHeaderFg = isCustomer ? const Color(0xFFFFC024) : Colors.black;
    final greet = state.profile.fullName.trim().isNotEmpty ? state.profile.fullName.trim() : (state.userEmail ?? '');
    final pendingAttentionExists = state.orders.isEmpty
        ? state.orderNosWithUnreadAttention.isNotEmpty
        : state.orders
            .where((o) => customerOrderPendingTab(o))
            .any((o) => state.orderNosWithUnreadAttention.contains(o.orderNo));
    final showAttentionDot = isCustomer ? pendingAttentionExists : (state.unreadNotificationsCount > 0 || pendingAttentionExists);
    return Drawer(
      child: ListView(
        children: [
          DrawerHeader(
            decoration: BoxDecoration(color: drawerHeaderBg),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                Image.asset(AppBrandAssets.logo, height: 52, fit: BoxFit.contain),
                const SizedBox(height: 10),
                if (greet.isNotEmpty)
                  Text(
                    'Hi, $greet!',
                    style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: drawerHeaderFg),
                  ),
              ],
            ),
          ),
          ListTile(
            title: const Text('Dashboard'),
            onTap: () => open(context, CustomerDashboardScreen(state: state)),
          ),
          ListTile(title: const Text('My Profile'), onTap: () => open(context, MyProfileScreen(state: state))),
          ListTile(
            title: const Text('My Orders'),
            trailing: showAttentionDot
                ? Container(
                    width: 10,
                    height: 10,
                    decoration: const BoxDecoration(color: Colors.red, shape: BoxShape.circle),
                  )
                : null,
            onTap: () {
              open(context, MyOrdersScreen(state: state));
            },
          ),
          ListTile(title: const Text('My Catering Inquiries'), onTap: () => open(context, MyInquiriesScreen(state: state))),
          ListTile(title: const Text('Your Tray'), onTap: () => open(context, TrayScreen(state: state))),
          ListTile(title: const Text('Restaurant Menu'), onTap: () => open(context, RestaurantMenuScreen(state: state))),
          ListTile(title: const Text('Inquire Catering'), onTap: () => open(context, InquiryScreen(state: state))),
          ListTile(title: const Text('Settings'), onTap: () => open(context, SettingsScreen(state: state))),
        ],
      ),
    );
  }
}

class CustomerDashboardScreen extends StatelessWidget {
  const CustomerDashboardScreen({super.key, required this.state});
  final AppState state;

  @override
  Widget build(BuildContext context) {
    final who = state.profile.fullName.trim().isNotEmpty
        ? state.profile.fullName.trim()
        : (state.userEmail ?? '').trim();
    final items = <({String title, IconData icon, Widget screen})>[
      (title: 'Restaurant Menu', icon: Icons.restaurant_menu_outlined, screen: RestaurantMenuScreen(state: state)),
      (title: 'Your Tray', icon: Icons.shopping_cart_outlined, screen: TrayScreen(state: state)),
      (title: 'My Orders', icon: Icons.receipt_long_outlined, screen: MyOrdersScreen(state: state)),
      (title: 'Inquire Catering', icon: Icons.event_available_outlined, screen: InquiryScreen(state: state)),
      (title: 'My Catering Inquiries', icon: Icons.question_answer_outlined, screen: MyInquiriesScreen(state: state)),
      (title: 'My Profile', icon: Icons.person_outline, screen: MyProfileScreen(state: state)),
    ];
    return AppScaffold(
      state: state,
      title: 'DASHBOARD',
      showTrayShortcut: false,
      forceDrawerLeading: true,
      body: Column(
        children: [
          Container(
            width: double.infinity,
            decoration: const BoxDecoration(color: Color(0xFF242424)),
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 14),
            child: Column(
          crossAxisAlignment: CrossAxisAlignment.center,
              children: [
            Center(child: Image.asset(AppBrandAssets.logoDashboard, height: 52, fit: BoxFit.contain)),
                if (who.isNotEmpty) ...[
                  const SizedBox(height: 10),
                  Text(
                    'Hi, $who!',
                    style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700, color: Colors.white),
                textAlign: TextAlign.center,
                  ),
                ],
              ],
            ),
          ),
          Expanded(
            child: RefreshIndicator(
              onRefresh: () async {
                await Future.wait([
                  state.loadMenu(force: true),
                  state.loadSetMenus(force: true),
                  state.loadProfile(force: true),
                  state.loadOrders(force: true),
                  state.loadInquiries(force: true),
                ]);
                await state.loadNotifications(force: true);
              },
              child: GridView.builder(
                physics: const AlwaysScrollableScrollPhysics(),
                padding: const EdgeInsets.all(12),
                gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: 2,
                  crossAxisSpacing: 10,
                  mainAxisSpacing: 10,
                  childAspectRatio: 1.35,
                ),
                itemCount: items.length,
                itemBuilder: (context, index) {
                  final item = items[index];
                  return Card(
                    child: InkWell(
                      borderRadius: BorderRadius.circular(12),
                      onTap: () {
                        Navigator.of(context).pushReplacement(
                          MaterialPageRoute<void>(builder: (_) => item.screen),
                        );
                      },
                      child: Padding(
                        padding: const EdgeInsets.all(14),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Icon(item.icon, color: AppColors.brand, size: 30),
                            const Spacer(),
                            Text(item.title, style: const TextStyle(fontWeight: FontWeight.w800)),
                          ],
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class ManagerDashboardScreen extends StatelessWidget {
  const ManagerDashboardScreen({super.key, required this.state});
  final AppState state;

  @override
  Widget build(BuildContext context) {
    final cards = <({String title, IconData icon, int tabIdx})>[
      (title: 'New Event', icon: Icons.add_box_outlined, tabIdx: 0),
      (title: 'Online Inquiries', icon: Icons.inbox_outlined, tabIdx: 1),
      (title: 'For Processing', icon: Icons.pending_actions_outlined, tabIdx: 2),
      (title: 'For Full Payment', icon: Icons.payments_outlined, tabIdx: 3),
      (title: 'Completed', icon: Icons.task_alt_outlined, tabIdx: 4),
      (title: 'Cancelled', icon: Icons.cancel_outlined, tabIdx: 5),
    ];
    return Scaffold(
      appBar: AppBar(
        backgroundColor: Colors.black87,
        foregroundColor: Colors.white,
        title: const Text('MANAGER DASHBOARD'),
      ),
      body: GridView.builder(
        padding: const EdgeInsets.all(12),
        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: 2,
          crossAxisSpacing: 10,
          mainAxisSpacing: 10,
          childAspectRatio: 1.35,
        ),
        itemCount: cards.length + 1,
        itemBuilder: (context, index) {
          if (index == cards.length) {
            return Card(
              child: InkWell(
                borderRadius: BorderRadius.circular(12),
                onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => SettingsScreen(state: state))),
                child: const Padding(
                  padding: EdgeInsets.all(14),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Icon(Icons.settings_outlined, color: AppColors.brand, size: 30),
                      Spacer(),
                      Text('Settings', style: TextStyle(fontWeight: FontWeight.w800)),
                    ],
                  ),
                ),
              ),
            );
          }
          final item = cards[index];
          return Card(
            child: InkWell(
              borderRadius: BorderRadius.circular(12),
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => ManagerCateringShellScreen(state: state, initialTabIndex: item.tabIdx),
                ),
              ),
              child: Padding(
                padding: const EdgeInsets.all(14),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(item.icon, color: AppColors.brand, size: 30),
                    const Spacer(),
                    Text(item.title, style: const TextStyle(fontWeight: FontWeight.w800)),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

class RestaurantMenuScreen extends StatefulWidget {
  const RestaurantMenuScreen({super.key, required this.state});
  final AppState state;

  @override
  State<RestaurantMenuScreen> createState() => _RestaurantMenuScreenState();
}

class _RestaurantMenuScreenState extends State<RestaurantMenuScreen> {
  String _search = '';
  String _sectionFilter = 'ALL';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      await Future.wait([
        widget.state.loadMenu(force: true),
        widget.state.loadSetMenus(force: true),
      ]);
      if (mounted) setState(() {});
    });
  }

  String _dishCardDescription(MenuItemData item) {
    final raw = item.description.trim();
    if (raw.isEmpty) return '';
    final noRestaurant = raw.replaceAll(RegExp(r'\brestaurant\b', caseSensitive: false), '').replaceAll('• •', '•');
    return noRestaurant
        .replaceAll(RegExp(r'\s*\.\s*'), ' • ')
        .replaceAll(RegExp(r'\s*•\s*'), ' • ')
        .replaceAll(RegExp(r'\s{2,}'), ' ')
        .replaceAll(RegExp(r'(^\s*•\s*|\s*•\s*$)'), '')
        .trim();
  }

  Future<void> _addToTray(BuildContext context, MenuItemData item) async {
    String selectedDip = '';
    if (item.dips.isNotEmpty) {
      final dipChoices = ['None', ...item.dips];
      selectedDip = 'None';
      await showDialog<void>(
        context: context,
        builder: (context) {
          return AlertDialog(
            title: Text('Choose dip for ${item.name}'),
            content: StatefulBuilder(
              builder: (context, setState) => DropdownButton<String>(
                value: selectedDip,
                isExpanded: true,
                items: dipChoices.map((d) => DropdownMenuItem(value: d, child: Text(d))).toList(),
                onChanged: (v) => setState(() => selectedDip = v ?? 'None'),
              ),
            ),
            actions: [
              TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Add')),
            ],
          );
        },
      );
    }
    final dip = selectedDip == 'None' ? '' : selectedDip;
    widget.state.addToTray(item, dip: dip);
    appSnack(context, 'Added ${item.name} to tray');
  }

  Widget _dishCard(BuildContext context, MenuItemData item) {
    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppColors.border),
        color: Colors.white,
      ),
      child: Column(
        children: [
          Expanded(
            child: Container(
              margin: const EdgeInsets.all(10),
              color: AppColors.canvas,
              child: _MenuThumb(item: item),
            ),
          ),
          Text(item.name.toUpperCase(), textAlign: TextAlign.center, style: const TextStyle(fontWeight: FontWeight.w700)),
          if (_dishCardDescription(item).isNotEmpty)
            Text(
              _dishCardDescription(item).toUpperCase(),
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 12),
            ),
          Text('₱${item.price.toStringAsFixed(2)}', style: const TextStyle(fontWeight: FontWeight.w800)),
          const SizedBox(height: 8),
          FilledButton(
            onPressed: () => _addToTray(context, item),
            style: FilledButton.styleFrom(backgroundColor: AppColors.brand, foregroundColor: AppColors.ink),
            child: const Text('ADD TO TRAY'),
          ),
          const SizedBox(height: 8),
        ],
      ),
    );
  }

  Widget _customerTraySidebar(BuildContext context, double subtotal) {
    return Container(
      width: 300,
      decoration: BoxDecoration(
        color: Colors.grey.shade50,
        border: Border(left: BorderSide(color: Colors.grey.shade300)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 12, 12, 4),
            child: Text('YOUR TRAY', style: TextStyle(fontWeight: FontWeight.w900, color: Colors.grey.shade900)),
          ),
          Expanded(
            child: widget.state.tray.isEmpty
                ? Center(child: Text('No dishes yet.', style: TextStyle(color: Colors.grey.shade600)))
                : ListView.builder(
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    itemCount: widget.state.tray.length,
                    itemBuilder: (context, i) {
                      final e = widget.state.tray[i];
                      return Card(
                        child: ListTile(
                          dense: true,
                          title: Text(e.menu.name, maxLines: 2, overflow: TextOverflow.ellipsis),
                          subtitle: Text(e.dip.isEmpty ? '—' : e.dip, maxLines: 1),
                          trailing: SizedBox(
                            width: 108,
                            child: Row(
                              mainAxisAlignment: MainAxisAlignment.end,
                              children: [
                                IconButton(
                                  padding: EdgeInsets.zero,
                                  constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
                                  icon: const Icon(Icons.remove_circle_outline, size: 22),
                                  onPressed: () => widget.state.changeQty(e, -1),
                                ),
                                Padding(
                                  padding: const EdgeInsets.symmetric(horizontal: 4),
                                  child: Text('${e.qty}', style: const TextStyle(fontWeight: FontWeight.w800)),
                                ),
                                IconButton(
                                  padding: EdgeInsets.zero,
                                  constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
                                  icon: const Icon(Icons.add_circle_outline, size: 22),
                                  onPressed: () => widget.state.changeQty(e, 1),
                                ),
                              ],
                            ),
                          ),
                        ),
                      );
                    },
                  ),
          ),
          Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text('Subtotal ₱${subtotal.toStringAsFixed(2)}', style: const TextStyle(fontWeight: FontWeight.w800)),
                const SizedBox(height: 10),
                Row(
                  children: [
                    Expanded(
                      child: FilledButton(
                        style: FilledButton.styleFrom(backgroundColor: AppColors.accent, foregroundColor: AppColors.ink),
                        onPressed: () => widget.state.clearTray(),
                        child: const Text('CANCEL'),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: FilledButton(
                        style: FilledButton.styleFrom(backgroundColor: AppColors.brand, foregroundColor: AppColors.ink),
                        onPressed: widget.state.tray.isEmpty
                            ? null
                            : () {
                                Navigator.of(context).push<void>(
                                  MaterialPageRoute<void>(
                                    builder: (_) => CheckoutScreen(state: widget.state),
                                  ),
                                );
                              },
                        child: const Text('CHECKOUT'),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: widget.state,
      builder: (context, _) {
        final restaurantItems = widget.state.menu.where((m) => m.isRestaurantDish).toList();
        final sectionLabels = <String, String>{};
        for (final m in restaurantItems) {
          final k = m.restaurantSectionKey;
          sectionLabels.putIfAbsent(k, () => m.restaurantSectionLabel);
        }
        final sectionKeysSorted = sectionLabels.keys.toList()
          ..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
        final filtered = restaurantItems.where((m) {
          final okSection =
              _sectionFilter == 'ALL' || m.restaurantSectionKey == _sectionFilter;
          final q = _search.trim().toLowerCase();
          final okSearch = q.isEmpty || m.name.toLowerCase().contains(q) || m.description.toLowerCase().contains(q);
          return okSection && okSearch;
        }).toList();
        final mq = MediaQuery.of(context);
        final land = mq.orientation == Orientation.landscape;
        var cw = restaurantGridCrossAxisCount(mq.size.width);
        if (land && mq.size.shortestSide >= 600) {
          cw = cw.clamp(2, 3);
        }
        var aspect = cw >= 4 ? 0.82 : 0.74;
        if (land && mq.size.shortestSide >= 600) {
          aspect = 0.62;
        }
        final gridDelegate = SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: cw,
          crossAxisSpacing: 10,
          mainAxisSpacing: 10,
          childAspectRatio: aspect,
        );
        final allAlpha = List<MenuItemData>.from(filtered)
          ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
        final subtotal = widget.state.tray.fold<double>(0, (s, e) => s + e.qty * e.menu.price);
        final menuBody = Column(
          children: [
            Padding(
              padding: const EdgeInsets.all(12),
              child: TextField(
                decoration: const InputDecoration(hintText: 'SEARCH'),
                onChanged: (v) => setState(() => _search = v),
              ),
            ),
            SizedBox(
              height: 44,
              child: ListView(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 12),
                children: [
                  Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: FilterChip(
                      label: const Text('ALL'),
                      selected: _sectionFilter == 'ALL',
                      onSelected: (_) => setState(() => _sectionFilter = 'ALL'),
                    ),
                  ),
                  ...sectionKeysSorted.map((k) {
                    final lab = sectionLabels[k] ?? k;
                    return Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: FilterChip(
                        label: Text(lab.toUpperCase()),
                        selected: _sectionFilter == k,
                        onSelected: (_) => setState(() => _sectionFilter = k),
                      ),
                    );
                  }),
                ],
              ),
            ),
            Expanded(
              child: RefreshIndicator(
                onRefresh: () async {
                  await Future.wait([
                    widget.state.loadMenu(force: true),
                    widget.state.loadSetMenus(force: true),
                  ]);
                  if (mounted) setState(() {});
                },
                child: filtered.isEmpty
                    ? ListView(
                        physics: const AlwaysScrollableScrollPhysics(),
                        children: const [
                          SizedBox(height: 120),
                          Center(child: Text('No restaurant menu items in this filter.')),
                        ],
                      )
                    : GridView.builder(
                        physics: const AlwaysScrollableScrollPhysics(),
                        padding: const EdgeInsets.all(12),
                        itemCount: _sectionFilter == 'ALL' ? allAlpha.length : filtered.length,
                        gridDelegate: gridDelegate,
                        itemBuilder: (context, index) => _sectionFilter == 'ALL'
                            ? _dishCard(context, allAlpha[index])
                            : _dishCard(context, filtered[index]),
                      ),
              ),
            ),
          ],
        );
        return AppScaffold(
          state: widget.state,
          title: 'MENU',
          showTrayShortcut: true,
          forceDrawerLeading: true,
          body: LayoutBuilder(
            builder: (context, constraints) {
              // Tablet: fixed tray when screen is large enough; phones stay single-column (shortestSide < 600).
              final sz = MediaQuery.sizeOf(context);
              final useTabletTrayRail = sz.shortestSide >= 600 && sz.width >= 700;
              if (useTabletTrayRail) {
                return Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Expanded(child: menuBody),
                    _customerTraySidebar(context, subtotal),
                  ],
                );
              }
              // Phone / narrow layout: scrollable menu only (tray & checkout live under Your Tray / checkout flow).
              return menuBody;
            },
          ),
        );
      },
    );
  }
}

class _MenuThumb extends StatelessWidget {
  const _MenuThumb({required this.item, this.compact = false});
  final MenuItemData item;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final iconSize = compact ? 22.0 : 60.0;
    final raw = item.imageBase64?.trim();
    if (raw != null && raw.isNotEmpty) {
      try {
        final bytes = base64Decode(raw);
        return Image.memory(Uint8List.fromList(bytes), fit: BoxFit.cover);
      } catch (_) {}
    }
    return Icon(Icons.fastfood, size: iconSize);
  }
}

class AiThemeStudioResult {
  const AiThemeStudioResult({
    required this.baseImageUrl,
    required this.selectedElements,
    required this.generatedNotes,
    required this.generatedImageBase64,
  });
  final String baseImageUrl;
  final List<String> selectedElements;
  final String generatedNotes;
  final String generatedImageBase64;
}

class AiThemeStudioPage extends StatefulWidget {
  const AiThemeStudioPage({
    super.key,
    required this.apiBase,
    required this.eventTitle,
    required this.eventType,
    required this.formalityLevel,
    required this.initialNotes,
  });
  final String apiBase;
  final String eventTitle;
  final String eventType;
  final String formalityLevel;
  final String initialNotes;

  @override
  State<AiThemeStudioPage> createState() => _AiThemeStudioPageState();
}

class _AiThemeStudioPageState extends State<AiThemeStudioPage> {
  static const List<Map<String, String>> _fallback = [
    {'title': 'Elegant Event Tablescape', 'url': 'https://images.unsplash.com/photo-1519225421980-715cb0215aed'},
    {'title': 'Floral Centerpiece Inspiration', 'url': 'https://images.unsplash.com/photo-1478146059778-26028b07395a'},
    {'title': 'Modern Reception Setup', 'url': 'https://images.unsplash.com/photo-1469371670807-013ccf25f16a'},
    {'title': 'Garden Party Decor', 'url': 'https://images.unsplash.com/photo-1522673607200-164d1b6ce486'},
    {'title': 'Romantic Wedding Setup', 'url': 'https://images.unsplash.com/photo-1511285560929-80b456fea0bc'},
  ];
  int _step = 0;
  int? _baseIdx;
  final Set<int> _elementIdx = <int>{};
  final Set<String> _selectedElementUrls = <String>{};
  late final TextEditingController _notesCtrl;
  late final TextEditingController _searchCtrl;
  late final TextEditingController _promptCtrl;
  late final TextEditingController _linkedBaseUrlCtrl;
  bool _searching = false;
  List<Map<String, String>> _templateSuggestions = List<Map<String, String>>.from(_fallback);
  List<Map<String, String>> _elementSuggestions = <Map<String, String>>[];
  bool _busy = false;
  String? _baseImageB64;
  List<Map<String, dynamic>> _extractedObjects = [];
  List<Map<String, dynamic>> _placements = [];
  List<Map<String, dynamic>> _freeSpaces = [];
  String _renderedB64 = '';
  bool _placementSaved = false;
  String _statusHint = 'Pick a base template, then tap Analyze Base.';
  int _lastTemplateSearchCount = 0;
  int _lastElementSearchCount = 0;

  @override
  void initState() {
    super.initState();
    _notesCtrl = TextEditingController(text: widget.initialNotes);
    _searchCtrl = TextEditingController(
      text: '${widget.eventType} ${widget.formalityLevel} ${widget.eventTitle}'.trim(),
    );
    _promptCtrl = TextEditingController();
    _linkedBaseUrlCtrl = TextEditingController();
  }

  @override
  void dispose() {
    _notesCtrl.dispose();
    _searchCtrl.dispose();
    _promptCtrl.dispose();
    _linkedBaseUrlCtrl.dispose();
    super.dispose();
  }

  void _snack(String message, {bool error = false}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: error ? Colors.red.shade700 : Colors.green.shade700,
      ),
    );
  }

  Future<void> _searchSuggestions() async {
    setState(() => _searching = true);
    try {
      final url = Uri.parse('${normalizeApiBase(widget.apiBase)}/api/public/events/theme-design/theme-search');
      final res = await http
          .post(
            url,
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({
              'eventTitle': widget.eventTitle,
              'eventType': widget.eventType,
              'formalityLevel': widget.formalityLevel,
              'prompt': _searchCtrl.text.trim(),
              'page': 1,
              'perPage': 12,
            }),
          )
          .timeout(_apiTimeout);
      if (res.statusCode == 200) {
        final body = jsonDecode(res.body);
        if (body is Map && body['images'] is List) {
          final images = (body['images'] as List)
              .whereType<Map>()
              .map((e) => {
                    'title': '${e['title'] ?? 'Theme suggestion'}',
                    'url': '${e['imageUrl'] ?? e['thumbnailUrl'] ?? ''}',
                  })
              .where((e) => (e['url'] ?? '').trim().isNotEmpty)
              .toList();
          if (images.isNotEmpty && mounted) {
            final usedFallback = body['usedFallback'] == true;
            final backendNote = '${body['error'] ?? ''}'.trim();
            setState(() {
              if (_step == 0) {
                _templateSuggestions = images;
                _baseIdx = null;
                _lastTemplateSearchCount = images.length;
              } else {
                _elementSuggestions = images;
                _elementIdx
                  ..clear()
                  ..addAll(
                    images.asMap().entries.where((e) => _selectedElementUrls.contains((e.value['url'] ?? '').trim())).map((e) => e.key),
                  );
                _lastElementSearchCount = images.length;
              }
              _statusHint = _step == 0
                  ? 'Search loaded ${images.length} template(s). Select one as your base.'
                  : 'Search loaded ${images.length} element candidate(s). Select items to extract.';
            });
            _snack(
              usedFallback
                  ? 'Loaded ${images.length} fallback template(s).${backendNote.isEmpty ? '' : ' $backendNote'}'
                  : 'Loaded ${images.length} template(s).',
              error: false,
            );
          } else {
            setState(() {
              if (_step == 0) {
                _lastTemplateSearchCount = 0;
                _statusHint = 'No template results. Try a different search phrase.';
              } else {
                _lastElementSearchCount = 0;
                _statusHint = 'No element results. Try a different search phrase.';
              }
            });
            _snack(_step == 0 ? 'No theme templates found for that search.' : 'No elements found for that search.', error: true);
          }
        }
      } else {
        _snack('Search failed (${res.statusCode}).', error: true);
      }
    } catch (_) {
      // Keep fallback suggestions.
      _snack('Could not reach AI search. Using fallback suggestions.', error: true);
    } finally {
      if (mounted) setState(() => _searching = false);
    }
  }

  void _addLinkedBaseImage() {
    final input = _linkedBaseUrlCtrl.text.trim();
    final uri = Uri.tryParse(input);
    if (input.isEmpty || uri == null || !(uri.hasScheme && (uri.scheme == 'http' || uri.scheme == 'https'))) {
      _snack('Please enter a valid image URL (http/https).', error: true);
      return;
    }
    setState(() {
      _templateSuggestions.insert(0, {
        'title': 'Linked base image',
        'url': input,
      });
      _baseIdx = 0;
      _step = 0;
      _statusHint = 'Linked image added. You can now use it as your main photo.';
    });
    _linkedBaseUrlCtrl.clear();
  }

  Future<String> _urlToBase64(String url) async {
    final uri = Uri.parse(url);
    final res = await http.get(uri).timeout(_apiTimeout);
    if (res.statusCode != 200) return '';
    return base64Encode(res.bodyBytes);
  }

  Future<void> _prepareBaseAndAnalyze() async {
    if (_baseIdx == null) return;
    setState(() => _busy = true);
    try {
      _baseImageB64 = await _urlToBase64(_templateSuggestions[_baseIdx!]['url']!);
      if ((_baseImageB64 ?? '').isEmpty) {
        _snack('Could not load the selected base image.', error: true);
        return;
      }
      final uri = Uri.parse('${normalizeApiBase(widget.apiBase)}/api/public/events/theme-design/analyze-base');
      final res = await http
          .post(
            uri,
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({'baseImageBase64': _baseImageB64}),
          )
          .timeout(_apiTimeout);
      if (res.statusCode == 200) {
        final body = jsonDecode(res.body);
        if (body is Map && body['freeSpaces'] is List) {
          _freeSpaces = (body['freeSpaces'] as List).whereType<Map>().map((e) => Map<String, dynamic>.from(e)).toList();
          _statusHint = 'Base analyzed. Go to Step 2 and extract objects.';
          _snack('Base analyzed. Ready for object placement.');
          if (_step == 0) {
            setState(() => _step = 1);
          }
        }
      }
    } catch (_) {
      _snack('Analyze base failed.', error: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _extractObjectsFromSelected() async {
    if (_elementIdx.isEmpty) return;
    setState(() => _busy = true);
    try {
      final list = <String>[];
      for (final i in _elementIdx) {
        if (i < 0 || i >= _elementSuggestions.length) continue;
        final b64 = await _urlToBase64(_elementSuggestions[i]['url']!);
        if (b64.isNotEmpty) list.add(b64);
      }
      if (list.isEmpty) {
        _snack('Could not load selected template images.', error: true);
        return;
      }
      final uri = Uri.parse('${normalizeApiBase(widget.apiBase)}/api/public/events/theme-design/extract-objects');
      final res = await http
          .post(
            uri,
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({'imagesBase64': list}),
          )
          .timeout(_apiTimeout);
      if (res.statusCode == 200) {
        final body = jsonDecode(res.body);
        if (body is Map && body['images'] is List) {
          final imgs = (body['images'] as List).whereType<Map>();
          final out = <Map<String, dynamic>>[];
          for (final im in imgs) {
            final objs = im['objects'];
            if (objs is List) {
              out.addAll(objs.whereType<Map>().map((e) => Map<String, dynamic>.from(e)));
            }
          }
          // Keep only true extracted objects (no full-image fallback proxies).
          final sourceB64 = list.map((e) => e.trim()).where((e) => e.isNotEmpty).toSet();
          final clean = out.where((o) {
            final id = '${o['id'] ?? ''}'.trim();
            final label = '${o['label'] ?? ''}'.trim().toLowerCase();
            final objB64 = '${o['objectImageBase64'] ?? ''}'.trim();
            if (id.startsWith('fallback_source_')) return false;
            if (label == 'source image') return false;
            if (objB64.isNotEmpty && sourceB64.contains(objB64)) return false;
            return true;
          }).toList();
          if (clean.isEmpty) {
            _extractedObjects = [];
            _placements = [];
            _placementSaved = false;
            _statusHint = 'No isolated objects detected. Try different element images.';
            _snack('No isolated objects found. Please search/select other element images.', error: true);
            return;
          }
          _extractedObjects = clean;
          _statusHint = 'Extracted ${clean.length} object(s). You can drag/drop in Step 2.';
          _snack('Extracted ${clean.length} object(s).');
        }
      }
    } catch (_) {
      _snack('Extract objects failed.', error: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _autoPlace() async {
    if (_extractedObjects.isEmpty) return;
    setState(() => _busy = true);
    try {
      final uri = Uri.parse('${normalizeApiBase(widget.apiBase)}/api/public/events/theme-design/auto-place');
      final res = await http
          .post(
            uri,
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({'freeSpaces': _freeSpaces, 'objects': _extractedObjects}),
          )
          .timeout(_apiTimeout);
      if (res.statusCode == 200) {
        final body = jsonDecode(res.body);
        if (body is Map && body['placements'] is List) {
          _placements = (body['placements'] as List).whereType<Map>().map((e) => Map<String, dynamic>.from(e)).toList();
          _placementSaved = false;
          _statusHint = 'Placement created. Go to Step 3 to render or add prompt objects.';
          _snack('Auto-placement generated (${_placements.length}).');
          if (_placements.isNotEmpty) {
            setState(() => _step = 2);
            // Auto-generate preview so users can immediately see changes.
            await _renderComposite();
          }
        }
      }
    } catch (_) {
      _snack('Auto place failed.', error: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _advanceToCompose() async {
    if (_elementIdx.isEmpty || _busy || _searching) return;
    await _extractObjectsFromSelected();
    if (_extractedObjects.isNotEmpty && _freeSpaces.isNotEmpty) {
      await _autoPlace();
    }
    if (mounted) {
      setState(() => _step = 2);
    }
  }

  Future<void> _renderComposite() async {
    if ((_baseImageB64 ?? '').isEmpty || _placements.isEmpty) return;
    setState(() => _busy = true);
    try {
      final objectById = <String, Map<String, dynamic>>{};
      for (final o in _extractedObjects) {
        objectById['${o['id'] ?? ''}'] = o;
      }
      final renderObjs = _placements
          .map((p) {
            final id = '${p['objectId'] ?? ''}';
            final src = objectById[id];
            final directObjectImage = '${p['objectImageBase64'] ?? ''}';
            if (src == null && directObjectImage.trim().isEmpty) return null;
            return {
              'objectImageBase64': src?['objectImageBase64'] ?? directObjectImage,
              'x': p['x'] ?? 0,
              'y': p['y'] ?? 0,
              'width': p['width'] ?? 0.25,
              'height': p['height'] ?? 0.25,
              'rotation': p['rotation'] ?? 0,
              'zIndex': p['zIndex'] ?? 0,
              'intensity': 1,
            };
          })
          .whereType<Map<String, dynamic>>()
          .toList();
      if (renderObjs.isEmpty) {
        _snack('No visible objects to preview yet. Try "Find Decor Items" first.', error: true);
        return;
      }
      final uri = Uri.parse('${normalizeApiBase(widget.apiBase)}/api/public/events/theme-design/render-composite');
      final res = await http
          .post(
            uri,
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({
              'baseImageBase64': _baseImageB64,
              'objects': renderObjs,
            }),
          )
          .timeout(_apiTimeout);
      if (res.statusCode == 200) {
        final body = jsonDecode(res.body);
        if (body is Map) {
          _renderedB64 = '${body['imageBase64'] ?? ''}';
          if (_renderedB64.trim().isNotEmpty) {
            _statusHint = 'Composite rendered. You can still add prompt objects.';
            _snack('Composite rendered successfully.');
          } else {
            _snack('Preview returned empty image.', error: true);
          }
        }
      }
    } catch (_) {
      _snack('Render failed.', error: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _addByPrompt() async {
    final prompt = _promptCtrl.text.trim();
    if ((_baseImageB64 ?? '').isEmpty || prompt.isEmpty) return;
    setState(() => _busy = true);
    try {
      final uri = Uri.parse('${normalizeApiBase(widget.apiBase)}/api/public/events/theme-design/add-by-prompt');
      final res = await http
          .post(
            uri,
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({
              'baseImageBase64': _baseImageB64,
              'eventTitle': widget.eventTitle,
              'eventType': widget.eventType,
              'formalityLevel': widget.formalityLevel,
              'prompt': prompt,
            }),
          )
          .timeout(const Duration(seconds: 180));
      if (res.statusCode == 200) {
        final body = jsonDecode(res.body);
        if (body is Map) {
          final b64 = '${body['imageBase64'] ?? ''}';
          if (b64.isNotEmpty) {
            _renderedB64 = b64;
            final fallbackUsed = body['usedSourceImageFallback'] == true || body['usedFallback'] == true;
            _statusHint = fallbackUsed
                ? 'Prompt applied with fallback sources.'
                : 'Prompt objects added to your composition.';
            _snack('Prompt objects added.');
          } else {
            final msg = '${body['error'] ?? 'No composed image returned.'}';
            _snack('Add-by-prompt: $msg', error: true);
          }
        }
      } else {
        String details = '';
        try {
          final errBody = jsonDecode(res.body);
          if (errBody is Map && errBody['error'] != null) details = ' ${errBody['error']}';
        } catch (_) {}
        _snack('Add-by-prompt failed.${details.isEmpty ? '' : details}', error: true);
      }
    } catch (_) {
      _snack('Add-by-prompt failed.', error: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _recolorFirstObject() async {
    if (_extractedObjects.isEmpty) return;
    final selection = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (ctx) {
        String? selectedObjectId = '${_extractedObjects.first['id'] ?? ''}';
        String selectedHex = '#F4511E';
        double selectedAlpha = 1.0;
        const palette = <String>['#F4511E', '#1DB954', '#1976D2', '#E91E63', '#6A1B9A', '#FFC107', '#FFFFFF', '#212121'];
        return StatefulBuilder(
          builder: (context, setLocalState) => AlertDialog(
            title: const Text('Recolor Extracted Objects'),
            content: SizedBox(
              width: 520,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: _extractedObjects.map((obj) {
                      final id = '${obj['id'] ?? ''}';
                      final label = '${obj['label'] ?? 'Object'}';
                      return FilterChip(
                        label: Text(label),
                        selected: selectedObjectId == id,
                        onSelected: (_) => setLocalState(() => selectedObjectId = id),
                      );
                    }).toList(),
                  ),
                  const SizedBox(height: 10),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: palette.map((hex) {
                      final selected = selectedHex == hex;
                      return GestureDetector(
                        onTap: () => setLocalState(() => selectedHex = hex),
                        child: Container(
                          width: 30,
                          height: 30,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: Color(int.parse(hex.substring(1), radix: 16) + 0xFF000000),
                            border: Border.all(color: selected ? Colors.black : Colors.black26, width: selected ? 2 : 1),
                          ),
                        ),
                      );
                    }).toList(),
                  ),
                  const SizedBox(height: 8),
                  Text('Intensity: ${(selectedAlpha * 100).round()}%'),
                  Slider(value: selectedAlpha, min: 0, max: 1, divisions: 20, onChanged: (v) => setLocalState(() => selectedAlpha = v)),
                ],
              ),
            ),
            actions: [
              TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
              FilledButton(
                onPressed: selectedObjectId == null
                    ? null
                    : () => Navigator.pop(ctx, {'objectId': selectedObjectId, 'targetHex': selectedHex, 'intensity': selectedAlpha}),
                child: const Text('Apply Color'),
              ),
            ],
          ),
        );
      },
    );
    if (selection == null) return;
    final objectId = '${selection['objectId'] ?? ''}';
    final targetHex = '${selection['targetHex'] ?? '#F4511E'}';
    final intensity = (selection['intensity'] as num?)?.toDouble() ?? 1.0;
    final target = _extractedObjects.firstWhere((obj) => '${obj['id'] ?? ''}' == objectId, orElse: () => <String, dynamic>{});
    if (target.isEmpty) return;
    final objectImageB64 = '${target['objectImageBase64'] ?? ''}'.trim();
    if (objectImageB64.isEmpty || objectId.isEmpty) return;
    setState(() => _busy = true);
    try {
      final uri = Uri.parse('${normalizeApiBase(widget.apiBase)}/api/public/events/theme-design/swap-colors');
      final res = await http
          .post(
            uri,
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({
              'imageBase64': objectImageB64,
              'masks': [
                {
                  'objectId': objectId,
                  if ('${target['maskBase64'] ?? ''}'.trim().isNotEmpty) 'maskBase64': target['maskBase64'],
                  if (target['polygonPoints'] is List) 'polygonPoints': target['polygonPoints'],
                }
              ],
              'edits': [
                {
                  'objectId': objectId,
                  'targetHex': targetHex,
                  'intensity': intensity,
                }
              ],
            }),
          )
          .timeout(_apiTimeout);
      if (res.statusCode == 200) {
        final body = jsonDecode(res.body);
        if (body is Map && '${body['imageBase64'] ?? ''}'.trim().isNotEmpty) {
          final recolored = '${body['imageBase64']}';
          final idx = _extractedObjects.indexWhere((obj) => '${obj['id'] ?? ''}' == objectId);
          if (idx >= 0) {
            _extractedObjects[idx] = {..._extractedObjects[idx], 'objectImageBase64': recolored};
          }
          _placementSaved = false;
          _snack('Object recolored successfully.');
        }
      } else {
        _snack('Recolor failed.', error: true);
      }
    } catch (_) {
      _snack('Recolor failed.', error: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  String _placementImageBase64(Map<String, dynamic> placement) {
    final direct = '${placement['objectImageBase64'] ?? ''}'.trim();
    if (direct.isNotEmpty) return direct;
    final id = '${placement['objectId'] ?? ''}';
    for (final o in _extractedObjects) {
      if ('${o['id'] ?? ''}' == id) {
        return '${o['objectImageBase64'] ?? ''}'.trim();
      }
    }
    return '';
  }

  void _addPlacementFromObject(Map<String, dynamic> object, Size canvasSize, Offset localPos) {
    final width = 0.22;
    final height = 0.22;
    final nx = (localPos.dx / canvasSize.width) - (width / 2);
    final ny = (localPos.dy / canvasSize.height) - (height / 2);
    setState(() {
      _placements.add({
        'objectId': '${object['id'] ?? ''}',
        'objectImageBase64': '${object['objectImageBase64'] ?? ''}',
        'x': nx.clamp(0.0, 1.0 - width),
        'y': ny.clamp(0.0, 1.0 - height),
        'width': width,
        'height': height,
        'rotation': 0,
        'zIndex': _placements.length,
      });
      _placementSaved = false;
      _statusHint = 'Object placed. Drag it on the preview to fine-tune.';
    });
  }

  Widget _buildStep2Canvas(String previewUrl) {
    if ((_baseImageB64 ?? '').trim().isEmpty && previewUrl.trim().isEmpty) {
      return Center(child: Text('Select and analyze a base image first.', style: TextStyle(color: Colors.grey.shade600)));
    }
    return LayoutBuilder(
      builder: (context, constraints) {
        final canvas = Size(constraints.maxWidth, constraints.maxHeight);
        return DragTarget<int>(
          onAcceptWithDetails: (details) {
            final i = details.data;
            if (i < 0 || i >= _extractedObjects.length) return;
            _addPlacementFromObject(_extractedObjects[i], canvas, details.offset - (context.findRenderObject() as RenderBox).localToGlobal(Offset.zero));
          },
          builder: (context, candidateData, rejectedData) {
            return ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: Stack(
                fit: StackFit.expand,
                children: [
                  ((_baseImageB64 ?? '').trim().isNotEmpty)
                      ? Image.memory(
                          base64Decode(_baseImageB64!),
                          fit: BoxFit.cover,
                          errorBuilder: (context, error, stackTrace) => Container(color: Colors.grey.shade200),
                        )
                      : Image.network(
                          previewUrl,
                          fit: BoxFit.cover,
                          errorBuilder: (context, error, stackTrace) => Container(color: Colors.grey.shade200),
                        ),
                  if (candidateData.isNotEmpty) Container(color: Colors.black.withValues(alpha: 0.08)),
                  ..._placements.asMap().entries.map((entry) {
                    final idx = entry.key;
                    final p = entry.value;
                    final x = ((p['x'] as num?)?.toDouble() ?? 0).clamp(0.0, 1.0);
                    final y = ((p['y'] as num?)?.toDouble() ?? 0).clamp(0.0, 1.0);
                    final w = (((p['width'] as num?)?.toDouble() ?? 0.22).clamp(0.08, 0.7));
                    final h = (((p['height'] as num?)?.toDouble() ?? 0.22).clamp(0.08, 0.7));
                    final img = _placementImageBase64(p);
                    if (img.isEmpty) return const SizedBox.shrink();
                    return Positioned(
                      left: x * canvas.width,
                      top: y * canvas.height,
                      width: w * canvas.width,
                      height: h * canvas.height,
                      child: GestureDetector(
                        onPanUpdate: (d) {
                          final dx = d.delta.dx / canvas.width;
                          final dy = d.delta.dy / canvas.height;
                          setState(() {
                            final nx = (((p['x'] as num?)?.toDouble() ?? 0) + dx).clamp(0.0, 1.0 - w);
                            final ny = (((p['y'] as num?)?.toDouble() ?? 0) + dy).clamp(0.0, 1.0 - h);
                            p['x'] = nx;
                            p['y'] = ny;
                            _placementSaved = false;
                          });
                        },
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            border: Border.all(color: Colors.white.withValues(alpha: 0.95), width: 1.2),
                            borderRadius: BorderRadius.circular(6),
                            boxShadow: const [BoxShadow(color: Colors.black26, blurRadius: 3)],
                          ),
                          child: Stack(
                            fit: StackFit.expand,
                            children: [
                              Image.memory(base64Decode(img), fit: BoxFit.cover),
                              Positioned(
                                right: 0,
                                top: 0,
                                child: InkWell(
                                  onTap: () => setState(() {
                                    _placements.removeAt(idx);
                                    _placementSaved = false;
                                  }),
                                  child: Container(
                                    color: Colors.black54,
                                    padding: const EdgeInsets.all(2),
                                    child: const Icon(Icons.close, color: Colors.white, size: 14),
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    );
                  }),
                ],
              ),
            );
          },
        );
      },
    );
  }

  String _autoNotes() {
    final title = widget.eventTitle.trim().isEmpty ? 'the event' : widget.eventTitle.trim();
    final elements = _elementIdx
        .where((i) => i >= 0 && i < _elementSuggestions.length)
        .map((i) => _elementSuggestions[i]['title']!)
        .join(', ');
    final base = _baseIdx != null ? _templateSuggestions[_baseIdx!]['title'] : 'selected inspiration';
    return 'Use $base as primary visual direction for $title. '
        'Blend accents from: ${elements.isEmpty ? 'floral and table styling motifs' : elements}. '
        'Event type: ${widget.eventType}. Formality: ${widget.formalityLevel}.';
  }

  @override
  Widget build(BuildContext context) {
    final isWide = MediaQuery.sizeOf(context).width >= 900;
    final isPhone = !isWide;
    Widget cards({required bool selectingBase}) {
      final options = selectingBase ? _templateSuggestions : _elementSuggestions;
      if (options.isEmpty) {
        return Center(
          child: Text(
            selectingBase
                ? 'No templates yet. Use Search to load design ideas.'
                : 'No element ideas yet. Search in Step 2 to load decor items.',
          ),
        );
      }
      return ListView.builder(
        itemCount: options.length,
        itemBuilder: (context, i) {
          final active = selectingBase ? _baseIdx == i : _elementIdx.contains(i);
          return Card(
            child: ListTile(
              leading: ClipRRect(
                borderRadius: BorderRadius.circular(6),
                child: Image.network(
                  options[i]['url']!,
                  width: 46,
                  height: 46,
                  fit: BoxFit.cover,
                  errorBuilder: (context, error, stackTrace) => Container(
                    width: 46,
                    height: 46,
                    color: Colors.grey.shade200,
                    child: const Icon(Icons.image_not_supported),
                  ),
                ),
              ),
              title: Text(options[i]['title']!),
              trailing: Icon(active ? Icons.check_box : Icons.check_box_outline_blank),
              onTap: () => setState(() {
                if (selectingBase) {
                  _baseIdx = i;
                } else if (_elementIdx.contains(i)) {
                  _elementIdx.remove(i);
                  _selectedElementUrls.remove((options[i]['url'] ?? '').trim());
                } else {
                  _elementIdx.add(i);
                  _selectedElementUrls.add((options[i]['url'] ?? '').trim());
                }
              }),
            ),
          );
        },
      );
    }

    final leftPane = Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Event Details', style: TextStyle(fontWeight: FontWeight.w800)),
            const SizedBox(height: 8),
            Text('Event: ${widget.eventTitle.isEmpty ? "(not set)" : widget.eventTitle}'),
            Text('Type: ${widget.eventType}'),
            Text('Formality: ${widget.formalityLevel}'),
            const SizedBox(height: 12),
            Text(_step == 0 ? 'Step 1: Choose Template' : 'Step 2: Add Elements', style: const TextStyle(fontWeight: FontWeight.w800)),
            const SizedBox(height: 8),
            TextField(
              controller: _searchCtrl,
              decoration: InputDecoration(
                labelText: _step == 0 ? 'Search templates' : 'Search elements',
                isDense: true,
                border: const OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 8),
            FilledButton.icon(
              onPressed: _searching ? null : _searchSuggestions,
              icon: _searching
                  ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.search, size: 16),
              label: Text(_searching ? 'Searching...' : _step == 0 ? 'Search Templates' : 'Search Elements'),
            ),
            if (_step == 0) ...[
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _linkedBaseUrlCtrl,
                      decoration: const InputDecoration(
                        labelText: 'Or paste image URL',
                        hintText: 'https://...',
                        isDense: true,
                        border: OutlineInputBorder(),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  OutlinedButton(onPressed: _addLinkedBaseImage, child: const Text('Add URL')),
                ],
              ),
            ],
            const SizedBox(height: 8),
            if (isWide)
              Expanded(child: cards(selectingBase: _step == 0))
            else
              SizedBox(height: 240, child: cards(selectingBase: _step == 0)),
          ],
        ),
      ),
    );
    final previewUrl = _step == 0
        ? (_baseIdx != null && _baseIdx! >= 0 && _baseIdx! < _templateSuggestions.length
            ? _templateSuggestions[_baseIdx!]['url'] ?? ''
            : '')
        : (_renderedB64.trim().isNotEmpty
            ? ''
            : ((_baseIdx != null && _baseIdx! >= 0 && _baseIdx! < _templateSuggestions.length)
                ? _templateSuggestions[_baseIdx!]['url'] ?? ''
                : ''));
    final centerPane = Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(_step == 2 ? 'Step 3: Compose your design on canvas' : 'Preview', style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 16)),
            const SizedBox(height: 8),
            Expanded(
              child: (_step == 1)
                  ? _buildStep2Canvas(previewUrl)
                  : (_renderedB64.trim().isNotEmpty)
                  ? InteractiveViewer(
                      minScale: 0.5,
                      maxScale: 3,
                      child: Center(
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(8),
                          child: Image.memory(base64Decode(_renderedB64), fit: BoxFit.contain),
                        ),
                      ),
                    )
                  : (previewUrl.trim().isEmpty
                      ? Center(child: Text('Select an image to preview.', style: TextStyle(color: Colors.grey.shade600)))
                      : InteractiveViewer(
                          minScale: 0.5,
                          maxScale: 3,
                          child: Center(
                            child: Image.network(
                              previewUrl,
                              fit: BoxFit.contain,
                              errorBuilder: (context, error, stackTrace) => const Text('Preview not available for this image.'),
                            ),
                          ),
                        )),
            ),
            if (_step == 2) ...[
              const SizedBox(height: 8),
              SizedBox(
                height: 110,
                child: Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('Before', style: TextStyle(fontSize: 12, color: Colors.grey.shade700, fontWeight: FontWeight.w700)),
                          const SizedBox(height: 4),
                          Expanded(
                            child: ClipRRect(
                              borderRadius: BorderRadius.circular(8),
                              child: ((_baseImageB64 ?? '').trim().isNotEmpty)
                                  ? Image.memory(
                                      base64Decode(_baseImageB64!),
                                      fit: BoxFit.cover,
                                      width: double.infinity,
                                      errorBuilder: (context, error, stackTrace) => Container(
                                        color: Colors.grey.shade200,
                                        alignment: Alignment.center,
                                        child: const Icon(Icons.broken_image),
                                      ),
                                    )
                                  : Container(
                                      color: Colors.grey.shade200,
                                      alignment: Alignment.center,
                                      child: const Text('No base'),
                                    ),
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('After', style: TextStyle(fontSize: 12, color: Colors.grey.shade700, fontWeight: FontWeight.w700)),
                          const SizedBox(height: 4),
                          Expanded(
                            child: ClipRRect(
                              borderRadius: BorderRadius.circular(8),
                              child: (_renderedB64.trim().isNotEmpty)
                                  ? Image.memory(
                                      base64Decode(_renderedB64),
                                      fit: BoxFit.cover,
                                      width: double.infinity,
                                      errorBuilder: (context, error, stackTrace) => Container(
                                        color: Colors.grey.shade200,
                                        alignment: Alignment.center,
                                        child: const Icon(Icons.broken_image),
                                      ),
                                    )
                                  : Container(
                                      color: Colors.grey.shade200,
                                      alignment: Alignment.center,
                                      child: const Text('No preview yet'),
                                    ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 8),
              const Text('Theme Notes', style: TextStyle(fontWeight: FontWeight.w800)),
              const SizedBox(height: 8),
              FilledButton.tonal(
                onPressed: () => setState(() => _notesCtrl.text = _autoNotes()),
                child: const Text('Generate Notes'),
              ),
              const SizedBox(height: 8),
              SizedBox(
                height: 150,
                child: TextField(
                  controller: _notesCtrl,
                  maxLines: null,
                  expands: true,
                  decoration: const InputDecoration(border: OutlineInputBorder()),
                ),
              ),
            ],
          ],
        ),
      ),
    );
    final rightPane = Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
            Text(
              _step == 0
                  ? 'Mark one base image, then proceed.'
                  : _step == 1
                      ? 'Check one or more images (not the base) to use as extraction sources.'
                      : 'Compose your design on canvas.',
            ),
            const SizedBox(height: 8),
            Text(
              _statusHint,
              style: TextStyle(fontSize: 12, color: Colors.blueGrey.shade700, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 6),
            Text(
              'Selected: ${_elementIdx.length}  |  Found: ${_extractedObjects.length}  |  Arranged: ${_placements.length}  |  Preview: ${_renderedB64.trim().isEmpty ? 'No' : 'Yes'}',
              style: TextStyle(fontSize: 12, color: Colors.grey.shade700),
            ),
            const SizedBox(height: 8),
            if (_step == 0)
              Text(
                _lastTemplateSearchCount > 0
                    ? 'Showing $_lastTemplateSearchCount template(s).'
                    : 'Showing ${_templateSuggestions.length} template(s).',
                style: TextStyle(fontSize: 12, color: Colors.grey.shade700),
              ),
            if (_step > 0)
              Text(
                _lastElementSearchCount > 0
                    ? 'Showing $_lastElementSearchCount element candidate(s).'
                    : 'Showing ${_elementSuggestions.length} element candidate(s).',
                style: TextStyle(fontSize: 12, color: Colors.grey.shade700),
              ),
            if (_step == 0) const SizedBox(height: 8),
            if (_step == 0)
              OutlinedButton(
                onPressed: (_baseIdx == null || _busy) ? null : _prepareBaseAndAnalyze,
                child: Text(_busy ? 'Preparing...' : 'Lock Base and Continue'),
              ),
            if (_step == 1) ...[
              OutlinedButton(
                onPressed: (_elementIdx.isEmpty || _busy) ? null : _extractObjectsFromSelected,
                child: Text(_busy ? 'Finding items...' : 'Extract Source Objects'),
              ),
              if (_extractedObjects.isNotEmpty) ...[
                const SizedBox(height: 6),
                Text(
                  'Drag object chips into the preview to place them.',
                  style: TextStyle(fontSize: 12, color: Colors.grey.shade700),
                ),
                const SizedBox(height: 6),
                SizedBox(
                  height: 66,
                  child: ListView.separated(
                    scrollDirection: Axis.horizontal,
                    itemCount: _extractedObjects.length,
                    separatorBuilder: (_, __) => const SizedBox(width: 6),
                    itemBuilder: (context, i) {
                      final b64 = '${_extractedObjects[i]['objectImageBase64'] ?? ''}'.trim();
                      return Draggable<int>(
                        data: i,
                        feedback: Material(
                          elevation: 4,
                          borderRadius: BorderRadius.circular(8),
                          child: Container(
                            width: 62,
                            height: 62,
                            color: Colors.white,
                            child: b64.isNotEmpty ? Image.memory(base64Decode(b64), fit: BoxFit.cover) : const Icon(Icons.image),
                          ),
                        ),
                        childWhenDragging: Opacity(
                          opacity: 0.35,
                          child: Container(
                            width: 62,
                            height: 62,
                            color: Colors.grey.shade300,
                            child: b64.isNotEmpty ? Image.memory(base64Decode(b64), fit: BoxFit.cover) : const Icon(Icons.image),
                          ),
                        ),
                        child: Container(
                          width: 62,
                          height: 62,
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(8),
                            border: Border.all(color: Colors.grey.shade300),
                          ),
                          child: b64.isNotEmpty ? Image.memory(base64Decode(b64), fit: BoxFit.cover) : const Icon(Icons.image),
                        ),
                      );
                    },
                  ),
                ),
              ],
              OutlinedButton(
                onPressed: (_extractedObjects.isEmpty || _busy) ? null : _autoPlace,
                child: Text(_busy ? 'Arranging...' : 'Auto Place'),
              ),
            ],
            if (_step == 2) ...[
              OutlinedButton(
                onPressed: (_elementIdx.isEmpty || _busy) ? null : _extractObjectsFromSelected,
                child: Text(_busy ? 'Segmenting...' : 'Extract'),
              ),
              OutlinedButton(
                onPressed: ((_extractedObjects.isEmpty && _placements.isEmpty) || _busy) ? null : _autoPlace,
                child: const Text('Auto Place'),
              ),
              OutlinedButton(
                onPressed: (_extractedObjects.isEmpty || _busy) ? null : _recolorFirstObject,
                child: Text(_busy ? 'Changing color...' : 'Recolor Objects'),
              ),
              OutlinedButton(
                onPressed: (_placements.isEmpty || _busy)
                    ? null
                    : () => setState(() {
                          _placementSaved = true;
                          _statusHint = 'Placement saved. You can now render and apply.';
                        }),
                child: Text(_placementSaved ? 'Placement Saved' : 'Save Placement'),
              ),
              OutlinedButton(
                onPressed: (_placements.isEmpty || !_placementSaved || _busy) ? null : _renderComposite,
                child: Text(_busy ? 'Rendering...' : 'Render'),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: _promptCtrl,
                onChanged: (_) => setState(() {}),
                decoration: const InputDecoration(labelText: 'Add by prompt', hintText: 'e.g. add more flowers on table', isDense: true),
              ),
              OutlinedButton(
                onPressed: ((_baseImageB64 ?? '').isEmpty || _promptCtrl.text.trim().isEmpty || _busy)
                    ? null
                    : _addByPrompt,
                child: Text(_busy ? 'Adding...' : 'Add by Prompt'),
              ),
            ],
            SizedBox(height: isPhone ? 10 : 120),
            if (_step > 0)
              OutlinedButton(
                onPressed: () => setState(() => _step--),
                child: const Text('Back'),
              ),
            if (_step < 2)
              FilledButton(
                onPressed: (_step == 0 && _baseIdx == null) || (_step == 1 && _elementIdx.isEmpty)
                    ? null
                    : (_step == 1 ? _advanceToCompose : () => setState(() => _step++)),
                child: Text(_step == 1 ? 'Next: Compose' : 'Next'),
              ),
            if (_step == 2 && _renderedB64.trim().isNotEmpty)
              FilledButton(
                onPressed: () {
                  final base = _baseIdx == null ? '' : _templateSuggestions[_baseIdx!]['url']!;
                  final picks = _elementIdx
                      .where((i) => i >= 0 && i < _elementSuggestions.length)
                      .map((i) => _elementSuggestions[i]['url']!)
                      .toList();
                  Navigator.pop(
                    context,
                    AiThemeStudioResult(
                      baseImageUrl: base,
                      selectedElements: picks,
                      generatedNotes: _notesCtrl.text.trim(),
                      generatedImageBase64: _renderedB64.trim(),
                    ),
                  );
                },
                child: const Text('Apply and Return'),
              ),
            OutlinedButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Back to Online Inquiry'),
            ),
            ],
          ),
        ),
      ),
    );

    return Scaffold(
      appBar: AppBar(title: const Text('Event Theme Design Studio')),
      body: Padding(
        padding: const EdgeInsets.all(12),
        child: isWide
            ? Row(
                children: [
                  SizedBox(width: 280, child: leftPane),
                  const SizedBox(width: 8),
                  Expanded(child: centerPane),
                  const SizedBox(width: 8),
                  SizedBox(width: 260, child: rightPane),
                ],
              )
            : Column(
                children: [
                  leftPane,
                  const SizedBox(height: 8),
                  Expanded(child: centerPane),
                  const SizedBox(height: 8),
                  SizedBox(height: 300, child: rightPane),
                ],
              ),
      ),
    );
  }
}

class TrayScreen extends StatelessWidget {
  const TrayScreen({super.key, required this.state});
  final AppState state;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: state,
      builder: (context, _) {
        return AppScaffold(
          state: state,
          title: 'YOUR TRAY',
          showTrayShortcut: false,
          body: Column(
            children: [
              Expanded(
                child: RefreshIndicator(
                  onRefresh: () async {
                    await state.loadMenu(force: true);
                    await state.pullCustomerTrayDraftFromServer();
                  },
                  child: state.tray.isEmpty
                      ? ListView(
                          physics: const AlwaysScrollableScrollPhysics(),
                          children: const [
                            SizedBox(height: 160),
                            Center(child: Text('Your tray is empty.')),
                          ],
                        )
                      : ListView.builder(
                          physics: const AlwaysScrollableScrollPhysics(),
                          padding: const EdgeInsets.all(12),
                          itemCount: state.tray.length,
                          itemBuilder: (context, index) {
                            final item = state.tray[index];
                            return Card(
                              child: ListTile(
                                leading: SizedBox(
                                  width: 56,
                                  height: 56,
                                  child: ClipRRect(
                                    borderRadius: BorderRadius.circular(8),
                                    child: _MenuThumb(item: item.menu, compact: true),
                                  ),
                                ),
                                title: Text(item.menu.name),
                                subtitle: Text('${item.dip.isEmpty ? 'No dip' : item.dip}\n₱${item.menu.price.toStringAsFixed(2)}'),
                                trailing: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    IconButton(
                                      onPressed: () {
                                        state.changeQty(item, 1);
                                      },
                                      icon: const Icon(Icons.add_circle, color: AppColors.success),
                                    ),
                                    Text('${item.qty}', style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 16)),
                                    IconButton(
                                      onPressed: () {
                                        final q = item.qty;
                                        state.changeQty(item, -1);
                                        if (q <= 1) {
                                          appSnack(context, 'Removed ${item.menu.name} from tray');
                                        }
                                      },
                                      icon: const Icon(Icons.remove_circle, color: AppColors.accent),
                                    ),
                                  ],
                                ),
                              ),
                            );
                          },
                        ),
                ),
              ),
              SummaryFooter(
                lines: [SummaryLine('SUBTOTAL', '₱${state.subtotal.toStringAsFixed(2)}')],
                actionLabel: 'CHECKOUT',
                onAction: state.tray.isEmpty
                    ? null
                    : () {
                        Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => CheckoutScreen(state: state)));
                      },
              ),
            ],
          ),
        );
      },
    );
  }
}

class CheckoutScreen extends StatefulWidget {
  const CheckoutScreen({super.key, required this.state});
  final AppState state;

  @override
  State<CheckoutScreen> createState() => _CheckoutScreenState();
}

class _CheckoutScreenState extends State<CheckoutScreen> {
  /// Kept in [State] so expanding/collapsing sections survives pushing [PaymentScreen] and popping back.
  bool showDelivery = true;
  bool showTray = true;
  bool showNotes = true;
  final noteController = TextEditingController();
  final List<String> _deliveryAddresses = [];
  String? _selectedDeliveryAddress;
  String _selectedDeliveryTime = 'NOW';

  @override
  void initState() {
    super.initState();
    noteController.text = widget.state.checkoutNote;
    final profile = widget.state.profile;
    final fromProfile = List<String>.from(profile.deliveryAddresses);
    final primary = profile.deliveryAddress.trim();
    final merged = <String>{...fromProfile};
    if (primary.isNotEmpty) merged.add(primary);
    _deliveryAddresses.addAll(merged);
    final savedSel = widget.state.checkoutSelectedAddress?.trim();
    if (savedSel != null && savedSel.isNotEmpty && _deliveryAddresses.contains(savedSel)) {
      _selectedDeliveryAddress = savedSel;
    } else if (_deliveryAddresses.isNotEmpty) {
      _selectedDeliveryAddress = _deliveryAddresses.first;
    }
    _selectedDeliveryTime = widget.state.checkoutDeliveryTime.trim().isEmpty ? 'NOW' : widget.state.checkoutDeliveryTime.trim();
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      await widget.state.loadMenu(force: true);
      await widget.state.pullCustomerTrayDraftFromServer();
      if (!mounted) return;
      if (widget.state.tray.isEmpty) {
        appSnack(context, 'Your tray is empty.');
        Navigator.of(context).maybePop();
        return;
      }
      setState(() {});
    });
  }

  Future<void> _pickScheduledDelivery() async {
    final now = DateTime.now();
    final d = await showDatePicker(
      context: context,
      initialDate: now,
      firstDate: now,
      lastDate: now.add(const Duration(days: 60)),
    );
    if (d == null || !mounted) return;
    final t = await showTimePicker(context: context, initialTime: TimeOfDay.now());
    if (t == null || !mounted) return;
    final dt = DateTime(d.year, d.month, d.day, t.hour, t.minute);
    final label = DateFormat('yyyy-MM-dd HH:mm').format(dt);
    setState(() => _selectedDeliveryTime = label);
    widget.state.updateCheckoutDraftDeliveryTime(label);
  }

  @override
  void dispose() {
    noteController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.state;
    return AppScaffold(
      state: s,
      title: 'CHECKOUT',
      showTrayShortcut: false,
      body: Column(
        children: [
          Expanded(
            child: RefreshIndicator(
              onRefresh: () async {
                await s.loadMenu(force: true);
                await s.pullCustomerTrayDraftFromServer();
                if (mounted) setState(() {});
              },
              child: ListView(
                physics: const AlwaysScrollableScrollPhysics(),
                padding: const EdgeInsets.all(12),
                children: [
                ToggleSection(
                  title: 'DELIVERY INFORMATION',
                  expanded: showDelivery,
                  onToggle: () => setState(() => showDelivery = !showDelivery),
                  child: Column(
                    children: [
                      LockedField(label: 'NAME', value: s.profile.fullName),
                      LockedField(label: 'CONTACT NUMBER', value: s.profile.contactNumber),
                      DropdownButtonFormField<String>(
                        isExpanded: true,
                        value: _selectedDeliveryAddress,
                        decoration: const InputDecoration(labelText: 'DELIVERY ADDRESS'),
                        items: _deliveryAddresses
                            .map(
                              (a) => DropdownMenuItem<String>(
                                value: a,
                                child: Text(
                                  a,
                                  maxLines: 3,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                            )
                            .toList(),
                        onChanged: (v) {
                          setState(() => _selectedDeliveryAddress = v);
                          widget.state.updateCheckoutDraftAddress(v);
                        },
                      ),
                      if (_deliveryAddresses.isEmpty)
                        Padding(
                          padding: const EdgeInsets.only(top: 8),
                          child: Text(
                            'Add addresses in My Profile first.',
                            style: TextStyle(color: Colors.red.shade800, fontSize: 13),
                          ),
                        ),
                      LockedField(label: 'TIME OF DELIVERY', value: _selectedDeliveryTime),
                      const SizedBox(height: 8),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          OutlinedButton.icon(
                            onPressed: () {
                              setState(() => _selectedDeliveryTime = 'NOW');
                              widget.state.updateCheckoutDraftDeliveryTime('NOW');
                            },
                            icon: const Icon(Icons.flash_on_outlined, size: 18),
                            label: const Text('ASAP'),
                          ),
                          OutlinedButton.icon(
                            onPressed: _pickScheduledDelivery,
                            icon: const Icon(Icons.schedule_outlined, size: 18),
                            label: const Text('SET SCHEDULE'),
                          ),
                        ],
                      ),
                      const LockedField(label: 'MODE OF PAYMENT', value: 'GCASH ONLY'),
                    ],
                  ),
                ),
                const SizedBox(height: 10),
                const _OrderNoCard(),
                const SizedBox(height: 10),
                ToggleSection(
                  title: 'YOUR TRAY',
                  expanded: showTray,
                  onToggle: () => setState(() => showTray = !showTray),
                  child: Column(
                    children: s.tray
                        .map(
                          (e) => ListTile(
                            dense: true,
                            title: Text(e.menu.name),
                            subtitle: Text(e.dip.isEmpty ? '-' : e.dip),
                            trailing: Text('x${e.qty}  ₱${(e.qty * e.menu.price).toStringAsFixed(2)}'),
                          ),
                        )
                        .toList(),
                  ),
                ),
                const SizedBox(height: 10),
                ToggleSection(
                  title: 'NOTES',
                  expanded: showNotes,
                  onToggle: () => setState(() => showNotes = !showNotes),
                  child: TextField(
                    controller: noteController,
                    maxLines: 4,
                    decoration: const InputDecoration(hintText: 'Write notes here...'),
                    onChanged: s.updateCheckoutDraftNote,
                  ),
                ),
              ],
              ),
            ),
          ),
          SummaryFooter(
            lines: [SummaryLine('YOUR ORDER', '₱${s.subtotal.toStringAsFixed(2)}'), SummaryLine('TOTAL', '₱${s.subtotal.toStringAsFixed(2)}', isTotal: true)],
            secondaryLabel: 'CANCEL',
            actionLabel: 'CONFIRM',
            onSecondary: () => Navigator.of(context).pop(),
            onAction: () async {
              if (s.tray.isEmpty) {
                appSnack(context, 'Your tray is empty.');
                return;
              }
              if ((_selectedDeliveryAddress ?? '').trim().isEmpty) {
                appSnack(context, 'Select your delivery address.');
                return;
              }
              if (s.profile.fullName.trim().isEmpty || s.profile.contactNumber.trim().isEmpty) {
                appSnack(context, 'Complete your name and contact number in My Profile first.');
                return;
              }
              s.profile.deliveryAddress = _selectedDeliveryAddress!.trim();
              s.updateCheckoutDraftDeliveryTime(_selectedDeliveryTime);
              final okCheckout = await showDialog<bool>(
                context: context,
                builder: (ctx) => AlertDialog(
                  title: const Text('Confirm order'),
                  content: Text(
                    'Place order ${s.tray.fold<int>(0, (n, i) => n + i.qty)} item(s) for ₱${s.subtotal.toStringAsFixed(2)}?',
                  ),
                  actions: [
                    TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
                    FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Confirm')),
                  ],
                ),
              );
              if (okCheckout != true || !context.mounted) return;
              Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => PaymentScreen(
                    state: s,
                    order: null,
                    note: noteController.text,
                    draftCheckout: true,
                  ),
                ),
              );
            },
          ),
        ],
      ),
    );
  }
}

class PaymentScreen extends StatefulWidget {
  const PaymentScreen({
    super.key,
    required this.state,
    this.order,
    required this.note,
    this.draftCheckout = false,
  });
  final AppState state;
  final OrderData? order;
  final String note;
  /// Checkout → payment without creating the server order yet (order is created when payment proof is uploaded).
  final bool draftCheckout;

  @override
  State<PaymentScreen> createState() => _PaymentScreenState();
}

class _PaymentScreenState extends State<PaymentScreen> {
  OrderData? _placedOrder;
  bool localProofUploaded = false;
  bool _uploadingProof = false;
  bool showPayment = true;
  bool showTray = true;
  bool showNotes = true;
  bool showDelivery = true;
  XFile? uploadedFile;
  Uint8List? _localProofBytes;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      await widget.state.loadOrders(force: true);
      if (!mounted) return;
      if (widget.draftCheckout &&
          _placedOrder == null &&
          widget.state.tray.isEmpty) {
        appSnack(context, 'Your tray is empty.');
        Navigator.of(context).maybePop();
        return;
      }
      setState(() {});
    });
  }

  OrderData? _syncedOrder(AppState s) {
    final base = _placedOrder ?? widget.order;
    if (base == null) return null;
    for (final o in s.orders) {
      if (o.id == base.id) return o;
    }
    return null;
  }

  OrderData _draftSnapshot(AppState s) {
    return OrderData(
      id: 0,
      orderNo: '—',
      status: 'DRAFT',
      total: s.subtotal,
      createdAt: DateTime.now(),
      lines: s.tray
          .map(
            (e) => OrderLineItem(
              itemName: e.menu.name,
              dip: e.dip,
              qty: e.qty,
              price: e.menu.price,
            ),
          )
          .toList(),
      userEmail: s.userEmail,
      note: widget.note,
      paymentMode: 'GCASH ONLY',
      deliveryName: s.profile.fullName,
      deliveryContact: s.profile.contactNumber,
      deliveryAddress: s.profile.deliveryAddress,
      deliveryTime: s.checkoutDeliveryTime,
    );
  }

  Future<void> _pickAndUploadProof({required bool insufficient, ImageSource source = ImageSource.gallery}) async {
    if (_uploadingProof) return;
    if (widget.draftCheckout && widget.state.tray.isEmpty) {
      appSnack(context, 'Your tray is empty.');
      return;
    }
    final picker = ImagePicker();
    final file = await picker.pickImage(
      source: source,
      imageQuality: 72,
      maxWidth: 1600,
      maxHeight: 1600,
    );
    if (file == null) return;
    final bytes = await file.readAsBytes();
    final s = widget.state;
    setState(() => _uploadingProof = true);
    try {
    if (widget.draftCheckout && _placedOrder == null) {
      if (!mounted) return;
      showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (_) => const Center(child: CircularProgressIndicator()),
      );
      final result = await s.submitOrder(clearCheckoutDraft: false);
      if (!mounted) return;
      Navigator.of(context).pop();
      if (result.error != null) {
        appSnack(context, result.error!);
        return;
      }
      final newOrder = result.order!;
      final err = await s.uploadPaymentProof(newOrder.id, file);
      if (!mounted) return;
      if (err != null) {
        appSnack(context, err);
        return;
      }
      await s.clearCheckoutAfterSuccessfulOrderAndPayment();
      setState(() {
        _placedOrder = newOrder;
        uploadedFile = file;
        _localProofBytes = bytes;
        localProofUploaded = true;
      });
      await s.loadOrders(force: true);
      appSnack(context, 'Payment proof uploaded — your order is placed.');
      return;
    }
    final oid = (_placedOrder ?? widget.order)!.id;
    final err = await s.uploadPaymentProof(oid, file);
    if (!mounted) return;
    if (err != null) {
      appSnack(context, err);
      return;
    }
    setState(() {
      uploadedFile = file;
      _localProofBytes = bytes;
      localProofUploaded = true;
    });
    appSnack(context, insufficient ? 'Balance payment proof uploaded' : 'Payment proof uploaded');
    } finally {
      if (mounted) setState(() => _uploadingProof = false);
    }
  }

  Widget _paymentProofPreview(OrderData? synced) {
    if (_localProofBytes != null) {
      final bytes = _localProofBytes!;
      return Padding(
        padding: const EdgeInsets.only(top: 10),
        child: InkWell(
          onTap: () => showProofFullScreen(context, bytes, title: 'Payment proof'),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(10),
            child: Image.memory(bytes, height: 160, fit: BoxFit.contain),
          ),
        ),
      );
    }
    final b64 = synced?.paymentProofBase64;
    if (b64 != null && b64.isNotEmpty) {
      try {
        final bytes = base64Decode(b64);
        return Padding(
          padding: const EdgeInsets.only(top: 10),
          child: InkWell(
            onTap: () => showProofFullScreen(context, Uint8List.fromList(bytes), title: 'Payment proof'),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(10),
              child: Image.memory(Uint8List.fromList(bytes), height: 160, fit: BoxFit.contain),
            ),
          ),
        );
      } catch (_) {}
    }
    return const SizedBox.shrink();
  }

  Widget _supplementalProofPreview(OrderData? synced) {
    final b64 = synced?.supplementalPaymentProofBase64;
    if (b64 == null || b64.isEmpty) return const SizedBox.shrink();
    try {
      final bytes = base64Decode(b64);
      return Padding(
        padding: const EdgeInsets.only(top: 10),
        child: InkWell(
          onTap: () => showProofFullScreen(context, Uint8List.fromList(bytes), title: 'Balance payment proof'),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(10),
            child: Image.memory(Uint8List.fromList(bytes), height: 140, fit: BoxFit.contain),
          ),
        ),
      );
    } catch (_) {
      return const SizedBox.shrink();
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.state;
    final p = s.profile;
    return ListenableBuilder(
      listenable: s,
      builder: (context, _) {
        final isDraft = widget.draftCheckout && _placedOrder == null;
        final synced = _syncedOrder(s);
        final orderForUi = isDraft ? _draftSnapshot(s) : (synced ?? _placedOrder ?? widget.order!);
        final insufficient = !isDraft && orderForUi.status.toUpperCase().contains('INSUFFICIENT');
        final paidSoFar = orderForUi.cashierAmountReceived ?? 0;
        final remainder = (orderForUi.total - paidSoFar).clamp(0, double.infinity);
        final supplementalOk =
            (synced?.supplementalPaymentProofBase64?.trim().isNotEmpty ?? false) || (insufficient && localProofUploaded);
        final proofDone = insufficient
            ? supplementalOk
            : ((synced?.paymentUploaded ?? false) ||
                localProofUploaded ||
                ((synced?.paymentProofBase64?.isNotEmpty ?? false)));
        return AppScaffold(
          state: s,
          title: 'PAYMENT',
          showTrayShortcut: false,
          body: Column(
            children: [
              if (_uploadingProof) const LinearProgressIndicator(minHeight: 3),
              Expanded(
                child: RefreshIndicator(
                  onRefresh: () async {
                    await s.loadOrders(force: true);
                    if (mounted) setState(() {});
                  },
                  child: ListView(
                    physics: const AlwaysScrollableScrollPhysics(),
                    padding: const EdgeInsets.all(12),
                    children: [
                    _OrderNoCard(displayNo: isDraft ? null : orderForUi.orderNo),
                    const SizedBox(height: 10),
                    if (insufficient) ...[
                      Card(
                        color: Colors.orange.shade50,
                        child: Padding(
                          padding: const EdgeInsets.all(12),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const Text('Additional payment required', style: TextStyle(fontWeight: FontWeight.w800)),
                              const SizedBox(height: 8),
                              Text('Amount we recorded from your first payment: ₱${paidSoFar.toStringAsFixed(2)}'),
                              Text('Order total: ₱${orderForUi.total.toStringAsFixed(2)}'),
                              Text(
                                'Remaining balance to confirm order: ₱${remainder.toStringAsFixed(2)}',
                                style: const TextStyle(fontWeight: FontWeight.w800),
                              ),
                              const SizedBox(height: 8),
                              const Text(
                                'Upload proof of your additional GCash payment below.',
                                style: TextStyle(fontSize: 12, height: 1.35),
                              ),
                            ],
                          ),
                        ),
                      ),
                      const SizedBox(height: 10),
                    ],
                    ToggleSection(
                      title: 'PAYMENT',
                      titleColor: proofDone ? AppColors.brand : AppColors.accent,
                      expanded: showPayment,
                      onToggle: () => setState(() => showPayment = !showPayment),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(insufficient ? 'Scan QR to pay the remaining balance' : 'Please scan the QR code below to pay'),
                          const SizedBox(height: 10),
                          Container(
                            height: 140,
                            width: double.infinity,
                            color: Colors.white,
                            alignment: Alignment.center,
                            padding: const EdgeInsets.all(8),
                            child: Image.asset(
                              AppBrandAssets.qrCode,
                              fit: BoxFit.contain,
                            ),
                          ),
                          const SizedBox(height: 12),
                          LayoutBuilder(
                            builder: (context, c) {
                              final narrow = c.maxWidth < 560;
                              if (narrow) {
                                return Column(
                                  crossAxisAlignment: CrossAxisAlignment.stretch,
                                  children: [
                                    Text(
                                      insufficient
                                          ? 'After paying the remaining balance, upload proof here.'
                                          : 'Once paid, upload proof of payment',
                                      maxLines: 3,
                                    ),
                                    const SizedBox(height: 8),
                                    Row(
                                      children: [
                                        Expanded(
                                          child: OutlinedButton(
                                            onPressed: _uploadingProof
                                                ? null
                                                : () => _pickAndUploadProof(insufficient: insufficient),
                                            child: Text(
                                              insufficient
                                                  ? (proofDone ? 'CHANGE BALANCE PROOF' : 'UPLOAD BALANCE PROOF')
                                                  : (uploadedFile == null && !proofDone ? 'UPLOAD' : 'CHANGE PHOTO'),
                                            ),
                                          ),
                                        ),
                                        const SizedBox(width: 8),
                                        OutlinedButton.icon(
                                          onPressed: _uploadingProof
                                              ? null
                                              : () => _pickAndUploadProof(insufficient: insufficient, source: ImageSource.camera),
                                          icon: const Icon(Icons.photo_camera_outlined, size: 18),
                                          label: const Text('CAMERA'),
                                        ),
                                      ],
                                    ),
                                  ],
                                );
                              }
                              return Row(
                                children: [
                                  Expanded(
                                    child: Text(
                                      insufficient
                                          ? 'After paying the remaining balance, upload proof here.'
                                          : 'Once paid, upload proof of payment',
                                    ),
                                  ),
                                  OutlinedButton(
                                    onPressed: _uploadingProof ? null : () => _pickAndUploadProof(insufficient: insufficient),
                                    child: Text(
                                      insufficient
                                          ? (proofDone ? 'CHANGE BALANCE PROOF' : 'UPLOAD BALANCE PROOF')
                                          : (uploadedFile == null && !proofDone ? 'UPLOAD' : 'CHANGE PHOTO'),
                                    ),
                                  ),
                                  const SizedBox(width: 8),
                                  OutlinedButton.icon(
                                    onPressed: _uploadingProof
                                        ? null
                                        : () => _pickAndUploadProof(insufficient: insufficient, source: ImageSource.camera),
                                    icon: const Icon(Icons.photo_camera_outlined, size: 18),
                                    label: const Text('CAMERA'),
                                  ),
                                ],
                              );
                            },
                          ),
                          if (!insufficient) _paymentProofPreview(synced),
                          if (insufficient) ...[
                            if (synced?.paymentProofBase64?.isNotEmpty ?? false) ...[
                              const SizedBox(height: 10),
                              const Text('Original payment proof', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 12)),
                              Padding(
                                padding: const EdgeInsets.only(top: 6),
                                child: InkWell(
                                  onTap: () => showProofFullScreen(
                                    context,
                                    Uint8List.fromList(base64Decode(synced.paymentProofBase64!)),
                                    title: 'Original payment proof',
                                  ),
                                  child: ClipRRect(
                                    borderRadius: BorderRadius.circular(10),
                                    child: Image.memory(
                                      Uint8List.fromList(base64Decode(synced!.paymentProofBase64!)),
                                      height: 120,
                                      fit: BoxFit.contain,
                                    ),
                                  ),
                                ),
                              ),
                            ],
                            const SizedBox(height: 10),
                            const Text('Balance payment proof', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 12)),
                            if (_localProofBytes != null)
                              Padding(
                                padding: const EdgeInsets.only(top: 6),
                                child: InkWell(
                                  onTap: () => showProofFullScreen(context, _localProofBytes!, title: 'Balance payment proof'),
                                  child: ClipRRect(
                                    borderRadius: BorderRadius.circular(10),
                                    child: Image.memory(_localProofBytes!, height: 160, fit: BoxFit.contain),
                                  ),
                                ),
                              )
                            else
                              _supplementalProofPreview(synced),
                          ],
                        ],
                      ),
                    ),
                    const SizedBox(height: 10),
                    ToggleSection(
                      title: 'YOUR TRAY',
                      expanded: showTray,
                      onToggle: () => setState(() => showTray = !showTray),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          if (isDraft)
                            ...s.tray.map(
                              (e) => ListTile(
                                dense: true,
                                title: Text(e.menu.name),
                                subtitle: Text(e.dip.isEmpty ? '-' : e.dip),
                                trailing: Text('x${e.qty}  ₱${(e.qty * e.menu.price).toStringAsFixed(2)}'),
                              ),
                            )
                          else if (orderForUi.lines.isEmpty)
                            const Text('No tray lines available.')
                          else
                            ...orderForUi.lines.map(
                              (l) => ListTile(
                                dense: true,
                                title: Text(l.itemName),
                                subtitle: Text(l.dip.isEmpty ? '-' : l.dip),
                                trailing: Text('x${l.qty}  ₱${(l.qty * l.price).toStringAsFixed(2)}'),
                              ),
                            ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 10),
                    ToggleSection(
                      title: 'NOTES',
                      expanded: showNotes,
                      onToggle: () => setState(() => showNotes = !showNotes),
                      child: Text(widget.note.trim().isEmpty ? 'Notes is empty.' : widget.note),
                    ),
                    const SizedBox(height: 10),
                    ToggleSection(
                      title: 'DELIVERY INFORMATION',
                      expanded: showDelivery,
                      onToggle: () => setState(() => showDelivery = !showDelivery),
                      child: Column(
                        children: [
                          LockedField(label: 'NAME', value: p.fullName),
                          LockedField(label: 'CONTACT NUMBER', value: p.contactNumber),
                          LockedField(label: 'DELIVERY ADDRESS', value: p.deliveryAddress),
                          const LockedField(label: 'TIME OF DELIVERY', value: 'NOW'),
                        ],
                      ),
                    ),
                  ],
                  ),
                ),
              ),
              SummaryFooter(
                lines: [
                  SummaryLine('YOUR ORDER', '₱${orderForUi.total.toStringAsFixed(2)}'),
                  SummaryLine('TOTAL', '₱${orderForUi.total.toStringAsFixed(2)}', isTotal: true),
                ],
                secondaryLabel: 'BACK',
                actionLabel: insufficient ? 'SUBMIT BALANCE PAYMENT' : 'SUBMIT ORDER',
                onSecondary: () => Navigator.of(context).pop(),
                onAction: () {
                  final syncedNow = _syncedOrder(s);
                  final ordNow = syncedNow ?? _placedOrder ?? widget.order;
                  if (ordNow == null || ordNow.id == 0) {
                    appSnack(context, 'Upload proof of payment first.');
                    return;
                  }
                  final insNow = ordNow.status.toUpperCase().contains('INSUFFICIENT');
                  final ok = insNow
                      ? (((syncedNow?.supplementalPaymentProofBase64?.trim().isNotEmpty ?? false) || localProofUploaded))
                      : ((syncedNow?.paymentUploaded ?? false) ||
                          localProofUploaded ||
                          ((syncedNow?.paymentProofBase64?.isNotEmpty ?? false)));
                  if (!ok) {
                    appSnack(context, insNow ? 'Upload balance payment proof before continuing.' : 'Upload proof of payment before continuing.');
                    return;
                  }
                  showDialog<bool>(
                    context: context,
                    builder: (ctx) => AlertDialog(
                      title: Text(insNow ? 'Submit balance payment?' : 'Submit order?'),
                      content: Text(
                        insNow
                            ? 'Please confirm your remaining balance payment proof before submitting.'
                            : 'Please confirm all details before submitting this order.',
                      ),
                      actions: [
                        TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Back')),
                        FilledButton(
                          onPressed: () => Navigator.pop(ctx, true),
                          child: Text(insNow ? 'Submit balance payment' : 'Submit order'),
                        ),
                      ],
                    ),
                  ).then((okSubmit) {
                    if (okSubmit != true || !context.mounted) return;
                    Navigator.of(context).pushReplacement(
                      MaterialPageRoute<void>(
                        builder: (_) => OrderStatusScreen(state: s, order: ordNow, paymentUploaded: true),
                      ),
                    );
                  });
                },
              ),
            ],
          ),
        );
      },
    );
  }
}

class OrderStatusScreen extends StatefulWidget {
  const OrderStatusScreen({
    super.key,
    required this.state,
    required this.order,
    required this.paymentUploaded,
  });

  final AppState state;
  final OrderData order;
  final bool paymentUploaded;

  @override
  State<OrderStatusScreen> createState() => _OrderStatusScreenState();
}

class _OrderStatusScreenState extends State<OrderStatusScreen> {
  OrderData _resolvedOrder() {
    for (final o in widget.state.orders) {
      if (o.id == widget.order.id) return o;
    }
    return widget.order;
  }

  bool _proofReceived(OrderData o) {
    return widget.paymentUploaded ||
        o.paymentUploaded ||
        (o.paymentProofBase64 != null && o.paymentProofBase64!.trim().isNotEmpty);
  }

  @override
  Widget build(BuildContext context) {
    final state = widget.state;
    final order = _resolvedOrder();
    final track = order.deliveryTrackingUrl.trim();
    final st = order.status.toUpperCase();
    final canFollowUp = st.contains('WAITING FOR PAYMENT CONFIRMATION') ||
        st.contains('WAITING FOR BALANCE PAYMENT CONFIRMATION') ||
        st.contains('WAITING FOR ORDER CONFIRMATION');
    return AppScaffold(
      state: state,
      title: 'ORDER STATUS',
      onBackPressed: () {
        Navigator.of(context).pushAndRemoveUntil(
          MaterialPageRoute<void>(builder: (_) => CustomerDashboardScreen(state: state)),
          (_) => false,
        );
      },
      body: RefreshIndicator(
        onRefresh: () async {
          await state.loadOrders(force: true);
          if (mounted) setState(() {});
        },
        child: SingleChildScrollView(
          physics: const AlwaysScrollableScrollPhysics(),
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(order.orderNo, style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w800)),
                        const SizedBox(height: 8),
                        Text('Status: ${statusReadable(order.status)}'),
                        Text('Total: ₱${order.total.toStringAsFixed(2)}'),
                        Text('Payment proof: ${_proofReceived(order) ? 'Received' : 'Not uploaded yet'}'),
                        if (canFollowUp) ...[
                          const SizedBox(height: 10),
                          OutlinedButton.icon(
                            onPressed: () async {
                              final err = await state.submitHelpRequest(
                                area: 'Order Follow-up',
                                problem: 'Follow-up on pending order ${order.orderNo}',
                                desiredOutcome: 'Please review this order and update the payment/order confirmation status.',
                              );
                              if (!context.mounted) return;
                              appSnack(context, err ?? 'Follow-up sent');
                            },
                            icon: const Icon(Icons.reply_outlined),
                            label: const Text('FOLLOW UP'),
                          ),
                        ],
                        if (track.isNotEmpty) ...[
                          const SizedBox(height: 12),
                          Text('Delivery tracking', style: Theme.of(context).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700)),
                          const SizedBox(height: 6),
                          Builder(
                            builder: (context) {
                              final u = Uri.tryParse(track);
                              final tappable = u != null && u.hasScheme && (u.scheme == 'http' || u.scheme == 'https');
                              if (tappable) {
                                return InkWell(
                                  onTap: () => launchUrl(u, mode: LaunchMode.externalApplication),
                                  child: Text(
                                    track,
                                    style: TextStyle(
                                      color: Colors.blue.shade800,
                                      decoration: TextDecoration.underline,
                                      height: 1.35,
                                    ),
                                  ),
                                );
                              }
                              return SelectableText(track);
                            },
                          ),
                          const SizedBox(height: 8),
                          FilledButton.icon(
                            onPressed: () async {
                              final u = Uri.tryParse(track);
                              if (u != null && await canLaunchUrl(u)) {
                                await launchUrl(u, mode: LaunchMode.externalApplication);
                              }
                            },
                            icon: const Icon(Icons.open_in_new),
                            label: const Text('OPEN TRACKING LINK'),
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                FilledButton(
                  onPressed: () {
                    Navigator.of(context).pushAndRemoveUntil(
                      MaterialPageRoute<void>(builder: (_) => RestaurantMenuScreen(state: state)),
                      (_) => false,
                    );
                  },
                  child: const Text('BACK TO MENU'),
                ),
                const SizedBox(height: 10),
                OutlinedButton(
                  onPressed: () {
                    Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => MyOrdersScreen(state: state)));
                  },
                  child: const Text('MY ORDERS'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class MyOrdersScreen extends StatefulWidget {
  const MyOrdersScreen({super.key, required this.state});
  final AppState state;

  @override
  State<MyOrdersScreen> createState() => _MyOrdersScreenState();
}

class _MyOrdersScreenState extends State<MyOrdersScreen> with SingleTickerProviderStateMixin {
  bool _isInsufficient(OrderData o) => o.status.toUpperCase().contains('INSUFFICIENT');
  bool _needsAttention(OrderData o) => widget.state.orderNosWithUnreadAttention.contains(o.orderNo);
  bool _canFollowUp(OrderData o) {
    final u = o.status.toUpperCase();
    if (u.contains('PAYMENT INSUFFICIENT') || u.contains('INSUFFICIENT')) return false;
    // Follow-up only when cashier confirmation is still needed (after the user paid the remainder).
    return u.contains('WAITING FOR PAYMENT CONFIRMATION') ||
        u.contains('WAITING FOR BALANCE PAYMENT CONFIRMATION') ||
        u.contains('WAITING FOR ORDER CONFIRMATION');
  }

  bool _canCustomerCancelOrder(OrderData o) {
    if (customerOrderCancelled(o) || orderLooksCompleted(o)) return false;
    final u = o.status.toUpperCase();
    return u.contains('WAITING FOR PAYMENT') ||
        u.contains('WAITING FOR ORDER') ||
        u.contains('INSUFFICIENT');
  }

  Future<void> _confirmCancelOrder(OrderData o) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Cancel this order?'),
        content: Text('Cancel ${o.orderNo}? It will appear under Cancelled orders.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('No')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Yes, cancel')),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    final err = await widget.state.cancelOrderAsCustomer(orderId: o.id);
    if (!mounted) return;
    appSnack(context, err ?? 'Order cancelled');
  }
  Color _fulfillmentStageColor(String stage) {
    switch (stage.toUpperCase()) {
      case 'OUT_FOR_DELIVERY':
        return Colors.orange.shade800;
      case 'IN_PREPARATION':
        return Colors.blue.shade700;
      case 'DELIVERED':
        return Colors.green.shade700;
      default:
        return Colors.grey.shade700;
    }
  }

  Color _orderStatusBadgeBg(OrderData o) {
    final up = statusReadableForOrder(o).toUpperCase();
    if (up.contains('INSUFFICIENT')) return Colors.red.shade100;
    if (up.contains('CONFIRMED')) return Colors.green.shade100;
    if (up.contains('CANCEL')) return Colors.grey.shade300;
    return Colors.amber.shade100;
  }

  Color _orderStatusBadgeFg(OrderData o) {
    final up = statusReadableForOrder(o).toUpperCase();
    if (up.contains('INSUFFICIENT')) return Colors.red.shade900;
    if (up.contains('CONFIRMED')) return Colors.green.shade900;
    if (up.contains('CANCEL')) return Colors.grey.shade900;
    return Colors.orange.shade900;
  }
  Future<void> _followUpOrder(OrderData o) async {
    final err = await widget.state.submitHelpRequest(
      area: 'Order Follow-up',
      problem: 'Follow-up on pending order ${o.orderNo}',
      desiredOutcome: 'Please update this order status or next action.',
    );
    if (!mounted) return;
    appSnack(context, err ?? 'Follow-up sent');
  }

  late TabController _tab;
  String _search = '';
  String _filter = 'all';

  @override
  void initState() {
    super.initState();
    _tab = TabController(length: 4, vsync: this);
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      await widget.state.loadOrders(force: true);
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _tab.dispose();
    super.dispose();
  }

  List<OrderData> _ordersForTab(int tabIndex) {
    final all = widget.state.orders;
    switch (tabIndex) {
      case 0:
        final pending = all.where(customerOrderPendingTab).toList();
        pending.sort((a, b) {
          final ai = (_isInsufficient(a) || _needsAttention(a)) ? 0 : 1;
          final bi = (_isInsufficient(b) || _needsAttention(b)) ? 0 : 1;
          if (ai != bi) return ai - bi;
          return b.createdAt.compareTo(a.createdAt);
        });
        return pending;
      case 1:
        return all.where(customerOrderConfirmedTab).toList();
      case 2:
        return all.where(orderLooksCompleted).toList();
      case 3:
        return all.where(customerOrderCancelled).toList();
      default:
        return [];
    }
  }

  Widget _paymentThumb(OrderData o) {
    final b64 = o.paymentProofBase64?.trim();
    if (b64 == null || b64.isEmpty) {
      return const Icon(Icons.receipt_long_outlined, size: 36);
    }
    try {
      final bytes = base64Decode(b64);
      return ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: Image.memory(Uint8List.fromList(bytes), width: 52, height: 52, fit: BoxFit.cover),
      );
    } catch (_) {
      return const Icon(Icons.broken_image_outlined, size: 36);
    }
  }

  Widget _tabBody(int tabIndex) {
    final query = _search.trim().toLowerCase();
    final filtered = _ordersForTab(tabIndex).where((o) {
      if (query.isEmpty) return true;
      return o.orderNo.toLowerCase().contains(query) ||
          statusReadable(o.status).toLowerCase().contains(query) ||
          fulfillmentStageReadable(o.fulfillmentStage).toLowerCase().contains(query);
    }).where((o) {
      switch (_filter) {
        case 'attention':
          return _needsAttention(o) || _isInsufficient(o);
        case 'payment_uploaded':
          return o.paymentUploaded || (o.paymentProofBase64?.trim().isNotEmpty ?? false);
        default:
          return true;
      }
    }).toList();
    return RefreshIndicator(
      onRefresh: () async {
        await widget.state.loadOrders(force: true);
        if (mounted) setState(() {});
      },
      child: filtered.isEmpty
          ? ListView(
              physics: const AlwaysScrollableScrollPhysics(),
              children: const [
                SizedBox(height: 140, child: Center(child: Text('No orders in this list.'))),
              ],
            )
          : ListView.builder(
              physics: const AlwaysScrollableScrollPhysics(),
              padding: const EdgeInsets.only(bottom: 16),
              itemCount: filtered.length,
              itemBuilder: (context, index) {
                final o = filtered[index];
                final alert = tabIndex == 0 && (_isInsufficient(o) || _needsAttention(o));
                return Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                  child: Stack(
                    clipBehavior: Clip.none,
                    children: [
                      Card(
                          color: alert ? Colors.amber.shade50 : null,
                        child: ListTile(
                          dense: true,
                          visualDensity: VisualDensity.compact,
                          contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                          minVerticalPadding: 0,
                          leading: _paymentThumb(o),
                          title: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Container(
                                constraints: const BoxConstraints(maxWidth: 190),
                                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                                decoration: BoxDecoration(
                                  color: _orderStatusBadgeBg(o),
                                  borderRadius: BorderRadius.circular(999),
                                ),
                                child: Text(
                                  statusReadableForOrder(o),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    fontSize: 10.5,
                                    fontWeight: FontWeight.w700,
                                    color: _orderStatusBadgeFg(o),
                                  ),
                                ),
                              ),
                              const SizedBox(height: 4),
                              Text(o.orderNo),
                            ],
                          ),
                          subtitle: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                fulfillmentStageReadable(o.fulfillmentStage),
                                style: TextStyle(
                                  fontWeight: FontWeight.w800,
                                  color: _fulfillmentStageColor(o.fulfillmentStage),
                                  height: 1.2,
                                ),
                              ),
                              if (o.loyaltyPointsEarned > 0 && (tabIndex == 1 || tabIndex == 2))
                                Text('Loyalty: +${o.loyaltyPointsEarned} pts', style: const TextStyle(fontSize: 12)),
                              Text(formatDateTimeLocal(o.createdAt), style: const TextStyle(fontSize: 12)),
                              const SizedBox(height: 4),
                              Text(
                                '₱${o.total.toStringAsFixed(2)}',
                                style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 12.5),
                              ),
                            ],
                          ),
                    isThreeLine: false,
                    trailing: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 92, minHeight: 0),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        mainAxisAlignment: MainAxisAlignment.end,
                        crossAxisAlignment: CrossAxisAlignment.center,
                        children: [
                          if (tabIndex == 0 && _canFollowUp(o)) ...[
                            const SizedBox(width: 2),
                            IconButton(
                              tooltip: 'Follow up',
                              padding: EdgeInsets.zero,
                              visualDensity: VisualDensity.compact,
                              constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
                              icon: const Icon(Icons.reply_outlined, size: 18),
                              onPressed: () => _followUpOrder(o),
                            ),
                          ],
                          if (tabIndex == 0 && _canCustomerCancelOrder(o)) ...[
                            const SizedBox(width: 2),
                            IconButton(
                              tooltip: 'Cancel order',
                              padding: EdgeInsets.zero,
                              visualDensity: VisualDensity.compact,
                              constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
                              icon: Icon(Icons.cancel_outlined, size: 18, color: Colors.red.shade800),
                              onPressed: () => _confirmCancelOrder(o),
                            ),
                          ],
                        ],
                      ),
                    ),
                    onTap: () {
                      widget.state.markOrderAttentionRead(o.orderNo);
                      showDialog<void>(
                        context: context,
                        builder: (ctx) => AlertDialog(
                          title: Text(o.orderNo),
                          content: SingleChildScrollView(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                _detailLine('Order no.', o.orderNo),
                                _detailLine('Status', statusReadableForOrder(o)),
                                _detailLine('Fulfillment stage', fulfillmentStageReadable(o.fulfillmentStage)),
                                if (o.loyaltyPointsEarned > 0)
                                  _detailLine('Loyalty points from this order', '+${o.loyaltyPointsEarned} pts'),
                                _detailLine('Placed', formatDateTimeLocal(o.createdAt)),
                                _detailLine('Account email', o.userEmail ?? '—'),
                                const Divider(height: 24),
                                const Text('Delivery & contact', style: TextStyle(fontWeight: FontWeight.w800, fontSize: 16)),
                                const SizedBox(height: 8),
                                _detailLine('Recipient name', o.deliveryName),
                                _detailLine('Contact number', o.deliveryContact),
                                _detailLine('Delivery address', o.deliveryAddress),
                                _detailLine(
                                  'Requested delivery time',
                                  o.deliveryTime.isEmpty || o.deliveryTime == 'NOW' ? 'As soon as possible' : o.deliveryTime,
                                ),
                                _detailLine('Payment method', o.paymentMode.isEmpty ? 'GCASH ONLY' : o.paymentMode),
                                if (o.deliveryTrackingUrl.trim().isNotEmpty) _detailTrackingUrl('Delivery tracking', o.deliveryTrackingUrl.trim()),
                                if (o.note.trim().isNotEmpty) _detailLine('Your note', o.note.trim()),
                                if (o.status.toUpperCase().contains('INSUFFICIENT')) ...[
                                  const Divider(height: 24),
                                  const Text('Balance payment', style: TextStyle(fontWeight: FontWeight.w800, fontSize: 16)),
                                  const SizedBox(height: 8),
                                  if (o.cashierAmountReceived != null)
                                    _detailLine('Amount recorded by kitchen (paid so far)', '₱${o.cashierAmountReceived!.toStringAsFixed(2)}'),
                                  _detailLine(
                                    'Still needed for confirmation',
                                    '₱${(o.total - (o.cashierAmountReceived ?? 0)).clamp(0, double.infinity).toStringAsFixed(2)}',
                                  ),
                                  _detailLine(
                                    'Balance proof uploaded',
                                    (o.supplementalPaymentProofBase64?.trim().isNotEmpty ?? false) ? 'Yes' : 'Not yet — open Balance payment',
                                  ),
                                ],
                                const SizedBox(height: 8),
                                Text(
                                  'Payment proof uploaded: ${o.paymentUploaded ? 'Yes' : 'No'}',
                                  style: const TextStyle(height: 1.35),
                                ),
                                if (o.paymentProofBase64 != null && o.paymentProofBase64!.trim().isNotEmpty) ...[
                                  const SizedBox(height: 12),
                                  const Text('Payment proof', style: TextStyle(fontWeight: FontWeight.w800, fontSize: 16)),
                                  const SizedBox(height: 8),
                                  ..._buildProofPreview(o.paymentProofBase64!),
                                ],
                                if (o.supplementalPaymentProofBase64 != null && o.supplementalPaymentProofBase64!.trim().isNotEmpty) ...[
                                  const SizedBox(height: 12),
                                  const Text('Additional payment proof', style: TextStyle(fontWeight: FontWeight.w800, fontSize: 16)),
                                  const SizedBox(height: 8),
                                  ..._buildProofPreview(o.supplementalPaymentProofBase64!),
                                ],
                                const SizedBox(height: 16),
                                const Text('Dishes ordered', style: TextStyle(fontWeight: FontWeight.w800, fontSize: 16)),
                                const SizedBox(height: 8),
                                if (o.lines.isEmpty)
                                  const Text('No line items from server — pull down to refresh.')
                                else
                                  ...o.lines.map(
                                    (l) => Padding(
                                      padding: const EdgeInsets.only(bottom: 8),
                                      child: Text(
                                        '• ${l.itemName}${l.dip.isEmpty ? '' : ' — ${l.dip}'} ×${l.qty}  ₱${(l.qty * l.price).toStringAsFixed(2)}',
                                        style: const TextStyle(height: 1.35),
                                      ),
                                    ),
                                  ),
                                const SizedBox(height: 16),
                                Text('Total: ₱${o.total.toStringAsFixed(2)}', style: const TextStyle(fontWeight: FontWeight.w800)),
                              ],
                            ),
                          ),
                          actions: [
                            if (!customerOrderCancelled(o) && o.status.toUpperCase().contains('INSUFFICIENT'))
                              TextButton(
                                onPressed: () {
                                  Navigator.of(ctx).pop();
                                  Navigator.of(context).push(
                                    MaterialPageRoute<void>(
                                      builder: (_) => PaymentScreen(state: widget.state, order: o, note: o.note),
                                    ),
                                  );
                                },
                                child: const Text('Balance payment'),
                              ),
                            TextButton(onPressed: () => Navigator.of(ctx).pop(), child: const Text('Close')),
                          ],
                        ),
                      );
                    },
                        ),
                      ),
                      if (widget.state.orderNosWithUnreadAttention.contains(o.orderNo))
                        Positioned(
                          right: 18,
                          top: 10,
                          child: Container(
                            width: 12,
                            height: 12,
                            decoration: const BoxDecoration(color: Colors.red, shape: BoxShape.circle),
                          ),
                        ),
                    ],
                  ),
                );
              },
            ),
    );
  }

  Widget _detailTrackingUrl(String label, String url) {
    final uri = Uri.tryParse(url);
    final ok = uri != null && uri.hasScheme && (uri.scheme == 'http' || uri.scheme == 'https');
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: TextStyle(fontSize: 12, color: Colors.grey.shade700, fontWeight: FontWeight.w700)),
          const SizedBox(height: 4),
          if (ok)
            InkWell(
              onTap: () => launchUrl(uri, mode: LaunchMode.externalApplication),
              child: Text(
                url,
                style: TextStyle(color: Colors.blue.shade800, decoration: TextDecoration.underline, height: 1.35),
              ),
            )
          else
            SelectableText(url.isEmpty ? '—' : url, style: const TextStyle(height: 1.35)),
        ],
      ),
    );
  }

  List<Widget> _buildProofPreview(String b64) {
    try {
      final bytes = base64Decode(b64.trim());
      final asList = Uint8List.fromList(bytes);
      return [
        InkWell(
          onTap: () => showProofFullScreen(context, asList),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(10),
            child: Image.memory(asList, height: 220, fit: BoxFit.contain),
          ),
        ),
      ];
    } catch (_) {
      return [const Text('Could not decode payment proof image.')];
    }
  }

  Widget _detailLine(String label, String value) {
    final v = value.trim().isEmpty ? '—' : value.trim();
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: TextStyle(fontSize: 12, color: Colors.grey.shade700, fontWeight: FontWeight.w700)),
          const SizedBox(height: 4),
          SelectableText(v, style: const TextStyle(height: 1.35)),
        ],
      ),
    );
  }

  bool _pendingTabHasUnreadAttention() {
    final pendingNos = widget.state.orders.where(customerOrderPendingTab).map((e) => e.orderNo).toSet();
    return widget.state.orderNosWithUnreadAttention.any((id) => pendingNos.contains(id));
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: widget.state,
      builder: (context, _) {
        return AppScaffold(
          state: widget.state,
          title: 'MY ORDERS',
          body: Column(
            children: [
              Padding(
                padding: const EdgeInsets.all(12),
                child: Row(
                  children: [
                    Expanded(
                      child: TextField(
                        decoration: const InputDecoration(
                          hintText: 'Search order no., status, fulfillment — use filter for presets',
                        ),
                        onChanged: (v) => setState(() => _search = v),
                      ),
                    ),
                    const SizedBox(width: 8),
                    PopupMenuButton<String>(
                      tooltip: 'Filters',
                      icon: Icon(Icons.filter_list, color: _filter == 'all' ? null : AppColors.accent),
                      onSelected: (v) => setState(() => _filter = v),
                      itemBuilder: (_) => const [
                        PopupMenuItem(value: 'all', child: Text('All')),
                        PopupMenuItem(value: 'attention', child: Text('Needs attention')),
                        PopupMenuItem(value: 'payment_uploaded', child: Text('With payment proof')),
                      ],
                    ),
                  ],
                ),
              ),
              Material(
                color: Colors.white,
                child: TabBar(
                  controller: _tab,
                  isScrollable: true,
                  labelColor: AppColors.ink,
                  unselectedLabelColor: Colors.grey.shade700,
                  indicatorColor: AppColors.brand,
                  tabs: [
                    Tab(
                      child: Badge(
                        isLabelVisible: _pendingTabHasUnreadAttention(),
                        backgroundColor: Colors.red,
                        smallSize: 10,
                        child: const Text('Pending Confirmation'),
                      ),
                    ),
                    const Tab(text: 'Confirmed Orders'),
                    const Tab(text: 'Completed'),
                    const Tab(text: 'Cancelled'),
                  ],
                ),
              ),
              Expanded(
                child: TabBarView(
                  controller: _tab,
                  children: [_tabBody(0), _tabBody(1), _tabBody(2), _tabBody(3)],
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class MyProfileScreen extends StatefulWidget {
  const MyProfileScreen({super.key, required this.state});
  final AppState state;

  @override
  State<MyProfileScreen> createState() => _MyProfileScreenState();
}

class _MyProfileScreenState extends State<MyProfileScreen> {
  late TextEditingController nameController;
  late TextEditingController contactController;
  late TextEditingController addressController;
  late bool deliveryMapConfirmedLocal;
  double? mapLat;
  double? mapLng;
  late List<String> _savedAddresses;
  final TextEditingController _newAddressManual = TextEditingController();
  final List<String> _addrSuggestions = [];
  Timer? _addrDebounce;

  void _applyProfileToControllers() {
    final p = widget.state.profile;
    nameController.text = p.fullName;
    contactController.text = p.contactNumber;
    addressController.text = p.deliveryAddress;
    deliveryMapConfirmedLocal = p.deliveryMapConfirmed;
    mapLat = p.deliveryLat;
    mapLng = p.deliveryLng;
    _savedAddresses = List<String>.from(p.deliveryAddresses);
    final primary = p.deliveryAddress.trim();
    if (primary.isNotEmpty && !_savedAddresses.contains(primary)) {
      _savedAddresses.insert(0, primary);
    }
  }

  @override
  void initState() {
    super.initState();
    nameController = TextEditingController();
    contactController = TextEditingController();
    addressController = TextEditingController();
    _applyProfileToControllers();
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      await widget.state.loadProfile(force: true);
      if (!mounted) return;
      setState(_applyProfileToControllers);
    });
  }

  @override
  void dispose() {
    nameController.dispose();
    contactController.dispose();
    addressController.dispose();
    _newAddressManual.dispose();
    _addrDebounce?.cancel();
    super.dispose();
  }

  void _suggestAddress(String q) {
    _addrDebounce?.cancel();
    final query = q.trim();
    if (query.length < 3) {
      if (_addrSuggestions.isNotEmpty) setState(() => _addrSuggestions.clear());
      return;
    }
    _addrDebounce = Timer(const Duration(milliseconds: 280), () async {
      try {
        final local = _savedAddresses.where((a) => a.toLowerCase().contains(query.toLowerCase())).take(5).toList();
        final uri = Uri.parse(
          'https://nominatim.openstreetmap.org/search?q=${Uri.encodeComponent(query)}&format=json&limit=5',
        );
        final res = await http.get(uri, headers: {'User-Agent': kNominatimUserAgent}).timeout(_apiTimeout);
        if (res.statusCode != 200 || !mounted) return;
        final body = jsonDecode(res.body);
        if (body is! List) return;
        final next = body
            .whereType<Map>()
            .map((e) => '${e['display_name'] ?? ''}'.trim())
            .where((s) => s.isNotEmpty)
            .take(5)
            .toList();
        if (!mounted) return;
        setState(() {
          _addrSuggestions
            ..clear()
            ..addAll(local)
            ..addAll(next.where((s) => !local.contains(s)));
        });
      } catch (_) {}
    });
  }

  Future<void> _openMapsDialog() async {
    final p = widget.state.profile;
    final addrHint = addressController.text.trim().isNotEmpty ? addressController.text.trim() : p.deliveryAddress;
    final r = await showDialog<MapPinResult>(
      context: context,
      builder: (ctx) => _MapPinPickerDialog(
        initialSearchQuery: addrHint,
        initialLat: mapLat ?? p.deliveryLat,
        initialLng: mapLng ?? p.deliveryLng,
      ),
    );
    if (r != null && mounted) {
      setState(() {
        addressController.text = r.address;
        mapLat = r.lat;
        mapLng = r.lng;
        deliveryMapConfirmedLocal = true;
        if (r.address.trim().isNotEmpty && !_savedAddresses.contains(r.address.trim())) {
          _savedAddresses.add(r.address.trim());
        }
      });
      appSnack(context, 'Location pinned. Save your profile to keep coordinates and address.');
    }
  }

  @override
  Widget build(BuildContext context) {
    return AppScaffold(
      state: widget.state,
      title: 'MY PROFILE',
      showTrayShortcut: false,
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            Expanded(
              child: RefreshIndicator(
                onRefresh: () async {
                  await widget.state.loadProfile(force: true);
                  if (!mounted) return;
                  setState(_applyProfileToControllers);
                },
                child: ListView(
                  physics: const AlwaysScrollableScrollPhysics(),
                  children: [
                  TextField(controller: nameController, decoration: const InputDecoration(labelText: 'Full Name')),
                  const SizedBox(height: 10),
                  TextField(controller: contactController, decoration: const InputDecoration(labelText: 'Contact Number')),
                  const SizedBox(height: 10),
                  TextField(
                    controller: addressController,
                    onChanged: _suggestAddress,
                    decoration: InputDecoration(
                      labelText: 'Primary delivery address',
                      hintText: 'Street, building, landmarks…',
                      suffixIcon: IconButton(
                        tooltip: 'Pin on map',
                        onPressed: _openMapsDialog,
                        icon: const Icon(Icons.place_outlined),
                      ),
                    ),
                    minLines: 2,
                    maxLines: 4,
                  ),
                  const SizedBox(height: 10),
                  TextField(
                    controller: _newAddressManual,
                    onChanged: _suggestAddress,
                    decoration: InputDecoration(
                      labelText: 'Add another address',
                      hintText: 'Type an address, then tap Add',
                      suffixIcon: IconButton(
                        tooltip: 'Pin on map',
                        onPressed: _openMapsDialog,
                        icon: const Icon(Icons.place_outlined),
                      ),
                    ),
                    minLines: 1,
                    maxLines: 3,
                  ),
                  if (_addrSuggestions.isNotEmpty)
                    Container(
                      margin: const EdgeInsets.only(top: 6),
                      decoration: BoxDecoration(
                        border: Border.all(color: Colors.grey.shade300),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Column(
                        children: _addrSuggestions
                            .map(
                              (s) => ListTile(
                                dense: true,
                                title: Text(s, maxLines: 2, overflow: TextOverflow.ellipsis),
                                onTap: () => setState(() {
                                  if (_newAddressManual.text.trim().isNotEmpty) {
                                    _newAddressManual.text = s;
                                  } else {
                                    addressController.text = s;
                                  }
                                  _addrSuggestions.clear();
                                }),
                              ),
                            )
                            .toList(),
                      ),
                    ),
                  const SizedBox(height: 8),
                  Align(
                    alignment: Alignment.centerRight,
                    child: TextButton.icon(
                      onPressed: () {
                        final v = _newAddressManual.text.trim();
                        if (v.isEmpty) return;
                        setState(() {
                          if (!_savedAddresses.contains(v)) _savedAddresses.add(v);
                          _newAddressManual.clear();
                        });
                      },
                      icon: const Icon(Icons.add_location_alt_outlined),
                      label: const Text('Add to saved addresses'),
                    ),
                  ),
                  if (_savedAddresses.isNotEmpty) ...[
                    const Text('Saved addresses', style: TextStyle(fontWeight: FontWeight.w800)),
                    const SizedBox(height: 6),
                    ..._savedAddresses.map(
                      (a) => Card(
                        margin: const EdgeInsets.only(bottom: 6),
                        child: ListTile(
                          dense: true,
                          title: Text(a, maxLines: 3),
                          trailing: IconButton(
                            icon: const Icon(Icons.close, size: 20),
                            onPressed: () => setState(() => _savedAddresses.remove(a)),
                          ),
                        ),
                      ),
                    ),
                  ],
                  const SizedBox(height: 16),
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(color: AppColors.border),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            const Expanded(
                              child: Text(
                                'Loyalty (restaurant orders)',
                                style: TextStyle(fontWeight: FontWeight.w800),
                              ),
                            ),
                            Text(
                              '${widget.state.profile.loyaltyPointsRestaurant} pts',
                              style: const TextStyle(fontWeight: FontWeight.w900),
                            ),
                          ],
                        ),
                        const SizedBox(height: 6),
                        Row(
                          children: [
                            const Expanded(
                              child: Text(
                                'Loyalty (catering / events)',
                                style: TextStyle(fontWeight: FontWeight.w800),
                              ),
                            ),
                            Text(
                              '${widget.state.profile.loyaltyPointsCatering} pts',
                              style: const TextStyle(fontWeight: FontWeight.w900),
                            ),
                          ],
                        ),
                        const Divider(height: 16),
                        Row(
                          children: [
                            const Expanded(
                              child: Text(
                                'Total Loyalty Points',
                                style: TextStyle(fontWeight: FontWeight.w800),
                              ),
                            ),
                            Text(
                              '${widget.state.profile.loyaltyPoints} pts',
                              style: const TextStyle(fontWeight: FontWeight.w900),
                            ),
                          ],
                        ),
                        const SizedBox(height: 10),
                        SizedBox(
                          height: 140,
                          child: widget.state.loyaltyHistory.isEmpty
                              ? const Align(
                                  alignment: Alignment.topLeft,
                                  child: Text('No loyalty history yet.'),
                                )
                              : ListView.separated(
                                  padding: EdgeInsets.zero,
                                  shrinkWrap: true,
                                  itemCount: widget.state.loyaltyHistory.length,
                                  separatorBuilder: (_, _) => const SizedBox(height: 10),
                                  itemBuilder: (context, index) {
                                    final h = widget.state.loyaltyHistory[index];
                                    final label = h.orderNo.trim().isEmpty ? '******' : h.orderNo.trim();
                                    final src = h.source == 'catering' ? 'Catering' : 'Restaurant';
                                    return Column(
                                      crossAxisAlignment: CrossAxisAlignment.start,
                                      children: [
                                        Text(
                                          '$label · $src · +${h.pointsDelta} pts',
                                          style: const TextStyle(fontWeight: FontWeight.w700),
                                        ),
                                        Text(formatDateTimeLocal(h.createdAt)),
                                      ],
                                    );
                                  },
                                ),
                        ),
                      ],
                    ),
                  ),
                ],
                ),
              ),
            ),
            FilledButton(
              onPressed: () async {
                final primary = addressController.text.trim();
                final merged = <String>{..._savedAddresses};
                if (primary.isNotEmpty) merged.add(primary);
                await widget.state.saveProfile(
                  ProfileData(
                    fullName: nameController.text.trim(),
                    contactNumber: contactController.text.trim(),
                    deliveryAddress: primary,
                    deliveryMapConfirmed: deliveryMapConfirmedLocal,
                    deliveryLat: mapLat,
                    deliveryLng: mapLng,
                    loyaltyPoints: widget.state.profile.loyaltyPoints,
                    loyaltyPointsRestaurant: widget.state.profile.loyaltyPointsRestaurant,
                    loyaltyPointsCatering: widget.state.profile.loyaltyPointsCatering,
                    deliveryAddresses: merged.toList(),
                  ),
                );
                if (!context.mounted) return;
                appSnack(context, 'Profile saved');
              },
              child: const Text('SAVE PROFILE'),
            ),
          ],
        ),
      ),
    );
  }
}

class MapPinResult {
  const MapPinResult({required this.address, required this.lat, required this.lng});
  final String address;
  final double lat;
  final double lng;
}

class _MapPinPickerDialog extends StatefulWidget {
  const _MapPinPickerDialog({
    required this.initialSearchQuery,
    this.initialLat,
    this.initialLng,
  });

  final String initialSearchQuery;
  final double? initialLat;
  final double? initialLng;

  @override
  State<_MapPinPickerDialog> createState() => _MapPinPickerDialogState();
}

class _MapPinPickerDialogState extends State<_MapPinPickerDialog> {
  late final MapController _mapController;
  late final TextEditingController _searchCtl;
  late LatLng _pin;
  String _resolvedAddress = '';
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _searchCtl = TextEditingController(text: widget.initialSearchQuery);
    _mapController = MapController();
    _pin = LatLng(
      widget.initialLat ?? 14.5995,
      widget.initialLng ?? 120.9842,
    );
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      await _centerFromSearchOrPin();
      await _reverse(_pin);
    });
  }

  Future<void> _searchTypedQuery() async {
    final q = _searchCtl.text.trim();
    if (q.isEmpty) return;
    setState(() => _busy = true);
    try {
      final uri = Uri.parse(
        'https://nominatim.openstreetmap.org/search?q=${Uri.encodeComponent(q)}&format=json&limit=1',
      );
      final res = await http.get(uri, headers: {'User-Agent': kNominatimUserAgent}).timeout(_apiTimeout);
      if (res.statusCode == 200) {
        final list = jsonDecode(res.body) as List<dynamic>;
        if (list.isNotEmpty) {
          final m = list.first as Map<String, dynamic>;
          final lat = jsonToDouble(m['lat']);
          final lon = jsonToDouble(m['lon']);
          final ll = LatLng(lat, lon);
          if (mounted) setState(() => _pin = ll);
          _mapController.move(ll, 16);
          await _reverse(ll);
          return;
        }
      }
      if (mounted) appSnack(context, 'No results — try a nearby landmark or street.');
    } catch (_) {
      if (mounted) appSnack(context, 'Search failed — try again.');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _centerFromSearchOrPin() async {
    final q = widget.initialSearchQuery.trim();
    if (q.isEmpty) {
      _mapController.move(_pin, 16);
      return;
    }
    setState(() => _busy = true);
    try {
      final uri = Uri.parse(
        'https://nominatim.openstreetmap.org/search?q=${Uri.encodeComponent(q)}&format=json&limit=1',
      );
      final res = await http.get(uri, headers: {'User-Agent': kNominatimUserAgent}).timeout(_apiTimeout);
      if (res.statusCode == 200) {
        final list = jsonDecode(res.body) as List<dynamic>;
        if (list.isNotEmpty) {
          final m = list.first as Map<String, dynamic>;
          final lat = jsonToDouble(m['lat']);
          final lon = jsonToDouble(m['lon']);
          final ll = LatLng(lat, lon);
          setState(() => _pin = ll);
          _mapController.move(ll, 16);
          await _reverse(ll);
          return;
        }
      }
      _mapController.move(_pin, 16);
    } catch (_) {
      _mapController.move(_pin, 16);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _reverse(LatLng ll) async {
    setState(() => _busy = true);
    try {
      final uri = Uri.parse(
        'https://nominatim.openstreetmap.org/reverse?lat=${ll.latitude}&lon=${ll.longitude}&format=json',
      );
      final res = await http.get(uri, headers: {'User-Agent': kNominatimUserAgent}).timeout(_apiTimeout);
      if (res.statusCode == 200) {
        final m = jsonDecode(res.body) as Map<String, dynamic>;
        final name = '${m['display_name'] ?? ''}'.trim();
        if (mounted) setState(() => _resolvedAddress = name);
      }
    } catch (_) {
      if (mounted) {
        setState(() => _resolvedAddress = '${ll.latitude.toStringAsFixed(6)}, ${ll.longitude.toStringAsFixed(6)}');
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _useDeviceGps() async {
    if (kIsWeb) {
      if (mounted) {
        appSnack(context, 'Device GPS is intended for iOS/Android. Use tap-to-pin here.');
      }
      return;
    }
    setState(() => _busy = true);
    try {
      var permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
      }
      if (permission == LocationPermission.denied ||
          permission == LocationPermission.deniedForever) {
        if (mounted) appSnack(context, 'Location permission is required for GPS pinning.');
        return;
      }
      final serviceOn = await Geolocator.isLocationServiceEnabled();
      if (!serviceOn) {
        if (mounted) appSnack(context, 'Turn on Location in system settings.');
        return;
      }
      final pos = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(accuracy: LocationAccuracy.high),
      );
      final ll = LatLng(pos.latitude, pos.longitude);
      if (!mounted) return;
      setState(() => _pin = ll);
      _mapController.move(ll, 17);
      await _reverse(ll);
    } catch (_) {
      if (mounted) appSnack(context, 'Could not get GPS location.');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  void dispose() {
    _searchCtl.dispose();
    _mapController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Pin delivery location'),
      content: SizedBox(
        width: double.maxFinite,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text(
                'Tap the map where you want delivery. Address updates use OpenStreetMap data (coordinates match what you see in other map apps).',
                style: TextStyle(height: 1.35, fontSize: 13),
              ),
              const SizedBox(height: 10),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: TextField(
                      controller: _searchCtl,
                      decoration: const InputDecoration(
                        labelText: 'Search place or address',
                        hintText: 'Barangay, street, landmark…',
                      ),
                      onSubmitted: (_) => _searchTypedQuery(),
                    ),
                  ),
                  const SizedBox(width: 8),
                  IconButton(
                    style: IconButton.styleFrom(
                      backgroundColor: Theme.of(context).colorScheme.secondaryContainer,
                      foregroundColor: Theme.of(context).colorScheme.onSecondaryContainer,
                    ),
                    onPressed: _busy ? null : _searchTypedQuery,
                    icon: const Icon(Icons.search),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              OutlinedButton.icon(
                onPressed: _busy ? null : _useDeviceGps,
                icon: const Icon(Icons.my_location_outlined),
                label: const Text('Use device location (GPS)'),
              ),
              const SizedBox(height: 6),
              Text(
                'Optional: grant location permission for a quicker, more accurate starting point.',
                style: TextStyle(fontSize: 11, color: Colors.grey.shade700, height: 1.35),
              ),
              const SizedBox(height: 10),
              SizedBox(
                height: 280,
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(12),
                  child: FlutterMap(
                    mapController: _mapController,
                    options: MapOptions(
                      initialCenter: _pin,
                      initialZoom: 16,
                      onTap: (_, ll) async {
                        setState(() => _pin = ll);
                        await _reverse(ll);
                      },
                    ),
                    children: [
                      TileLayer(
                        urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                        userAgentPackageName: 'com.curatering.mobile',
                      ),
                      MarkerLayer(
                        markers: [
                          Marker(
                            point: _pin,
                            width: 44,
                            height: 44,
                            alignment: Alignment.center,
                            child: const Icon(Icons.location_on, color: AppColors.accent, size: 44),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 10),
              SelectableText(
                _resolvedAddress.isEmpty ? 'Resolving address…' : _resolvedAddress,
                style: const TextStyle(fontWeight: FontWeight.w600, height: 1.35),
              ),
              const SizedBox(height: 6),
              Text(
                'Coordinates: ${_pin.latitude.toStringAsFixed(6)}, ${_pin.longitude.toStringAsFixed(6)}',
                style: TextStyle(fontSize: 12, color: Colors.grey.shade800),
              ),
              if (_busy) const Padding(padding: EdgeInsets.only(top: 8), child: LinearProgressIndicator()),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(
          onPressed: _busy
              ? null
              : () {
                  Navigator.pop(
                    context,
                    MapPinResult(
                      address: _resolvedAddress.isNotEmpty
                          ? _resolvedAddress
                          : '${_pin.latitude.toStringAsFixed(6)}, ${_pin.longitude.toStringAsFixed(6)}',
                      lat: _pin.latitude,
                      lng: _pin.longitude,
                    ),
                  );
                },
          child: const Text('Use this location'),
        ),
      ],
    );
  }
}

/// One event day with a time range (stored in inquiry `date_of_event` as text).
class _InquiryEventWindow {
  DateTime? date;
  TimeOfDay? from;
  TimeOfDay? to;
}

class InquiryScreen extends StatefulWidget {
  const InquiryScreen({super.key, required this.state});
  final AppState state;
  @override
  State<InquiryScreen> createState() => _InquiryScreenState();
}

class _InquiryScreenState extends State<InquiryScreen> {
  String inquiryType = 'CATERING';
  bool curateOwn = false;
  bool _menuChoicePicked = false;
  bool _attemptedSubmit = false;
  static const int _minSelectedDishesRequired = 4;
  String _themeDesignChoice = '';
  String menuSuggestionNote = '';
  String themeSuggestionNote = '';
  final themeNotesController = TextEditingController();
  final List<String> _themeReferenceImagesB64 = <String>[];
  String selectedSetMenu = 'All Dishes';
  final selectedDishes = <String>{};
  final guestCount = TextEditingController();
  final eventTitle = TextEditingController();
  final eventTypeOther = TextEditingController();
  String eventTypeChoice = 'Birthday';
  final contactPerson = TextEditingController();
  final contactNumber = TextEditingController();
  final inquiryEmail = TextEditingController();
  final List<_InquiryEventWindow> _eventWindows = [_InquiryEventWindow()];
  Timer? _scheduleConflictDebounce;
  int _publicScheduleConflictCount = 0;
  final eventCity = TextEditingController();
  final List<String> _venueSuggestions = [];
  Timer? _venueDebounce;
  final note = TextEditingController();
  String eventSetting = 'open';
  String serviceIncluded = 'no';
  String formalityLevel = 'casual';
  bool foodTastingRequested = false;
  final foodTastingDate = TextEditingController();
  final foodTastingTime = TextEditingController();
  final menuSearchController = TextEditingController();

  InputDecoration _requiredDecoration({
    required String label,
    required bool invalid,
    String? hint,
    Widget? suffixIcon,
  }) {
    final red = Colors.red.shade700;
    final bad = _attemptedSubmit && invalid;
    final borderSide = BorderSide(color: bad ? red : Colors.grey.shade400);
    return InputDecoration(
      labelText: label,
      hintText: hint,
      suffixIcon: suffixIcon,
      errorText: bad ? 'Required' : null,
      border: OutlineInputBorder(borderSide: borderSide),
      enabledBorder: OutlineInputBorder(borderSide: borderSide),
      focusedBorder: OutlineInputBorder(
        borderSide: BorderSide(color: bad ? red : AppColors.brand, width: bad ? 1.5 : 2),
      ),
    );
  }

  @override
  void initState() {
    super.initState();
    final p = widget.state.profile;
    contactPerson.text = p.fullName;
    contactNumber.text = p.contactNumber;
    inquiryEmail.text = widget.state.userEmail ?? '';
    eventCity.addListener(_onVenueChanged);
    WidgetsBinding.instance.addPostFrameCallback((_) => _scheduleConflictRefresh());
  }

  @override
  void dispose() {
    _scheduleConflictDebounce?.cancel();
    _venueDebounce?.cancel();
    eventCity.removeListener(_onVenueChanged);
    guestCount.dispose();
    eventTitle.dispose();
    eventTypeOther.dispose();
    contactPerson.dispose();
    contactNumber.dispose();
    inquiryEmail.dispose();
    eventCity.dispose();
    note.dispose();
    foodTastingDate.dispose();
    foodTastingTime.dispose();
    menuSearchController.dispose();
    themeNotesController.dispose();
    super.dispose();
  }

  int _minPaxForCurrentInquiry() =>
      inquiryType == 'CATERING AND EVENT' ? kMinCateringEventPax : kMinCateringOnlyPax;

  /// For estimate: empty guests → 0; otherwise clamp to the minimum for this inquiry type.
  int _billableGuestCountForPricing() {
    final raw = guestCount.text.trim();
    if (raw.isEmpty) return 0;
    final g = int.tryParse(raw) ?? 0;
    if (g <= 0) return 0;
    final min = _minPaxForCurrentInquiry();
    return g < min ? min : g;
  }

  /// Stored guest count when submitting (minimum pax applies if the field is empty).
  int _guestCountForSubmit() {
    final raw = guestCount.text.trim();
    final min = _minPaxForCurrentInquiry();
    if (raw.isEmpty) return min;
    final g = int.tryParse(raw) ?? 0;
    if (g <= 0) return min;
    return g < min ? min : g;
  }

  String _serializedEventDates() {
    final parts = <String>[];
    for (final w in _eventWindows) {
      if (w.date == null || w.from == null || w.to == null) continue;
      final d = w.date!;
      final dateStr = '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
      final f =
          '${w.from!.hour.toString().padLeft(2, '0')}:${w.from!.minute.toString().padLeft(2, '0')}';
      final t = '${w.to!.hour.toString().padLeft(2, '0')}:${w.to!.minute.toString().padLeft(2, '0')}';
      parts.add('$dateStr from $f to $t');
    }
    return parts.join('; ');
  }

  String _scheduleSlotsJsonForSubmit() {
    final slots = <Map<String, String>>[];
    for (final w in _eventWindows) {
      if (w.date == null || w.from == null || w.to == null) continue;
      final d = w.date!;
      final dateStr = '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
      final f =
          '${w.from!.hour.toString().padLeft(2, '0')}:${w.from!.minute.toString().padLeft(2, '0')}';
      final t = '${w.to!.hour.toString().padLeft(2, '0')}:${w.to!.minute.toString().padLeft(2, '0')}';
      slots.add({'date': dateStr, 'from': f, 'to': t, 'label': '$dateStr from $f to $t'});
    }
    return jsonEncode(slots);
  }

  void _scheduleConflictRefresh() {
    _scheduleConflictDebounce?.cancel();
    _scheduleConflictDebounce = Timer(const Duration(milliseconds: 450), () async {
      final slots = <Map<String, String>>[];
      for (final w in _eventWindows) {
        if (w.date == null || w.from == null || w.to == null) continue;
        final d = w.date!;
        final dateStr = '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
        slots.add({
          'date': dateStr,
          'from': '${w.from!.hour.toString().padLeft(2, '0')}:${w.from!.minute.toString().padLeft(2, '0')}',
          'to': '${w.to!.hour.toString().padLeft(2, '0')}:${w.to!.minute.toString().padLeft(2, '0')}',
        });
      }
      if (!mounted) return;
      if (slots.isEmpty) {
        setState(() => _publicScheduleConflictCount = 0);
        return;
      }
      final n = await widget.state.countCateringScheduleConflicts(slots);
      if (mounted) setState(() => _publicScheduleConflictCount = n);
    });
  }

  Future<void> _pickWindowDate(int index) async {
    final ctx = context;
    final w = _eventWindows[index];
    final base = w.date ?? DateTime.now();
    final d = await showDatePicker(
      context: ctx,
      initialDate: base,
      firstDate: DateTime.now().subtract(const Duration(days: 1)),
      lastDate: DateTime.now().add(const Duration(days: 365 * 3)),
    );
    if (!ctx.mounted || d == null) return;
    setState(() => _eventWindows[index].date = DateTime(d.year, d.month, d.day));
    _scheduleConflictRefresh();
  }

  Future<void> _pickWindowFrom(int index) async {
    final ctx = context;
    final w = _eventWindows[index];
    final t = await showTimePicker(
      context: ctx,
      initialTime: w.from ?? const TimeOfDay(hour: 12, minute: 0),
    );
    if (!ctx.mounted || t == null) return;
    setState(() => _eventWindows[index].from = t);
    _scheduleConflictRefresh();
  }

  Future<void> _pickWindowTo(int index) async {
    final ctx = context;
    final w = _eventWindows[index];
    final t = await showTimePicker(
      context: ctx,
      initialTime: w.to ?? const TimeOfDay(hour: 14, minute: 0),
    );
    if (!ctx.mounted || t == null) return;
    setState(() => _eventWindows[index].to = t);
    _scheduleConflictRefresh();
  }

  void _onVenueChanged() {
    _venueDebounce?.cancel();
    final q = eventCity.text.trim();
    if (q.length < 3) {
      if (_venueSuggestions.isNotEmpty && mounted) setState(() => _venueSuggestions.clear());
      return;
    }
    _venueDebounce = Timer(const Duration(milliseconds: 300), () async {
      try {
        final local = widget.state.profile.deliveryAddresses
            .where((a) => a.toLowerCase().contains(q.toLowerCase()))
            .take(5)
            .toList();
        final uri = Uri.parse(
          'https://nominatim.openstreetmap.org/search?q=${Uri.encodeComponent(q)}&format=json&limit=5',
        );
        final res = await http.get(uri, headers: {'User-Agent': kNominatimUserAgent}).timeout(_apiTimeout);
        if (res.statusCode != 200 || !mounted) return;
        final body = jsonDecode(res.body);
        if (body is! List) return;
        final next = body
            .whereType<Map>()
            .map((e) => '${e['display_name'] ?? ''}'.trim())
            .where((s) => s.isNotEmpty)
            .take(5)
            .toList();
        if (mounted) setState(() {
          _venueSuggestions
            ..clear()
            ..addAll(local)
            ..addAll(next);
        });
      } catch (_) {}
    });
  }

  Future<void> _pickVenueOnMap() async {
    final res = await Navigator.of(context).push<MapPinResult>(
      MaterialPageRoute(
        builder: (_) => _MapPinPickerDialog(initialSearchQuery: eventCity.text.trim()),
      ),
    );
    if (res == null || !mounted) return;
    setState(() {
      eventCity.text = res.address.trim();
      _venueSuggestions.clear();
    });
  }

  double _estimatedCost() => _billableGuestCountForPricing() * kPesosPerPax;

  String _resolvedEventType() {
    if (eventTypeChoice != 'Other') return eventTypeChoice;
    return eventTypeOther.text.trim();
  }

  bool get _contactNumberInvalid {
    final phone = contactNumber.text.trim();
    if (phone.isEmpty) return true;
    return phone.length < 7 || !RegExp(r'^[0-9+\-\s()]+$').hasMatch(phone);
  }

  bool get _emailInvalid {
    final email = inquiryEmail.text.trim();
    if (email.isEmpty) return true;
    return !RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$').hasMatch(email);
  }

  bool get _eventTypeOtherInvalid => eventTypeChoice == 'Other' && eventTypeOther.text.trim().isEmpty;

  bool get _hasAnyPartialWindow =>
      _eventWindows.any((w) => w.date != null || w.from != null || w.to != null) &&
      _eventWindows.any((w) => !(w.date != null && w.from != null && w.to != null));

  bool get _hasNoCompleteWindow =>
      _eventWindows.where((w) => w.date != null && w.from != null && w.to != null).isEmpty;

  bool get _hasWindowTimeRangeError => _eventWindows.any((w) {
    if (w.date == null || w.from == null || w.to == null) return false;
    final sm = w.from!.hour * 60 + w.from!.minute;
    final em = w.to!.hour * 60 + w.to!.minute;
    return em <= sm;
  });

  bool get _guestCountInvalid {
    final rawGuests = guestCount.text.trim();
    if (rawGuests.isEmpty) return true;
    final gNum = int.tryParse(rawGuests);
    if (gNum == null || gNum < 1) return true;
    return gNum < _minPaxForCurrentInquiry();
  }

  Future<void> _pickThemeReferenceImage() async {
    final x = await ImagePicker().pickImage(source: ImageSource.gallery, imageQuality: 85);
    if (x == null) return;
    final bytes = await x.readAsBytes();
    if (!mounted) return;
    setState(() {
      _themeReferenceImagesB64.add(base64Encode(bytes));
    });
  }

  /// Returns null if valid; otherwise an error message for the user.
  String? _validateInquiry() {
    if (contactPerson.text.trim().isEmpty) return 'Enter contact person.';
    final phone = contactNumber.text.trim();
    if (phone.isEmpty) return 'Enter contact number.';
    if (phone.length < 7 || !RegExp(r'^[0-9+\-\s()]+$').hasMatch(phone)) {
      return 'Enter a valid contact number.';
    }
    final email = inquiryEmail.text.trim();
    if (email.isEmpty) return 'Enter email address.';
    if (!RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$').hasMatch(email)) {
      return 'Enter a valid email address.';
    }
    if (eventCity.text.trim().isEmpty) return 'Enter event venue.';
    for (final w in _eventWindows) {
      final any = w.date != null || w.from != null || w.to != null;
      final all = w.date != null && w.from != null && w.to != null;
      if (any && !all) return 'Complete event date, start time, and end time for each row (or remove extra rows).';
    }
    final completeWindows = _eventWindows.where((w) => w.date != null && w.from != null && w.to != null).toList();
    if (completeWindows.isEmpty) return 'Set at least one event day with start and end time.';
    for (final w in completeWindows) {
      final sm = w.from!.hour * 60 + w.from!.minute;
      final em = w.to!.hour * 60 + w.to!.minute;
      if (em <= sm) return 'End time must be after start time for each event.';
    }
    if (!_menuChoicePicked) return 'Choose a menu preference.';
    if (curateOwn && selectedDishes.length < _minSelectedDishesRequired) {
      return 'Select at least $_minSelectedDishesRequired dish(es) for the menu.';
    }
    if (inquiryType == 'CATERING AND EVENT' && _themeDesignChoice.isEmpty) {
      return 'Choose an event theme design option.';
    }
    if (inquiryType == 'CATERING AND EVENT' && eventTitle.text.trim().isEmpty) return 'Enter event title.';
    if (eventTypeChoice == 'Other' && eventTypeOther.text.trim().isEmpty) {
      return 'Describe the event type for “Other”.';
    }
    if (foodTastingRequested &&
        (foodTastingDate.text.trim().isEmpty || foodTastingTime.text.trim().isEmpty)) {
      return 'Enter date and time for food tasting.';
    }
    final rawGuests = guestCount.text.trim();
    if (rawGuests.isEmpty) return 'Enter number of guests.';
    final gNum = int.tryParse(rawGuests);
    if (gNum == null || gNum < 1) return 'Enter a valid number of guests.';
    final min = _minPaxForCurrentInquiry();
    if (gNum < min) return 'Minimum guests for this inquiry type is $min.';
    return null;
  }

  Widget _buildEventTypePicker() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        DropdownButtonFormField<String>(
          value: kMobileEventTypeChoices.contains(eventTypeChoice) ? eventTypeChoice : 'Other',
          decoration: _requiredDecoration(label: 'Event type', invalid: false),
          items: kMobileEventTypeChoices.map((e) => DropdownMenuItem(value: e, child: Text(e))).toList(),
          onChanged: (v) => setState(() => eventTypeChoice = v ?? 'Other'),
        ),
        if (eventTypeChoice == 'Other') ...[
          const SizedBox(height: 8),
          TextField(
            controller: eventTypeOther,
            decoration: _requiredDecoration(
              label: 'Describe event type',
              invalid: _eventTypeOtherInvalid,
            ),
            onChanged: (_) => setState(() {}),
          ),
        ],
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final state = widget.state;
    final cateringMenu = state.menu.where((m) => m.isCateringDish).toList();
    final setMenuNames = ['All Dishes', ...state.setMenus.map((m) => m.name)];
    final effectiveSetMenu = setMenuNames.contains(selectedSetMenu) ? selectedSetMenu : 'All Dishes';
    final q = menuSearchController.text.trim().toLowerCase();
    final availableDishes = cateringMenu
        .map((m) => m.name.trim())
        .where((n) => n.isNotEmpty)
        .toSet()
        .where((n) => q.isEmpty || n.toLowerCase().contains(q))
        .toList();
    final estimate = _estimatedCost();
    return AppScaffold(
      state: state,
      title: 'INQUIRE CATERING SERVICE',
      showTrayShortcut: false,
      body: Column(
        children: [
          Expanded(
            child: RefreshIndicator(
              onRefresh: () async {
                await state.loadMenu(force: true);
                await state.loadSetMenus(force: true);
                if (mounted) setState(() {});
              },
              child: ListView(
                physics: const AlwaysScrollableScrollPhysics(),
                padding: const EdgeInsets.all(12),
                children: [
                DropdownButtonFormField<String>(
                  value: inquiryType,
                  items: const [
                    DropdownMenuItem(value: 'CATERING', child: Text('CATERING')),
                    DropdownMenuItem(value: 'CATERING AND EVENT', child: Text('CATERING AND EVENT')),
                  ],
                  onChanged: (v) => setState(() => inquiryType = v ?? 'CATERING'),
                ),
                if (inquiryType == 'CATERING') ...[
                  const SizedBox(height: 10),
                  _buildEventTypePicker(),
                ],
                const SizedBox(height: 10),
                Text(
                  'Catering only: minimum $kMinCateringOnlyPax guests. Catering & event: minimum $kMinCateringEventPax guests. Estimated cost is ₱${kPesosPerPax.toStringAsFixed(0)} × guests (shows ₱0 until you enter a guest count).',
                  style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 10),
                ToggleSection(
                  title: 'EVENT INFORMATION',
                  expanded: true,
                  onToggle: () {},
                  hideToggleIcon: true,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      TextField(
                        controller: eventTitle,
                        decoration: _requiredDecoration(
                          label: 'Event title',
                          invalid: inquiryType == 'CATERING AND EVENT' && eventTitle.text.trim().isEmpty,
                        ),
                      ),
                      const SizedBox(height: 8),
                      if (inquiryType == 'CATERING AND EVENT') ...[
                        _buildEventTypePicker(),
                        const SizedBox(height: 8),
                        Text('Formality level', style: Theme.of(context).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700)),
                        const SizedBox(height: 6),
                        SegmentedButton<String>(
                          segments: const [
                            ButtonSegment(value: 'casual', label: Text('Casual')),
                            ButtonSegment(value: 'semiformal', label: Text('Semiformal')),
                            ButtonSegment(value: 'formal', label: Text('Formal')),
                          ],
                          selected: {formalityLevel},
                          onSelectionChanged: (s) => setState(() => formalityLevel = s.first),
                        ),
                        const SizedBox(height: 12),
                      ],
                      TextField(
                        controller: contactPerson,
                        decoration: _requiredDecoration(
                          label: 'Contact person',
                          invalid: contactPerson.text.trim().isEmpty,
                        ),
                      ),
                      const SizedBox(height: 8),
                      TextField(
                        controller: contactNumber,
                        decoration: _requiredDecoration(
                          label: 'Contact number',
                          invalid: _contactNumberInvalid,
                        ),
                      ),
                      const SizedBox(height: 8),
                      TextField(
                        controller: inquiryEmail,
                        decoration: _requiredDecoration(
                          label: 'Email address',
                          invalid: _emailInvalid,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text('Event schedule (from / to)', style: Theme.of(context).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700)),
                      const SizedBox(height: 6),
                      ...List.generate(_eventWindows.length, (index) {
                        final w = _eventWindows[index];
                        final dateLabel = w.date == null
                            ? 'Date'
                            : '${w.date!.year}-${w.date!.month.toString().padLeft(2, '0')}-${w.date!.day.toString().padLeft(2, '0')}';
                        String fmt(TimeOfDay? t) => t == null
                            ? '—'
                            : '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';
                        final fromLabel = fmt(w.from);
                        final toLabel = fmt(w.to);
                        return Padding(
                          padding: const EdgeInsets.only(bottom: 10),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              Row(
                                children: [
                                  Expanded(
                                    child: OutlinedButton(
                                      onPressed: () => _pickWindowDate(index),
                                      child: Text(dateLabel, overflow: TextOverflow.ellipsis),
                                    ),
                                  ),
                                  if (_eventWindows.length > 1)
                                    IconButton(
                                      icon: const Icon(Icons.remove_circle_outline, color: AppColors.accent),
                                      onPressed: () {
                                        setState(() {
                                          if (_eventWindows.length > 1) _eventWindows.removeAt(index);
                                        });
                                        _scheduleConflictRefresh();
                                      },
                                    ),
                                ],
                              ),
                              const SizedBox(height: 6),
                              Row(
                                children: [
                                  Expanded(
                                    child: OutlinedButton(
                                      onPressed: () => _pickWindowFrom(index),
                                      child: Text('From $fromLabel'),
                                    ),
                                  ),
                                  const SizedBox(width: 8),
                                  Expanded(
                                    child: OutlinedButton(
                                      onPressed: () => _pickWindowTo(index),
                                      child: Text('to $toLabel'),
                                    ),
                                  ),
                                ],
                              ),
                            ],
                          ),
                        );
                      }),
                      if (_attemptedSubmit && (_hasAnyPartialWindow || _hasNoCompleteWindow || _hasWindowTimeRangeError))
                        Padding(
                          padding: const EdgeInsets.only(bottom: 8),
                          child: Text(
                            _hasAnyPartialWindow
                                ? 'Complete date/start/end time for each row, or remove incomplete rows.'
                                : _hasNoCompleteWindow
                                    ? 'Set at least one event day with start and end time.'
                                    : 'End time must be after start time for each event.',
                            style: TextStyle(color: Colors.red.shade700, fontSize: 12),
                          ),
                        ),
                      if (_publicScheduleConflictCount > 0)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 8),
                          child: Text(
                            '$_publicScheduleConflictCount proposed window(s) overlap active For Processing schedules. '
                            'You may still submit; Macrina\'s will confirm availability.',
                            style: TextStyle(color: Colors.deepOrange.shade800, fontSize: 12),
                          ),
                        ),
                      Align(
                        alignment: Alignment.centerLeft,
                        child: TextButton.icon(
                          onPressed: () {
                            setState(() => _eventWindows.add(_InquiryEventWindow()));
                          },
                          icon: const Icon(Icons.add),
                          label: const Text('Add another day'),
                        ),
                      ),
                      const SizedBox(height: 8),
                      TextField(
                        controller: eventCity,
                        decoration: _requiredDecoration(
                          label: 'Event venue',
                          invalid: eventCity.text.trim().isEmpty,
                          suffixIcon: IconButton(
                            tooltip: 'Pin on map',
                            onPressed: _pickVenueOnMap,
                            icon: const Icon(Icons.place_outlined),
                          ),
                        ),
                      ),
                      if (_venueSuggestions.isNotEmpty)
                        Container(
                          margin: const EdgeInsets.only(top: 6),
                          decoration: BoxDecoration(
                            border: Border.all(color: Colors.grey.shade300),
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: Column(
                            children: _venueSuggestions
                                .map(
                                  (s) => ListTile(
                                    dense: true,
                                    title: Text(s, maxLines: 2, overflow: TextOverflow.ellipsis),
                                    onTap: () => setState(() {
                                      eventCity.text = s;
                                      _venueSuggestions.clear();
                                    }),
                                  ),
                                )
                                .toList(),
                          ),
                        ),
                      const SizedBox(height: 8),
                      Text('Setting of event', style: Theme.of(context).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700)),
                      const SizedBox(height: 6),
                      Row(
                        children: [
                          Expanded(
                            child: RadioListTile<String>(
                              dense: true,
                              contentPadding: EdgeInsets.zero,
                              title: const Text('Open space'),
                              value: 'open',
                              groupValue: eventSetting,
                              onChanged: (v) => setState(() => eventSetting = v ?? 'open'),
                            ),
                          ),
                          Expanded(
                            child: RadioListTile<String>(
                              dense: true,
                              contentPadding: EdgeInsets.zero,
                              title: const Text('Closed space'),
                              value: 'closed',
                              groupValue: eventSetting,
                              onChanged: (v) => setState(() => eventSetting = v ?? 'closed'),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 4),
                      TextField(
                        controller: guestCount,
                        decoration: _requiredDecoration(
                          label: 'Number of guests',
                          invalid: _guestCountInvalid,
                        ),
                        keyboardType: TextInputType.number,
                        onChanged: (_) => setState(() {}),
                      ),
                      const SizedBox(height: 8),
                      TextField(
                        controller: note,
                        decoration: const InputDecoration(labelText: 'Note (optional)'),
                        maxLines: 3,
                      ),
                      const SizedBox(height: 8),
                      Text('Service', style: Theme.of(context).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700)),
                      Row(
                        children: [
                          Expanded(
                            child: RadioListTile<String>(
                              dense: true,
                              contentPadding: EdgeInsets.zero,
                              title: const Text('With service'),
                              value: 'yes',
                              groupValue: serviceIncluded,
                              onChanged: (v) => setState(() => serviceIncluded = v ?? 'yes'),
                            ),
                          ),
                          Expanded(
                            child: RadioListTile<String>(
                              dense: true,
                              contentPadding: EdgeInsets.zero,
                              title: const Text('Without service'),
                              value: 'no',
                              groupValue: serviceIncluded,
                              onChanged: (v) => setState(() => serviceIncluded = v ?? 'no'),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
                if (inquiryType == 'CATERING AND EVENT') ...[
                  const SizedBox(height: 10),
                  ToggleSection(
                    title: 'EVENT THEME DESIGN',
                    expanded: true,
                    onToggle: () {},
                    hideToggleIcon: true,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        const Text('DO YOU ALREADY HAVE A DESIGN DIRECTION IN MIND?'),
                        const SizedBox(height: 8),
                        RadioListTile<String>(
                          dense: true,
                          contentPadding: EdgeInsets.zero,
                          value: 'suggest',
                          groupValue: _themeDesignChoice,
                          title: const Text('No, suggest me a design'),
                          onChanged: (v) => setState(() => _themeDesignChoice = v ?? 'suggest'),
                        ),
                        RadioListTile<String>(
                          dense: true,
                          contentPadding: EdgeInsets.zero,
                          value: 'create_own',
                          groupValue: _themeDesignChoice,
                          title: const Text('Yes, I would like to create my own design'),
                          onChanged: (v) => setState(() => _themeDesignChoice = v ?? 'create_own'),
                        ),
                        if (_attemptedSubmit && _themeDesignChoice.isEmpty)
                          Padding(
                            padding: const EdgeInsets.only(bottom: 8),
                            child: Text(
                              'Required',
                              style: TextStyle(color: Colors.red.shade700, fontSize: 12),
                            ),
                          ),
                        const SizedBox(height: 10),
                        TextField(
                          controller: themeNotesController,
                          maxLines: 4,
                          decoration: const InputDecoration(
                            labelText: 'Theme / styling notes',
                            hintText: 'Describe preferred look, colors, motif, and styling notes',
                          ),
                        ),
                        const SizedBox(height: 10),
                        Row(
                          children: [
                            OutlinedButton.icon(
                              onPressed: _pickThemeReferenceImage,
                              icon: const Icon(Icons.upload_file),
                              label: const Text('Upload Reference Image'),
                            ),
                            const SizedBox(width: 8),
                            Text('${_themeReferenceImagesB64.length} image(s) attached'),
                          ],
                        ),
                        if (_themeReferenceImagesB64.isNotEmpty) ...[
                          const SizedBox(height: 8),
                          SizedBox(
                            height: 82,
                            child: ListView.separated(
                              scrollDirection: Axis.horizontal,
                              itemCount: _themeReferenceImagesB64.length,
                              separatorBuilder: (_, __) => const SizedBox(width: 8),
                              itemBuilder: (context, i) => Stack(
                                children: [
                                  ClipRRect(
                                    borderRadius: BorderRadius.circular(8),
                                    child: Image.memory(
                                      base64Decode(_themeReferenceImagesB64[i]),
                                      width: 82,
                                      height: 82,
                                      fit: BoxFit.cover,
                                    ),
                                  ),
                                  Positioned(
                                    right: 0,
                                    top: 0,
                                    child: InkWell(
                                      onTap: () => setState(() => _themeReferenceImagesB64.removeAt(i)),
                                      child: Container(
                                        color: Colors.black54,
                                        padding: const EdgeInsets.all(2),
                                        child: const Icon(Icons.close, size: 14, color: Colors.white),
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                ],
                const SizedBox(height: 10),
                ToggleSection(
                  title: 'MENU',
                  expanded: true,
                  onToggle: () {},
                  hideToggleIcon: true,
                  child: Column(
                    children: [
                      const Text('WOULD YOU LIKE TO CURATE YOUR OWN MENU?'),
                      const SizedBox(height: 8),
                      RadioListTile<bool>(
                        dense: true,
                        contentPadding: EdgeInsets.zero,
                        value: true,
                        groupValue: _menuChoicePicked ? curateOwn : null,
                        title: const Text('Yes, curate my own menu'),
                        onChanged: (v) => setState(() {
                          _menuChoicePicked = true;
                          curateOwn = true;
                          menuSuggestionNote = '';
                          selectedSetMenu = 'All Dishes';
                          selectedDishes.clear();
                        }),
                      ),
                      RadioListTile<bool>(
                        dense: true,
                        contentPadding: EdgeInsets.zero,
                        value: false,
                        groupValue: _menuChoicePicked ? curateOwn : null,
                        title: const Text('No, suggest a menu'),
                        onChanged: (v) => setState(() {
                          _menuChoicePicked = true;
                          curateOwn = false;
                          selectedDishes.clear();
                          menuSuggestionNote = 'No, suggest me a menu instead.';
                        }),
                      ),
                      if (_attemptedSubmit && !_menuChoicePicked)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 8),
                          child: Text(
                            'Required',
                            style: TextStyle(color: Colors.red.shade700, fontSize: 12),
                          ),
                        ),
                      if (curateOwn) ...[
                        CheckboxListTile(
                          dense: true,
                          contentPadding: EdgeInsets.zero,
                          title: const Text('With food tasting'),
                          value: foodTastingRequested,
                          onChanged: (v) => setState(() => foodTastingRequested = v ?? false),
                        ),
                        if (foodTastingRequested) ...[
                          const Align(
                            alignment: Alignment.centerLeft,
                            child: Text('Food Tasting Schedule', style: TextStyle(fontWeight: FontWeight.w700)),
                          ),
                          const SizedBox(height: 6),
                          Row(
                            children: [
                              Expanded(
                                child: TextField(
                                  controller: foodTastingDate,
                                  readOnly: true,
                                  decoration: _requiredDecoration(
                                    label: 'Food tasting date',
                                    invalid: foodTastingRequested && foodTastingDate.text.trim().isEmpty,
                                    hint: 'date',
                                  ),
                                  onTap: () async {
                                    final d = await showDatePicker(
                                      context: context,
                                      initialDate: DateTime.now(),
                                      firstDate: DateTime.now().subtract(const Duration(days: 1)),
                                      lastDate: DateTime.now().add(const Duration(days: 365 * 2)),
                                    );
                                    if (d == null) return;
                                    setState(() {
                                      foodTastingDate.text =
                                          '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
                                    });
                                  },
                                ),
                              ),
                              const SizedBox(width: 8),
                              Expanded(
                                child: TextField(
                                  controller: foodTastingTime,
                                  readOnly: true,
                                  decoration: _requiredDecoration(
                                    label: 'Food tasting time',
                                    invalid: foodTastingRequested && foodTastingTime.text.trim().isEmpty,
                                    hint: 'time',
                                  ),
                                  onTap: () async {
                                    final t = await showTimePicker(context: context, initialTime: const TimeOfDay(hour: 13, minute: 0));
                                    if (t == null) return;
                                    setState(() {
                                      foodTastingTime.text =
                                          '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';
                                    });
                                  },
                                ),
                              ),
                            ],
                          ),
                        ],
                        const SizedBox(height: 10),
                        TextField(
                          controller: menuSearchController,
                          decoration: const InputDecoration(labelText: 'Search dishes', prefixIcon: Icon(Icons.search)),
                          onChanged: (_) => setState(() {}),
                        ),
                        const SizedBox(height: 8),
                        DropdownButtonFormField<String>(
                          value: effectiveSetMenu,
                          items: setMenuNames.map((name) => DropdownMenuItem(value: name, child: Text(name))).toList(),
                          onChanged: (v) {
                            final next = v ?? 'All Dishes';
                            setState(() {
                              final prev = selectedSetMenu;
                              if (prev != next && prev != 'All Dishes') {
                                final prevRows = state.setMenus.where((m) => m.name == prev).toList();
                                if (prevRows.isNotEmpty) {
                                  for (final d in prevRows.first.dishes) {
                                    selectedDishes.remove(d);
                                  }
                                }
                              }
                              selectedSetMenu = next;
                              if (next != 'All Dishes') {
                                final rows = state.setMenus.where((m) => m.name == next).toList();
                                if (rows.isNotEmpty) selectedDishes.addAll(rows.first.dishes);
                              }
                            });
                          },
                        ),
                        const SizedBox(height: 8),
                        Align(
                          alignment: Alignment.centerLeft,
                          child: Text(
                            'Required selected dishes: at least $_minSelectedDishesRequired',
                            style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700),
                          ),
                        ),
                        const SizedBox(height: 6),
                        LayoutBuilder(
                          builder: (context, _) {
                            final sorted = availableDishes.toList()
                              ..sort((a, b) {
                                final sa = selectedDishes.contains(a) ? 0 : 1;
                                final sb = selectedDishes.contains(b) ? 0 : 1;
                                if (sa != sb) return sa - sb;
                                return a.toLowerCase().compareTo(b.toLowerCase());
                              });
                            final maxH = (MediaQuery.sizeOf(context).height * 0.38).clamp(220.0, 420.0);
                            return SizedBox(
                              height: maxH,
                              child: ListView(
                                shrinkWrap: false,
                                children: sorted.map((dishName) {
                                  MenuItemData? dish;
                                  for (final c in cateringMenu) {
                                    if (c.name == dishName) {
                                      dish = c;
                                      break;
                                    }
                                  }
                                  final sel = selectedDishes.contains(dishName);
                                  return Padding(
                                    padding: const EdgeInsets.only(bottom: 6),
                                    child: CheckboxListTile(
                                      dense: true,
                                      contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                                      tileColor: sel ? AppColors.brand.withValues(alpha: 0.35) : Colors.grey.shade100,
                                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                                      secondary: ClipRRect(
                                        borderRadius: BorderRadius.circular(6),
                                        child: SizedBox(
                                          width: 40,
                                          height: 40,
                                          child: dish != null
                                              ? _MenuThumb(item: dish, compact: true)
                                              : const Icon(Icons.fastfood, size: 22),
                                        ),
                                      ),
                                      title: Text(dishName, style: const TextStyle(fontSize: 13)),
                                      value: sel,
                                      onChanged: (_) => setState(() {
                                        if (sel) {
                                          selectedDishes.remove(dishName);
                                        } else {
                                          selectedDishes.add(dishName);
                                        }
                                      }),
                                      controlAffinity: ListTileControlAffinity.leading,
                                    ),
                                  );
                                }).toList(),
                              ),
                            );
                          },
                        ),
                        if (_attemptedSubmit && curateOwn && selectedDishes.length < _minSelectedDishesRequired)
                          Padding(
                            padding: const EdgeInsets.only(top: 6),
                            child: Text(
                              'Select at least $_minSelectedDishesRequired dish(es).',
                              style: TextStyle(color: Colors.red.shade700, fontSize: 12),
                            ),
                          ),
                      ],
                    ],
                  ),
                ),
              ],
              ),
            ),
          ),
          SummaryFooter(
            lines: [
              SummaryLine('Estimated Cost', '₱${estimate.toStringAsFixed(2)}', isTotal: true),
            ],
            secondaryLabel: 'CANCEL',
            actionLabel: 'SUBMIT',
            onSecondary: () => Navigator.of(context).pop(),
            onAction: () async {
              setState(() => _attemptedSubmit = true);
              final v = _validateInquiry();
              if (v != null) {
                appSnack(context, v);
                return;
              }
              final est = _estimatedCost();
              final typeLabel = _resolvedEventType();
              final ok = await showDialog<bool>(
                context: context,
                builder: (ctx) => AlertDialog(
                  title: const Text('Submit inquiry?'),
                  content: SingleChildScrollView(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text('Type: $inquiryType'),
                        if (inquiryType == 'CATERING AND EVENT' && eventTitle.text.trim().isNotEmpty) ...[
                          const SizedBox(height: 6),
                          Text('Event: ${eventTitle.text.trim()}'),
                        ],
                        const SizedBox(height: 6),
                        Text('Event type: $typeLabel'),
                        const SizedBox(height: 6),
                        Text('Guests: ${guestCount.text.trim()}'),
                        const SizedBox(height: 6),
                        Text('Venue: ${eventCity.text.trim()}'),
                        const SizedBox(height: 6),
                        Text('When: ${_serializedEventDates()}'),
                        const SizedBox(height: 6),
                        Text('Estimated: ₱${est.toStringAsFixed(2)}'),
                      ],
                    ),
                  ),
                  actions: [
                    TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Back')),
                    FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Submit')),
                  ],
                ),
              );
              if (ok != true || !context.mounted) return;
              showDialog<void>(
                context: context,
                barrierDismissible: false,
                builder: (loadingCtx) => PopScope(
                  canPop: false,
                  child: AlertDialog(
                    content: Row(
                      children: [
                        const CircularProgressIndicator(),
                        const SizedBox(width: 18),
                        Expanded(
                          child: Text(
                            'Submitting inquiry…',
                            style: TextStyle(color: Colors.grey.shade800, fontWeight: FontWeight.w600),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              );
              String? err;
              try {
              final guestsSaved = _guestCountForSubmit();
              err = await state.submitInquiry({
                'inquiry_type': inquiryType,
                'event_title': eventTitle.text.trim(),
                'event_type': (inquiryType == 'CATERING' || inquiryType == 'CATERING AND EVENT') ? _resolvedEventType() : '',
                'customer': contactPerson.text.trim(),
                'contact_person': contactPerson.text.trim(),
                'contact_number': contactNumber.text.trim(),
                'inquiry_email': inquiryEmail.text.trim(),
                'date_of_event': _scheduleSlotsJsonForSubmit(),
                'note': note.text.trim(),
                'curate_own_menu': curateOwn,
                'selected_set_menu': selectedSetMenu,
                'selected_dishes': selectedDishes.toList(),
                'include_event_theme': inquiryType == 'CATERING AND EVENT',
                'guest_count': guestsSaved,
                'estimated_total': est,
                'menu_suggestion_note': curateOwn ? '' : menuSuggestionNote,
                'theme_suggestion_note': themeNotesController.text.trim(),
                if (inquiryType == 'CATERING AND EVENT')
                  'theme_design': {
                    'note': themeNotesController.text.trim(),
                    'reference_images': _themeReferenceImagesB64,
                  },
                'event_city': eventCity.text.trim(),
                'event_setting': eventSetting,
                'service_included': serviceIncluded,
                'formality_level': inquiryType == 'CATERING AND EVENT' ? formalityLevel : '',
                'food_tasting_requested': foodTastingRequested,
                'food_tasting_date': foodTastingDate.text.trim(),
                'food_tasting_time': foodTastingTime.text.trim(),
              });
              } finally {
                if (context.mounted) Navigator.of(context).pop();
              }
              if (!context.mounted) return;
              if (err != null) {
                appSnack(context, err);
                return;
              }
              appSnack(context, 'Inquiry submitted');
              Navigator.of(context).pushReplacement(MaterialPageRoute<void>(builder: (_) => RestaurantMenuScreen(state: state)));
            },
          ),
        ],
      ),
    );
  }
}

class MyInquiriesScreen extends StatefulWidget {
  const MyInquiriesScreen({super.key, required this.state});
  final AppState state;

  @override
  State<MyInquiriesScreen> createState() => _MyInquiriesScreenState();
}

class _MyInquiriesScreenState extends State<MyInquiriesScreen> with SingleTickerProviderStateMixin {
  late TabController _tab;
  String _search = '';
  String _filter = 'all';
  Map<String, Map<String, dynamic>> _feedbackByInquiryId = <String, Map<String, dynamic>>{};
  Set<String> _readCompletedInquiryIds = <String>{};

  String get _feedbackPrefsKey {
    final e = widget.state.userEmail?.trim().toLowerCase() ?? 'guest';
    return 'inquiry_feedback_v1_$e';
  }

  String get _readCompletedPrefsKey {
    final e = widget.state.userEmail?.trim().toLowerCase() ?? 'guest';
    return 'inquiry_completed_read_v1_$e';
  }

  Future<void> _loadInquiryLocalState() async {
    final prefs = await SharedPreferences.getInstance();
    final rawFeedback = prefs.getString(_feedbackPrefsKey);
    final rawRead = prefs.getStringList(_readCompletedPrefsKey) ?? const <String>[];
    final nextFeedback = <String, Map<String, dynamic>>{};
    if (rawFeedback != null && rawFeedback.trim().isNotEmpty) {
      try {
        final decoded = jsonDecode(rawFeedback);
        if (decoded is Map<String, dynamic>) {
          decoded.forEach((k, v) {
            if (v is Map<String, dynamic>) nextFeedback[k] = v;
          });
        }
      } catch (_) {}
    }
    if (!mounted) return;
    setState(() {
      _feedbackByInquiryId = nextFeedback;
      _readCompletedInquiryIds = rawRead.map((e) => e.trim()).where((e) => e.isNotEmpty).toSet();
    });
  }

  Future<void> _persistFeedbackState() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_feedbackPrefsKey, jsonEncode(_feedbackByInquiryId));
  }

  Future<void> _persistReadState() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(_readCompletedPrefsKey, _readCompletedInquiryIds.toList()..sort());
  }

  bool _isCompletedInquiryUnread(InquiryRecord r) {
    if (!r.isCompletedBooking) return false;
    if (_feedbackByInquiryId.containsKey(r.id.toString())) return false;
    return !_readCompletedInquiryIds.contains(r.id.toString());
  }

  Color _inquiryStatusBadgeBg(String status) {
    final s = status.trim().toLowerCase();
    if (s == 'completed') return Colors.green.shade100;
    if (s == 'cancelled') return Colors.grey.shade300;
    if (s == 'for_post_analysis' || s == 'for_processing') return Colors.blue.shade100;
    return Colors.orange.shade100;
  }

  Color _inquiryStatusBadgeFg(String status) {
    final s = status.trim().toLowerCase();
    if (s == 'completed') return Colors.green.shade900;
    if (s == 'cancelled') return Colors.grey.shade900;
    if (s == 'for_post_analysis' || s == 'for_processing') return Colors.blue.shade900;
    return Colors.orange.shade900;
  }

  Future<void> _markCompletedInquiryRead(InquiryRecord r) async {
    if (!r.isCompletedBooking) return;
    final id = r.id.toString();
    if (_readCompletedInquiryIds.contains(id)) return;
    setState(() => _readCompletedInquiryIds.add(id));
    await _persistReadState();
  }

  @override
  void initState() {
    super.initState();
    _tab = TabController(length: 4, vsync: this);
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      await _loadInquiryLocalState();
      await widget.state.loadInquiries(force: true);
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _tab.dispose();
    super.dispose();
  }

  List<Widget> _inquiryDetailLines(InquiryRecord r) {
    final isFullEvent = r.inquiryType == 'CATERING AND EVENT';
    Widget line(String text) => Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: Text(text, style: const TextStyle(height: 1.35)),
        );

    final lines = <Widget>[
      line('Transaction no.: ${r.displayTransactionRef}'),
      line('Type: ${r.inquiryType}'),
      line('Status: ${inquiryStatusReadable(r.status)}'),
    ];
    if (r.isCompletedBooking && r.loyaltyPointsEarned > 0) {
      lines.add(line('Catering loyalty: +${r.loyaltyPointsEarned} pts'));
    }

    if (r.eventType.trim().isNotEmpty) {
      lines.add(line('Event type: ${r.eventType}'));
    }
    if (isFullEvent) {
      if (r.eventTitle.trim().isNotEmpty) lines.add(line('Event title: ${r.eventTitle}'));
      if (r.formalityLevel.trim().isNotEmpty) lines.add(line('Formality: ${r.formalityLevel}'));
      if (r.eventCity.trim().isNotEmpty) lines.add(line('City: ${r.eventCity}'));
      if (r.eventSetting.trim().isNotEmpty) lines.add(line('Setting: ${r.eventSetting}'));
      if (r.themeSuggestionNote.trim().isNotEmpty) lines.add(line('Theme / styling: ${r.themeSuggestionNote}'));
    }

    lines.add(line('Guests: ${r.guestCount}'));
    lines.add(line('Contact: ${r.contactPerson} / ${r.contactNumber}'));
    lines.add(line('Email: ${r.inquiryEmail}'));
    if (r.dateOfEvent.trim().isNotEmpty) {
      final formatted = formatScheduleSlotLine(r.dateOfEvent).trim();
      if (formatted.isNotEmpty) {
        lines.add(line('Date/Time of Event:'));
        for (final ln in formatted.split('\n')) {
          final t = ln.trim();
          if (t.isNotEmpty) lines.add(line(t));
        }
      }
    }
    if (r.serviceIncluded.trim().isNotEmpty) {
      lines.add(line('Service: ${r.serviceIncluded == 'yes' ? 'With service' : 'Without service'}'));
    }
    lines.add(line('Food tasting requested: ${r.foodTastingRequested ? 'Yes' : 'No'}'));
    if (r.note.trim().isNotEmpty) lines.add(line('Note: ${r.note}'));
    lines.add(line('Curate own menu: ${r.curateOwnMenu ? 'Yes' : 'No'}'));
    if (r.selectedSetMenu.trim().isNotEmpty && r.selectedSetMenu != 'All Dishes') {
      lines.add(line('Set menu: ${r.selectedSetMenu}'));
    }
    if (r.selectedDishes.isNotEmpty) {
      lines.add(line('Dishes: ${r.selectedDishes.join(', ')}'));
    }
    if (r.menuSuggestionNote.trim().isNotEmpty &&
        !r.menuSuggestionNote.toLowerCase().contains('suggest me a menu instead')) {
      lines.add(line('Menu note: ${r.menuSuggestionNote}'));
    }
    if (r.estimatedTotal > 0) {
      final st = r.status.trim().toLowerCase();
      final useFinal = st == 'for_processing' || st == 'for_post_analysis' || st == 'completed';
      lines.add(
        line('${useFinal ? 'Final cost' : 'Estimated cost'}: ₱${r.estimatedTotal.toStringAsFixed(2)}'),
      );
    }
    if (r.downPaymentAmount > 0) {
      lines.add(line('Down payment paid: ₱${r.downPaymentAmount.toStringAsFixed(2)}'));
    }
    if (r.fullPaymentAmount > 0) {
      lines.add(line('Full payment recorded: ₱${r.fullPaymentAmount.toStringAsFixed(2)}'));
    }
    lines.add(line('Submitted: ${formatDateTimeLocal(r.createdAt)}'));

    return lines;
  }

  Future<void> _followUp(InquiryRecord r) async {
    final ref = r.displayTransactionRef;
    final err = await widget.state.submitHelpRequest(
      area: 'Catering Inquiry Follow-up',
      problem: 'Customer follow-up on inquiry $ref',
      desiredOutcome: 'Please review and respond to this inquiry as soon as possible.',
    );
    if (!mounted) return;
    appSnack(context, err ?? 'Follow-up sent to manager');
  }

  Future<void> _cancelInquiry(InquiryRecord r) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Cancel inquiry/order?'),
        content: Text('Cancel ${r.displayTransactionRef}?'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('No')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Yes, cancel')),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    final err = await widget.state.cancelInquiryAsCustomer(inquiryId: r.id);
    if (!mounted) return;
    appSnack(context, err ?? 'Inquiry cancelled');
  }

  Future<void> _sendFeedback(InquiryRecord r) async {
    final ctl = TextEditingController(
      text: (_feedbackByInquiryId[r.id.toString()]?['remarks'] ?? '').toString(),
    );
    var stars = 5;
    final prevStars = _feedbackByInquiryId[r.id.toString()]?['stars'];
    if (prevStars is int) {
      stars = prevStars.clamp(1, 5);
    } else if (prevStars != null) {
      final n = int.tryParse('$prevStars');
      if (n != null) stars = n.clamp(1, 5);
    }
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (ctx, setModalState) => AlertDialog(
            title: Text('Feedback · ${r.displayTransactionRef}'),
            content: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('How was your experience?'),
                  const SizedBox(height: 8),
                  Row(
                    children: List.generate(5, (idx) {
                      final selected = idx < stars;
                      return IconButton(
                        visualDensity: VisualDensity.compact,
                        splashRadius: 20,
                        onPressed: () => setModalState(() => stars = idx + 1),
                        icon: Icon(
                          selected ? Icons.star : Icons.star_border,
                          color: selected ? Colors.amber : null,
                        ),
                      );
                    }),
                  ),
                  const SizedBox(height: 8),
                  TextField(
                    controller: ctl,
                    maxLines: 4,
                    decoration: const InputDecoration(
                      labelText: 'Remarks',
                      hintText: 'Share your feedback for this completed catering order',
                    ),
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
              FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Submit')),
            ],
          ),
        );
      },
    );
    final msg = ctl.text.trim();
    if (ok != true || msg.isEmpty || !mounted) return;
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => const Center(child: CircularProgressIndicator()),
    );
    final err = await widget.state.submitHelpRequest(
      area: 'Catering Feedback',
      problem: 'Customer feedback for ${r.displayTransactionRef}',
      desiredOutcome: 'Rating: ${stars.toString()}/5\nRemarks: $msg',
    );
    if (mounted) Navigator.of(context).pop();
    if (!mounted) return;
    if (err == null) {
      setState(() {
        _feedbackByInquiryId[r.id.toString()] = <String, dynamic>{
          'stars': stars,
          'remarks': msg,
          'submittedAt': DateTime.now().toIso8601String(),
        };
        _readCompletedInquiryIds.add(r.id.toString());
      });
      await _persistFeedbackState();
      await _persistReadState();
    }
    appSnack(context, err ?? 'Feedback submitted');
  }

  void _showDetail(InquiryRecord r, {required bool allowFollowUp}) {
    _markCompletedInquiryRead(r);
    final feedback = _feedbackByInquiryId[r.id.toString()];
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(r.displayTransactionRef),
        content: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              ..._inquiryDetailLines(r),
              if (feedback != null) ...[
                const SizedBox(height: 8),
                const Divider(height: 16),
                Text(
                  'Your feedback',
                  style: Theme.of(context).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 6),
                Text('Rating: ${feedback['stars'] ?? 5}/5'),
                const SizedBox(height: 4),
                Text('Remarks: ${(feedback['remarks'] ?? '').toString()}'),
              ],
            ],
          ),
        ),
        actions: [
          if (allowFollowUp) TextButton(onPressed: () => _followUp(r), child: const Text('Follow up')),
          TextButton(onPressed: () => Navigator.of(ctx).pop(), child: const Text('Close')),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.state;
    final waiting = s.inquiries.where((r) => r.isWaiting).toList();
    final responded = s.inquiries.where((r) => !r.isWaiting && !r.isCompletedBooking && r.status.trim().toLowerCase() != 'cancelled').toList();
    final completed = s.inquiries.where((r) => r.isCompletedBooking).toList();
    final cancelled = s.inquiries.where((r) => r.status.trim().toLowerCase() == 'cancelled').toList();

    Widget buildList(
      List<InquiryRecord> list, {
      required bool allowFollowUp,
      bool showLoyaltyHint = false,
      bool allowFeedback = false,
      bool allowCancel = false,
    }) {
      final q = _search.trim().toLowerCase();
      final filtered = list.where((i) {
        if (q.isNotEmpty) {
          final ok = i.displayTransactionRef.toLowerCase().contains(q) ||
              i.inquiryType.toLowerCase().contains(q) ||
              i.eventTitle.toLowerCase().contains(q) ||
              i.status.toLowerCase().contains(q);
          if (!ok) return false;
        }
        switch (_filter) {
          case 'event_only':
            return i.inquiryType == 'CATERING AND EVENT';
          case 'catering_only':
            return i.inquiryType == 'CATERING';
          default:
            return true;
        }
      }).toList();
      return RefreshIndicator(
        onRefresh: () async {
          await s.loadInquiries(force: true);
          if (mounted) setState(() {});
        },
        child: filtered.isEmpty
            ? ListView(
                physics: const AlwaysScrollableScrollPhysics(),
                children: const [
                  SizedBox(height: 120),
                  Center(child: Text('No inquiries here yet.')),
                ],
              )
            : ListView.builder(
                physics: const AlwaysScrollableScrollPhysics(),
                padding: const EdgeInsets.all(8),
                itemCount: filtered.length,
                itemBuilder: (context, index) {
                  final i = filtered[index];
                  final hasFeedback = _feedbackByInquiryId.containsKey(i.id.toString());
                  final hasUnreadCompleted = _isCompletedInquiryUnread(i);
                  Widget? trailing;
                  if (allowFollowUp) {
                    trailing = Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        IconButton(
                          icon: const Icon(Icons.reply_outlined),
                          tooltip: 'Follow up',
                          onPressed: () => _followUp(i),
                        ),
                        if (allowCancel)
                          IconButton(
                            icon: Icon(Icons.cancel_outlined, color: Colors.red.shade800),
                            tooltip: 'Cancel inquiry',
                            onPressed: () => _cancelInquiry(i),
                          ),
                      ],
                    );
                  } else if (allowCancel && i.status.trim().toLowerCase() == 'for_processing') {
                    trailing = IconButton(
                      icon: Icon(Icons.cancel_outlined, color: Colors.red.shade800),
                      tooltip: 'Cancel order',
                      onPressed: () => _cancelInquiry(i),
                    );
                  } else if (allowFeedback) {
                    trailing = Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (hasUnreadCompleted)
                          const Padding(
                            padding: EdgeInsets.only(right: 6),
                            child: Icon(Icons.circle, color: Colors.red, size: 10),
                          ),
                        IconButton(
                          icon: Icon(hasFeedback ? Icons.check_circle : Icons.rate_review_outlined),
                          tooltip: hasFeedback ? 'Feedback submitted' : 'Feedback',
                          onPressed: () => _sendFeedback(i),
                        ),
                      ],
                    );
                  }
                  return Stack(
                    children: [
                      Card(
                        margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                        child: ListTile(
                          title: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Container(
                                constraints: const BoxConstraints(maxWidth: 165),
                                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                                decoration: BoxDecoration(
                                  color: _inquiryStatusBadgeBg(i.status),
                                  borderRadius: BorderRadius.circular(999),
                                ),
                                child: Text(
                                  inquiryStatusReadable(i.status),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    fontSize: 10.5,
                                    fontWeight: FontWeight.w700,
                                    color: _inquiryStatusBadgeFg(i.status),
                                  ),
                                ),
                              ),
                              const SizedBox(height: 4),
                              Text(i.displayTransactionRef),
                            ],
                          ),
                          subtitle: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                showLoyaltyHint && i.loyaltyPointsEarned > 0
                                    ? '${i.inquiryType} — ${i.eventTitle}\n'
                                        'Loyalty: +${i.loyaltyPointsEarned} pts\n'
                                        '${formatDateTimeLocal(i.createdAt)}'
                                    : '${i.inquiryType} — ${i.eventTitle}\n${formatDateTimeLocal(i.createdAt)}',
                              ),
                              if (allowFeedback && hasFeedback) ...[
                                const SizedBox(height: 4),
                                Text(
                                  'Feedback: ${"★" * ((int.tryParse("${_feedbackByInquiryId[i.id.toString()]?['stars'] ?? 5}") ?? 5).clamp(1, 5))}',
                                  style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700),
                                ),
                              ],
                              if (allowFeedback && hasUnreadCompleted) ...[
                                const SizedBox(height: 4),
                                Text(
                                  "We'd love to have your feedback!",
                                  style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: Colors.red.shade700),
                                ),
                              ],
                              if (i.estimatedTotal > 0) ...[
                                const SizedBox(height: 4),
                                Text(
                                  '₱${i.estimatedTotal.toStringAsFixed(2)}',
                                  style: TextStyle(
                                    fontSize: 12,
                                    fontWeight: FontWeight.w800,
                                    color: Colors.blueGrey.shade800,
                                  ),
                                ),
                              ],
                            ],
                          ),
                          isThreeLine: true,
                          trailing: trailing,
                          onTap: () => _showDetail(i, allowFollowUp: allowFollowUp),
                        ),
                      ),
                      if (allowFeedback && hasUnreadCompleted)
                        const Positioned(
                          right: 18,
                          top: 10,
                          child: Icon(Icons.circle, color: Colors.red, size: 10),
                        ),
                    ],
                  );
                },
              ),
      );
    }

    return AppScaffold(
      state: s,
      title: 'MY CATERING INQUIRIES',
      showTrayShortcut: false,
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 12, 12, 8),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    decoration: const InputDecoration(
                      hintText: 'SEARCH REF, TYPE, TITLE, STATUS',
                      prefixIcon: Icon(Icons.search),
                    ),
                    onChanged: (v) => setState(() => _search = v),
                  ),
                ),
                const SizedBox(width: 8),
                PopupMenuButton<String>(
                  tooltip: 'Filters',
                  icon: Icon(Icons.filter_list, color: _filter == 'all' ? null : AppColors.accent),
                  onSelected: (v) => setState(() => _filter = v),
                  itemBuilder: (_) => const [
                    PopupMenuItem(value: 'all', child: Text('All')),
                    PopupMenuItem(value: 'catering_only', child: Text('Catering')),
                    PopupMenuItem(value: 'event_only', child: Text('Catering+Event')),
                  ],
                ),
              ],
            ),
          ),
          TabBar(
            controller: _tab,
            isScrollable: true,
            tabs: [
              const Tab(text: 'WAITING FOR RESPONSE'),
              const Tab(text: 'RESPONDED'),
              Tab(
                child: Badge(
                  isLabelVisible: completed.any((r) => _isCompletedInquiryUnread(r)),
                  backgroundColor: Colors.red,
                  smallSize: 10,
                  child: const Text('COMPLETED CATERING ORDERS'),
                ),
              ),
              const Tab(text: 'CANCELLED'),
            ],
          ),
          Expanded(
            child: TabBarView(
              controller: _tab,
              children: [
                buildList(waiting, allowFollowUp: true, allowCancel: true),
                buildList(responded, allowFollowUp: false, allowCancel: true),
                buildList(completed, allowFollowUp: false, showLoyaltyHint: true, allowFeedback: true),
                buildList(cancelled, allowFollowUp: false),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key, required this.state});
  final AppState state;

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  final helpArea = TextEditingController();
  final helpProblem = TextEditingController();
  final helpWant = TextEditingController();

  @override
  void dispose() {
    helpArea.dispose();
    helpProblem.dispose();
    helpWant.dispose();
    super.dispose();
  }

  Future<void> _confirmLogout() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Log out?'),
        content: const Text('You will need to sign in again to use the app.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Log out')),
        ],
      ),
    );
    if (ok == true && context.mounted) {
      widget.state.logout();
      if (!mounted) return;
      Navigator.of(context, rootNavigator: true).pushAndRemoveUntil(
        MaterialPageRoute<void>(builder: (_) => AuthScreen(state: widget.state, cashierMode: kPosLoginBuild)),
        (_) => false,
      );
    }
  }

  void _openHelp() {
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Help request'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: helpArea,
                decoration: const InputDecoration(labelText: 'Which part of the app?'),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: helpProblem,
                maxLines: 3,
                decoration: const InputDecoration(labelText: 'What is your concern or problem?'),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: helpWant,
                maxLines: 3,
                decoration: const InputDecoration(labelText: 'What would you like to happen?'),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(
            onPressed: () async {
              final err = await widget.state.submitHelpRequest(
                area: helpArea.text.trim(),
                problem: helpProblem.text.trim(),
                desiredOutcome: helpWant.text.trim(),
              );
              if (!context.mounted) return;
              Navigator.pop(ctx);
              if (err != null) {
                appSnack(context, err);
              } else {
                appSnack(context, 'Help request sent');
                helpArea.clear();
                helpProblem.clear();
                helpWant.clear();
              }
            },
            child: const Text('Submit'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: widget.state,
      builder: (context, _) {
        return AppScaffold(
          state: widget.state,
          title: 'SETTINGS',
          showTrayShortcut: false,
          body: Padding(
            padding: const EdgeInsets.all(14),
            child: RefreshIndicator(
              onRefresh: () async {
                await widget.state.loadProfile(force: true);
                if (mounted) setState(() {});
              },
              child: SingleChildScrollView(
                physics: const AlwaysScrollableScrollPhysics(),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (widget.state.isManagerOrSupervisor)
                      const ListTile(
                        leading: Icon(Icons.restaurant_menu),
                        title: Text('Restaurant loyalty rewards'),
                        subtitle: Text(
                          'Customers earn loyalty points on confirmed restaurant orders (tracked separately from catering/event loyalty). '
                          'Rates are applied automatically when orders complete.',
                        ),
                      ),
                    ListTile(
                      leading: Icon(widget.state.themeMode == ThemeMode.dark ? Icons.dark_mode_outlined : Icons.light_mode_outlined),
                      title: const Text('Appearance'),
                      subtitle: Padding(
                        padding: const EdgeInsets.only(top: 8),
                        child: SegmentedButton<ThemeMode>(
                          segments: const [
                            ButtonSegment<ThemeMode>(
                              value: ThemeMode.light,
                              icon: Icon(Icons.light_mode),
                              label: Text('Light'),
                            ),
                            ButtonSegment<ThemeMode>(
                              value: ThemeMode.dark,
                              icon: Icon(Icons.dark_mode),
                              label: Text('Dark'),
                            ),
                          ],
                          selected: {widget.state.themeMode},
                          onSelectionChanged: (Set<ThemeMode> next) {
                            if (next.isNotEmpty) widget.state.setThemeMode(next.first);
                          },
                        ),
                      ),
                    ),
                    ListTile(
                      leading: const Icon(Icons.help_outline),
                      title: const Text('Help request'),
                      subtitle: const Text('Describe your issue so we can help'),
                      onTap: _openHelp,
                    ),
                    ListTile(
                      leading: const Icon(Icons.logout),
                      title: const Text('Log out'),
                      onTap: _confirmLogout,
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

class ToggleSection extends StatelessWidget {
  const ToggleSection({
    super.key,
    required this.title,
    required this.expanded,
    required this.onToggle,
    required this.child,
    this.titleColor = AppColors.brand,
    this.hideToggleIcon = false,
  });
  final String title;
  final bool expanded;
  final VoidCallback? onToggle;
  final Widget child;
  final Color titleColor;
  final bool hideToggleIcon;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(color: Colors.white, border: Border.all(color: AppColors.border), borderRadius: BorderRadius.circular(14)),
      child: Column(
        children: [
          InkWell(
            onTap: onToggle,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              decoration: BoxDecoration(color: titleColor, borderRadius: const BorderRadius.vertical(top: Radius.circular(14))),
              child: Row(
                children: [
                  Expanded(child: Text(title, textAlign: TextAlign.center, style: const TextStyle(fontWeight: FontWeight.w800))),
                  if (!hideToggleIcon) Icon(expanded ? Icons.remove : Icons.add),
                ],
              ),
            ),
          ),
          if (expanded) Padding(padding: const EdgeInsets.all(12), child: child),
        ],
      ),
    );
  }
}

class LockedField extends StatelessWidget {
  const LockedField({super.key, required this.label, required this.value});
  final String label;
  final String value;
  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        children: [
          SizedBox(width: 120, child: Text(label, style: const TextStyle(fontWeight: FontWeight.w700))),
          Expanded(
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
              decoration: BoxDecoration(color: Colors.grey.shade200, borderRadius: BorderRadius.circular(8), border: Border.all(color: AppColors.border)),
              child: Text(value),
            ),
          ),
        ],
      ),
    );
  }
}

class _OrderNoCard extends StatelessWidget {
  /// Checkout: omit [displayNo] — shows label only until the order exists.
  const _OrderNoCard({this.displayNo});
  final String? displayNo;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(12), border: Border.all(color: AppColors.brand)),
      child: displayNo != null && displayNo!.trim().isNotEmpty
          ? Text(displayNo!.trim(), style: const TextStyle(fontWeight: FontWeight.w700))
          : Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('ORDER NO.', style: TextStyle(fontWeight: FontWeight.w800)),
                const SizedBox(height: 4),
                Text(
                  'Your order number appears here after you confirm.',
                  style: TextStyle(fontSize: 12, color: Colors.grey.shade800, height: 1.25),
                ),
              ],
            ),
    );
  }
}

class SummaryLine {
  const SummaryLine(this.label, this.value, {this.isTotal = false});
  final String label;
  final String value;
  final bool isTotal;
}

class SummaryFooter extends StatelessWidget {
  const SummaryFooter({
    super.key,
    required this.lines,
    this.secondaryLabel,
    this.actionLabel,
    this.onSecondary,
    this.onAction,
  });
  final List<SummaryLine> lines;
  final String? secondaryLabel;
  final String? actionLabel;
  final VoidCallback? onSecondary;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(color: Colors.white, border: Border(top: BorderSide(color: Color(0xFF8ADFC1)))),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              children: lines
                  .map(
                    (l) => Row(
                      children: [
                        Expanded(child: Text(l.label, style: TextStyle(fontWeight: l.isTotal ? FontWeight.w800 : FontWeight.w500, fontSize: l.isTotal ? 22 : 14))),
                        Text(l.value, style: TextStyle(fontWeight: FontWeight.w800, fontSize: l.isTotal ? 22 : 14)),
                      ],
                    ),
                  )
                  .toList(),
            ),
          ),
          if (secondaryLabel != null || actionLabel != null)
            Row(
              children: [
                if (secondaryLabel != null)
                  Expanded(
                    child: FilledButton(
                      onPressed: onSecondary,
                      style: FilledButton.styleFrom(backgroundColor: AppColors.accent, shape: const RoundedRectangleBorder()),
                      child: Text(secondaryLabel!),
                    ),
                  ),
                if (actionLabel != null)
                  Expanded(
                    child: FilledButton(
                      onPressed: onAction,
                      style: FilledButton.styleFrom(backgroundColor: AppColors.brand, foregroundColor: AppColors.ink, shape: const RoundedRectangleBorder()),
                      child: Text(actionLabel!),
                    ),
                  ),
              ],
            ),
        ],
      ),
    );
  }
}

void showCashierHelpDialog(BuildContext context, AppState state) {
  final area = TextEditingController();
  final problem = TextEditingController();
  final outcome = TextEditingController();
  showDialog<void>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('Help request'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(controller: area, decoration: const InputDecoration(labelText: 'Which part of the app?')),
            const SizedBox(height: 10),
            TextField(controller: problem, maxLines: 3, decoration: const InputDecoration(labelText: 'What is the problem?')),
            const SizedBox(height: 10),
            TextField(controller: outcome, maxLines: 3, decoration: const InputDecoration(labelText: 'Desired outcome')),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
        FilledButton(
          onPressed: () async {
            final err = await state.submitHelpRequest(
              area: area.text.trim(),
              problem: problem.text.trim(),
              desiredOutcome: outcome.text.trim(),
            );
            if (!context.mounted) return;
            Navigator.pop(ctx);
            if (err != null) {
              appSnack(context, err);
            } else {
              appSnack(context, 'Help request sent');
            }
          },
          child: const Text('Submit'),
        ),
      ],
    ),
  );
}

class PosOrderHistoryScreen extends StatefulWidget {
  const PosOrderHistoryScreen({super.key, required this.state});
  final AppState state;

  @override
  State<PosOrderHistoryScreen> createState() => _PosOrderHistoryScreenState();
}

class _PosOrderHistoryScreenState extends State<PosOrderHistoryScreen> {
  Color _statusBadgeBg(String status) {
    final up = status.toUpperCase();
    if (up.contains('INSUFFICIENT')) return Colors.red.shade100;
    if (up.contains('CONFIRMED') || up.contains('OVERPAYMENT')) return Colors.green.shade100;
    if (up.contains('CANCEL')) return Colors.grey.shade300;
    return Colors.orange.shade100;
  }

  Color _statusBadgeFg(String status) {
    final up = status.toUpperCase();
    if (up.contains('INSUFFICIENT')) return Colors.red.shade900;
    if (up.contains('CONFIRMED') || up.contains('OVERPAYMENT')) return Colors.green.shade900;
    if (up.contains('CANCEL')) return Colors.grey.shade900;
    return Colors.orange.shade900;
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => widget.state.loadCashierOrderHistory(force: true));
  }

  Widget _historyProofImage(BuildContext context, String? b64, {String title = 'Payment proof'}) {
    if (b64 == null || b64.trim().isEmpty) return const SizedBox.shrink();
    try {
      final bytes = Uint8List.fromList(base64Decode(b64.trim()));
      return InkWell(
        onTap: () => showProofFullScreen(context, bytes, title: title),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(10),
          child: Image.memory(
            bytes,
            height: 200,
            fit: BoxFit.contain,
          ),
        ),
      );
    } catch (_) {
      return const Text('(Invalid image data)');
    }
  }

  void _showOrderDetail(OrderData o) {
    final p1 = _historyProofImage(context, o.paymentProofBase64, title: 'Payment proof');
    final p2 = _historyProofImage(context, o.supplementalPaymentProofBase64, title: 'Additional payment proof');
    final showP1 = o.paymentProofBase64 != null && o.paymentProofBase64!.trim().isNotEmpty;
    final showP2 = o.supplementalPaymentProofBase64 != null && o.supplementalPaymentProofBase64!.trim().isNotEmpty;
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(o.orderNo),
        content: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('Placed: ${formatDateTimeLocal(o.createdAt)}'),
              Text('Source: ${o.orderSource}'),
              Text('Status: ${statusReadable(o.status)}'),
              Text('Fulfillment: ${o.fulfillmentStage}'),
              if ((o.userEmail ?? '').trim().isNotEmpty) Text('Customer email: ${o.userEmail}'),
              if (o.posCustomerLabel.trim().isNotEmpty) Text('Walk-in label: ${o.posCustomerLabel}'),
              Text('Payment: ${o.paymentMode}'),
              Text('Total: ₱${o.total.toStringAsFixed(2)}'),
              if (o.loyaltyPointsEarned > 0)
                Text('Customer loyalty (this order): +${o.loyaltyPointsEarned} pts'),
              if (o.cashierAmountReceived != null)
                Text('Amount received (recorded): ₱${o.cashierAmountReceived!.toStringAsFixed(2)}'),
              if (o.cashierSecondaryAmountReceived != null)
                Text('Additional amount (recorded): ₱${o.cashierSecondaryAmountReceived!.toStringAsFixed(2)}'),
              if (o.paymentMode.toUpperCase().contains('CASH') &&
                  o.cashierChange != null &&
                  o.cashierChange!.abs() > 0.005)
                Text('Change given: ₱${o.cashierChange!.toStringAsFixed(2)}'),
              const SizedBox(height: 12),
              if (showP1) ...[
                const Text('Payment proof', style: TextStyle(fontWeight: FontWeight.w800)),
                const SizedBox(height: 8),
                p1,
              ],
              if (showP2) ...[
                const SizedBox(height: 12),
                const Text('Additional payment proof', style: TextStyle(fontWeight: FontWeight.w800)),
                const SizedBox(height: 8),
                p2,
              ],
              const SizedBox(height: 12),
              const Text('Items', style: TextStyle(fontWeight: FontWeight.w800)),
              if (o.lines.isEmpty)
                const Text('No line items.')
              else
                ...o.lines.map(
                  (l) => Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: Text(
                      '• ${l.itemName}${l.dip.isEmpty ? '' : ' (${l.dip})'} ×${l.qty} @ ₱${l.price.toStringAsFixed(2)}',
                    ),
                  ),
                ),
              if (o.note.trim().isNotEmpty) ...[
                const SizedBox(height: 12),
                Text('Note: ${o.note}'),
              ],
            ],
          ),
        ),
        actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Close'))],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: widget.state,
      builder: (context, _) {
        final rows = widget.state.cashierOrderHistory;
        return Scaffold(
          appBar: AppBar(title: const Text('ORDER HISTORY'), backgroundColor: Colors.black87, foregroundColor: Colors.white),
          body: RefreshIndicator(
            onRefresh: () => widget.state.loadCashierOrderHistory(force: true),
            child: rows.isEmpty
                ? ListView(
                    physics: const AlwaysScrollableScrollPhysics(),
                    children: const [
                      SizedBox(height: 120, child: Center(child: Text('No orders loaded yet.'))),
                    ],
                  )
                : ListView.builder(
                    padding: const EdgeInsets.all(12),
                    itemCount: rows.length,
                    itemBuilder: (context, i) {
                      final o = rows[i];
                      return Card(
                        child: ListTile(
                          title: Row(
                            children: [
                              Expanded(child: Text(o.orderNo)),
                              const SizedBox(width: 6),
                              Container(
                                constraints: const BoxConstraints(maxWidth: 180),
                                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                                decoration: BoxDecoration(
                                  color: _statusBadgeBg(o.status),
                                  borderRadius: BorderRadius.circular(999),
                                ),
                                child: Text(
                                  statusReadable(o.status),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    fontSize: 10.5,
                                    fontWeight: FontWeight.w700,
                                    color: _statusBadgeFg(o.status),
                                  ),
                                ),
                              ),
                            ],
                          ),
                          subtitle: Text(
                            '${o.orderSource}\n${formatDateTimeLocal(o.createdAt)}'
                            '${o.loyaltyPointsEarned > 0 ? '\nLoyalty: +${o.loyaltyPointsEarned} pts' : ''}',
                          ),
                          isThreeLine: true,
                          trailing: Text('₱${o.total.toStringAsFixed(2)}'),
                          onTap: () => _showOrderDetail(o),
                        ),
                      );
                    },
                  ),
          ),
        );
      },
    );
  }
}

// --- Manager/Supervisor Catering POS ---

class ManagerCateringShellScreen extends StatefulWidget {
  const ManagerCateringShellScreen({super.key, required this.state, this.initialTabIndex = 0});
  final AppState state;
  final int initialTabIndex;
  @override
  State<ManagerCateringShellScreen> createState() => _ManagerCateringShellScreenState();
}

class _ManagerCateringShellScreenState extends State<ManagerCateringShellScreen> with SingleTickerProviderStateMixin {
  late TabController _tab;
  static const _stages = [
    'new_event',
    'online_inquiries',
    'for_processing',
    'for_post_analysis',
    'completed',
    'cancelled',
  ];
  static const _labels = [
    'New Event',
    'Online Inquiries',
    'For Processing',
    'For Full Payment',
    'Completed',
    'Cancelled',
  ];
  @override
  void initState() {
    super.initState();
    final idx = widget.initialTabIndex.clamp(0, 5);
    _tab = TabController(length: 6, vsync: this, initialIndex: idx);
    widget.state.setManagerActiveStage(_stages[idx]);
    _tab.addListener(() {
      if (_tab.indexIsChanging) return;
      widget.state.setManagerActiveStage(_stages[_tab.index]);
      widget.state.loadManagerCateringByStage(_stages[_tab.index], force: true);
    });
    widget.state.loadManagerCateringByStage(_stages[idx], force: true);
  }

  @override
  void dispose() {
    _tab.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final who = widget.state.cashierDisplayName.trim().isNotEmpty
        ? widget.state.cashierDisplayName
        : (widget.state.userEmail ?? 'User');
    return AnimatedBuilder(
      animation: widget.state,
      builder: (context, _) {
        return Scaffold(
          appBar: AppBar(
            backgroundColor: Colors.black87,
            foregroundColor: Colors.white,
            leading: Builder(
              builder: (ctx) => IconButton(
                icon: const Icon(Icons.menu, color: AppColors.brand),
                onPressed: () => Scaffold.of(ctx).openDrawer(),
              ),
            ),
            title: Text((_labels[_tab.index]).toUpperCase()),
            bottom: TabBar(
              controller: _tab,
              isScrollable: true,
              tabs: _labels.map((lab) => Tab(text: lab)).toList(),
            ),
          ),
          drawer: Drawer(
            child: ListView(
              children: [
                DrawerHeader(
                  decoration: const BoxDecoration(color: AppColors.brand),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      Image.asset(AppBrandAssets.logo, height: 52, fit: BoxFit.contain),
                      const SizedBox(height: 10),
                      Text('Hi, $who!', style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 18)),
                    ],
                  ),
                ),
                ListTile(
                  leading: const Icon(Icons.dashboard_outlined),
                  title: const Text('Dashboard'),
                  onTap: () {
                    Navigator.pop(context);
                    Navigator.of(context).pushReplacement(
                      MaterialPageRoute<void>(builder: (_) => ManagerDashboardScreen(state: widget.state)),
                    );
                  },
                ),
                ListTile(
                  leading: const Icon(Icons.dashboard_customize_outlined),
                  title: const Text('Manage Events'),
                  onTap: () {
                    Navigator.pop(context);
                    _tab.animateTo(0);
                  },
                ),
                ListTile(
                  leading: const Icon(Icons.settings),
                  title: const Text('Settings'),
                  onTap: () {
                    Navigator.pop(context);
                    Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => SettingsScreen(state: widget.state)));
                  },
                ),
              ],
            ),
          ),
          body: TabBarView(
            controller: _tab,
            children: [
              _ManagerNewEventListTab(state: widget.state),
              _ManagerStageListTab(state: widget.state, stage: 'online_inquiries', isReadOnly: false),
              _ManagerStageListTab(state: widget.state, stage: 'for_processing', isReadOnly: false),
              _ManagerStageListTab(state: widget.state, stage: 'for_post_analysis', isReadOnly: false),
              _ManagerStageListTab(state: widget.state, stage: 'completed', isReadOnly: true),
              _ManagerStageListTab(state: widget.state, stage: 'cancelled', isReadOnly: true),
            ],
          ),
        );
      },
    );
  }
}

class _ManagerNewEventListTab extends StatelessWidget {
  const _ManagerNewEventListTab({required this.state});
  final AppState state;
  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 10, 12, 4),
          child: FilledButton.icon(
            onPressed: () {
              Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (ctx) => ManagerNewEventCreateScreen(state: state),
                ),
              );
            },
            icon: const Icon(Icons.add_circle_outline),
            label: const Text('NEW EVENT'),
          ),
        ),
        Expanded(child: _ManagerStageListTab(state: state, stage: 'new_event', isReadOnly: false)),
      ],
    );
  }
}

class ManagerNewEventCreateScreen extends StatefulWidget {
  const ManagerNewEventCreateScreen({super.key, required this.state});
  final AppState state;
  @override
  State<ManagerNewEventCreateScreen> createState() => _ManagerNewEventCreateScreenState();
}

class _ManagerNewEventCreateScreenState extends State<ManagerNewEventCreateScreen> {
  static const String _managerNewEventDraftKey = 'manager_new_event_unsaved_draft_v1';
  String inquiryType = 'CATERING';
  bool curateOwn = false;
  String selectedSetMenu = 'All Dishes';
  final selectedDishes = <String>{};
  final guestCount = TextEditingController();
  String menuSuggestionNote = '';
  String themeSuggestionNote = '';
  final eventTitle = TextEditingController();
  final eventTypeOther = TextEditingController();
  String eventTypeChoice = 'Birthday';
  final contactPerson = TextEditingController();
  final contactNumber = TextEditingController();
  final inquiryEmail = TextEditingController();
  final List<_InquiryEventWindow> _eventWindows = [_InquiryEventWindow()];
  final eventCity = TextEditingController();
  final List<String> _venueSuggestions = [];
  Timer? _venueDebounce;
  final note = TextEditingController();
  String eventSetting = 'open';
  String serviceIncluded = 'no';
  String formalityLevel = 'casual';
  bool foodTastingRequested = false;
  final foodTastingDate = TextEditingController();
  final foodTastingTime = TextEditingController();
  final laborMaleController = TextEditingController(text: '0');
  final laborFemaleController = TextEditingController(text: '0');
  final laborManualLabelController = TextEditingController();
  final laborManualAmountController = TextEditingController();
  final travelCostController = TextEditingController(text: '0');
  final themeCostController = TextEditingController(text: '0');
  final additionalCostLabelController = TextEditingController();
  final additionalCostAmountController = TextEditingController();
  final menuSearchController = TextEditingController();
  final List<Map<String, dynamic>> laborManualCosts = [];
  final List<Map<String, dynamic>> additionalCosts = [];
  final List<_InquiryEventWindow> _forProcessingWindows = [];
  bool _forProcessingWindowsLoading = false;
  bool _forProcessingWindowsLoaded = false;

  @override
  void initState() {
    super.initState();
    _restoreLocalDraft();
    for (final c in [
      guestCount,
      eventTitle,
      eventTypeOther,
      contactPerson,
      contactNumber,
      inquiryEmail,
      eventCity,
      note,
      foodTastingDate,
      foodTastingTime,
      themeCostController,
      menuSearchController,
    ]) {
      c.addListener(_saveLocalDraftDebounced);
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _loadForProcessingWindowsIfNeeded();
    });
    eventCity.addListener(_onVenueChanged);
  }

  @override
  void dispose() {
    guestCount.dispose();
    _venueDebounce?.cancel();
    eventCity.removeListener(_onVenueChanged);
    eventTitle.dispose();
    eventTypeOther.dispose();
    contactPerson.dispose();
    contactNumber.dispose();
    inquiryEmail.dispose();
    eventCity.dispose();
    note.dispose();
    foodTastingDate.dispose();
    foodTastingTime.dispose();
    laborMaleController.dispose();
    laborFemaleController.dispose();
    laborManualLabelController.dispose();
    laborManualAmountController.dispose();
    travelCostController.dispose();
    themeCostController.dispose();
    additionalCostLabelController.dispose();
    additionalCostAmountController.dispose();
    menuSearchController.dispose();
    _saveLocalDraftNow();
    super.dispose();
  }

  Timer? _localDraftDebounce;
  void _saveLocalDraftDebounced() {
    _localDraftDebounce?.cancel();
    _localDraftDebounce = Timer(const Duration(milliseconds: 300), _saveLocalDraftNow);
  }

  Future<void> _saveLocalDraftNow() async {
    try {
      final p = await SharedPreferences.getInstance();
      final payload = <String, dynamic>{
        'inquiryType': inquiryType,
        'eventTitle': eventTitle.text.trim(),
        'eventTypeChoice': eventTypeChoice,
        'eventTypeOther': eventTypeOther.text.trim(),
        'contactPerson': contactPerson.text.trim(),
        'contactNumber': contactNumber.text.trim(),
        'inquiryEmail': inquiryEmail.text.trim(),
        'eventCity': eventCity.text.trim(),
        'note': note.text.trim(),
        'guestCount': guestCount.text.trim(),
        'eventSetting': eventSetting,
        'serviceIncluded': serviceIncluded,
        'formalityLevel': formalityLevel,
        'foodTastingRequested': foodTastingRequested,
        'foodTastingDate': foodTastingDate.text.trim(),
        'foodTastingTime': foodTastingTime.text.trim(),
        'selectedDishes': selectedDishes.toList(),
      };
      await p.setString(_managerNewEventDraftKey, jsonEncode(payload));
    } catch (_) {}
  }

  Future<void> _restoreLocalDraft() async {
    try {
      final p = await SharedPreferences.getInstance();
      final raw = p.getString(_managerNewEventDraftKey);
      if (raw == null || raw.trim().isEmpty) return;
      final m = jsonDecode(raw);
      if (m is! Map) return;
      inquiryType = '${m['inquiryType'] ?? inquiryType}';
      eventTitle.text = '${m['eventTitle'] ?? ''}';
      eventTypeChoice = '${m['eventTypeChoice'] ?? eventTypeChoice}';
      eventTypeOther.text = '${m['eventTypeOther'] ?? ''}';
      contactPerson.text = '${m['contactPerson'] ?? ''}';
      contactNumber.text = '${m['contactNumber'] ?? ''}';
      inquiryEmail.text = '${m['inquiryEmail'] ?? ''}';
      eventCity.text = '${m['eventCity'] ?? ''}';
      note.text = '${m['note'] ?? ''}';
      guestCount.text = '${m['guestCount'] ?? ''}';
      eventSetting = '${m['eventSetting'] ?? eventSetting}';
      serviceIncluded = '${m['serviceIncluded'] ?? serviceIncluded}';
      formalityLevel = '${m['formalityLevel'] ?? formalityLevel}';
      foodTastingRequested = m['foodTastingRequested'] == true;
      foodTastingDate.text = '${m['foodTastingDate'] ?? ''}';
      foodTastingTime.text = '${m['foodTastingTime'] ?? ''}';
      final dishes = m['selectedDishes'];
      if (dishes is List) {
        selectedDishes
          ..clear()
          ..addAll(dishes.map((e) => '$e'));
      }
    } catch (_) {}
  }

  int _minPaxForCurrentInquiry() =>
      inquiryType == 'CATERING AND EVENT' ? kMinCateringEventPax : kMinCateringOnlyPax;

  int _billableGuestCountForPricing() {
    final raw = guestCount.text.trim();
    if (raw.isEmpty) return 0;
    final g = int.tryParse(raw) ?? 0;
    if (g <= 0) return 0;
    final min = _minPaxForCurrentInquiry();
    return g < min ? min : g;
  }

  int _guestCountForSubmit() {
    final raw = guestCount.text.trim();
    final min = _minPaxForCurrentInquiry();
    if (raw.isEmpty) return min;
    final g = int.tryParse(raw) ?? 0;
    if (g <= 0) return min;
    return g < min ? min : g;
  }

  Future<void> _pickWindowDate(int index) async {
    final ctx = context;
    final w = _eventWindows[index];
    final base = w.date ?? DateTime.now();
    final d = await showDatePicker(
      context: ctx,
      initialDate: base,
      firstDate: DateTime.now().subtract(const Duration(days: 1)),
      lastDate: DateTime.now().add(const Duration(days: 365 * 3)),
    );
    if (!ctx.mounted || d == null) return;
    setState(() => _eventWindows[index].date = DateTime(d.year, d.month, d.day));
  }

  Future<void> _pickWindowFrom(int index) async {
    final ctx = context;
    final w = _eventWindows[index];
    final t = await showTimePicker(
      context: ctx,
      initialTime: w.from ?? const TimeOfDay(hour: 12, minute: 0),
    );
    if (!ctx.mounted || t == null) return;
    setState(() => _eventWindows[index].from = t);
  }

  Future<void> _pickWindowTo(int index) async {
    final ctx = context;
    final w = _eventWindows[index];
    final t = await showTimePicker(
      context: ctx,
      initialTime: w.to ?? const TimeOfDay(hour: 14, minute: 0),
    );
    if (!ctx.mounted || t == null) return;
    setState(() => _eventWindows[index].to = t);
  }

  double _sumCostRows(List<Map<String, dynamic>> rows) {
    double sum = 0;
    for (final e in rows) {
      sum += jsonToDouble(e['amount']);
    }
    return sum;
  }

  double _laborCostComputed() {
    final male = int.tryParse(laborMaleController.text.trim()) ?? 0;
    final female = int.tryParse(laborFemaleController.text.trim()) ?? 0;
    final maleCost = male < 0 ? 0 : male * 1000;
    final femaleCost = female < 0 ? 0 : female * 500;
    return maleCost + femaleCost + _sumCostRows(laborManualCosts);
  }

  double _travelCostComputed() => double.tryParse(travelCostController.text.trim()) ?? 0;

  double _themeCostComputed() => double.tryParse(themeCostController.text.trim()) ?? 0;

  double _estimatedCost() =>
      (_billableGuestCountForPricing() * kPesosPerPax) +
      _laborCostComputed() +
      _travelCostComputed() +
      _themeCostComputed() +
      _sumCostRows(additionalCosts);

  String _resolvedEventType() {
    if (eventTypeChoice != 'Other') return eventTypeChoice;
    return eventTypeOther.text.trim();
  }

  List<Map<String, String>> _scheduleSlotsPayload() {
    final out = <Map<String, String>>[];
    for (final w in _eventWindows) {
      if (w.date == null || w.from == null || w.to == null) continue;
      final d = w.date!;
      final dateStr = '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
      final f = '${w.from!.hour.toString().padLeft(2, '0')}:${w.from!.minute.toString().padLeft(2, '0')}';
      final t = '${w.to!.hour.toString().padLeft(2, '0')}:${w.to!.minute.toString().padLeft(2, '0')}';
      out.add({'date': dateStr, 'from': f, 'to': t, 'label': '$dateStr from $f to $t'});
    }
    return out;
  }

  DateTime? _tryParseScheduleDate(dynamic v) {
    final s = v == null ? '' : v.toString().trim();
    if (s.isEmpty) return null;
    try {
      return DateTime.parse(s);
    } catch (_) {
      return null;
    }
  }

  TimeOfDay? _tryParseScheduleTime(dynamic v) {
    final s = v == null ? '' : v.toString().trim();
    if (s.isEmpty) return null;
    final m = RegExp(r'^(\d{1,2}):(\d{2})').firstMatch(s);
    if (m == null) return null;
    final hh = int.tryParse(m.group(1) ?? '');
    final mm = int.tryParse(m.group(2) ?? '');
    if (hh == null || mm == null) return null;
    if (hh < 0 || hh > 23 || mm < 0 || mm > 59) return null;
    return TimeOfDay(hour: hh, minute: mm);
  }

  List<_InquiryEventWindow> _windowsFromScheduleSlots(dynamic raw) {
    final out = <_InquiryEventWindow>[];
    dynamic listLike = raw;
    if (raw is Map) listLike = [raw];
    if (raw is String) {
      final t = raw.trim();
      if (t.startsWith('[') || t.startsWith('{')) {
        try {
          listLike = jsonDecode(t);
        } catch (_) {}
      }
    }
    if (listLike is List) {
      for (final s in listLike) {
        if (s is Map) {
          final date = _tryParseScheduleDate(s['date'] ?? s['label']);
          final from = _tryParseScheduleTime(s['from']);
          final to = _tryParseScheduleTime(s['to']);
          if (date != null && from != null && to != null) {
            out.add(_InquiryEventWindow()..date = date..from = from..to = to);
          }
        }
      }
    }
    return out;
  }

  bool _windowsOverlapOnSameDate(_InquiryEventWindow a, _InquiryEventWindow b) {
    if (a.date == null || a.from == null || a.to == null) return false;
    if (b.date == null || b.from == null || b.to == null) return false;
    if (a.date!.year != b.date!.year || a.date!.month != b.date!.month || a.date!.day != b.date!.day) return false;
    final aStart = a.from!.hour * 60 + a.from!.minute;
    final aEnd = a.to!.hour * 60 + a.to!.minute;
    final bStart = b.from!.hour * 60 + b.from!.minute;
    final bEnd = b.to!.hour * 60 + b.to!.minute;
    return aStart < bEnd && aEnd > bStart;
  }

  int _conflictCountWithForProcessing() {
    if (!_forProcessingWindowsLoaded) return 0;
    final processingWindows = _forProcessingWindows;
    var conflicts = 0;
    for (final w in _eventWindows) {
      for (final pw in processingWindows) {
        if (_windowsOverlapOnSameDate(w, pw)) conflicts++;
      }
    }
    return conflicts;
  }

  Future<void> _loadForProcessingWindowsIfNeeded() async {
    if (_forProcessingWindowsLoading || _forProcessingWindowsLoaded) return;
    final email = widget.state.userEmail;
    if (email == null || widget.state.loginPassword.isEmpty) return;

    setState(() => _forProcessingWindowsLoading = true);
    try {
      final listUri = Uri.parse('${normalizeApiBase(widget.state.apiBase)}/api/mobile/pos/catering/list');
      final res = await http
          .post(
            listUri,
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({
              'cashier_email': email,
              'cashier_password': widget.state.loginPassword,
              'stage': 'for_processing',
              'summary': true,
            }),
          )
          .timeout(_managerCateringListTimeout);
      if (res.statusCode != 200) return;
      final body = jsonDecode(res.body);
      if (body is! List) return;

      final windows = <_InquiryEventWindow>[];
      for (final e in body) {
        if (e is Map) {
          windows.addAll(_windowsFromScheduleSlots(e['schedule_slots']));
        }
      }

      if (!mounted) return;
      setState(() {
        _forProcessingWindows
          ..clear()
          ..addAll(windows);
        _forProcessingWindowsLoaded = true;
        _forProcessingWindowsLoading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _forProcessingWindowsLoaded = false;
        _forProcessingWindowsLoading = false;
      });
    }
  }

  String? _validateManagerNewEvent() {
    if (contactPerson.text.trim().isEmpty) return 'Enter contact person.';
    if (contactNumber.text.trim().isEmpty) return 'Enter contact number.';
    if (inquiryEmail.text.trim().isEmpty) return 'Enter email address.';
    if (eventCity.text.trim().isEmpty) return 'Enter event venue.';
    for (final w in _eventWindows) {
      final any = w.date != null || w.from != null || w.to != null;
      final all = w.date != null && w.from != null && w.to != null;
      if (any && !all) return 'Complete event date, start time, and end time for each row (or remove extra rows).';
    }
    final completeWindows = _eventWindows.where((w) => w.date != null && w.from != null && w.to != null).toList();
    if (completeWindows.isEmpty) return 'Set at least one event day with start and end time.';
    for (final w in completeWindows) {
      final sm = w.from!.hour * 60 + w.from!.minute;
      final em = w.to!.hour * 60 + w.to!.minute;
      if (em <= sm) return 'End time must be after start time for each event.';
    }
    if (selectedDishes.isEmpty) return 'Select at least one dish for the menu.';
    if (inquiryType == 'CATERING AND EVENT' && eventTitle.text.trim().isEmpty) return 'Enter event title.';
    if (eventTypeChoice == 'Other' && eventTypeOther.text.trim().isEmpty) {
      return 'Describe the event type for Other.';
    }
    if (foodTastingRequested &&
        (foodTastingDate.text.trim().isEmpty || foodTastingTime.text.trim().isEmpty)) {
      return 'Enter date and time for food tasting.';
    }
    final rawGuests = guestCount.text.trim();
    if (rawGuests.isEmpty) return 'Enter number of guests.';
    final gNum = int.tryParse(rawGuests);
    if (gNum == null || gNum < 1) return 'Enter a valid number of guests.';
    final min = _minPaxForCurrentInquiry();
    if (gNum < min) return 'Minimum guests for this inquiry type is $min.';
    return null;
  }

  Widget _buildEventTypePicker() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        DropdownButtonFormField<String>(
          value: kMobileEventTypeChoices.contains(eventTypeChoice) ? eventTypeChoice : 'Other',
          decoration: const InputDecoration(labelText: 'Event type'),
          items: kMobileEventTypeChoices.map((e) => DropdownMenuItem(value: e, child: Text(e))).toList(),
          onChanged: (v) => setState(() => eventTypeChoice = v ?? 'Other'),
        ),
        if (eventTypeChoice == 'Other') ...[
          const SizedBox(height: 8),
          TextField(
            controller: eventTypeOther,
            decoration: const InputDecoration(labelText: 'Describe event type'),
            onChanged: (_) => setState(() {}),
          ),
        ],
      ],
    );
  }

  void _onVenueChanged() {
    _venueDebounce?.cancel();
    final q = eventCity.text.trim();
    if (q.length < 3) {
      if (_venueSuggestions.isNotEmpty && mounted) setState(() => _venueSuggestions.clear());
      return;
    }
    _venueDebounce = Timer(const Duration(milliseconds: 300), () async {
      try {
        final uri = Uri.parse(
          'https://nominatim.openstreetmap.org/search?q=${Uri.encodeComponent(q)}&format=json&limit=5',
        );
        final res = await http.get(uri, headers: {'User-Agent': kNominatimUserAgent}).timeout(_apiTimeout);
        if (res.statusCode != 200 || !mounted) return;
        final body = jsonDecode(res.body);
        if (body is! List) return;
        final next = body
            .whereType<Map>()
            .map((e) => '${e['display_name'] ?? ''}'.trim())
            .where((s) => s.isNotEmpty)
            .take(5)
            .toList();
        if (mounted) setState(() {
          _venueSuggestions
            ..clear()
            ..addAll(next);
        });
      } catch (_) {}
    });
  }

  Future<void> _pickVenueOnMap() async {
    final res = await Navigator.of(context).push<MapPinResult>(
      MaterialPageRoute(
        builder: (_) => _MapPinPickerDialog(initialSearchQuery: eventCity.text.trim()),
      ),
    );
    if (res == null || !mounted) return;
    setState(() {
      eventCity.text = res.address.trim();
      _venueSuggestions.clear();
    });
  }

  @override
  Widget build(BuildContext context) {
    final state = widget.state;
    final cateringMenu = state.menu.where((m) => m.isCateringDish).toList();
    final setMenuNames = ['All Dishes', ...state.setMenus.map((m) => m.name)];
    final effectiveSetMenu = setMenuNames.contains(selectedSetMenu) ? selectedSetMenu : 'All Dishes';
    final q = menuSearchController.text.trim().toLowerCase();
    final availableDishes = cateringMenu
        .map((m) => m.name.trim())
        .where((n) => n.isNotEmpty)
        .toSet()
        .where((n) => q.isEmpty || n.toLowerCase().contains(q))
        .toList();
    final estimate = _estimatedCost();
    final scheduleConflictsForProcessing = _conflictCountWithForProcessing();
    final orderKind = inquiryType == 'CATERING' ? 'catering' : 'event';

    Future<void> createNewEvent() async {
      final v = _validateManagerNewEvent();
      if (v != null) {
        appSnack(context, v);
        return;
      }
      final est = _estimatedCost();
      final guestsSaved = _guestCountForSubmit();
      final menuPayload = selectedDishes.toList();
      final themeDesign = <String, dynamic>{
        'note': note.text.trim(),
        'event_setting': eventSetting,
        'service_included': serviceIncluded,
        'food_tasting_requested': foodTastingRequested,
        'food_tasting_date': foodTastingDate.text.trim(),
        'food_tasting_time': foodTastingTime.text.trim(),
        'theme_cost': _themeCostComputed(),
        'additional_costs': additionalCosts,
        'labor_manual_costs': laborManualCosts,
        if (inquiryType == 'CATERING AND EVENT') 'theme_suggestion_note': themeSuggestionNote,
      };
      final costBreakdown = <Map<String, dynamic>>[
        {'label': 'Base food cost', 'amount': _billableGuestCountForPricing() * kPesosPerPax},
        {'label': 'Labor cost', 'amount': _laborCostComputed()},
        {'label': 'Travel cost', 'amount': _travelCostComputed()},
        {'label': 'Theme design cost', 'amount': _themeCostComputed()},
        {'label': 'Additional costs', 'amount': _sumCostRows(additionalCosts)},
      ];
      final yes = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Create new event?'),
          content: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text('Type: $inquiryType'),
                if (inquiryType == 'CATERING AND EVENT' && eventTitle.text.trim().isNotEmpty) ...[
                  const SizedBox(height: 6),
                  Text('Event: ${eventTitle.text.trim()}'),
                ],
                const SizedBox(height: 6),
                Text('Event type: ${_resolvedEventType()}'),
                const SizedBox(height: 6),
                Text('Guests: ${guestCount.text.trim()}'),
                const SizedBox(height: 6),
                Text('Venue: ${eventCity.text.trim()}'),
                const SizedBox(height: 6),
                Text('Estimated: ₱${est.toStringAsFixed(2)}'),
              ],
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
            FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Confirm')),
          ],
        ),
      );
      if (yes != true || !context.mounted) return;
      final err = await widget.state.managerCreateNewEvent(
        orderKind: orderKind,
        eventTitle: inquiryType == 'CATERING AND EVENT' ? eventTitle.text.trim() : '',
        eventType: (inquiryType == 'CATERING' || inquiryType == 'CATERING AND EVENT') ? _resolvedEventType() : '',
        customerName: contactPerson.text.trim(),
        contactPerson: contactPerson.text.trim(),
        contactNumber: contactNumber.text.trim(),
        emailAddress: inquiryEmail.text.trim(),
        address: eventCity.text.trim(),
        guestCount: guestsSaved,
        paymentMethod: 'cash',
        costBreakdown: costBreakdown,
        laborMaleCount: int.tryParse(laborMaleController.text.trim()) ?? 0,
        laborFemaleCount: int.tryParse(laborFemaleController.text.trim()) ?? 0,
        laborManualException: _sumCostRows(laborManualCosts),
        travelCost: _travelCostComputed(),
        manualTotalCost: null,
        scheduleSlots: _scheduleSlotsPayload(),
        menu: menuPayload,
        themeDesign: themeDesign,
        formalityLevel: inquiryType == 'CATERING AND EVENT' ? formalityLevel : '',
      );
      if (!context.mounted) return;
      if (err != null) {
        appSnack(context, err);
        return;
      }
      appSnack(context, 'New event created');
      try {
        final p = await SharedPreferences.getInstance();
        await p.remove(_managerNewEventDraftKey);
      } catch (_) {}
      await widget.state.loadManagerCateringByStage('new_event', force: true);
      if (context.mounted) Navigator.of(context).pop();
    }

    Future<void> generateOrderSummaryPdfForDraft() async {
      final v = _validateManagerNewEvent();
      if (v != null) {
        appSnack(context, v);
        return;
      }
      final doc = pw.Document();
      final labelBg = pdf.PdfColor.fromInt(0xFFCFCFCF);
      final eventWhen = _scheduleSlotsPayload().map((e) => e['label'] ?? '').where((e) => e.trim().isNotEmpty).join(' ; ');
      final menuLines = selectedDishes.toList()..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
      final guestCountValue = _guestCountForSubmit();
      final baseFoodCost = _billableGuestCountForPricing() * kPesosPerPax;
      final laborCost = _laborCostComputed();
      final travelCost = _travelCostComputed();
      final themeCost = _themeCostComputed();
      final additionalCostTotal = _sumCostRows(additionalCosts);
      final total = _estimatedCost();
      final downPaymentDue = total * 0.5;
      final totalDueNow = total - downPaymentDue;
      final settingLabel = eventSetting == 'closed' ? 'Closed space' : 'Open space';
      final cateringType = inquiryType == 'CATERING' ? 'Catering' : 'Catering and Event';

      pw.Widget labelValueRow(String k, String v) => pw.Padding(
            padding: const pw.EdgeInsets.only(bottom: 5),
            child: pw.Row(
              crossAxisAlignment: pw.CrossAxisAlignment.start,
              children: [
                pw.Expanded(
                  flex: 2,
                  child: pw.Container(
                    color: labelBg,
                    padding: const pw.EdgeInsets.symmetric(horizontal: 6, vertical: 5),
                    child: pw.Text(k, style: pw.TextStyle(fontWeight: pw.FontWeight.bold, fontSize: 10)),
                  ),
                ),
                pw.SizedBox(width: 6),
                pw.Expanded(
                  flex: 3,
                  child: pw.Padding(
                    padding: const pw.EdgeInsets.symmetric(vertical: 5),
                    child: pw.Text(v.isEmpty ? '—' : v, style: const pw.TextStyle(fontSize: 10)),
                  ),
                ),
              ],
            ),
          );

      doc.addPage(
        pw.MultiPage(
          build: (ctx) => [
            pw.Text('Order Summary', style: pw.TextStyle(fontSize: 18, fontWeight: pw.FontWeight.bold)),
            pw.Text('Macrina\'s Kitchen and Catering', style: pw.TextStyle(fontSize: 10, color: pdf.PdfColors.grey700)),
            pw.SizedBox(height: 12),
            labelValueRow('Transaction No.', '—'),
            labelValueRow('Date/Time processed', formatDateTimeLocal(DateTime.now())),
            labelValueRow(
              'Event',
              inquiryType == 'CATERING AND EVENT' ? eventTitle.text.trim() : contactPerson.text.trim(),
            ),
            labelValueRow('Date/Time of Event', eventWhen.isEmpty ? '—' : eventWhen),
            labelValueRow('Customer', contactPerson.text.trim()),
            labelValueRow('Contact person', contactPerson.text.trim()),
            labelValueRow('Contact number', contactNumber.text.trim()),
            labelValueRow('Email address', inquiryEmail.text.trim()),
            labelValueRow('Catering type', cateringType),
            labelValueRow('Event type', _resolvedEventType()),
            labelValueRow('Address of event', eventCity.text.trim()),
            labelValueRow('Service', serviceIncluded == 'yes' ? 'With service' : 'Without service'),
            labelValueRow('Event setting', settingLabel),
            labelValueRow('Formality level', inquiryType == 'CATERING AND EVENT' ? formalityLevel : '—'),
            labelValueRow('Menu dishes', menuLines.isEmpty ? '—' : menuLines.join(', ')),
            labelValueRow(
              'No. of PAX and cost',
              '$guestCountValue x PHP ${kPesosPerPax.toStringAsFixed(0)} | PHP ${baseFoodCost.toStringAsFixed(2)}',
            ),
            labelValueRow('Event theme design cost', 'PHP ${themeCost.toStringAsFixed(2)}'),
            labelValueRow('Labor cost', 'PHP ${laborCost.toStringAsFixed(2)}'),
            labelValueRow('Travel cost', 'PHP ${travelCost.toStringAsFixed(2)}'),
            labelValueRow(
              'Additional costs',
              additionalCosts.isEmpty
                  ? '—'
                  : additionalCosts
                      .map((e) {
                        final lb = '${e['label'] ?? ''}'.trim();
                        final am = jsonToDouble(e['amount']);
                        if (lb.isEmpty && am <= 0) return '';
                        return '${lb.isEmpty ? 'Item' : lb}: PHP ${am.toStringAsFixed(2)}';
                      })
                      .where((x) => x.isNotEmpty)
                      .join(' · '),
            ),
            labelValueRow('Additional costs (total)', 'PHP ${additionalCostTotal.toStringAsFixed(2)}'),
            labelValueRow('Total invoice', 'PHP ${total.toStringAsFixed(2)}'),
            labelValueRow('Down payment (50%)', 'PHP ${downPaymentDue.toStringAsFixed(2)}'),
            labelValueRow('Total amount due (after down payment)', 'PHP ${totalDueNow.toStringAsFixed(2)}'),
            labelValueRow('Note', note.text.trim().isEmpty ? '—' : note.text.trim()),
          ],
        ),
      );
      await Printing.layoutPdf(onLayout: (_) async => doc.save());
    }

    return Scaffold(
      appBar: AppBar(title: const Text('NEW EVENT')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(12, 12, 12, 220),
        children: [
        Text(
          'Catering only: minimum $kMinCateringOnlyPax guests. Catering + Event: minimum $kMinCateringEventPax guests. Estimated cost uses ₱${kPesosPerPax.toStringAsFixed(0)} × billable guests.',
          style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 10),
        ToggleSection(
          title: 'Event Information',
          expanded: true,
          onToggle: () {},
          hideToggleIcon: true,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              DropdownButtonFormField<String>(
                value: inquiryType,
                decoration: const InputDecoration(
                  labelText: 'Inquiry type',
                  helperText: 'Same as Online Inquiries — Catering Only vs Catering + Event.',
                ),
                items: const [
                  DropdownMenuItem(value: 'CATERING', child: Text('CATERING')),
                  DropdownMenuItem(value: 'CATERING AND EVENT', child: Text('CATERING AND EVENT')),
                ],
                onChanged: (v) => setState(() => inquiryType = v ?? 'CATERING'),
              ),
              const SizedBox(height: 8),
              _buildEventTypePicker(),
              const SizedBox(height: 8),
              if (inquiryType == 'CATERING AND EVENT') ...[
                Text('Formality level', style: Theme.of(context).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700)),
                const SizedBox(height: 6),
                SegmentedButton<String>(
                  segments: const [
                    ButtonSegment(value: 'casual', label: Text('Casual')),
                    ButtonSegment(value: 'semiformal', label: Text('Semiformal')),
                    ButtonSegment(value: 'formal', label: Text('Formal')),
                  ],
                  selected: {formalityLevel},
                  onSelectionChanged: (s) => setState(() => formalityLevel = s.first),
                ),
                const SizedBox(height: 12),
              ],
              const Text('Event setting', style: TextStyle(fontWeight: FontWeight.w600)),
              const SizedBox(height: 6),
              Row(
                children: [
                  Expanded(
                    child: RadioListTile<String>(
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      title: const Text('Open space'),
                      value: 'open',
                      groupValue: eventSetting,
                      onChanged: (v) => setState(() => eventSetting = v ?? 'open'),
                    ),
                  ),
                  Expanded(
                    child: RadioListTile<String>(
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      title: const Text('Closed space'),
                      value: 'closed',
                      groupValue: eventSetting,
                      onChanged: (v) => setState(() => eventSetting = v ?? 'closed'),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              TextField(controller: eventTitle, decoration: const InputDecoration(labelText: 'Event title')),
              const SizedBox(height: 8),
              TextField(controller: contactPerson, decoration: const InputDecoration(labelText: 'Contact person')),
              const SizedBox(height: 8),
              TextField(controller: contactNumber, decoration: const InputDecoration(labelText: 'Contact number')),
              const SizedBox(height: 8),
              TextField(controller: inquiryEmail, decoration: const InputDecoration(labelText: 'Email address')),
              const SizedBox(height: 8),
              TextField(
                controller: eventCity,
                decoration: InputDecoration(
                  labelText: 'Event venue',
                  suffixIcon: IconButton(
                    tooltip: 'Pin on map',
                    onPressed: _pickVenueOnMap,
                    icon: const Icon(Icons.place_outlined),
                  ),
                ),
              ),
              if (_venueSuggestions.isNotEmpty)
                Container(
                  margin: const EdgeInsets.only(top: 6),
                  decoration: BoxDecoration(
                    border: Border.all(color: Colors.grey.shade300),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Column(
                    children: _venueSuggestions
                        .map(
                          (s) => ListTile(
                            dense: true,
                            title: Text(s, maxLines: 2, overflow: TextOverflow.ellipsis),
                            onTap: () => setState(() {
                              eventCity.text = s;
                              _venueSuggestions.clear();
                            }),
                          ),
                        )
                        .toList(),
                  ),
                ),
              const SizedBox(height: 8),
              const Text('Date & time of event', style: TextStyle(fontWeight: FontWeight.w600)),
              const SizedBox(height: 6),
              ...List.generate(_eventWindows.length, (index) {
                final w = _eventWindows[index];
                final dateLabel = w.date == null
                    ? 'Pick date'
                    : '${w.date!.month}/${w.date!.day}/${w.date!.year}';
                return Padding(
                  padding: const EdgeInsets.only(bottom: 10),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: OutlinedButton(
                              onPressed: () => _pickWindowDate(index),
                              child: Text(dateLabel, overflow: TextOverflow.ellipsis),
                            ),
                          ),
                          if (_eventWindows.length > 1)
                            IconButton(
                              tooltip: 'Remove window',
                              icon: const Icon(Icons.remove_circle_outline, color: AppColors.accent),
                              onPressed: () => setState(() {
                                if (_eventWindows.length > 1) _eventWindows.removeAt(index);
                              }),
                            ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      Row(
                        children: [
                          Expanded(
                            child: OutlinedButton(
                              onPressed: () => _pickWindowFrom(index),
                              child: Text(w.from == null ? 'From' : w.from!.format(context)),
                            ),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: OutlinedButton(
                              onPressed: () => _pickWindowTo(index),
                              child: Text(w.to == null ? 'To' : w.to!.format(context)),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                );
              }),
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  onPressed: () => setState(() => _eventWindows.add(_InquiryEventWindow())),
                  icon: const Icon(Icons.add),
                  label: const Text('Add another window'),
                ),
              ),
              if (scheduleConflictsForProcessing > 0)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Text(
                    'Schedule overlaps another order already in For Processing — adjust date/time or confirm capacity.',
                    style: TextStyle(color: Colors.red.shade700, fontWeight: FontWeight.w700),
                  ),
                ),
              const SizedBox(height: 8),
              TextField(
                controller: guestCount,
                decoration: const InputDecoration(labelText: 'Number of guests'),
                keyboardType: TextInputType.number,
                onChanged: (_) => setState(() {}),
              ),
              const SizedBox(height: 8),
              TextField(controller: note, decoration: const InputDecoration(labelText: 'Note'), maxLines: 3),
              const SizedBox(height: 8),
              Text('Service', style: Theme.of(context).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700)),
              Row(
                children: [
                  Expanded(
                    child: RadioListTile<String>(
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      title: const Text('With service'),
                      value: 'yes',
                      groupValue: serviceIncluded,
                      onChanged: (v) => setState(() => serviceIncluded = v ?? 'yes'),
                    ),
                  ),
                  Expanded(
                    child: RadioListTile<String>(
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      title: const Text('Without service'),
                      value: 'no',
                      groupValue: serviceIncluded,
                      onChanged: (v) => setState(() => serviceIncluded = v ?? 'no'),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
        const SizedBox(height: 10),
        ToggleSection(
          title: 'Menu',
          expanded: true,
          onToggle: () {},
          hideToggleIcon: true,
          child: Column(
            children: [
              const Text('Build or modify menu by selecting dishes below.'),
              const SizedBox(height: 8),
              CheckboxListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                title: const Text('With food tasting'),
                value: foodTastingRequested,
                onChanged: (v) => setState(() => foodTastingRequested = v ?? false),
              ),
              if (foodTastingRequested) ...[
                const SizedBox(height: 8),
                const Align(
                  alignment: Alignment.centerLeft,
                  child: Text('Food Tasting Schedule', style: TextStyle(fontWeight: FontWeight.w700)),
                ),
                const SizedBox(height: 6),
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: foodTastingDate,
                        readOnly: true,
                        decoration: const InputDecoration(hintText: 'date'),
                        onTap: () async {
                          final d = await showDatePicker(
                            context: context,
                            initialDate: DateTime.now(),
                            firstDate: DateTime.now().subtract(const Duration(days: 1)),
                            lastDate: DateTime.now().add(const Duration(days: 365 * 2)),
                          );
                          if (d == null) return;
                          setState(() {
                            foodTastingDate.text =
                                '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
                          });
                        },
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: TextField(
                        controller: foodTastingTime,
                        readOnly: true,
                        decoration: const InputDecoration(hintText: 'time'),
                        onTap: () async {
                          final t = await showTimePicker(context: context, initialTime: const TimeOfDay(hour: 13, minute: 0));
                          if (t == null) return;
                          setState(() {
                            foodTastingTime.text =
                                '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';
                          });
                        },
                      ),
                    ),
                  ],
                ),
              ],
              const SizedBox(height: 10),
              TextField(
                controller: menuSearchController,
                decoration: const InputDecoration(
                  labelText: 'Search dishes',
                  prefixIcon: Icon(Icons.search),
                ),
                onChanged: (_) => setState(() {}),
              ),
              const SizedBox(height: 8),
              DropdownButtonFormField<String>(
                value: effectiveSetMenu,
                items: setMenuNames.map((name) => DropdownMenuItem(value: name, child: Text(name))).toList(),
                onChanged: (v) {
                  final next = v ?? 'All Dishes';
                  setState(() {
                    selectedSetMenu = next;
                    selectedDishes.clear();
                    if (next != 'All Dishes') {
                      final rows = state.setMenus.where((m) => m.name == next).toList();
                      if (rows.isNotEmpty) selectedDishes.addAll(rows.first.dishes);
                    }
                  });
                },
              ),
              const SizedBox(height: 8),
              SizedBox(
                height: math.min(420, MediaQuery.sizeOf(context).height * 0.42),
                child: ListView(
                  padding: EdgeInsets.zero,
                  children: [
                    ...(() {
                      final dishes = availableDishes.toList()
                        ..sort((a, b) {
                          final aSel = selectedDishes.contains(a) ? 0 : 1;
                          final bSel = selectedDishes.contains(b) ? 0 : 1;
                          if (aSel != bSel) return aSel - bSel;
                          return a.toLowerCase().compareTo(b.toLowerCase());
                        });
                      return dishes;
                    }()).map((dishName) {
                      MenuItemData? dish;
                      for (final c in cateringMenu) {
                        if (c.name == dishName) {
                          dish = c;
                          break;
                        }
                      }
                      final sel = selectedDishes.contains(dishName);
                      return Padding(
                        padding: const EdgeInsets.only(bottom: 6),
                        child: Material(
                          color: sel ? AppColors.brand.withValues(alpha: 0.35) : Colors.grey.shade100,
                          borderRadius: BorderRadius.circular(10),
                          child: InkWell(
                            borderRadius: BorderRadius.circular(10),
                            onTap: () => setState(() {
                              if (sel) {
                                selectedDishes.remove(dishName);
                              } else {
                                selectedDishes.add(dishName);
                              }
                            }),
                            child: Padding(
                              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                              child: Row(
                                children: [
                                  ClipRRect(
                                    borderRadius: BorderRadius.circular(6),
                                    child: SizedBox(
                                      width: 40,
                                      height: 40,
                                      child: dish != null ? _MenuThumb(item: dish, compact: true) : const Icon(Icons.fastfood, size: 22),
                                    ),
                                  ),
                                  const SizedBox(width: 10),
                                  Expanded(child: Text(dishName, style: const TextStyle(fontSize: 13))),
                                  Icon(
                                    sel ? Icons.check_circle : Icons.circle_outlined,
                                    size: 22,
                                    color: sel ? AppColors.success : Colors.grey.shade500,
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                      );
                    }),
                  ],
                ),
              ),
            ],
          ),
        ),
        if (inquiryType == 'CATERING AND EVENT') ...[
          const SizedBox(height: 10),
          ToggleSection(
            title: 'Event Theme Design',
            expanded: true,
            onToggle: () {},
            hideToggleIcon: true,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const SizedBox(height: 8),
                Text(
                  'Customize event design in web only. Mobile manager view is notes-only.',
                  style: TextStyle(color: Colors.blueGrey.shade700, fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: note,
                  maxLines: 4,
                  decoration: const InputDecoration(labelText: 'Theme design notes'),
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: themeCostController,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(
                    labelText: 'Theme design cost (estimate)',
                    helperText: 'Included in estimated total — matches Online Inquiries + manager costing.',
                  ),
                  onChanged: (_) => setState(() {}),
                ),
              ],
            ),
          ),
        ],
        const SizedBox(height: 10),
        ToggleSection(
          title: 'Labor costing & travel',
          expanded: true,
          onToggle: () {},
          hideToggleIcon: true,
          child: Column(
            children: [
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: laborMaleController,
                      keyboardType: TextInputType.number,
                      decoration: const InputDecoration(labelText: 'Male workers (₱1000 each)'),
                      onChanged: (_) => setState(() {}),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: TextField(
                      controller: laborFemaleController,
                      keyboardType: TextInputType.number,
                      decoration: const InputDecoration(labelText: 'Female workers (₱500 each)'),
                      onChanged: (_) => setState(() {}),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: laborManualLabelController,
                      decoration: const InputDecoration(labelText: 'Labor item'),
                    ),
                  ),
                  const SizedBox(width: 8),
                  SizedBox(
                    width: 120,
                    child: TextField(
                      controller: laborManualAmountController,
                      keyboardType: TextInputType.number,
                      decoration: const InputDecoration(labelText: 'Cost'),
                    ),
                  ),
                  IconButton(
                    onPressed: () {
                      final l = laborManualLabelController.text.trim();
                      final a = double.tryParse(laborManualAmountController.text.trim());
                      if (l.isEmpty || a == null) return;
                      setState(() {
                        laborManualCosts.add({'label': l, 'amount': a});
                        laborManualLabelController.clear();
                        laborManualAmountController.clear();
                      });
                    },
                    icon: const Icon(Icons.add),
                  ),
                ],
              ),
              ...laborManualCosts.map((e) => ListTile(
                    dense: true,
                    title: Text('${e['label']}'),
                    trailing: Text('₱${jsonToDouble(e['amount']).toStringAsFixed(2)}'),
                  )),
              Align(
                alignment: Alignment.centerLeft,
                child: Text('Computed labor cost: ₱${_laborCostComputed().toStringAsFixed(2)}'),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: travelCostController,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(labelText: 'Travel cost'),
                onChanged: (_) => setState(() {}),
              ),
            ],
          ),
        ),
        const SizedBox(height: 10),
        ToggleSection(
          title: 'Additional costs',
          expanded: true,
          onToggle: () {},
          hideToggleIcon: true,
          child: Column(
            children: [
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: additionalCostLabelController,
                      decoration: const InputDecoration(labelText: 'Label'),
                    ),
                  ),
                  const SizedBox(width: 8),
                  SizedBox(
                    width: 120,
                    child: TextField(
                      controller: additionalCostAmountController,
                      keyboardType: TextInputType.number,
                      decoration: const InputDecoration(labelText: 'Amount'),
                    ),
                  ),
                  IconButton(
                    onPressed: () {
                      final l = additionalCostLabelController.text.trim();
                      final a = double.tryParse(additionalCostAmountController.text.trim());
                      if (l.isEmpty || a == null) return;
                      setState(() {
                        additionalCosts.add({'label': l, 'amount': a});
                        additionalCostLabelController.clear();
                        additionalCostAmountController.clear();
                      });
                    },
                    icon: const Icon(Icons.add),
                  ),
                ],
              ),
              ...additionalCosts.map((e) => ListTile(
                    dense: true,
                    title: Text('${e['label']}'),
                    trailing: Text('₱${jsonToDouble(e['amount']).toStringAsFixed(2)}'),
                  )),
            ],
          ),
        ),
        if (!widget.state.isManager) ...[
          const SizedBox(height: 8),
          const Text('Supervisor has limited access: viewing and processing only.'),
        ],
        ],
      ),
      bottomNavigationBar: SafeArea(
        child: Container(
          decoration: BoxDecoration(
            color: Theme.of(context).scaffoldBackgroundColor,
            border: Border(top: BorderSide(color: Colors.grey.shade300)),
          ),
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 10),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Center(
                child: Column(
                  children: [
                    const Text('Estimated Cost', style: TextStyle(fontWeight: FontWeight.w800)),
                    const SizedBox(height: 2),
                    Text(
                      '₱${estimate.toStringAsFixed(2)}',
                      style: const TextStyle(fontSize: 24, fontWeight: FontWeight.w800),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 8),
              OutlinedButton(
                onPressed: generateOrderSummaryPdfForDraft,
                child: const Text('Generate Order Summary PDF'),
              ),
              const SizedBox(height: 8),
              FilledButton(
                onPressed: !widget.state.isManager ? null : createNewEvent,
                child: const Text('Save'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ManagerStageListTab extends StatelessWidget {
  const _ManagerStageListTab({required this.state, required this.stage, required this.isReadOnly});
  final AppState state;
  final String stage;
  final bool isReadOnly;
  String _next(String s) {
    if (s == 'new_event' || s == 'online_inquiries') return 'for_processing';
    if (s == 'for_processing') return 'for_post_analysis';
    if (s == 'for_post_analysis') return 'completed';
    return 'completed';
  }

  Color _statusBadgeBg(String status) {
    final s = status.trim().toLowerCase();
    if (s == 'completed') return Colors.green.shade100;
    if (s == 'cancelled') return Colors.grey.shade300;
    if (s == 'for_post_analysis') return Colors.indigo.shade100;
    if (s == 'for_processing') return Colors.blue.shade100;
    return Colors.orange.shade100;
  }

  Color _statusBadgeFg(String status) {
    final s = status.trim().toLowerCase();
    if (s == 'completed') return Colors.green.shade900;
    if (s == 'cancelled') return Colors.grey.shade900;
    if (s == 'for_post_analysis') return Colors.indigo.shade900;
    if (s == 'for_processing') return Colors.blue.shade900;
    return Colors.orange.shade900;
  }

  @override
  Widget build(BuildContext context) {
    final rows = state.managerCateringRows.where((e) => e.status == stage).toList();
    return RefreshIndicator(
      onRefresh: () => state.loadManagerCateringByStage(stage, force: true),
      child: rows.isEmpty
          ? ListView(children: const [SizedBox(height: 140), Center(child: Text('No records in this stage.'))])
          : ListView.builder(
              padding: const EdgeInsets.all(10),
              itemCount: rows.length,
              itemBuilder: (context, i) {
                final r = rows[i];
                final entered = r.stageEnteredAt ?? r.updatedAt;
                final whenStr = formatDateTimeLocal(entered);
                final scheduleLine =
                    r.schedulePreview.trim().isNotEmpty ? 'Event date/time: ${r.schedulePreview}' : '';
                final settingLabel = managerEventSettingDisplayLabel(r.eventSetting);
                final settingLine = settingLabel.isNotEmpty ? 'Setting: $settingLabel' : '';
                final conflictLine = stage == 'for_processing' && r.processingScheduleOverlaps > 0
                    ? 'Schedule overlap: crosses ${r.processingScheduleOverlaps} other active order(s) — open for details.'
                    : '';
                final stLower = r.status.trim().toLowerCase();
                final loyaltyLine = r.cateringLoyaltyPointsEarned > 0 && stLower == 'completed'
                    ? 'Catering loyalty applied: +${r.cateringLoyaltyPointsEarned} pts'
                    : (stLower != 'completed' && r.cateringLoyaltyEligiblePointsIfCompleted > 0)
                        ? 'If completed at this total: +${r.cateringLoyaltyEligiblePointsIfCompleted} pts (min ₱${kCateringLoyaltyMinOrderTotal.toStringAsFixed(0)} catering)'
                        : '';
                final subtitleLines = <String>[
                  r.contactPerson,
                  '${managerStageListTimestampLabel(stage)}: $whenStr',
                  if (scheduleLine.isNotEmpty) scheduleLine,
                  if (settingLine.isNotEmpty) settingLine,
                  if (conflictLine.isNotEmpty) conflictLine,
                  if (loyaltyLine.isNotEmpty) loyaltyLine,
                ];
                return Card(
                  child: ListTile(
                    leading: stage == 'for_processing' && r.processingScheduleOverlaps > 0
                        ? Icon(Icons.warning_amber_rounded, color: Colors.orange.shade800)
                        : (r.status == 'new_event' || r.status == 'online_inquiries')
                            ? Icon(Icons.notifications_active, color: Colors.red.shade700)
                            : null,
                    title: Row(
                      children: [
                        Expanded(
                          child: Text(r.eventTitle.isEmpty ? r.customerName : r.eventTitle),
                        ),
                        const SizedBox(width: 6),
                        Container(
                          constraints: const BoxConstraints(maxWidth: 165),
                          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                          decoration: BoxDecoration(
                            color: _statusBadgeBg(r.status),
                            borderRadius: BorderRadius.circular(999),
                          ),
                          child: Text(
                            inquiryStatusReadable(r.status),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 10.5,
                              fontWeight: FontWeight.w700,
                              color: _statusBadgeFg(r.status),
                            ),
                          ),
                        ),
                      ],
                    ),
                    subtitle: Text(subtitleLines.join('\n')),
                    isThreeLine: subtitleLines.length > 2,
                    trailing: isReadOnly
                        ? const Icon(Icons.lock_outline)
                        : Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            crossAxisAlignment: CrossAxisAlignment.end,
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              if (stage == 'new_event' || stage == 'online_inquiries')
                                TextButton(
                                  onPressed: () async {
                                    final ok = await showDialog<bool>(
                                      context: context,
                                      builder: (ctx) => AlertDialog(
                                        title: const Text('Cancel this inquiry?'),
                                        content: const Text(
                                          'It will move to the Cancelled tab. This cannot be undone from the app.',
                                        ),
                                        actions: [
                                          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('No')),
                                          FilledButton(
                                            onPressed: () => Navigator.pop(ctx, true),
                                            child: const Text('Yes, cancel'),
                                          ),
                                        ],
                                      ),
                                    );
                                    if (ok != true || !context.mounted) return;
                                    final err = await state.managerAdvanceCateringStage(
                                      id: r.id,
                                      orderKind: r.orderKind,
                                      status: 'cancelled',
                                    );
                                    if (!context.mounted) return;
                                    if (err != null) {
                                      appSnack(context, err);
                                      return;
                                    }
                                    appSnack(context, 'Cancelled');
                                    await state.loadManagerCateringByStage(stage, force: true);
                                  },
                                  child: Text('Cancel', style: TextStyle(color: Colors.red.shade800)),
                                ),
                              FilledButton(
                                onPressed: () async {
                                  final target = _next(stage);
                                  if (!state.isManager && target == 'completed') {
                                    appSnack(context, 'Supervisor cannot complete orders.');
                                    return;
                                  }
                                  if (target == 'completed') {
                                    final double tc = r.totalCost > 0 ? r.totalCost : 1.0;
                                    if (!cateringFullPaymentConfirmed(r, tc)) {
                                      appSnack(context, 'Full payment confirmation is required before completing this order.');
                                      return;
                                    }
                                  }
                                  final err = await state.managerAdvanceCateringStage(
                                    id: r.id,
                                    orderKind: r.orderKind,
                                    status: target,
                                    downPaymentAmount: stage == 'for_processing' ? (r.totalCost * 0.5) : null,
                                    fullPaymentAmount: null,
                                    postAnalysis: stage == 'for_post_analysis' ? {'completed_by': state.userEmail} : null,
                                  );
                                  if (!context.mounted) return;
                                  if (err != null) {
                                    appSnack(context, err);
                                    return;
                                  }
                                  appSnack(context, 'Moved to next stage');
                                  await state.loadManagerCateringByStage(stage, force: true);
                                },
                                child: const Text('Next'),
                              ),
                            ],
                          ),
                    onTap: () {
                      Navigator.of(context).push<void>(
                        MaterialPageRoute<void>(
                          builder: (_) => ManagerCateringDetailScreen(state: state, row: r, stage: stage),
                        ),
                      );
                    },
                  ),
                );
              },
            ),
    );
  }
}

class ManagerCateringDetailScreen extends StatefulWidget {
  const ManagerCateringDetailScreen({super.key, required this.state, required this.row, required this.stage});
  final AppState state;
  final CateringEventRecord row;
  final String stage;
  @override
  State<ManagerCateringDetailScreen> createState() => _ManagerCateringDetailScreenState();
}

class _ManagerCateringDetailScreenState extends State<ManagerCateringDetailScreen> {
  static const String _managerDraftDetailKeyPrefix = 'manager_draft_detail_unsaved_v1_';
  CateringEventRecord? _loadedDetailRow;
  bool _detailReady = false;
  Timer? _localDraftDebounce;

  CateringEventRecord get d => _loadedDetailRow ?? widget.row;

  final downPaymentController = TextEditingController();
  final downPaymentPaidController = TextEditingController();
  final fullPaymentController = TextEditingController();
  final analysisController = TextEditingController();
  final checklistController = TextEditingController();
  final taskAssignmentController = TextEditingController();
  final businessCardsController = TextEditingController();
  final spotInquiriesController = TextEditingController();
  final complaintsController = TextEditingController();
  final popularDishController = TextEditingController();
  final popularDrinkController = TextEditingController();
  final popularDessertController = TextEditingController();
  final laborMaleController = TextEditingController(text: '0');
  final laborFemaleController = TextEditingController(text: '0');
  final laborManualLabelController = TextEditingController();
  final laborManualAmountController = TextEditingController();
  final travelCostController = TextEditingController(text: '0');
  final additionalCostLabelController = TextEditingController();
  final additionalCostAmountController = TextEditingController();
  final themeCostLabelController = TextEditingController();
  final themeCostAmountController = TextEditingController();
  final menuSearchController = TextEditingController();
  final managerEventTypeOtherController = TextEditingController();
  final managerDraftEventTitleController = TextEditingController();
  final managerGuestCountController = TextEditingController();
  final managerInquiryNoteController = TextEditingController();
  String managerEventTypeChoice = 'Birthday';
  String managerServiceIncluded = 'no';
  String managerFormalityLevel = 'casual';
  String managerEventSetting = 'open';
  /// Draft-stage inquiry kind (`catering` vs `event`); may differ from [d] until saved / migrated.
  String _draftOrderKind = 'event';
  final List<_InquiryEventWindow> _eventWindows = [_InquiryEventWindow()];
  final List<_InquiryEventWindow> _forProcessingWindows = [];
  bool _forProcessingWindowsLoading = false;
  bool _forProcessingWindowsLoaded = false;
  String selectedSetMenu = 'All Dishes';
  final selectedDishes = <String>{};
  final List<Map<String, dynamic>> laborManualCosts = [];
  final List<Map<String, dynamic>> additionalCosts = [];
  final List<Map<String, dynamic>> themeDesignCosts = [];
  // Post-Analysis requirement: keep the initial order summary PDF (#1)
  // and generate a second one (#2) when additional costs are added/changed.
  Uint8List? _postAnalysisPdf1Bytes;
  Uint8List? _postAnalysisPdf2Bytes;
  String _postAnalysisPdf1Signature = '';
  String _postAnalysisPdf2Signature = '';
  bool _postAnalysisPdfGenerating = false;
  final List<Map<String, dynamic>> checklistRows = [];
  final List<Map<String, dynamic>> checklistRowsOriginal = [];
  final List<Map<String, dynamic>> taskRows = [];
  final List<Map<String, dynamic>> taskRowsOriginal = [];
  final List<String> actualEventImages = [];
  Uint8List? _managerDownPaymentProofBytes;
  Uint8List? _managerFullPaymentProofBytes;

  double _sumCostRows(List<Map<String, dynamic>> rows) {
    double sum = 0;
    for (final e in rows) {
      sum += jsonToDouble(e['amount']);
    }
    return sum;
  }

  double _baseFoodCost() {
    final g = d.guestCount;
    final minGuests = d.orderKind == 'event' ? kMinCateringEventPax : kMinCateringOnlyPax;
    final billable = g < minGuests ? minGuests : g;
    return billable * kPesosPerPax;
  }

  DateTime? _parseScheduleDate(dynamic v) {
    final s = v == null ? '' : v.toString().trim();
    if (s.isEmpty) return null;
    try {
      return DateTime.parse(s);
    } catch (_) {
      return null;
    }
  }

  TimeOfDay? _parseScheduleTime(dynamic v) {
    final s = v == null ? '' : v.toString().trim();
    if (s.isEmpty) return null;
    // Supports "HH:MM" (optionally with seconds).
    final m = RegExp(r'^(\d{1,2}):(\d{2})').firstMatch(s);
    if (m == null) return null;
    final hh = int.tryParse(m.group(1) ?? '');
    final mm = int.tryParse(m.group(2) ?? '');
    if (hh == null || mm == null) return null;
    if (hh < 0 || hh > 23 || mm < 0 || mm > 59) return null;
    return TimeOfDay(hour: hh, minute: mm);
  }

  List<_InquiryEventWindow> _windowsFromScheduleSlots(dynamic raw) {
    final out = <_InquiryEventWindow>[];
    dynamic listLike = raw;
    if (raw is Map) listLike = [raw];
    if (raw is String) {
      final t = raw.trim();
      if (t.startsWith('[') || t.startsWith('{')) {
        try {
          listLike = jsonDecode(t);
        } catch (_) {}
      }
    }
    if (listLike is List) {
      for (final s in listLike) {
        if (s is Map) {
          final date = _parseScheduleDate(s['date'] ?? s['label']);
          final from = _parseScheduleTime(s['from']);
          final to = _parseScheduleTime(s['to']);
          if (date != null && from != null && to != null) {
            out.add(_InquiryEventWindow()..date = date..from = from..to = to);
          }
        }
      }
    }
    return out;
  }

  List<Map<String, String>> _scheduleSlotsPayload() {
    final out = <Map<String, String>>[];
    for (final w in _eventWindows) {
      if (w.date == null || w.from == null || w.to == null) continue;
      final d = w.date!;
      final dateStr = '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
      final f = '${w.from!.hour.toString().padLeft(2, '0')}:${w.from!.minute.toString().padLeft(2, '0')}';
      final t = '${w.to!.hour.toString().padLeft(2, '0')}:${w.to!.minute.toString().padLeft(2, '0')}';
      out.add({'date': dateStr, 'from': f, 'to': t, 'label': '$dateStr from $f to $t'});
    }
    return out;
  }

  bool _windowsOverlapOnSameDate(_InquiryEventWindow a, _InquiryEventWindow b) {
    if (a.date == null || a.from == null || a.to == null) return false;
    if (b.date == null || b.from == null || b.to == null) return false;
    if (a.date!.year != b.date!.year || a.date!.month != b.date!.month || a.date!.day != b.date!.day) return false;
    final aStart = a.from!.hour * 60 + a.from!.minute;
    final aEnd = a.to!.hour * 60 + a.to!.minute;
    final bStart = b.from!.hour * 60 + b.from!.minute;
    final bEnd = b.to!.hour * 60 + b.to!.minute;
    return aStart < bEnd && aEnd > bStart;
  }

  Future<void> _loadForProcessingWindowsIfNeeded() async {
    if (_forProcessingWindowsLoading || _forProcessingWindowsLoaded) return;
    final email = widget.state.userEmail;
    if (email == null || widget.state.loginPassword.isEmpty) return;

    setState(() => _forProcessingWindowsLoading = true);
    try {
      final listUri = Uri.parse('${normalizeApiBase(widget.state.apiBase)}/api/mobile/pos/catering/list');
      final res = await http
          .post(
            listUri,
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({
              'cashier_email': email,
              'cashier_password': widget.state.loginPassword,
              'stage': 'for_processing',
              'summary': true,
            }),
          )
          .timeout(_managerCateringListTimeout);
      if (res.statusCode != 200) return;
      final body = jsonDecode(res.body);
      if (body is! List) return;

      final windows = <_InquiryEventWindow>[];
      for (final e in body) {
        if (e is Map) {
          windows.addAll(_windowsFromScheduleSlots(e['schedule_slots']));
        }
      }

      if (!mounted) return;
      setState(() {
        _forProcessingWindows
          ..clear()
          ..addAll(windows);
        _forProcessingWindowsLoaded = true;
        _forProcessingWindowsLoading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _forProcessingWindowsLoaded = false;
        _forProcessingWindowsLoading = false;
      });
    }
  }

  int _conflictCountWithForProcessing() {
    final draftStage = widget.stage == 'new_event' || widget.stage == 'online_inquiries';
    if (!draftStage) return 0;
    if (!_forProcessingWindowsLoaded) return 0;
    final processingWindows = _forProcessingWindows;
    var conflicts = 0;
    for (final w in _eventWindows) {
      for (final pw in processingWindows) {
        if (_windowsOverlapOnSameDate(w, pw)) conflicts++;
      }
    }
    return conflicts;
  }

  Future<void> _pickWindowDate(int idx) async {
    if (idx < 0 || idx >= _eventWindows.length) return;
    final initial = _eventWindows[idx].date ?? DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: initial,
      firstDate: DateTime(2020),
      lastDate: DateTime(2100),
    );
    if (picked == null) return;
    setState(() {
      _eventWindows[idx].date = picked;
    });
    _saveLocalDraftDebounced();
  }

  Future<void> _pickWindowFromTime(int idx) async {
    if (idx < 0 || idx >= _eventWindows.length) return;
    final initial = _eventWindows[idx].from ?? const TimeOfDay(hour: 9, minute: 0);
    final picked = await showTimePicker(context: context, initialTime: initial);
    if (picked == null) return;
    setState(() {
      _eventWindows[idx].from = picked;
    });
    _saveLocalDraftDebounced();
  }

  Future<void> _pickWindowToTime(int idx) async {
    if (idx < 0 || idx >= _eventWindows.length) return;
    final initial = _eventWindows[idx].to ?? const TimeOfDay(hour: 10, minute: 0);
    final picked = await showTimePicker(context: context, initialTime: initial);
    if (picked == null) return;
    setState(() {
      _eventWindows[idx].to = picked;
    });
    _saveLocalDraftDebounced();
  }

  void _addAnotherWindow() {
    setState(() {
      _eventWindows.add(_InquiryEventWindow());
    });
    _saveLocalDraftDebounced();
  }

  void _removeWindowAt(int idx) {
    setState(() {
      if (_eventWindows.length <= 1) {
        _eventWindows[0] = _InquiryEventWindow();
      } else {
        _eventWindows.removeAt(idx);
      }
    });
    _saveLocalDraftDebounced();
  }

  List<Widget> _buildLabeledScheduleRows(List<dynamic> scheduleSlots) {
    final out = <Widget>[];
    for (final s in scheduleSlots) {
      if (s is Map) {
        final dateRaw = s['date'] ?? s['label'] ?? '';
        final fromRaw = s['from'] ?? '';
        final toRaw = s['to'] ?? '';
        final dateStr = '$dateRaw'.trim();
        final fromStr = '$fromRaw'.trim();
        final toStr = '$toRaw'.trim();
        if (dateStr.isNotEmpty && fromStr.isNotEmpty && toStr.isNotEmpty) {
          out.add(
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Row(
                children: [
                  Text('Date: $dateStr'),
                  const SizedBox(width: 12),
                  Text('Time: $fromStr - $toStr'),
                ],
              ),
            ),
          );
          continue;
        }
      }
      out.add(
        Padding(
          padding: const EdgeInsets.only(bottom: 6),
          child: Text(formatScheduleSlotLine(s).trim()),
        ),
      );
    }
    return out;
  }

  double _laborCostComputed() {
    final male = int.tryParse(laborMaleController.text.trim()) ?? 0;
    final female = int.tryParse(laborFemaleController.text.trim()) ?? 0;
    final maleCost = male < 0 ? 0 : male * 1000;
    final femaleCost = female < 0 ? 0 : female * 500;
    return maleCost + femaleCost + _sumCostRows(laborManualCosts);
  }

  double _travelCostComputed() => double.tryParse(travelCostController.text.trim()) ?? 0;

  double _grandTotalComputed() =>
      _baseFoodCost() + _laborCostComputed() + _travelCostComputed() + _sumCostRows(additionalCosts) + _sumCostRows(themeDesignCosts);

  String _additionalCostsSignature(List<Map<String, dynamic>> costs) {
    final normalized = costs.map((e) => {
          'label': '${e['label'] ?? ''}'.trim(),
          'amount': jsonToDouble(e['amount']).toStringAsFixed(2),
        });
    return jsonEncode(normalized.toList());
  }

  String _eventDateTimeJoinedFromRowScheduleSlots(List<dynamic> slots) {
    final lines = <String>[];
    for (final s in slots) {
      final f = formatScheduleSlotLine(s).trim();
      if (f.isNotEmpty) lines.add(f.replaceAll('\n', ' | '));
    }
    return lines.join(' ; ');
  }

  List<String> _menuDishNamesFromRowMenu() {
    final names = <String>{};
    final entries = normalizeCateringMenuList(d.menu);
    for (final e in entries) {
      final n = dishNameFromCateringMenuEntry(e).trim();
      if (n.isNotEmpty) names.add(n);
    }
    return names.toList()..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
  }

  Future<Uint8List> _buildOrderSummaryPdfBytes({
    required List<Map<String, dynamic>> additionalCostsForPdf,
    bool postAnalysis2Only = false,
  }) async {
    final doc = pw.Document();
    final labelBg = pdf.PdfColor.fromInt(0xFFCFCFCF);
    final themeCost = _sumCostRows(themeDesignCosts);
    final additionalCostTotal = _sumCostRows(additionalCostsForPdf);
    final processingAt = formatDateTimeLocal(d.stageEnteredAt ?? d.updatedAt);
    final eventWhen = _eventDateTimeJoinedFromRowScheduleSlots(d.scheduleSlots);
    final settingLabel = managerEventSetting == 'closed' ? 'Closed space' : 'Open space';

    pw.Widget labelValueRow(String k, String v) => pw.Padding(
          padding: const pw.EdgeInsets.only(bottom: 5),
          child: pw.Row(
            crossAxisAlignment: pw.CrossAxisAlignment.start,
            children: [
              pw.Expanded(
                flex: 2,
                child: pw.Container(
                  color: labelBg,
                  padding: const pw.EdgeInsets.symmetric(horizontal: 6, vertical: 5),
                  child: pw.Text(k, style: pw.TextStyle(fontWeight: pw.FontWeight.bold, fontSize: 10)),
                ),
              ),
              pw.SizedBox(width: 6),
              pw.Expanded(
                flex: 3,
                child: pw.Padding(
                  padding: const pw.EdgeInsets.symmetric(vertical: 5),
                  child: pw.Text(v.isEmpty ? '—' : v, style: const pw.TextStyle(fontSize: 10)),
                ),
              ),
            ],
          ),
        );

    if (postAnalysis2Only) {
      final addRows = <pw.Widget>[
        labelValueRow('Date/Time of Event', eventWhen.isEmpty ? '—' : eventWhen),
        labelValueRow('Event setting', settingLabel),
      ];
      for (final e in additionalCostsForPdf) {
        final label = '${e['label'] ?? ''}'.trim();
        final amount = jsonToDouble(e['amount']);
        if (label.isEmpty && amount <= 0) continue;
        addRows.add(labelValueRow(label.isEmpty ? 'Additional item' : label, 'PHP ${amount.toStringAsFixed(2)}'));
      }
      addRows.add(labelValueRow('Additional costs (total)', 'PHP ${additionalCostTotal.toStringAsFixed(2)}'));
      doc.addPage(
        pw.MultiPage(
          build: (ctx) => [
            pw.Text('Order Summary', style: pw.TextStyle(fontSize: 18, fontWeight: pw.FontWeight.bold)),
            pw.Text('Macrina\'s Kitchen and Catering', style: pw.TextStyle(fontSize: 10, color: pdf.PdfColors.grey700)),
            pw.SizedBox(height: 12),
            pw.Text('Event information', style: pw.TextStyle(fontSize: 12, fontWeight: pw.FontWeight.bold)),
            pw.SizedBox(height: 6),
            labelValueRow('Transaction No.', d.transactionNo.isEmpty ? '—' : d.transactionNo),
            labelValueRow('Event', d.eventTitle.isEmpty ? d.customerName : d.eventTitle),
            labelValueRow('Customer', d.customerName),
            labelValueRow('Contact person', d.contactPerson),
            labelValueRow('Address', d.address),
            ...addRows,
          ],
        ),
      );
      return doc.save();
    }

    final laborLine = _laborCostComputed();
    final travelLine = _travelCostComputed();
    final totalComputed = _baseFoodCost() + laborLine + travelLine + themeCost + additionalCostTotal;
    final noPaxAmount = d.guestCount * kPesosPerPax;
    final downPaymentDue = totalComputed * 0.5;
    final totalDueNow = totalComputed - downPaymentDue;
    final menuLines = _menuDishNamesFromRowMenu();
    final cateringType = d.orderKind == 'catering' ? 'Catering' : 'Catering and Event';

    doc.addPage(
      pw.MultiPage(
        build: (ctx) => [
          pw.Text('Order Summary', style: pw.TextStyle(fontSize: 18, fontWeight: pw.FontWeight.bold)),
          pw.Text('Macrina\'s Kitchen and Catering', style: pw.TextStyle(fontSize: 10, color: pdf.PdfColors.grey700)),
          pw.SizedBox(height: 12),
          labelValueRow('Transaction No.', d.transactionNo.isEmpty ? '—' : d.transactionNo),
          labelValueRow('Date/Time processed', processingAt),
          labelValueRow('Event', d.eventTitle.isEmpty ? d.customerName : d.eventTitle),
          labelValueRow('Date/Time of Event', eventWhen.isEmpty ? '—' : eventWhen),
          labelValueRow('Customer', d.customerName),
          labelValueRow('Contact person', d.contactPerson),
          labelValueRow('Catering type', cateringType),
          labelValueRow('Address of event', d.address),
          labelValueRow('Menu dishes', menuLines.isEmpty ? '—' : menuLines.join(', ')),
          labelValueRow(
            'No. of PAX and cost',
            '${d.guestCount} x PHP ${kPesosPerPax.toStringAsFixed(0)} | PHP ${noPaxAmount.toStringAsFixed(2)}',
          ),
          labelValueRow('Event theme design cost', 'PHP ${themeCost.toStringAsFixed(2)}'),
          labelValueRow('Labor cost', 'PHP ${laborLine.toStringAsFixed(2)}'),
          labelValueRow('Travel cost', 'PHP ${travelLine.toStringAsFixed(2)}'),
          labelValueRow(
            'Additional costs',
            additionalCostsForPdf.isEmpty
                ? '—'
                : additionalCostsForPdf
                    .map((e) {
                      final lb = '${e['label'] ?? ''}'.trim();
                      final am = jsonToDouble(e['amount']);
                      if (lb.isEmpty && am <= 0) return '';
                      return '${lb.isEmpty ? 'Item' : lb}: PHP ${am.toStringAsFixed(2)}';
                    })
                    .where((x) => x.isNotEmpty)
                    .join(' · '),
          ),
          labelValueRow('Additional costs (total)', 'PHP ${additionalCostTotal.toStringAsFixed(2)}'),
          labelValueRow('Total invoice', 'PHP ${totalComputed.toStringAsFixed(2)}'),
          labelValueRow('Down payment (50%)', 'PHP ${downPaymentDue.toStringAsFixed(2)}'),
          labelValueRow('Total amount due (after down payment)', 'PHP ${totalDueNow.toStringAsFixed(2)}'),
        ],
      ),
    );

    return doc.save();
  }

  Future<void> _openOrderSummaryPdfBytes(Uint8List bytes) async {
    await Printing.layoutPdf(onLayout: (_) async => bytes);
  }

  Future<void> _sendOrderSummaryPdfToCustomer() async {
    final bytes = await _buildOrderSummaryPdfBytes(additionalCostsForPdf: additionalCosts);
    final d = _loadedDetailRow ?? widget.row;
    final tx = d.transactionNo.trim().isEmpty ? d.id : d.transactionNo.trim();
    await Printing.sharePdf(
      bytes: bytes,
      filename: 'order_summary_$tx.pdf',
      subject: 'Order summary $tx',
      body: 'Please see attached order summary for ${d.customerName}.',
    );
  }

  Future<void> _capturePostAnalysisPdf1IfNeeded() async {
    if (widget.stage != 'for_post_analysis') return;
    if (_postAnalysisPdf1Bytes != null) return;

    final snapshot = additionalCosts.map((e) => Map<String, dynamic>.from(e)).toList();
    final sig = _additionalCostsSignature(snapshot);
    final bytes = await _buildOrderSummaryPdfBytes(additionalCostsForPdf: snapshot);
    if (!mounted) return;
    setState(() {
      _postAnalysisPdf1Bytes = bytes;
      _postAnalysisPdf1Signature = sig;
      _postAnalysisPdf2Bytes = null;
      _postAnalysisPdf2Signature = '';
    });
  }

  Future<void> _maybeGeneratePostAnalysisPdf2IfNeeded() async {
    if (widget.stage != 'for_post_analysis') return;
    if (_postAnalysisPdf1Bytes == null) {
      await _capturePostAnalysisPdf1IfNeeded();
      if (_postAnalysisPdf1Bytes == null) return;
    }
    if (_postAnalysisPdf1Signature.isEmpty) return;

    final snapshot = additionalCosts.map((e) => Map<String, dynamic>.from(e)).toList();
    final sig = _additionalCostsSignature(snapshot);
    if (sig == _postAnalysisPdf1Signature) {
      // Back to initial state: hide #2.
      if (_postAnalysisPdf2Bytes != null) {
        if (!mounted) return;
        setState(() {
          _postAnalysisPdf2Bytes = null;
          _postAnalysisPdf2Signature = '';
        });
      }
      return;
    }
    if (_postAnalysisPdf2Bytes != null && sig == _postAnalysisPdf2Signature) return;
    if (_postAnalysisPdfGenerating) return;

    setState(() => _postAnalysisPdfGenerating = true);
    try {
      final bytes = await _buildOrderSummaryPdfBytes(
        additionalCostsForPdf: snapshot,
        postAnalysis2Only: true,
      );
      if (!mounted) return;
      setState(() {
        _postAnalysisPdf2Bytes = bytes;
        _postAnalysisPdf2Signature = sig;
      });
    } finally {
      if (mounted) setState(() => _postAnalysisPdfGenerating = false);
    }
  }

  void _refreshDueAndDefaults() {
    final total = widget.stage == 'for_processing'
        ? _baseFoodCost() + _sumCostRows(themeDesignCosts) + _sumCostRows(additionalCosts)
        : _grandTotalComputed();
    downPaymentController.text = (total * 0.5).toStringAsFixed(2);
    if (fullPaymentController.text.trim().isEmpty || jsonToDouble(fullPaymentController.text) <= 0) {
      fullPaymentController.text = total.toStringAsFixed(2);
    }
  }

  @override
  void initState() {
    super.initState();
    for (final c in [
      managerDraftEventTitleController,
      managerEventTypeOtherController,
      managerGuestCountController,
      managerInquiryNoteController,
    ]) {
      c.addListener(_saveLocalDraftDebounced);
    }
    Future.microtask(_bootstrapDetail);
  }

  String get _localDraftKey => '$_managerDraftDetailKeyPrefix${widget.row.id}_${widget.stage}';

  void _saveLocalDraftDebounced() {
    _localDraftDebounce?.cancel();
    _localDraftDebounce = Timer(const Duration(milliseconds: 350), _saveLocalDraftNow);
  }

  Future<void> _saveLocalDraftNow() async {
    final isDraftStage = widget.stage == 'new_event' || widget.stage == 'online_inquiries';
    if (!isDraftStage || !_detailReady) return;
    try {
      final p = await SharedPreferences.getInstance();
      await p.setString(
        _localDraftKey,
        jsonEncode({
          'draft_order_kind': _draftOrderKind,
          'event_title': managerDraftEventTitleController.text.trim(),
          'event_type_choice': managerEventTypeChoice,
          'event_type_other': managerEventTypeOtherController.text.trim(),
          'guest_count': managerGuestCountController.text.trim(),
          'inquiry_note': managerInquiryNoteController.text.trim(),
          'event_setting': managerEventSetting,
          'service_included': managerServiceIncluded,
          'formality_level': managerFormalityLevel,
          'selected_dishes': selectedDishes.toList(),
          'schedule_slots': _scheduleSlotsPayload(),
        }),
      );
    } catch (_) {}
  }

  Future<void> _restoreLocalDraftIfAny() async {
    final isDraftStage = widget.stage == 'new_event' || widget.stage == 'online_inquiries';
    if (!isDraftStage) return;
    try {
      final p = await SharedPreferences.getInstance();
      final raw = p.getString(_localDraftKey);
      if (raw == null || raw.trim().isEmpty) return;
      final m = jsonDecode(raw);
      if (m is! Map) return;
      _draftOrderKind = '${m['draft_order_kind'] ?? _draftOrderKind}';
      managerDraftEventTitleController.text = '${m['event_title'] ?? managerDraftEventTitleController.text}';
      managerEventTypeChoice = '${m['event_type_choice'] ?? managerEventTypeChoice}';
      managerEventTypeOtherController.text = '${m['event_type_other'] ?? managerEventTypeOtherController.text}';
      managerGuestCountController.text = '${m['guest_count'] ?? managerGuestCountController.text}';
      managerInquiryNoteController.text = '${m['inquiry_note'] ?? managerInquiryNoteController.text}';
      managerEventSetting = '${m['event_setting'] ?? managerEventSetting}';
      managerServiceIncluded = '${m['service_included'] ?? managerServiceIncluded}';
      managerFormalityLevel = '${m['formality_level'] ?? managerFormalityLevel}';
      final dishes = m['selected_dishes'];
      if (dishes is List) {
        selectedDishes
          ..clear()
          ..addAll(dishes.map((e) => '$e'));
      }
      final slots = m['schedule_slots'];
      if (slots is List) {
        _eventWindows
          ..clear()
          ..addAll(_windowsFromScheduleSlots(slots));
        if (_eventWindows.isEmpty) _eventWindows.add(_InquiryEventWindow());
      }
    } catch (_) {}
  }

  Future<void> _bootstrapDetail() async {
    final full = await widget.state.loadManagerCateringItem(
      id: widget.row.id,
      orderKind: widget.row.orderKind,
    );
    if (!mounted) return;
    _loadedDetailRow = full ?? widget.row;
    _initControllersFromRow(_loadedDetailRow!);
    await _restoreLocalDraftIfAny();
    setState(() => _detailReady = true);
  }

  void _initControllersFromRow(CateringEventRecord row) {
    final tdInit = row.themeDesign;
    final existingEventType =
        '${row.postAnalysis['event_type'] ?? tdInit['event_type'] ?? row.eventType}'.trim();
    if (existingEventType.isNotEmpty) {
      if (kMobileEventTypeChoices.contains(existingEventType)) {
        managerEventTypeChoice = existingEventType;
      } else {
        managerEventTypeChoice = 'Other';
        managerEventTypeOtherController.text = existingEventType;
      }
    }
    managerServiceIncluded = '${tdInit['service_included'] ?? row.serviceIncluded ?? 'no'}' == 'yes' ? 'yes' : 'no';
    managerFormalityLevel =
        row.formalityLevel.trim().isEmpty ? '${tdInit['formality_level'] ?? 'casual'}'.trim() : row.formalityLevel.trim();
    if (!{'casual', 'semiformal', 'formal'}.contains(managerFormalityLevel)) managerFormalityLevel = 'casual';
    managerDraftEventTitleController.text =
        row.eventTitle.trim().isNotEmpty ? row.eventTitle.trim() : '${tdInit['event_title'] ?? ''}'.trim();
    managerGuestCountController.text = '${row.guestCount <= 0 ? '' : row.guestCount}';
    managerInquiryNoteController.text = '${tdInit['note'] ?? ''}';
    managerEventSetting = '${tdInit['event_setting'] ?? 'open'}'.trim().isEmpty ? 'open' : tdInit['event_setting'].toString().trim();
    _draftOrderKind = row.orderKind;
    if (widget.stage == 'new_event' || widget.stage == 'online_inquiries') {
      _eventWindows
        ..clear()
        ..addAll(_windowsFromScheduleSlots(row.scheduleSlots));
      if (_eventWindows.isEmpty) _eventWindows.add(_InquiryEventWindow());
    }
    if (widget.stage == 'new_event' || widget.stage == 'online_inquiries') {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        _loadForProcessingWindowsIfNeeded();
      });
    }
    downPaymentPaidController.text = row.downPaymentAmount > 0 ? row.downPaymentAmount.toStringAsFixed(2) : '';
    fullPaymentController.text = row.fullPaymentAmount > 0 ? row.fullPaymentAmount.toStringAsFixed(2) : '';
    analysisController.text = '${row.postAnalysis['notes'] ?? ''}';
    checklistController.text = row.checklist.map((e) => '$e').join('\n');
    taskAssignmentController.text = '${row.postAnalysis['task_assignment'] ?? ''}';
    businessCardsController.text = '${row.postAnalysis['business_cards_given'] ?? ''}';
    spotInquiriesController.text = '${row.postAnalysis['on_the_spot_inquiries'] ?? ''}';
    complaintsController.text = '${row.postAnalysis['complaints'] ?? ''}';
    popularDishController.text = '${row.postAnalysis['most_popular_dish'] ?? ''}';
    popularDrinkController.text = '${row.postAnalysis['most_popular_drink'] ?? ''}';
    popularDessertController.text = '${row.postAnalysis['most_popular_dessert'] ?? ''}';
    travelCostController.text = row.travelCost.toStringAsFixed(2);
    if (row.laborCost > 0) {
      laborManualCosts.add({'label': 'Existing labor amount', 'amount': row.laborCost});
    }
    laborMaleController.text = '${row.postAnalysis['labor_male_count'] ?? 0}';
    laborFemaleController.text = '${row.postAnalysis['labor_female_count'] ?? 0}';
    for (final c in row.additionalCosts) {
      if (c is Map<String, dynamic>) additionalCosts.add(c);
    }
    final td = tdInit;
    final tc = td['cost_items'];
    if (tc is List) {
      for (final e in tc) {
        if (e is Map<String, dynamic>) themeDesignCosts.add(e);
      }
    }
    final rowMenu = normalizeCateringMenuList(row.menu);
    for (final m in rowMenu) {
      final n = dishNameFromCateringMenuEntry(m).trim();
      if (n.isNotEmpty) selectedDishes.add(n);
    }
    for (final c in row.checklist) {
      if (c is Map<String, dynamic>) {
        checklistRows.add({
          'item': '${c['item'] ?? ''}',
          'description': '${c['description'] ?? ''}',
          'quantity': '${c['quantity'] ?? ''}',
          'cost': '${c['cost'] ?? ''}',
          'status': '${c['status'] ?? 'not done'}',
        });
      } else if ('$c'.trim().isNotEmpty) {
        checklistRows.add({'item': '$c', 'description': '', 'quantity': '', 'cost': '', 'status': 'not done'});
      }
    }
    if (checklistRows.isEmpty) {
      checklistRows.add({'item': '', 'description': '', 'quantity': '', 'cost': '', 'status': 'not done'});
    }
    checklistRowsOriginal
      ..clear()
      ..addAll(checklistRows.map((e) => Map<String, dynamic>.from(e)));
    final existingTaskRows = row.postAnalysis['task_assignment_rows'];
    if (existingTaskRows is List && existingTaskRows.isNotEmpty) {
      for (final t in existingTaskRows) {
        if (t is Map) {
          taskRows.add({
            'employee': '${t['employee'] ?? ''}',
            'tasks': '${t['tasks'] ?? ''}',
            'schedule_of_tasks': '${t['schedule_of_tasks'] ?? ''}',
            'budget': '${t['budget'] ?? ''}',
            'status': '${t['status'] ?? 'not done'}',
          });
        }
      }
    }
    if (taskRows.isEmpty) {
      for (var i = 0; i < 5; i++) {
        taskRows.add({
          'employee': '',
          'tasks': '',
          'schedule_of_tasks': '',
          'budget': '',
          'status': 'not done',
        });
      }
    }
    taskRowsOriginal
      ..clear()
      ..addAll(taskRows.map((e) => Map<String, dynamic>.from(e)));
    _managerDownPaymentProofBytes = null;
    _managerFullPaymentProofBytes = null;
    final dpb = row.postAnalysis['manager_down_payment_proof_b64'];
    if (dpb is String && dpb.trim().isNotEmpty) {
      try {
        _managerDownPaymentProofBytes = Uint8List.fromList(base64Decode(dpb.trim()));
      } catch (_) {}
    }
    final fpb = row.postAnalysis['manager_full_payment_proof_b64'];
    if (fpb is String && fpb.trim().isNotEmpty) {
      try {
        _managerFullPaymentProofBytes = Uint8List.fromList(base64Decode(fpb.trim()));
      } catch (_) {}
    }
    if (widget.stage == 'for_post_analysis') {
      WidgetsBinding.instance.addPostFrameCallback((_) async {
        if (!mounted) return;
        await _capturePostAnalysisPdf1IfNeeded();
      });
    }
    _refreshDueAndDefaults();
  }

  @override
  void dispose() {
    _localDraftDebounce?.cancel();
    _saveLocalDraftNow();
    downPaymentController.dispose();
    downPaymentPaidController.dispose();
    fullPaymentController.dispose();
    analysisController.dispose();
    checklistController.dispose();
    taskAssignmentController.dispose();
    businessCardsController.dispose();
    spotInquiriesController.dispose();
    complaintsController.dispose();
    popularDishController.dispose();
    popularDrinkController.dispose();
    popularDessertController.dispose();
    laborMaleController.dispose();
    laborFemaleController.dispose();
    laborManualLabelController.dispose();
    laborManualAmountController.dispose();
    travelCostController.dispose();
    additionalCostLabelController.dispose();
    additionalCostAmountController.dispose();
    themeCostLabelController.dispose();
    themeCostAmountController.dispose();
    menuSearchController.dispose();
    managerEventTypeOtherController.dispose();
    managerDraftEventTitleController.dispose();
    managerGuestCountController.dispose();
    managerInquiryNoteController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!_detailReady) {
      return Scaffold(
        appBar: AppBar(title: const Text('Loading…')),
        body: const Center(child: CircularProgressIndicator()),
      );
    }
    final row = d;
    final isProcessing = widget.stage == 'for_processing';
    final isPost = widget.stage == 'for_post_analysis';
    final isCompleted = widget.stage == 'completed';
    final isOnlineInquiry = widget.stage == 'online_inquiries';
    final isDraftStage = widget.stage == 'new_event' || widget.stage == 'online_inquiries';
    final isThemeReadOnly = isProcessing || isPost || isCompleted;
    final canEditStage = !isCompleted;
    final canComplete = widget.state.isManager;
    final totalComputed = _grandTotalComputed();
    final displayInvoiceTotal = isProcessing
        ? (_baseFoodCost() + _sumCostRows(themeDesignCosts) + _sumCostRows(additionalCosts))
        : totalComputed;
    final scheduleConflictsForProcessing = _conflictCountWithForProcessing();
    final downPaymentDue = displayInvoiceTotal * 0.5;
    final isFullPaymentConfirmed = cateringFullPaymentConfirmed(row, totalComputed);
    final laborCostComputed = _laborCostComputed();
    final rowMenu = normalizeCateringMenuList(row.menu);
    Future<void> _generateChecklistPdf() async {
      final baseFont = await PdfGoogleFonts.notoSansRegular();
      final boldFont = await PdfGoogleFonts.notoSansBold();
      final doc = pw.Document(
        theme: pw.ThemeData.withFont(base: baseFont, bold: boldFont),
      );
      final stageLabel = widget.stage.replaceAll('_', ' ').toUpperCase();
      final generatedAt = DateTime.now().toLocal().toString();
      String enrichChecklistItem(String item) {
        final n = item.trim();
        if (n.isEmpty) return item;
        for (final m in widget.state.menu) {
          if (m.name.trim() == n && m.ingredients.isNotEmpty) {
            return '$n (${m.ingredients.join(', ')})';
          }
        }
        return item;
      }

      final rows = checklistRows
          .map(
            (r) => [
              enrichChecklistItem('${r['item'] ?? ''}'),
              '${r['description'] ?? ''}',
              '${r['quantity'] ?? ''}',
              '${r['cost'] ?? ''}',
              '${r['status'] ?? 'not done'}',
            ],
          )
          .toList();
      doc.addPage(
        pw.MultiPage(
          build: (ctx) => [
            pw.Text('Checklist', style: pw.TextStyle(fontSize: 18, fontWeight: pw.FontWeight.bold)),
            pw.SizedBox(height: 6),
            pw.Text('Event: ${row.eventTitle.isEmpty ? row.customerName : row.eventTitle}'),
            pw.Text('Customer: ${row.customerName}'),
            pw.Text('Stage: $stageLabel'),
            pw.Text('Generated: $generatedAt'),
            pw.SizedBox(height: 10),
            pw.TableHelper.fromTextArray(
              headers: const ['Item', 'Description', 'Quantity', 'Cost', 'Status'],
              data: rows.isEmpty ? const [['', 'No checklist items.', '', '', '']] : rows,
            ),
          ],
        ),
      );
      await Printing.layoutPdf(onLayout: (format) async => doc.save());
    }
    Future<void> _generateTaskPdf() async {
      final doc = pw.Document();
      final stageLabel = widget.stage.replaceAll('_', ' ').toUpperCase();
      final generatedAt = DateTime.now().toLocal().toString();
      final rows = taskRows
          .map(
            (r) => [
              '${r['employee'] ?? ''}',
              '${r['tasks'] ?? ''}',
              '${r['schedule_of_tasks'] ?? ''}',
              '${r['budget'] ?? ''}',
              '${r['status'] ?? 'not done'}',
            ],
          )
          .toList();
      doc.addPage(
        pw.MultiPage(
          build: (ctx) => [
            pw.Text('Task Assignment', style: pw.TextStyle(fontSize: 18, fontWeight: pw.FontWeight.bold)),
            pw.SizedBox(height: 6),
            pw.Text('Event: ${row.eventTitle.isEmpty ? row.customerName : row.eventTitle}'),
            pw.Text('Customer: ${row.customerName}'),
            pw.Text('Stage: $stageLabel'),
            pw.Text('Generated: $generatedAt'),
            pw.SizedBox(height: 10),
            pw.TableHelper.fromTextArray(
              headers: const ['Employee', 'Task', 'Schedule of Task', 'Budget', 'Status'],
              data: rows.isEmpty ? const [['', 'No task assignment rows.', '', '', '']] : rows,
            ),
          ],
        ),
      );
      await Printing.layoutPdf(onLayout: (format) async => doc.save());
    }
    Future<void> _generateInvoicePdf() async {
      final bytes = await _buildOrderSummaryPdfBytes(additionalCostsForPdf: additionalCosts);
      await Printing.layoutPdf(onLayout: (_) async => bytes);
    }
    Future<void> _openChecklistEditor() async {
      final draft = checklistRows.map((e) => Map<String, dynamic>.from(e)).toList();
      final saved = await showDialog<bool>(
        context: context,
        builder: (ctx) => StatefulBuilder(
          builder: (ctx, setDialogState) => AlertDialog(
            title: const Text('Checklist Editor'),
            content: SizedBox(
              width: 760,
              child: SingleChildScrollView(
                child: Column(
                  children: [
                    ...draft.asMap().entries.map((entry) {
                      final i = entry.key;
                      final r = entry.value;
                      return Card(
                        margin: const EdgeInsets.only(bottom: 8),
                        child: Padding(
                          padding: const EdgeInsets.all(10),
                          child: Column(
                            children: [
                              TextField(
                                controller: TextEditingController(text: '${r['item'] ?? ''}'),
                                decoration: const InputDecoration(labelText: 'Item'),
                                onChanged: (v) => r['item'] = v,
                              ),
                              const SizedBox(height: 6),
                              TextField(
                                controller: TextEditingController(text: '${r['description'] ?? ''}'),
                                decoration: const InputDecoration(labelText: 'Description'),
                                onChanged: (v) => r['description'] = v,
                              ),
                              const SizedBox(height: 6),
                              Row(
                                children: [
                                  Expanded(
                                    child: TextField(
                                      controller: TextEditingController(text: '${r['quantity'] ?? ''}'),
                                      decoration: const InputDecoration(labelText: 'Quantity'),
                                      onChanged: (v) => r['quantity'] = v,
                                    ),
                                  ),
                                  const SizedBox(width: 8),
                                  Expanded(
                                    child: TextField(
                                      controller: TextEditingController(text: '${r['cost'] ?? ''}'),
                                      decoration: const InputDecoration(labelText: 'Cost'),
                                      onChanged: (v) => r['cost'] = v,
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 6),
                              DropdownButtonFormField<String>(
                                value: ('${r['status'] ?? 'not done'}' == 'completed') ? 'completed' : 'not done',
                                items: const [
                                  DropdownMenuItem(value: 'not done', child: Text('not done')),
                                  DropdownMenuItem(value: 'completed', child: Text('completed')),
                                ],
                                onChanged: (v) => r['status'] = v ?? 'not done',
                              ),
                              Align(
                                alignment: Alignment.centerRight,
                                child: IconButton(
                                  onPressed: () => setDialogState(() => draft.removeAt(i)),
                                  icon: const Icon(Icons.delete_outline),
                                ),
                              ),
                            ],
                          ),
                        ),
                      );
                    }),
                    Align(
                      alignment: Alignment.centerLeft,
                      child: TextButton.icon(
                        onPressed: () => setDialogState(() {
                          draft.add({'item': '', 'description': '', 'quantity': '', 'cost': '', 'status': 'not done'});
                        }),
                        icon: const Icon(Icons.add),
                        label: const Text('Add row'),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            actions: [
              TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
              FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Save')),
            ],
          ),
        ),
      );
      if (saved == true) {
        setState(() {
          checklistRows
            ..clear()
            ..addAll(draft);
          checklistRowsOriginal
            ..clear()
            ..addAll(draft.map((e) => Map<String, dynamic>.from(e)));
        });
      }
    }
    Future<void> _openTaskEditor() async {
      final draft = taskRows.map((e) => Map<String, dynamic>.from(e)).toList();
      final saved = await showDialog<bool>(
        context: context,
        builder: (ctx) => StatefulBuilder(
          builder: (ctx, setDialogState) => AlertDialog(
            title: const Text('Task Assignment Editor'),
            content: SizedBox(
              width: 760,
              child: SingleChildScrollView(
                child: Column(
                  children: [
                    ...draft.asMap().entries.map((entry) {
                      final i = entry.key;
                      final r = entry.value;
                      return Card(
                        margin: const EdgeInsets.only(bottom: 8),
                        child: Padding(
                          padding: const EdgeInsets.all(10),
                          child: Column(
                            children: [
                              TextField(
                                controller: TextEditingController(text: '${r['employee'] ?? ''}'),
                                decoration: const InputDecoration(labelText: 'Employee'),
                                onChanged: (v) => r['employee'] = v,
                              ),
                              const SizedBox(height: 6),
                              TextField(
                                controller: TextEditingController(text: '${r['tasks'] ?? ''}'),
                                decoration: const InputDecoration(labelText: 'Task'),
                                onChanged: (v) => r['tasks'] = v,
                              ),
                              const SizedBox(height: 6),
                              Builder(
                                builder: (context) {
                                  final scheduleCtrl = TextEditingController(text: '${r['schedule_of_tasks'] ?? ''}');
                                  return TextField(
                                    controller: scheduleCtrl,
                                    readOnly: true,
                                    decoration: const InputDecoration(
                                      labelText: 'Schedule of Task',
                                      suffixIcon: Icon(Icons.calendar_month_outlined),
                                    ),
                                    onTap: () async {
                                      DateTime initial = DateTime.now();
                                      final existing = '${r['schedule_of_tasks'] ?? ''}'.trim();
                                      final parsed = DateTime.tryParse(existing);
                                      if (parsed != null) initial = parsed;
                                      final d = await showDatePicker(
                                        context: context,
                                        initialDate: initial,
                                        firstDate: DateTime(2020, 1, 1),
                                        lastDate: DateTime(2100, 12, 31),
                                      );
                                      if (d == null) return;
                                      final dateText =
                                          '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
                                      setDialogState(() {
                                        r['schedule_of_tasks'] = dateText;
                                      });
                                    },
                                  );
                                },
                              ),
                              const SizedBox(height: 6),
                              TextField(
                                controller: TextEditingController(text: '${r['budget'] ?? ''}'),
                                decoration: const InputDecoration(labelText: 'Budget'),
                                onChanged: (v) => r['budget'] = v,
                              ),
                              const SizedBox(height: 6),
                              DropdownButtonFormField<String>(
                                value: ('${r['status'] ?? 'not done'}' == 'completed') ? 'completed' : 'not done',
                                items: const [
                                  DropdownMenuItem(value: 'not done', child: Text('not done')),
                                  DropdownMenuItem(value: 'completed', child: Text('completed')),
                                ],
                                onChanged: (v) => r['status'] = v ?? 'not done',
                              ),
                              Align(
                                alignment: Alignment.centerRight,
                                child: IconButton(
                                  onPressed: () => setDialogState(() => draft.removeAt(i)),
                                  icon: const Icon(Icons.delete_outline),
                                ),
                              ),
                            ],
                          ),
                        ),
                      );
                    }),
                    Align(
                      alignment: Alignment.centerLeft,
                      child: TextButton.icon(
                        onPressed: () => setDialogState(() {
                          draft.add({
                            'employee': '',
                            'tasks': '',
                            'schedule_of_tasks': '',
                            'budget': '',
                            'status': 'not done',
                          });
                        }),
                        icon: const Icon(Icons.add),
                        label: const Text('Add task and schedule'),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            actions: [
              TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
              FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Save')),
            ],
          ),
        ),
      );
      if (saved == true) {
        setState(() {
          taskRows
            ..clear()
            ..addAll(draft);
          taskRowsOriginal
            ..clear()
            ..addAll(draft.map((e) => Map<String, dynamic>.from(e)));
        });
      }
    }
    String? _validateDraftScheduleCoherence() {
      if (widget.stage != 'new_event' && widget.stage != 'online_inquiries') return null;
      for (final w in _eventWindows) {
        final any = w.date != null || w.from != null || w.to != null;
        final all = w.date != null && w.from != null && w.to != null;
        if (any && !all) {
          return 'Complete date, start time, and end time for each schedule row (or remove the row).';
        }
      }
      final filled = _eventWindows.where((x) => x.date != null && x.from != null && x.to != null).toList();
      for (final w in filled) {
        final sm = w.from!.hour * 60 + w.from!.minute;
        final em = w.to!.hour * 60 + w.to!.minute;
        if (em <= sm) return 'End time must be after start time for each event window.';
      }
      return null;
    }

    String? _validateDraftReadyForNextStage() {
      final sch = _validateDraftScheduleCoherence();
      if (sch != null) return sch;
      if (widget.stage != 'new_event' && widget.stage != 'online_inquiries') return null;
      final kind = d.orderKind;
      final et =
          managerEventTypeChoice == 'Other' ? managerEventTypeOtherController.text.trim() : managerEventTypeChoice;
      if (et.trim().isEmpty) return 'Choose or describe the event type.';
      if (managerEventTypeChoice == 'Other' && managerEventTypeOtherController.text.trim().isEmpty) {
        return 'Describe the event type for Other.';
      }
      if (kind == 'event' && managerDraftEventTitleController.text.trim().isEmpty) {
        return 'Enter an event title for Catering + Event.';
      }
      final gc = int.tryParse(managerGuestCountController.text.trim());
      if (gc == null || gc < 1) return 'Enter a valid number of guests.';
      final minPax = kind == 'event' ? kMinCateringEventPax : kMinCateringOnlyPax;
      if (gc < minPax) return 'Minimum guests for this inquiry type is $minPax.';
      final complete = _eventWindows.where((x) => x.date != null && x.from != null && x.to != null).toList();
      if (complete.isEmpty) return 'Add at least one event date with start and end time.';
      if (selectedDishes.isEmpty) return 'Select at least one dish for the menu.';
      return null;
    }

    Future<void> submitNext() async {
      final target = widget.stage == 'online_inquiries'
          ? 'for_processing'
          : widget.stage == 'new_event'
              ? 'for_processing'
          : widget.stage == 'for_processing'
          ? 'for_post_analysis'
          : widget.stage == 'for_post_analysis'
              ? 'completed'
              : '';
      if (target.isEmpty) return;
      if (!canComplete && target == 'completed') {
        appSnack(context, 'Supervisor cannot complete orders.');
        return;
      }
      final isDraftAdvance = widget.stage == 'new_event' || widget.stage == 'online_inquiries';
      if (isDraftAdvance) {
        final verr = _validateDraftReadyForNextStage();
        if (verr != null) {
          appSnack(context, verr);
          return;
        }
      }
      if (isDraftAdvance && _draftOrderKind != d.orderKind) {
        final errSwitch = await widget.state.managerSwitchCateringOrderKind(
          id: d.id,
          fromKind: d.orderKind,
          toKind: _draftOrderKind,
        );
        if (!mounted) return;
        if (errSwitch != null) {
          appSnack(context, errSwitch);
          return;
        }
        final migrated = await widget.state.loadManagerCateringItem(
          id: d.id,
          orderKind: _draftOrderKind,
        );
        if (!mounted) return;
        if (migrated != null) {
          setState(() => _loadedDetailRow = migrated);
        }
      }
      final rowSubmit = d;
      final downPayment = double.tryParse(downPaymentController.text.trim());
      final downPaymentPaid = double.tryParse(downPaymentPaidController.text.trim());
      final fullPayment = double.tryParse(fullPaymentController.text.trim());
      final postAnalysis = <String, dynamic>{
        'notes': analysisController.text.trim(),
        'task_assignment': taskAssignmentController.text.trim(),
        'task_assignment_rows': taskRows,
        'business_cards_given': businessCardsController.text.trim(),
        'on_the_spot_inquiries': spotInquiriesController.text.trim(),
        'complaints': complaintsController.text.trim(),
        'most_popular_dish': popularDishController.text.trim(),
        'most_popular_drink': popularDrinkController.text.trim(),
        'most_popular_dessert': popularDessertController.text.trim(),
        'labor_male_count': int.tryParse(laborMaleController.text.trim()) ?? 0,
        'labor_female_count': int.tryParse(laborFemaleController.text.trim()) ?? 0,
        'labor_manual_costs': laborManualCosts,
        if (rowSubmit.postAnalysis['manager_full_payment_confirmed'] == true) 'manager_full_payment_confirmed': true,
        if (rowSubmit.postAnalysis['additional_costs_payment_confirmed'] == true)
          'additional_costs_payment_confirmed': true,
        if (isOnlineInquiry || widget.stage == 'new_event')
          'event_type': managerEventTypeChoice == 'Other'
              ? managerEventTypeOtherController.text.trim()
              : managerEventTypeChoice,
      };
      if (_managerDownPaymentProofBytes != null) {
        postAnalysis['manager_down_payment_proof_b64'] = base64Encode(_managerDownPaymentProofBytes!);
      }
      if (_managerFullPaymentProofBytes != null) {
        postAnalysis['manager_full_payment_proof_b64'] = base64Encode(_managerFullPaymentProofBytes!);
      }
      final laborForSubmit = isProcessing ? 0.0 : laborCostComputed;
      final travelForSubmit = isProcessing ? 0.0 : _travelCostComputed();
      final invoiceTotalSubmit = isProcessing
          ? (_baseFoodCost() + _sumCostRows(themeDesignCosts) + _sumCostRows(additionalCosts))
          : totalComputed;
      final themeDesign = <String, dynamic>{
        ...rowSubmit.themeDesign,
        'cost_items': themeDesignCosts,
        'service_included': managerServiceIncluded,
        'note': managerInquiryNoteController.text.trim(),
        'event_title': managerDraftEventTitleController.text.trim(),
        'event_type':
            managerEventTypeChoice == 'Other' ? managerEventTypeOtherController.text.trim() : managerEventTypeChoice,
        'event_setting': managerEventSetting,
        'formality_level': managerFormalityLevel,
      };
      final costBreakdown = <Map<String, dynamic>>[
        {'label': 'Base food cost', 'amount': _baseFoodCost()},
        {'label': 'Labor cost', 'amount': laborForSubmit},
        {'label': 'Travel cost', 'amount': travelForSubmit},
        {'label': 'Theme design cost', 'amount': _sumCostRows(themeDesignCosts)},
        {'label': 'Additional costs', 'amount': _sumCostRows(additionalCosts)},
      ];
      final confirm = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Confirm submission'),
          content: Text('Proceed to ${target == 'completed' ? 'Completed' : 'next stage'}?'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
            FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Confirm')),
          ],
        ),
      );
      if (confirm != true) return;
      if (target == 'completed') {
        if (!cateringFullPaymentConfirmed(rowSubmit, totalComputed)) {
          appSnack(context, 'Full payment confirmation is required before completing this order.');
          return;
        }
      }
      final err = await widget.state.managerAdvanceCateringStage(
        id: rowSubmit.id,
        orderKind: rowSubmit.orderKind,
        status: target,
        downPaymentAmount: isProcessing
            ? (downPaymentPaid ?? downPayment ?? (invoiceTotalSubmit * 0.5))
            : null,
        fullPaymentAmount: (isPost && target != 'completed') ? (fullPayment ?? totalComputed) : null,
        postAnalysis:
            (isProcessing || isPost || isOnlineInquiry || widget.stage == 'new_event') ? postAnalysis : null,
        checklist: checklistRows.map((e) => Map<String, dynamic>.from(e)).toList(),
        actualEventImages: actualEventImages.isEmpty ? null : actualEventImages,
        additionalCosts: additionalCosts,
        laborCost: laborForSubmit,
        travelCost: travelForSubmit,
        totalCost: invoiceTotalSubmit,
        costBreakdown: costBreakdown,
        themeDesign: themeDesign,
        menu: selectedDishes.isEmpty ? rowSubmit.menu : selectedDishes.toList(),
      );
      if (!mounted) return;
      if (err != null) {
        appSnack(context, err);
        return;
      }
      appSnack(context, target == 'completed' ? 'Order completed' : 'Moved to next stage');
      await widget.state.loadManagerCateringByStage(widget.stage, force: true);
      if (mounted) Navigator.of(context).pop();
    }
    Future<void> saveCurrentStage() async {
      final isProcessingHere = widget.stage == 'for_processing';
      final laborCostComputedNow = isProcessingHere ? 0.0 : _laborCostComputed();
      final travelNow = isProcessingHere ? 0.0 : _travelCostComputed();
      final totalNow = isProcessingHere
          ? (_baseFoodCost() + _sumCostRows(themeDesignCosts) + _sumCostRows(additionalCosts))
          : _grandTotalComputed();
      final et =
          managerEventTypeChoice == 'Other' ? managerEventTypeOtherController.text.trim() : managerEventTypeChoice;

      final isDraftStageHere = widget.stage == 'new_event' || widget.stage == 'online_inquiries';
      if (isDraftStageHere) {
        final verr = _validateDraftScheduleCoherence();
        if (verr != null) {
          appSnack(context, verr);
          return;
        }
      }
      if (isDraftStageHere && _draftOrderKind != d.orderKind) {
        final errSwitch = await widget.state.managerSwitchCateringOrderKind(
          id: d.id,
          fromKind: d.orderKind,
          toKind: _draftOrderKind,
        );
        if (!mounted) return;
        if (errSwitch != null) {
          appSnack(context, errSwitch);
          return;
        }
        final migrated = await widget.state.loadManagerCateringItem(
          id: d.id,
          orderKind: _draftOrderKind,
        );
        if (!mounted) return;
        if (migrated != null) {
          setState(() => _loadedDetailRow = migrated);
        }
      }

      final rowBase = d;
      final postAnalysis = <String, dynamic>{
        'notes': analysisController.text.trim(),
        'task_assignment': taskAssignmentController.text.trim(),
        'task_assignment_rows': taskRows,
        'business_cards_given': businessCardsController.text.trim(),
        'on_the_spot_inquiries': spotInquiriesController.text.trim(),
        'complaints': complaintsController.text.trim(),
        'most_popular_dish': popularDishController.text.trim(),
        'most_popular_drink': popularDrinkController.text.trim(),
        'most_popular_dessert': popularDessertController.text.trim(),
        'labor_male_count': int.tryParse(laborMaleController.text.trim()) ?? 0,
        'labor_female_count': int.tryParse(laborFemaleController.text.trim()) ?? 0,
        'labor_manual_costs': laborManualCosts,
        if (rowBase.postAnalysis['manager_full_payment_confirmed'] == true) 'manager_full_payment_confirmed': true,
        if (rowBase.postAnalysis['additional_costs_payment_confirmed'] == true)
          'additional_costs_payment_confirmed': true,
        if (isOnlineInquiry || widget.stage == 'new_event') 'event_type': et,
      };
      if (_managerDownPaymentProofBytes != null) {
        postAnalysis['manager_down_payment_proof_b64'] = base64Encode(_managerDownPaymentProofBytes!);
      }
      if (_managerFullPaymentProofBytes != null) {
        postAnalysis['manager_full_payment_proof_b64'] = base64Encode(_managerFullPaymentProofBytes!);
      }
      final themeDesign = <String, dynamic>{
        ...rowBase.themeDesign,
        'cost_items': themeDesignCosts,
        'service_included': managerServiceIncluded,
        'note': managerInquiryNoteController.text.trim(),
        'event_title': managerDraftEventTitleController.text.trim(),
        'event_type': et,
        'event_setting': managerEventSetting,
        'formality_level': managerFormalityLevel,
      };

      if (isDraftStageHere) {
        final gc = int.tryParse(managerGuestCountController.text.trim());
        final err = await widget.state.managerSaveCateringDraft(
          id: rowBase.id,
          orderKind: rowBase.orderKind,
          draft: {
            'post_analysis': postAnalysis,
            'checklist': checklistRows.map((e) => Map<String, dynamic>.from(e)).toList(),
            'theme_design': themeDesign,
            'schedule_slots': _scheduleSlotsPayload(),
            // Needed for event_orders so the list endpoint can populate columns for later stages.
            'event_title': managerDraftEventTitleController.text.trim(),
            'event_type': et,
            'formality_level': managerFormalityLevel,
            'menu': selectedDishes.isEmpty ? rowBase.menu : selectedDishes.toList(),
            'additional_costs': additionalCosts,
            'labor_cost': laborCostComputedNow,
            'travel_cost': travelNow,
            'total_cost': totalNow,
            'cost_breakdown': [
              {'label': 'Base food cost', 'amount': _baseFoodCost()},
              {'label': 'Labor cost', 'amount': laborCostComputedNow},
              {'label': 'Travel cost', 'amount': travelNow},
              {'label': 'Theme design cost', 'amount': _sumCostRows(themeDesignCosts)},
              {'label': 'Additional costs', 'amount': _sumCostRows(additionalCosts)},
            ],
            if (gc != null && gc >= 0) 'guest_count': gc,
          },
        );
        if (!mounted) return;
        if (err != null) {
          appSnack(context, err);
          return;
        }
        appSnack(context, 'Draft saved');
        try {
          final p = await SharedPreferences.getInstance();
          await p.remove(_localDraftKey);
        } catch (_) {}
        await widget.state.loadManagerCateringByStage(widget.stage, force: true);
        return;
      }

      final err = await widget.state.managerAdvanceCateringStage(
        id: rowBase.id,
        orderKind: rowBase.orderKind,
        status: widget.stage,
        downPaymentAmount: isProcessing ? (double.tryParse(downPaymentPaidController.text.trim()) ?? downPaymentDue) : null,
        // Post-analysis full payment is confirmed via [managerPatchCateringPostAnalysis] (manager only), not by setting amounts here.
        fullPaymentAmount: null,
        postAnalysis: (isProcessing || isPost || isOnlineInquiry) ? postAnalysis : null,
        checklist: checklistRows.map((e) => Map<String, dynamic>.from(e)).toList(),
        additionalCosts: additionalCosts,
        laborCost: laborCostComputedNow,
        travelCost: travelNow,
        totalCost: totalNow,
        costBreakdown: [
          {'label': 'Base food cost', 'amount': _baseFoodCost()},
          {'label': 'Labor cost', 'amount': laborCostComputedNow},
          {'label': 'Travel cost', 'amount': travelNow},
          {'label': 'Theme design cost', 'amount': _sumCostRows(themeDesignCosts)},
          {'label': 'Additional costs', 'amount': _sumCostRows(additionalCosts)},
        ],
        themeDesign: themeDesign,
        menu: selectedDishes.isEmpty ? rowBase.menu : selectedDishes.toList(),
      );
      if (!mounted) return;
      appSnack(context, err ?? 'Changes saved');
      if (err == null) {
        await widget.state.loadManagerCateringByStage(widget.stage, force: true);
      }
    }
    return Scaffold(
      appBar: AppBar(title: Text(row.eventTitle.isEmpty ? row.customerName : row.eventTitle)),
      body: ListView(
        padding: const EdgeInsets.all(12),
        children: [
          if (row.cateringLoyaltyPointsEarned > 0 && row.status.trim().toLowerCase() == 'completed')
            Card(
              color: Colors.amber.shade50,
              child: ListTile(
                leading: const Icon(Icons.card_giftcard_outlined),
                title: Text(
                  'Catering loyalty applied: +${row.cateringLoyaltyPointsEarned} pts',
                  style: const TextStyle(fontWeight: FontWeight.w700),
                ),
              ),
            )
          else if (row.status.trim().toLowerCase() != 'completed' &&
              row.cateringLoyaltyEligiblePointsIfCompleted > 0)
            Card(
              child: ListTile(
                leading: Icon(Icons.stars_outlined, color: Colors.blue.shade700),
                title: const Text('Catering loyalty (if completed at this total)'),
                subtitle: Text(
                  '+${row.cateringLoyaltyEligiblePointsIfCompleted} pts — minimum order ₱${kCateringLoyaltyMinOrderTotal.toStringAsFixed(0)}',
                ),
              ),
            ),
          if (isProcessing)
            Card(
              color: Colors.orange.shade50,
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(
                      isOnlineInquiry ? 'Costing and Payment' : 'Down Payment',
                      style: const TextStyle(fontWeight: FontWeight.w800),
                    ),
                    const SizedBox(height: 8),
                    Text('Amount due (50% of total): ₱${downPaymentDue.toStringAsFixed(2)}'),
                    const SizedBox(height: 8),
                    TextField(
                      controller: downPaymentController,
                      keyboardType: TextInputType.number,
                      readOnly: true,
                      decoration: const InputDecoration(labelText: 'Downpayment amount due'),
                    ),
                    const SizedBox(height: 8),
                    TextField(
                      controller: downPaymentPaidController,
                      keyboardType: TextInputType.number,
                      readOnly: !isProcessing,
                      decoration: const InputDecoration(labelText: 'Downpayment amount paid (manual input)'),
                    ),
                    const SizedBox(height: 10),
                    const Text('Proof of down payment (GCash)', style: TextStyle(fontWeight: FontWeight.w700)),
                    const SizedBox(height: 6),
                    Row(
                      children: [
                        Expanded(
                          child: OutlinedButton.icon(
                            onPressed: !isProcessing
                                ? null
                                : () async {
                                    final x = await ImagePicker().pickImage(source: ImageSource.gallery);
                                    if (x == null || !mounted) return;
                                    final b = await x.readAsBytes();
                                    setState(() => _managerDownPaymentProofBytes = b);
                                  },
                            icon: const Icon(Icons.upload_file, size: 18),
                            label: const Text('Upload'),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: OutlinedButton.icon(
                            onPressed: !isProcessing
                                ? null
                                : () async {
                                    final x = await ImagePicker().pickImage(source: ImageSource.camera);
                                    if (x == null || !mounted) return;
                                    final b = await x.readAsBytes();
                                    setState(() => _managerDownPaymentProofBytes = b);
                                  },
                            icon: const Icon(Icons.photo_camera_outlined, size: 18),
                            label: const Text('Camera'),
                          ),
                        ),
                      ],
                    ),
                    if (_managerDownPaymentProofBytes != null) ...[
                      const SizedBox(height: 8),
                      ClipRRect(
                        borderRadius: BorderRadius.circular(8),
                        child: Image.memory(_managerDownPaymentProofBytes!, height: 120, fit: BoxFit.contain),
                      ),
                    ],
                    const SizedBox(height: 10),
                    FilledButton(
                      onPressed: !isProcessing
                          ? null
                          : () async {
                              setState(() {
                                downPaymentPaidController.text = downPaymentDue.toStringAsFixed(2);
                              });
                              await saveCurrentStage();
                              if (mounted) appSnack(context, 'Down payment amount saved');
                            },
                      child: const Text('Confirm down payment'),
                    ),
                  ],
                ),
              ),
            ),
          if (isPost || isCompleted)
            Card(
              color: Colors.green.shade50,
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const Text('Full Payment', style: TextStyle(fontWeight: FontWeight.w800)),
                    const SizedBox(height: 8),
                    TextField(
                      controller: downPaymentPaidController,
                      readOnly: true,
                      decoration: const InputDecoration(labelText: 'Down payment paid'),
                    ),
                    const SizedBox(height: 8),
                    Builder(
                      builder: (ctx) {
                        final balanceDue =
                            totalComputed - (double.tryParse(downPaymentPaidController.text.trim()) ?? 0);
                        return Container(
                          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                          decoration: BoxDecoration(
                            color: isFullPaymentConfirmed ? Colors.green.shade50 : Colors.red.shade50,
                            borderRadius: BorderRadius.circular(8),
                            border: Border.all(
                              color: isFullPaymentConfirmed ? Colors.green.shade700 : Colors.red.shade700,
                              width: 1.5,
                            ),
                          ),
                          child: Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              const Text('Balance amount due', style: TextStyle(fontWeight: FontWeight.w600)),
                              Text(
                                'PHP ${balanceDue.toStringAsFixed(2)}',
                                style: TextStyle(
                                  fontWeight: FontWeight.w800,
                                  fontSize: 16,
                                  color: isFullPaymentConfirmed ? Colors.green.shade900 : Colors.red.shade900,
                                ),
                              ),
                            ],
                          ),
                        );
                      },
                    ),
                    const SizedBox(height: 8),
                    TextField(
                      controller: fullPaymentController,
                      keyboardType: TextInputType.number,
                      readOnly: true,
                      decoration: const InputDecoration(labelText: 'Full payment amount'),
                    ),
                    const SizedBox(height: 10),
                    const Text('Proof of full payment (GCash)', style: TextStyle(fontWeight: FontWeight.w700)),
                    const SizedBox(height: 6),
                    Row(
                      children: [
                        Expanded(
                          child: OutlinedButton.icon(
                            onPressed: !isPost
                                ? null
                                : () async {
                                    final x = await ImagePicker().pickImage(source: ImageSource.gallery);
                                    if (x == null || !mounted) return;
                                    final b = await x.readAsBytes();
                                    setState(() => _managerFullPaymentProofBytes = b);
                                  },
                            icon: const Icon(Icons.upload_file, size: 18),
                            label: const Text('Upload'),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: OutlinedButton.icon(
                            onPressed: !isPost
                                ? null
                                : () async {
                                    final x = await ImagePicker().pickImage(source: ImageSource.camera);
                                    if (x == null || !mounted) return;
                                    final b = await x.readAsBytes();
                                    setState(() => _managerFullPaymentProofBytes = b);
                                  },
                            icon: const Icon(Icons.photo_camera_outlined, size: 18),
                            label: const Text('Camera'),
                          ),
                        ),
                      ],
                    ),
                    if (_managerFullPaymentProofBytes != null) ...[
                      const SizedBox(height: 8),
                      ClipRRect(
                        borderRadius: BorderRadius.circular(8),
                        child: Image.memory(_managerFullPaymentProofBytes!, height: 120, fit: BoxFit.contain),
                      ),
                    ],
                    const SizedBox(height: 8),
                    FilledButton(
                      onPressed: (!widget.state.isManager || !isPost || isFullPaymentConfirmed)
                          ? null
                          : () async {
                              final balanceDue =
                                  totalComputed - (double.tryParse(downPaymentPaidController.text.trim()) ?? 0);
                              final ok = await showDialog<bool>(
                                context: context,
                                builder: (dlgCtx) => AlertDialog(
                                  title: const Text('Confirm full payment'),
                                  content: Text(
                                    'Confirm that full payment of PHP ${balanceDue.toStringAsFixed(2)} has been received?',
                                  ),
                                  actions: [
                                    TextButton(onPressed: () => Navigator.pop(dlgCtx, false), child: const Text('Cancel')),
                                    FilledButton(
                                      onPressed: () => Navigator.pop(dlgCtx, true),
                                      child: const Text('Confirm'),
                                    ),
                                  ],
                                ),
                              );
                              if (ok != true || !mounted) return;
                              final err = await widget.state.managerPatchCateringPostAnalysis(
                                id: row.id,
                                orderKind: row.orderKind,
                                patch: {'manager_full_payment_confirmed': true},
                              );
                              if (!mounted) return;
                              if (err != null) {
                                appSnack(context, err);
                                return;
                              }
                              final full = await widget.state.loadManagerCateringItem(
                                id: row.id,
                                orderKind: row.orderKind,
                              );
                              if (!mounted) return;
                              if (full != null) setState(() => _loadedDetailRow = full);
                              appSnack(context, 'Full payment confirmed');
                            },
                      child: Text(isFullPaymentConfirmed ? 'FULLY PAID' : 'Confirm Full Payment'),
                    ),
                    const SizedBox(height: 12),
                    Container(
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(8),
                        color: Colors.blueGrey.shade50,
                        border: Border.all(color: Colors.blueGrey.shade100),
                      ),
                      child: const Text(
                        'Post-analysis section has been removed. Use this stage for full payment confirmation only.',
                      ),
                    ),
                  ],
                ),
              ),
            ),
          if (isProcessing || isPost || isCompleted)
            Card(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const Text('Checklist and Task Assignment', style: TextStyle(fontWeight: FontWeight.w800)),
                    const SizedBox(height: 8),
                    Text(
                      isProcessing
                          ? 'Open each section in a separate window for easier card-based editing.'
                          : 'PDF generation is available in this stage. Editing is disabled.',
                    ),
                    const SizedBox(height: 10),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        if (isProcessing) ...[
                          OutlinedButton(onPressed: _openChecklistEditor, child: const Text('Open Checklist Editor')),
                          OutlinedButton(onPressed: _openTaskEditor, child: const Text('Open Task Assignment Editor')),
                        ],
                        OutlinedButton(onPressed: _generateChecklistPdf, child: const Text('Generate Checklist PDF')),
                        OutlinedButton(onPressed: _generateTaskPdf, child: const Text('Generate Task Assignment PDF')),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('Event Information', style: TextStyle(fontWeight: FontWeight.w800)),
                  const SizedBox(height: 8),
                  if (!isDraftStage) ...[
                    Text('Order type: ${row.orderKind == 'catering' ? 'Catering Only' : 'Catering + Event'}'),
                    if (row.transactionNo.trim().isNotEmpty) Text('Transaction No.: ${row.transactionNo}'),
                    Text('Event: ${row.eventTitle.trim().isEmpty ? row.customerName : row.eventTitle}'),
                    Text('Customer: ${row.customerName}'),
                    Text('Contact person: ${row.contactPerson}'),
                    Text('Contact number: ${row.contactNumber}'),
                    Text('Email: ${row.emailAddress}'),
                    Text('Address: ${row.address}'),
                    Text('Guests: ${row.guestCount}'),
                    Text('Payment method: ${row.paymentMethod}'),
                    Text('Labor cost: ₱${laborCostComputed.toStringAsFixed(2)}'),
                    Text('Travel cost: ₱${_travelCostComputed().toStringAsFixed(2)}'),
                    if (row.formalityLevel.trim().isNotEmpty) Text('Formality: ${row.formalityLevel}'),
                    if (row.scheduleSlots.isNotEmpty) ...[
                      const SizedBox(height: 6),
                      if (isProcessing || isPost) ...[
                        Text(
                          'Date & time of event',
                          style: Theme.of(context).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700),
                        ),
                        const SizedBox(height: 6),
                        ..._buildLabeledScheduleRows(row.scheduleSlots),
                        if (isProcessing && row.processingScheduleOverlaps > 0) ...[
                          const SizedBox(height: 8),
                          Text(
                            'This date and time conflicts with another event in For Processing.',
                            style: TextStyle(color: Colors.red.shade800, fontWeight: FontWeight.w600),
                          ),
                        ],
                      ] else ...[
                        for (final s in row.scheduleSlots)
                          for (final line in formatScheduleSlotLine(s).split('\n'))
                            if (line.trim().isNotEmpty) Text(line.trim()),
                      ],
                    ],
                  ] else ...[
                    DropdownButtonFormField<String>(
                      value: _draftOrderKind == 'catering' ? 'CATERING' : 'CATERING AND EVENT',
                      decoration: const InputDecoration(
                        labelText: 'Inquiry type',
                        helperText: 'Changing type moves this record between catering-only and full event tables when you save.',
                      ),
                      items: const [
                        DropdownMenuItem(value: 'CATERING', child: Text('CATERING')),
                        DropdownMenuItem(value: 'CATERING AND EVENT', child: Text('CATERING AND EVENT')),
                      ],
                      onChanged: canEditStage
                          ? (v) => setState(() {
                                _draftOrderKind = v == 'CATERING' ? 'catering' : 'event';
                                _saveLocalDraftDebounced();
                              })
                          : null,
                    ),
                    const SizedBox(height: 8),
                    DropdownButtonFormField<String>(
                      value: kMobileEventTypeChoices.contains(managerEventTypeChoice) ? managerEventTypeChoice : 'Other',
                      decoration: const InputDecoration(labelText: 'Event type'),
                      items: kMobileEventTypeChoices.map((e) => DropdownMenuItem(value: e, child: Text(e))).toList(),
                      onChanged: canEditStage
                          ? (v) => setState(() {
                                managerEventTypeChoice = v ?? 'Other';
                                _saveLocalDraftDebounced();
                              })
                          : null,
                    ),
                    if (managerEventTypeChoice == 'Other') ...[
                      const SizedBox(height: 8),
                      TextFormField(
                        controller: managerEventTypeOtherController,
                        readOnly: !canEditStage,
                        decoration: const InputDecoration(labelText: 'Describe event type'),
                      ),
                    ],
                    const SizedBox(height: 8),
                    const Text('Event setting', style: TextStyle(fontWeight: FontWeight.w600)),
                    RadioListTile<String>(
                      value: 'open',
                      groupValue: managerEventSetting,
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      title: const Text('Open space'),
                      onChanged: canEditStage
                          ? (v) => setState(() {
                                managerEventSetting = v ?? 'open';
                                _saveLocalDraftDebounced();
                              })
                          : null,
                    ),
                    RadioListTile<String>(
                      value: 'closed',
                      groupValue: managerEventSetting,
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      title: const Text('Closed space'),
                      onChanged: canEditStage
                          ? (v) => setState(() {
                                managerEventSetting = v ?? 'open';
                                _saveLocalDraftDebounced();
                              })
                          : null,
                    ),
                    const SizedBox(height: 8),
                    TextField(
                      controller: managerDraftEventTitleController,
                      readOnly: !canEditStage,
                      decoration: const InputDecoration(labelText: 'Event title'),
                    ),
                    const SizedBox(height: 8),
                    TextFormField(
                      readOnly: !canEditStage,
                      initialValue: row.contactPerson,
                      decoration: const InputDecoration(labelText: 'Contact person'),
                    ),
                    const SizedBox(height: 8),
                    TextFormField(
                      readOnly: !canEditStage,
                      initialValue: row.contactNumber,
                      decoration: const InputDecoration(labelText: 'Contact number'),
                    ),
                    const SizedBox(height: 8),
                    TextFormField(
                      readOnly: !canEditStage,
                      initialValue: row.emailAddress,
                      decoration: const InputDecoration(labelText: 'Email address'),
                    ),
                    const SizedBox(height: 8),
                    TextFormField(
                      readOnly: !canEditStage,
                      initialValue: row.address,
                      decoration: const InputDecoration(labelText: 'Event venue'),
                    ),
                    const SizedBox(height: 8),
                    const Text('Date & time of event', style: TextStyle(fontWeight: FontWeight.w600)),
                    const SizedBox(height: 4),
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        for (int i = 0; i < _eventWindows.length; i++)
                          Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              Row(
                                children: [
                                  Expanded(
                                    child: OutlinedButton(
                                      onPressed: canEditStage ? () => _pickWindowDate(i) : null,
                                      child: Text(
                                        _eventWindows[i].date == null
                                            ? 'Pick date'
                                            : '${_eventWindows[i].date!.month}/${_eventWindows[i].date!.day}/${_eventWindows[i].date!.year}',
                                      ),
                                    ),
                                  ),
                                  if (canEditStage && _eventWindows.length > 1) ...[
                                    const SizedBox(width: 8),
                                    IconButton(
                                      onPressed: () => _removeWindowAt(i),
                                      icon: const Icon(Icons.delete_outline),
                                      tooltip: 'Remove window',
                                    ),
                                  ],
                                ],
                              ),
                              const SizedBox(height: 8),
                              Row(
                                children: [
                                  Expanded(
                                    child: OutlinedButton(
                                      onPressed: canEditStage ? () => _pickWindowFromTime(i) : null,
                                      child: Text(
                                        _eventWindows[i].from == null ? 'From' : _eventWindows[i].from!.format(context),
                                      ),
                                    ),
                                  ),
                                  const SizedBox(width: 8),
                                  Expanded(
                                    child: OutlinedButton(
                                      onPressed: canEditStage ? () => _pickWindowToTime(i) : null,
                                      child: Text(
                                        _eventWindows[i].to == null ? 'To' : _eventWindows[i].to!.format(context),
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 12),
                            ],
                          ),
                        if (canEditStage)
                          Align(
                            alignment: Alignment.centerLeft,
                            child: TextButton.icon(
                              onPressed: _addAnotherWindow,
                              icon: const Icon(Icons.add),
                              label: const Text('Add another window'),
                            ),
                          ),
                        if (scheduleConflictsForProcessing > 0)
                          Padding(
                            padding: const EdgeInsets.only(top: 8),
                            child: Text(
                              'Conflicts detected with an existing event in For Processing.',
                              style: TextStyle(
                                color: Colors.red.shade700,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    const SizedBox(height: 6),
                    const Text('Formality level', style: TextStyle(fontWeight: FontWeight.w600)),
                    const SizedBox(height: 6),
                    SegmentedButton<String>(
                      segments: const [
                        ButtonSegment(value: 'casual', label: Text('Casual')),
                        ButtonSegment(value: 'semiformal', label: Text('Semiformal')),
                        ButtonSegment(value: 'formal', label: Text('Formal')),
                      ],
                      selected: {managerFormalityLevel},
                      onSelectionChanged: canEditStage
                          ? (s) => setState(() {
                                managerFormalityLevel = s.first;
                                _saveLocalDraftDebounced();
                              })
                          : null,
                    ),
                    const SizedBox(height: 8),
                    TextField(
                      controller: managerGuestCountController,
                      keyboardType: TextInputType.number,
                      readOnly: !canEditStage,
                      decoration: const InputDecoration(labelText: 'Number of guests'),
                    ),
                    const SizedBox(height: 8),
                    const SizedBox(height: 6),
                    const Text('Service', style: TextStyle(fontWeight: FontWeight.w600)),
                    RadioListTile<String>(
                      value: 'yes',
                      groupValue: managerServiceIncluded,
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      title: const Text('With service'),
                      onChanged: canEditStage
                          ? (v) => setState(() {
                                managerServiceIncluded = v ?? 'no';
                                _saveLocalDraftDebounced();
                              })
                          : null,
                    ),
                    RadioListTile<String>(
                      value: 'no',
                      groupValue: managerServiceIncluded,
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      title: const Text('Without service'),
                      onChanged: canEditStage
                          ? (v) => setState(() {
                                managerServiceIncluded = v ?? 'no';
                                _saveLocalDraftDebounced();
                              })
                          : null,
                    ),
                    if (row.orderKind == 'catering') ...[
                      const SizedBox(height: 8),
                      TextField(
                        controller: managerInquiryNoteController,
                        readOnly: !canEditStage,
                        decoration: const InputDecoration(labelText: 'Note'),
                        maxLines: 3,
                      ),
                    ],
                  ],
                  const SizedBox(height: 8),
                ],
              ),
            ),
          ),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('Menu', style: TextStyle(fontWeight: FontWeight.w800)),
                  const SizedBox(height: 8),
                  if (isDraftStage) ...[
                    TextField(
                      controller: menuSearchController,
                      decoration: const InputDecoration(
                        labelText: 'Search dishes',
                        prefixIcon: Icon(Icons.search),
                      ),
                      onChanged: (_) => setState(() {}),
                    ),
                    const SizedBox(height: 8),
                    DropdownButtonFormField<String>(
                      value: selectedSetMenu,
                      items: ['All Dishes', ...widget.state.setMenus.map((m) => m.name)]
                          .map((name) => DropdownMenuItem(value: name, child: Text(name)))
                          .toList(),
                      onChanged: !canEditStage
                          ? null
                          : (v) {
                              final next = v ?? 'All Dishes';
                              setState(() {
                                selectedSetMenu = next;
                                selectedDishes.clear();
                                if (next != 'All Dishes') {
                                  final rows = widget.state.setMenus.where((m) => m.name == next).toList();
                                  if (rows.isNotEmpty) selectedDishes.addAll(rows.first.dishes);
                                }
                              });
                            },
                    ),
                    const SizedBox(height: 8),
                    SizedBox(
                      height: math.min(420, MediaQuery.sizeOf(context).height * 0.42),
                      child: ListView(
                        padding: EdgeInsets.zero,
                        children: [
                          ...(() {
                            final seen = <String>{};
                            final dishes = widget.state.menu.where((m) => m.isCateringDish).where((m) {
                              final q = menuSearchController.text.trim().toLowerCase();
                              final n = m.name.trim().toLowerCase();
                              if (n.isEmpty || seen.contains(n)) return false;
                              seen.add(n);
                              return q.isEmpty || n.contains(q);
                            }).toList();
                            dishes.sort((a, b) {
                              final sa = selectedDishes.contains(a.name) ? 0 : 1;
                              final sb = selectedDishes.contains(b.name) ? 0 : 1;
                              if (sa != sb) return sa - sb;
                              return a.name.toLowerCase().compareTo(b.name.toLowerCase());
                            });
                            return dishes;
                          }()).map((dish) {
                            final sel = selectedDishes.contains(dish.name);
                            return Padding(
                              padding: const EdgeInsets.only(bottom: 6),
                              child: Material(
                                color: sel ? AppColors.brand.withValues(alpha: 0.35) : Colors.grey.shade100,
                                borderRadius: BorderRadius.circular(10),
                                child: InkWell(
                                  borderRadius: BorderRadius.circular(10),
                                  onTap: !canEditStage
                                      ? null
                                      : () => setState(() {
                                            if (sel) {
                                              selectedDishes.remove(dish.name);
                                            } else {
                                              selectedDishes.add(dish.name);
                                            }
                                          }),
                                  child: Padding(
                                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                                    child: Row(
                                      children: [
                                        SizedBox(
                                          width: 40,
                                          height: 40,
                                          child: ClipRRect(
                                            borderRadius: BorderRadius.circular(8),
                                            child: _MenuThumb(item: dish, compact: true),
                                          ),
                                        ),
                                        const SizedBox(width: 10),
                                        Expanded(child: Text(dish.name)),
                                        Icon(
                                          sel ? Icons.check_circle : Icons.circle_outlined,
                                          color: sel ? AppColors.success : Colors.grey.shade500,
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                              ),
                            );
                          }),
                        ],
                      ),
                    ),
                  ] else ...[
                    if (rowMenu.isEmpty)
                      const Text('No menu selected.')
                    else
                      ...rowMenu.map((m) {
                        final dishName = dishNameFromCateringMenuEntry(m);
                        final dishImage = imageBase64FromCateringMenuEntry(m);
                        MenuItemData? lookup;
                        for (final dish in widget.state.menu) {
                          if (dish.name.toLowerCase() == dishName.toLowerCase()) {
                            lookup = dish;
                            break;
                          }
                        }
                        final thumbItem = MenuItemData(
                          id: lookup?.id ?? dishName,
                          name: dishName,
                          description: lookup?.description ?? '',
                          price: lookup?.price ?? 0,
                          dips: const [],
                          category: lookup?.category ?? '',
                          dishType: lookup?.dishType ?? '',
                          imageBase64: dishImage ?? lookup?.imageBase64,
                        );
                        return ListTile(
                          dense: true,
                          contentPadding: EdgeInsets.zero,
                          leading: SizedBox(
                            width: 42,
                            height: 42,
                            child: ClipRRect(
                              borderRadius: BorderRadius.circular(8),
                              child: _MenuThumb(item: thumbItem, compact: true),
                            ),
                          ),
                          title: Text(dishName),
                        );
                      }),
                  ],
                ],
              ),
            ),
          ),
          if (row.orderKind == 'event')
            Card(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('Event Theme Design', style: TextStyle(fontWeight: FontWeight.w800)),
                    if (isDraftStage) ...[
                      const SizedBox(height: 8),
                      Text(
                        'Customize event design in web only. Mobile manager view is notes-only.',
                        style: TextStyle(color: Colors.blueGrey.shade700, fontWeight: FontWeight.w600),
                      ),
                      const SizedBox(height: 10),
                      TextField(
                        controller: managerInquiryNoteController,
                        readOnly: isThemeReadOnly || !canEditStage,
                        maxLines: 4,
                        decoration: const InputDecoration(labelText: 'Theme notes'),
                      ),
                      const SizedBox(height: 8),
                      TextField(
                        controller: themeCostAmountController,
                        keyboardType: TextInputType.number,
                        readOnly: isThemeReadOnly || !canEditStage,
                        decoration: const InputDecoration(labelText: 'Theme design cost'),
                      ),
                    ] else ...[
                      const SizedBox(height: 8),
                      Builder(
                        builder: (context) {
                          final webImage = '${row.themeDesign['image'] ?? row.themeDesign['imageBase64'] ?? row.themeDesign['output'] ?? ''}'.trim();
                          final webImageUrl = '${row.themeDesign['imageUrl'] ?? row.themeDesign['url'] ?? ''}'.trim();
                          if (webImage.isNotEmpty) {
                            return Padding(
                              padding: const EdgeInsets.only(bottom: 8),
                              child: ClipRRect(
                                borderRadius: BorderRadius.circular(8),
                                child: Image.memory(
                                  base64Decode(webImage),
                                  height: 160,
                                  fit: BoxFit.contain,
                                  errorBuilder: (context, error, stackTrace) => const SizedBox.shrink(),
                                ),
                              ),
                            );
                          }
                          if (webImageUrl.isNotEmpty) {
                            return Padding(
                              padding: const EdgeInsets.only(bottom: 8),
                              child: ClipRRect(
                                borderRadius: BorderRadius.circular(8),
                                child: Image.network(
                                  webImageUrl,
                                  height: 160,
                                  fit: BoxFit.contain,
                                  errorBuilder: (context, error, stackTrace) => const SizedBox.shrink(),
                                ),
                              ),
                            );
                          }
                          return Text(
                            'No web theme design output found in this order.',
                            style: TextStyle(color: Colors.grey.shade700),
                          );
                        },
                      ),
                      if (managerInquiryNoteController.text.trim().isNotEmpty ||
                          '${row.themeDesign['note'] ?? ''}'.trim().isNotEmpty)
                        Text(
                          'Notes: ${managerInquiryNoteController.text.trim().isNotEmpty ? managerInquiryNoteController.text.trim() : '${row.themeDesign['note'] ?? ''}'}',
                        ),
                      if (themeDesignCosts.isNotEmpty) ...[
                        const SizedBox(height: 8),
                        ...themeDesignCosts.map(
                          (e) => ListTile(
                            dense: true,
                            contentPadding: EdgeInsets.zero,
                            title: Text('${e['label'] ?? ''}'.trim().isEmpty ? 'Theme cost' : '${e['label']}'),
                            trailing: Text('₱${jsonToDouble(e['amount']).toStringAsFixed(2)}'),
                          ),
                        ),
                      ],
                      if ('${row.themeDesign['note'] ?? ''}'.trim().isEmpty &&
                          managerInquiryNoteController.text.trim().isEmpty &&
                          themeDesignCosts.isEmpty)
                        const SizedBox.shrink(),
                    ],
                    const SizedBox(height: 8),
                  ],
                ),
              ),
            ),
          if (isDraftStage) ...[
            Card(
              color: Colors.orange.shade50,
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const Text('Labor Cost', style: TextStyle(fontWeight: FontWeight.w800)),
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        Expanded(
                          child: TextField(
                            controller: laborMaleController,
                            keyboardType: TextInputType.number,
                            readOnly: !canEditStage,
                            decoration: const InputDecoration(labelText: 'Male workers (₱1000 each)'),
                            onChanged: (_) => setState(_refreshDueAndDefaults),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: TextField(
                            controller: laborFemaleController,
                            keyboardType: TextInputType.number,
                            readOnly: !canEditStage,
                            decoration: const InputDecoration(labelText: 'Female workers (₱500 each)'),
                            onChanged: (_) => setState(_refreshDueAndDefaults),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        Expanded(
                          child: TextField(
                            controller: laborManualLabelController,
                            readOnly: !canEditStage,
                            decoration: const InputDecoration(labelText: 'Labor item'),
                          ),
                        ),
                        const SizedBox(width: 8),
                        SizedBox(
                          width: 110,
                          child: TextField(
                            controller: laborManualAmountController,
                            keyboardType: TextInputType.number,
                            readOnly: !canEditStage,
                            decoration: const InputDecoration(labelText: 'Amount'),
                          ),
                        ),
                        IconButton(
                          onPressed: !canEditStage
                              ? null
                              : () {
                                  final l = laborManualLabelController.text.trim();
                                  final a = double.tryParse(laborManualAmountController.text.trim());
                                  if (l.isEmpty || a == null) return;
                                  setState(() {
                                    laborManualCosts.add({'label': l, 'amount': a});
                                    laborManualLabelController.clear();
                                    laborManualAmountController.clear();
                                    _refreshDueAndDefaults();
                                  });
                                },
                          icon: const Icon(Icons.add),
                        ),
                      ],
                    ),
                    ...laborManualCosts.asMap().entries.map((entry) {
                      final idx = entry.key;
                      final e = entry.value;
                      return ListTile(
                        dense: true,
                        title: Text('${e['label']}'),
                        trailing: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text('₱${jsonToDouble(e['amount']).toStringAsFixed(2)}'),
                            IconButton(
                              onPressed: !canEditStage
                                  ? null
                                  : () => setState(() {
                                      laborManualCosts.removeAt(idx);
                                      _refreshDueAndDefaults();
                                    }),
                              icon: const Icon(Icons.delete_outline),
                            ),
                          ],
                        ),
                      );
                    }),
                    const SizedBox(height: 8),
                    Text('Computed labor cost: ₱${laborCostComputed.toStringAsFixed(2)}'),
                  ],
                ),
              ),
            ),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const Text('Travel Cost', style: TextStyle(fontWeight: FontWeight.w800)),
                    const SizedBox(height: 8),
                    TextField(
                      controller: travelCostController,
                      keyboardType: TextInputType.number,
                      readOnly: !canEditStage,
                      decoration: const InputDecoration(labelText: 'Travel cost'),
                      onChanged: (_) => setState(_refreshDueAndDefaults),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      'Travel cost: ₱${_travelCostComputed().toStringAsFixed(2)}',
                      style: const TextStyle(fontWeight: FontWeight.w600),
                    ),
                  ],
                ),
              ),
            ),
          ],
          if (isDraftStage || isPost || isProcessing) ...[
            Card(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const Text('Additional costs', style: TextStyle(fontWeight: FontWeight.w800)),
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        Expanded(
                          child: TextField(
                            controller: additionalCostLabelController,
                            readOnly: !(isDraftStage || isProcessing || isPost),
                            decoration: const InputDecoration(labelText: 'Label'),
                          ),
                        ),
                        const SizedBox(width: 8),
                        SizedBox(
                          width: 110,
                          child: TextField(
                            controller: additionalCostAmountController,
                            keyboardType: TextInputType.number,
                            readOnly: !(isDraftStage || isProcessing || isPost),
                            decoration: const InputDecoration(labelText: 'Amount'),
                          ),
                        ),
                        IconButton(
                          onPressed: !(isDraftStage || isProcessing || isPost)
                              ? null
                              : () {
                                  final l = additionalCostLabelController.text.trim();
                                  final a = double.tryParse(additionalCostAmountController.text.trim());
                                  if (l.isEmpty || a == null) return;
                                  setState(() {
                                    additionalCosts.add({'label': l, 'amount': a});
                                    additionalCostLabelController.clear();
                                    additionalCostAmountController.clear();
                                    _refreshDueAndDefaults();
                                  });
                                  if (isPost) {
                                    _maybeGeneratePostAnalysisPdf2IfNeeded();
                                  }
                                },
                          icon: const Icon(Icons.add),
                        ),
                      ],
                    ),
                    ...additionalCosts.asMap().entries.map(
                      (entry) {
                        final idx = entry.key;
                        final e = entry.value;
                        return ListTile(
                          title: Text('${e['label']}'),
                          trailing: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text('₱${jsonToDouble(e['amount']).toStringAsFixed(2)}'),
                              IconButton(
                                onPressed: !(isDraftStage || isProcessing || isPost)
                                    ? null
                                    : () => setState(() {
                                          additionalCosts.removeAt(idx);
                                          _refreshDueAndDefaults();
                                          if (isPost) {
                                            // Trigger second summary generation after additional costs change.
                                            _maybeGeneratePostAnalysisPdf2IfNeeded();
                                          }
                                        }),
                                icon: const Icon(Icons.delete_outline),
                              ),
                            ],
                          ),
                        );
                      },
                    ),
                    if (isPost && _postAnalysisPdf2Bytes != null) ...[
                      const SizedBox(height: 12),
                      Container(
                        width: double.infinity,
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: Colors.red.shade50,
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(color: Colors.red.shade700, width: 1.5),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Text(
                              'Additional Costs Payment',
                              style: TextStyle(fontWeight: FontWeight.w800, color: Colors.red.shade900),
                            ),
                            const SizedBox(height: 8),
                            Text(
                              'PHP ${_sumCostRows(additionalCosts).toStringAsFixed(2)}',
                              style: TextStyle(fontWeight: FontWeight.w800, fontSize: 18, color: Colors.red.shade900),
                            ),
                            const SizedBox(height: 8),
                            FilledButton(
                              style: FilledButton.styleFrom(backgroundColor: Colors.red.shade800),
                              onPressed: !widget.state.isManager ||
                                      (d.postAnalysis['additional_costs_payment_confirmed'] == true)
                                  ? null
                                  : () async {
                                      final ok = await showDialog<bool>(
                                        context: context,
                                        builder: (dlgCtx) => AlertDialog(
                                          title: const Text('Confirm additional costs payment'),
                                          content: Text(
                                            'Confirm payment of PHP ${_sumCostRows(additionalCosts).toStringAsFixed(2)} for additional costs?',
                                          ),
                                          actions: [
                                            TextButton(
                                              onPressed: () => Navigator.pop(dlgCtx, false),
                                              child: const Text('Cancel'),
                                            ),
                                            FilledButton(
                                              onPressed: () => Navigator.pop(dlgCtx, true),
                                              child: const Text('Confirm'),
                                            ),
                                          ],
                                        ),
                                      );
                                      if (ok != true || !mounted) return;
                                      final err = await widget.state.managerPatchCateringPostAnalysis(
                                        id: d.id,
                                        orderKind: d.orderKind,
                                        patch: {'additional_costs_payment_confirmed': true},
                                      );
                                      if (!mounted) return;
                                      if (err != null) {
                                        appSnack(context, err);
                                        return;
                                      }
                                      final full = await widget.state.loadManagerCateringItem(
                                        id: d.id,
                                        orderKind: d.orderKind,
                                      );
                                      if (!mounted) return;
                                      if (full != null) setState(() => _loadedDetailRow = full);
                                      appSnack(context, 'Additional costs payment confirmed');
                                    },
                              child: Text(
                                d.postAnalysis['additional_costs_payment_confirmed'] == true
                                    ? 'PAID'
                                    : 'Confirm payment',
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                    if (isPost) ...[
                      const SizedBox(height: 10),
                      Text(
                        'Order Summary PDFs',
                        style: Theme.of(context).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w800),
                      ),
                      const SizedBox(height: 8),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          OutlinedButton(
                            onPressed: _postAnalysisPdf1Bytes == null
                                ? null
                                : () => _openOrderSummaryPdfBytes(_postAnalysisPdf1Bytes!),
                            child: const Text('Order Summary #1'),
                          ),
                          OutlinedButton(
                            onPressed: _postAnalysisPdf2Bytes == null
                                ? null
                                : () => _openOrderSummaryPdfBytes(_postAnalysisPdf2Bytes!),
                            child: _postAnalysisPdf2Bytes == null
                                ? (_postAnalysisPdfGenerating
                                    ? const SizedBox(
                                        width: 18,
                                        height: 18,
                                        child: CircularProgressIndicator(strokeWidth: 2),
                                      )
                                    : const Text('Order Summary #2'))
                                : const Text('Order Summary #2'),
                          ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      Text(
                        'Summary #1 reflects the initial quoted costs. Summary #2 includes event information and additional costs entered in this stage.',
                        style: TextStyle(fontSize: 12, height: 1.35, color: Colors.black.withValues(alpha: 0.72)),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ],
          if (isCompleted)
            const Padding(
              padding: EdgeInsets.only(top: 8),
              child: Text(
                'Completed records are locked and cannot be edited.',
                style: TextStyle(fontWeight: FontWeight.w700),
              ),
            ),
        ],
      ),
      bottomNavigationBar: (!isCompleted && (isProcessing || isPost || isOnlineInquiry || isDraftStage))
          ? SafeArea(
              child: Container(
                decoration: BoxDecoration(
                  color: Theme.of(context).scaffoldBackgroundColor,
                  border: Border(top: BorderSide(color: Colors.grey.shade300)),
                ),
                padding: const EdgeInsets.fromLTRB(12, 8, 12, 10),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Center(
                      child: Column(
                        children: [
                          Text(
                            isProcessing ? 'Final Cost' : 'Estimated Cost',
                            style: const TextStyle(fontWeight: FontWeight.w800),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            '₱${(isProcessing ? displayInvoiceTotal : totalComputed).toStringAsFixed(2)}',
                            style: const TextStyle(fontSize: 24, fontWeight: FontWeight.w800),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 8),
                    OutlinedButton(
                      onPressed: () async {
                        if (isPost) {
                          if (_postAnalysisPdf2Bytes != null) {
                            await _openOrderSummaryPdfBytes(_postAnalysisPdf2Bytes!);
                            return;
                          }
                            if (_postAnalysisPdfGenerating) {
                              // If #2 is still being generated, fall back to generating the latest view.
                              await _generateInvoicePdf();
                              return;
                            }
                          if (_postAnalysisPdf1Bytes != null) {
                            await _openOrderSummaryPdfBytes(_postAnalysisPdf1Bytes!);
                            return;
                          }
                        }
                        await _generateInvoicePdf();
                      },
                      child: const Text('Generate Order Summary PDF'),
                    ),
                    if (isProcessing) ...[
                      const SizedBox(height: 8),
                      OutlinedButton.icon(
                        onPressed: () async {
                          await _sendOrderSummaryPdfToCustomer();
                        },
                        icon: const Icon(Icons.send_outlined),
                        label: const Text('Send Order Summary PDF to Customer'),
                      ),
                    ],
                    if (isDraftStage || isProcessing || isPost) ...[
                      const SizedBox(height: 8),
                      FilledButton(
                        onPressed: submitNext,
                        child: Text(
                          isDraftStage
                              ? 'Save and Move to For Processing'
                              : (isPost ? 'Complete Order' : 'Submit to Next Stage'),
                        ),
                      ),
                    ],
                    if (isDraftStage || isProcessing || isPost) ...[
                      const SizedBox(height: 8),
                      OutlinedButton(
                        onPressed: saveCurrentStage,
                        child: Text(isDraftStage ? 'Save draft' : 'Save'),
                      ),
                    ],
                  ],
                ),
              ),
            )
          : null,
    );
  }
}

// --- Cashier POS (restaurant orders / walk-in) ---

class PosShellScreen extends StatefulWidget {
  const PosShellScreen({super.key, required this.state});
  final AppState state;

  @override
  State<PosShellScreen> createState() => _PosShellScreenState();
}

class _PosShellScreenState extends State<PosShellScreen> with SingleTickerProviderStateMixin {
  late TabController _tab;

  @override
  void initState() {
    super.initState();
    _tab = TabController(length: 3, vsync: this);
    _tab.addListener(() {
      if (!mounted) return;
      setState(() {});
      if (_tab.index == 2 && !_tab.indexIsChanging) {
        widget.state.loadCashierWalkInQueues(force: true);
      }
    });
  }

  @override
  void dispose() {
    _tab.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final name = widget.state.cashierDisplayName.trim().isNotEmpty
        ? widget.state.cashierDisplayName.toUpperCase()
        : (widget.state.userEmail ?? '').toUpperCase();
    return AnimatedBuilder(
      animation: widget.state,
      builder: (context, _) {
        return Scaffold(
          backgroundColor: Theme.of(context).scaffoldBackgroundColor,
          appBar: AppBar(
            backgroundColor: Colors.black87,
            foregroundColor: Colors.white,
            leading: Builder(
              builder: (ctx) => Stack(
                clipBehavior: Clip.none,
                children: [
                  IconButton(
                    icon: const Icon(Icons.menu, color: AppColors.brand),
                    onPressed: () => Scaffold.of(ctx).openDrawer(),
                  ),
                  if (widget.state.hasCashierAttentionBadge)
                    const Positioned(
                      right: 9,
                      top: 9,
                      child: SizedBox(
                        width: 10,
                        height: 10,
                        child: DecoratedBox(
                          decoration: BoxDecoration(color: Colors.red, shape: BoxShape.circle),
                        ),
                      ),
                    ),
                ],
              ),
            ),
            title: Text(name, style: const TextStyle(fontWeight: FontWeight.w700, letterSpacing: 0.5)),
            actions: [
              Padding(
                padding: const EdgeInsets.only(right: 10),
                child: Center(
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                    decoration: BoxDecoration(color: AppColors.brand, borderRadius: BorderRadius.circular(12)),
                    child: Text(
                      _tab.index == 0
                          ? 'NEW ORDER'
                          : _tab.index == 1
                              ? 'ONLINE ORDERS'
                              : 'ONGOING WALK-IN',
                      style: const TextStyle(color: AppColors.ink, fontWeight: FontWeight.w800, fontSize: 12),
                    ),
                  ),
                ),
              ),
            ],
            bottom: TabBar(
              controller: _tab,
              indicatorColor: AppColors.brand,
              labelColor: AppColors.brand,
              unselectedLabelColor: Colors.white70,
              onTap: (_) => setState(() {}),
              tabs: [
                const Tab(text: 'New Order'),
                Tab(
                  child: Badge(
                    isLabelVisible: widget.state.hasCashierAttentionBadge,
                    backgroundColor: Colors.red,
                    smallSize: 10,
                    child: const Text('Online Orders'),
                  ),
                ),
                const Tab(text: 'Walk-in ongoing'),
              ],
            ),
          ),
          drawer: Drawer(
            child: ListView(
              children: [
                DrawerHeader(
                  decoration: const BoxDecoration(color: AppColors.brand),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      Image.asset(AppBrandAssets.logo, height: 52, fit: BoxFit.contain),
                      const SizedBox(height: 10),
                      Text(
                        'Hi, ${widget.state.cashierDisplayName.isNotEmpty ? widget.state.cashierDisplayName : 'Cashier'}',
                        style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 18),
                      ),
                      Text(widget.state.userEmail ?? '', style: const TextStyle(fontSize: 13)),
                    ],
                  ),
                ),
                ListTile(
                  leading: const Icon(Icons.dashboard_customize_outlined),
                  title: const Text('Manage Orders'),
                  onTap: () {
                    Navigator.pop(context);
                    _tab.animateTo(0);
                  },
                ),
                ListTile(
                  leading: const Icon(Icons.history),
                  title: const Text('Order history'),
                  onTap: () {
                    Navigator.pop(context);
                    Navigator.of(context).push(
                      MaterialPageRoute<void>(builder: (_) => PosOrderHistoryScreen(state: widget.state)),
                    );
                  },
                ),
                ListTile(
                  leading: const Icon(Icons.help_outline),
                  title: const Text('Help request'),
                  onTap: () {
                    Navigator.pop(context);
                    showCashierHelpDialog(context, widget.state);
                  },
                ),
                ListTile(
                  leading: const Icon(Icons.settings),
                  title: const Text('Settings'),
                  onTap: () {
                    Navigator.pop(context);
                    Navigator.of(context).push(
                      MaterialPageRoute<void>(builder: (_) => SettingsScreen(state: widget.state)),
                    );
                  },
                ),
              ],
            ),
          ),
          body: TabBarView(
            controller: _tab,
            children: [
              PosNewOrderTab(state: widget.state),
              PosOnlineOrdersTab(state: widget.state),
              PosWalkInOngoingTab(state: widget.state),
            ],
          ),
        );
      },
    );
  }
}

class PosNewOrderTab extends StatefulWidget {
  const PosNewOrderTab({super.key, required this.state});
  final AppState state;

  @override
  State<PosNewOrderTab> createState() => _PosNewOrderTabState();
}

class _PosNewOrderTabState extends State<PosNewOrderTab> {
  static const List<String> _sectionChips = [
    'ALL',
    'rice meals',
    'silog meals',
    'pasta',
    'sandwiches',
    'others',
    'drinks',
  ];

  String search = '';
  String sectionFilter = 'ALL';

  Widget _posDishCard(MenuItemData item) {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(
            child: ClipRRect(
              borderRadius: const BorderRadius.vertical(top: Radius.circular(11)),
              child: _MenuThumb(item: item),
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(item.name, maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 12)),
                if (item.dips.isNotEmpty)
                  Text(
                    item.dips.join(', ').toUpperCase(),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 9, color: Colors.grey.shade700),
                  ),
                Row(
                  children: [
                    Text('₱${item.price.toStringAsFixed(2)}', style: const TextStyle(fontWeight: FontWeight.w800)),
                    const Spacer(),
                    IconButton(
                      onPressed: () {
                        widget.state.addToTray(item, dip: item.dips.isNotEmpty ? item.dips.first : '');
                      },
                      icon: const Icon(Icons.add_box_outlined),
                      color: AppColors.ink,
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _traySidebar(BuildContext context, double subtotal) {
    return Container(
      width: 300,
      decoration: BoxDecoration(
        color: Colors.grey.shade50,
        border: Border(left: BorderSide(color: Colors.grey.shade300)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 12, 12, 4),
            child: Text('TRAY', style: TextStyle(fontWeight: FontWeight.w900, color: Colors.grey.shade900)),
          ),
          Expanded(
            child: widget.state.tray.isEmpty
                ? Center(child: Text('No dishes yet.', style: TextStyle(color: Colors.grey.shade600)))
                : ListView.builder(
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    itemCount: widget.state.tray.length,
                    itemBuilder: (context, i) {
                      final e = widget.state.tray[i];
                      return Card(
                        child: ListTile(
                          dense: true,
                          title: Text(e.menu.name, maxLines: 2, overflow: TextOverflow.ellipsis),
                          subtitle: Text(e.dip.isEmpty ? '—' : e.dip, maxLines: 1),
                          trailing: SizedBox(
                            width: 108,
                            child: Row(
                              mainAxisAlignment: MainAxisAlignment.end,
                              children: [
                                IconButton(
                                  padding: EdgeInsets.zero,
                                  constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
                                  icon: const Icon(Icons.remove_circle_outline, size: 22),
                                  onPressed: () => widget.state.changeQty(e, -1),
                                ),
                                Padding(
                                  padding: const EdgeInsets.symmetric(horizontal: 4),
                                  child: Text('${e.qty}', style: const TextStyle(fontWeight: FontWeight.w800)),
                                ),
                                IconButton(
                                  padding: EdgeInsets.zero,
                                  constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
                                  icon: const Icon(Icons.add_circle_outline, size: 22),
                                  onPressed: () => widget.state.changeQty(e, 1),
                                ),
                              ],
                            ),
                          ),
                        ),
                      );
                    },
                  ),
          ),
          Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text('Subtotal ₱${subtotal.toStringAsFixed(2)}', style: const TextStyle(fontWeight: FontWeight.w800)),
                const SizedBox(height: 10),
                Row(
                  children: [
                    Expanded(
                      child: FilledButton(
                        style: FilledButton.styleFrom(backgroundColor: AppColors.brand, foregroundColor: AppColors.ink),
                        onPressed: () {
                          Navigator.of(context).push<void>(
                            MaterialPageRoute<void>(builder: (_) => PosWalkInCheckoutScreen(state: widget.state, subtotal: subtotal)),
                          );
                        },
                        child: const Text('CHECKOUT'),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: widget.state,
      builder: (context, _) {
        final items = widget.state.menu.where((m) => m.isRestaurantDish).toList();
        final filtered = items.where((m) {
          final okSection =
              sectionFilter == 'ALL' || m.restaurantMenuBucket.toLowerCase() == sectionFilter.toLowerCase();
          final okSearch =
              search.trim().isEmpty || m.name.toLowerCase().contains(search.trim().toLowerCase());
          return okSection && okSearch;
        }).toList();
        final subtotal = widget.state.tray.fold<double>(0, (s, e) => s + e.qty * e.menu.price);
        final cw = restaurantGridCrossAxisCount(MediaQuery.sizeOf(context).width);
        final gridDelegate = SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: cw,
          crossAxisSpacing: 10,
          mainAxisSpacing: 10,
          childAspectRatio: cw >= 4 ? 0.78 : 0.72,
        );
        final menuBody = Column(
          children: [
            Padding(
              padding: const EdgeInsets.all(12),
              child: TextField(
                decoration: const InputDecoration(hintText: 'SEARCH'),
                onChanged: (v) => setState(() => search = v),
              ),
            ),
            SizedBox(
              height: 44,
              child: ListView(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 12),
                children: [
                  ..._sectionChips.map(
                    (c) => Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: FilterChip(
                        label: Text(c.toUpperCase()),
                        selected: sectionFilter == c,
                        onSelected: (_) => setState(() => sectionFilter = c),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            Expanded(
              child: filtered.isEmpty
                  ? const Center(child: Text('No menu items (tag dishes as category "restaurant").'))
                  : GridView.builder(
                      padding: const EdgeInsets.all(12),
                      gridDelegate: gridDelegate,
                      itemCount: filtered.length,
                      itemBuilder: (context, i) => _posDishCard(filtered[i]),
                    ),
            ),
          ],
        );
        return LayoutBuilder(
          builder: (context, constraints) {
            final mq = MediaQuery.sizeOf(context);
            final tabletLike = mq.shortestSide >= 600;
            final wide = constraints.maxWidth >= 900 || (tabletLike && constraints.maxWidth >= 700);
            if (wide) {
              return Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Expanded(child: menuBody),
                  _traySidebar(context, subtotal),
                ],
              );
            }
            return Column(
              children: [
                Expanded(child: menuBody),
                Container(
                  decoration: const BoxDecoration(color: Colors.white, border: Border(top: BorderSide(color: Color(0xFF8ADFC1)))),
                  padding: const EdgeInsets.all(12),
                  child: Row(
                    children: [
                      Expanded(
                        child: FilledButton(
                          style: FilledButton.styleFrom(backgroundColor: AppColors.brand, foregroundColor: AppColors.ink),
                          onPressed: () {
                            Navigator.of(context).push<void>(
                              MaterialPageRoute<void>(builder: (_) => PosYourTrayScreen(state: widget.state, subtotal: subtotal)),
                            );
                          },
                          child: const Text('YOUR TRAY'),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            );
          },
        );
      },
    );
  }
}

class PosWalkInCheckoutScreen extends StatefulWidget {
  const PosWalkInCheckoutScreen({super.key, required this.state, required this.subtotal});
  final AppState state;
  final double subtotal;

  @override
  State<PosWalkInCheckoutScreen> createState() => _PosWalkInCheckoutScreenState();
}

class PosYourTrayScreen extends StatelessWidget {
  const PosYourTrayScreen({super.key, required this.state, required this.subtotal});
  final AppState state;
  final double subtotal;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        backgroundColor: Colors.black87,
        foregroundColor: Colors.white,
        title: const Text('YOUR TRAY'),
      ),
      body: Column(
        children: [
          Expanded(
            child: state.tray.isEmpty
                ? const Center(child: Text('No dishes yet.'))
                : ListView.builder(
                    padding: const EdgeInsets.all(12),
                    itemCount: state.tray.length,
                    itemBuilder: (context, i) {
                      final e = state.tray[i];
                      return Card(
                        child: ListTile(
                          title: Text(e.menu.name),
                          subtitle: Text(e.dip.isEmpty ? '—' : e.dip),
                          trailing: Text('x${e.qty}  ₱${(e.qty * e.menu.price).toStringAsFixed(2)}'),
                        ),
                      );
                    },
                  ),
          ),
          Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text('Subtotal ₱${subtotal.toStringAsFixed(2)}', style: const TextStyle(fontWeight: FontWeight.w800)),
                const SizedBox(height: 10),
                Row(
                  children: [
                    Expanded(
                      child: FilledButton(
                        style: FilledButton.styleFrom(backgroundColor: AppColors.accent, foregroundColor: AppColors.ink),
                        onPressed: () async {
                          final ok = await showDialog<bool>(
                            context: context,
                            builder: (ctx) => AlertDialog(
                              title: const Text('Clear tray?'),
                              content: const Text('Remove all items from the tray?'),
                              actions: [
                                TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('No')),
                                FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Yes')),
                              ],
                            ),
                          );
                          if (ok == true) state.clearTray();
                        },
                        child: const Text('CANCEL'),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: FilledButton(
                        style: FilledButton.styleFrom(backgroundColor: AppColors.brand, foregroundColor: AppColors.ink),
                        onPressed: state.tray.isEmpty
                            ? null
                            : () {
                                Navigator.of(context).push<void>(
                                  MaterialPageRoute<void>(
                                    builder: (_) => PosWalkInCheckoutScreen(state: state, subtotal: subtotal),
                                  ),
                                );
                              },
                        child: const Text('NEXT'),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _PosWalkInCheckoutScreenState extends State<PosWalkInCheckoutScreen> {
  String paymentMethod = 'CASH';
  final amountReceived = TextEditingController();
  final note = TextEditingController();
  final customerLabel = TextEditingController();
  Uint8List? gcashProofBytes;

  void _showGcashProofFullscreen() {
    final b = gcashProofBytes;
    if (b == null) return;
    showDialog<void>(
      context: context,
      barrierColor: Colors.black87,
      builder: (ctx) => Dialog(
        insetPadding: EdgeInsets.zero,
        backgroundColor: Colors.black,
        child: Stack(
          fit: StackFit.expand,
          children: [
            InteractiveViewer(
              minScale: 0.5,
              maxScale: 4,
              child: Center(child: Image.memory(b, fit: BoxFit.contain)),
            ),
            Positioned(
              top: 8,
              right: 8,
              child: IconButton(
                icon: const Icon(Icons.close, color: Colors.white),
                onPressed: () => Navigator.pop(ctx),
              ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  void dispose() {
    amountReceived.dispose();
    note.dispose();
    customerLabel.dispose();
    super.dispose();
  }

  Future<void> _pickGcashProof(ImageSource source) async {
    final x = await ImagePicker().pickImage(source: source);
    if (x == null) return;
    final b = await x.readAsBytes();
    setState(() => gcashProofBytes = b);
  }

  @override
  Widget build(BuildContext context) {
    final parsed = double.tryParse(amountReceived.text.trim());
    final arNum = parsed ?? 0;
    final change = arNum - widget.subtotal;
    final isGcash = paymentMethod == 'GCASH';
    return Scaffold(
      appBar: AppBar(
        backgroundColor: Colors.black87,
        foregroundColor: Colors.white,
        title: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(color: AppColors.brand, borderRadius: BorderRadius.circular(10)),
          child: const Text('CHECKOUT', style: TextStyle(color: AppColors.ink, fontWeight: FontWeight.w800)),
        ),
        centerTitle: true,
      ),
      body: Column(
        children: [
          Expanded(
            child: ListView(
              padding: const EdgeInsets.all(12),
              children: [
                DropdownButtonFormField<String>(
                  value: paymentMethod,
                  decoration: const InputDecoration(labelText: 'PAYMENT METHOD'),
                  items: const [
                    DropdownMenuItem(value: 'CASH', child: Text('CASH')),
                    DropdownMenuItem(value: 'GCASH', child: Text('GCASH')),
                  ],
                  onChanged: (v) => setState(() => paymentMethod = v ?? 'CASH'),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: amountReceived,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(labelText: 'AMOUNT RECEIVED'),
                  onChanged: (_) => setState(() {}),
                ),
                Text('Amount due: ₱${widget.subtotal.toStringAsFixed(2)}'),
                if (!isGcash)
                  Text('Change: ₱${change.toStringAsFixed(2)}', style: const TextStyle(fontWeight: FontWeight.w700)),
                if (isGcash) ...[
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed: () => _pickGcashProof(ImageSource.gallery),
                          icon: const Icon(Icons.upload_file),
                          label: const Text('UPLOAD PROOF'),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed: () => _pickGcashProof(ImageSource.camera),
                          icon: const Icon(Icons.photo_camera_outlined),
                          label: const Text('CAMERA'),
                        ),
                      ),
                    ],
                  ),
                  if (gcashProofBytes != null) ...[
                    Align(
                      alignment: Alignment.centerLeft,
                      child: TextButton.icon(
                        onPressed: () => _pickGcashProof(ImageSource.camera),
                        icon: const Icon(Icons.refresh, size: 18),
                        label: const Text('Retake / replace photo'),
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.only(top: 10),
                      child: GestureDetector(
                        onTap: _showGcashProofFullscreen,
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(10),
                          child: Image.memory(gcashProofBytes!, height: 140, fit: BoxFit.contain),
                        ),
                      ),
                    ),
                  ],
                ],
                const SizedBox(height: 12),
                TextField(controller: customerLabel, decoration: const InputDecoration(labelText: 'Customer name / reference (optional)')),
                TextField(controller: note, decoration: const InputDecoration(labelText: 'NOTE'), maxLines: 2),
                const Divider(height: 28),
                const Align(
                  alignment: Alignment.centerLeft,
                  child: Text('YOUR TRAY', style: TextStyle(fontWeight: FontWeight.w900, letterSpacing: 0.8)),
                ),
                const SizedBox(height: 10),
                ...widget.state.tray.map(
                  (e) => Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(
                          child: Text(
                            '${e.menu.name}${e.dip.trim().isNotEmpty ? ' — ${e.dip}' : ''} × ${e.qty}',
                            style: const TextStyle(height: 1.25),
                          ),
                        ),
                        Text(
                          '₱${(e.qty * e.menu.price).toStringAsFixed(2)}',
                          style: const TextStyle(fontWeight: FontWeight.w800),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
          SummaryFooter(
            lines: [
              SummaryLine('TOTAL', '₱${widget.subtotal.toStringAsFixed(2)}', isTotal: true),
            ],
            actionLabel: 'CONFIRM',
            onAction: () async {
              if (amountReceived.text.trim().isEmpty) {
                await showStaffPosNotification('Checkout', 'Enter amount received.');
                return;
              }
              if (parsed == null) {
                await showStaffPosNotification('Checkout', 'Enter a valid amount.');
                return;
              }
              if (arNum < widget.subtotal) {
                await showStaffPosNotification('Checkout', 'Amount received is less than the total.');
                return;
              }
              if (isGcash && gcashProofBytes == null) {
                await showStaffPosNotification('Checkout', 'Upload proof of payment for GCash.');
                return;
              }
              final ok = await showDialog<bool>(
                context: context,
                builder: (ctx) => AlertDialog(
                  title: const Text('Confirm walk-in sale'),
                  content: Text('Total ₱${widget.subtotal.toStringAsFixed(2)} — complete this sale?'),
                  actions: [
                    TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
                    FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Confirm')),
                  ],
                ),
              );
              if (ok != true || !context.mounted) return;
              final err = await widget.state.submitPosWalkInOrder(
                paymentMethod: paymentMethod,
                amountReceived: arNum,
                note: note.text.trim(),
                posCustomerLabel: customerLabel.text.trim(),
                paymentProofBase64: gcashProofBytes != null ? base64Encode(gcashProofBytes!) : '',
              );
              if (!context.mounted) return;
              if (err != null) {
                await showStaffPosNotification('Checkout', err);
                return;
              }
              await showStaffPosNotification('Checkout', 'Walk-in order saved.');
              Navigator.of(context).popUntil((r) => r.isFirst);
            },
          ),
        ],
      ),
    );
  }
}

class PosWalkInOngoingTab extends StatefulWidget {
  const PosWalkInOngoingTab({super.key, required this.state});
  final AppState state;

  @override
  State<PosWalkInOngoingTab> createState() => _PosWalkInOngoingTabState();
}

class _PosWalkInOngoingTabState extends State<PosWalkInOngoingTab> with SingleTickerProviderStateMixin {
  late TabController _walkTab;

  @override
  void initState() {
    super.initState();
    _walkTab = TabController(length: 2, vsync: this);
    widget.state.loadCashierWalkInQueues(force: true);
  }

  @override
  void dispose() {
    _walkTab.dispose();
    super.dispose();
  }

  Future<void> _showWalkInDetail(OrderData o) async {
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(o.orderNo),
        content: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('Total: ₱${o.total.toStringAsFixed(2)}'),
              Text('Status: ${statusReadable(o.status)}'),
              Text('Placed: ${formatDateTimeLocal(o.createdAt)}'),
              Text('Payment: ${o.paymentMode.trim().isEmpty ? '—' : o.paymentMode}'),
              if (o.cashierAmountReceived != null)
                Text('Amount received: ₱${o.cashierAmountReceived!.toStringAsFixed(2)}'),
              if (o.cashierChange != null && o.cashierChange != 0)
                Text('Change: ₱${o.cashierChange!.toStringAsFixed(2)}'),
              if (o.posCustomerLabel.trim().isNotEmpty) Text('Customer: ${o.posCustomerLabel}'),
              if (o.note.trim().isNotEmpty) Text('Note: ${o.note}'),
              const SizedBox(height: 12),
              const Text('Items', style: TextStyle(fontWeight: FontWeight.w800)),
              ...o.lines.map((l) => Text('• ${l.itemName}${l.dip.isEmpty ? '' : ' — ${l.dip}'} ×${l.qty}')),
              if (o.paymentProofBase64 != null && o.paymentProofBase64!.trim().isNotEmpty) ...[
                const SizedBox(height: 12),
                const Text('Payment proof', style: TextStyle(fontWeight: FontWeight.w800)),
                const SizedBox(height: 8),
                ...(() {
                  try {
                    final bytes = base64Decode(o.paymentProofBase64!.trim());
                    return [
                      ClipRRect(
                        borderRadius: BorderRadius.circular(10),
                        child: Image.memory(Uint8List.fromList(bytes), height: 160, fit: BoxFit.contain),
                      ),
                    ];
                  } catch (_) {
                    return [const Text('Could not load payment proof image.')];
                  }
                })(),
              ],
            ],
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Close')),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: widget.state,
      builder: (context, _) {
        return Column(
          children: [
            Material(
              color: Theme.of(context).colorScheme.surface,
              child: TabBar(
                controller: _walkTab,
                labelColor: AppColors.brand,
                unselectedLabelColor: Colors.grey.shade700,
                indicatorColor: AppColors.brand,
                tabs: const [
                  Tab(text: 'Preparing'),
                  Tab(text: 'Complete'),
                ],
              ),
            ),
            Expanded(
              child: TabBarView(
                controller: _walkTab,
                children: [
                  RefreshIndicator(
                    onRefresh: () => widget.state.loadCashierWalkInQueues(force: true),
                    child: _walkList(widget.state.cashierWalkInPreparing, showClaim: true),
                  ),
                  RefreshIndicator(
                    onRefresh: () => widget.state.loadCashierWalkInQueues(force: true),
                    child: _walkList(widget.state.cashierWalkInComplete, showClaim: false),
                  ),
                ],
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _walkList(List<OrderData> rows, {required bool showClaim}) {
    if (rows.isEmpty) {
      return ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        children: const [
          SizedBox(height: 120, child: Center(child: Text('No orders in this stage.'))),
        ],
      );
    }
    return ListView.builder(
      padding: const EdgeInsets.all(12),
      itemCount: rows.length,
      itemBuilder: (context, i) {
        final o = rows[i];
        final submitted = formatDateTimeLocal(o.createdAt);
        final completed =
            o.updatedAt != null ? formatDateTimeLocal(o.updatedAt!) : '';
        return Card(
          child: ListTile(
            title: Text(o.orderNo),
            subtitle: Text(
              [
                'Submitted: $submitted',
                if (!showClaim && completed.isNotEmpty) 'Completed: $completed',
                if (o.posCustomerLabel.trim().isNotEmpty) o.posCustomerLabel.trim(),
                if (o.paymentMode.trim().isNotEmpty) o.paymentMode.toUpperCase(),
              ].where((s) => s.isNotEmpty).join('\n'),
            ),
            isThreeLine: true,
            trailing: showClaim
                ? FilledButton(
                    onPressed: () async {
                      final yes = await showDialog<bool>(
                        context: context,
                        builder: (ctx) => AlertDialog(
                          title: const Text('Mark order claimed?'),
                          content: Text(
                            'Confirm when ${o.orderNo} has been picked up by the customer. It will move to Complete here and appear in Order history.',
                          ),
                          actions: [
                            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
                            FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Confirm')),
                          ],
                        ),
                      );
                      if (yes != true || !context.mounted) return;
                      final err = await widget.state.claimWalkInOrder(o.id);
                      if (mounted && err != null) appSnack(context, err);
                    },
                    child: const Text('Claim'),
                  )
                : const Icon(Icons.check_circle_outline, color: AppColors.success),
            onTap: () => _showWalkInDetail(o),
          ),
        );
      },
    );
  }
}

class PosOnlineOrdersTab extends StatefulWidget {
  const PosOnlineOrdersTab({super.key, required this.state});
  final AppState state;

  @override
  State<PosOnlineOrdersTab> createState() => _PosOnlineOrdersTabState();
}

class _PosOnlineOrdersTabState extends State<PosOnlineOrdersTab> with SingleTickerProviderStateMixin {
  late TabController _fulTab;
  String _search = '';
  Timer? _pendingReminderTimer;
  final Map<int, int> _pendingAlertStage = {};

  Color _statusBadgeBg(String status) {
    final up = status.toUpperCase();
    if (up.contains('INSUFFICIENT')) return Colors.red.shade100;
    if (up.contains('CONFIRMED') || up.contains('OVERPAYMENT')) return Colors.green.shade100;
    if (up.contains('CANCEL')) return Colors.grey.shade300;
    return Colors.orange.shade100;
  }

  Color _statusBadgeFg(String status) {
    final up = status.toUpperCase();
    if (up.contains('INSUFFICIENT')) return Colors.red.shade900;
    if (up.contains('CONFIRMED') || up.contains('OVERPAYMENT')) return Colors.green.shade900;
    if (up.contains('CANCEL')) return Colors.grey.shade900;
    return Colors.orange.shade900;
  }

  @override
  void initState() {
    super.initState();
    _fulTab = TabController(length: 4, vsync: this);
    _pendingReminderTimer = Timer.periodic(const Duration(seconds: 25), (_) => _tickPendingAlerts());
  }

  @override
  void dispose() {
    _pendingReminderTimer?.cancel();
    _fulTab.dispose();
    super.dispose();
  }

  void _tickPendingAlerts() {
    if (!mounted) return;
    final pending =
        widget.state.cashierOnlineOrders.where((o) => o.fulfillmentStage.toUpperCase() == 'PENDING_CASHIER');
    final now = DateTime.now();
    for (final o in pending) {
      final mins = now.difference(o.createdAt).inMinutes;
      final st = _pendingAlertStage[o.id] ?? 0;
      if (mins >= 10 && st < 2) {
        _pendingAlertStage[o.id] = 2;
        showStaffPosNotification('Online orders', '${o.orderNo} is still awaiting cashier action.');
      } else if (mins >= 5 && st < 1) {
        _pendingAlertStage[o.id] = 1;
        showStaffPosNotification('Online orders', '${o.orderNo} — please review when ready.');
      }
    }
  }

  static const _stages = [
    'PENDING_CASHIER',
    'IN_PREPARATION',
    'OUT_FOR_DELIVERY',
    'DELIVERED',
  ];

  List<OrderData> _forIndex(int i) {
    final want = _stages[i];
    return widget.state.cashierOnlineOrders
        .where((o) => o.fulfillmentStage.toUpperCase() == want)
        .where((o) {
          final q = _search.trim().toLowerCase();
          if (q.isEmpty) return true;
          return o.orderNo.toLowerCase().contains(q) ||
              (o.userEmail ?? '').toLowerCase().contains(q) ||
              cashierCustomerLabel(o).toLowerCase().contains(q) ||
              statusReadable(o.status).toLowerCase().contains(q);
        })
        .toList();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: widget.state,
      builder: (context, _) {
        return Column(
          children: [
            Padding(
              padding: const EdgeInsets.all(12),
              child: TextField(
                decoration: const InputDecoration(hintText: 'SEARCH ORDER NO / EMAIL / STATUS'),
                onChanged: (v) => setState(() => _search = v),
              ),
            ),
            Material(
              color: Theme.of(context).colorScheme.surface,
              child: TabBar(
                controller: _fulTab,
                isScrollable: true,
                labelColor: AppColors.brand,
                unselectedLabelColor: Colors.grey.shade700,
                indicatorColor: AppColors.brand,
                tabs: const [
                  Tab(text: 'Pending'),
                  Tab(text: 'Preparing'),
                  Tab(text: 'For delivery'),
                  Tab(text: 'Delivered'),
                ],
              ),
            ),
            Expanded(
              child: TabBarView(
                controller: _fulTab,
                children: List.generate(4, (idx) {
                  final rows = _forIndex(idx);
                  return RefreshIndicator(
                    onRefresh: () => widget.state.loadCashierOnlineOrders(force: true),
                    child: rows.isEmpty
                        ? ListView(
                            physics: const AlwaysScrollableScrollPhysics(),
                            children: const [
                              SizedBox(height: 120, child: Center(child: Text('No orders in this stage.'))),
                            ],
                          )
                        : ListView.builder(
                            padding: const EdgeInsets.all(12),
                            itemCount: rows.length,
                            itemBuilder: (context, i) {
                              final o = rows[i];
                              return Card(
                                child: ListTile(
                                  leading: o.balanceProofPendingReview
                                      ? Icon(Icons.notifications_active, color: Colors.deepOrange.shade700)
                                      : null,
                                  title: Row(
                                    children: [
                                      Expanded(child: Text(o.orderNo)),
                                      const SizedBox(width: 6),
                                      Container(
                                        constraints: const BoxConstraints(maxWidth: 180),
                                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                                        decoration: BoxDecoration(
                                          color: _statusBadgeBg(o.status),
                                          borderRadius: BorderRadius.circular(999),
                                        ),
                                        child: Text(
                                          statusReadable(o.status),
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: TextStyle(
                                            fontSize: 10.5,
                                            fontWeight: FontWeight.w700,
                                            color: _statusBadgeFg(o.status),
                                          ),
                                        ),
                                      ),
                                    ],
                                  ),
                                  subtitle: Text(
                                    '${cashierCustomerLabel(o)}'
                                    '${o.loyaltyPointsEarned > 0 && (o.status.toUpperCase().contains('ORDER CONFIRMED') || o.status.toUpperCase().contains('OVERPAYMENT')) ? '\nLoyalty: +${o.loyaltyPointsEarned} pts' : ''}',
                                  ),
                                  isThreeLine: true,
                                  trailing: Text('₱${o.total.toStringAsFixed(2)}'),
                                  onTap: () async {
                                    await Navigator.of(context).push<void>(
                                      MaterialPageRoute<void>(
                                        builder: (_) => PosOnlineOrderDetailScreen(state: widget.state, order: o),
                                      ),
                                    );
                                    if (context.mounted) await widget.state.loadCashierOnlineOrders(force: true);
                                  },
                                ),
                              );
                            },
                          ),
                  );
                }),
              ),
            ),
          ],
        );
      },
    );
  }
}

class PosOnlineOrderDetailScreen extends StatefulWidget {
  const PosOnlineOrderDetailScreen({super.key, required this.state, required this.order});
  final AppState state;
  final OrderData order;

  @override
  State<PosOnlineOrderDetailScreen> createState() => _PosOnlineOrderDetailScreenState();
}

class _PosOnlineOrderDetailScreenState extends State<PosOnlineOrderDetailScreen> {
  final amountReceived = TextEditingController();
  final supplementalAmount = TextEditingController();
  final trackingUrl = TextEditingController();
  bool showDelivery = true;
  bool showPayment = true;
  bool showTray = true;
  bool showNotes = true;

  OrderData _currentOrder() {
    for (final e in widget.state.cashierOnlineOrders) {
      if (e.id == widget.order.id) return e;
    }
    return widget.order;
  }

  @override
  void initState() {
    super.initState();
    final o = widget.order;
    amountReceived.text = o.cashierAmountReceived?.toStringAsFixed(2) ?? '';
    supplementalAmount.text = o.cashierSecondaryAmountReceived?.toStringAsFixed(2) ?? '';
    trackingUrl.text = o.deliveryTrackingUrl;
  }

  @override
  void dispose() {
    amountReceived.dispose();
    supplementalAmount.dispose();
    trackingUrl.dispose();
    super.dispose();
  }

  Future<bool> _confirmDialog(String title, String body) async {
    final r = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: Text(body),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Confirm')),
        ],
      ),
    );
    return r == true;
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: widget.state,
      builder: (context, _) {
        final o = _currentOrder();
        final proofOk = o.paymentUploaded || (o.paymentProofBase64?.isNotEmpty ?? false);
        final parsed = double.tryParse(amountReceived.text.trim());
        final parsedSupp = double.tryParse(supplementalAmount.text.trim());
        final ar = parsed;
        final pm = (o.paymentMode.isEmpty ? 'GCASH ONLY' : o.paymentMode).toUpperCase();
        final isGcash = pm.contains('GCASH');
        final stage = o.fulfillmentStage.toUpperCase();
        final paymentLocked = stage != 'PENDING_CASHIER';
        final amountLocked = o.cashierAmountReceived;
        final trackingReadOnly = o.deliveryTrackingUrl.trim().isNotEmpty;
        final statusUp = o.status.toUpperCase();
        final insufficientStatus = statusUp.contains('INSUFFICIENT');
        final hasSupProof = o.supplementalPaymentProofBase64?.trim().isNotEmpty ?? false;
        final pendingBalReview = o.balanceProofPendingReview && hasSupProof;
        final waitingCustomerBalance = insufficientStatus && !hasSupProof && stage == 'PENDING_CASHIER';
        final entered = parsed;
        final amountClassified = entered != null;
        final exactAmount = amountClassified && (entered - o.total).abs() <= 0.009;
        final insufficientAmount = amountClassified && entered + 0.009 < o.total;
        final overAmount = amountClassified && entered - o.total > 0.009;

        final paymentAtTop = stage == 'PENDING_CASHIER';
        final forDeliveryAtTop = stage == 'IN_PREPARATION';
        final trackingAtTop = stage == 'OUT_FOR_DELIVERY';

        return Scaffold(
      appBar: AppBar(
        backgroundColor: Colors.black87,
        foregroundColor: Colors.white,
        title: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(color: AppColors.brand, borderRadius: BorderRadius.circular(10)),
          child: const Text('CHECKOUT', style: TextStyle(color: AppColors.ink, fontWeight: FontWeight.w800)),
        ),
        centerTitle: true,
      ),
      body: Column(
        children: [
          Expanded(
            child: ListView(
              padding: const EdgeInsets.all(12),
              children: [
                if ((statusUp.contains('ORDER CONFIRMED') || statusUp.contains('OVERPAYMENT')) &&
                    o.loyaltyPointsEarned > 0)
                  Card(
                    color: Colors.amber.shade50,
                    child: ListTile(
                      leading: const Icon(Icons.card_giftcard_outlined),
                      title: Text(
                        'Customer loyalty this order: +${o.loyaltyPointsEarned} pts',
                        style: const TextStyle(fontWeight: FontWeight.w700),
                      ),
                    ),
                  ),
                if (paymentAtTop) ...[
                  ToggleSection(
                    title: 'PAYMENT',
                    titleColor: proofOk ? AppColors.brand : AppColors.accent,
                    expanded: showPayment,
                    onToggle: () => setState(() => showPayment = !showPayment),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        LockedField(label: 'PAYMENT METHOD', value: pm),
                        const SizedBox(height: 8),
                        if (paymentLocked) ...[
                          Padding(
                            padding: const EdgeInsets.symmetric(vertical: 12),
                            child: Text(
                              'PAYMENT IS COMPLETE!',
                              textAlign: TextAlign.center,
                              style: TextStyle(
                                fontWeight: FontWeight.w900,
                                fontSize: 17,
                                color: AppColors.success,
                                letterSpacing: 0.5,
                              ),
                            ),
                          ),
                          LockedField(
                            label: 'AMOUNT RECEIVED',
                            value: (amountLocked ?? parsed ?? 0).toStringAsFixed(2),
                          ),
                        ] else if (pendingBalReview) ...[
                          Card(
                            color: Colors.deepOrange.shade50,
                            child: const ListTile(
                              leading: Icon(Icons.mark_email_unread, color: Colors.deepOrange),
                              title: Text('Customer uploaded balance payment proof'),
                              subtitle: Text('Verify the supplemental proof and enter how much they paid for the balance.'),
                            ),
                          ),
                          const SizedBox(height: 10),
                          LockedField(
                            label: 'FIRST PAYMENT RECORDED',
                            value: (o.cashierAmountReceived ?? 0).toStringAsFixed(2),
                          ),
                          const SizedBox(height: 10),
                          TextField(
                            controller: supplementalAmount,
                            keyboardType: TextInputType.number,
                            decoration: const InputDecoration(
                              labelText: 'ADDITIONAL AMOUNT RECEIVED (balance)',
                            ),
                            onChanged: (_) => setState(() {}),
                          ),
                        ] else ...[
                          TextField(
                            controller: amountReceived,
                            keyboardType: TextInputType.number,
                            readOnly: insufficientStatus && (o.cashierAmountReceived != null),
                            decoration: InputDecoration(
                              labelText: 'AMOUNT RECEIVED',
                              helperText:
                                  insufficientStatus ? 'Recorded when payment was marked insufficient.' : null,
                            ),
                            onChanged: (_) => setState(() {}),
                          ),
                        ],
                        LockedField(label: 'AMOUNT DUE', value: o.total.toStringAsFixed(2)),
                        if (waitingCustomerBalance)
                          Padding(
                            padding: const EdgeInsets.only(top: 10),
                            child: Text(
                              'Waiting for the customer to upload balance payment proof in the app.',
                              style: TextStyle(color: Colors.deepOrange.shade900, fontWeight: FontWeight.w700),
                            ),
                          ),
                        if (!isGcash && !paymentLocked && !pendingBalReview)
                          Text(
                            'CHANGE: ₱${((ar ?? 0) - o.total).toStringAsFixed(2)}',
                            style: const TextStyle(fontWeight: FontWeight.w700),
                          ),
                        const SizedBox(height: 10),
                        OutlinedButton(
                          onPressed: o.paymentProofBase64 == null || o.paymentProofBase64!.isEmpty
                              ? null
                              : () {
                                  try {
                                    final bytes = base64Decode(o.paymentProofBase64!);
                                    showDialog<void>(
                                      context: context,
                                      builder: (ctx) => AlertDialog(
                                        title: const Text('Proof of payment'),
                                        content: Image.memory(Uint8List.fromList(bytes)),
                                        actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Close'))],
                                      ),
                                    );
                                  } catch (_) {
                                    appSnack(context, 'Could not display image');
                                  }
                                },
                          child: const Text('VIEW PROOF OF PAYMENT'),
                        ),
                        if (hasSupProof) ...[
                          const SizedBox(height: 8),
                          OutlinedButton(
                            onPressed: () {
                              try {
                                final bytes = base64Decode(o.supplementalPaymentProofBase64!.trim());
                                showDialog<void>(
                                  context: context,
                                  builder: (ctx) => AlertDialog(
                                    title: const Text('Balance payment proof'),
                                    content: SingleChildScrollView(
                                      child: Image.memory(Uint8List.fromList(bytes)),
                                    ),
                                    actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Close'))],
                                  ),
                                );
                              } catch (_) {
                                appSnack(context, 'Could not display image');
                              }
                            },
                            child: const Text('VIEW BALANCE PAYMENT PROOF'),
                          ),
                        ],
                        if (!paymentLocked && !insufficientStatus && !pendingBalReview) ...[
                          const SizedBox(height: 8),
                          FilledButton(
                            style: FilledButton.styleFrom(backgroundColor: AppColors.accent, foregroundColor: Colors.white),
                            onPressed: insufficientAmount ? () async {
                              if (!await _confirmDialog('Insufficient payment?', 'Notify the customer that payment is short?')) return;
                              final err = await widget.state.cashierReviewOrder(
                                orderId: o.id,
                                action: 'insufficient',
                                amountReceived: ar,
                              );
                              if (!context.mounted) return;
                              if (err != null) {
                                appSnack(context, err);
                                return;
                              }
                              appSnack(context, 'Customer notified (insufficient payment)');
                              Navigator.pop(context);
                            } : null,
                            child: const Text('INSUFFICIENT PAYMENT'),
                          ),
                          const SizedBox(height: 8),
                          FilledButton(
                            style: FilledButton.styleFrom(backgroundColor: AppColors.brand, foregroundColor: AppColors.ink),
                            onPressed: overAmount ? () async {
                              if (!await _confirmDialog('Overpayment?', 'Confirm order with overpayment notice?')) return;
                              final err = await widget.state.cashierReviewOrder(
                                orderId: o.id,
                                action: 'overpayment',
                                amountReceived: ar,
                              );
                              if (!context.mounted) return;
                              if (err != null) {
                                appSnack(context, err);
                                return;
                              }
                              appSnack(context, 'Customer notified (overpayment)');
                              Navigator.pop(context);
                            } : null,
                            child: const Text('OVERPAYMENT'),
                          ),
                        ],
                      ],
                    ),
                  ),
                  const SizedBox(height: 10),
                ],
                if (forDeliveryAtTop) ...[
                  Container(
                    width: double.infinity,
                    decoration: BoxDecoration(
                      color: Colors.red.shade50,
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: Colors.red.shade400, width: 1.5),
                    ),
                    padding: const EdgeInsets.all(8),
                    child: ToggleSection(
                      title: 'FOR DELIVERY',
                      expanded: true,
                      onToggle: () {},
                      hideToggleIcon: true,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          TextField(
                            controller: trackingUrl,
                            readOnly: trackingReadOnly,
                            decoration: InputDecoration(
                              labelText: 'Delivery tracking link (shown to customer)',
                              hintText: 'https://...',
                              filled: trackingReadOnly,
                              fillColor: trackingReadOnly ? Colors.grey.shade200 : null,
                            ),
                            onChanged: (_) => setState(() {}),
                          ),
                          const SizedBox(height: 10),
                          FilledButton(
                            onPressed: () async {
                              if (trackingUrl.text.trim().isEmpty) {
                                appSnack(context, 'Enter a tracking link for the customer.');
                                return;
                              }
                              if (!await _confirmDialog(
                                    'Send for delivery?',
                                    'Move this order to “for delivery” and save the tracking link?',
                                  )) {
                                return;
                              }
                              final err = await widget.state.cashierPatchFulfillment(
                                orderId: o.id,
                                fulfillmentStage: 'OUT_FOR_DELIVERY',
                                deliveryTrackingUrl: trackingUrl.text.trim(),
                              );
                              if (!context.mounted) return;
                              if (err != null) {
                                appSnack(context, err);
                                return;
                              }
                              appSnack(context, 'Tracking saved — customer can see it in order status');
                              Navigator.pop(context);
                            },
                            child: const Text('SAVE TRACKING & SEND FOR DELIVERY'),
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 10),
                ],
                if (trackingAtTop) ...[
                  ToggleSection(
                    title: 'TRACKING',
                    expanded: true,
                    onToggle: () {},
                    hideToggleIcon: true,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        SelectableText(o.deliveryTrackingUrl.trim().isEmpty ? '—' : o.deliveryTrackingUrl.trim()),
                        const SizedBox(height: 10),
                        FilledButton(
                          onPressed: () async {
                            if (!await _confirmDialog('Mark delivered?', 'Mark this order as delivered?')) return;
                            final err = await widget.state.cashierPatchFulfillment(
                              orderId: o.id,
                              fulfillmentStage: 'DELIVERED',
                              deliveryTrackingUrl: o.deliveryTrackingUrl,
                            );
                            if (!context.mounted) return;
                            if (err != null) {
                              appSnack(context, err);
                              return;
                            }
                            appSnack(context, 'Order marked delivered');
                            Navigator.pop(context);
                          },
                          child: const Text('MARK DELIVERED'),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 10),
                ],
                _OrderNoCard(displayNo: o.orderNo),
                const SizedBox(height: 10),
                ToggleSection(
                  title: 'ORDER SUMMARY',
                  expanded: true,
                  onToggle: () {},
                  hideToggleIcon: true,
                  child: Column(
                    children: [
                      LockedField(label: 'CUSTOMER', value: cashierCustomerLabel(o)),
                      LockedField(label: 'CUSTOMER EMAIL', value: o.userEmail?.trim().isNotEmpty == true ? o.userEmail! : '—'),
                      LockedField(label: 'ORDER STATUS', value: statusReadable(o.status)),
                      LockedField(label: 'FULFILLMENT STAGE', value: o.fulfillmentStage),
                      LockedField(label: 'ORDERED AT', value: formatDateTimeLocal(o.createdAt)),
                      LockedField(label: 'SUBTOTAL / TOTAL', value: '₱${o.total.toStringAsFixed(2)}'),
                    ],
                  ),
                ),
                const SizedBox(height: 10),
                ToggleSection(
                  title: 'DELIVERY INFORMATION',
                  expanded: showDelivery,
                  onToggle: () => setState(() => showDelivery = !showDelivery),
                  child: Column(
                    children: [
                      LockedField(label: 'NAME', value: o.deliveryName.isEmpty ? '—' : o.deliveryName),
                      LockedField(label: 'CONTACT NUMBER', value: o.deliveryContact.isEmpty ? '—' : o.deliveryContact),
                      LockedField(label: 'DELIVERY ADDRESS', value: o.deliveryAddress.isEmpty ? '—' : o.deliveryAddress),
                      LockedField(label: 'TIME OF DELIVERY', value: o.deliveryTime.isEmpty ? 'NOW' : o.deliveryTime),
                    ],
                  ),
                ),
                const SizedBox(height: 10),
                if (!paymentAtTop) ...[
                  ToggleSection(
                    title: 'PAYMENT',
                    titleColor: proofOk ? AppColors.brand : AppColors.accent,
                    expanded: showPayment,
                    onToggle: () => setState(() => showPayment = !showPayment),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        LockedField(label: 'PAYMENT METHOD', value: pm),
                        const SizedBox(height: 8),
                        if (paymentLocked) ...[
                          Padding(
                            padding: const EdgeInsets.symmetric(vertical: 12),
                            child: Text(
                              'PAYMENT IS COMPLETE!',
                              textAlign: TextAlign.center,
                              style: TextStyle(
                                fontWeight: FontWeight.w900,
                                fontSize: 17,
                                color: AppColors.success,
                                letterSpacing: 0.5,
                              ),
                            ),
                          ),
                          LockedField(
                            label: 'AMOUNT RECEIVED',
                            value: (amountLocked ?? parsed ?? 0).toStringAsFixed(2),
                          ),
                        ] else if (pendingBalReview) ...[
                          Card(
                            color: Colors.deepOrange.shade50,
                            child: const ListTile(
                              leading: Icon(Icons.mark_email_unread, color: Colors.deepOrange),
                              title: Text('Customer uploaded balance payment proof'),
                              subtitle: Text('Verify the supplemental proof and enter how much they paid for the balance.'),
                            ),
                          ),
                          const SizedBox(height: 10),
                          LockedField(
                            label: 'FIRST PAYMENT RECORDED',
                            value: (o.cashierAmountReceived ?? 0).toStringAsFixed(2),
                          ),
                          const SizedBox(height: 10),
                          TextField(
                            controller: supplementalAmount,
                            keyboardType: TextInputType.number,
                            decoration: const InputDecoration(
                              labelText: 'ADDITIONAL AMOUNT RECEIVED (balance)',
                            ),
                            onChanged: (_) => setState(() {}),
                          ),
                        ] else ...[
                          TextField(
                            controller: amountReceived,
                            keyboardType: TextInputType.number,
                            readOnly: insufficientStatus && (o.cashierAmountReceived != null),
                            decoration: InputDecoration(
                              labelText: 'AMOUNT RECEIVED',
                              helperText:
                                  insufficientStatus ? 'Recorded when payment was marked insufficient.' : null,
                            ),
                            onChanged: (_) => setState(() {}),
                          ),
                        ],
                        LockedField(label: 'AMOUNT DUE', value: o.total.toStringAsFixed(2)),
                        if (waitingCustomerBalance)
                          Padding(
                            padding: const EdgeInsets.only(top: 10),
                            child: Text(
                              'Waiting for the customer to upload balance payment proof in the app.',
                              style: TextStyle(color: Colors.deepOrange.shade900, fontWeight: FontWeight.w700),
                            ),
                          ),
                        if (!isGcash && !paymentLocked && !pendingBalReview)
                          Text(
                            'CHANGE: ₱${((ar ?? 0) - o.total).toStringAsFixed(2)}',
                            style: const TextStyle(fontWeight: FontWeight.w700),
                          ),
                        const SizedBox(height: 10),
                        OutlinedButton(
                          onPressed: o.paymentProofBase64 == null || o.paymentProofBase64!.isEmpty
                              ? null
                              : () {
                                  try {
                                    final bytes = base64Decode(o.paymentProofBase64!);
                                    showDialog<void>(
                                      context: context,
                                      builder: (ctx) => AlertDialog(
                                        title: const Text('Proof of payment'),
                                        content: Image.memory(Uint8List.fromList(bytes)),
                                        actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Close'))],
                                      ),
                                    );
                                  } catch (_) {
                                    appSnack(context, 'Could not display image');
                                  }
                                },
                          child: const Text('VIEW PROOF OF PAYMENT'),
                        ),
                        if (hasSupProof) ...[
                          const SizedBox(height: 8),
                          OutlinedButton(
                            onPressed: () {
                              try {
                                final bytes = base64Decode(o.supplementalPaymentProofBase64!.trim());
                                showDialog<void>(
                                  context: context,
                                  builder: (ctx) => AlertDialog(
                                    title: const Text('Balance payment proof'),
                                    content: SingleChildScrollView(
                                      child: Image.memory(Uint8List.fromList(bytes)),
                                    ),
                                    actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Close'))],
                                  ),
                                );
                              } catch (_) {
                                appSnack(context, 'Could not display image');
                              }
                            },
                            child: const Text('VIEW BALANCE PAYMENT PROOF'),
                          ),
                        ],
                        if (!paymentLocked && !insufficientStatus && !pendingBalReview) ...[
                          const SizedBox(height: 8),
                          FilledButton(
                            style: FilledButton.styleFrom(backgroundColor: AppColors.accent, foregroundColor: Colors.white),
                            onPressed: insufficientAmount ? () async {
                              if (!await _confirmDialog('Insufficient payment?', 'Notify the customer that payment is short?')) return;
                              final err = await widget.state.cashierReviewOrder(
                                orderId: o.id,
                                action: 'insufficient',
                                amountReceived: ar,
                              );
                              if (!context.mounted) return;
                              if (err != null) {
                                appSnack(context, err);
                                return;
                              }
                              appSnack(context, 'Customer notified (insufficient payment)');
                              Navigator.pop(context);
                            } : null,
                            child: const Text('INSUFFICIENT PAYMENT'),
                          ),
                          const SizedBox(height: 8),
                          FilledButton(
                            style: FilledButton.styleFrom(backgroundColor: AppColors.brand, foregroundColor: AppColors.ink),
                            onPressed: overAmount ? () async {
                              if (!await _confirmDialog('Overpayment?', 'Confirm order with overpayment notice?')) return;
                              final err = await widget.state.cashierReviewOrder(
                                orderId: o.id,
                                action: 'overpayment',
                                amountReceived: ar,
                              );
                              if (!context.mounted) return;
                              if (err != null) {
                                appSnack(context, err);
                                return;
                              }
                              appSnack(context, 'Customer notified (overpayment)');
                              Navigator.pop(context);
                            } : null,
                            child: const Text('OVERPAYMENT'),
                          ),
                        ],
                      ],
                    ),
                  ),
                  const SizedBox(height: 10),
                ],
                ToggleSection(
                  title: 'YOUR TRAY',
                  expanded: showTray,
                  onToggle: () => setState(() => showTray = !showTray),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (o.lines.isEmpty)
                        const Text('No dishes on file — refresh from the server if this looks wrong.')
                      else
                        ...o.lines.map(
                          (l) => ListTile(
                            dense: true,
                            title: Text(l.itemName),
                            subtitle: Text(l.dip.isEmpty ? '—' : l.dip),
                            trailing: Text('x${l.qty}  ₱${(l.qty * l.price).toStringAsFixed(2)}'),
                          ),
                        ),
                    ],
                  ),
                ),
                const SizedBox(height: 10),
                ToggleSection(
                  title: 'ORDER NOTE',
                  expanded: showNotes,
                  onToggle: () => setState(() => showNotes = !showNotes),
                  child: Text(o.note.isEmpty ? '—' : o.note),
                ),
              ],
            ),
          ),
          if (stage == 'PENDING_CASHIER') ...[
            if (waitingCustomerBalance)
              Container(
                width: double.infinity,
                color: Colors.orange.shade50,
                padding: const EdgeInsets.symmetric(vertical: 18, horizontal: 12),
                child: Column(
                  children: [
                    Text(
                      'Waiting for the customer to upload balance payment proof in the app. You can confirm once it appears above.',
                      textAlign: TextAlign.center,
                      style: TextStyle(fontWeight: FontWeight.w700, color: Colors.orange.shade900),
                    ),
                    const SizedBox(height: 10),
                    OutlinedButton.icon(
                      onPressed: () async {
                        final err = await widget.state.cashierRemindInsufficientOrder(orderId: o.id);
                        if (!context.mounted) return;
                        appSnack(context, err ?? 'Follow-up sent to customer');
                      },
                      icon: const Icon(Icons.notifications_active_outlined),
                      label: const Text('Follow up customer'),
                    ),
                  ],
                ),
              )
            else if (pendingBalReview)
              SummaryFooter(
                lines: [
                  SummaryLine('First payment recorded', '₱${(o.cashierAmountReceived ?? 0).toStringAsFixed(2)}'),
                  SummaryLine('Order total', '₱${o.total.toStringAsFixed(2)}', isTotal: true),
                ],
                actionLabel: 'CONFIRM ORDER',
                onAction: () async {
                  if (supplementalAmount.text.trim().isEmpty || parsedSupp == null) {
                    appSnack(context, 'Enter the additional amount received for the balance.');
                    return;
                  }
                  final suppAmt = parsedSupp;
                  if (suppAmt < 0) return;
                  final first = o.cashierAmountReceived ?? 0;
                  if (first + suppAmt < o.total - 1e-9) {
                    appSnack(context, 'First payment plus additional amount must cover the order total.');
                    return;
                  }
                  if (!await _confirmDialog(
                    'Confirm order?',
                    'Confirm ${o.orderNo} with an additional ₱${suppAmt.toStringAsFixed(2)} recorded toward payment?',
                  )) {
                    return;
                  }
                  final err = await widget.state.cashierReviewOrder(
                    orderId: o.id,
                    action: 'confirm',
                    supplementalAmountReceived: suppAmt,
                  );
                  if (!context.mounted) return;
                  if (err != null) {
                    appSnack(context, err);
                    return;
                  }
                  appSnack(context, 'Order confirmed — customer notified');
                  Navigator.pop(context);
                },
              )
            else
              SummaryFooter(
                lines: [
                  SummaryLine('TOTAL', '₱${o.total.toStringAsFixed(2)}', isTotal: true),
                ],
                actionLabel: 'CONFIRM ORDER',
                onAction: exactAmount ? () async {
                  if (amountReceived.text.trim().isEmpty) {
                    appSnack(context, 'Enter amount received.');
                    return;
                  }
                  if (parsed == null) {
                    appSnack(context, 'Enter a valid amount.');
                    return;
                  }
                  if ((ar ?? 0) < o.total) return;
                  if (isGcash && !proofOk) {
                    appSnack(context, 'Customer payment proof must be received before confirming.');
                    return;
                  }
                  if (!await _confirmDialog(
                    'Confirm order?',
                    'Confirm ${o.orderNo} for ₱${o.total.toStringAsFixed(2)} and notify the customer?',
                  )) {
                    return;
                  }
                  final err = await widget.state.cashierReviewOrder(
                    orderId: o.id,
                    action: 'confirm',
                    amountReceived: ar,
                  );
                  if (!context.mounted) return;
                  if (err != null) {
                    appSnack(context, err);
                    return;
                  }
                  appSnack(context, 'Order confirmed — customer notified');
                  Navigator.pop(context);
                } : (amountClassified ? () {
                  final kind = insufficientAmount
                      ? 'insufficient'
                      : (overAmount ? 'overpayment' : 'different');
                  appSnack(context, 'The amount received is $kind, not exact. Please use the matching action button.');
                } : null),
              ),
          ],
        ],
      ),
    );
      },
    );
  }
}
