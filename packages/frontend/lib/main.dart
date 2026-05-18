import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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
import 'features/event_design/event_theme_design_screen.dart';
import 'features/seating/seating_layout_editor_screen.dart';
import 'features/seating/seating_plan.dart';
import 'utils/allergen_ui.dart';
import 'utils/order_type_utils.dart';
import 'widgets/manager_theme_seating_blocks.dart';

/// Optional logical flavor at Dart level (`customer` / `staff`).
const String kAppFlavor = String.fromEnvironment('APP_FLAVOR', defaultValue: 'customer');
/// When `true`, login hides sign-up for staff/POS builds.
const bool kPosLoginBuild = bool.fromEnvironment('POS_LOGIN', defaultValue: false) || kAppFlavor == 'staff';

/// Paths declared under `flutter.assets` in pubspec.yaml.
class AppBrandAssets {
  AppBrandAssets._();
  static const String logo = 'assets/images/macrinasLogo.png';
  static const String logoDashboard = 'assets/images/macrinasLogo3.png';
  static const String logoCuratering = 'assets/images/curatering.png';
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
  /// Last used interval for [_realtimeSyncTimer] (3 staff / 4 customer); used to restart when role changes.
  int _realtimePollIntervalSec = 0;
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
          title: Text(uiOrderNo(o.orderNo)),
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
                      'Cancel ${uiOrderNo(o.orderNo)}? It will move to Cancelled orders.',
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
                              SnackBar(content: Text('${uiOrderNo(o.orderNo)} cancelled')),
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
          _realtimePollIntervalSec = 0;
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
        if (email != null &&
            !(appState.userRole == 'customer' && appState.isGuestSession)) {
          final every = (appState.isCashier || appState.isManagerOrSupervisor) ? 3 : 4;
          if (_realtimeSyncTimer == null || !_realtimeSyncTimer!.isActive || _realtimePollIntervalSec != every) {
            _realtimePollIntervalSec = every;
            _realtimeSyncTimer?.cancel();
            _realtimeSyncTimer = Timer.periodic(Duration(seconds: every), (_) => appState.pollRealtimeSync());
          }
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
                  cashierMode: widget.forcePosLogin || kPosLoginBuild || appState.reopenAuthAsStaff,
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
      return 'In this stage since';
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

/// Layout variant for manager catering order summary PDFs.
enum _ManagerOrderSummaryPdfVariant {
  /// Quote before down payment is received.
  beforeDownPayment,
  /// After down payment; balance still due until full payment.
  afterDownPayment,
  /// Supplemental sheet for post-analysis additional costs.
  additionalCostsSheet,
  /// Completed / fully settled totals.
  fullyPaid,
}
const double kRestaurantLat = 14.513436;
const double kRestaurantLng = 121.059198;
const double kDeliveryMaxDistanceKm = 5.0;
const List<String> kCateringAllowedRegions = [
  'ncr',
  'national capital region',
  'metro manila',
  'bulacan',
  'cavite',
  'rizal',
  'laguna',
];

double haversineKm({
  required double lat1,
  required double lng1,
  required double lat2,
  required double lng2,
}) {
  const r = 6371.0;
  final dLat = (lat2 - lat1) * math.pi / 180.0;
  final dLng = (lng2 - lng1) * math.pi / 180.0;
  final a = math.sin(dLat / 2) * math.sin(dLat / 2) +
      math.cos(lat1 * math.pi / 180.0) *
          math.cos(lat2 * math.pi / 180.0) *
          math.sin(dLng / 2) *
          math.sin(dLng / 2);
  final c = 2 * math.atan2(math.sqrt(a), math.sqrt(1 - a));
  return r * c;
}

/// Geocode [address] and return straight-line km from the restaurant (for delivery-radius checks).
Future<double?> geocodeAddressDistanceKmFromRestaurant(String address) async {
  final q = address.trim();
  if (q.isEmpty) return null;
  try {
    final uri = Uri.parse(
      'https://nominatim.openstreetmap.org/search?q=${Uri.encodeComponent(q)}&format=json&limit=1',
    );
    final res = await http.get(uri, headers: {'User-Agent': kNominatimUserAgent}).timeout(_apiTimeout);
    if (res.statusCode != 200) return null;
    final list = jsonDecode(res.body);
    if (list is! List || list.isEmpty) return null;
    final m = list.first;
    if (m is! Map) return null;
    final lat = jsonToDouble(m['lat']);
    final lng = jsonToDouble(m['lon']);
    return haversineKm(lat1: kRestaurantLat, lng1: kRestaurantLng, lat2: lat, lng2: lng);
  } catch (_) {
    return null;
  }
}

bool isAllowedCateringAddressInCoverage(String address) {
  final t = address.trim().toLowerCase();
  if (t.isEmpty) return false;
  final hasAllowedRegion = kCateringAllowedRegions.any((p) => t.contains(p));
  if (!hasAllowedRegion) return false;
  // Keep PH-only intent while still allowing local short entries (e.g. "Taguig, Metro Manila").
  if (t.contains('philippines') || t.contains('ph')) return true;
  return true;
}

String cateringCoverageErrorText() {
  return 'Service area is limited to NCR, Bulacan, Cavite, Rizal, and Laguna (Philippines).';
}

/// Shown at top of Restaurant Menu and My Catering Inquiries for customer awareness.
const String kCustomerOnlineOrdersAreaNotice =
    'Online orders are available within 5 km of our restaurant in Taguig City.';

const String kCustomerCateringInquiriesAreaNotice =
    'Our catering service is available in NCR, Bulacan, Cavite, Rizal, and Laguna ONLY.';

/// Legacy combined notice (avoid breaking imports); prefer the specific constants above.
const String kCustomerDeliveryAndCateringAreaNotice = kCustomerOnlineOrdersAreaNotice;

bool isWithinPast30Days(DateTime t) => DateTime.now().difference(t) <= const Duration(days: 30);

/// Catering/event loyalty (matches backend `loyalty-calculation` thresholds).
const double kCateringLoyaltyMinOrderTotal = 500;
const int kCateringLoyaltyPointsAward = 8;

/// Matches backend `loyaltyPointsFor('catering_event', total)`.
int cateringLoyaltyPointsForOrderTotal(double totalAmount) {
  if (!totalAmount.isFinite || totalAmount <= 0) return 0;
  return (totalAmount / kCateringLoyaltyMinOrderTotal).floor() * kCateringLoyaltyPointsAward;
}

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
    this.allergens = const [],
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
  final List<String> allergens;
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
    if (isRestaurantDish) return false;
    final c = category.toLowerCase().trim();
    final t = dishType.toLowerCase().trim();
    if (c == 'catering' || c.contains('catering')) return true;
    if (t == 'catering' || t.contains('catering')) return true;
    return c.isEmpty;
  }
}

/// Extra add-on units beyond the first (per main dish qty) are charged this amount (matches server).
const double kRestaurantAddonExtraPhp = 15;

double cartLineSubtotal(CartItem item) {
  final dip = item.dip.trim();
  final hasDip = dip.isNotEmpty;
  final dq = hasDip ? item.dipQty.clamp(0, 999999) : 0;
  final extra = hasDip ? math.max(0, dq - 1) * kRestaurantAddonExtraPhp * item.qty : 0;
  return item.qty * item.menu.price + extra;
}

class CartItem {
  CartItem({
    required this.menu,
    this.dip = '',
    this.dipQty = 1,
    this.qty = 1,
  });

  final MenuItemData menu;
  String dip;
  /// Portions of add-on when a dip/sauce is selected; first unit has no extra charge.
  int dipQty;
  int qty;
}

class ProfileData {
  ProfileData({
    this.fullName = '',
    this.contactNumber = '',
    this.contactEmail = '',
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
  /// Contact email (guest checkout / inquiry); not persisted to profile API for registered users unless added server-side.
  String contactEmail;
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

/// Sum of positive catering loyalty entries (completed catering / catering+event awards from history).
int cateringCompletedLoyaltyEarnedFromHistory(List<LoyaltyHistoryItem> history) {
  return history
      .where((h) => h.source == 'catering' && h.pointsDelta > 0)
      .fold<int>(0, (sum, h) => sum + h.pointsDelta);
}

class OrderLineItem {
  OrderLineItem({
    required this.itemName,
    required this.dip,
    this.dipQty = 1,
    required this.qty,
    required this.price,
  });

  final String itemName;
  final String dip;
  final int dipQty;
  final int qty;
  final double price;
}

double orderLineSubtotal(OrderLineItem line) {
  final dip = line.dip.trim();
  final hasDip = dip.isNotEmpty;
  final dq = hasDip ? line.dipQty.clamp(0, 999999) : 0;
  final extra = hasDip ? math.max(0, dq - 1) * kRestaurantAddonExtraPhp * line.qty : 0;
  return line.qty * line.price + extra;
}

double cartAddonExtraSubtotal(CartItem item) {
  final dip = item.dip.trim();
  if (dip.isEmpty) return 0;
  final dq = item.dipQty.clamp(0, 999999);
  return math.max(0, dq - 1) * kRestaurantAddonExtraPhp * item.qty;
}

double orderLineAddonExtraSubtotal(OrderLineItem line) {
  final dip = line.dip.trim();
  if (dip.isEmpty) return 0;
  final dq = line.dipQty.clamp(0, 999999);
  return math.max(0, dq - 1) * kRestaurantAddonExtraPhp * line.qty;
}

/// Subtitle for tray/checkout: main price, add-on qty and extra charge, line total.
String cartLineDetailSubtitle(CartItem e) {
  final main = 'Main ×${e.qty} @ ₱${e.menu.price.toStringAsFixed(2)}';
  final dip = e.dip.trim();
  if (dip.isEmpty) return '$main · ₱${cartLineSubtotal(e).toStringAsFixed(2)}';
  final extra = cartAddonExtraSubtotal(e);
  final addOn =
      'Add-on: $dip × ${e.dipQty}${extra > 0 ? ' · +₱${extra.toStringAsFixed(0)} extra' : (e.dipQty == 0 ? ' · no extra portions' : ' · included')}';
  return '$main\n$addOn · ₱${cartLineSubtotal(e).toStringAsFixed(2)}';
}

String orderLineDetailSubtitle(OrderLineItem l) {
  final main = 'Main ×${l.qty} @ ₱${l.price.toStringAsFixed(2)}';
  final dip = l.dip.trim();
  if (dip.isEmpty) return '$main · ₱${orderLineSubtotal(l).toStringAsFixed(2)}';
  final extra = orderLineAddonExtraSubtotal(l);
  final addOn =
      'Add-on: $dip × ${l.dipQty}${extra > 0 ? ' · +₱${extra.toStringAsFixed(0)} extra' : (l.dipQty == 0 ? ' · no extra portions' : ' · included')}';
  return '$main\n$addOn · ₱${orderLineSubtotal(l).toStringAsFixed(2)}';
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
          dipQty: math.max(0, jsonToInt(m['dip_qty'], 1)),
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
    this.paymentReferenceInitial,
    this.paymentReferenceBalance,
    this.guestContactEmail,
    this.orderFullName,
    this.orderContactNumber,
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
  /// GCash / bank reference entered on web checkout (not an image).
  final String? paymentReferenceInitial;
  final String? paymentReferenceBalance;
  final String? guestContactEmail;
  /// Canonical name on the order row (`full_name`), when set by web or checkout.
  final String? orderFullName;
  final String? orderContactNumber;
}

bool looksLikeBase64ImageProof(String? raw) {
  final s = raw?.trim();
  if (s == null || s.isEmpty) return false;
  if (s.startsWith('data:image')) return true;
  if (s.length < 120) return false;
  try {
    base64Decode(s.length > 256 ? s.substring(0, 256) : s);
    return true;
  } catch (_) {
    return false;
  }
}

String? orderPaymentReferenceInitial(OrderData o) {
  final r = o.paymentReferenceInitial?.trim();
  if (r != null && r.isNotEmpty) return r;
  final p = o.paymentProofBase64?.trim();
  if (p != null && p.isNotEmpty && !looksLikeBase64ImageProof(p)) return p;
  return null;
}

String? orderPaymentReferenceBalance(OrderData o) {
  final r = o.paymentReferenceBalance?.trim();
  if (r != null && r.isNotEmpty) return r;
  final p = o.supplementalPaymentProofBase64?.trim();
  if (p != null && p.isNotEmpty && !looksLikeBase64ImageProof(p)) return p;
  return null;
}

bool orderHasInitialPaymentProofImage(OrderData o) => looksLikeBase64ImageProof(o.paymentProofBase64);

bool orderHasBalancePaymentProofImage(OrderData o) => looksLikeBase64ImageProof(o.supplementalPaymentProofBase64);

bool orderHasPaymentOnFile(OrderData o) =>
    o.paymentUploaded || orderPaymentReferenceInitial(o) != null || orderHasInitialPaymentProofImage(o);

List<Widget> cashierPaymentProofAndReferenceSection(
  BuildContext context,
  OrderData o, {
  bool includeBalance = true,
}) {
  final widgets = <Widget>[];
  final initRef = orderPaymentReferenceInitial(o);
  if (initRef != null) {
    widgets.add(LockedField(label: 'PAYMENT REFERENCE (full)', value: initRef));
    widgets.add(const SizedBox(height: 8));
  }
  if (includeBalance) {
    final balRef = orderPaymentReferenceBalance(o);
    if (balRef != null) {
      widgets.add(LockedField(label: 'PAYMENT REFERENCE (balance)', value: balRef));
      widgets.add(const SizedBox(height: 8));
    }
  }
  if (orderHasInitialPaymentProofImage(o)) {
    widgets.add(
      OutlinedButton(
        onPressed: () {
          try {
            final bytes = base64Decode(o.paymentProofBase64!.trim());
            showProofFullScreen(context, Uint8List.fromList(bytes), title: 'Proof of payment');
          } catch (_) {
            appSnack(context, 'Could not display image');
          }
        },
        child: const Text('VIEW PROOF OF PAYMENT'),
      ),
    );
  }
  if (includeBalance && orderHasBalancePaymentProofImage(o)) {
    if (widgets.isNotEmpty) widgets.add(const SizedBox(height: 8));
    widgets.add(
      OutlinedButton(
        onPressed: () {
          try {
            final bytes = base64Decode(o.supplementalPaymentProofBase64!.trim());
            showProofFullScreen(context, Uint8List.fromList(bytes), title: 'Balance payment proof');
          } catch (_) {
            appSnack(context, 'Could not display image');
          }
        },
        child: const Text('VIEW BALANCE PAYMENT PROOF'),
      ),
    );
  }
  return widgets;
}

OrderData orderDataFromApiMap(Map<String, dynamic> map, List<OrderLineItem> lines) {
  final proofRaw = map['payment_proof'];
  final proofStr = proofRaw != null ? '$proofRaw'.trim() : '';
  final supRaw = map['supplemental_payment_proof'];
  final supStr = supRaw != null ? '$supRaw'.trim() : '';
  final refInit = '${map['payment_reference_initial'] ?? ''}'.trim();
  final refBal = '${map['payment_reference_balance'] ?? ''}'.trim();
  final guestEm = '${map['guest_contact_email'] ?? ''}'.trim();
  final fullName = '${map['full_name'] ?? ''}'.trim();
  final contactNum = '${map['contact_number'] ?? ''}'.trim();
  return OrderData(
    id: jsonToInt(map['id']),
    orderNo: orderNoFromApiMap(map),
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
    paymentReferenceInitial: refInit.isEmpty ? null : refInit,
    paymentReferenceBalance: refBal.isEmpty ? null : refBal,
    guestContactEmail: guestEm.isEmpty ? null : guestEm,
    orderFullName: fullName.isEmpty ? null : fullName,
    orderContactNumber: contactNum.isEmpty ? null : contactNum,
  );
}

String cashierCustomerLabel(OrderData o) {
  final n = o.customerDisplayName?.trim();
  if (n != null && n.isNotEmpty) return n;
  final fn = o.orderFullName?.trim();
  if (fn != null && fn.isNotEmpty) return fn;
  final dn = o.deliveryName.trim();
  if (dn.isNotEmpty) return dn;
  final guest = o.guestContactEmail?.trim();
  if (guest != null && guest.isNotEmpty) return guest;
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

/// Confirmed-tab delivery: show cashier tracking when URL is set and order is in a delivery phase.
bool orderShowsDeliveryTrackingLink(OrderData o) {
  if (o.deliveryTrackingUrl.trim().isEmpty) return false;
  final fs = o.fulfillmentStage.toUpperCase();
  if (fs == 'OUT_FOR_DELIVERY') return true;
  final st = o.status.toUpperCase();
  if (st.contains('FOR DELIVERY') || st.contains('OUT FOR DELIVERY')) return true;
  return false;
}

/// Prefer business `order_id` (ORD-******) over legacy `order_no` alias.
String orderNoFromApiMap(Map<String, dynamic> map) {
  var orderId = '${map['order_id'] ?? ''}'.trim();
  if (orderId.isEmpty || orderId.toUpperCase() == 'TEMP') {
    orderId = '${map['order_no'] ?? ''}'.trim();
  }
  if (orderId.isNotEmpty && orderId.toUpperCase() != 'TEMP') return orderId;
  final mid = map['id'] ?? map['mobile_id'];
  if (mid != null) {
    final n = int.tryParse('$mid');
    if (n != null && n > 0) return 'ORD-${n.toString().padLeft(6, '0')}';
  }
  return '';
}

/// UI-only formatting for customer-facing order numbers.
/// Backend stores values like `Order No. 000123`; mobile should show `ORD-000123`.
String uiOrderNo(String raw) {
  final s = raw.trim();
  if (s.isEmpty) return '—';
  if (s.toUpperCase().startsWith('ORD-')) return s.toUpperCase();
  final digits = s.replaceAll(RegExp(r'\D'), '');
  if (digits.isEmpty) return s;
  final last6 = digits.length >= 6 ? digits.substring(digits.length - 6) : digits.padLeft(6, '0');
  return 'ORD-$last6';
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
  final hasBalanceProof = orderPaymentReferenceBalance(o) != null ||
      orderHasBalancePaymentProofImage(o) ||
      o.balanceProofPendingReview;
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
      return 'For Down Payment';
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

String cateringManagerListStatusLabelFor(String status, String processingSubstageLabel) {
  final low = status.trim().toLowerCase();
  if (low == 'for_processing') {
    return processingSubstageLabel == 'ongoing' ? 'On Going' : 'For Down Payment';
  }
  return inquiryStatusReadable(status);
}

/// Detail AppBar: tab the order is in (not generic status text).
String cateringManagerDetailTabTitle(
  CateringEventRecord row,
  String detailStage, {
  String? processingSubstageOverride,
}) {
  switch (detailStage.trim().toLowerCase()) {
    case 'online_inquiries':
      return 'Online Inquiries';
    case 'new_event':
      return 'New Event';
    case 'for_post_analysis':
      return 'For Full Payment';
    case 'completed':
      return 'Completed';
    case 'cancelled':
      return 'Cancelled';
    case 'for_processing':
      final sub = (processingSubstageOverride ?? row.processingSubstageLabel).trim();
      return sub == 'ongoing' ? 'On Going' : 'For Down Payment';
    default:
      return cateringManagerListStatusLabelFor(row.status, row.processingSubstageLabel);
  }
}

const TextStyle kManagerAppBarTitleStyle = TextStyle(fontWeight: FontWeight.w800, fontSize: 16);

/// Stages whose additional costs appear on Order Summary | Additional Costs (not draft inquiries).
const Set<String> kManagerAdditionalCostsSheetStageLabels = {
  'For Down Payment',
  'On Going',
  'For Full Payment',
};

bool _isManagerAdditionalCostsSheetStage(String stageLabel) =>
    kManagerAdditionalCostsSheetStageLabels.contains(stageLabel.trim());

/// Post-draft additional costs total for payment gates (from saved groups on a row).
double cateringCompiledAdditionalCostsTotal(CateringEventRecord row) {
  var sum = 0.0;
  final groups = row.postAnalysis['additional_costs_groups'];
  if (groups is List) {
    for (final g in groups) {
      if (g is! Map) continue;
      if (!_isManagerAdditionalCostsSheetStage('${g['stage'] ?? ''}')) continue;
      final items = g['items'];
      if (items is List) {
        for (final e in items) {
          if (e is Map) sum += jsonToDouble(e['amount']);
        }
      }
    }
  }
  return sum;
}

Future<bool> openGoogleMapsForAddress(
  String address, {
  double? lat,
  double? lng,
}) async {
  final q = address.trim();
  if (q.isEmpty) return false;
  final encoded = Uri.encodeComponent(q);
  final uris = <Uri>[
    if (lat != null && lng != null)
      Uri.parse('https://www.google.com/maps/search/?api=1&query=$lat,$lng'),
    Uri.parse('https://www.google.com/maps/search/?api=1&query=$encoded'),
    Uri.parse('geo:0,0?q=$encoded'),
    Uri.parse('https://maps.google.com/maps?q=$encoded'),
    Uri.parse('comgooglemaps://?q=$encoded'),
  ];
  for (final uri in uris) {
    try {
      final ok = await launchUrl(uri, mode: LaunchMode.externalApplication);
      if (ok) return true;
    } catch (_) {
      /* try next scheme */
    }
  }
  return false;
}

/// Tappable venue line for manager lists and detail (opens map preview dialog).
Widget buildEventVenueAddressLink(
  BuildContext context,
  String address, {
  String prefix = 'Venue',
  TextStyle? style,
}) {
  final addr = address.trim();
  if (addr.isEmpty) {
    return Text('$prefix: —', style: style);
  }
  return Wrap(
    crossAxisAlignment: WrapCrossAlignment.center,
    children: [
      Text('$prefix: ', style: style),
      InkWell(
        onTap: () => showEventVenueMapPreview(context, addr),
        child: Text(
          addr,
          style: (style ?? const TextStyle(height: 1.35)).copyWith(
            color: Colors.blue.shade800,
            decoration: TextDecoration.underline,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
    ],
  );
}

Future<void> showEventVenueMapPreview(BuildContext context, String address) async {
  final q = address.trim();
  if (q.isEmpty) {
    appSnack(context, 'No event venue address to show.');
    return;
  }
  await showDialog<void>(
    context: context,
    builder: (ctx) => _EventVenueMapPreviewDialog(address: q),
  );
}

int paxBufferFromCateringRow(CateringEventRecord row) {
  if (row.paxBuffer > 0) return row.paxBuffer;
  final td = row.themeDesign;
  final raw = td['pax_buffer'] ?? row.postAnalysis['pax_buffer'];
  if (raw is num) return raw.toInt().clamp(0, 999999);
  final n = int.tryParse('$raw'.trim());
  return (n == null || n < 0) ? 0 : n;
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

/// Blocking loading dialog for cashier POS; pops automatically when [future] completes.
Future<T?> withCashierBlockingProgress<T>(
  BuildContext context,
  String message,
  Future<T> future,
) async {
  showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (ctx) => AlertDialog(
      content: Row(
        children: [
          const SizedBox(width: 8),
          const SizedBox(
            width: 28,
            height: 28,
            child: CircularProgressIndicator(strokeWidth: 3),
          ),
          const SizedBox(width: 20),
          Expanded(child: Text(message)),
        ],
      ),
    ),
  );
  try {
    return await future;
  } finally {
    if (context.mounted) Navigator.of(context).pop();
  }
}

/// Edit dialog for a single additional-cost line (label + amount).
Future<Map<String, dynamic>?> promptAdditionalCostLineItem(
  BuildContext context, {
  String initialLabel = '',
  double? initialAmount,
}) async {
  final labelCtrl = TextEditingController(text: initialLabel);
  final amountCtrl = TextEditingController(
    text: initialAmount != null && initialAmount > 0 ? initialAmount.toStringAsFixed(2) : '',
  );
  final ok = await showDialog<bool>(
    context: context,
    builder: (dlgCtx) => AlertDialog(
      title: Text(initialLabel.isEmpty ? 'Add additional cost' : 'Edit additional cost'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            controller: labelCtrl,
            decoration: const InputDecoration(labelText: 'Label'),
            textCapitalization: TextCapitalization.sentences,
          ),
          const SizedBox(height: 10),
          TextField(
            controller: amountCtrl,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: const InputDecoration(labelText: 'Amount'),
          ),
        ],
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(dlgCtx, false), child: const Text('Cancel')),
        FilledButton(onPressed: () => Navigator.pop(dlgCtx, true), child: const Text('Save')),
      ],
    ),
  );
  final label = labelCtrl.text.trim();
  final amount = double.tryParse(amountCtrl.text.trim());
  labelCtrl.dispose();
  amountCtrl.dispose();
  if (ok != true || label.isEmpty || amount == null) return null;
  return {'label': label, 'amount': amount};
}

String additionalCostsSummaryForPdf(List<Map<String, dynamic>> costs) {
  final labels = costs.map((e) => '${e['label'] ?? ''}'.trim()).where((x) => x.isNotEmpty);
  if (labels.isEmpty) return '—';
  return labels.join(' · ');
}

/// Returns true when the manager chooses to continue after an insufficient/excessive payment warning.
Future<bool> confirmManagerPaymentAmountMismatch(
  BuildContext context, {
  required String paymentLabel,
  required double amountEntered,
  required double amountDue,
}) async {
  const tolerance = 0.01;
  if ((amountEntered - amountDue).abs() <= tolerance) return true;
  final insufficient = amountEntered < amountDue - tolerance;
  final proceed = await showDialog<bool>(
    context: context,
    builder: (dlgCtx) => AlertDialog(
      title: Text(
        insufficient ? '$paymentLabel — insufficient payment' : '$paymentLabel — excessive payment',
      ),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            insufficient
                ? 'The amount entered is less than the amount due.'
                : 'The amount entered is more than the amount due.',
            style: TextStyle(
              fontWeight: FontWeight.w700,
              color: insufficient ? Colors.orange.shade900 : Colors.red.shade900,
            ),
          ),
          const SizedBox(height: 12),
          Text('Amount entered', style: TextStyle(fontSize: 12, color: Colors.grey.shade700)),
          Text(
            'PHP ${amountEntered.toStringAsFixed(2)}',
            style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 18),
          ),
          const SizedBox(height: 8),
          Text('Amount due', style: TextStyle(fontSize: 12, color: Colors.grey.shade700)),
          Text(
            'PHP ${amountDue.toStringAsFixed(2)}',
            style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 16),
          ),
          const SizedBox(height: 12),
          const Text('Continue with this payment amount?'),
        ],
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(dlgCtx, false), child: const Text('Go back')),
        FilledButton(onPressed: () => Navigator.pop(dlgCtx, true), child: const Text('Continue anyway')),
      ],
    ),
  );
  return proceed == true;
}

int cashierOnlinePendingSortPriority(OrderData o) {
  final u = statusReadableForOrder(o).toUpperCase();
  if (u.contains('BALANCE PAYMENT CONFIRMATION') ||
      u.contains('WAITING FOR BALANCE') ||
      (o.balanceProofPendingReview && (o.supplementalPaymentProofBase64?.trim().isNotEmpty ?? false))) {
    return 0;
  }
  if (u.contains('WAITING FOR PAYMENT CONFIRMATION') ||
      u.contains('WAITING FOR ORDER CONFIRMATION') ||
      u.contains('WAITING FOR ORDER')) {
    return 1;
  }
  if (u.contains('INSUFFICIENT') || u.contains('PAYMENT INSUFFICIENT')) {
    return 2;
  }
  return 3;
}

bool orderMatchesCashierOnlinePendingFilter(OrderData o, String mode) {
  final u = statusReadableForOrder(o).toUpperCase();
  switch (mode) {
    case 'past_30':
      return isWithinPast30Days(o.createdAt);
    case 'wait_payment':
      return u.contains('WAITING FOR PAYMENT CONFIRMATION') ||
          u.contains('WAITING FOR ORDER CONFIRMATION') ||
          u.contains('WAITING FOR ORDER');
    case 'payment_insufficient':
      return u.contains('INSUFFICIENT') || u.contains('PAYMENT INSUFFICIENT');
    case 'wait_balance':
      return u.contains('BALANCE PAYMENT CONFIRMATION') ||
          u.contains('WAITING FOR BALANCE') ||
          (o.balanceProofPendingReview && (o.supplementalPaymentProofBase64?.trim().isNotEmpty ?? false));
    default:
      return true;
  }
}

bool orderMatchesCashierOnlinePreparingFilter(OrderData o, String mode) {
  final u = o.status.toUpperCase();
  switch (mode) {
    case 'payment_confirmed':
      return u.contains('ORDER CONFIRMED') && !u.contains('OVERPAYMENT');
    case 'overpayment':
      return u.contains('OVERPAYMENT');
    default:
      return true;
  }
}

bool orderMatchesCashierOnlineDeliveredFilter(OrderData o, String mode) {
  final pm = o.paymentMode.toUpperCase();
  switch (mode) {
    case 'past_30':
      return isWithinPast30Days(o.createdAt);
    case 'balance_proof':
      return (o.supplementalPaymentProofBase64?.trim().isNotEmpty ?? false);
    case 'cash':
      return pm.contains('CASH') && !pm.contains('GCASH');
    case 'gcash':
      return pm.contains('GCASH');
    default:
      return true;
  }
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
    this.themeDesign = const {},
    this.seatingPlan = const {},
    this.orderKind = 'catering',
  });

  final String id;
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
  final Map<String, dynamic> themeDesign;
  final Map<String, dynamic> seatingPlan;
  final String orderKind;

  bool get isCateringPlusEvent =>
      inquiryType.trim().toUpperCase() == 'CATERING AND EVENT' ||
      orderKind == 'event' ||
      isCateringPlusEventOrderType(orderKind, eventTitle: eventTitle);

  /// Seating layout is manager-only; customers do not access seating in the app.
  bool get canShowSeating => false;

  bool get canEditSeating => false;

  bool get canEditThemeDesign {
    if (!isCateringPlusEvent) return false;
    const allowed = {'online_inquiries', 'new_event', 'for_processing', 'for_post_analysis'};
    return allowed.contains(status.trim().toLowerCase());
  }

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

/// Sum of loyalty credits shown on completed catering / catering+event inquiries in the app.
int cateringCompletedLoyaltyFromInquiries(List<InquiryRecord> inquiries) {
  return inquiries
      .where((r) => r.isCompletedBooking && r.loyaltyPointsEarned > 0)
      .fold<int>(0, (sum, r) => sum + r.loyaltyPointsEarned);
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
    this.paxBuffer = 0,
    this.orderType = '',
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
    this.seatingPlan = const {},
    this.serviceIncluded = '',
    this.formalityLevel = '',
    this.eventSetting = '',
    this.schedulePreview = '',
    this.processingScheduleOverlaps = 0,
    this.cateringLoyaltyPointsEarned = 0,
    this.checklistCountSummary = 0,
    this.processingPhaseSk = '',
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
  final int paxBuffer;
  final String orderType;
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
  final Map<String, dynamic> seatingPlan;
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

  /// List summary only: checklist row count (for processing substage).
  final int checklistCountSummary;

  /// List summary: `post_analysis.processing_phase` (`down_payment` | `ongoing`).
  final String processingPhaseSk;

  /// While [status] is `for_processing`: which workflow tab this row belongs in.
  String get processingSubstageLabel {
    if (status.trim().toLowerCase() != 'for_processing') return '';
    final p = processingPhaseSk.trim().toLowerCase();
    if (p == 'ongoing') return 'ongoing';
    if (p == 'down_payment') return 'down_payment';
    if (checklistCountSummary > 0) return 'ongoing';
    var filledChecklistRows = 0;
    for (final c in checklist) {
      if (c is Map) {
        final it = '${c['item'] ?? ''}'.trim();
        if (it.isNotEmpty) filledChecklistRows++;
      } else if ('$c'.trim().isNotEmpty) {
        filledChecklistRows++;
      }
    }
    if (filledChecklistRows > 0) return 'ongoing';
    return 'down_payment';
  }

  int get cateringLoyaltyEligiblePointsIfCompleted => cateringLoyaltyPointsForOrderTotal(totalCost);

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
      paxBuffer: jsonToInt(m['pax_buffer']),
      orderType: '${m['order_type'] ?? ''}',
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
      seatingPlan: () {
        final raw = m['seating_plan'];
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
      checklistCountSummary: jsonToInt(m['checklist_count_summary']),
      processingPhaseSk: '${m['processing_phase_sk'] ?? ''}',
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

/// Down payment (50%) treated as confirmed when the manager sets [manager_down_payment_confirmed] or legacy amounts match [downDue].
bool cateringDownPaymentConfirmed(CateringEventRecord r, double downDue) {
  if (downDue <= 0) return true;
  if (r.postAnalysis['manager_down_payment_confirmed'] == true) return true;
  final st = r.downPaymentStatus.trim().toLowerCase();
  final hasAmt = r.downPaymentAmount > 0 && r.downPaymentAmount >= downDue * 0.99;
  return hasAmt && (st.isEmpty || st == 'paid');
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
  final List<String> allergenCatalog = [];
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
  final List<OrderData> cashierWalkInCancelled = [];
  final Map<String, List<CateringEventRecord>> _managerCateringByStage = {};
  final List<LoyaltyHistoryItem> loyaltyHistory = [];
  bool showLoginWelcomeDialog = false;
  /// Bumped on [logout] so [AuthScreen] state resets (fixes staff re-login without app restart).
  int authSessionKey = 0;
  /// When true, the combined app opens [AuthScreen] in staff mode after a staff session ended.
  bool reopenAuthAsStaff = false;
  /// After [requestAuthSignup], [AuthScreen] opens in sign-up mode.
  bool openAuthInSignupMode = false;
  /// Guest tapped Sign Up — after account creation, require a fresh login (no auto session).
  bool signupFromGuestPrompt = false;
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
  /// Last cashier list/load failure (online or walk-in queues).
  String? cashierDataLoadError;
  DateTime? _cashierWalkInQueuesLoadedAt;
  DateTime? _cashierOrderHistoryLoadedAt;
  bool _loadSetMenusInFlight = false;
  bool _loadAllergensInFlight = false;
  DateTime? _allergensLoadedAt;
  bool _loadLoyaltyHistoryInFlight = false;
  bool _loadMenuInFlight = false;
  DateTime? _setMenusLoadedAt;
  DateTime? _loyaltyHistoryLoadedAt;
  bool get hasCashierAttentionBadge => cashierOnlineOrders.any((o) => o.balanceProofPendingReview);
  List<CateringEventRecord> managerRowsForStage(String stage) =>
      List.unmodifiable(_managerCateringByStage[stage] ?? const <CateringEventRecord>[]);

  int managerCateringCountForTab(int tabIdx) {
    switch (tabIdx) {
      case 0:
        return managerRowsForStage('new_event').length;
      case 1:
        return managerRowsForStage('online_inquiries').length;
      case 2:
        return managerRowsForStage('for_processing').where((e) => e.processingSubstageLabel == 'down_payment').length;
      case 3:
        return managerRowsForStage('for_processing').where((e) => e.processingSubstageLabel == 'ongoing').length;
      case 4:
        return managerRowsForStage('for_post_analysis').length;
      default:
        return 0;
    }
  }

  Future<void> preloadManagerDashboardCounts() async {
    await Future.wait([
      loadManagerCateringByStage('new_event', force: true),
      loadManagerCateringByStage('online_inquiries', force: true),
      loadManagerCateringByStage('for_processing', force: true),
      loadManagerCateringByStage('for_post_analysis', force: true),
    ]);
  }

  /// Rows for the last manager tab API stage ([_managerActiveStage]).
  List<CateringEventRecord> get managerCateringRows => managerRowsForStage(_managerActiveStage);

  bool get hasManagerAttentionBadge => _managerCateringByStage.values.any(
        (list) => list.any((r) => r.status == 'new_event' || r.status == 'online_inquiries'),
      );
  bool get hasAnyAttentionBadge =>
      unreadNotificationsCount > 0 || hasCashierAttentionBadge || hasManagerAttentionBadge;

  bool get isCashier => userRole == 'cashier';
  bool get isGuestSession {
    final em = (userEmail ?? '').trim().toLowerCase();
    return em.endsWith('@guest.curatering.internal');
  }
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
        await loadNotifications(force: true);
      } else if (isManagerOrSupervisor) {
        await Future.wait([
          loadMenu(force: true),
          loadSetMenus(force: true),
          loadManagerCateringByStage('new_event', force: true),
        ]);
        await loadNotifications(force: true);
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
      reopenAuthAsStaff = false;
      if (userRole == 'customer') {
        authSessionKey++;
      }
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
    bool loginAfter = true,
  }) async {
    try {
      final res = await http
          .post(
            _uri('/api/mobile/auth/signup/complete'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({
              'email': email.trim(),
              'otp': otp.replaceAll(RegExp(r'\D'), '').trim(),
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
      if (!loginAfter) return null;
      return await login(email, password);
    } catch (e) {
      return describeApiNetworkError(e, normalizeApiBase(apiBase));
    }
  }

  /// `(ok: true)` when OTP was sent; `notRegistered: true` when identity is unknown (customer only).
  Future<({bool ok, bool notRegistered, String? error})> requestPasswordReset({
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
      if (res.statusCode == 404) {
        try {
          final err = jsonDecode(res.body) as Map<String, dynamic>;
          if ('${err['error']}' == 'not_registered') {
            return (ok: false, notRegistered: true, error: null);
          }
        } catch (_) {}
      }
      if (res.statusCode != 200) {
        try {
          final err = jsonDecode(res.body) as Map<String, dynamic>;
          return (
            ok: false,
            notRegistered: false,
            error: '${err['error'] ?? 'Could not request password reset'}',
          );
        } catch (_) {
          return (
            ok: false,
            notRegistered: false,
            error: 'Could not request password reset (${res.statusCode})',
          );
        }
      }
      return (ok: true, notRegistered: false, error: null);
    } catch (e) {
      return (ok: false, notRegistered: false, error: describeApiNetworkError(e, normalizeApiBase(apiBase)));
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
              'otp': otp.replaceAll(RegExp(r'\D'), '').trim(),
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

  Future<String?> verifyPasswordResetOtp({
    required String identity,
    required String otp,
    required String role,
  }) async {
    try {
      final res = await http
          .post(
            _uri('/api/mobile/auth/check-password-reset-otp'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({
              'identity': identity.trim(),
              'otp': otp.replaceAll(RegExp(r'\D'), '').trim(),
              'role': role,
            }),
          )
          .timeout(_apiTimeout);
      if (res.statusCode != 200) {
        try {
          final err = jsonDecode(res.body) as Map<String, dynamic>;
          return '${err['error'] ?? 'Invalid OTP'}';
        } catch (_) {
          return 'Invalid OTP (${res.statusCode})';
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

  /// After order is placed (before payment), empty tray so checkout items do not linger in UI.
  Future<void> clearTrayPersistOnly() async {
    tray.clear();
    notifyListeners();
    final e = userEmail?.toLowerCase();
    if (e == null || userRole != 'customer') return;
    final p = await SharedPreferences.getInstance();
    await p.remove('customer_tray_v1_$e');
    unawaited(_pushCustomerTrayDraftToServer([]));
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
            'dip_qty': e.dipQty,
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
      final dipQty = math.max(0, jsonToInt(e['dip_qty'], 1));
      final qty = jsonToInt(e['qty']);
      MenuItemData? foundItem;
      for (final x in menu) {
        if (x.id == id) {
          foundItem = x;
          break;
        }
      }
      if (foundItem != null && qty > 0) {
        tray.add(CartItem(menu: foundItem, dip: dip, dipQty: dipQty, qty: qty));
      }
    }
  }

  Future<void> _pushCustomerTrayDraftToServer(List<Map<String, dynamic>> lines) async {
    final email = userEmail;
    if (email == null || userRole != 'customer' || isGuestSession) return;
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
    if (email == null || userRole != 'customer' || isGuestSession) return;
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

  Future<String?> cancelInquiryAsCustomer({required String inquiryId}) async {
    if (userEmail == null) return 'Not signed in';
    final id = inquiryId.trim();
    if (id.isEmpty) return 'Invalid inquiry';
    try {
      final res = await http
          .patch(
            _uri('/api/mobile/inquiries/$id/cancel-customer'),
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

  void requestAuthSignup() {
    signupFromGuestPrompt = true;
    openAuthInSignupMode = true;
    reopenAuthAsStaff = false;
    logout();
  }

  void returnGuestToCustomerLogin() {
    signupFromGuestPrompt = false;
    openAuthInSignupMode = false;
    reopenAuthAsStaff = false;
    logout();
  }

  void logout() {
    final persistedEmail = userEmail?.toLowerCase();
    reopenAuthAsStaff = isCashier || isManagerOrSupervisor;
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
    cashierWalkInCancelled.clear();
    _managerCateringByStage.clear();
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

  /// Local-only session for ordering without an account (see [isGuestSession]).
  Future<void> enterGuestCheckoutSession() async {
    final salt = DateTime.now().millisecondsSinceEpoch;
    final r = math.Random().nextInt(1 << 30);
    userEmail = 'guest_${salt}_$r@guest.curatering.internal'.toLowerCase();
    loginPassword = '';
    userRole = 'customer';
    cashierDisplayName = '';
    profile = ProfileData();
    loyaltyHistory.clear();
    orders.clear();
    inquiries.clear();
    tray.clear();
    checkoutNote = '';
    checkoutSelectedAddress = null;
    checkoutDeliveryTime = 'NOW';
    authSessionKey++;
    showLoginWelcomeDialog = false;
    _profileLoadedAt = DateTime.now();
    notifyListeners();
    try {
      await Future.wait([
        loadMenu(force: true),
        loadSetMenus(force: true),
      ]);
      await loadOrders(force: true);
      await loadInquiries(force: true);
      await bootstrapRealtimeSync();
    } catch (e, st) {
      debugPrint('enterGuestCheckoutSession failed: $e\n$st');
      rethrow;
    }
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
        if (_stampChanged(previous, next, 'notifications')) {
          final notifIds = delta?['notification_ids'];
          final allow = delta == null || (notifIds is List && notifIds.isNotEmpty);
          if (allow) jobs.add(loadNotifications(force: true));
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
        if (_stampChanged(previous, next, 'notifications')) {
          final notifIds = delta?['notification_ids'];
          final allow = delta == null || (notifIds is List && notifIds.isNotEmpty);
          if (allow) jobs.add(loadNotifications(force: true));
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
          if (allow && !isGuestSession) jobs.add(loadProfile(force: true));
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
            final allergenValues =
                map['allergens'] is List ? (map['allergens'] as List<dynamic>).map((d) => '$d').toList() : <String>[];
            return MenuItemData(
              id: '${map['id']}',
              name: '${map['name']}',
              description: '${map['description']}',
              price: jsonToDouble(map['price']),
              dips: dipValues,
              ingredients: ingValues,
              allergens: allergenValues,
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

  Future<void> loadAllergenCatalog({bool force = false}) async {
    if (_loadAllergensInFlight) return;
    if (!force &&
        _allergensLoadedAt != null &&
        DateTime.now().difference(_allergensLoadedAt!) < const Duration(seconds: 30) &&
        allergenCatalog.isNotEmpty) {
      return;
    }
    _loadAllergensInFlight = true;
    try {
      final res = await http.get(_uri('/api/mobile/allergens'));
      if (res.statusCode != 200) return;
      final body = jsonDecode(res.body);
      if (body is! List) return;
      allergenCatalog
        ..clear()
        ..addAll(
          body
              .whereType<Map<String, dynamic>>()
              .map((m) => '${m['name'] ?? ''}'.trim())
              .where((n) => n.isNotEmpty),
        );
      _allergensLoadedAt = DateTime.now();
      notifyListeners();
    } finally {
      _loadAllergensInFlight = false;
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
    if (userEmail == null || isGuestSession || _loadProfileInFlight) return;
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
      contactEmail: '${map['contact_email'] ?? ''}',
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
    if (userEmail == null || isGuestSession || _loadLoyaltyHistoryInFlight) return;
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
              orderNo: orderNoFromApiMap(m),
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
    if (userEmail == null || isGuestSession) return;
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
        contactEmail: updated.contactEmail,
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

  void updateGuestCheckoutContact({
    String? fullName,
    String? contactNumber,
    String? contactEmail,
    String? deliveryAddress,
    double? deliveryLat,
    double? deliveryLng,
    bool? deliveryMapConfirmed,
  }) {
    if (!isGuestSession) return;
    if (fullName != null) profile.fullName = fullName;
    if (contactNumber != null) profile.contactNumber = contactNumber;
    if (contactEmail != null) profile.contactEmail = contactEmail;
    if (deliveryAddress != null) profile.deliveryAddress = deliveryAddress;
    if (deliveryLat != null) profile.deliveryLat = deliveryLat;
    if (deliveryLng != null) profile.deliveryLng = deliveryLng;
    if (deliveryMapConfirmed != null) profile.deliveryMapConfirmed = deliveryMapConfirmed;
    notifyListeners();
  }

  void addToTray(MenuItemData menuItem, {String dip = '', int dipQty = 1}) {
    final dq = dip.trim().isEmpty ? 1 : math.max(0, dipQty);
    final existing = tray.where((e) => e.menu.id == menuItem.id && e.dip == dip && e.dipQty == dq).toList();
    if (existing.isEmpty) {
      tray.add(CartItem(menu: menuItem, dip: dip, dipQty: dq, qty: 1));
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

  void changeDipQty(CartItem item, int delta) {
    if (item.dip.trim().isEmpty) return;
    item.dipQty += delta;
    if (item.dipQty < 0) item.dipQty = 0;
    notifyListeners();
    _persistCustomerTraySnapshot().catchError((_) {});
  }

  /// Customer menu + cashier POS: optional add-on / quantity before adding a line to the tray.
  Future<void> promptAndAddRestaurantDish(BuildContext context, MenuItemData item) async {
    var selectedDip = '';
    var addonQty = 1;
    if (item.dips.isNotEmpty) {
      final dipChoices = ['None', ...item.dips];
      selectedDip = 'None';
      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) {
          return StatefulBuilder(
            builder: (ctx, setSt) {
              return AlertDialog(
                title: Text('Add ${item.name}', maxLines: 2),
                content: SingleChildScrollView(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      DropdownButtonFormField<String>(
                        value: selectedDip,
                        isExpanded: true,
                        decoration: const InputDecoration(labelText: 'Add-on'),
                        items: dipChoices.map((d) => DropdownMenuItem(value: d, child: Text(d))).toList(),
                        onChanged: (v) => setSt(() {
                          selectedDip = v ?? 'None';
                          addonQty = 1;
                        }),
                      ),
                      if (selectedDip != 'None') ...[
                        const SizedBox(height: 12),
                        Row(
                          children: [
                            const Text('Add-on qty'),
                            const Spacer(),
                            IconButton(
                              icon: const Icon(Icons.remove_circle_outline),
                              onPressed: addonQty > 0 ? () => setSt(() => addonQty--) : null,
                            ),
                            Padding(
                              padding: const EdgeInsets.symmetric(horizontal: 6),
                              child: Text('$addonQty', style: const TextStyle(fontWeight: FontWeight.w800)),
                            ),
                            IconButton(
                              icon: const Icon(Icons.add_circle_outline),
                              onPressed: () => setSt(() => addonQty++),
                            ),
                          ],
                        ),
                        Text(
                          'First add-on is included; +₱${kRestaurantAddonExtraPhp.toStringAsFixed(0)} for each extra (per main dish).',
                          style: TextStyle(fontSize: 11, color: Colors.grey.shade700),
                        ),
                      ],
                    ],
                  ),
                ),
                actions: [
                  TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
                  FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Add to tray')),
                ],
              );
            },
          );
        },
      );
      if (ok != true) return;
    }
    final dip = selectedDip == 'None' || selectedDip.isEmpty ? '' : selectedDip;
    final dq = dip.isEmpty ? 1 : addonQty;
    addToTray(item, dip: dip, dipQty: dq);
  }

  void clearTray() {
    tray.clear();
    notifyListeners();
    _persistCustomerTraySnapshot().catchError((_) {});
  }

  double get subtotal => tray.fold<double>(0, (sum, i) => sum + cartLineSubtotal(i));

  Future<SubmitOrderResult> submitOrder({bool clearCheckoutDraft = true}) async {
    if (userEmail == null || tray.isEmpty) {
      return SubmitOrderResult(error: 'Missing profile or empty tray');
    }
    if (isGuestSession) {
      final nameParts = profile.fullName.trim().split(RegExp(r'\s+'));
      if (nameParts.isEmpty || nameParts.first.isEmpty) {
        return SubmitOrderResult(error: 'Enter your first name.');
      }
      if (nameParts.length < 2 || nameParts.sublist(1).join(' ').trim().isEmpty) {
        return SubmitOrderResult(error: 'Enter your last name.');
      }
      if (profile.contactNumber.trim().isEmpty) {
        return SubmitOrderResult(error: 'Enter your contact number.');
      }
      if (profile.deliveryAddress.trim().isEmpty) {
        return SubmitOrderResult(error: 'Enter your delivery address.');
      }
      final em = profile.contactEmail.trim();
      if (em.isEmpty || !em.contains('@') || !em.contains('.')) {
        return SubmitOrderResult(error: 'Enter a valid contact email.');
      }
      if (checkoutDeliveryTime.trim().isEmpty) {
        return SubmitOrderResult(error: 'Choose a delivery time.');
      }
      double? km = profile.deliveryLat != null && profile.deliveryLng != null
          ? haversineKm(
              lat1: kRestaurantLat,
              lng1: kRestaurantLng,
              lat2: profile.deliveryLat!,
              lng2: profile.deliveryLng!,
            )
          : await geocodeAddressDistanceKmFromRestaurant(profile.deliveryAddress.trim());
      if (km == null || km > kDeliveryMaxDistanceKm + 0.05) {
        return SubmitOrderResult(
          error: 'Delivery address must be within ${kDeliveryMaxDistanceKm.toStringAsFixed(0)} km of the restaurant.',
        );
      }
    }
    try {
      final res = await http
          .post(
            _uri('/api/mobile/orders'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({
              'user_email': userEmail,
              if (isGuestSession) 'contact_email': profile.contactEmail.trim(),
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
                      'dip_qty': e.dipQty,
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
              dipQty: e.dipQty,
              qty: e.qty,
              price: e.menu.price,
            ),
          )
          .toList();
      final order = OrderData(
        id: jsonToInt(map['id']),
        orderNo: orderNoFromApiMap(map),
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

  Future<String?> uploadPaymentProof(int orderId, XFile file, {String? paymentProofBase64}) async {
    try {
      var encoded = paymentProofBase64 ?? base64Encode(await file.readAsBytes());
      final comma = encoded.indexOf(',');
      if (encoded.toLowerCase().startsWith('data:') && comma >= 0) {
        encoded = encoded.substring(comma + 1).trim();
      }
      encoded = encoded.replaceAll(RegExp(r'\s+'), '');
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
    if (isGuestSession) {
      profile = ProfileData();
    }
    notifyListeners();
    await clearPersistedCustomerDraft();
  }

  Future<void> loadOrders({bool force = false}) async {
    if (userEmail == null || _loadOrdersInFlight) return;
    if (!force && _ordersLoadedAt != null && DateTime.now().difference(_ordersLoadedAt!) < const Duration(seconds: 2)) {
      return;
    }
    _loadOrdersInFlight = true;
    try {
      final query = <String, String>{'user_email': userEmail!};
      if (isGuestSession) {
        final guestContact = profile.contactEmail.trim().toLowerCase();
        if (guestContact.isNotEmpty) query['contact_email'] = guestContact;
      }
      final res = await http.get(_uri('/api/mobile/orders', query));
      if (res.statusCode != 200) {
        debugPrint('loadOrders failed: ${res.statusCode} ${res.body}');
        return;
      }
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
      _managerCateringByStage[stage] =
          body.whereType<Map<String, dynamic>>().map(CateringEventRecord.fromApiMap).toList();
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
    Map<String, dynamic>? seatingPlan,
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
              if (seatingPlan != null && seatingPlan.isNotEmpty) 'seating_plan': seatingPlan,
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
      if (res.statusCode != 200) {
        try {
          final body = jsonDecode(res.body);
          if (body is Map && body['error'] != null) return '${body['error']}';
        } catch (_) {}
        return 'Could not update stage (${res.statusCode})';
      }
      return null;
    } catch (e) {
      return describeApiNetworkError(e, normalizeApiBase(apiBase));
    }
  }

  Future<String?> managerSendOrderSummaryEmail({
    required String orderKind,
    required String id,
    required String customerEmail,
    required String pdfBase64,
  }) async {
    if (userEmail == null || !isManagerOrSupervisor) return 'Not signed in';
    try {
      final res = await http
          .post(
            _uri('/api/mobile/pos/catering/send-order-summary-email'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({
              'cashier_email': userEmail,
              'cashier_password': loginPassword,
              'order_kind': orderKind,
              'id': id,
              'customer_email': customerEmail.trim().toLowerCase(),
              'pdf_base64': pdfBase64,
            }),
          )
          .timeout(_apiTimeout);
      if (res.statusCode != 200) {
        try {
          final err = jsonDecode(res.body) as Map<String, dynamic>;
          return '${err['error'] ?? 'Could not send email'}';
        } catch (_) {
          return 'Could not send email (${res.statusCode})';
        }
      }
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
    if (userEmail == null || _loadNotificationsInFlight) return;
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
      if (isCashier || isManagerOrSupervisor) {
        _notificationsLoadedAt = DateTime.now();
        notifyListeners();
        return;
      }
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

  /// Persists completed-order feedback (restaurant or catering inquiry). Returns null on success.
  Future<String?> submitOrderFeedback({
    required String kind,
    required String reference,
    required int rating,
    required String comment,
  }) async {
    if (userEmail == null) return 'Not signed in';
    if (isGuestSession) return 'Sign in to submit feedback.';
    try {
      final res = await http
          .post(
            _uri('/api/mobile/order-feedback'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({
              'user_email': userEmail,
              'kind': kind,
              'reference': reference,
              'rating': rating,
              'comment': comment,
            }),
          )
          .timeout(_apiTimeout);
      if (res.statusCode != 201) {
        try {
          final err = jsonDecode(res.body) as Map<String, dynamic>;
          return '${err['error'] ?? 'Could not submit feedback'}';
        } catch (_) {
          return 'Could not submit feedback (${res.statusCode})';
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
        final idStr = '${map['id'] ?? ''}'.trim();
        if (idStr.isEmpty) continue;
        final dishes = inquirySelectedDishLabels(map['selected_dishes']);
        parsed.add(
          InquiryRecord(
            id: idStr,
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
            themeDesign: () {
              final td = map['theme_design'];
              if (td is Map) return Map<String, dynamic>.from(td);
              return const <String, dynamic>{};
            }(),
            seatingPlan: () {
              final sp = map['seating_plan'];
              if (sp is Map) return Map<String, dynamic>.from(sp);
              return const <String, dynamic>{};
            }(),
            orderKind: '${map['order_kind'] ?? 'catering'}',
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
    if (userEmail == null || !isCashier) return;
    if (!force &&
        _cashierOnlineOrdersLoadedAt != null &&
        DateTime.now().difference(_cashierOnlineOrdersLoadedAt!) < const Duration(seconds: 2)) {
      return;
    }
    if (_loadCashierOnlineOrdersInFlight) {
      if (!force) return;
      for (var i = 0; i < 60 && _loadCashierOnlineOrdersInFlight; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 40));
      }
      if (_loadCashierOnlineOrdersInFlight) return;
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
      if (res.statusCode != 200) {
        try {
          final err = jsonDecode(res.body) as Map<String, dynamic>;
          cashierDataLoadError = '${err['error'] ?? 'Could not load online orders'}';
        } catch (_) {
          cashierDataLoadError = 'Could not load online orders (${res.statusCode})';
        }
        notifyListeners();
        return;
      }
      cashierDataLoadError = null;
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
        DateTime.now().difference(_cashierWalkInQueuesLoadedAt!) < const Duration(seconds: 2)) {
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
        if (res.statusCode != 200) {
          try {
            final err = jsonDecode(res.body) as Map<String, dynamic>;
            throw StateError('${err['error'] ?? 'Could not load walk-in orders'}');
          } catch (e) {
            if (e is StateError) rethrow;
            throw StateError('Could not load walk-in orders (${res.statusCode})');
          }
        }
        final List<dynamic> body = jsonDecode(res.body) as List<dynamic>;
        return body.map((e) {
          final map = e as Map<String, dynamic>;
          return orderDataFromApiMap(map, orderLinesFromApiMap(map));
        }).toList();
      }

      final prepF = fetch('preparing');
      final claimF = fetch('claimed');
      final cancelF = fetch('cancelled');
      final results = await Future.wait([prepF, claimF, cancelF]);
      cashierWalkInPreparing
        ..clear()
        ..addAll(results[0]);
      cashierWalkInComplete
        ..clear()
        ..addAll(results[1]);
      cashierWalkInCancelled
        ..clear()
        ..addAll(results[2]);
      _cashierWalkInQueuesLoadedAt = DateTime.now();
      cashierDataLoadError = null;
      notifyListeners();
    } catch (e) {
      cashierDataLoadError = e is StateError ? e.message : 'Could not load walk-in orders';
      notifyListeners();
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

  Future<String?> cancelWalkInOrder(int orderId) async {
    if (userEmail == null || !isCashier) return 'Not signed in';
    try {
      final res = await http
          .patch(
            _uri('/api/mobile/pos/walkin-orders/$orderId/cancel'),
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
          return '${err['error'] ?? 'Could not cancel order'}';
        } catch (_) {
          return 'Could not cancel (${res.statusCode})';
        }
      }
      await loadCashierWalkInQueues(force: true);
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
                      'dip_qty': e.dipQty,
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
      await loadCashierWalkInQueues(force: true);
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
  final forgotEmailController = TextEditingController();
  final forgotOtpController = TextEditingController();
  final forgotNewPasswordController = TextEditingController();
  final forgotConfirmPasswordController = TextEditingController();
  bool signupMode = false;
  bool otpSent = false;
  /// Non-null while a blocking auth action runs (login, signup OTP, etc.).
  String? busyMessage;

  @override
  void initState() {
    super.initState();
    if (!widget.cashierMode && widget.state.openAuthInSignupMode) {
      signupMode = true;
      widget.state.openAuthInSignupMode = false;
    }
  }

  @override
  void dispose() {
    emailController.dispose();
    passwordController.dispose();
    confirmPasswordController.dispose();
    otpController.dispose();
    forgotEmailController.dispose();
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
            const SizedBox(height: 36),
            if (widget.cashierMode)
              Image.asset(AppBrandAssets.logoDashboard, height: 76, fit: BoxFit.contain)
            else
              SizedBox(
                height: 140,
                width: double.infinity,
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
                child: Column(
                  children: [
                    Expanded(
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
                          onPressed: busyMessage != null
                              ? null
                              : () async {
                                  setState(() => busyMessage = 'Sending code...');
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
                                    if (mounted) setState(() => busyMessage = null);
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
                            onPressed: busyMessage != null
                                ? null
                                : () async {
                                    if (passwordController.text != confirmPasswordController.text) {
                                      await _toast('Passwords do not match');
                                      return;
                                    }
                                    setState(() => busyMessage = 'Creating account...');
                                    try {
                                      final fromGuest = widget.state.signupFromGuestPrompt;
                                      final err = await widget.state.completeSignup(
                                        email: emailController.text,
                                        otp: otpController.text,
                                        password: passwordController.text,
                                        loginAfter: !fromGuest,
                                      );
                                      if (!mounted) return;
                                      if (err != null) {
                                        await _toast(err);
                                        return;
                                      }
                                      if (fromGuest) {
                                        widget.state.signupFromGuestPrompt = false;
                                        setState(() {
                                          signupMode = false;
                                          otpSent = false;
                                          otpController.clear();
                                          confirmPasswordController.clear();
                                          passwordController.clear();
                                        });
                                        await _toast('Account created! Please log in with your new email and password.');
                                      }
                                    } finally {
                                      if (mounted) setState(() => busyMessage = null);
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
                          onPressed: busyMessage != null
                              ? null
                              : () async {
                                  setState(() => busyMessage = 'Logging in...');
                                  try {
                                    final err = await widget.state.login(
                                      emailController.text,
                                      passwordController.text,
                                    );
                                    if (!mounted) return;
                                    if (err != null) await _toast(err);
                                  } finally {
                                    if (mounted) setState(() => busyMessage = null);
                                  }
                                },
                          style: FilledButton.styleFrom(
                            backgroundColor: Colors.white,
                            foregroundColor: AppColors.ink,
                            side: const BorderSide(color: AppColors.ink),
                          ),
                          child: const Text('LOG IN'),
                        ),
                        if (!widget.cashierMode) ...[
                          const SizedBox(height: 14),
                          Text(
                            'OR',
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w700,
                              color: Colors.white.withValues(alpha: 0.85),
                            ),
                          ),
                          const SizedBox(height: 10),
                          OutlinedButton(
                            onPressed: busyMessage != null
                                ? null
                                : () async {
                                    setState(() => busyMessage = 'Opening…');
                                    try {
                                      await widget.state.enterGuestCheckoutSession();
                                      if (!mounted) return;
                                      // Ensure the user lands on the dashboard even if the root widget rebuild lags.
                                      WidgetsBinding.instance.addPostFrameCallback((_) {
                                        if (!mounted) return;
                                        Navigator.of(context).pushReplacement(
                                          MaterialPageRoute<void>(builder: (_) => CustomerDashboardScreen(state: widget.state)),
                                        );
                                      });
                                    } catch (e) {
                                      if (mounted) {
                                        appSnack(
                                          context,
                                          describeApiNetworkError(e, normalizeApiBase(widget.state.apiBase)),
                                        );
                                      }
                                    } finally {
                                      if (mounted) setState(() => busyMessage = null);
                                    }
                                  },
                            style: OutlinedButton.styleFrom(
                              foregroundColor: AppColors.ink,
                              side: const BorderSide(color: AppColors.ink),
                            ),
                            child: const Text('CONTINUE AS GUEST'),
                          ),
                        ],
                        const SizedBox(height: 8),
                        TextButton(
                          onPressed: busyMessage != null
                              ? null
                              : () async {
                                  forgotEmailController.clear();
                                  forgotOtpController.clear();
                                  forgotNewPasswordController.clear();
                                  forgotConfirmPasswordController.clear();
                                  await showDialog<void>(
                                    context: context,
                                    builder: (dCtx) {
                                      final step = <int>[0];
                                      String? notReg;
                                      InputDecoration deco(String label) => InputDecoration(
                                            labelText: label,
                                            filled: true,
                                            fillColor: Colors.white,
                                            border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
                                          );
                                      bool emailOk(String v) => v.contains('@') && v.contains('.');
                                      String? emailForRequest() {
                                        final v = forgotEmailController.text.trim().toLowerCase();
                                        return v.isEmpty ? null : v;
                                      }
                                      return StatefulBuilder(
                                        builder: (ctx, setDialogState) {
                                          return Theme(
                                            data: ThemeData(
                                              colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF3949AB)),
                                              useMaterial3: true,
                                            ),
                                            child: AlertDialog(
                                              title: const Text('Forgot password'),
                                              content: SingleChildScrollView(
                                                child: Column(
                                                  mainAxisSize: MainAxisSize.min,
                                                  crossAxisAlignment: CrossAxisAlignment.stretch,
                                                  children: [
                                                    if (step[0] == 0) ...[
                                                      TextField(
                                                        controller: forgotEmailController,
                                                        keyboardType: TextInputType.emailAddress,
                                                        decoration: deco('Email'),
                                                      ),
                                                      if (notReg != null)
                                                        Padding(
                                                          padding: const EdgeInsets.only(top: 8),
                                                          child: Text(
                                                            notReg!,
                                                            style: const TextStyle(color: Colors.red, fontSize: 13),
                                                          ),
                                                        ),
                                                      const SizedBox(height: 12),
                                                      FilledButton(
                                                        onPressed: busyMessage != null
                                                            ? null
                                                            : () async {
                                                                notReg = null;
                                                                final id = emailForRequest();
                                                                if (id == null) {
                                                                  await _toast('Enter your email');
                                                                  setDialogState(() {});
                                                                  return;
                                                                }
                                                                if (!emailOk(forgotEmailController.text.trim())) {
                                                                  await _toast('Enter a valid email');
                                                                  return;
                                                                }
                                                                setState(() => busyMessage = 'Sending OTP...');
                                                                try {
                                                                  final r = await widget.state.requestPasswordReset(
                                                                    identity: id,
                                                                    channel: 'email',
                                                                    role: widget.cashierMode ? 'cashier' : 'customer',
                                                                  );
                                                                  if (!mounted) return;
                                                                  if (r.notRegistered) {
                                                                    setDialogState(() {
                                                                      notReg = 'This email is not registered.';
                                                                    });
                                                                    return;
                                                                  }
                                                                  if (!r.ok) {
                                                                    await _toast(r.error ?? 'Could not send OTP');
                                                                    return;
                                                                  }
                                                                  setDialogState(() {
                                                                    step[0] = 1;
                                                                    notReg = null;
                                                                  });
                                                                  await _toast('OTP sent. Check your email.');
                                                                } finally {
                                                                  if (mounted) setState(() => busyMessage = null);
                                                                }
                                                              },
                                                        child: const Text('REQUEST RESET OTP'),
                                                      ),
                                                    ],
                                                    if (step[0] == 1) ...[
                                                      Padding(
                                                        padding: const EdgeInsets.only(bottom: 8),
                                                        child: Text(
                                                          forgotEmailController.text.trim().isNotEmpty
                                                              ? "Please enter the code we've sent to your email: ${forgotEmailController.text.trim()}"
                                                              : "Please enter the code we've sent to your email.",
                                                          style: const TextStyle(fontSize: 13, height: 1.35),
                                                        ),
                                                      ),
                                                      TextField(
                                                        controller: forgotOtpController,
                                                        keyboardType: TextInputType.number,
                                                        decoration: deco('OTP code'),
                                                      ),
                                                      const SizedBox(height: 8),
                                                      OutlinedButton(
                                                        onPressed: busyMessage != null
                                                            ? null
                                                            : () async {
                                                                final id = emailForRequest();
                                                                if (id == null) return;
                                                                setState(() => busyMessage = 'Sending OTP...');
                                                                try {
                                                                  final r = await widget.state.requestPasswordReset(
                                                                    identity: id,
                                                                    channel: 'email',
                                                                    role: widget.cashierMode ? 'cashier' : 'customer',
                                                                  );
                                                                  if (!mounted) return;
                                                                  if (r.notRegistered) {
                                                                    setDialogState(() {
                                                                      notReg = 'This email is not registered.';
                                                                    });
                                                                    return;
                                                                  }
                                                                  if (!r.ok) {
                                                                    await _toast(r.error ?? 'Could not send OTP');
                                                                    return;
                                                                  }
                                                                  forgotOtpController.clear();
                                                                  await _toast('OTP resent. Check your email.');
                                                                } finally {
                                                                  if (mounted) setState(() => busyMessage = null);
                                                                }
                                                              },
                                                        child: const Text('RESEND OTP'),
                                                      ),
                                                      const SizedBox(height: 12),
                                                      FilledButton(
                                                        onPressed: busyMessage != null
                                                            ? null
                                                            : () async {
                                                                final id = emailForRequest();
                                                                if (id == null) return;
                                                                final otp = forgotOtpController.text.replaceAll(RegExp(r'\D'), '').trim();
                                                                if (otp.isEmpty) {
                                                                  await _toast('Enter your OTP code.');
                                                                  return;
                                                                }
                                                                setState(() => busyMessage = 'Verifying code...');
                                                                try {
                                                                  final err = await widget.state.verifyPasswordResetOtp(
                                                                    identity: id,
                                                                    otp: otp,
                                                                    role: widget.cashierMode ? 'cashier' : 'customer',
                                                                  );
                                                                  if (!mounted) return;
                                                                  if (err != null) {
                                                                    await _toast(err);
                                                                    return;
                                                                  }
                                                                  setDialogState(() => step[0] = 2);
                                                                } finally {
                                                                  if (mounted) setState(() => busyMessage = null);
                                                                }
                                                              },
                                                        child: const Text('CONTINUE'),
                                                      ),
                                                    ],
                                                    if (step[0] == 2) ...[
                                                      TextField(
                                                        controller: forgotNewPasswordController,
                                                        obscureText: true,
                                                        decoration: deco('New password (min 8)'),
                                                      ),
                                                      const SizedBox(height: 10),
                                                      TextField(
                                                        controller: forgotConfirmPasswordController,
                                                        obscureText: true,
                                                        decoration: deco('Confirm new password'),
                                                      ),
                                                      const SizedBox(height: 12),
                                                      FilledButton(
                                                        onPressed: () async {
                                                          if (forgotNewPasswordController.text !=
                                                              forgotConfirmPasswordController.text) {
                                                            await _toast('Passwords do not match');
                                                            return;
                                                          }
                                                          final id = emailForRequest();
                                                          if (id == null) return;
                                                          final otp = forgotOtpController.text.replaceAll(RegExp(r'\D'), '').trim();
                                                          if (otp.isEmpty) {
                                                            await _toast('Enter your OTP code.');
                                                            return;
                                                          }
                                                          final err = await widget.state.resetPasswordWithOtp(
                                                            identity: id,
                                                            otp: otp,
                                                            password: forgotNewPasswordController.text,
                                                            role: widget.cashierMode ? 'cashier' : 'customer',
                                                          );
                                                          if (err != null) {
                                                            await _toast(err);
                                                            return;
                                                          }
                                                          if (dCtx.mounted) Navigator.pop(dCtx);
                                                          await _toast('Password updated. Log in with your new password.');
                                                        },
                                                        child: const Text('RESET PASSWORD'),
                                                      ),
                                                    ],
                                                  ],
                                                ),
                                              ),
                                              actions: [
                                                TextButton(onPressed: () => Navigator.pop(dCtx), child: const Text('Close')),
                                              ],
                                            ),
                                          );
                                        },
                                      );
                                    },
                                  );
                                },
                          child: const Text('FORGOT PASSWORD?'),
                        ),
                      ],
                      if (!widget.cashierMode)
                        TextButton(
                          onPressed: busyMessage != null
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
                    if (widget.cashierMode) ...[
                      const SizedBox(height: 12),
                      Image.asset(AppBrandAssets.logoCuratering, height: 44, fit: BoxFit.contain),
                      const SizedBox(height: 12),
                    ],
                  ],
                ),
              ),
            ),
              ],
            ),
            if (busyMessage != null)
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
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const SizedBox(
                            width: 20,
                            height: 20,
                            child: CircularProgressIndicator(strokeWidth: 2.4),
                          ),
                          const SizedBox(width: 12),
                          Text(
                            busyMessage!,
                            style: TextStyle(fontSize: 15, color: Colors.grey.shade900),
                          ),
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
    final greet = state.isGuestSession
        ? 'Guest'
        : (state.profile.fullName.trim().isNotEmpty ? state.profile.fullName.trim() : (state.userEmail ?? ''));
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
          if (!state.isGuestSession) ...[
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
          ],
          ListTile(title: const Text('Your Tray'), onTap: () => open(context, TrayScreen(state: state))),
          ListTile(title: const Text('Order Now'), onTap: () => open(context, RestaurantMenuScreen(state: state))),
          ListTile(title: const Text('Inquire Catering'), onTap: () => open(context, InquiryScreen(state: state))),
          ListTile(title: const Text('Settings'), onTap: () => open(context, SettingsScreen(state: state))),
          if (state.isGuestSession) ...[
            const Divider(height: 28),
            ListTile(
              leading: const Icon(Icons.login),
              title: const Text('Return to log in'),
              onTap: () {
                Navigator.pop(context);
                state.returnGuestToCustomerLogin();
                Navigator.of(context, rootNavigator: true).pushAndRemoveUntil(
                  MaterialPageRoute<void>(
                    builder: (_) => AuthScreen(state: state, cashierMode: false),
                  ),
                  (_) => false,
                );
              },
            ),
          ],
        ],
      ),
    );
  }
}

/// Payment methods recorded in catering [postAnalysis] for manager "For processing" flows.
const List<String> kManagerPaymentMethods = ['Cash', 'E-Wallet', 'Bank Transfer', 'Cheque'];

const Color kManagerCompletedIconColor = Color(0xFF2ECC71);
const Color kManagerSettingsIconColor = Color(0xFF424242);

Widget _managerTabCountBadge(int count) {
  if (count <= 0) return const SizedBox.shrink();
  final label = count > 99 ? '99+' : '$count';
  return Container(
    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
    constraints: const BoxConstraints(minWidth: 20, minHeight: 20),
    decoration: const BoxDecoration(color: Colors.red, shape: BoxShape.circle),
    alignment: Alignment.center,
    child: Text(
      label,
      style: const TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.w800, height: 1.1),
    ),
  );
}

Widget _buildManagerHamburgerLeading(BuildContext context, AppState state) {
  if (Navigator.canPop(context)) {
    return IconButton(
      icon: const Icon(Icons.arrow_back, color: Color(0xFFFFC024)),
      onPressed: () => Navigator.maybePop(context),
    );
  }
  return Builder(
    builder: (ctx) => IconButton(
      icon: const Icon(Icons.menu, color: Color(0xFFFFC024)),
      onPressed: () => Scaffold.of(ctx).openDrawer(),
    ),
  );
}

Widget _buildCashierHamburgerLeading(BuildContext context, AppState state) {
  final dot = state.hasCashierAttentionBadge || state.unreadNotificationsCount > 0;
  return Builder(
    builder: (ctx) => Stack(
      clipBehavior: Clip.none,
      children: [
        IconButton(
          icon: const Icon(Icons.menu, color: AppColors.brand),
          onPressed: () => Scaffold.of(ctx).openDrawer(),
        ),
        if (dot)
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
  );
}

/// Cashier drawer: matches POS shell; use [closeExtraRouteForManageOrders] on pushed routes (e.g. order history).
class CashierRoleDrawer extends StatelessWidget {
  const CashierRoleDrawer({
    super.key,
    required this.state,
    this.tabController,
    this.closeExtraRouteForManageOrders = false,
  });
  final AppState state;
  final TabController? tabController;
  final bool closeExtraRouteForManageOrders;

  @override
  Widget build(BuildContext context) {
    return Drawer(
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
                  'Hi, ${state.cashierDisplayName.isNotEmpty ? state.cashierDisplayName : 'Cashier'}',
                  style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 18),
                ),
                Text(state.userEmail ?? '', style: const TextStyle(fontSize: 13)),
              ],
            ),
          ),
          ListTile(
            leading: const Icon(Icons.dashboard_customize_outlined),
            title: const Text('Manage Orders'),
            onTap: () {
              Navigator.pop(context);
              if (closeExtraRouteForManageOrders) {
                Navigator.of(context).pop();
              } else {
                tabController?.animateTo(0);
              }
            },
          ),
          ListTile(
            leading: const Icon(Icons.history),
            title: const Text('Order history'),
            onTap: () {
              Navigator.pop(context);
              if (!closeExtraRouteForManageOrders) {
                Navigator.of(context).push(
                  MaterialPageRoute<void>(builder: (_) => PosOrderHistoryScreen(state: state)),
                );
              }
            },
          ),
          ListTile(
            leading: const Icon(Icons.help_outline),
            title: const Text('Help request'),
            onTap: () {
              Navigator.pop(context);
              showCashierHelpDialog(context, state);
            },
          ),
          ListTile(
            leading: const Icon(Icons.settings),
            title: const Text('Settings'),
            onTap: () {
              Navigator.pop(context);
              Navigator.of(context).push(
                MaterialPageRoute<void>(builder: (_) => SettingsScreen(state: state)),
              );
            },
          ),
        ],
      ),
    );
  }
}

class ManagerRoleDrawer extends StatelessWidget {
  const ManagerRoleDrawer({
    super.key,
    required this.state,
    required this.onDashboard,
    required this.onManageEvents,
  });
  final AppState state;
  final VoidCallback onDashboard;
  final VoidCallback onManageEvents;

  @override
  Widget build(BuildContext context) {
    final who = state.cashierDisplayName.trim().isNotEmpty
        ? state.cashierDisplayName.trim()
        : (state.userEmail ?? '');
    return Drawer(
      child: ListView(
        children: [
          DrawerHeader(
            decoration: const BoxDecoration(color: Color(0xFF242424)),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                Image.asset(AppBrandAssets.logo, height: 52, fit: BoxFit.contain),
                const SizedBox(height: 10),
                if (who.isNotEmpty)
                  Text(
                    'Hi, $who!',
                    style: const TextStyle(
                      fontWeight: FontWeight.w800,
                      fontSize: 18,
                      color: Color(0xFFFFC024),
                    ),
                  ),
              ],
            ),
          ),
          ListTile(
            leading: const Icon(Icons.dashboard_outlined),
            title: const Text('Dashboard'),
            onTap: () {
              Navigator.pop(context);
              onDashboard();
            },
          ),
          ListTile(
            leading: const Icon(Icons.dashboard_customize_outlined),
            title: const Text('Manage Events'),
            onTap: () {
              Navigator.pop(context);
              onManageEvents();
            },
          ),
          ListTile(
            leading: const Icon(Icons.settings),
            title: const Text('Settings'),
            onTap: () {
              Navigator.pop(context);
              Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => SettingsScreen(state: state)));
            },
          ),
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
    final isGuest = state.isGuestSession;
    final who = isGuest
        ? 'Guest'
        : (state.profile.fullName.trim().isNotEmpty
            ? state.profile.fullName.trim()
            : (state.userEmail ?? '').trim());
    final items = <({String title, IconData icon, Widget? screen, VoidCallback? onTap})>[
      (title: 'Order Now', icon: Icons.restaurant_menu_outlined, screen: RestaurantMenuScreen(state: state), onTap: null),
      (title: 'Your Tray', icon: Icons.shopping_cart_outlined, screen: TrayScreen(state: state), onTap: null),
      if (!isGuest) (title: 'My Orders', icon: Icons.receipt_long_outlined, screen: MyOrdersScreen(state: state), onTap: null),
      (title: 'Inquire Catering', icon: Icons.event_available_outlined, screen: InquiryScreen(state: state), onTap: null),
      if (!isGuest)
        (title: 'My Catering Inquiries', icon: Icons.question_answer_outlined, screen: MyInquiriesScreen(state: state), onTap: null),
      if (!isGuest) (title: 'My Profile', icon: Icons.person_outline, screen: MyProfileScreen(state: state), onTap: null),
    ];
    final gridItems = items;
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
            Center(child: Image.asset(AppBrandAssets.logoDashboard, height: 76, fit: BoxFit.contain)),
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
          if (isGuest)
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    'Create an account to earn loyalty rewards on restaurant orders and completed catering events.',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 14,
                      height: 1.4,
                      fontWeight: FontWeight.w600,
                      color: Colors.grey.shade800,
                    ),
                  ),
                  const SizedBox(height: 14),
                  FilledButton(
                    onPressed: state.requestAuthSignup,
                    child: const Text('SIGN UP'),
                  ),
                ],
              ),
            ),
          Expanded(
            child: RefreshIndicator(
              onRefresh: () async {
                final wait = <Future<void>>[
                  state.loadMenu(force: true),
                  state.loadSetMenus(force: true),
                  state.loadOrders(force: true),
                  state.loadInquiries(force: true),
                ];
                if (!state.isGuestSession) wait.add(state.loadProfile(force: true));
                await Future.wait(wait);
                await state.loadNotifications(force: true);
              },
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final w = constraints.maxWidth;
                  final crossAxisCount = w >= 800 ? 3 : 2;
                  final childAspectRatio = w >= 800 ? 1.15 : 1.35;
                  return GridView.builder(
                    physics: const AlwaysScrollableScrollPhysics(),
                    padding: const EdgeInsets.all(12),
                    gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                      crossAxisCount: crossAxisCount,
                      crossAxisSpacing: 10,
                      mainAxisSpacing: 10,
                      childAspectRatio: childAspectRatio,
                    ),
                    itemCount: gridItems.length,
                    itemBuilder: (context, index) {
                      final item = gridItems[index];
                      return Card(
                        color: Colors.white,
                        elevation: 2,
                        shadowColor: Colors.black26,
                        child: InkWell(
                          borderRadius: BorderRadius.circular(12),
                          onTap: () {
                            if (item.onTap != null) {
                              item.onTap!();
                              return;
                            }
                            final screen = item.screen;
                            if (screen == null) return;
                            Navigator.of(context).pushReplacement(
                              MaterialPageRoute<void>(builder: (_) => screen),
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

class ManagerDashboardScreen extends StatefulWidget {
  const ManagerDashboardScreen({super.key, required this.state});
  final AppState state;

  @override
  State<ManagerDashboardScreen> createState() => _ManagerDashboardScreenState();
}

class _ManagerDashboardScreenState extends State<ManagerDashboardScreen> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      widget.state.preloadManagerDashboardCounts();
    });
  }

  Color _cardIconColor(int tabIdx) {
    if (tabIdx == 5) return kManagerCompletedIconColor;
    if (tabIdx == 6) return const Color(0xFFE92E0D);
    return AppColors.brand;
  }

  @override
  Widget build(BuildContext context) {
    final state = widget.state;
    final who = state.cashierDisplayName.trim().isNotEmpty
        ? state.cashierDisplayName.trim()
        : (state.userEmail ?? '').trim();
    final cards = <({String title, IconData icon, int tabIdx})>[
      (title: 'New Event', icon: Icons.add_box_outlined, tabIdx: 0),
      (title: 'Online Inquiries', icon: Icons.inbox_outlined, tabIdx: 1),
      (title: 'For Down Payment', icon: Icons.pending_actions_outlined, tabIdx: 2),
      (title: 'On Going', icon: Icons.event_note_outlined, tabIdx: 3),
      (title: 'For Full Payment', icon: Icons.payments_outlined, tabIdx: 4),
      (title: 'Completed', icon: Icons.task_alt_outlined, tabIdx: 5),
      (title: 'Cancelled', icon: Icons.cancel_outlined, tabIdx: 6),
    ];
    return AnimatedBuilder(
      animation: state,
      builder: (context, _) {
        return Scaffold(
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      appBar: AppBar(
        backgroundColor: const Color(0xFF242424),
        foregroundColor: const Color(0xFFFFC024),
        leading: _buildManagerHamburgerLeading(context, state),
        title: const Text('DASHBOARD', style: kManagerAppBarTitleStyle),
        centerTitle: true,
      ),
      drawer: ManagerRoleDrawer(
        state: state,
        onDashboard: () {
          Navigator.of(context).popUntil((route) => route.isFirst);
        },
        onManageEvents: () {
          Navigator.of(context).push(
            MaterialPageRoute<void>(builder: (_) => ManagerCateringShellScreen(state: state)),
          );
        },
      ),
      body: Column(
        children: [
          Container(
            width: double.infinity,
            decoration: const BoxDecoration(color: Color(0xFF242424)),
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Image.asset(AppBrandAssets.logoDashboard, height: 76, fit: BoxFit.contain),
                    const SizedBox(width: 12),
                    Image.asset(AppBrandAssets.logoCuratering, height: 48, fit: BoxFit.contain),
                  ],
                ),
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
            child: LayoutBuilder(
              builder: (context, constraints) {
                final w = constraints.maxWidth;
                // Tablet: make tiles smaller so 2 columns don't feel oversized.
                final crossAxisCount = w >= 800 ? 3 : 2;
                final childAspectRatio = w >= 800 ? 1.15 : 1.35;
                return GridView.builder(
                  padding: const EdgeInsets.all(12),
                  gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: crossAxisCount,
                    crossAxisSpacing: 10,
                    mainAxisSpacing: 10,
                    childAspectRatio: childAspectRatio,
                  ),
                  itemCount: cards.length + 1,
                  itemBuilder: (context, index) {
                    if (index == cards.length) {
                      return Card(
                        color: Colors.white,
                        elevation: 2,
                        shadowColor: Colors.black26,
                        child: InkWell(
                          borderRadius: BorderRadius.circular(12),
                          onTap: () => Navigator.of(context).push(
                            MaterialPageRoute<void>(builder: (_) => SettingsScreen(state: state)),
                          ),
                          child: const Padding(
                            padding: EdgeInsets.all(14),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Icon(Icons.settings_outlined, color: kManagerSettingsIconColor, size: 30),
                                Spacer(),
                                Text('Settings', style: TextStyle(fontWeight: FontWeight.w800)),
                              ],
                            ),
                          ),
                        ),
                      );
                    }
                    final item = cards[index];
                    final badgeCount = state.managerCateringCountForTab(item.tabIdx);
                    final showBadge = item.tabIdx <= 4 && badgeCount > 0;
                    return Card(
                      color: Colors.white,
                      elevation: 2,
                      shadowColor: Colors.black26,
                      child: InkWell(
                        borderRadius: BorderRadius.circular(12),
                        onTap: () {
                          Navigator.of(context).pushReplacement(
                            MaterialPageRoute<void>(
                              builder: (_) => ManagerCateringShellScreen(state: state, initialTabIndex: item.tabIdx),
                            ),
                          );
                        },
                        child: Padding(
                          padding: const EdgeInsets.all(14),
                          child: Stack(
                            clipBehavior: Clip.none,
                            children: [
                              Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Icon(item.icon, color: _cardIconColor(item.tabIdx), size: 30),
                                  const Spacer(),
                                  Text(item.title, style: const TextStyle(fontWeight: FontWeight.w800)),
                                ],
                              ),
                              if (showBadge)
                                Positioned(
                                  top: -4,
                                  right: -4,
                                  child: _managerTabCountBadge(badgeCount),
                                ),
                            ],
                          ),
                        ),
                      ),
                    );
                  },
                );
              },
            ),
          ),
        ],
      ),
    );
      },
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
    await widget.state.promptAndAddRestaurantDish(context, item);
    if (context.mounted) appSnack(context, 'Added ${item.name} to tray');
  }

  Widget _dishCard(BuildContext context, MenuItemData item) {
    return Material(
      color: Colors.white,
      borderRadius: BorderRadius.circular(14),
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: () => showDishAllergensDialog(context, dishName: item.name, allergens: item.allergens),
        child: Container(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: AppColors.border),
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
        ),
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
                        child: Padding(
                          padding: const EdgeInsets.fromLTRB(8, 8, 8, 8),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              Text(e.menu.name, maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w700)),
                              const SizedBox(height: 4),
                              Text(
                                cartLineDetailSubtitle(e),
                                style: TextStyle(fontSize: 11, height: 1.25, color: Colors.grey.shade800),
                              ),
                              Row(
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
                              if (e.dip.trim().isNotEmpty)
                                Row(
                                  mainAxisAlignment: MainAxisAlignment.end,
                                  children: [
                                    IconButton(
                                      padding: EdgeInsets.zero,
                                      constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
                                      icon: const Icon(Icons.remove_circle_outline, size: 20),
                                      onPressed: e.dipQty > 0 ? () => widget.state.changeDipQty(e, -1) : null,
                                    ),
                                    Padding(
                                      padding: const EdgeInsets.symmetric(horizontal: 4),
                                      child: Text('${e.dipQty}', style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 13)),
                                    ),
                                    IconButton(
                                      padding: EdgeInsets.zero,
                                      constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
                                      icon: const Icon(Icons.add_circle_outline, size: 20),
                                      onPressed: () => widget.state.changeDipQty(e, 1),
                                    ),
                                  ],
                                ),
                            ],
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
        final subtotal = widget.state.tray.fold<double>(0, (s, e) => s + cartLineSubtotal(e));
        final menuBody = Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
              child: TextField(
                decoration: const InputDecoration(hintText: 'SEARCH'),
                onChanged: (v) => setState(() => _search = v),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
              child: Align(
                alignment: Alignment.center,
                child: Text(
                  kCustomerOnlineOrdersAreaNotice,
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 12, height: 1.35, color: Colors.blueGrey.shade800, fontWeight: FontWeight.w600),
                ),
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
                              child: Padding(
                                padding: const EdgeInsets.fromLTRB(8, 10, 8, 10),
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.stretch,
                                  children: [
                                    Row(
                                      crossAxisAlignment: CrossAxisAlignment.start,
                                      children: [
                                        SizedBox(
                                          width: 56,
                                          height: 56,
                                          child: ClipRRect(
                                            borderRadius: BorderRadius.circular(8),
                                            child: _MenuThumb(item: item.menu, compact: true),
                                          ),
                                        ),
                                        const SizedBox(width: 10),
                                        Expanded(
                                          child: Column(
                                            crossAxisAlignment: CrossAxisAlignment.start,
                                            children: [
                                              Text(item.menu.name, style: const TextStyle(fontWeight: FontWeight.w700)),
                                              const SizedBox(height: 4),
                                              Text(
                                                cartLineDetailSubtitle(item),
                                                style: TextStyle(fontSize: 12, height: 1.3, color: Colors.grey.shade800),
                                              ),
                                            ],
                                          ),
                                        ),
                                      ],
                                    ),
                                    const SizedBox(height: 8),
                                    Row(
                                      children: [
                                        const Text('Main qty', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 12)),
                                        const Spacer(),
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
                                    if (item.dip.trim().isNotEmpty) ...[
                                      const SizedBox(height: 4),
                                      Row(
                                        children: [
                                          const Text('Add-on qty', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 12)),
                                          const Spacer(),
                                          IconButton(
                                            onPressed: item.dipQty > 0 ? () => state.changeDipQty(item, -1) : null,
                                            icon: const Icon(Icons.remove_circle_outline),
                                          ),
                                          Text('${item.dipQty}', style: const TextStyle(fontWeight: FontWeight.w800)),
                                          IconButton(
                                            onPressed: () => state.changeDipQty(item, 1),
                                            icon: const Icon(Icons.add_circle_outline),
                                          ),
                                        ],
                                      ),
                                    ],
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
  bool _deliveryAddressOptionsLoading = true;
  final TextEditingController _guestFirstNameCtl = TextEditingController();
  final TextEditingController _guestLastNameCtl = TextEditingController();
  final TextEditingController _guestContactCtl = TextEditingController();
  final TextEditingController _guestEmailCtl = TextEditingController();
  final TextEditingController _guestDeliveryCtl = TextEditingController();
  double? _guestMapLat;
  double? _guestMapLng;
  double? _guestDeliveryDistanceKm;
  bool _guestDeliveryRangeBusy = false;
  String? _guestDeliveryRangeError;
  final List<String> _guestAddrSuggestions = [];
  Timer? _guestGeoDebounce;

  bool get _guestDeliveryOutOfRange =>
      _guestDeliveryDistanceKm != null && _guestDeliveryDistanceKm! > kDeliveryMaxDistanceKm;

  String _guestFullName() => '${_guestFirstNameCtl.text.trim()} ${_guestLastNameCtl.text.trim()}'.trim();

  void _syncGuestFullName() => widget.state.updateGuestCheckoutContact(fullName: _guestFullName());

  @override
  void initState() {
    super.initState();
    noteController.text = widget.state.checkoutNote;
    final p = widget.state.profile;
    final nameParts = p.fullName.trim().split(RegExp(r'\s+'));
    _guestFirstNameCtl.text = nameParts.isNotEmpty ? nameParts.first : '';
    _guestLastNameCtl.text = nameParts.length > 1 ? nameParts.sublist(1).join(' ') : '';
    _guestContactCtl.text = p.contactNumber;
    _guestEmailCtl.text = p.contactEmail;
    _guestDeliveryCtl.text = p.deliveryAddress;
    _guestMapLat = p.deliveryLat;
    _guestMapLng = p.deliveryLng;
    if (_guestMapLat != null && _guestMapLng != null) {
      _guestDeliveryDistanceKm = haversineKm(
        lat1: kRestaurantLat,
        lng1: kRestaurantLng,
        lat2: _guestMapLat!,
        lng2: _guestMapLng!,
      );
    }
    _deliveryAddresses.clear();
    _selectedDeliveryAddress = null;
    _selectedDeliveryTime = widget.state.checkoutDeliveryTime.trim().isEmpty ? 'NOW' : widget.state.checkoutDeliveryTime.trim();
    unawaited(_loadInRangeDeliveryAddresses());
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      await widget.state.loadMenu(force: true);
      if (!widget.state.isGuestSession) {
        await widget.state.pullCustomerTrayDraftFromServer();
      }
      if (!mounted) return;
      if (widget.state.tray.isEmpty) {
        appSnack(context, 'Your tray is empty.');
        Navigator.of(context).maybePop();
        return;
      }
      setState(() {});
    });
  }

  Future<void> _loadInRangeDeliveryAddresses() async {
    final profile = widget.state.profile;
    final fromProfile = List<String>.from(profile.deliveryAddresses);
    final primary = profile.deliveryAddress.trim();
    final merged = <String>{...fromProfile};
    if (primary.isNotEmpty) merged.add(primary);
    final ordered = merged.toList();
    const eps = 0.05;
    final kept = <String>[];
    for (final a in ordered) {
      final trim = a.trim();
      if (trim.isEmpty) continue;
      double? d;
      if (trim == primary && profile.deliveryLat != null && profile.deliveryLng != null) {
        d = haversineKm(
          lat1: kRestaurantLat,
          lng1: kRestaurantLng,
          lat2: profile.deliveryLat!,
          lng2: profile.deliveryLng!,
        );
      } else {
        d = await geocodeAddressDistanceKmFromRestaurant(trim);
      }
      if (d != null && d <= kDeliveryMaxDistanceKm + eps) kept.add(a);
    }
    if (!mounted) return;
    final savedSel = widget.state.checkoutSelectedAddress?.trim();
    String? nextSel;
    if (savedSel != null && savedSel.isNotEmpty && kept.contains(savedSel)) {
      nextSel = savedSel;
    } else if (kept.isNotEmpty) {
      nextSel = kept.first;
    }
    setState(() {
      _deliveryAddresses
        ..clear()
        ..addAll(kept);
      _selectedDeliveryAddress = nextSel;
      _deliveryAddressOptionsLoading = false;
    });
    if (nextSel != null) {
      widget.state.updateCheckoutDraftAddress(nextSel);
    } else {
      widget.state.updateCheckoutDraftAddress(null);
    }
  }

  Future<void> _evaluateGuestDeliveryRangeFromLatLng(double lat, double lng) async {
    final d = haversineKm(lat1: kRestaurantLat, lng1: kRestaurantLng, lat2: lat, lng2: lng);
    if (!mounted) return;
    setState(() {
      _guestDeliveryDistanceKm = d;
      _guestDeliveryRangeError = null;
      _guestDeliveryRangeBusy = false;
    });
    widget.state.updateGuestCheckoutContact(deliveryLat: lat, deliveryLng: lng, deliveryMapConfirmed: true);
  }

  Future<void> _resolveGuestDeliveryRangeFromAddress(String address) async {
    final q = address.trim();
    widget.state.updateGuestCheckoutContact(deliveryAddress: q);
    if (q.isEmpty) {
      if (!mounted) return;
      setState(() {
        _guestDeliveryDistanceKm = null;
        _guestDeliveryRangeError = null;
        _guestDeliveryRangeBusy = false;
      });
      return;
    }
    if (mounted) setState(() => _guestDeliveryRangeBusy = true);
    try {
      final uri = Uri.parse(
        'https://nominatim.openstreetmap.org/search?q=${Uri.encodeComponent(q)}&format=json&limit=1',
      );
      final res = await http.get(uri, headers: {'User-Agent': kNominatimUserAgent}).timeout(_apiTimeout);
      if (res.statusCode != 200) {
        if (!mounted) return;
        setState(() {
          _guestDeliveryRangeError = 'Could not verify delivery range yet.';
          _guestDeliveryRangeBusy = false;
        });
        return;
      }
      final list = jsonDecode(res.body) as List<dynamic>;
      if (list.isEmpty) {
        if (!mounted) return;
        setState(() {
          _guestDeliveryRangeError = 'Could not locate this address for range validation.';
          _guestDeliveryRangeBusy = false;
        });
        return;
      }
      final m = list.first as Map<String, dynamic>;
      final lat = jsonToDouble(m['lat']);
      final lng = jsonToDouble(m['lon']);
      _guestMapLat = lat;
      _guestMapLng = lng;
      await _evaluateGuestDeliveryRangeFromLatLng(lat, lng);
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _guestDeliveryRangeError = 'Could not verify delivery range yet.';
        _guestDeliveryRangeBusy = false;
      });
    }
  }

  void _suggestGuestAddress(String q) {
    _guestGeoDebounce?.cancel();
    final query = q.trim();
    widget.state.updateGuestCheckoutContact(deliveryAddress: query);
    if (query.length < 3) {
      if (_guestAddrSuggestions.isNotEmpty && mounted) setState(() => _guestAddrSuggestions.clear());
      return;
    }
    _guestGeoDebounce = Timer(const Duration(milliseconds: 280), () async {
      unawaited(_resolveGuestDeliveryRangeFromAddress(query));
      try {
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
          _guestAddrSuggestions
            ..clear()
            ..addAll(next);
        });
      } catch (_) {}
    });
  }

  Future<void> _openGuestMapsDialog() async {
    final addrHint = _guestDeliveryCtl.text.trim();
    final r = await showDialog<MapPinResult>(
      context: context,
      builder: (ctx) => _MapPinPickerDialog(
        initialSearchQuery: addrHint,
        initialLat: _guestMapLat ?? widget.state.profile.deliveryLat,
        initialLng: _guestMapLng ?? widget.state.profile.deliveryLng,
      ),
    );
    if (r != null && mounted) {
      setState(() {
        _guestDeliveryCtl.text = r.address;
        _guestMapLat = r.lat;
        _guestMapLng = r.lng;
        _guestAddrSuggestions.clear();
      });
      widget.state.updateGuestCheckoutContact(
        deliveryAddress: r.address,
        deliveryLat: r.lat,
        deliveryLng: r.lng,
        deliveryMapConfirmed: true,
      );
      await _evaluateGuestDeliveryRangeFromLatLng(r.lat, r.lng);
    }
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
    _guestGeoDebounce?.cancel();
    noteController.dispose();
    _guestFirstNameCtl.dispose();
    _guestLastNameCtl.dispose();
    _guestContactCtl.dispose();
    _guestEmailCtl.dispose();
    _guestDeliveryCtl.dispose();
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
                if (!s.isGuestSession) await s.loadProfile(force: true);
                await s.loadMenu(force: true);
                if (!s.isGuestSession) await s.pullCustomerTrayDraftFromServer();
                if (!mounted) return;
                setState(() => _deliveryAddressOptionsLoading = true);
                await _loadInRangeDeliveryAddresses();
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
                      if (s.isGuestSession) ...[
                        TextField(
                          controller: _guestFirstNameCtl,
                          decoration: const InputDecoration(labelText: 'FIRST NAME'),
                          onChanged: (_) => _syncGuestFullName(),
                        ),
                        const SizedBox(height: 10),
                        TextField(
                          controller: _guestLastNameCtl,
                          decoration: const InputDecoration(labelText: 'LAST NAME'),
                          onChanged: (_) => _syncGuestFullName(),
                        ),
                        const SizedBox(height: 10),
                        TextField(
                          controller: _guestContactCtl,
                          keyboardType: TextInputType.phone,
                          maxLength: 11,
                          inputFormatters: [
                            FilteringTextInputFormatter.digitsOnly,
                            LengthLimitingTextInputFormatter(11),
                          ],
                          decoration: const InputDecoration(labelText: 'CONTACT NUMBER', counterText: ''),
                          onChanged: (v) => s.updateGuestCheckoutContact(contactNumber: v),
                        ),
                        const SizedBox(height: 10),
                        TextField(
                          controller: _guestEmailCtl,
                          keyboardType: TextInputType.emailAddress,
                          decoration: const InputDecoration(labelText: 'EMAIL ADDRESS'),
                          onChanged: (v) => s.updateGuestCheckoutContact(contactEmail: v),
                        ),
                        const SizedBox(height: 10),
                        TextField(
                          controller: _guestDeliveryCtl,
                          minLines: 2,
                          maxLines: 4,
                          onChanged: _suggestGuestAddress,
                          decoration: InputDecoration(
                            labelText: 'DELIVERY ADDRESS',
                            hintText: 'Within ${kDeliveryMaxDistanceKm.toStringAsFixed(0)} km of our Taguig restaurant',
                            suffixIcon: IconButton(
                              tooltip: 'Pin on map',
                              onPressed: _openGuestMapsDialog,
                              icon: const Icon(Icons.place_outlined),
                            ),
                          ),
                        ),
                        if (_guestDeliveryRangeBusy)
                          const Padding(
                            padding: EdgeInsets.only(top: 6),
                            child: LinearProgressIndicator(minHeight: 2),
                          ),
                        if (_guestDeliveryOutOfRange)
                          Padding(
                            padding: const EdgeInsets.only(top: 6),
                            child: Text(
                              'Out of range (~${_guestDeliveryDistanceKm!.toStringAsFixed(1)} km; max ${kDeliveryMaxDistanceKm.toStringAsFixed(0)} km)',
                              style: TextStyle(fontSize: 12, color: Colors.red.shade800, fontWeight: FontWeight.w700),
                            ),
                          )
                        else if (_guestDeliveryDistanceKm != null)
                          Padding(
                            padding: const EdgeInsets.only(top: 6),
                            child: Text(
                              'Within delivery range (~${_guestDeliveryDistanceKm!.toStringAsFixed(1)} km)',
                              style: TextStyle(fontSize: 12, color: Colors.green.shade800, fontWeight: FontWeight.w600),
                            ),
                          ),
                        if (_guestDeliveryRangeError != null && _guestDeliveryRangeError!.isNotEmpty)
                          Padding(
                            padding: const EdgeInsets.only(top: 6),
                            child: Text(
                              _guestDeliveryRangeError!,
                              style: TextStyle(fontSize: 12, color: Colors.red.shade800),
                            ),
                          ),
                        if (_guestAddrSuggestions.isNotEmpty)
                          Container(
                            margin: const EdgeInsets.only(top: 6),
                            decoration: BoxDecoration(
                              border: Border.all(color: Colors.grey.shade300),
                              borderRadius: BorderRadius.circular(8),
                            ),
                            child: Column(
                              children: _guestAddrSuggestions
                                  .map(
                                    (addr) => ListTile(
                                      dense: true,
                                      title: Text(addr, maxLines: 2, overflow: TextOverflow.ellipsis),
                                      onTap: () {
                                        setState(() {
                                          _guestDeliveryCtl.text = addr;
                                          _guestAddrSuggestions.clear();
                                        });
                                        unawaited(_resolveGuestDeliveryRangeFromAddress(addr));
                                      },
                                    ),
                                  )
                                  .toList(),
                            ),
                          ),
                      ] else ...[
                        LockedField(label: 'NAME', value: s.profile.fullName),
                        LockedField(label: 'CONTACT NUMBER', value: s.profile.contactNumber),
                      ],
                      if (!s.isGuestSession) ...[
                      if (_deliveryAddressOptionsLoading)
                        const Padding(
                          padding: EdgeInsets.symmetric(vertical: 16),
                          child: Center(child: CircularProgressIndicator()),
                        )
                      else if (_deliveryAddresses.isEmpty)
                        Padding(
                          padding: const EdgeInsets.only(top: 4, bottom: 4),
                          child: Text(
                            'No saved addresses are within ${kDeliveryMaxDistanceKm.toStringAsFixed(0)} km. Add or pin an in-range address in My Profile.',
                            style: TextStyle(color: Colors.red.shade800, fontSize: 13),
                          ),
                        )
                      else
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
                      ],
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
                            isThreeLine: e.dip.trim().isNotEmpty,
                            title: Text(e.menu.name),
                            subtitle: Text(cartLineDetailSubtitle(e)),
                            trailing: Text('₱${cartLineSubtotal(e).toStringAsFixed(2)}', style: const TextStyle(fontWeight: FontWeight.w800)),
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
              if (!s.isGuestSession && _deliveryAddressOptionsLoading) {
                appSnack(context, 'Still checking which addresses are in range.');
                return;
              }
              if (s.tray.isEmpty) {
                appSnack(context, 'Your tray is empty.');
                return;
              }
              if (s.isGuestSession) {
                s.updateGuestCheckoutContact(
                  fullName: _guestFullName(),
                  contactNumber: _guestContactCtl.text.trim(),
                  contactEmail: _guestEmailCtl.text.trim(),
                  deliveryAddress: _guestDeliveryCtl.text.trim(),
                );
                if (_guestFirstNameCtl.text.trim().isEmpty) {
                  appSnack(context, 'Enter your first name.');
                  return;
                }
                if (_guestLastNameCtl.text.trim().isEmpty) {
                  appSnack(context, 'Enter your last name.');
                  return;
                }
                if (s.profile.contactNumber.trim().isEmpty) {
                  appSnack(context, 'Enter your contact number.');
                  return;
                }
                final em = s.profile.contactEmail.trim();
                if (em.isEmpty || !em.contains('@') || !em.contains('.')) {
                  appSnack(context, 'Enter a valid email address.');
                  return;
                }
                if (s.profile.deliveryAddress.trim().isEmpty) {
                  appSnack(context, 'Enter your delivery address.');
                  return;
                }
                if (_selectedDeliveryTime.trim().isEmpty) {
                  appSnack(context, 'Choose a delivery time (ASAP or schedule).');
                  return;
                }
                if (_guestDeliveryDistanceKm == null || _guestDeliveryOutOfRange) {
                  appSnack(context, 'Pin or select a delivery address within ${kDeliveryMaxDistanceKm.toStringAsFixed(0)} km of the restaurant.');
                  return;
                }
              } else {
                if ((_selectedDeliveryAddress ?? '').trim().isEmpty) {
                  appSnack(context, 'Select your delivery address.');
                  return;
                }
                if (s.profile.fullName.trim().isEmpty || s.profile.contactNumber.trim().isEmpty) {
                  appSnack(context, 'Complete your name and contact number in My Profile first.');
                  return;
                }
                s.profile.deliveryAddress = _selectedDeliveryAddress!.trim();
              }
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
  /// Keeps first GCash proof visible after customer uploads balance proof (server field can lag on refresh).
  String? _pinnedInitialProofB64;

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
              dipQty: e.dipQty,
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
      imageQuality: 48,
      maxWidth: 1024,
      maxHeight: 1024,
    );
    if (file == null) return;
    final bytes = await file.readAsBytes();
    final proofB64 = base64Encode(bytes);
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
      final err = await s.uploadPaymentProof(newOrder.id, file, paymentProofBase64: proofB64);
      if (!mounted) return;
      if (err != null) {
        appSnack(context, err);
        return;
      }
      setState(() {
        _placedOrder = newOrder;
        uploadedFile = file;
        _localProofBytes = bytes;
        localProofUploaded = true;
      });
      await s.loadOrders(force: true);
      return;
    }
    final ordPre = _placedOrder ?? widget.order;
    if (ordPre != null) {
      final st = ordPre.status.toUpperCase();
      final ins = st.contains('INSUFFICIENT') || st.contains('PAYMENT INSUFFICIENT');
      if (ins) {
        final pb = ordPre.paymentProofBase64?.trim();
        if (pb != null && pb.isNotEmpty) _pinnedInitialProofB64 ??= pb;
      }
    }
    final oid = (_placedOrder ?? widget.order)!.id;
    final err = await s.uploadPaymentProof(oid, file, paymentProofBase64: proofB64);
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
    await s.loadOrders(force: true);
    final syPin = _syncedOrder(s);
    final pbp = syPin?.paymentProofBase64?.trim();
    if (pbp != null && pbp.isNotEmpty) _pinnedInitialProofB64 ??= pbp;
    } finally {
      if (mounted) setState(() => _uploadingProof = false);
    }
  }

  Widget _paymentProofPreview(OrderData? synced) {
    if (_localProofBytes != null) {
      final bytes = _localProofBytes!;
      return Padding(
        padding: const EdgeInsets.only(top: 10),
        child: Center(
          child: InkWell(
            onTap: () => showProofFullScreen(context, bytes, title: 'Payment proof'),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(10),
              child: Image.memory(bytes, height: 200, fit: BoxFit.contain),
            ),
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
          child: Center(
            child: InkWell(
              onTap: () => showProofFullScreen(context, Uint8List.fromList(bytes), title: 'Payment proof'),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(10),
                child: Image.memory(Uint8List.fromList(bytes), height: 200, fit: BoxFit.contain),
              ),
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
        final finalOrderStatusUp = orderForUi.status.toUpperCase();
        // Keep the balance-payment UI (additional-payment card + original proof)
        // even after uploading the balance proof; the backend switches the status
        // to "WAITING FOR BALANCE PAYMENT CONFIRMATION".
        final insufficient = !isDraft &&
            (finalOrderStatusUp.contains('INSUFFICIENT') || finalOrderStatusUp.contains('WAITING FOR BALANCE PAYMENT CONFIRMATION'));
        final paidSoFar = orderForUi.cashierAmountReceived ?? 0;
        final remainder = (orderForUi.total - paidSoFar).clamp(0, double.infinity);
        final supplementalOk =
            (synced?.supplementalPaymentProofBase64?.trim().isNotEmpty ?? false) || (insufficient && localProofUploaded);
        final proofDone = insufficient
            ? supplementalOk
            : ((synced?.paymentUploaded ?? false) ||
                localProofUploaded ||
                ((synced?.paymentProofBase64?.isNotEmpty ?? false)));
        final interceptBack =
            localProofUploaded || _placedOrder != null || (!widget.draftCheckout && widget.order != null);
        return PopScope(
          canPop: !interceptBack,
          onPopInvokedWithResult: (didPop, _) {
            if (didPop) return;
            Navigator.of(context).pushAndRemoveUntil(
              MaterialPageRoute<void>(builder: (_) => CustomerDashboardScreen(state: s)),
              (_) => false,
            );
          },
          child: AppScaffold(
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
                    if (s.isGuestSession && (proofDone || _placedOrder != null)) ...[
                      Container(
                        width: double.infinity,
                        padding: const EdgeInsets.all(14),
                        decoration: BoxDecoration(
                          color: const Color(0xFFFFF3CD),
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(color: const Color(0xFFFFC107), width: 2),
                        ),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Icon(Icons.mark_email_read_outlined, color: Colors.orange.shade900, size: 28),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Text(
                                'After you submit payment proof, watch your email and text messages for payment confirmation and other order updates.',
                                style: TextStyle(
                                  fontSize: 14,
                                  height: 1.4,
                                  fontWeight: FontWeight.w800,
                                  color: Colors.brown.shade900,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 12),
                    ],
                    _OrderNoCard(displayNo: isDraft ? null : uiOrderNo(orderForUi.orderNo)),
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
                            if (((_pinnedInitialProofB64 ?? synced?.paymentProofBase64) ?? '').trim().isNotEmpty) ...[
                              const SizedBox(height: 10),
                              const Text('Original payment proof', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 12)),
                              Padding(
                                padding: const EdgeInsets.only(top: 6),
                                child: InkWell(
                                  onTap: () {
                                    final b64 = (_pinnedInitialProofB64 ?? synced?.paymentProofBase64 ?? '').trim();
                                    showProofFullScreen(
                                      context,
                                      Uint8List.fromList(base64Decode(b64)),
                                      title: 'Original payment proof',
                                    );
                                  },
                                  child: ClipRRect(
                                    borderRadius: BorderRadius.circular(10),
                                    child: Image.memory(
                                      Uint8List.fromList(
                                        base64Decode((_pinnedInitialProofB64 ?? synced?.paymentProofBase64 ?? '').trim()),
                                      ),
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
                                isThreeLine: e.dip.trim().isNotEmpty,
                                title: Text(e.menu.name),
                                subtitle: Text(cartLineDetailSubtitle(e)),
                                trailing: Text('₱${cartLineSubtotal(e).toStringAsFixed(2)}', style: const TextStyle(fontWeight: FontWeight.w800)),
                              ),
                            )
                          else if (orderForUi.lines.isEmpty)
                            const Text('No tray lines available.')
                          else
                            ...orderForUi.lines.map(
                              (l) => ListTile(
                                dense: true,
                                isThreeLine: l.dip.trim().isNotEmpty,
                                title: Text(l.itemName),
                                subtitle: Text(orderLineDetailSubtitle(l)),
                                trailing: Text('₱${orderLineSubtotal(l).toStringAsFixed(2)}', style: const TextStyle(fontWeight: FontWeight.w800)),
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
                  final insNow = ordNow.status.toUpperCase().contains('INSUFFICIENT') ||
                      ordNow.status.toUpperCase().contains('WAITING FOR BALANCE PAYMENT CONFIRMATION');
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
                    // Requirement: navigate to the order page first, then clear tray/draft.
                    if (widget.draftCheckout) unawaited(s.clearCheckoutAfterSuccessfulOrderAndPayment());
                  });
                },
              ),
            ],
          ),
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
  bool _didShowProofSnack = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      await widget.state.loadOrders(force: true);
      if (!mounted) return;
      setState(() {});
      final o = _resolvedOrder();
      final proofOk = widget.paymentUploaded ||
          o.paymentUploaded ||
          (o.paymentProofBase64 != null && o.paymentProofBase64!.trim().isNotEmpty);
      if (proofOk && !_didShowProofSnack) {
        _didShowProofSnack = true;
        appSnack(context, 'Payment proof uploaded. We will notify you when payment is confirmed.');
      }
    });
  }

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
      title: 'YOUR ORDER',
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
                if (state.isGuestSession) ...[
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(14),
                    decoration: BoxDecoration(
                      color: const Color(0xFFFFF3CD),
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(color: const Color(0xFFFFC107), width: 2),
                    ),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Icon(Icons.sms_outlined, color: Colors.orange.shade900, size: 28),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text(
                            'Please wait for an email or text message from us about payment confirmation, insufficient payment, and delivery updates. '
                            'Save the contact number and email you used at checkout so you do not miss our messages.',
                            style: TextStyle(
                              fontSize: 14,
                              height: 1.4,
                              fontWeight: FontWeight.w800,
                              color: Colors.brown.shade900,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 14),
                ] else
                  Text(
                    'You will be notified for payment confirmation soon!',
                    style: TextStyle(fontSize: 14, height: 1.35, color: Colors.blueGrey.shade800, fontWeight: FontWeight.w600),
                  ),
                if (!state.isGuestSession) const SizedBox(height: 12),
                if (state.isGuestSession) const SizedBox(height: 4),
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(uiOrderNo(order.orderNo), style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w800)),
                        const SizedBox(height: 8),
                        Text('Status: ${statusReadable(order.status)}'),
                        Text('Total: ₱${order.total.toStringAsFixed(2)}'),
                        Text('Payment proof: ${_proofReceived(order) ? 'Received' : 'Not uploaded yet'}'),
                        if (order.lines.isNotEmpty) ...[
                          const Divider(height: 22),
                          const Text('Your items', style: TextStyle(fontWeight: FontWeight.w800)),
                          const SizedBox(height: 8),
                          ...order.lines.map(
                            (l) => Padding(
                              padding: const EdgeInsets.only(bottom: 6),
                              child: Text(
                                '• ${l.itemName}${l.dip.isEmpty ? '' : ' — ${l.dip} ×${l.dipQty}'} ×${l.qty}  ₱${orderLineSubtotal(l).toStringAsFixed(2)}',
                                style: const TextStyle(height: 1.3),
                              ),
                            ),
                          ),
                        ],
                        if (canFollowUp) ...[
                          const SizedBox(height: 10),
                          OutlinedButton.icon(
                            onPressed: () async {
                              final err = await state.submitHelpRequest(
                                area: 'Order Follow-up',
                                problem: 'Follow-up on pending order ${uiOrderNo(order.orderNo)}',
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
                if (!state.isGuestSession) ...[
                  const SizedBox(height: 10),
                  OutlinedButton(
                    onPressed: () {
                      Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => MyOrdersScreen(state: state)));
                    },
                    child: const Text('MY ORDERS'),
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
        content: Text('Cancel ${uiOrderNo(o.orderNo)}? It will appear under Cancelled orders.'),
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

  Widget _starRatingView(int stars) {
    final clamped = stars.clamp(1, 5);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: List.generate(5, (i) {
        final selected = i < clamped;
        return Icon(
          selected ? Icons.star : Icons.star_border,
          size: 14,
          color: selected ? Colors.amber.shade700 : Colors.grey.shade400,
        );
      }),
    );
  }
  Future<void> _followUpOrder(OrderData o) async {
    final err = await widget.state.submitHelpRequest(
      area: 'Order Follow-up',
      problem: 'Follow-up on pending order ${uiOrderNo(o.orderNo)}',
      desiredOutcome: 'Please update this order status or next action.',
    );
    if (!mounted) return;
    appSnack(context, err ?? 'Follow-up sent');
  }

  late TabController _tab;
  String _search = '';
  /// Tab 0 — Pending Confirmation: All, Past 30 days, Waiting for Payment Confirmation, Payment Insufficient
  String _pendingFilterMode = 'all';
  /// Tabs 1 and 3 — Confirmed / Cancelled: All vs Past 30 days
  String _ordersDateRangeNonPending = 'all';
  /// Tab 2 — Completed: All vs Past 30 days
  String _completedOrdersRange = 'all';
  Map<String, Map<String, dynamic>> _restaurantFeedbackByOrderNo = <String, Map<String, dynamic>>{};

  String get _restaurantFbPrefsKey =>
      'restaurant_order_feedback_v1_${widget.state.userEmail?.trim().toLowerCase() ?? 'guest'}';

  Future<void> _loadRestaurantFeedbackPrefs() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_restaurantFbPrefsKey);
    final next = <String, Map<String, dynamic>>{};
    if (raw != null && raw.trim().isNotEmpty) {
      try {
        final decoded = jsonDecode(raw);
        if (decoded is Map<String, dynamic>) {
          decoded.forEach((k, v) {
            if (v is Map<String, dynamic>) next[k] = v;
          });
        }
      } catch (_) {}
    }
    if (!mounted) return;
    setState(() => _restaurantFeedbackByOrderNo = next);
  }

  Future<void> _persistRestaurantFeedbackPrefs() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_restaurantFbPrefsKey, jsonEncode(_restaurantFeedbackByOrderNo));
  }

  Future<void> _sendRestaurantOrderFeedback(OrderData o) async {
    if (widget.state.isGuestSession) {
      appSnack(context, 'Sign in to submit feedback.');
      return;
    }
    final key = o.orderNo;
    final ctl = TextEditingController(
      text: (_restaurantFeedbackByOrderNo[key]?['remarks'] ?? '').toString(),
    );
    var stars = 5;
    final prevStars = _restaurantFeedbackByOrderNo[key]?['stars'];
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
            title: Text('Feedback · ${uiOrderNo(o.orderNo)}'),
            content: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('How was this restaurant order?'),
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
                      hintText: 'Optional comments about your completed order',
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
    ctl.dispose();
    if (ok != true || !mounted) return;
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => const Center(child: CircularProgressIndicator()),
    );
    final err = await widget.state.submitOrderFeedback(
      kind: 'restaurant_order',
      reference: key,
      rating: stars,
      comment: msg,
    );
    if (mounted) Navigator.of(context).pop();
    if (!mounted) return;
    if (err == null) {
      setState(() {
        _restaurantFeedbackByOrderNo[key] = <String, dynamic>{
          'stars': stars,
          'remarks': msg,
          'submittedAt': DateTime.now().toIso8601String(),
        };
      });
      await _persistRestaurantFeedbackPrefs();
    }
    if (!mounted) return;
    appSnack(context, err ?? 'Feedback submitted');
  }

  @override
  void initState() {
    super.initState();
    _tab = TabController(length: 4, vsync: this);
    _tab.addListener(() {
      if (mounted) setState(() {});
    });
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      await _loadRestaurantFeedbackPrefs();
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
      if (tabIndex == 0) {
        switch (_pendingFilterMode) {
          case 'past_30':
            if (!isWithinPast30Days(o.createdAt)) return false;
            break;
          case 'wait_payment_confirm':
            final u = o.status.toUpperCase();
            if (!(u.contains('WAITING FOR PAYMENT CONFIRMATION') ||
                u.contains('WAITING FOR BALANCE PAYMENT CONFIRMATION') ||
                u.contains('WAITING FOR ORDER CONFIRMATION') ||
                u.contains('WAITING FOR ORDER'))) {
              return false;
            }
            break;
          case 'payment_insufficient':
            final u = o.status.toUpperCase();
            if (!u.contains('INSUFFICIENT') && !u.contains('PAYMENT INSUFFICIENT')) return false;
            break;
        }
      } else if (tabIndex == 1 || tabIndex == 3) {
        if (_ordersDateRangeNonPending == 'past_30' && !isWithinPast30Days(o.createdAt)) return false;
      } else if (tabIndex == 2) {
        if (_completedOrdersRange == 'past_30' && !isWithinPast30Days(o.createdAt)) return false;
      }
      return true;
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
                              Text(uiOrderNo(o.orderNo)),
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
                              if (o.loyaltyPointsEarned > 0 && (tabIndex == 1 || tabIndex == 2) && !widget.state.isGuestSession)
                                Text('Loyalty: +${o.loyaltyPointsEarned} pts', style: const TextStyle(fontSize: 12)),
                              if (tabIndex == 2 && _restaurantFeedbackByOrderNo.containsKey(o.orderNo))
                                Builder(
                                  builder: (ctx) {
                                    final fb = _restaurantFeedbackByOrderNo[o.orderNo];
                                    final rawStars = fb?['stars'];
                                    final stars = rawStars is int ? rawStars : int.tryParse('$rawStars') ?? 0;
                                    return stars > 0 ? _starRatingView(stars) : const SizedBox.shrink();
                                  },
                                ),
                              Text(formatDateTimeLocal(o.createdAt), style: const TextStyle(fontSize: 12)),
                              const SizedBox(height: 4),
                              Text(
                                '₱${o.total.toStringAsFixed(2)}',
                                style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 12.5),
                              ),
                              if (tabIndex == 1 &&
                                  orderShowsDeliveryTrackingLink(o)) ...[
                                const SizedBox(height: 6),
                                Builder(
                                  builder: (ctx) {
                                    final uri = _tryBuildHttpUri(o.deliveryTrackingUrl.trim());
                                    if (uri != null) {
                                      return InkWell(
                                        onTap: () => launchUrl(uri, mode: LaunchMode.externalApplication),
                                        child: Text(
                                          'Tracking: ${o.deliveryTrackingUrl.trim()}',
                                          style: TextStyle(
                                            fontSize: 12,
                                            color: Colors.blue.shade800,
                                            decoration: TextDecoration.underline,
                                          ),
                                        ),
                                      );
                                    }
                                    return SelectableText(
                                      'Tracking: ${o.deliveryTrackingUrl.trim()}',
                                      style: const TextStyle(fontSize: 12, height: 1.3),
                                    );
                                  },
                                ),
                              ],
                            ],
                          ),
                    isThreeLine: false,
                    trailing: ConstrainedBox(
                      constraints: BoxConstraints(
                        maxWidth: tabIndex == 2 ? 120 : 92,
                        minHeight: 0,
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        mainAxisAlignment: MainAxisAlignment.end,
                        crossAxisAlignment: CrossAxisAlignment.center,
                        children: [
                          if (tabIndex == 2 && orderLooksCompleted(o) && !widget.state.isGuestSession) ...[
                            IconButton(
                              tooltip: _restaurantFeedbackByOrderNo.containsKey(o.orderNo)
                                  ? 'Feedback submitted'
                                  : 'Rate this order',
                              padding: EdgeInsets.zero,
                              visualDensity: VisualDensity.compact,
                              constraints: const BoxConstraints(minWidth: 30, minHeight: 32),
                              icon: Icon(
                                _restaurantFeedbackByOrderNo.containsKey(o.orderNo)
                                    ? Icons.check_circle
                                    : Icons.rate_review_outlined,
                                size: 18,
                              ),
                              onPressed: () => _sendRestaurantOrderFeedback(o),
                            ),
                          ],
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
                          title: Text(uiOrderNo(o.orderNo)),
                          content: SingleChildScrollView(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                _detailLine('Order no.', uiOrderNo(o.orderNo)),
                                _detailLine('Status', statusReadableForOrder(o)),
                                _detailLine('Fulfillment stage', fulfillmentStageReadable(o.fulfillmentStage)),
                                Builder(
                                  builder: (ctx) {
                                    final fb = _restaurantFeedbackByOrderNo[o.orderNo];
                                    if (fb == null) return const SizedBox.shrink();
                                    final rawStars = fb['stars'];
                                    final stars = rawStars is int ? rawStars : int.tryParse('$rawStars') ?? 0;
                                    final remarks = '${fb['remarks'] ?? ''}'.trim();
                                    return Column(
                                      crossAxisAlignment: CrossAxisAlignment.start,
                                      children: [
                                        if (stars > 0) _starRatingView(stars),
                                        if (remarks.isNotEmpty) ...[
                                          const SizedBox(height: 8),
                                          _detailLine('Remarks', remarks),
                                        ],
                                      ],
                                    );
                                  },
                                ),
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
                                if (orderShowsDeliveryTrackingLink(o)) _detailTrackingUrl('Delivery tracking', o.deliveryTrackingUrl.trim()),
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
                                    (orderPaymentReferenceBalance(o) != null || orderHasBalancePaymentProofImage(o))
                                        ? 'Yes'
                                        : 'Not yet — open Balance payment',
                                  ),
                                ],
                                const SizedBox(height: 8),
                                Text(
                                  'Payment on file: ${orderHasPaymentOnFile(o) ? 'Yes' : 'No'}',
                                  style: const TextStyle(height: 1.35),
                                ),
                                if (orderPaymentReferenceInitial(o) != null)
                                  _detailLine('Payment reference', orderPaymentReferenceInitial(o)!),
                                if (orderPaymentReferenceBalance(o) != null)
                                  _detailLine('Balance payment reference', orderPaymentReferenceBalance(o)!),
                                if (orderHasInitialPaymentProofImage(o)) ...[
                                  const SizedBox(height: 12),
                                  const Text('Payment proof', style: TextStyle(fontWeight: FontWeight.w800, fontSize: 16)),
                                  const SizedBox(height: 8),
                                  ..._buildProofPreview(o.paymentProofBase64!),
                                ],
                                if (orderHasBalancePaymentProofImage(o)) ...[
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
                                        '• ${l.itemName}${l.dip.isEmpty ? '' : ' — ${l.dip} ×${l.dipQty}'} ×${l.qty}  ₱${orderLineSubtotal(l).toStringAsFixed(2)}',
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

  Uri? _tryBuildHttpUri(String raw) {
    final s = raw.trim();
    if (s.isEmpty) return null;
    final withScheme = (s.startsWith('http://') || s.startsWith('https://')) ? s : 'https://$s';
    final uri = Uri.tryParse(withScheme);
    if (uri == null) return null;
    final scheme = uri.scheme.toLowerCase();
    if (scheme != 'http' && scheme != 'https') return null;
    return uri;
  }

  Widget _detailTrackingUrl(String label, String url) {
    final uri = _tryBuildHttpUri(url);
    final ok = uri != null;
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
                    if (_tab.index == 0)
                      PopupMenuButton<String>(
                        tooltip: 'Pending filters',
                        icon: Icon(Icons.filter_list, color: _pendingFilterMode == 'all' ? null : AppColors.accent),
                        onSelected: (v) => setState(() => _pendingFilterMode = v),
                        itemBuilder: (ctx) => [
                          PopupMenuItem<String>(
                            value: 'all',
                            child: Row(
                              children: [
                                if (_pendingFilterMode == 'all')
                                  Icon(Icons.check, size: 18, color: Theme.of(ctx).colorScheme.primary),
                                if (_pendingFilterMode == 'all') const SizedBox(width: 4),
                                const Text('All'),
                              ],
                            ),
                          ),
                          PopupMenuItem<String>(
                            value: 'past_30',
                            child: Row(
                              children: [
                                if (_pendingFilterMode == 'past_30')
                                  Icon(Icons.check, size: 18, color: Theme.of(ctx).colorScheme.primary),
                                if (_pendingFilterMode == 'past_30') const SizedBox(width: 4),
                                const Text('Past 30 days'),
                              ],
                            ),
                          ),
                          PopupMenuItem<String>(
                            value: 'wait_payment_confirm',
                            child: Row(
                              children: [
                                if (_pendingFilterMode == 'wait_payment_confirm')
                                  Icon(Icons.check, size: 18, color: Theme.of(ctx).colorScheme.primary),
                                if (_pendingFilterMode == 'wait_payment_confirm') const SizedBox(width: 4),
                                const Text('Waiting for Payment Confirmation'),
                              ],
                            ),
                          ),
                          PopupMenuItem<String>(
                            value: 'payment_insufficient',
                            child: Row(
                              children: [
                                if (_pendingFilterMode == 'payment_insufficient')
                                  Icon(Icons.check, size: 18, color: Theme.of(ctx).colorScheme.primary),
                                if (_pendingFilterMode == 'payment_insufficient') const SizedBox(width: 4),
                                const Text('Payment Insufficient'),
                              ],
                            ),
                          ),
                        ],
                      ),
                    if (_tab.index == 1 || _tab.index == 3)
                      PopupMenuButton<String>(
                        tooltip: 'Date range',
                        icon: Icon(Icons.date_range, color: _ordersDateRangeNonPending == 'past_30' ? AppColors.accent : null),
                        onSelected: (v) => setState(() => _ordersDateRangeNonPending = v),
                        itemBuilder: (ctx) => [
                          PopupMenuItem<String>(
                            value: 'all',
                            child: Row(
                              children: [
                                if (_ordersDateRangeNonPending == 'all')
                                  Icon(Icons.check, size: 18, color: Theme.of(ctx).colorScheme.primary),
                                if (_ordersDateRangeNonPending == 'all') const SizedBox(width: 4),
                                const Text('All'),
                              ],
                            ),
                          ),
                          PopupMenuItem<String>(
                            value: 'past_30',
                            child: Row(
                              children: [
                                if (_ordersDateRangeNonPending == 'past_30')
                                  Icon(Icons.check, size: 18, color: Theme.of(ctx).colorScheme.primary),
                                if (_ordersDateRangeNonPending == 'past_30') const SizedBox(width: 4),
                                const Text('Past 30 days'),
                              ],
                            ),
                          ),
                        ],
                      ),
                    if (_tab.index == 2)
                      PopupMenuButton<String>(
                        tooltip: 'Completed orders date range',
                        icon: Icon(Icons.date_range, color: _completedOrdersRange == 'past_30' ? AppColors.accent : null),
                        onSelected: (v) => setState(() => _completedOrdersRange = v),
                        itemBuilder: (ctx) => [
                          PopupMenuItem<String>(
                            value: 'all',
                            child: Row(
                              children: [
                                if (_completedOrdersRange == 'all')
                                  Icon(Icons.check, size: 18, color: Theme.of(ctx).colorScheme.primary),
                                if (_completedOrdersRange == 'all') const SizedBox(width: 4),
                                const Text('All'),
                              ],
                            ),
                          ),
                          PopupMenuItem<String>(
                            value: 'past_30',
                            child: Row(
                              children: [
                                if (_completedOrdersRange == 'past_30')
                                  Icon(Icons.check, size: 18, color: Theme.of(ctx).colorScheme.primary),
                                if (_completedOrdersRange == 'past_30') const SizedBox(width: 4),
                                const Text('Past 30 days'),
                              ],
                            ),
                          ),
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
  bool _deliveryRangeBusy = false;
  double? _deliveryDistanceKm;
  String? _deliveryRangeError;

  bool get _deliveryOutOfRange =>
      _deliveryDistanceKm != null && _deliveryDistanceKm! > kDeliveryMaxDistanceKm;

  Future<void> _evaluateDeliveryRangeFromLatLng(double lat, double lng) async {
    final d = haversineKm(
      lat1: kRestaurantLat,
      lng1: kRestaurantLng,
      lat2: lat,
      lng2: lng,
    );
    if (!mounted) return;
    setState(() {
      _deliveryDistanceKm = d;
      _deliveryRangeError = null;
      _deliveryRangeBusy = false;
    });
  }

  Future<void> _resolveAndEvaluateDeliveryRangeFromAddress(String address) async {
    final q = address.trim();
    if (q.isEmpty) {
      if (!mounted) return;
      setState(() {
        _deliveryDistanceKm = null;
        _deliveryRangeError = null;
        _deliveryRangeBusy = false;
      });
      return;
    }
    setState(() {
      _deliveryRangeBusy = true;
      _deliveryRangeError = null;
    });
    try {
      final uri = Uri.parse(
        'https://nominatim.openstreetmap.org/search?q=${Uri.encodeComponent(q)}&format=json&limit=1',
      );
      final res = await http.get(uri, headers: {'User-Agent': kNominatimUserAgent}).timeout(_apiTimeout);
      if (res.statusCode != 200) {
        if (!mounted) return;
        setState(() {
          _deliveryRangeError = 'Could not verify delivery range yet.';
          _deliveryRangeBusy = false;
        });
        return;
      }
      final list = jsonDecode(res.body) as List<dynamic>;
      if (list.isEmpty) {
        if (!mounted) return;
        setState(() {
          _deliveryRangeError = 'Could not locate this address for range validation.';
          _deliveryRangeBusy = false;
        });
        return;
      }
      final m = list.first as Map<String, dynamic>;
      final lat = jsonToDouble(m['lat']);
      final lng = jsonToDouble(m['lon']);
      mapLat = lat;
      mapLng = lng;
      await _evaluateDeliveryRangeFromLatLng(lat, lng);
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _deliveryRangeError = 'Could not verify delivery range yet.';
        _deliveryRangeBusy = false;
      });
    }
  }

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
    if (mapLat != null && mapLng != null) {
      final d = haversineKm(
        lat1: kRestaurantLat,
        lng1: kRestaurantLng,
        lat2: mapLat!,
        lng2: mapLng!,
      );
      _deliveryDistanceKm = d;
      _deliveryRangeError = null;
      _deliveryRangeBusy = false;
    } else {
      _deliveryDistanceKm = null;
      _deliveryRangeError = null;
      _deliveryRangeBusy = false;
    }
  }

  @override
  void initState() {
    super.initState();
    nameController = TextEditingController();
    contactController = TextEditingController();
    addressController = TextEditingController();
    _applyProfileToControllers();
    if ((mapLat == null || mapLng == null) && addressController.text.trim().isNotEmpty) {
      unawaited(_resolveAndEvaluateDeliveryRangeFromAddress(addressController.text.trim()));
    }
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!widget.state.isGuestSession) {
        await widget.state.loadProfile(force: true);
      }
      await widget.state.loadInquiries(force: true);
      if (!mounted) return;
      setState(_applyProfileToControllers);
      if ((mapLat == null || mapLng == null) && addressController.text.trim().isNotEmpty) {
        unawaited(_resolveAndEvaluateDeliveryRangeFromAddress(addressController.text.trim()));
      }
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

  void _suggestAddress(String q, {bool evaluateRange = true}) {
    _addrDebounce?.cancel();
    final query = q.trim();
    if (query.length < 3) {
      if (_addrSuggestions.isNotEmpty) setState(() => _addrSuggestions.clear());
      return;
    }
    _addrDebounce = Timer(const Duration(milliseconds: 280), () async {
      if (evaluateRange) {
        unawaited(_resolveAndEvaluateDeliveryRangeFromAddress(query));
      }
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
      await _evaluateDeliveryRangeFromLatLng(r.lat, r.lng);
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
                  TextField(
                    controller: contactController,
                    keyboardType: TextInputType.phone,
                    maxLength: 11,
                    inputFormatters: [
                      FilteringTextInputFormatter.digitsOnly,
                      LengthLimitingTextInputFormatter(11),
                    ],
                    decoration: const InputDecoration(
                      labelText: 'Contact Number',
                      counterText: '',
                    ),
                  ),
                  const SizedBox(height: 10),
                  TextField(
                    controller: addressController,
                    onChanged: (v) {
                      _suggestAddress(v, evaluateRange: true);
                    },
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
                  if (_deliveryRangeBusy)
                    const Padding(
                      padding: EdgeInsets.only(top: 6),
                      child: LinearProgressIndicator(minHeight: 2),
                    ),
                  if (_deliveryOutOfRange)
                    Padding(
                      padding: const EdgeInsets.only(top: 6),
                      child: Text(
                        'Delivery address is out of range (max ${kDeliveryMaxDistanceKm.toStringAsFixed(0)} km from restaurant).',
                        style: TextStyle(color: Colors.red.shade700, fontWeight: FontWeight.w700),
                      ),
                    )
                  else if (_deliveryDistanceKm != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 6),
                      child: Text(
                        'Distance from restaurant: ${_deliveryDistanceKm!.toStringAsFixed(2)} km',
                        style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
                      ),
                    ),
                  if (_deliveryRangeError != null && _deliveryRangeError!.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 6),
                      child: Text(
                        _deliveryRangeError!,
                        style: TextStyle(color: Colors.red.shade700, fontWeight: FontWeight.w700),
                      ),
                    ),
                  const SizedBox(height: 10),
                  TextField(
                    controller: _newAddressManual,
                    onChanged: (v) => _suggestAddress(v, evaluateRange: false),
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
                                    unawaited(_resolveAndEvaluateDeliveryRangeFromAddress(s));
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
                          onTap: () {
                            setState(() {
                              addressController.text = a;
                            });
                            unawaited(_resolveAndEvaluateDeliveryRangeFromAddress(a));
                          },
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
                        Padding(
                          padding: const EdgeInsets.only(top: 4),
                          child: Text(
                            'Points earned from completed catering & events: ${cateringCompletedLoyaltyEarnedFromHistory(widget.state.loyaltyHistory)} pts',
                            style: TextStyle(fontSize: 12, height: 1.3, color: Colors.grey.shade800),
                          ),
                        ),
                        Padding(
                          padding: const EdgeInsets.only(top: 4),
                          child: Text(
                            'Completed catering inquiries (My Catering Inquiries): ${cateringCompletedLoyaltyFromInquiries(widget.state.inquiries)} pts',
                            style: TextStyle(fontSize: 12, height: 1.3, color: Colors.grey.shade800),
                          ),
                        ),
                        const Divider(height: 16),
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
                                    final label = h.orderNo.trim().isEmpty ? '******' : uiOrderNo(h.orderNo);
                                    final src = h.source == 'catering' ? 'Catering / Event' : 'Restaurant';
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
                if (primary.isNotEmpty) {
                  if (mapLat == null || mapLng == null) {
                    await _resolveAndEvaluateDeliveryRangeFromAddress(primary);
                  }
                  if (_deliveryOutOfRange) {
                    if (mounted) {
                      appSnack(
                        context,
                        'Delivery address is out of range. Please use an address within ${kDeliveryMaxDistanceKm.toStringAsFixed(0)} km.',
                      );
                    }
                    return;
                  }
                  if (_deliveryDistanceKm == null) {
                    if (mounted) {
                      appSnack(context, 'Unable to validate delivery range. Please pin your location on the map.');
                    }
                    return;
                  }
                }
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

class _EventVenueMapPreviewDialog extends StatefulWidget {
  const _EventVenueMapPreviewDialog({required this.address});
  final String address;

  @override
  State<_EventVenueMapPreviewDialog> createState() => _EventVenueMapPreviewDialogState();
}

class _EventVenueMapPreviewDialogState extends State<_EventVenueMapPreviewDialog> {
  final MapController _mapController = MapController();
  LatLng _pin = const LatLng(14.5995, 120.9842);
  bool _busy = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _loadPin());
  }

  Future<void> _loadPin() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final uri = Uri.parse(
        'https://nominatim.openstreetmap.org/search?q=${Uri.encodeComponent(widget.address)}&format=json&limit=1',
      );
      final res = await http.get(uri, headers: {'User-Agent': kNominatimUserAgent}).timeout(_apiTimeout);
      if (res.statusCode != 200) {
        if (mounted) setState(() => _error = 'Could not load map for this address.');
        return;
      }
      final list = jsonDecode(res.body) as List<dynamic>;
      if (list.isEmpty) {
        if (mounted) setState(() => _error = 'Could not find this address on the map.');
        return;
      }
      final m = list.first as Map<String, dynamic>;
      final lat = jsonToDouble(m['lat']);
      final lng = jsonToDouble(m['lon']);
      final ll = LatLng(lat, lng);
      if (!mounted) return;
      setState(() => _pin = ll);
      _mapController.move(ll, 16);
    } catch (_) {
      if (mounted) setState(() => _error = 'Could not load map for this address.');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Event venue'),
      content: SizedBox(
        width: double.maxFinite,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SelectableText(widget.address, style: const TextStyle(fontWeight: FontWeight.w600, height: 1.35)),
            const SizedBox(height: 12),
            if (_busy)
              const SizedBox(height: 220, child: Center(child: CircularProgressIndicator()))
            else if (_error != null)
              SizedBox(
                height: 120,
                child: Center(child: Text(_error!, textAlign: TextAlign.center)),
              )
            else
              SizedBox(
                height: 260,
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(12),
                  child: FlutterMap(
                    mapController: _mapController,
                    options: MapOptions(initialCenter: _pin, initialZoom: 16),
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
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Close')),
        FilledButton.icon(
          onPressed: _busy
              ? null
              : () async {
                  final ok = await openGoogleMapsForAddress(
                    widget.address,
                    lat: _pin.latitude,
                    lng: _pin.longitude,
                  );
                  if (!context.mounted) return;
                  if (!ok) {
                    appSnack(context, 'Could not open Google Maps on this device.');
                  }
                },
          icon: const Icon(Icons.open_in_new, size: 18),
          label: const Text('Open in Google Maps'),
        ),
      ],
    );
  }
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
  String _themeDesignSessionId = 'inquiry-${DateTime.now().microsecondsSinceEpoch}';
  Map<String, dynamic>? _aiThemeDesignPayload;
  String menuSuggestionNote = '';
  String themeSuggestionNote = '';
  final themeNotesController = TextEditingController();
  final List<String> _themeReferenceImagesB64 = <String>[];
  final Set<String> _selectedGuestAllergens = {};
  String selectedSetMenu = 'All Dishes';
  final selectedDishes = <String>{};
  final guestCount = TextEditingController();
  final paxBuffer = TextEditingController();
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
    inquiryEmail.text = p.contactEmail.trim().isNotEmpty
        ? p.contactEmail.trim()
        : (widget.state.isGuestSession ? '' : (widget.state.userEmail ?? ''));
    eventCity.addListener(_onVenueChanged);
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      await Future.wait([
        widget.state.loadMenu(force: true),
        widget.state.loadSetMenus(force: true),
        widget.state.loadAllergenCatalog(force: true),
      ]);
      _scheduleConflictRefresh();
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _scheduleConflictDebounce?.cancel();
    _venueDebounce?.cancel();
    eventCity.removeListener(_onVenueChanged);
    guestCount.dispose();
    paxBuffer.dispose();
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

  void _resetInquiryForm() {
    setState(() {
      inquiryType = 'CATERING';
      curateOwn = false;
      _menuChoicePicked = false;
      _attemptedSubmit = false;
      _themeDesignChoice = '';
      _themeDesignSessionId = 'inquiry-${DateTime.now().microsecondsSinceEpoch}';
      _aiThemeDesignPayload = null;
      menuSuggestionNote = '';
      themeSuggestionNote = '';
      selectedSetMenu = 'All Dishes';
      selectedDishes.clear();
      eventTypeChoice = 'Birthday';
      eventSetting = 'open';
      serviceIncluded = 'no';
      formalityLevel = 'casual';
      foodTastingRequested = false;
      _themeReferenceImagesB64.clear();
      _selectedGuestAllergens.clear();
      _eventWindows
        ..clear()
        ..add(_InquiryEventWindow());
      _publicScheduleConflictCount = 0;
    });
    themeNotesController.clear();
    guestCount.clear();
    paxBuffer.clear();
    eventTitle.clear();
    eventTypeOther.clear();
    contactPerson.clear();
    contactNumber.clear();
    inquiryEmail.clear();
    eventCity.clear();
    note.clear();
    foodTastingDate.clear();
    foodTastingTime.clear();
    menuSearchController.clear();
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

  int _paxBufferForPricing() {
    final raw = paxBuffer.text.trim();
    if (raw.isEmpty) return 0;
    final n = int.tryParse(raw) ?? 0;
    return n < 0 ? 0 : n;
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

  double _estimatedCost() => (_billableGuestCountForPricing() + _paxBufferForPricing()) * kPesosPerPax;

  String _resolvedEventType() {
    if (eventTypeChoice != 'Other') return eventTypeChoice;
    return eventTypeOther.text.trim();
  }

  bool get _contactNumberInvalid {
    final phone = contactNumber.text.trim();
    if (phone.isEmpty) return true;
    if (phone.length > 11) return true;
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

  bool get _venueOutOfCoverage {
    final venue = eventCity.text.trim();
    if (venue.isEmpty) return false;
    return !isAllowedCateringAddressInCoverage(venue);
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

  Widget _eventDesignChoiceCard({
    required String title,
    required String subtitle,
    required bool selected,
    required VoidCallback onTap,
  }) {
    return Material(
      color: selected ? const Color(0xFFFFF8E1) : Colors.white,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: selected ? const Color(0xFFE8B923) : Colors.grey.shade400, width: selected ? 2 : 1),
      ),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(selected ? Icons.radio_button_checked : Icons.radio_button_off, size: 20),
                  const SizedBox(width: 8),
                  Expanded(child: Text(title, style: const TextStyle(fontWeight: FontWeight.w700))),
                ],
              ),
              const SizedBox(height: 6),
              Text(subtitle, style: TextStyle(fontSize: 12, color: Colors.grey.shade700, height: 1.3)),
            ],
          ),
        ),
      ),
    );
  }

  /// Returns null if valid; otherwise an error message for the user.
  String? _validateInquiry() {
    if (contactPerson.text.trim().isEmpty) return 'Enter contact person.';
    final phone = contactNumber.text.trim();
    if (phone.isEmpty) return 'Enter contact number.';
    if (phone.length > 11) return 'Contact number must be at most 11 characters.';
    if (phone.length < 7 || !RegExp(r'^[0-9+\-\s()]+$').hasMatch(phone)) {
      return 'Enter a valid contact number.';
    }
    final email = inquiryEmail.text.trim();
    if (email.isEmpty) return 'Enter email address.';
    if (!RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$').hasMatch(email)) {
      return 'Enter a valid email address.';
    }
    if (eventCity.text.trim().isEmpty) return 'Enter event venue.';
    if (!isAllowedCateringAddressInCoverage(eventCity.text.trim())) {
      return cateringCoverageErrorText();
    }
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
    if (inquiryType == 'CATERING AND EVENT' &&
        _themeDesignChoice == 'create_own' &&
        (_aiThemeDesignPayload == null ||
            '${_aiThemeDesignPayload!['generatedImageUrl'] ?? ''}'.trim().isEmpty)) {
      return 'Create your theme design before submitting.';
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
                await Future.wait([
                  state.loadMenu(force: true),
                  state.loadSetMenus(force: true),
                  state.loadAllergenCatalog(force: true),
                ]);
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
                  'Catering only: minimum $kMinCateringOnlyPax guests. Catering & event: minimum $kMinCateringEventPax guests. Estimated cost is ₱${kPesosPerPax.toStringAsFixed(0)} × (billable guests + pax buffer).',
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
                      ],
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
                        keyboardType: TextInputType.phone,
                        maxLength: 11,
                        inputFormatters: [
                          FilteringTextInputFormatter.digitsOnly,
                          LengthLimitingTextInputFormatter(11),
                        ],
                        decoration: _requiredDecoration(
                          label: 'Contact number',
                          invalid: _contactNumberInvalid,
                        ).copyWith(counterText: ''),
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
                      if (_venueOutOfCoverage)
                        Padding(
                          padding: const EdgeInsets.only(top: 6),
                          child: Text(
                            cateringCoverageErrorText(),
                            style: TextStyle(color: Colors.red.shade700, fontWeight: FontWeight.w700),
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
                        controller: paxBuffer,
                        decoration: const InputDecoration(
                          labelText: 'Pax Buffer (optional)',
                          helperText: 'Additional pax for estimate only (₱500 per pax)',
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
                        const Text(
                          'Before we submit, tell us how you want to approach your event look and feel.',
                          style: TextStyle(height: 1.35),
                        ),
                        const SizedBox(height: 12),
                        Row(
                          children: [
                            Expanded(
                              child: _eventDesignChoiceCard(
                                title: "Have Macrina's design my event",
                                subtitle: 'Share your palette and theme; our team will propose a look.',
                                selected: _themeDesignChoice == 'suggest',
                                onTap: () => setState(() {
                                  _themeDesignChoice = 'suggest';
                                  _aiThemeDesignPayload = null;
                                }),
                              ),
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: _eventDesignChoiceCard(
                                title: 'I want to design my event',
                                subtitle: 'Use AI to explore styles, then submit with your inquiry.',
                                selected: _themeDesignChoice == 'create_own',
                                onTap: () => setState(() => _themeDesignChoice = 'create_own'),
                              ),
                            ),
                          ],
                        ),
                        if (_attemptedSubmit && _themeDesignChoice.isEmpty)
                          Padding(
                            padding: const EdgeInsets.only(top: 8),
                            child: Text(
                              'Choose how you want to handle event design.',
                              style: TextStyle(color: Colors.red.shade700, fontSize: 12),
                            ),
                          ),
                        if (_themeDesignChoice == 'suggest') ...[
                          const SizedBox(height: 12),
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
                                label: const Text('Upload reference image'),
                              ),
                              const SizedBox(width: 8),
                              Text('${_themeReferenceImagesB64.length} image(s)'),
                            ],
                          ),
                        ],
                        if (_themeDesignChoice == 'create_own') ...[
                          const SizedBox(height: 12),
                          if (_aiThemeDesignPayload != null &&
                              '${_aiThemeDesignPayload!['generatedImageUrl'] ?? ''}'.trim().isNotEmpty)
                            Padding(
                              padding: const EdgeInsets.only(bottom: 8),
                              child: ClipRRect(
                                borderRadius: BorderRadius.circular(8),
                                child: Image.network(
                                  '${_aiThemeDesignPayload!['generatedImageUrl']}',
                                  height: 120,
                                  width: double.infinity,
                                  fit: BoxFit.cover,
                                ),
                              ),
                            ),
                          FilledButton.icon(
                            onPressed: () async {
                              final email = inquiryEmail.text.trim().isNotEmpty
                                  ? inquiryEmail.text.trim()
                                  : (widget.state.userEmail ?? '');
                              if (email.isEmpty) {
                                appSnack(context, 'Enter your email before opening theme design.');
                                return;
                              }
                              final result = await Navigator.push<Map<String, dynamic>?>(
                                context,
                                MaterialPageRoute<Map<String, dynamic>?>(
                                  builder: (_) => EventThemeDesignScreen(
                                    apiBase: widget.state.apiBase,
                                    userEmail: email,
                                    designSessionId: _themeDesignSessionId,
                                    initialEventType: _resolvedEventType(),
                                    initialThemeDesign: _aiThemeDesignPayload,
                                    eventTitle: eventTitle.text.trim(),
                                    formalityLevel: formalityLevel,
                                    eventSetting: eventSetting,
                                  ),
                                ),
                              );
                              if (result != null && mounted) {
                                setState(() => _aiThemeDesignPayload = result);
                              }
                            },
                            icon: const Icon(Icons.auto_awesome),
                            label: Text(
                              _aiThemeDesignPayload == null
                                  ? 'Create my own theme design'
                                  : 'Edit theme design',
                            ),
                          ),
                        ],
                        if (_themeReferenceImagesB64.isNotEmpty && _themeDesignChoice == 'suggest') ...[
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
                  title: 'ALLERGENS',
                  expanded: true,
                  onToggle: () {},
                  hideToggleIcon: true,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text(
                        'Select all allergens your guests must avoid (optional).',
                        style: TextStyle(fontSize: 13, color: Colors.grey.shade800, height: 1.35),
                      ),
                      const SizedBox(height: 10),
                      if (state.allergenCatalog.isEmpty)
                        Text(
                          'Loading allergen list… Pull down to refresh if empty.',
                          style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
                        )
                      else
                        Wrap(
                          spacing: 8,
                          runSpacing: 8,
                          children: [
                            for (final name in state.allergenCatalog)
                              FilterChip(
                                label: Text(name, style: const TextStyle(fontSize: 12)),
                                selected: _selectedGuestAllergens.contains(name),
                                onSelected: (sel) => setState(() {
                                  if (sel) {
                                    _selectedGuestAllergens.add(name);
                                  } else {
                                    _selectedGuestAllergens.remove(name);
                                  }
                                }),
                              ),
                          ],
                        ),
                    ],
                  ),
                ),
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
                      if (_menuChoicePicked) ...[
                        const SizedBox(height: 10),
                        Text('Set menu', style: Theme.of(context).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700)),
                        const SizedBox(height: 6),
                        DropdownButtonFormField<String>(
                          value: effectiveSetMenu,
                          decoration: const InputDecoration(
                            border: OutlineInputBorder(),
                            isDense: true,
                            helperText: 'Choose a preset set menu or All Dishes',
                          ),
                          items: setMenuNames.map((name) => DropdownMenuItem(value: name, child: Text(name))).toList(),
                          onChanged: (v) {
                            final next = v ?? 'All Dishes';
                            setState(() {
                              final prev = selectedSetMenu;
                              if (curateOwn && prev != next && prev != 'All Dishes') {
                                final prevRows = state.setMenus.where((m) => m.name == prev).toList();
                                if (prevRows.isNotEmpty) {
                                  for (final d in prevRows.first.dishes) {
                                    selectedDishes.remove(d);
                                  }
                                }
                              }
                              selectedSetMenu = next;
                              if (curateOwn && next != 'All Dishes') {
                                final rows = state.setMenus.where((m) => m.name == next).toList();
                                if (rows.isNotEmpty) selectedDishes.addAll(rows.first.dishes);
                              }
                              if (!curateOwn && next != 'All Dishes') {
                                menuSuggestionNote = 'Preferred set menu: $next';
                              } else if (!curateOwn) {
                                menuSuggestionNote = 'No, suggest me a menu instead.';
                              }
                            });
                          },
                        ),
                      ],
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
                                      title: InkWell(
                                        onTap: () => showDishAllergensDialog(
                                          context,
                                          dishName: dishName,
                                          allergens: dish?.allergens ?? const [],
                                        ),
                                        child: Text(dishName, style: const TextStyle(fontSize: 13, decoration: TextDecoration.underline)),
                                      ),
                                      subtitle: const Text('Tap dish name for allergens', style: TextStyle(fontSize: 11)),
                                      value: sel,
                                      onChanged: (_) => setState(() {
                                        if (sel) {
                                          selectedDishes.remove(dishName);
                                        } else {
                                          selectedDishes.add(dishName);
                                        }
                                      }),
                                      trailing: IconButton(
                                        icon: const Icon(Icons.info_outline, size: 22),
                                        tooltip: 'View allergens',
                                        onPressed: () => showDishAllergensDialog(
                                          context,
                                          dishName: dishName,
                                          allergens: dish?.allergens ?? const [],
                                        ),
                                      ),
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
              SummaryLine('Total Cost', '₱${estimate.toStringAsFixed(2)}', isTotal: true),
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
                        if (_paxBufferForPricing() > 0) ...[
                          const SizedBox(height: 6),
                          Text('Pax buffer: ${_paxBufferForPricing()}'),
                        ],
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
              final paxBufferSaved = _paxBufferForPricing();
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
                'pax_buffer': paxBufferSaved,
                'estimated_total': est,
                'cost_breakdown': [
                  {'label': 'Base food cost', 'amount': guestsSaved * kPesosPerPax},
                  {'label': 'Pax buffer', 'amount': paxBufferSaved * kPesosPerPax},
                ],
                'menu_suggestion_note': curateOwn ? '' : menuSuggestionNote,
                'theme_suggestion_note': themeNotesController.text.trim(),
                if (inquiryType == 'CATERING AND EVENT')
                  'theme_design': _themeDesignChoice == 'create_own'
                      ? Map<String, dynamic>.from(_aiThemeDesignPayload ?? {})
                      : {
                          'eventDesignSource': 'macrina',
                          'note': themeNotesController.text.trim(),
                          'reference_images': _themeReferenceImagesB64,
                        },
                'event_city': eventCity.text.trim(),
                'event_setting': eventSetting,
                'service_included': serviceIncluded,
                'formality_level': formalityLevel,
                if (_selectedGuestAllergens.isNotEmpty) 'guest_allergens': _selectedGuestAllergens.toList(),
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
              if (state.isGuestSession) {
                _resetInquiryForm();
              }
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
  /// Completed tab only: default past 30 days.
  String _inquiryCompletedRange = 'past_30';
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
    if (_feedbackByInquiryId.containsKey(r.id)) return false;
    return !_readCompletedInquiryIds.contains(r.id);
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
    final id = r.id;
    if (_readCompletedInquiryIds.contains(id)) return;
    setState(() => _readCompletedInquiryIds.add(id));
    await _persistReadState();
  }

  @override
  void initState() {
    super.initState();
    _tab = TabController(length: 4, vsync: this);
    _tab.addListener(() {
      if (mounted) setState(() {});
    });
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
    if (r.formalityLevel.trim().isNotEmpty) {
      lines.add(line('Formality: ${r.formalityLevel}'));
    }
    final guestAllergens = r.themeDesign['guest_allergens'];
    if (guestAllergens is List && guestAllergens.isNotEmpty) {
      lines.add(line('Guest allergens to avoid: ${guestAllergens.map((e) => '$e').join(', ')}'));
    }
    if (isFullEvent) {
      if (r.eventTitle.trim().isNotEmpty) lines.add(line('Event title: ${r.eventTitle}'));
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
      text: (_feedbackByInquiryId[r.id]?['remarks'] ?? '').toString(),
    );
    var stars = 5;
    final prevStars = _feedbackByInquiryId[r.id]?['stars'];
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
    if (ok != true || !mounted) return;
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => const Center(child: CircularProgressIndicator()),
    );
    final err = await widget.state.submitOrderFeedback(
      kind: 'catering_inquiry',
      reference: r.id,
      rating: stars,
      comment: msg,
    );
    if (mounted) Navigator.of(context).pop();
    if (!mounted) return;
    if (err == null) {
      setState(() {
        _feedbackByInquiryId[r.id] = <String, dynamic>{
          'stars': stars,
          'remarks': msg,
          'submittedAt': DateTime.now().toIso8601String(),
        };
        _readCompletedInquiryIds.add(r.id);
      });
      await _persistFeedbackState();
      await _persistReadState();
    }
    appSnack(context, err ?? 'Feedback submitted');
  }

  void _showDetail(InquiryRecord r, {required bool allowFollowUp}) {
    _markCompletedInquiryRead(r);
    final feedback = _feedbackByInquiryId[r.id];
    final themeImg =
        '${r.themeDesign['generatedImageUrl'] ?? r.themeDesign['imageUrl'] ?? ''}'.trim();
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(r.displayTransactionRef),
        content: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              ..._inquiryDetailLines(r),
              if (r.isCateringPlusEvent && hasEventThemeDesign(r.themeDesign)) ...[
                const SizedBox(height: 12),
                const Divider(height: 16),
                Text(
                  'Event theme design',
                  style: Theme.of(context).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 6),
                Text(
                  eventDesignSourceLabel(r.themeDesign),
                  style: TextStyle(color: Colors.grey.shade700, fontSize: 13),
                ),
                const SizedBox(height: 8),
                if (themeImg.isNotEmpty)
                  ClipRRect(
                    borderRadius: BorderRadius.circular(8),
                    child: Image.network(
                      themeImg,
                      height: 140,
                      width: double.infinity,
                      fit: BoxFit.cover,
                      errorBuilder: (_, __, ___) => const SizedBox.shrink(),
                    ),
                  )
                else if ('${r.themeDesign['venuePhotoBase64'] ?? ''}'.trim().isNotEmpty)
                  ClipRRect(
                    borderRadius: BorderRadius.circular(8),
                    child: Image.memory(
                      base64Decode('${r.themeDesign['venuePhotoBase64']}'),
                      height: 140,
                      width: double.infinity,
                      fit: BoxFit.cover,
                      errorBuilder: (_, __, ___) => const SizedBox.shrink(),
                    ),
                  ),
              ],
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
      bool applyCompletedDateFilter = false,
    }) {
      final q = _search.trim().toLowerCase();
      final filtered = list.where((i) {
        if (applyCompletedDateFilter && _inquiryCompletedRange == 'past_30' && !isWithinPast30Days(i.createdAt)) {
          return false;
        }
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
                if (_tab.index == 2)
                  PopupMenuButton<String>(
                    tooltip: 'Completed inquiries date range',
                    icon: Icon(Icons.date_range, color: _inquiryCompletedRange == 'past_30' ? AppColors.accent : null),
                    onSelected: (v) => setState(() => _inquiryCompletedRange = v),
                    itemBuilder: (_) => [
                      PopupMenuItem<String>(
                        value: 'past_30',
                        child: Row(
                          children: [
                            if (_inquiryCompletedRange == 'past_30') const Icon(Icons.check, size: 18),
                            const SizedBox(width: 4),
                            const Text('Past 30 days'),
                          ],
                        ),
                      ),
                    ],
                  ),
                PopupMenuButton<String>(
                  tooltip: 'Filters',
                  icon: Icon(Icons.filter_list, color: _filter == 'all' ? null : AppColors.accent),
                  onSelected: (v) => setState(() => _filter = v),
                  itemBuilder: (ctx) => [
                    PopupMenuItem<String>(
                      value: 'all',
                      child: Row(
                        children: [
                          if (_filter == 'all') Icon(Icons.check, size: 18, color: Theme.of(ctx).colorScheme.primary),
                          if (_filter == 'all') const SizedBox(width: 4),
                          const Text('All'),
                        ],
                      ),
                    ),
                    PopupMenuItem<String>(
                      value: 'catering_only',
                      child: Row(
                        children: [
                          if (_filter == 'catering_only') Icon(Icons.check, size: 18, color: Theme.of(ctx).colorScheme.primary),
                          if (_filter == 'catering_only') const SizedBox(width: 4),
                          const Text('Catering'),
                        ],
                      ),
                    ),
                    PopupMenuItem<String>(
                      value: 'event_only',
                      child: Row(
                        children: [
                          if (_filter == 'event_only') Icon(Icons.check, size: 18, color: Theme.of(ctx).colorScheme.primary),
                          if (_filter == 'event_only') const SizedBox(width: 4),
                          const Text('Catering+Event'),
                        ],
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
            child: Align(
              alignment: Alignment.center,
              child: Text(
                kCustomerCateringInquiriesAreaNotice,
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 12, height: 1.35, color: Colors.blueGrey.shade800, fontWeight: FontWeight.w600),
              ),
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
                buildList(completed,
                    allowFollowUp: false, showLoyaltyHint: true, allowFeedback: true, applyCompletedDateFilter: true),
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
  bool _loggingOut = false;

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
    if (ok != true || !context.mounted) return;
    setState(() => _loggingOut = true);
    await Future<void>.delayed(const Duration(milliseconds: 120));
    widget.state.logout();
    if (!mounted) return;
    Navigator.of(context, rootNavigator: true).pushAndRemoveUntil(
      MaterialPageRoute<void>(
        builder: (_) => AuthScreen(
          state: widget.state,
          cashierMode: kPosLoginBuild || widget.state.reopenAuthAsStaff,
        ),
      ),
      (_) => false,
    );
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

  Widget _settingsContent() {
    return Padding(
      padding: const EdgeInsets.all(14),
      child: RefreshIndicator(
        onRefresh: () async {
          if (widget.state.userRole == 'customer') {
            await widget.state.loadProfile(force: true);
            if (mounted) setState(() {});
          }
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
                leading: Icon(
                  widget.state.themeMode == ThemeMode.dark ? Icons.dark_mode_outlined : Icons.light_mode_outlined,
                ),
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
              if (!widget.state.isGuestSession)
                ListTile(
                  leading: const Icon(Icons.logout),
                  title: const Text('Log out'),
                  onTap: _confirmLogout,
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _logoutOverlay() {
    if (!_loggingOut) return const SizedBox.shrink();
    return Positioned.fill(
      child: ColoredBox(
        color: Colors.black54,
        child: Center(
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2.4)),
                const SizedBox(width: 12),
                Text('Logging out...', style: TextStyle(fontSize: 15, color: Colors.grey.shade900)),
              ],
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: widget.state,
      builder: (context, _) {
        final s = widget.state;
        if (s.isManagerOrSupervisor) {
          return Stack(
            children: [
              Scaffold(
                backgroundColor: Theme.of(context).scaffoldBackgroundColor,
                appBar: AppBar(
                  backgroundColor: const Color(0xFF242424),
                  foregroundColor: const Color(0xFFFFC024),
                  leading: _buildManagerHamburgerLeading(context, s),
                  title: const Text('SETTINGS', style: TextStyle(fontWeight: FontWeight.w800)),
                  centerTitle: true,
                ),
                drawer: ManagerRoleDrawer(
                  state: s,
                  onDashboard: () => Navigator.of(context).popUntil((route) => route.isFirst),
                  onManageEvents: () => Navigator.of(context).pop(),
                ),
                body: _settingsContent(),
              ),
              _logoutOverlay(),
            ],
          );
        }
        if (s.isCashier) {
          return Stack(
            children: [
              Scaffold(
                backgroundColor: Theme.of(context).scaffoldBackgroundColor,
                appBar: AppBar(
                  backgroundColor: Colors.black87,
                  foregroundColor: Colors.white,
                  title: const Text('SETTINGS', style: TextStyle(fontWeight: FontWeight.w700)),
                  centerTitle: true,
                ),
                body: _settingsContent(),
              ),
              _logoutOverlay(),
            ],
          );
        }
        return Stack(
          children: [
            AppScaffold(
              state: s,
              title: 'SETTINGS',
              showTrayShortcut: false,
              body: _settingsContent(),
            ),
            _logoutOverlay(),
          ],
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
        title: Text(uiOrderNo(o.orderNo)),
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
          appBar: AppBar(
            backgroundColor: Colors.black87,
            foregroundColor: Colors.white,
            leading: _buildCashierHamburgerLeading(context, widget.state),
            title: const Text('ORDER HISTORY', style: TextStyle(fontWeight: FontWeight.w700)),
            centerTitle: true,
          ),
          drawer: CashierRoleDrawer(state: widget.state, closeExtraRouteForManageOrders: true),
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
                              Expanded(child: Text(uiOrderNo(o.orderNo))),
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
  /// API stage per tab (Down Payment + On Going both use `for_processing`).
  static const _stages = [
    'new_event',
    'online_inquiries',
    'for_processing',
    'for_processing',
    'for_post_analysis',
    'completed',
    'cancelled',
  ];
  static const _labels = [
    'New Event',
    'Online Inquiries',
    'For Down Payment',
    'On Going',
    'For Full Payment',
    'Completed',
    'Cancelled',
  ];
  @override
  void initState() {
    super.initState();
    final idx = widget.initialTabIndex.clamp(0, 6);
    _tab = TabController(length: 7, vsync: this, initialIndex: idx);
    widget.state.setManagerActiveStage(_stages[idx]);
    _tab.addListener(() {
      if (_tab.indexIsChanging) return;
      widget.state.setManagerActiveStage(_stages[_tab.index]);
      widget.state.loadManagerCateringByStage(_stages[_tab.index], force: true);
    });
    widget.state.loadManagerCateringByStage(_stages[idx], force: true);
    widget.state.preloadManagerDashboardCounts();
  }

  @override
  void dispose() {
    _tab.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: widget.state,
      builder: (context, _) {
        return Scaffold(
          appBar: AppBar(
            backgroundColor: const Color(0xFF242424),
            foregroundColor: const Color(0xFFFFC024),
            leading: _buildManagerHamburgerLeading(context, widget.state),
            title: Text((_labels[_tab.index]).toUpperCase(), style: kManagerAppBarTitleStyle),
            centerTitle: true,
            bottom: PreferredSize(
              preferredSize: const Size.fromHeight(48),
              child: Material(
                color: Colors.white,
                elevation: 2,
                shadowColor: Colors.black26,
                child: TabBar(
                  controller: _tab,
                  isScrollable: true,
                  indicatorColor: const Color(0xFFFFC024),
                  labelColor: const Color(0xFFFFC024),
                  unselectedLabelColor: Colors.grey.shade700,
                  tabs: List.generate(_labels.length, (i) {
                    final count = widget.state.managerCateringCountForTab(i);
                    return Tab(
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(_labels[i]),
                          if (i <= 4 && count > 0) ...[
                            const SizedBox(width: 6),
                            _managerTabCountBadge(count),
                          ],
                        ],
                      ),
                    );
                  }),
                ),
              ),
            ),
          ),
          drawer: ManagerRoleDrawer(
            state: widget.state,
            onDashboard: () {
              Navigator.of(context).popUntil((route) => route.isFirst);
            },
            onManageEvents: () {
              _tab.animateTo(0);
            },
          ),
          body: TabBarView(
            controller: _tab,
            children: [
              _ManagerNewEventListTab(state: widget.state),
              _ManagerStageListTab(state: widget.state, stage: 'online_inquiries', isReadOnly: false),
              _ManagerStageListTab(
                state: widget.state,
                stage: 'for_processing',
                isReadOnly: false,
                processingSubstageFilter: 'down_payment',
              ),
              _ManagerStageListTab(
                state: widget.state,
                stage: 'for_processing',
                isReadOnly: false,
                processingSubstageFilter: 'ongoing',
              ),
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
  final paxBuffer = TextEditingController();
  String menuSuggestionNote = '';
  String themeSuggestionNote = '';
  final eventTitle = TextEditingController();
  final customerName = TextEditingController();
  final eventTypeOther = TextEditingController();
  String eventTypeChoice = 'Birthday';
  final contactPerson = TextEditingController();
  final contactNumber = TextEditingController();
  bool _customerSameAsContact = false;
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
  final Set<String> _selectedGuestAllergens = {};
  String _newEventThemeSessionId = 'manager-ne-${DateTime.now().microsecondsSinceEpoch}';
  Map<String, dynamic>? _newEventThemeDesign;
  SeatingPlanData? _newEventSeatingPlan;

  void _syncCustomerFromContactIfChecked() {
    if (!_customerSameAsContact) return;
    customerName.text = contactPerson.text;
  }

  void _resetNewEventFormKeepContactOnly() {
    inquiryType = 'CATERING';
    curateOwn = false;
    selectedSetMenu = 'All Dishes';
    selectedDishes.clear();
    guestCount.clear();
    paxBuffer.clear();
    menuSuggestionNote = '';
    themeSuggestionNote = '';
    eventTitle.clear();
    eventTypeOther.clear();
    eventTypeChoice = 'Birthday';
    customerName.clear();
    _customerSameAsContact = false;
    inquiryEmail.clear();
    eventCity.clear();
    note.clear();
    eventSetting = 'open';
    serviceIncluded = 'no';
    formalityLevel = 'casual';
    _selectedGuestAllergens.clear();
    _newEventThemeSessionId = 'manager-ne-${DateTime.now().microsecondsSinceEpoch}';
    _newEventThemeDesign = null;
    _newEventSeatingPlan = null;
    foodTastingRequested = false;
    foodTastingDate.clear();
    foodTastingTime.clear();
    laborMaleController.text = '0';
    laborFemaleController.text = '0';
    laborManualLabelController.clear();
    laborManualAmountController.clear();
    travelCostController.text = '0';
    themeCostController.text = '0';
    additionalCostLabelController.clear();
    additionalCostAmountController.clear();
    menuSearchController.clear();
    laborManualCosts.clear();
    additionalCosts.clear();
    _eventWindows
      ..clear()
      ..add(_InquiryEventWindow());
  }

  @override
  void initState() {
    super.initState();
    _resetNewEventFormKeepContactOnly();
    contactPerson.addListener(_syncCustomerFromContactIfChecked);
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted) return;
      await widget.state.loadAllergenCatalog();
      if (!mounted) return;
      _loadForProcessingWindowsIfNeeded();
    });
    eventCity.addListener(_onVenueChanged);
  }

  @override
  void dispose() {
    guestCount.dispose();
    paxBuffer.dispose();
    _venueDebounce?.cancel();
    eventCity.removeListener(_onVenueChanged);
    contactPerson.removeListener(_syncCustomerFromContactIfChecked);
    eventTitle.dispose();
    customerName.dispose();
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
    super.dispose();
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

  int _paxBufferForPricing() {
    final raw = paxBuffer.text.trim();
    if (raw.isEmpty) return 0;
    final n = int.tryParse(raw) ?? 0;
    return n < 0 ? 0 : n;
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
      ((_billableGuestCountForPricing() + _paxBufferForPricing()) * kPesosPerPax) +
      _laborCostComputed() +
      _travelCostComputed() +
      (inquiryType == 'CATERING AND EVENT' ? _themeCostComputed() : 0) +
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
    if (customerName.text.trim().isEmpty) return 'Enter customer name.';
    if (contactPerson.text.trim().isEmpty) return 'Enter contact person.';
    final phone = contactNumber.text.trim();
    if (phone.isEmpty) return 'Enter contact number.';
    if (phone.length > 11) return 'Contact number must be at most 11 characters.';
    if (phone.length < 7 || !RegExp(r'^[0-9+\-\s()]+$').hasMatch(phone)) {
      return 'Enter a valid contact number.';
    }
    final email = inquiryEmail.text.trim();
    if (email.isEmpty) return 'Enter email address.';
    if (!RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$').hasMatch(email)) {
      return 'Enter a valid email address.';
    }
    if (eventCity.text.trim().isEmpty) return 'Enter event venue.';
    if (!isAllowedCateringAddressInCoverage(eventCity.text.trim())) {
      return cateringCoverageErrorText();
    }
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
    if (selectedSetMenu == 'All Dishes' && selectedDishes.length < 4) {
      return 'Select at least 4 dishes for the menu.';
    }
    if (selectedDishes.isEmpty) return 'Select at least one dish for the menu.';
    if (eventTitle.text.trim().isEmpty) return 'Enter event title.';
    if (inquiryType == 'CATERING AND EVENT' &&
        themeSuggestionNote.trim().isEmpty &&
        themeCostController.text.trim().isEmpty) {
      return 'Enter theme design notes or theme design cost for Catering + Event.';
    }
    if (travelCostController.text.trim().isEmpty) return 'Enter travel cost.';
    final maleN = int.tryParse(laborMaleController.text.trim()) ?? 0;
    final femaleN = int.tryParse(laborFemaleController.text.trim()) ?? 0;
    if (maleN <= 0 && femaleN <= 0 && laborManualCosts.isEmpty) {
      return 'Enter labor costing (workers and/or manual line items).';
    }
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

  bool get _venueOutOfCoverage {
    final venue = eventCity.text.trim();
    if (venue.isEmpty) return false;
    return !isAllowedCateringAddressInCoverage(venue);
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
        ...?_newEventThemeDesign,
        'note': note.text.trim(),
        'pax_buffer': _paxBufferForPricing(),
        'event_setting': eventSetting,
        'service_included': serviceIncluded,
        'food_tasting_requested': foodTastingRequested,
        'food_tasting_date': foodTastingDate.text.trim(),
        'food_tasting_time': foodTastingTime.text.trim(),
        'theme_cost': _themeCostComputed(),
        'additional_costs': additionalCosts,
        'labor_manual_costs': laborManualCosts,
        'formality_level': formalityLevel,
        if (_selectedGuestAllergens.isNotEmpty) 'guest_allergens': _selectedGuestAllergens.toList(),
        if (inquiryType == 'CATERING AND EVENT') 'theme_suggestion_note': themeSuggestionNote,
      };
      final costBreakdown = <Map<String, dynamic>>[
        {'label': 'Base food cost', 'amount': _billableGuestCountForPricing() * kPesosPerPax},
        {'label': 'Pax buffer', 'amount': _paxBufferForPricing() * kPesosPerPax},
        {'label': 'Labor cost', 'amount': _laborCostComputed()},
        {'label': 'Travel cost', 'amount': _travelCostComputed()},
        if (inquiryType == 'CATERING AND EVENT')
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
                if (eventTitle.text.trim().isNotEmpty) ...[
                  const SizedBox(height: 6),
                  Text('Event: ${eventTitle.text.trim()}'),
                ],
                const SizedBox(height: 6),
                Text('Event type: ${_resolvedEventType()}'),
                const SizedBox(height: 6),
                Text('Guests: ${guestCount.text.trim()}'),
                if (_paxBufferForPricing() > 0) ...[
                  const SizedBox(height: 6),
                  Text('Pax buffer: ${_paxBufferForPricing()}'),
                ],
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
      final err = await withCashierBlockingProgress<String?>(
        context,
        'Saving new event…',
        (() async {
          final createErr = await widget.state.managerCreateNewEvent(
            orderKind: orderKind,
            eventTitle: eventTitle.text.trim(),
            eventType: (inquiryType == 'CATERING' || inquiryType == 'CATERING AND EVENT') ? _resolvedEventType() : '',
            customerName: customerName.text.trim(),
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
            formalityLevel: formalityLevel,
            seatingPlan: orderKind == 'event' &&
                    _newEventSeatingPlan != null &&
                    !_newEventSeatingPlan!.isEffectivelyEmpty
                ? _newEventSeatingPlan!.toJson()
                : null,
          );
          if (createErr != null) return createErr;
          await widget.state.loadManagerCateringByStage('new_event', force: true);
          return null;
        })(),
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
      final paxBufferValue = _paxBufferForPricing();
      final baseFoodCost = _billableGuestCountForPricing() * kPesosPerPax;
      final laborCost = _laborCostComputed();
      final travelCost = _travelCostComputed();
      final themeCost = _themeCostComputed();
      final additionalCostTotal = _sumCostRows(additionalCosts);
      final total = _estimatedCost();
      final downPaymentDue = total * 0.5;
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
            pw.Text('Order Summary before Down Payment', style: pw.TextStyle(fontSize: 18, fontWeight: pw.FontWeight.bold)),
            pw.Text('Macrina\'s Kitchen and Catering', style: pw.TextStyle(fontSize: 10, color: pdf.PdfColors.grey700)),
            pw.SizedBox(height: 12),
            labelValueRow('Transaction No.', '—'),
            labelValueRow('Date/Time processed', formatDateTimeLocal(DateTime.now())),
            labelValueRow(
              'Event',
              eventTitle.text.trim().isEmpty ? customerName.text.trim() : eventTitle.text.trim(),
            ),
            labelValueRow('Date/Time of Event', eventWhen.isEmpty ? '—' : eventWhen),
            labelValueRow('Customer', customerName.text.trim()),
            labelValueRow('Contact person', contactPerson.text.trim()),
            labelValueRow('Contact number', contactNumber.text.trim()),
            labelValueRow('Email address', inquiryEmail.text.trim()),
            labelValueRow('Catering type', cateringType),
            labelValueRow('Event type', _resolvedEventType()),
            labelValueRow('Address of event', eventCity.text.trim()),
            labelValueRow('Service', serviceIncluded == 'yes' ? 'With service' : 'Without service'),
            labelValueRow('Event setting', settingLabel),
            labelValueRow('Formality level', formalityLevel),
            labelValueRow('Menu dishes', menuLines.isEmpty ? '—' : menuLines.join(', ')),
            labelValueRow(
              'No. of PAX and cost',
              '$guestCountValue x PHP ${kPesosPerPax.toStringAsFixed(0)} | PHP ${baseFoodCost.toStringAsFixed(2)}',
            ),
            labelValueRow(
              'PAX buffer and cost',
              '$paxBufferValue x PHP ${kPesosPerPax.toStringAsFixed(0)} | PHP ${(paxBufferValue * kPesosPerPax).toStringAsFixed(2)}',
            ),
            if (inquiryType == 'CATERING AND EVENT')
              labelValueRow('Event theme design cost', 'PHP ${themeCost.toStringAsFixed(2)}'),
            if (additionalCostTotal > 0.01) ...[
              labelValueRow('Additional costs', additionalCostsSummaryForPdf(additionalCosts)),
              labelValueRow('Additional costs (total)', 'PHP ${additionalCostTotal.toStringAsFixed(2)}'),
            ],
            labelValueRow('Labor cost', 'PHP ${laborCost.toStringAsFixed(2)}'),
            labelValueRow('Travel cost', 'PHP ${travelCost.toStringAsFixed(2)}'),
            labelValueRow('Total invoice', 'PHP ${total.toStringAsFixed(2)}'),
            labelValueRow('Total Cost', 'PHP ${total.toStringAsFixed(2)}'),
            labelValueRow('Down payment due (50%)', 'PHP ${downPaymentDue.toStringAsFixed(2)}'),
            labelValueRow('Note', note.text.trim().isEmpty ? '—' : note.text.trim()),
          ],
        ),
      );
      await Printing.layoutPdf(onLayout: (_) async => doc.save());
    }

    return Scaffold(
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      appBar: AppBar(
        backgroundColor: const Color(0xFF242424),
        foregroundColor: const Color(0xFFFFC024),
        leading: _buildManagerHamburgerLeading(context, widget.state),
        title: const Text('NEW EVENT', style: TextStyle(fontWeight: FontWeight.w800)),
        centerTitle: true,
      ),
      drawer: ManagerRoleDrawer(
        state: widget.state,
        onDashboard: () => Navigator.of(context).popUntil((route) => route.isFirst),
        onManageEvents: () => Navigator.of(context).pop(),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(12, 12, 12, 220),
        children: [
        Text(
          'Catering only: minimum $kMinCateringOnlyPax guests. Catering + Event: minimum $kMinCateringEventPax guests. Estimated cost uses ₱${kPesosPerPax.toStringAsFixed(0)} × (billable guests + pax buffer).',
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
                decoration: const InputDecoration(labelText: 'Inquiry type'),
                items: const [
                  DropdownMenuItem(value: 'CATERING', child: Text('CATERING')),
                  DropdownMenuItem(value: 'CATERING AND EVENT', child: Text('CATERING AND EVENT')),
                ],
                onChanged: (v) => setState(() => inquiryType = v ?? 'CATERING'),
              ),
              const SizedBox(height: 8),
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
              const Text('Allergens', style: TextStyle(fontWeight: FontWeight.w800)),
              const SizedBox(height: 6),
              buildGuestAllergenSelector(
                catalog: state.allergenCatalog,
                selected: _selectedGuestAllergens,
                enabled: true,
                onChanged: (next) => setState(() {
                  _selectedGuestAllergens
                    ..clear()
                    ..addAll(next);
                }),
              ),
              const SizedBox(height: 12),
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
              TextField(
                controller: customerName,
                decoration: const InputDecoration(
                  labelText: 'Customer',
                  helperText: 'Required',
                ),
              ),
              const SizedBox(height: 2),
              CheckboxListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                value: _customerSameAsContact,
                onChanged: (v) {
                  setState(() {
                    _customerSameAsContact = v ?? false;
                    if (_customerSameAsContact) {
                      customerName.text = contactPerson.text;
                    }
                  });
                },
                title: const Text('Same as contact person'),
                controlAffinity: ListTileControlAffinity.leading,
              ),
              const SizedBox(height: 8),
              TextField(
                controller: eventTitle,
                decoration: const InputDecoration(
                  labelText: 'Event title',
                  helperText: 'Required',
                ),
              ),
              const SizedBox(height: 8),
              TextField(controller: contactPerson, decoration: const InputDecoration(labelText: 'Contact person')),
              const SizedBox(height: 8),
              TextField(
                controller: contactNumber,
                keyboardType: TextInputType.phone,
                maxLength: 11,
                inputFormatters: [
                  FilteringTextInputFormatter.digitsOnly,
                  LengthLimitingTextInputFormatter(11),
                ],
                decoration: const InputDecoration(labelText: 'Contact number', counterText: ''),
              ),
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
              if (_venueOutOfCoverage)
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Text(
                    cateringCoverageErrorText(),
                    style: TextStyle(color: Colors.red.shade700, fontWeight: FontWeight.w700),
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
              TextField(
                controller: paxBuffer,
                decoration: const InputDecoration(
                  labelText: 'Pax Buffer (optional)',
                  helperText: 'Additional pax for estimate only (₱500 per pax)',
                ),
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
            child: buildManagerThemeDesignBlock(
              themeDesign: _newEventThemeDesign ?? const {},
              openEditorLabel: _newEventThemeDesign == null ? 'Create my own theme design' : 'Edit theme design',
              onOpenEditor: () async {
                final email = inquiryEmail.text.trim().isNotEmpty
                    ? inquiryEmail.text.trim()
                    : (widget.state.userEmail ?? '');
                if (email.isEmpty) {
                  appSnack(context, 'Enter customer email before opening theme design.');
                  return;
                }
                final result = await Navigator.push<Map<String, dynamic>?>(
                  context,
                  MaterialPageRoute<Map<String, dynamic>?>(
                    builder: (_) => EventThemeDesignScreen(
                      apiBase: widget.state.apiBase,
                      userEmail: email,
                      designSessionId: _newEventThemeSessionId,
                      initialEventType: _resolvedEventType(),
                      initialThemeDesign: _newEventThemeDesign,
                      eventTitle: eventTitle.text.trim(),
                      formalityLevel: formalityLevel,
                      eventSetting: eventSetting,
                      cashierEmail: widget.state.userEmail,
                      cashierPassword: widget.state.loginPassword,
                    ),
                  ),
                );
                if (result != null && mounted) {
                  setState(() => _newEventThemeDesign = result);
                }
              },
              showCostFields: true,
              noteController: note,
              costController: themeCostController,
            ),
          ),
          const SizedBox(height: 10),
          ToggleSection(
            title: 'Seating layout',
            expanded: true,
            onToggle: () {},
            hideToggleIcon: true,
            child: buildManagerSeatingLayoutBlock(
              seatingPlanJson: _newEventSeatingPlan?.toJson() ?? const {},
              helperText: 'Plan tables and chairs for this event (optional). Saved with the new event.',
              buttonLabel: _newEventSeatingPlan == null || _newEventSeatingPlan!.isEffectivelyEmpty
                  ? 'Edit seating layout'
                  : 'Edit seating layout (draft saved)',
              onOpenEditor: () async {
                final email = inquiryEmail.text.trim().isNotEmpty
                    ? inquiryEmail.text.trim()
                    : (widget.state.userEmail ?? '');
                if (email.isEmpty) {
                  appSnack(context, 'Enter customer email before editing seating.');
                  return;
                }
                final result = await Navigator.push<SeatingPlanData?>(
                  context,
                  MaterialPageRoute<SeatingPlanData?>(
                    builder: (_) => SeatingLayoutEditorScreen(
                      apiBase: widget.state.apiBase,
                      userEmail: email,
                      orderKind: 'event',
                      draftOnly: true,
                      initialPlan: _newEventSeatingPlan,
                    ),
                  ),
                );
                if (result != null && mounted) {
                  setState(() => _newEventSeatingPlan = result);
                }
              },
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
                decoration: const InputDecoration(labelText: 'Travel cost', helperText: 'Required'),
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
              ...additionalCosts.asMap().entries.map((entry) {
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
                        tooltip: 'Edit',
                        onPressed: () async {
                          final updated = await promptAdditionalCostLineItem(
                            context,
                            initialLabel: '${e['label'] ?? ''}'.trim(),
                            initialAmount: jsonToDouble(e['amount']),
                          );
                          if (updated == null || !mounted) return;
                          setState(() {
                            additionalCosts[idx] = updated;
                          });
                        },
                        icon: const Icon(Icons.edit_outlined, size: 20),
                      ),
                      IconButton(
                        tooltip: 'Delete',
                        onPressed: () => setState(() => additionalCosts.removeAt(idx)),
                        icon: const Icon(Icons.delete_outline, size: 20),
                      ),
                    ],
                  ),
                );
              }),
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
                    const Text('Total Cost', style: TextStyle(fontWeight: FontWeight.w800)),
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

class _ManagerStageListTab extends StatefulWidget {
  const _ManagerStageListTab({
    required this.state,
    required this.stage,
    required this.isReadOnly,
    this.processingSubstageFilter,
  });
  final AppState state;
  final String stage;
  final bool isReadOnly;
  /// When [stage] is `for_processing`, keep only `down_payment` or `ongoing` rows.
  final String? processingSubstageFilter;

  @override
  State<_ManagerStageListTab> createState() => _ManagerStageListTabState();
}

class _ManagerStageListTabState extends State<_ManagerStageListTab> {
  String _q = '';
  String _kind = 'all';
  String _completedListRange = 'past_30';

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
    final state = widget.state;
    final stage = widget.stage;
    var rows = state.managerRowsForStage(stage);
    if (stage == 'completed' && _completedListRange == 'past_30') {
      rows = rows.where((r) => isWithinPast30Days(r.createdAt)).toList();
    }
    if (widget.processingSubstageFilter != null && stage == 'for_processing') {
      rows = rows.where((e) => e.processingSubstageLabel == widget.processingSubstageFilter).toList();
    }
    if (_kind == 'catering') rows = rows.where((r) => r.orderKind == 'catering').toList();
    if (_kind == 'event') rows = rows.where((r) => r.orderKind == 'event').toList();
    final q = _q.trim().toLowerCase();
    if (q.isNotEmpty) {
      rows = rows.where((r) {
        return r.customerName.toLowerCase().contains(q) ||
            r.emailAddress.toLowerCase().contains(q) ||
            r.transactionNo.toLowerCase().contains(q) ||
            r.eventTitle.toLowerCase().contains(q) ||
            r.contactPerson.toLowerCase().contains(q);
      }).toList();
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(10, 8, 10, 4),
          child: Row(
            children: [
              Expanded(
                child: TextField(
                  decoration: const InputDecoration(
                    hintText: 'Search name, email, ref…',
                    isDense: true,
                    border: OutlineInputBorder(),
                  ),
                  onChanged: (v) => setState(() => _q = v),
                ),
              ),
              if (stage == 'completed')
                PopupMenuButton<String>(
                  tooltip: 'Completed date range',
                  icon: Icon(Icons.date_range, color: _completedListRange == 'past_30' ? AppColors.accent : null),
                  onSelected: (v) => setState(() => _completedListRange = v),
                  itemBuilder: (_) => const [
                    PopupMenuItem(value: 'past_30', child: Text('Past 30 days')),
                    PopupMenuItem(value: 'all', child: Text('All time')),
                  ],
                ),
              PopupMenuButton<String>(
                tooltip: 'Filter type',
                onSelected: (v) => setState(() => _kind = v),
                itemBuilder: (ctx) => const [
                  PopupMenuItem(value: 'all', child: Text('All types')),
                  PopupMenuItem(value: 'catering', child: Text('Catering only')),
                  PopupMenuItem(value: 'event', child: Text('Catering + Event')),
                ],
                child: const Icon(Icons.filter_list),
              ),
            ],
          ),
        ),
        Expanded(
          child: RefreshIndicator(
            onRefresh: () => state.loadManagerCateringByStage(stage, force: true),
            child: rows.isEmpty
                ? ListView(
                    physics: const AlwaysScrollableScrollPhysics(),
                    children: const [
                      SizedBox(height: 140),
                      Center(child: Text('No records in this stage.')),
                    ],
                  )
                : ListView.builder(
                    padding: const EdgeInsets.all(10),
                    itemCount: rows.length,
                    itemBuilder: (context, i) {
                      final r = rows[i];
                      final entered = r.stageEnteredAt ?? r.updatedAt;
                      final whenStr = formatDateTimeLocal(entered);
                      final stLower = r.status.trim().toLowerCase();
                      final listSubstage = stage == 'for_processing'
                          ? (widget.processingSubstageFilter ?? r.processingSubstageLabel)
                          : r.processingSubstageLabel;
                      final isDownPaymentCard =
                          stLower == 'for_processing' && listSubstage == 'down_payment';
                      final scheduleLine = (stLower == 'for_post_analysis' || stLower == 'completed' || isDownPaymentCard) &&
                              r.totalCost > 0
                          ? 'Total cost: ₱${r.totalCost.toStringAsFixed(2)}'
                          : (r.schedulePreview.trim().isNotEmpty ? 'Event date/time: ${r.schedulePreview}' : '');
                      final settingLabel = managerEventSettingDisplayLabel(r.eventSetting);
                      final settingLine = settingLabel.isNotEmpty ? 'Setting: $settingLabel' : '';
                      final conflictLine = stage == 'for_processing' && r.processingScheduleOverlaps > 0
                          ? 'Schedule overlap: crosses ${r.processingScheduleOverlaps} other active order(s) — open for details.'
                          : '';
                      final loyaltyLine = () {
                        if (r.cateringLoyaltyPointsEarned > 0) {
                          return 'Catering loyalty: +${r.cateringLoyaltyPointsEarned} pts (this order)';
                        }
                        if (r.cateringLoyaltyEligiblePointsIfCompleted > 0 &&
                            r.status.trim().toLowerCase() != 'completed') {
                          return 'Catering loyalty if completed at this total: +${r.cateringLoyaltyEligiblePointsIfCompleted} pts';
                        }
                        return '';
                      }();
                      final subtitleWidgets = <Widget>[
                        Text(r.contactPerson),
                        Text('${managerStageListTimestampLabel(stage)}: $whenStr'),
                        if (scheduleLine.isNotEmpty) Text(scheduleLine),
                        if (settingLine.isNotEmpty) Text(settingLine),
                        if (r.address.trim().isNotEmpty)
                          buildEventVenueAddressLink(context, r.address, prefix: 'Venue'),
                        if (conflictLine.isNotEmpty) Text(conflictLine),
                        if (loyaltyLine.isNotEmpty) Text(loyaltyLine),
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
                                  cateringManagerListStatusLabelFor(r.status, listSubstage),
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
                          subtitle: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: subtitleWidgets,
                          ),
                          isThreeLine: subtitleWidgets.length > 2,
                          trailing: widget.isReadOnly
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
                                  ],
                                ),
                          onTap: () {
                            Navigator.of(context).push<void>(
                              MaterialPageRoute<void>(
                                builder: (_) => ManagerCateringDetailScreen(
                                  state: state,
                                  row: r,
                                  stage: stage,
                                  processingSubstage: widget.processingSubstageFilter,
                                ),
                              ),
                            );
                          },
                        ),
                      );
                    },
                  ),
          ),
        ),
      ],
    );
  }
}

class ManagerCateringDetailScreen extends StatefulWidget {
  const ManagerCateringDetailScreen({
    super.key,
    required this.state,
    required this.row,
    required this.stage,
    this.processingSubstage,
  });
  final AppState state;
  final CateringEventRecord row;
  final String stage;
  /// Tab context for `for_processing` (`down_payment` | `ongoing`).
  final String? processingSubstage;
  @override
  State<ManagerCateringDetailScreen> createState() => _ManagerCateringDetailScreenState();
}

class _ManagerCateringDetailScreenState extends State<ManagerCateringDetailScreen> {
  static const String _managerDraftDetailKeyPrefix = 'manager_draft_detail_unsaved_v1_';
  CateringEventRecord? _loadedDetailRow;
  bool _detailReady = false;

  CateringEventRecord get d => _loadedDetailRow ?? widget.row;

  String get _processingSubstageForUi {
    if (widget.stage != 'for_processing') return d.processingSubstageLabel;
    // Tab context wins so On Going list/detail never shows "For Down Payment" for ongoing work.
    final tab = widget.processingSubstage?.trim();
    if (tab == 'ongoing' || tab == 'down_payment') return tab!;
    final fromRow = d.processingSubstageLabel.trim();
    if (fromRow == 'ongoing' || fromRow == 'down_payment') return fromRow;
    return 'down_payment';
  }

  final downPaymentController = TextEditingController();
  final downPaymentPaidController = TextEditingController();
  final fullPaymentController = TextEditingController();
  final additionalCostsPaidController = TextEditingController();
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
  final managerCustomerNameController = TextEditingController();
  final managerContactPersonController = TextEditingController();
  final managerContactNumberController = TextEditingController();
  final managerEmailController = TextEditingController();
  final managerAddressController = TextEditingController();
  final managerGuestCountController = TextEditingController();
  final managerPaxBufferController = TextEditingController();
  final managerInquiryNoteController = TextEditingController();
  bool _managerCustomerSameAsContact = false;
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
  Uint8List? _additionalCostsSheetPdfBytes;
  String _additionalCostsSheetPdfSig = '';
  bool _additionalCostsSheetPdfGenerating = false;
  /// Additional-cost line items used for Order Summary PDF #1 (captured on entering For Full Payment, persisted on complete).
  final List<Map<String, dynamic>> _orderSummaryPdf1AdditionalCosts = [];
  /// Committed additional-cost groups per workflow tab (For Down Payment / On Going / For Full Payment).
  final List<Map<String, dynamic>> _additionalCostsGroups = [];
  /// Fingerprint of editable fields for back-navigation prompts.
  String _pristineManagerDetailSig = '';
  /// After a confirmed draft [saveCurrentStage], matches [_computeManagerDetailSignature] until the form changes.
  String _managerDraftAdvanceGateSig = '';
  final List<Map<String, dynamic>> checklistRows = [];
  final List<Map<String, dynamic>> checklistRowsOriginal = [];
  final List<Map<String, dynamic>> taskRows = [];
  final List<Map<String, dynamic>> taskRowsOriginal = [];
  final List<String> actualEventImages = [];
  Uint8List? _managerDownPaymentProofBytes;
  Uint8List? _managerFullPaymentProofBytes;
  Uint8List? _managerAdditionalCostsProofBytes;
  String _managerDownPaymentMethod = 'Cash';
  String _managerFullPaymentMethod = 'Cash';
  final Set<String> managerGuestAllergens = {};
  final List<String> _managerVenueSuggestions = [];
  Timer? _managerVenueDebounce;

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

  /// Guest count as entered on inquiry / new event (excludes pax buffer).
  int _guestCountEntered(CateringEventRecord row) => row.guestCount < 0 ? 0 : row.guestCount;

  int _paxBufferCount(CateringEventRecord row) => paxBufferFromCateringRow(row);

  double _paxBufferCostAmount(CateringEventRecord row) => _paxBufferCount(row) * kPesosPerPax;

  double _guestPaxCostAmount(CateringEventRecord row) => _guestCountEntered(row) * kPesosPerPax;

  String _additionalCostsStageLabel() {
    if (widget.stage == 'for_post_analysis') return 'For Full Payment';
    final sub = _processingSubstageForUi;
    if (sub == 'ongoing') return 'On Going';
    if (sub == 'down_payment') return 'For Down Payment';
    return '';
  }

  bool get _isManagerDraftDetailStage =>
      widget.stage == 'new_event' || widget.stage == 'online_inquiries';

  String _draftAdditionalCostsStageLabel(CateringEventRecord row) {
    for (final label in ['Online Inquiries', 'New Event']) {
      if (_additionalCostsGroups.any((g) => '${g['stage'] ?? ''}'.trim() == label)) return label;
    }
    return row.source.trim().toLowerCase().contains('online') ? 'Online Inquiries' : 'New Event';
  }

  String? _previousAdditionalCostsStageLabel(CateringEventRecord row) {
    final current = cateringManagerDetailTabTitle(
      row,
      widget.stage,
      processingSubstageOverride: widget.processingSubstage,
    );
    switch (current) {
      case 'For Down Payment':
        return _draftAdditionalCostsStageLabel(row);
      case 'On Going':
        return 'For Down Payment';
      case 'For Full Payment':
        return 'On Going';
      default:
        return null;
    }
  }

  List<Map<String, dynamic>> _additionalCostsItemsForStageLabel(String stageLabel) {
    for (final g in _additionalCostsGroups) {
      if ('${g['stage'] ?? ''}'.trim() != stageLabel) continue;
      final items = g['items'];
      if (items is! List) return [];
      return items.whereType<Map>().map((e) => Map<String, dynamic>.from(e)).toList();
    }
    return [];
  }

  List<Map<String, dynamic>> _previousAdditionalCostsItems(CateringEventRecord row) {
    final label = _previousAdditionalCostsStageLabel(row);
    if (label == null || label.isEmpty) return [];
    return _additionalCostsItemsForStageLabel(label);
  }

  void _applyDraftLaborTravelFromRow(CateringEventRecord row) {
    if (_isManagerDraftDetailStage) return;
    travelCostController.text = row.travelCost.toStringAsFixed(2);
    laborMaleController.text = '${row.postAnalysis['labor_male_count'] ?? 0}';
    laborFemaleController.text = '${row.postAnalysis['labor_female_count'] ?? 0}';
    laborManualCosts
      ..clear()
      ..addAll(_laborManualCostsFromRow(row));
  }

  List<Map<String, dynamic>> _laborManualCostsFromRow(CateringEventRecord row) {
    final out = <Map<String, dynamic>>[];
    final lmc = row.postAnalysis['labor_manual_costs'];
    if (lmc is List) {
      for (final e in lmc) {
        if (e is! Map) continue;
        final label = '${e['label'] ?? ''}'.trim();
        if (label == 'Existing labor amount' || label == 'Recorded labor (balance)') continue;
        final amount = jsonToDouble(e['amount']);
        if (label.isEmpty && amount == 0) continue;
        out.add({'label': label, 'amount': amount});
      }
    }
    return out;
  }

  bool _hasAdditionalCostsSectionInput() => additionalCosts.isNotEmpty;

  Future<void> _maybeAutoGenerateAdditionalCostsSheetPdf() async {
    if (_isManagerDraftDetailStage) return;
    if (!_hasAdditionalCostsSectionInput()) {
      if (_additionalCostsSheetPdfBytes != null && mounted) {
        setState(() {
          _additionalCostsSheetPdfBytes = null;
          _additionalCostsSheetPdfSig = '';
        });
      }
      return;
    }
    final sig = _additionalCostsSignature(additionalCosts);
    if (sig == _additionalCostsSheetPdfSig || _additionalCostsSheetPdfGenerating) return;
    _additionalCostsSheetPdfGenerating = true;
    try {
      final bytes = await _buildOrderSummaryPdfBytes(
        additionalCostsForPdf: additionalCosts,
        postAnalysis2Only: true,
        variant: _ManagerOrderSummaryPdfVariant.additionalCostsSheet,
      );
      if (!mounted) return;
      setState(() {
        _additionalCostsSheetPdfBytes = bytes;
        _additionalCostsSheetPdfSig = sig;
      });
    } catch (_) {
      // Preview button still works on demand.
    } finally {
      _additionalCostsSheetPdfGenerating = false;
    }
  }

  List<Map<String, dynamic>> _additionalCostsGroupsForOrderSummarySheet() => _additionalCostsGroups
      .where((g) => _isManagerAdditionalCostsSheetStage('${g['stage'] ?? ''}'))
      .toList();

  /// Sheet PDF groups, including unsaved line items for the active workflow tab.
  List<Map<String, dynamic>> _additionalCostsGroupsForAdditionalCostsSheetPdf() {
    final out = _additionalCostsGroupsForOrderSummarySheet()
        .map((g) => Map<String, dynamic>.from(g))
        .toList();
    final currentLabel = _additionalCostsStageLabel();
    if (currentLabel.isEmpty || additionalCosts.isEmpty) return out;
    final items = additionalCosts.map((e) => Map<String, dynamic>.from(e)).toList();
    final entry = <String, dynamic>{
      'stage': currentLabel,
      'items': items,
      'total': _sumCostRows(items),
      'processed_at': DateTime.now().toIso8601String(),
    };
    final idx = out.indexWhere((g) => '${g['stage'] ?? ''}'.trim() == currentLabel);
    if (idx >= 0) {
      out[idx] = entry;
    } else {
      out.add(entry);
    }
    return out;
  }

  double _additionalCostsSheetPdfTotal() {
    var sum = 0.0;
    for (final g in _additionalCostsGroupsForAdditionalCostsSheetPdf()) {
      final items = (g['items'] is List)
          ? (g['items'] as List).whereType<Map>().map((e) => Map<String, dynamic>.from(e)).toList()
          : <Map<String, dynamic>>[];
      sum += jsonToDouble(g['total']) > 0 ? jsonToDouble(g['total']) : _sumCostRows(items);
    }
    return sum;
  }

  List<Map<String, dynamic>> _flattenAdditionalCostsFromGroupsList(List<Map<String, dynamic>> groups) {
    final out = <Map<String, dynamic>>[];
    for (final g in groups) {
      final items = g['items'];
      if (items is List) {
        for (final e in items) {
          if (e is Map) out.add(Map<String, dynamic>.from(e));
        }
      }
    }
    return out;
  }

  List<Map<String, dynamic>> _sheetAdditionalCostsForOrderSummaryPdf() =>
      _flattenAdditionalCostsFromGroupsList(_additionalCostsGroupsForOrderSummarySheet());

  List<Map<String, dynamic>> _allAdditionalCostsForMainOrderSummaryPdf() {
    final out = <Map<String, dynamic>>[];
    final seen = <String>{};
    void addItem(Map<String, dynamic> e) {
      final key = '${e['label'] ?? ''}|${jsonToDouble(e['amount']).toStringAsFixed(2)}';
      if (seen.add(key)) out.add(e);
    }
    for (final e in _flattenAdditionalCostsFromGroups()) {
      addItem(e);
    }
    for (final c in d.additionalCosts) {
      if (c is Map) addItem(Map<String, dynamic>.from(c));
    }
    return out;
  }

  double _compiledPostDraftAdditionalCostsTotal({bool includeWorkingPostStage = false}) {
    var sum = 0.0;
    for (final g in _additionalCostsGroupsForOrderSummarySheet()) {
      final items = (g['items'] is List)
          ? (g['items'] as List).whereType<Map>().map((e) => Map<String, dynamic>.from(e)).toList()
          : <Map<String, dynamic>>[];
      sum += jsonToDouble(g['total']) > 0 ? jsonToDouble(g['total']) : _sumCostRows(items);
    }
    if (includeWorkingPostStage && widget.stage == 'for_post_analysis') {
      sum += _sumCostRows(additionalCosts);
    }
    return sum;
  }

  List<Map<String, dynamic>> _flattenAdditionalCostsFromGroups() {
    final out = <Map<String, dynamic>>[];
    for (final g in _additionalCostsGroups) {
      final items = g['items'];
      if (items is List) {
        for (final e in items) {
          if (e is Map) out.add(Map<String, dynamic>.from(e));
        }
      }
    }
    for (final e in additionalCosts) {
      out.add(Map<String, dynamic>.from(e));
    }
    return out;
  }

  bool _hasAdditionalCostsForOrderSummaryPdf() =>
      _hasAdditionalCostsSectionInput() || _sheetAdditionalCostsForOrderSummaryPdf().isNotEmpty;

  void _snapshotAdditionalCostsForCurrentStage({bool clearWorking = false, bool refreshTimestamp = true}) {
    final label = _additionalCostsStageLabel();
    if (label.isEmpty || additionalCosts.isEmpty) return;
    final items = additionalCosts.map((e) => Map<String, dynamic>.from(e)).toList();
    final idx = _additionalCostsGroups.indexWhere((g) => '${g['stage'] ?? ''}'.trim() == label);
    final entry = <String, dynamic>{
      'stage': label,
      'items': items,
      'total': _sumCostRows(items),
      'processed_at': refreshTimestamp || idx < 0
          ? DateTime.now().toIso8601String()
          : '${_additionalCostsGroups[idx]['processed_at'] ?? DateTime.now().toIso8601String()}',
    };
    if (idx >= 0) {
      _additionalCostsGroups[idx] = entry;
    } else {
      _additionalCostsGroups.add(entry);
    }
    if (clearWorking) additionalCosts.clear();
  }

  void _loadAdditionalCostsGroupsFromRow(CateringEventRecord row) {
    _additionalCostsGroups.clear();
    final saved = row.postAnalysis['additional_costs_groups'];
    if (saved is List) {
      for (final e in saved) {
        if (e is! Map) continue;
        final items = <Map<String, dynamic>>[];
        final rawItems = e['items'];
        if (rawItems is List) {
          for (final it in rawItems) {
            if (it is Map) items.add(Map<String, dynamic>.from(it));
          }
        }
        if (items.isEmpty) continue;
        _additionalCostsGroups.add({
          'stage': '${e['stage'] ?? ''}'.trim(),
          'items': items,
          'total': jsonToDouble(e['total']) > 0 ? jsonToDouble(e['total']) : _sumCostRows(items),
          'processed_at': '${e['processed_at'] ?? ''}'.trim(),
        });
      }
    } else if (row.additionalCosts.isNotEmpty) {
      final items = <Map<String, dynamic>>[];
      for (final c in row.additionalCosts) {
        if (c is Map) items.add(Map<String, dynamic>.from(c));
      }
      if (items.isNotEmpty) {
        final legacyStage = row.source.trim().toLowerCase().contains('online')
            ? 'Online Inquiries'
            : 'New Event';
        _additionalCostsGroups.add({
          'stage': legacyStage,
          'items': items,
          'total': _sumCostRows(items),
          'processed_at': (row.stageEnteredAt ?? row.updatedAt).toIso8601String(),
        });
      }
    }
    additionalCosts.clear();
    final stageLabel = cateringManagerDetailTabTitle(row, widget.stage, processingSubstageOverride: widget.processingSubstage);
    for (final g in _additionalCostsGroups) {
      if ('${g['stage'] ?? ''}'.trim() != stageLabel) continue;
      final items = g['items'];
      if (items is List) {
        for (final it in items) {
          if (it is Map) additionalCosts.add(Map<String, dynamic>.from(it));
        }
      }
      break;
    }
    if (!_isManagerDraftDetailStage && additionalCosts.isNotEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        _maybeAutoGenerateAdditionalCostsSheetPdf();
      });
    }
  }

  void _onAdditionalCostsWorkingListChanged({bool post = false}) {
    if (post) _maybeGeneratePostAnalysisPdf2IfNeeded();
    if (!_isManagerDraftDetailStage) {
      _maybeAutoGenerateAdditionalCostsSheetPdf();
    }
  }

  List<Map<String, dynamic>> _additionalCostsGroupsForPostAnalysis() =>
      _additionalCostsGroups.map((g) => Map<String, dynamic>.from(g)).toList();

  Widget? _paymentProofSuffixIcon(
    BuildContext context, {
    Uint8List? localBytes,
    required String proofB64Key,
    required String title,
  }) {
    Uint8List? bytes = localBytes;
    if (bytes == null) {
      final b = '${d.postAnalysis[proofB64Key] ?? ''}'.trim();
      if (b.isEmpty) return null;
      try {
        bytes = Uint8List.fromList(base64Decode(b));
      } catch (_) {
        return null;
      }
    }
    final proofBytes = bytes!;
    return IconButton(
      tooltip: 'View $title',
      icon: const Icon(Icons.image_outlined),
      onPressed: () => showProofFullScreen(context, proofBytes, title: title),
    );
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
  }

  Future<void> _pickWindowFromTime(int idx) async {
    if (idx < 0 || idx >= _eventWindows.length) return;
    final initial = _eventWindows[idx].from ?? const TimeOfDay(hour: 9, minute: 0);
    final picked = await showTimePicker(context: context, initialTime: initial);
    if (picked == null) return;
    setState(() {
      _eventWindows[idx].from = picked;
    });
  }

  Future<void> _pickWindowToTime(int idx) async {
    if (idx < 0 || idx >= _eventWindows.length) return;
    final initial = _eventWindows[idx].to ?? const TimeOfDay(hour: 10, minute: 0);
    final picked = await showTimePicker(context: context, initialTime: initial);
    if (picked == null) return;
    setState(() {
      _eventWindows[idx].to = picked;
    });
  }

  void _addAnotherWindow() {
    setState(() {
      _eventWindows.add(_InquiryEventWindow());
    });
  }

  void _removeWindowAt(int idx) {
    setState(() {
      if (_eventWindows.length <= 1) {
        _eventWindows[0] = _InquiryEventWindow();
      } else {
        _eventWindows.removeAt(idx);
      }
    });
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

  bool get _includesThemeDesignInTotals => d.orderKind == 'event';

  double _themeDesignCostAmount() =>
      _includesThemeDesignInTotals ? _sumCostRows(themeDesignCosts) : 0;

  double _grandTotalComputed() =>
      _baseFoodCost() +
      _laborCostComputed() +
      _travelCostComputed() +
      _sumCostRows(_flattenAdditionalCostsFromGroups()) +
      _themeDesignCostAmount();

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
    _ManagerOrderSummaryPdfVariant variant = _ManagerOrderSummaryPdfVariant.beforeDownPayment,
  }) async {
    final doc = pw.Document();
    final labelBg = pdf.PdfColor.fromInt(0xFFCFCFCF);
    final themeCost = _themeDesignCostAmount();
    final additionalCostTotal = _sumCostRows(additionalCostsForPdf);
    final processingAt = formatDateTimeLocal(d.stageEnteredAt ?? d.updatedAt);
    final eventWhen = _eventDateTimeJoinedFromRowScheduleSlots(d.scheduleSlots);

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
      final addlPaid = d.postAnalysis['additional_costs_payment_confirmed'] == true;
      final addRows = <pw.Widget>[];
      final groups = _additionalCostsGroupsForAdditionalCostsSheetPdf();
      for (final group in groups) {
        final items = (group['items'] is List)
            ? (group['items'] as List).whereType<Map>().map((e) => Map<String, dynamic>.from(e)).toList()
            : <Map<String, dynamic>>[];
        if (items.isEmpty) continue;
        final stage = '${group['stage'] ?? 'Additional costs'}'.trim();
        final groupTotal = jsonToDouble(group['total']) > 0 ? jsonToDouble(group['total']) : _sumCostRows(items);
        final processedRaw = '${group['processed_at'] ?? ''}'.trim();
        final processedAt = processedRaw.isEmpty
            ? '—'
            : (DateTime.tryParse(processedRaw) != null ? formatDateTimeLocal(DateTime.parse(processedRaw)) : processedRaw);
        addRows.add(
          labelValueRow(
            'Additional costs ($stage)',
            items.map((e) => '${e['label'] ?? ''}'.trim()).where((x) => x.isNotEmpty).join(' · '),
          ),
        );
        addRows.add(labelValueRow('Additional costs (total)', 'PHP ${groupTotal.toStringAsFixed(2)}'));
        addRows.add(labelValueRow('Date/Time processed', processedAt));
        addRows.add(pw.SizedBox(height: 6));
      }
      if (addRows.isEmpty && additionalCosts.isNotEmpty) {
        final currentLabel = _additionalCostsStageLabel();
        final stage = currentLabel.isEmpty ? 'Additional costs' : currentLabel;
        addRows.add(
          labelValueRow(
            'Additional costs ($stage)',
            additionalCosts.map((e) => '${e['label'] ?? ''}'.trim()).where((x) => x.isNotEmpty).join(' · '),
          ),
        );
        addRows.add(
          labelValueRow('Additional costs (total)', 'PHP ${_sumCostRows(additionalCosts).toStringAsFixed(2)}'),
        );
        addRows.add(labelValueRow('Date/Time processed', processingAt));
        addRows.add(pw.SizedBox(height: 6));
      } else if (addRows.isEmpty) {
        addRows.add(labelValueRow('Additional costs', '—'));
      }
      final sheetAdditionalTotal = _additionalCostsSheetPdfTotal();
      addRows.add(
        labelValueRow(
          'Total Cost',
          'PHP ${sheetAdditionalTotal.toStringAsFixed(2)}',
        ),
      );
      doc.addPage(
        pw.MultiPage(
          build: (ctx) => [
            pw.Text(
              'Order Summary | Additional Costs',
              style: pw.TextStyle(fontSize: 18, fontWeight: pw.FontWeight.bold),
            ),
            pw.Text('Macrina\'s Kitchen and Catering', style: pw.TextStyle(fontSize: 10, color: pdf.PdfColors.grey700)),
            pw.SizedBox(height: 12),
            pw.Text('Event information', style: pw.TextStyle(fontSize: 12, fontWeight: pw.FontWeight.bold)),
            pw.SizedBox(height: 6),
            labelValueRow('Transaction No.', d.transactionNo.isEmpty ? '—' : d.transactionNo),
            labelValueRow('Event', d.eventTitle.isEmpty ? d.customerName : d.eventTitle),
            labelValueRow('Customer', d.customerName),
            labelValueRow('Contact person', d.contactPerson),
            labelValueRow('Contact number', d.contactNumber.trim().isEmpty ? '—' : d.contactNumber.trim()),
            labelValueRow('Email address', d.emailAddress.trim().isEmpty ? '—' : d.emailAddress.trim()),
            labelValueRow('Address', d.address),
            ...addRows,
            if (addlPaid) ...[
              pw.SizedBox(height: 10),
              pw.Text(
                'PAID',
                style: pw.TextStyle(
                  fontSize: 14,
                  fontWeight: pw.FontWeight.bold,
                  color: pdf.PdfColors.green,
                ),
              ),
            ],
          ],
        ),
      );
      return doc.save();
    }

    final laborLine = _laborCostComputed();
    final travelLine = _travelCostComputed();
    final totalComputed = _baseFoodCost() + laborLine + travelLine + themeCost + additionalCostTotal;
    final guestEntered = _guestCountEntered(d);
    final paxBufferCount = _paxBufferCount(d);
    final guestPaxAmount = _guestPaxCostAmount(d);
    final paxBufferAmount = _paxBufferCostAmount(d);
    final downPaymentDue = totalComputed * 0.5;
    final totalDueNow = totalComputed - downPaymentDue;
    final downPaidStored = d.downPaymentAmount > 0 ? d.downPaymentAmount : (double.tryParse(downPaymentPaidController.text.trim()) ?? 0);
    final downPaidLine = downPaidStored > 0 ? downPaidStored : downPaymentDue;
    final balanceStillDue = (totalComputed - downPaidLine).clamp(0.0, double.infinity);
    final balancePaidLine = d.fullPaymentAmount > 0 ? d.fullPaymentAmount : balanceStillDue;
    final menuLines = _menuDishNamesFromRowMenu();
    final cateringType = d.orderKind == 'catering' ? 'Catering' : 'Catering and Event';

    String pdfTitle() {
      switch (variant) {
        case _ManagerOrderSummaryPdfVariant.beforeDownPayment:
          return 'Order Summary before Down Payment';
        case _ManagerOrderSummaryPdfVariant.afterDownPayment:
          return 'Order Summary after Down Payment';
        case _ManagerOrderSummaryPdfVariant.additionalCostsSheet:
          return 'Order Summary | Additional Costs';
        case _ManagerOrderSummaryPdfVariant.fullyPaid:
          return 'Order Summary Fully Paid';
      }
    }

    final tailRows = <pw.Widget>[];
    switch (variant) {
      case _ManagerOrderSummaryPdfVariant.beforeDownPayment:
        tailRows.addAll([
          labelValueRow('Total Cost', 'PHP ${totalComputed.toStringAsFixed(2)}'),
          labelValueRow('Down payment due (50%)', 'PHP ${downPaymentDue.toStringAsFixed(2)}'),
        ]);
        break;
      case _ManagerOrderSummaryPdfVariant.afterDownPayment:
        tailRows.addAll([
          labelValueRow('Total Cost', 'PHP ${totalComputed.toStringAsFixed(2)}'),
          labelValueRow('Down payment paid', 'PHP ${downPaidLine.toStringAsFixed(2)}'),
          labelValueRow('Total amount due', 'PHP ${balanceStillDue.toStringAsFixed(2)}'),
        ]);
        break;
      case _ManagerOrderSummaryPdfVariant.additionalCostsSheet:
        tailRows.addAll([
          labelValueRow('Total Cost', 'PHP ${totalComputed.toStringAsFixed(2)}'),
          labelValueRow('Down payment paid', 'PHP ${downPaidLine.toStringAsFixed(2)}'),
          labelValueRow('Total amount due', 'PHP ${totalDueNow.toStringAsFixed(2)}'),
        ]);
        break;
      case _ManagerOrderSummaryPdfVariant.fullyPaid:
        tailRows.addAll([
          labelValueRow('Total Cost', 'PHP ${totalComputed.toStringAsFixed(2)}'),
          labelValueRow('Down payment paid', 'PHP ${downPaidLine.toStringAsFixed(2)}'),
          labelValueRow('Balance amount paid', 'PHP ${balancePaidLine.toStringAsFixed(2)}'),
        ]);
        break;
    }

    doc.addPage(
      pw.MultiPage(
        build: (ctx) => [
          pw.Text(pdfTitle(), style: pw.TextStyle(fontSize: 18, fontWeight: pw.FontWeight.bold)),
          pw.Text('Macrina\'s Kitchen and Catering', style: pw.TextStyle(fontSize: 10, color: pdf.PdfColors.grey700)),
          pw.SizedBox(height: 12),
          labelValueRow('Transaction No.', d.transactionNo.isEmpty ? '—' : d.transactionNo),
          labelValueRow('Date/Time processed', processingAt),
          labelValueRow('Event', d.eventTitle.isEmpty ? d.customerName : d.eventTitle),
          labelValueRow('Date/Time of Event', eventWhen.isEmpty ? '—' : eventWhen),
          labelValueRow('Customer', d.customerName),
          labelValueRow('Contact person', d.contactPerson),
          labelValueRow('Contact number', d.contactNumber.trim().isEmpty ? '—' : d.contactNumber.trim()),
          labelValueRow('Email address', d.emailAddress.trim().isEmpty ? '—' : d.emailAddress.trim()),
          labelValueRow('Catering type', cateringType),
          labelValueRow('Address of event', d.address),
          labelValueRow('Menu dishes', menuLines.isEmpty ? '—' : menuLines.join(', ')),
          labelValueRow(
            'No. of PAX and cost',
            '$guestEntered x PHP ${kPesosPerPax.toStringAsFixed(0)} | PHP ${guestPaxAmount.toStringAsFixed(2)}',
          ),
          if (paxBufferCount > 0)
            labelValueRow(
              'PAX Buffer and cost',
              '$paxBufferCount x PHP ${kPesosPerPax.toStringAsFixed(0)} | PHP ${paxBufferAmount.toStringAsFixed(2)}',
            ),
          if (_includesThemeDesignInTotals)
            labelValueRow('Event theme design cost', 'PHP ${themeCost.toStringAsFixed(2)}'),
          if (variant != _ManagerOrderSummaryPdfVariant.beforeDownPayment && additionalCostTotal > 0.01) ...[
            labelValueRow('Additional costs', additionalCostsSummaryForPdf(additionalCostsForPdf)),
            labelValueRow('Additional costs (total)', 'PHP ${additionalCostTotal.toStringAsFixed(2)}'),
          ],
          labelValueRow('Labor cost', 'PHP ${laborLine.toStringAsFixed(2)}'),
          labelValueRow('Travel cost', 'PHP ${travelLine.toStringAsFixed(2)}'),
          ...tailRows,
          if (variant == _ManagerOrderSummaryPdfVariant.fullyPaid)
            pw.Padding(
              padding: const pw.EdgeInsets.only(top: 10),
              child: pw.Text(
                'PAID',
                style: pw.TextStyle(
                  fontSize: 14,
                  fontWeight: pw.FontWeight.bold,
                  color: pdf.PdfColors.green,
                ),
              ),
            ),
        ],
      ),
    );

    return doc.save();
  }

  Future<void> _openOrderSummaryPdfBytes(Uint8List bytes) async {
    await Printing.layoutPdf(onLayout: (_) async => bytes);
  }

  Future<void> _previewManagerOrderSummary(
    _ManagerOrderSummaryPdfVariant variant, {
    bool postAnalysis2Only = false,
  }) async {
    try {
      final List<Map<String, dynamic>> pdfCosts;
      if (variant == _ManagerOrderSummaryPdfVariant.beforeDownPayment) {
        pdfCosts = [];
      } else if (postAnalysis2Only) {
        pdfCosts = _sheetAdditionalCostsForOrderSummaryPdf();
      } else {
        pdfCosts = _allAdditionalCostsForMainOrderSummaryPdf();
      }
      final bytes = await _buildOrderSummaryPdfBytes(
        additionalCostsForPdf: pdfCosts,
        postAnalysis2Only: postAnalysis2Only,
        variant: variant,
      );
      await _openOrderSummaryPdfBytes(bytes);
    } catch (e) {
      if (mounted) appSnack(context, 'Could not build PDF: $e');
    }
  }

  Future<void> _sendOrderSummaryPdfToCustomer() async {
    final r = _loadedDetailRow ?? widget.row;
    final isProcessing = widget.stage == 'for_processing';
    final sub = _processingSubstageForUi.trim().toLowerCase();
    final isOngoingSubstage = isProcessing && sub == 'ongoing';
    final isDownPaymentSubstage = isProcessing && sub == 'down_payment';
    final isPost = widget.stage == 'for_post_analysis';
    final isCompleted = widget.stage == 'completed';
    final isDraftStage = widget.stage == 'new_event' || widget.stage == 'online_inquiries';
    final isOnlineInquiry = widget.stage == 'online_inquiries';
    final totalComputed = _grandTotalComputed();
    final isFullPaymentConfirmed = cateringFullPaymentConfirmed(r, totalComputed);
    final pdfVariant = isCompleted || isFullPaymentConfirmed
        ? _ManagerOrderSummaryPdfVariant.fullyPaid
        : (isOngoingSubstage || isPost)
            ? _ManagerOrderSummaryPdfVariant.afterDownPayment
            : (isDownPaymentSubstage || isDraftStage || isOnlineInquiry)
                ? _ManagerOrderSummaryPdfVariant.beforeDownPayment
                : _ManagerOrderSummaryPdfVariant.afterDownPayment;
    final bytes = await _buildOrderSummaryPdfBytes(
      additionalCostsForPdf:
          pdfVariant == _ManagerOrderSummaryPdfVariant.beforeDownPayment ? [] : additionalCosts,
      variant: pdfVariant,
    );
    final to = r.emailAddress.trim().toLowerCase();
    if (!to.contains('@')) {
      appSnack(context, 'Customer email is missing or invalid.');
      return;
    }
    final b64 = base64Encode(bytes);
    final err = await widget.state.managerSendOrderSummaryEmail(
      orderKind: r.orderKind,
      id: r.id,
      customerEmail: to,
      pdfBase64: b64,
    );
    if (!mounted) return;
    if (err != null) {
      appSnack(context, err);
    } else {
      appSnack(context, 'Order summary emailed to $to');
    }
  }

  Future<void> _capturePostAnalysisPdf1IfNeeded() async {
    if (widget.stage != 'for_post_analysis') return;
    if (_postAnalysisPdf1Bytes != null) return;

    final snapshot = additionalCosts.map((e) => Map<String, dynamic>.from(e)).toList();
    final sig = _additionalCostsSignature(snapshot);
    final bytes = await _buildOrderSummaryPdfBytes(
      additionalCostsForPdf: snapshot,
      variant: _ManagerOrderSummaryPdfVariant.afterDownPayment,
    );
    if (!mounted) return;
    setState(() {
      _orderSummaryPdf1AdditionalCosts
        ..clear()
        ..addAll(snapshot.map((e) => Map<String, dynamic>.from(e)));
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
        ? _baseFoodCost() + _themeDesignCostAmount() + _sumCostRows(additionalCosts)
        : _grandTotalComputed();
    downPaymentController.text = (total * 0.5).toStringAsFixed(2);
    if (fullPaymentController.text.trim().isEmpty || jsonToDouble(fullPaymentController.text) <= 0) {
      fullPaymentController.text = total.toStringAsFixed(2);
    }
  }

  void _maybeCopyContactToCustomerForCheckbox() {
    if (!_managerCustomerSameAsContact) return;
    managerCustomerNameController.text = managerContactPersonController.text;
  }

  @override
  void initState() {
    super.initState();
    managerContactPersonController.addListener(_maybeCopyContactToCustomerForCheckbox);
    managerAddressController.addListener(_onManagerVenueChanged);
    for (final c in [
      managerDraftEventTitleController,
      managerCustomerNameController,
      managerContactPersonController,
      managerContactNumberController,
      managerEmailController,
      managerAddressController,
      managerEventTypeOtherController,
      managerGuestCountController,
      managerInquiryNoteController,
    ]) {
      c.addListener(() {
        if (mounted) setState(() {});
      });
    }
    Future.microtask(() async {
      await widget.state.loadAllergenCatalog();
      if (!mounted) return;
      await _bootstrapDetail();
    });
  }

  void _onManagerVenueChanged() {
    _managerVenueDebounce?.cancel();
    final q = managerAddressController.text.trim();
    if (q.length < 3) {
      if (_managerVenueSuggestions.isNotEmpty && mounted) {
        setState(() => _managerVenueSuggestions.clear());
      }
      return;
    }
    _managerVenueDebounce = Timer(const Duration(milliseconds: 300), () async {
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
        if (mounted) {
          setState(() {
            _managerVenueSuggestions
              ..clear()
              ..addAll(next);
          });
        }
      } catch (_) {}
    });
  }

  Future<void> _pickManagerVenueOnMap() async {
    final res = await Navigator.of(context).push<MapPinResult>(
      MaterialPageRoute(
        builder: (_) => _MapPinPickerDialog(initialSearchQuery: managerAddressController.text.trim()),
      ),
    );
    if (res == null || !mounted) return;
    setState(() {
      managerAddressController.text = res.address.trim();
      _managerVenueSuggestions.clear();
    });
  }

  String get _localDraftKey => '$_managerDraftDetailKeyPrefix${widget.row.id}_${widget.stage}';

  Future<void> _bootstrapDetail() async {
    final full = await widget.state.loadManagerCateringItem(
      id: widget.row.id,
      orderKind: widget.row.orderKind,
    );
    if (!mounted) return;
    _loadedDetailRow = full ?? widget.row;
    _initControllersFromRow(_loadedDetailRow!);
    setState(() => _detailReady = true);
  }

  void _initControllersFromRow(CateringEventRecord row) {
    additionalCosts.clear();
    themeDesignCosts.clear();
    laborManualCosts.clear();
    selectedDishes.clear();
    checklistRows.clear();
    taskRows.clear();
    _postAnalysisPdf1Bytes = null;
    _postAnalysisPdf2Bytes = null;
    _postAnalysisPdf1Signature = '';
    _postAnalysisPdf2Signature = '';
    _postAnalysisPdfGenerating = false;
    _orderSummaryPdf1AdditionalCosts.clear();

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
    managerCustomerNameController.text = row.customerName.trim();
    managerContactPersonController.text = row.contactPerson.trim();
    managerContactNumberController.text = row.contactNumber.trim();
    managerEmailController.text = row.emailAddress.trim();
    managerAddressController.text = row.address.trim();
    _managerCustomerSameAsContact = false;
    managerGuestCountController.text = '${row.guestCount <= 0 ? '' : row.guestCount}';
    managerPaxBufferController.text = '${_paxBufferCount(row) <= 0 ? '' : _paxBufferCount(row)}';
    managerInquiryNoteController.text = '${tdInit['note'] ?? ''}';
    managerEventSetting = '${tdInit['event_setting'] ?? 'open'}'.trim().isEmpty ? 'open' : tdInit['event_setting'].toString().trim();
    managerGuestAllergens.clear();
    final gaRaw = tdInit['guest_allergens'] ?? row.postAnalysis['guest_allergens'];
    if (gaRaw is List) {
      for (final e in gaRaw) {
        final s = '$e'.trim();
        if (s.isNotEmpty) managerGuestAllergens.add(s);
      }
    }
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
    laborMaleController.text = '${row.postAnalysis['labor_male_count'] ?? 0}';
    laborFemaleController.text = '${row.postAnalysis['labor_female_count'] ?? 0}';
    laborManualCosts
      ..clear()
      ..addAll(_laborManualCostsFromRow(row));
    _loadAdditionalCostsGroupsFromRow(row);
    _applyDraftLaborTravelFromRow(row);
    final pdf1Saved = row.postAnalysis['order_summary_pdf1_additional_costs'];
    if (pdf1Saved is List) {
      for (final e in pdf1Saved) {
        if (e is Map) {
          _orderSummaryPdf1AdditionalCosts.add({
            'label': '${e['label'] ?? ''}',
            'amount': jsonToDouble(e['amount']),
          });
        }
      }
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
    _managerAdditionalCostsProofBytes = null;
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
    final acpb = row.postAnalysis['manager_additional_costs_proof_b64'];
    if (acpb is String && acpb.trim().isNotEmpty) {
      try {
        _managerAdditionalCostsProofBytes = Uint8List.fromList(base64Decode(acpb.trim()));
      } catch (_) {}
    }
    String normPm(String raw) {
      final t = raw.trim();
      if (kManagerPaymentMethods.contains(t)) return t;
      return 'Cash';
    }

    _managerDownPaymentMethod = normPm('${row.postAnalysis['manager_down_payment_method'] ?? 'Cash'}');
    _managerFullPaymentMethod = normPm('${row.postAnalysis['manager_full_payment_method'] ?? 'Cash'}');
    additionalCostsPaidController.text =
        _compiledPostDraftAdditionalCostsTotal(includeWorkingPostStage: true).toStringAsFixed(2);
    if (widget.stage == 'for_post_analysis') {
      WidgetsBinding.instance.addPostFrameCallback((_) async {
        if (!mounted) return;
        await _capturePostAnalysisPdf1IfNeeded();
      });
    }
    _refreshDueAndDefaults();
    _pristineManagerDetailSig = _computeManagerDetailSignature();
    _managerDraftAdvanceGateSig = '';
  }

  String _computeManagerDetailSignature() {
    final slotPayload = _scheduleSlotsPayload();
    final dishList = selectedDishes.toList();
    dishList.sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
    final imgList = List<String>.from(actualEventImages);
    imgList.sort();
    return jsonEncode({
      'analysis': analysisController.text,
      'task_assignment': taskAssignmentController.text,
      'task_rows': taskRows,
      'checklist': checklistRows,
      'business_cards': businessCardsController.text,
      'spot': spotInquiriesController.text,
      'complaints': complaintsController.text,
      'popular_dish': popularDishController.text,
      'popular_drink': popularDrinkController.text,
      'popular_dessert': popularDessertController.text,
      'labor_male': laborMaleController.text,
      'labor_female': laborFemaleController.text,
      'labor_manual': laborManualCosts.map((e) => Map<String, dynamic>.from(e)).toList(),
      'travel': travelCostController.text,
      'additional': _additionalCostsSignature(additionalCosts),
      'theme': _additionalCostsSignature(themeDesignCosts),
      'dishes': dishList,
      'down_due': downPaymentController.text,
      'down_paid': downPaymentPaidController.text,
      'full_paid': fullPaymentController.text,
      'service_included': managerServiceIncluded,
      'formality': managerFormalityLevel,
      'event_setting': managerEventSetting,
      'event_type_choice': managerEventTypeChoice,
      'event_type_other': managerEventTypeOtherController.text,
      'draft_title': managerDraftEventTitleController.text,
      'customer_name': managerCustomerNameController.text,
      'contact_person': managerContactPersonController.text,
      'contact_number': managerContactNumberController.text,
      'email': managerEmailController.text,
      'address': managerAddressController.text,
      'guests': managerGuestCountController.text,
      'inquiry_note': managerInquiryNoteController.text,
      'draft_kind': _draftOrderKind,
      'schedule_slots': slotPayload,
      'down_pm': _managerDownPaymentMethod,
      'full_pm': _managerFullPaymentMethod,
      'proof_dp': _managerDownPaymentProofBytes?.length ?? 0,
      'proof_fp': _managerFullPaymentProofBytes?.length ?? 0,
      'proof_ac': _managerAdditionalCostsProofBytes?.length ?? 0,
      'actual_images': imgList,
      'guest_allergens': (managerGuestAllergens.toList()..sort()),
    });
  }

  bool _managerDetailHasUnsavedEdits() =>
      _pristineManagerDetailSig.isNotEmpty && _pristineManagerDetailSig != _computeManagerDetailSignature();

  void _showManagerBlockingProgress(String message) {
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      useRootNavigator: true,
      builder: (dlgCtx) => PopScope(
        canPop: false,
        child: AlertDialog(
          content: Row(
            children: [
              const SizedBox(width: 4, height: 4),
              const CircularProgressIndicator(),
              const SizedBox(width: 18),
              Expanded(child: Text(message)),
            ],
          ),
        ),
      ),
    );
  }

  void _hideManagerBlockingProgress() {
    final nav = Navigator.of(context, rootNavigator: true);
    if (nav.canPop()) nav.pop();
  }

  Future<void> _reloadManagerDetailDiscardUnsaved() async {
    final id = d.id;
    final kind = d.orderKind;
    final full = await widget.state.loadManagerCateringItem(id: id, orderKind: kind);
    if (!mounted) return;
    _loadedDetailRow = full ?? widget.row;
    _initControllersFromRow(_loadedDetailRow!);
    setState(() {});
  }

  @override
  void dispose() {
    _managerVenueDebounce?.cancel();
    managerAddressController.removeListener(_onManagerVenueChanged);
    managerContactPersonController.removeListener(_maybeCopyContactToCustomerForCheckbox);
    downPaymentController.dispose();
    downPaymentPaidController.dispose();
    fullPaymentController.dispose();
    additionalCostsPaidController.dispose();
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
    managerCustomerNameController.dispose();
    managerContactPersonController.dispose();
    managerContactNumberController.dispose();
    managerEmailController.dispose();
    managerAddressController.dispose();
    managerGuestCountController.dispose();
    managerPaxBufferController.dispose();
    managerInquiryNoteController.dispose();
    super.dispose();
  }

  Widget _laborTravelPlainTextSection(CateringEventRecord row) {
    final male = int.tryParse(laborMaleController.text.trim()) ?? 0;
    final female = int.tryParse(laborFemaleController.text.trim()) ?? 0;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Labor cost: ₱${_laborCostComputed().toStringAsFixed(2)}', style: const TextStyle(fontWeight: FontWeight.w600)),
        if (male > 0) Text('Male workers: $male'),
        if (female > 0) Text('Female workers: $female'),
        ...laborManualCosts.map((e) {
          final label = '${e['label'] ?? ''}'.trim();
          return Text(
            '${label.isEmpty ? 'Labor item' : label}: ₱${jsonToDouble(e['amount']).toStringAsFixed(2)}',
          );
        }),
        const SizedBox(height: 4),
        Text('Travel cost: ₱${_travelCostComputed().toStringAsFixed(2)}', style: const TextStyle(fontWeight: FontWeight.w600)),
      ],
    );
  }

  Widget _laborCostCard({required bool allowLaborEdits, required bool showTravelReadOnly}) {
    return Card(
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
                    readOnly: !allowLaborEdits,
                    decoration: const InputDecoration(labelText: 'Male workers (₱1000 each)'),
                    onChanged: (_) => setState(_refreshDueAndDefaults),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: TextField(
                    controller: laborFemaleController,
                    keyboardType: TextInputType.number,
                    readOnly: !allowLaborEdits,
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
                    readOnly: !allowLaborEdits,
                    decoration: const InputDecoration(labelText: 'Labor item'),
                  ),
                ),
                const SizedBox(width: 8),
                SizedBox(
                  width: 110,
                  child: TextField(
                    controller: laborManualAmountController,
                    keyboardType: TextInputType.number,
                    readOnly: !allowLaborEdits,
                    decoration: const InputDecoration(labelText: 'Amount'),
                  ),
                ),
                IconButton(
                  onPressed: !allowLaborEdits
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
              final label = '${e['label'] ?? ''}'.trim();
              return ListTile(
                dense: true,
                title: Text(label.isEmpty ? 'Labor item' : label),
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text('₱${jsonToDouble(e['amount']).toStringAsFixed(2)}'),
                    IconButton(
                      onPressed: !allowLaborEdits
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
            Text('Computed labor cost: ₱${_laborCostComputed().toStringAsFixed(2)}'),
            if (showTravelReadOnly) ...[
              const SizedBox(height: 8),
              Text(
                'Travel cost: ₱${_travelCostComputed().toStringAsFixed(2)}',
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _additionalCostsCard({
    required bool draft,
    required bool processing,
    required bool post,
    required CateringEventRecord row,
  }) {
    final allowEdits = draft || processing || post;
    final previousItems = draft ? <Map<String, dynamic>>[] : _previousAdditionalCostsItems(row);
    final previousLabel = _previousAdditionalCostsStageLabel(row);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text('Additional costs', style: TextStyle(fontWeight: FontWeight.w800)),
            if (!draft && previousItems.isNotEmpty) ...[
                const SizedBox(height: 8),
                Text(
                  'From ${previousLabel ?? 'previous stage'}',
                  style: TextStyle(fontWeight: FontWeight.w700, color: Colors.grey.shade800),
                ),
                ...previousItems.map(
                  (e) => ListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    title: Text('${e['label'] ?? ''}'.trim().isEmpty ? 'Additional cost' : '${e['label']}'),
                    trailing: Text('₱${jsonToDouble(e['amount']).toStringAsFixed(2)}'),
                  ),
                ),
                const Divider(height: 20),
            ],
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: additionalCostLabelController,
                    readOnly: !allowEdits,
                    decoration: const InputDecoration(labelText: 'Label'),
                  ),
                ),
                const SizedBox(width: 8),
                SizedBox(
                  width: 110,
                  child: TextField(
                    controller: additionalCostAmountController,
                    keyboardType: TextInputType.number,
                    readOnly: !allowEdits,
                    decoration: const InputDecoration(labelText: 'Amount'),
                  ),
                ),
                IconButton(
                  onPressed: !allowEdits
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
                          _onAdditionalCostsWorkingListChanged(post: post);
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
                        tooltip: 'Edit',
                        onPressed: !allowEdits
                            ? null
                            : () async {
                                final updated = await promptAdditionalCostLineItem(
                                  context,
                                  initialLabel: '${e['label'] ?? ''}'.trim(),
                                  initialAmount: jsonToDouble(e['amount']),
                                );
                                if (updated == null || !mounted) return;
                                setState(() {
                                  additionalCosts[idx] = updated;
                                  _refreshDueAndDefaults();
                                });
                                _onAdditionalCostsWorkingListChanged(post: post);
                              },
                        icon: const Icon(Icons.edit_outlined),
                      ),
                      IconButton(
                        tooltip: 'Delete',
                        onPressed: !allowEdits
                            ? null
                            : () {
                                setState(() {
                                  additionalCosts.removeAt(idx);
                                  _refreshDueAndDefaults();
                                });
                                _onAdditionalCostsWorkingListChanged(post: post);
                              },
                        icon: const Icon(Icons.delete_outline),
                      ),
                    ],
                  ),
                );
              },
            ),
            if (post && _compiledPostDraftAdditionalCostsTotal(includeWorkingPostStage: true) > 0.01) ...[
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
                    const SizedBox(height: 6),
                    Text(
                      'One combined payment for all additional costs entered in For Down Payment, On Going, and For Full Payment.',
                      style: TextStyle(fontSize: 12, height: 1.35, color: Colors.red.shade900),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      'Amount due: PHP ${_compiledPostDraftAdditionalCostsTotal(includeWorkingPostStage: true).toStringAsFixed(2)}',
                      style: TextStyle(fontWeight: FontWeight.w700, color: Colors.red.shade900),
                    ),
                    const SizedBox(height: 8),
                    TextField(
                      controller: additionalCostsPaidController,
                      keyboardType: TextInputType.number,
                      readOnly: !widget.state.isManager ||
                          (d.postAnalysis['additional_costs_payment_confirmed'] == true),
                      decoration: const InputDecoration(
                        labelText: 'Additional costs paid',
                        prefixText: 'PHP ',
                      ),
                    ),
                    const SizedBox(height: 8),
                    const Text('Proof of additional costs payment', style: TextStyle(fontWeight: FontWeight.w700)),
                    const SizedBox(height: 6),
                    Row(
                      children: [
                        Expanded(
                          child: OutlinedButton.icon(
                            onPressed: !widget.state.isManager ||
                                    (d.postAnalysis['additional_costs_payment_confirmed'] == true)
                                ? null
                                : () async {
                                    final x = await ImagePicker().pickImage(source: ImageSource.gallery);
                                    if (x == null || !mounted) return;
                                    final b = await x.readAsBytes();
                                    setState(() => _managerAdditionalCostsProofBytes = b);
                                  },
                            icon: const Icon(Icons.upload_file, size: 18),
                            label: const Text('Upload'),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: OutlinedButton.icon(
                            onPressed: !widget.state.isManager ||
                                    (d.postAnalysis['additional_costs_payment_confirmed'] == true)
                                ? null
                                : () async {
                                    final x = await ImagePicker().pickImage(source: ImageSource.camera);
                                    if (x == null || !mounted) return;
                                    final b = await x.readAsBytes();
                                    setState(() => _managerAdditionalCostsProofBytes = b);
                                  },
                            icon: const Icon(Icons.photo_camera_outlined, size: 18),
                            label: const Text('Camera'),
                          ),
                        ),
                      ],
                    ),
                    if (_managerAdditionalCostsProofBytes != null) ...[
                      const SizedBox(height: 8),
                      InkWell(
                        onTap: () => showProofFullScreen(
                          context,
                          _managerAdditionalCostsProofBytes!,
                          title: 'Additional costs proof',
                        ),
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(8),
                          child: Image.memory(_managerAdditionalCostsProofBytes!, height: 120, fit: BoxFit.contain),
                        ),
                      ),
                    ],
                    const SizedBox(height: 8),
                    FilledButton(
                      style: FilledButton.styleFrom(backgroundColor: Colors.red.shade800),
                      onPressed: !widget.state.isManager ||
                              (d.postAnalysis['additional_costs_payment_confirmed'] == true) ||
                              _managerAdditionalCostsProofBytes == null
                          ? null
                          : () async {
                              _snapshotAdditionalCostsForCurrentStage(clearWorking: false, refreshTimestamp: true);
                              final addlDue =
                                  _compiledPostDraftAdditionalCostsTotal(includeWorkingPostStage: true);
                              final addlPaid =
                                  double.tryParse(additionalCostsPaidController.text.trim()) ?? addlDue;
                              if (!await confirmManagerPaymentAmountMismatch(
                                context,
                                paymentLabel: 'Additional costs payment',
                                amountEntered: addlPaid,
                                amountDue: addlDue,
                              )) {
                                return;
                              }
                              final ok = await showDialog<bool>(
                                context: context,
                                builder: (dlgCtx) => AlertDialog(
                                  title: const Text('Confirm additional costs payment'),
                                  content: Text(
                                    'Confirm payment of PHP ${addlPaid.toStringAsFixed(2)} for all compiled additional costs (due: PHP ${addlDue.toStringAsFixed(2)})?',
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
                                patch: {
                                  'additional_costs_payment_confirmed': true,
                                  'manager_additional_costs_proof_b64':
                                      base64Encode(_managerAdditionalCostsProofBytes!),
                                  'additional_costs_groups': _additionalCostsGroupsForPostAnalysis(),
                                },
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
                        d.postAnalysis['additional_costs_payment_confirmed'] == true ? 'PAID' : 'Confirm payment',
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (!_detailReady) {
      return Scaffold(
        backgroundColor: Theme.of(context).scaffoldBackgroundColor,
        appBar: AppBar(
          backgroundColor: const Color(0xFF242424),
          foregroundColor: const Color(0xFFFFC024),
          leading: _buildManagerHamburgerLeading(context, widget.state),
          title: const Text('Loading…', style: TextStyle(fontWeight: FontWeight.w800)),
          centerTitle: true,
        ),
        drawer: ManagerRoleDrawer(
          state: widget.state,
          onDashboard: () => Navigator.of(context).popUntil((route) => route.isFirst),
          onManageEvents: () {
            Navigator.of(context).popUntil((route) => route.isFirst);
            Navigator.of(context).push(
              MaterialPageRoute<void>(builder: (_) => ManagerCateringShellScreen(state: widget.state)),
            );
          },
        ),
        body: const Center(child: CircularProgressIndicator()),
      );
    }
    final row = d;
    final isProcessing = widget.stage == 'for_processing';
    final processingSubstage = _processingSubstageForUi;
    final tabSub = widget.processingSubstage?.trim();
    final isOngoingSubstage = isProcessing &&
        (processingSubstage == 'ongoing' || tabSub == 'ongoing');
    final isDownPaymentSubstage =
        isProcessing && !isOngoingSubstage && (processingSubstage == 'down_payment' || tabSub == 'down_payment');
    final isPost = widget.stage == 'for_post_analysis';
    final isCompleted = widget.stage == 'completed';
    final isOnlineInquiry = widget.stage == 'online_inquiries';
    final isDraftStage = widget.stage == 'new_event' || widget.stage == 'online_inquiries';
    final managerDraftCanAdvanceToNext =
        !isDraftStage ||
            (_managerDraftAdvanceGateSig.isNotEmpty &&
                _managerDraftAdvanceGateSig == _computeManagerDetailSignature());
    final isThemeReadOnly = isProcessing || isPost || isCompleted;
    final canEditStage = !isCompleted;
    final canComplete = widget.state.isManager;
    final totalComputed = _grandTotalComputed();
    final displayInvoiceTotal = isProcessing
        ? (_baseFoodCost() + _themeDesignCostAmount() + _sumCostRows(_flattenAdditionalCostsFromGroups()))
        : totalComputed;
    final scheduleConflictsForProcessing = _conflictCountWithForProcessing();
    final downPaymentDue = displayInvoiceTotal * 0.5;
    final isDownPaymentConfirmed = cateringDownPaymentConfirmed(row, downPaymentDue);
    final isFullPaymentConfirmed = cateringFullPaymentConfirmed(row, totalComputed);
    final hasFullPaymentProofImage = _managerFullPaymentProofBytes != null ||
        ('${row.postAnalysis['manager_full_payment_proof_b64'] ?? ''}'.trim().isNotEmpty);
    final hasDownPaymentProofImage = _managerDownPaymentProofBytes != null ||
        ('${row.postAnalysis['manager_down_payment_proof_b64'] ?? ''}'.trim().isNotEmpty);
    final laborCostComputed = _laborCostComputed();
    final loyaltyOrderTotal = isCompleted && row.totalCost > 0 ? row.totalCost : totalComputed;
    final loyaltyPointsAtCurrentTotal = cateringLoyaltyPointsForOrderTotal(loyaltyOrderTotal);
    final showCateringLoyaltySection = isCompleted || isPost || isProcessing;
    final rowMenu = normalizeCateringMenuList(row.menu);
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
      if (managerCustomerNameController.text.trim().isEmpty) {
        return 'Enter the customer name.';
      }
      if (widget.stage == 'new_event' && managerDraftEventTitleController.text.trim().isEmpty) {
        return 'Enter event title.';
      }
      if (widget.stage == 'new_event' && travelCostController.text.trim().isEmpty) {
        return 'Enter travel cost.';
      }
      if (!isAllowedCateringAddressInCoverage(managerAddressController.text.trim())) {
        return cateringCoverageErrorText();
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

    Future<bool> saveCurrentStage({bool showConfirmDialog = true, bool popAfterSuccess = true}) async {
      final isProcessingHere = widget.stage == 'for_processing';
      final isDraftStageHereEarly = widget.stage == 'new_event' || widget.stage == 'online_inquiries';
      if (!isDraftStageHereEarly) {
        _applyDraftLaborTravelFromRow(d);
      }
      final laborCostComputedNow = _laborCostComputed();
      final travelNow = _travelCostComputed();
      final flatAdditionalSave = _flattenAdditionalCostsFromGroups();
      final totalNow = isProcessingHere
          ? (_baseFoodCost() + _themeDesignCostAmount() + _sumCostRows(flatAdditionalSave))
          : _grandTotalComputed();
      final et =
          managerEventTypeChoice == 'Other' ? managerEventTypeOtherController.text.trim() : managerEventTypeChoice;

      final isDraftStageHere = widget.stage == 'new_event' || widget.stage == 'online_inquiries';
      if (isDraftStageHere) {
        final verr = _validateDraftScheduleCoherence();
        if (verr != null) {
          appSnack(context, verr);
          return false;
        }
      }
      if (showConfirmDialog) {
        final okSave = await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: Text(isDraftStageHere ? 'Save draft' : 'Save changes'),
            content: Text(isDraftStageHere ? 'Save this draft to the server?' : 'Save your changes to this order?'),
            actions: [
              TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
              FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Save')),
            ],
          ),
        );
        if (okSave != true) return false;
      }
      _showManagerBlockingProgress('Saving…');
      try {
        if (isDraftStageHere && _draftOrderKind != d.orderKind) {
          final errSwitch = await widget.state.managerSwitchCateringOrderKind(
            id: d.id,
            fromKind: d.orderKind,
            toKind: _draftOrderKind,
          );
          if (!mounted) return false;
          if (errSwitch != null) {
            appSnack(context, errSwitch);
            return false;
          }
          final migrated = await widget.state.loadManagerCateringItem(
            id: d.id,
            orderKind: _draftOrderKind,
          );
          if (!mounted) return false;
          if (migrated != null) {
            setState(() => _loadedDetailRow = migrated);
          }
        }

        _snapshotAdditionalCostsForCurrentStage(refreshTimestamp: true);
        final rowBase = d;
        final postAnalysis = <String, dynamic>{
          'notes': analysisController.text.trim(),
          'additional_costs_groups': _additionalCostsGroupsForPostAnalysis(),
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
          if (rowBase.postAnalysis['manager_down_payment_confirmed'] == true) 'manager_down_payment_confirmed': true,
          if (rowBase.postAnalysis['manager_full_payment_confirmed'] == true) 'manager_full_payment_confirmed': true,
          if (rowBase.postAnalysis['additional_costs_payment_confirmed'] == true)
            'additional_costs_payment_confirmed': true,
          if (isOnlineInquiry || widget.stage == 'new_event') 'event_type': et,
          if (isProcessingHere) ...{
            'manager_down_payment_method': _managerDownPaymentMethod,
            'processing_phase': _processingSubstageForUi,
          },
          if (widget.stage == 'for_post_analysis') 'manager_full_payment_method': _managerFullPaymentMethod,
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
          if (managerGuestAllergens.isNotEmpty) 'guest_allergens': managerGuestAllergens.toList(),
        };

        if (isDraftStageHere) {
          final gc = int.tryParse(managerGuestCountController.text.trim());
          final formalityOut = managerFormalityLevel;
          final err = await widget.state.managerSaveCateringDraft(
            id: rowBase.id,
            orderKind: rowBase.orderKind,
            draft: {
              'post_analysis': postAnalysis,
              'checklist': checklistRows.map((e) => Map<String, dynamic>.from(e)).toList(),
              'theme_design': {...themeDesign, 'formality_level': formalityOut},
              'schedule_slots': _scheduleSlotsPayload(),
              'event_title': managerDraftEventTitleController.text.trim(),
              'event_type': et,
              'formality_level': formalityOut,
              'customer_name': managerCustomerNameController.text.trim(),
              'contact_person': managerContactPersonController.text.trim(),
              'contact_number': managerContactNumberController.text.trim(),
              'email_address': managerEmailController.text.trim(),
              'address': managerAddressController.text.trim(),
              'menu': selectedDishes.isEmpty ? rowBase.menu : selectedDishes.toList(),
              'additional_costs': flatAdditionalSave,
              'labor_cost': laborCostComputedNow,
              'travel_cost': travelNow,
              'total_cost': totalNow,
              'cost_breakdown': [
                {'label': 'Base food cost', 'amount': _baseFoodCost()},
                {'label': 'Labor cost', 'amount': laborCostComputedNow},
                {'label': 'Travel cost', 'amount': travelNow},
                if (_includesThemeDesignInTotals)
                  {'label': 'Theme design cost', 'amount': _themeDesignCostAmount()},
                {'label': 'Additional costs', 'amount': _sumCostRows(flatAdditionalSave)},
              ],
              if (gc != null && gc >= 0) 'guest_count': gc,
              'pax_buffer': int.tryParse(managerPaxBufferController.text.trim()) ?? 0,
            },
          );
          if (!mounted) return false;
          if (err != null) {
            appSnack(context, err);
            return false;
          }
          appSnack(context, 'Draft saved');
          try {
            final p = await SharedPreferences.getInstance();
            await p.remove(_localDraftKey);
          } catch (_) {}
          await widget.state.loadManagerCateringByStage(widget.stage, force: true);
          _pristineManagerDetailSig = _computeManagerDetailSignature();
          _managerDraftAdvanceGateSig = _pristineManagerDetailSig;
          if (mounted) setState(() {});
          if (popAfterSuccess && mounted) {
            if (widget.stage != 'online_inquiries' && widget.stage != 'new_event') {
              Navigator.of(context).pop();
            }
          }
          return true;
        }

        final err = await widget.state.managerAdvanceCateringStage(
          id: rowBase.id,
          orderKind: rowBase.orderKind,
          status: widget.stage,
          downPaymentAmount: isProcessing ? (double.tryParse(downPaymentPaidController.text.trim()) ?? downPaymentDue) : null,
          fullPaymentAmount: null,
          postAnalysis: (isProcessing || isPost || isOnlineInquiry) ? postAnalysis : null,
          checklist: checklistRows.map((e) => Map<String, dynamic>.from(e)).toList(),
          additionalCosts: flatAdditionalSave,
          laborCost: laborCostComputedNow,
          travelCost: travelNow,
          totalCost: totalNow,
          costBreakdown: [
            {'label': 'Base food cost', 'amount': _baseFoodCost()},
            {'label': 'Labor cost', 'amount': laborCostComputedNow},
            {'label': 'Travel cost', 'amount': travelNow},
            if (_includesThemeDesignInTotals)
              {'label': 'Theme design cost', 'amount': _themeDesignCostAmount()},
            {'label': 'Additional costs', 'amount': _sumCostRows(flatAdditionalSave)},
          ],
          themeDesign: themeDesign,
          menu: selectedDishes.isEmpty ? rowBase.menu : selectedDishes.toList(),
        );
        if (!mounted) return false;
        if (err != null) {
          appSnack(context, err);
          return false;
        }
        appSnack(context, 'Changes saved');
        final refreshed = await widget.state.loadManagerCateringItem(
          id: rowBase.id,
          orderKind: rowBase.orderKind,
        );
        if (refreshed != null && mounted) {
          setState(() => _loadedDetailRow = refreshed);
        }
        await widget.state.loadManagerCateringByStage(widget.stage, force: true);
        _pristineManagerDetailSig = _computeManagerDetailSignature();
        if (popAfterSuccess && mounted) {
          if (widget.stage != 'online_inquiries' && widget.stage != 'new_event') {
            Navigator.of(context).pop();
          }
        }
        return true;
      } finally {
        if (mounted) _hideManagerBlockingProgress();
      }
    }

    Future<void> _generateChecklistPdf() async {
      final baseFont = await PdfGoogleFonts.notoSansRegular();
      final boldFont = await PdfGoogleFonts.notoSansBold();
      final doc = pw.Document(
        theme: pw.ThemeData.withFont(base: baseFont, bold: boldFont),
      );
      final stageLabel = widget.stage.replaceAll('_', ' ').toUpperCase();
      final generatedAt = DateTime.now().toLocal().toString();
      final eventWhen = _eventDateTimeJoinedFromRowScheduleSlots(row.scheduleSlots);

      List<String> ingredientsForDishName(String dishName) {
        final want = dishName.trim().toLowerCase();
        if (want.isEmpty) return [];
        MenuItemData? fallback;
        for (final m in widget.state.menu) {
          final n = m.name.trim().toLowerCase();
          if (n.isEmpty) continue;
          if (n == want && m.ingredients.isNotEmpty) {
            return m.ingredients.map((e) => e.trim()).where((e) => e.isNotEmpty).toList();
          }
          if (m.ingredients.isNotEmpty && (n.contains(want) || want.contains(n))) {
            fallback = m;
          }
        }
        return fallback?.ingredients.map((e) => e.trim()).where((e) => e.isNotEmpty).toList() ?? [];
      }

      final rows = <List<String>>[];
      for (final cr in checklistRows) {
        final item = '${cr['item'] ?? ''}'.trim();
        final desc = '${cr['description'] ?? ''}'.trim();
        final q = '${cr['quantity'] ?? ''}'.trim();
        final c = '${cr['cost'] ?? ''}'.trim();
        final st = '${cr['status'] ?? 'not done'}'.trim();
        if (item.isEmpty && desc.isEmpty) continue;
        final dish = item.isNotEmpty ? item : desc;
        final ings = ingredientsForDishName(dish);
        if (ings.isEmpty) {
          rows.add([item, desc, q, c, st]);
        } else {
          for (final ing in ings) {
            rows.add([ing, dish, q, c, st]);
          }
        }
      }
      doc.addPage(
        pw.MultiPage(
          build: (ctx) => [
            pw.Text('Checklist', style: pw.TextStyle(fontSize: 18, fontWeight: pw.FontWeight.bold)),
            pw.SizedBox(height: 6),
            pw.Text('Event: ${row.eventTitle.isEmpty ? row.customerName : row.eventTitle}'),
            pw.Text('Customer: ${row.customerName}'),
            pw.Text('Transaction: ${row.transactionNo.trim().isEmpty ? '—' : row.transactionNo.trim()}'),
            pw.Text('Date / time of event: ${eventWhen.isEmpty ? '—' : eventWhen}'),
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
      final _ManagerOrderSummaryPdfVariant pdfVariant;
      if (isCompleted || isFullPaymentConfirmed) {
        pdfVariant = _ManagerOrderSummaryPdfVariant.fullyPaid;
      } else if (isOngoingSubstage || isPost) {
        pdfVariant = _ManagerOrderSummaryPdfVariant.afterDownPayment;
      } else if (isDownPaymentSubstage || isDraftStage || isOnlineInquiry) {
        pdfVariant = _ManagerOrderSummaryPdfVariant.beforeDownPayment;
      } else {
        pdfVariant = _ManagerOrderSummaryPdfVariant.afterDownPayment;
      }
      final bytes = await _buildOrderSummaryPdfBytes(
        additionalCostsForPdf: additionalCosts,
        variant: pdfVariant,
      );
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
                              TextFormField(
                                key: ValueKey('checklist_item_$i'),
                                initialValue: '${r['item'] ?? ''}',
                                decoration: const InputDecoration(labelText: 'Item'),
                                onChanged: (v) => r['item'] = v,
                              ),
                              const SizedBox(height: 6),
                              TextFormField(
                                key: ValueKey('checklist_desc_$i'),
                                initialValue: '${r['description'] ?? ''}',
                                decoration: const InputDecoration(labelText: 'Description'),
                                onChanged: (v) => r['description'] = v,
                              ),
                              const SizedBox(height: 6),
                              Row(
                                children: [
                                  Expanded(
                                    child: TextFormField(
                                      key: ValueKey('checklist_qty_$i'),
                                      initialValue: '${r['quantity'] ?? ''}',
                                      decoration: const InputDecoration(labelText: 'Quantity'),
                                      onChanged: (v) => r['quantity'] = v,
                                    ),
                                  ),
                                  const SizedBox(width: 8),
                                  Expanded(
                                    child: TextFormField(
                                      key: ValueKey('checklist_cost_$i'),
                                      initialValue: '${r['cost'] ?? ''}',
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
                                onChanged: (v) => setDialogState(() => r['status'] = v ?? 'not done'),
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
        await saveCurrentStage(showConfirmDialog: false, popAfterSuccess: false);
        if (mounted) appSnack(context, 'Checklist saved');
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
                              TextFormField(
                                key: ValueKey('task_emp_$i'),
                                initialValue: '${r['employee'] ?? ''}',
                                decoration: const InputDecoration(labelText: 'Employee'),
                                onChanged: (v) => r['employee'] = v,
                              ),
                              const SizedBox(height: 6),
                              TextFormField(
                                key: ValueKey('task_tasks_$i'),
                                initialValue: '${r['tasks'] ?? ''}',
                                decoration: const InputDecoration(labelText: 'Task'),
                                onChanged: (v) => r['tasks'] = v,
                              ),
                              const SizedBox(height: 6),
                              TextFormField(
                                key: ValueKey('task_sched_${i}_${r['schedule_of_tasks'] ?? ''}'),
                                initialValue: '${r['schedule_of_tasks'] ?? ''}',
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
                                  final picked = await showDatePicker(
                                    context: context,
                                    initialDate: initial,
                                    firstDate: DateTime(2020, 1, 1),
                                    lastDate: DateTime(2100, 12, 31),
                                  );
                                  if (picked == null) return;
                                  final dateText =
                                      '${picked.year.toString().padLeft(4, '0')}-${picked.month.toString().padLeft(2, '0')}-${picked.day.toString().padLeft(2, '0')}';
                                  setDialogState(() {
                                    r['schedule_of_tasks'] = dateText;
                                  });
                                },
                              ),
                              const SizedBox(height: 6),
                              TextFormField(
                                key: ValueKey('task_budget_$i'),
                                initialValue: '${r['budget'] ?? ''}',
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
                                onChanged: (v) => setDialogState(() => r['status'] = v ?? 'not done'),
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
        await saveCurrentStage(showConfirmDialog: false, popAfterSuccess: false);
        if (mounted) appSnack(context, 'Task assignment saved');
      }
    }

    List<Widget> checklistAndTaskToolsSection({required bool allowEditors}) {
      return [
        Card(
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Text('Checklist', style: TextStyle(fontWeight: FontWeight.w800)),
                const SizedBox(height: 8),
                Text(
                  allowEditors
                      ? 'Update the checklist, save, then generate the PDF. Saved rows appear in the PDF.'
                      : isPost
                          ? 'Checklist from On Going. Generate a PDF export here.'
                          : 'PDF generation is available for this record.',
                ),
                const SizedBox(height: 10),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    if (allowEditors)
                      OutlinedButton(onPressed: _openChecklistEditor, child: const Text('Checklist Editor')),
                    OutlinedButton(onPressed: _generateChecklistPdf, child: const Text('Generate Checklist PDF')),
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
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Text('Task Assignment', style: TextStyle(fontWeight: FontWeight.w800)),
                const SizedBox(height: 8),
                Text(
                  allowEditors
                      ? 'Update task assignments, save, then generate the PDF. Saved rows appear in the PDF.'
                      : isPost
                          ? 'Task assignment from On Going. Generate a PDF export here.'
                          : 'PDF generation is available for this record.',
                ),
                const SizedBox(height: 10),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    if (allowEditors)
                      OutlinedButton(onPressed: _openTaskEditor, child: const Text('Task Assignment Editor')),
                    OutlinedButton(onPressed: _generateTaskPdf, child: const Text('Generate Task Assignment PDF')),
                  ],
                ),
              ],
            ),
          ),
        ),
      ];
    }

    Future<void> submitNext() async {
      final processingSubstageEarly = _processingSubstageForUi;
      if (widget.stage == 'for_processing' && processingSubstageEarly == 'down_payment') {
        final invoiceEarly = _baseFoodCost() + _themeDesignCostAmount() + _sumCostRows(additionalCosts);
        final dueHalfEarly = invoiceEarly * 0.5;
        if (!cateringDownPaymentConfirmed(d, dueHalfEarly)) {
          appSnack(context, 'Confirm down payment with proof before continuing to On Going.');
          return;
        }
        final okCont = await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: const Text('Continue to On Going'),
            content: const Text(
              'Down payment is confirmed. Move this order to On Going for checklist and task assignment?',
            ),
            actions: [
              TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
              FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Continue')),
            ],
          ),
        );
        if (okCont != true || !mounted) return;
        await saveCurrentStage(showConfirmDialog: false, popAfterSuccess: false);
        if (!mounted) return;
        _snapshotAdditionalCostsForCurrentStage(clearWorking: true, refreshTimestamp: true);
        _showManagerBlockingProgress('Moving to On Going…');
        try {
          final err = await widget.state.managerPatchCateringPostAnalysis(
            id: d.id,
            orderKind: d.orderKind,
            patch: {
              'processing_phase': 'ongoing',
              'additional_costs_groups': _additionalCostsGroupsForPostAnalysis(),
            },
          );
          if (!mounted) return;
          if (err != null) {
            appSnack(context, err);
            return;
          }
          final full = await widget.state.loadManagerCateringItem(id: d.id, orderKind: d.orderKind);
          if (!mounted) return;
          if (full != null) setState(() => _loadedDetailRow = full);
          await widget.state.loadManagerCateringByStage(widget.stage, force: true);
          appSnack(context, 'Moved to On Going');
        } finally {
          if (mounted) _hideManagerBlockingProgress();
        }
        return;
      }

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
      if (!isDraftAdvance) {
        _applyDraftLaborTravelFromRow(rowSubmit);
      }
      _snapshotAdditionalCostsForCurrentStage(refreshTimestamp: true);
      final flatAdditionalSubmit = _flattenAdditionalCostsFromGroups();
      final downPayment = double.tryParse(downPaymentController.text.trim());
      final downPaymentPaid = double.tryParse(downPaymentPaidController.text.trim());
      final fullPayment = double.tryParse(fullPaymentController.text.trim());
      final postAnalysis = <String, dynamic>{
        'additional_costs_groups': _additionalCostsGroupsForPostAnalysis(),
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
        if (rowSubmit.postAnalysis['manager_down_payment_confirmed'] == true) 'manager_down_payment_confirmed': true,
        if (rowSubmit.postAnalysis['manager_full_payment_confirmed'] == true) 'manager_full_payment_confirmed': true,
        if (rowSubmit.postAnalysis['additional_costs_payment_confirmed'] == true)
          'additional_costs_payment_confirmed': true,
        if (isOnlineInquiry || widget.stage == 'new_event')
          'event_type': managerEventTypeChoice == 'Other'
              ? managerEventTypeOtherController.text.trim()
              : managerEventTypeChoice,
        if (isProcessing) ...{
          'manager_down_payment_method': _managerDownPaymentMethod,
          'processing_phase': _processingSubstageForUi,
        },
        if (isPost) 'manager_full_payment_method': _managerFullPaymentMethod,
      };
      if (_managerDownPaymentProofBytes != null) {
        postAnalysis['manager_down_payment_proof_b64'] = base64Encode(_managerDownPaymentProofBytes!);
      }
      if (_managerFullPaymentProofBytes != null) {
        postAnalysis['manager_full_payment_proof_b64'] = base64Encode(_managerFullPaymentProofBytes!);
      }
      final laborForSubmit = laborCostComputed;
      final travelForSubmit = _travelCostComputed();
      final invoiceTotalSubmit = isProcessing
          ? (_baseFoodCost() + _themeDesignCostAmount() + _sumCostRows(flatAdditionalSubmit))
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
        if (managerGuestAllergens.isNotEmpty) 'guest_allergens': managerGuestAllergens.toList(),
      };
      final costBreakdown = <Map<String, dynamic>>[
        {'label': 'Base food cost', 'amount': _baseFoodCost()},
        {'label': 'Labor cost', 'amount': laborForSubmit},
        {'label': 'Travel cost', 'amount': travelForSubmit},
        if (_includesThemeDesignInTotals)
          {'label': 'Theme design cost', 'amount': _themeDesignCostAmount()},
        {'label': 'Additional costs', 'amount': _sumCostRows(flatAdditionalSubmit)},
      ];
      final advancingToFullPayment =
          widget.stage == 'for_processing' && processingSubstageEarly == 'ongoing' && target == 'for_post_analysis';
      final confirm = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text(advancingToFullPayment ? 'Continue to For Full Payment' : 'Confirm submission'),
          content: Text(
            advancingToFullPayment
                ? 'Save and move this order to For Full Payment?'
                : 'Proceed to ${target == 'completed' ? 'Completed' : 'next stage'}?',
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
            FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Confirm')),
          ],
        ),
      );
      if (confirm != true) return;
      if (advancingToFullPayment) {
        _snapshotAdditionalCostsForCurrentStage(clearWorking: true, refreshTimestamp: true);
      }
      if (target == 'for_post_analysis' && !advancingToFullPayment) {
        final dueHalf = invoiceTotalSubmit * 0.5;
        if (!cateringDownPaymentConfirmed(rowSubmit, dueHalf)) {
          appSnack(
            context,
            'Confirm down payment with proof (manager) before moving to the next stage.',
          );
          return;
        }
      }
      if (target == 'completed') {
        if (!cateringFullPaymentConfirmed(rowSubmit, totalComputed)) {
          appSnack(context, 'Full payment confirmation is required before completing this order.');
          return;
        }
        final addlTotal = cateringCompiledAdditionalCostsTotal(rowSubmit);
        if (addlTotal > 0.01 && rowSubmit.postAnalysis['additional_costs_payment_confirmed'] != true) {
          appSnack(context, 'Confirm compiled additional costs payment before completing this order.');
          return;
        }
      }
      if (widget.stage == 'for_post_analysis' && target == 'completed') {
        postAnalysis['order_summary_pdf1_additional_costs'] =
            _orderSummaryPdf1AdditionalCosts.map((e) => Map<String, dynamic>.from(e)).toList();
      }
      _showManagerBlockingProgress('Submitting…');
      try {
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
          additionalCosts: flatAdditionalSubmit,
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
        appSnack(
          context,
          target == 'completed'
              ? 'Order completed'
              : (advancingToFullPayment ? 'Moved to For Full Payment' : 'Moved to next stage'),
        );
        if (advancingToFullPayment) {
          await widget.state.loadManagerCateringByStage('for_post_analysis', force: true);
        }
        await widget.state.loadManagerCateringByStage('for_processing', force: true);
        await widget.state.loadManagerCateringByStage(widget.stage, force: true);
        if (mounted) Navigator.of(context).pop();
      } finally {
        if (mounted) _hideManagerBlockingProgress();
      }
    }
    return PopScope(
      canPop: isCompleted || !_managerDetailHasUnsavedEdits(),
      onPopInvokedWithResult: (didPop, result) async {
        if (didPop) return;
        if (isCompleted) {
          if (context.mounted) Navigator.of(context).pop();
          return;
        }
        if (!_managerDetailHasUnsavedEdits()) {
          if (context.mounted) Navigator.of(context).pop();
          return;
        }
        final choice = await showDialog<String>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: const Text('Unsaved changes'),
            content: const Text('Save your changes, discard and reload from the server, or stay on this screen?'),
            actions: [
              TextButton(onPressed: () => Navigator.pop(ctx, 'cancel'), child: const Text('Stay')),
              TextButton(onPressed: () => Navigator.pop(ctx, 'discard'), child: const Text('Discard')),
              FilledButton(onPressed: () => Navigator.pop(ctx, 'save'), child: const Text('Save')),
            ],
          ),
        );
        if (!context.mounted || choice == null || choice == 'cancel') return;
        if (choice == 'discard') {
          await _reloadManagerDetailDiscardUnsaved();
          if (!context.mounted) return;
          if (Navigator.of(context).canPop()) Navigator.of(context).pop();
          return;
        }
        if (choice == 'save') {
          final ok = await saveCurrentStage(showConfirmDialog: false, popAfterSuccess: false);
          if (!context.mounted) return;
          if (ok && Navigator.of(context).canPop()) Navigator.of(context).pop();
        }
      },
      child: Scaffold(
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      appBar: AppBar(
        backgroundColor: const Color(0xFF242424),
        foregroundColor: const Color(0xFFFFC024),
        leading: _buildManagerHamburgerLeading(context, widget.state),
        title: Text(
          row.transactionNo.trim().isNotEmpty
              ? '${cateringManagerDetailTabTitle(row, widget.stage, processingSubstageOverride: widget.processingSubstage)} — ${row.transactionNo.trim()}'
              : (row.eventTitle.isEmpty ? row.customerName : row.eventTitle),
          style: kManagerAppBarTitleStyle,
        ),
        centerTitle: true,
      ),
      drawer: ManagerRoleDrawer(
        state: widget.state,
        onDashboard: () => Navigator.of(context).popUntil((route) => route.isFirst),
        onManageEvents: () => Navigator.of(context).pop(),
      ),
      body: Column(
        children: [
          Expanded(
            child: ListView(
              padding: const EdgeInsets.all(12),
              children: [
          if (showCateringLoyaltySection)
            Card(
              color: isCompleted && row.cateringLoyaltyPointsEarned > 0
                  ? Colors.amber.shade50
                  : (loyaltyPointsAtCurrentTotal > 0 ? Colors.blue.shade50 : null),
              child: ListTile(
                leading: Icon(
                  isCompleted && row.cateringLoyaltyPointsEarned > 0
                      ? Icons.card_giftcard_outlined
                      : Icons.stars_outlined,
                  color: isCompleted && row.cateringLoyaltyPointsEarned > 0
                      ? null
                      : Colors.blue.shade700,
                ),
                title: Text(
                  isCompleted && row.cateringLoyaltyPointsEarned > 0
                      ? 'Catering loyalty: +${row.cateringLoyaltyPointsEarned} pts (this order)'
                      : isCompleted
                          ? 'Catering loyalty'
                          : 'Catering loyalty (current order total)',
                  style: const TextStyle(fontWeight: FontWeight.w700),
                ),
                subtitle: Text(
                  isCompleted && row.cateringLoyaltyPointsEarned > 0
                      ? 'Points awarded when this order was completed.'
                      : loyaltyPointsAtCurrentTotal > 0
                          ? '+$loyaltyPointsAtCurrentTotal pts if completed at ₱${loyaltyOrderTotal.toStringAsFixed(2)} '
                              '(₱${kCateringLoyaltyMinOrderTotal.toStringAsFixed(0)} = $kCateringLoyaltyPointsAward pts; updates as costs change)'
                          : 'Current total ₱${loyaltyOrderTotal.toStringAsFixed(2)} is below '
                              '₱${kCateringLoyaltyMinOrderTotal.toStringAsFixed(0)} for catering loyalty points.',
                ),
              ),
            ),
          if (isOngoingSubstage || isPost || isCompleted)
            ...checklistAndTaskToolsSection(
              allowEditors: isOngoingSubstage && canEditStage && widget.state.isManager,
            ),
          if (isDownPaymentSubstage)
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
                      decoration: const InputDecoration(labelText: 'Down payment due'),
                    ),
                    const SizedBox(height: 8),
                    TextField(
                      controller: downPaymentPaidController,
                      keyboardType: TextInputType.number,
                      readOnly: !isProcessing || isDownPaymentConfirmed,
                      decoration: InputDecoration(
                        labelText: 'Down payment paid',
                        suffixIcon: _paymentProofSuffixIcon(
                          context,
                          localBytes: _managerDownPaymentProofBytes,
                          proofB64Key: 'manager_down_payment_proof_b64',
                          title: 'Down payment proof',
                        ),
                      ),
                    ),
                    const SizedBox(height: 10),
                    const Text('Proof of down payment', style: TextStyle(fontWeight: FontWeight.w700)),
                    const SizedBox(height: 6),
                    DropdownButtonFormField<String>(
                      value: _managerDownPaymentMethod,
                      decoration: const InputDecoration(
                        labelText: 'Payment method',
                        isDense: true,
                      ),
                      items: kManagerPaymentMethods
                          .map((e) => DropdownMenuItem<String>(value: e, child: Text(e)))
                          .toList(),
                      onChanged: (!isProcessing || isDownPaymentConfirmed)
                          ? null
                          : (v) {
                              if (v == null) return;
                              setState(() => _managerDownPaymentMethod = v);
                            },
                    ),
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        Expanded(
                          child: OutlinedButton.icon(
                            onPressed: (!isProcessing || isDownPaymentConfirmed)
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
                            onPressed: (!isProcessing || isDownPaymentConfirmed)
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
                      Material(
                        color: Colors.transparent,
                        child: InkWell(
                          onTap: () => showProofFullScreen(
                            context,
                            _managerDownPaymentProofBytes!,
                            title: 'Down payment proof',
                          ),
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(8),
                            child: Image.memory(_managerDownPaymentProofBytes!, height: 120, fit: BoxFit.contain),
                          ),
                        ),
                      ),
                    ],
                    const SizedBox(height: 10),
                    FilledButton(
                      onPressed: (!isProcessing ||
                              isDownPaymentConfirmed ||
                              !widget.state.isManager ||
                              !hasDownPaymentProofImage)
                          ? null
                          : () async {
                              final paid = double.tryParse(downPaymentPaidController.text.trim()) ?? 0;
                              if (!await confirmManagerPaymentAmountMismatch(
                                context,
                                paymentLabel: 'Down payment',
                                amountEntered: paid,
                                amountDue: downPaymentDue,
                              )) {
                                return;
                              }
                              final ok = await showDialog<bool>(
                                context: context,
                                builder: (dlgCtx) => AlertDialog(
                                  title: const Text('Confirm down payment'),
                                  content: Text(
                                    'Confirm down payment of PHP ${paid.toStringAsFixed(2)} (50% due: PHP ${downPaymentDue.toStringAsFixed(2)}) with proof on file?',
                                  ),
                                  actions: [
                                    TextButton(onPressed: () => Navigator.pop(dlgCtx, false), child: const Text('Cancel')),
                                    FilledButton(onPressed: () => Navigator.pop(dlgCtx, true), child: const Text('Confirm')),
                                  ],
                                ),
                              );
                              if (ok != true || !mounted) return;
                              await saveCurrentStage();
                              if (!mounted) return;
                              final err = await widget.state.managerPatchCateringPostAnalysis(
                                id: d.id,
                                orderKind: d.orderKind,
                                patch: {'manager_down_payment_confirmed': true},
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
                              appSnack(context, 'Down payment confirmed');
                            },
                      child: Text(isDownPaymentConfirmed ? 'DOWN PAYMENT CONFIRMED' : 'Confirm down payment'),
                    ),
                  ],
                ),
              ),
            ),
          if (isOngoingSubstage)
            Card(
              color: Colors.blue.shade50,
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const Text('Payments', style: TextStyle(fontWeight: FontWeight.w800)),
                    const SizedBox(height: 8),
                    TextField(
                      controller: downPaymentPaidController,
                      readOnly: true,
                      decoration: InputDecoration(
                        labelText: 'Down payment paid',
                        suffixIcon: _paymentProofSuffixIcon(
                          context,
                          localBytes: _managerDownPaymentProofBytes,
                          proofB64Key: 'manager_down_payment_proof_b64',
                          title: 'Down payment proof',
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          if (isPost)
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
                      decoration: InputDecoration(
                        labelText: 'Down payment paid',
                        suffixIcon: _paymentProofSuffixIcon(
                          context,
                          localBytes: _managerDownPaymentProofBytes,
                          proofB64Key: 'manager_down_payment_proof_b64',
                          title: 'Down payment proof',
                        ),
                      ),
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
                      readOnly: !isPost || isFullPaymentConfirmed,
                      decoration: InputDecoration(
                        labelText: 'Full payment paid',
                        suffixIcon: _paymentProofSuffixIcon(
                          context,
                          localBytes: _managerFullPaymentProofBytes,
                          proofB64Key: 'manager_full_payment_proof_b64',
                          title: 'Full payment proof',
                        ),
                      ),
                    ),
                    const SizedBox(height: 10),
                    const Text('Proof of full payment', style: TextStyle(fontWeight: FontWeight.w700)),
                    const SizedBox(height: 6),
                    DropdownButtonFormField<String>(
                      value: _managerFullPaymentMethod,
                      decoration: const InputDecoration(
                        labelText: 'Payment method',
                        isDense: true,
                      ),
                      items: kManagerPaymentMethods
                          .map((e) => DropdownMenuItem<String>(value: e, child: Text(e)))
                          .toList(),
                      onChanged: (!isPost || isFullPaymentConfirmed)
                          ? null
                          : (v) {
                              if (v == null) return;
                              setState(() => _managerFullPaymentMethod = v);
                            },
                    ),
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        Expanded(
                          child: OutlinedButton.icon(
                            onPressed: (!isPost || isFullPaymentConfirmed)
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
                            onPressed: (!isPost || isFullPaymentConfirmed)
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
                      Material(
                        color: Colors.transparent,
                        child: InkWell(
                          onTap: () => showProofFullScreen(
                            context,
                            _managerFullPaymentProofBytes!,
                            title: 'Full payment proof',
                          ),
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(8),
                            child: Image.memory(_managerFullPaymentProofBytes!, height: 120, fit: BoxFit.contain),
                          ),
                        ),
                      ),
                    ],
                    const SizedBox(height: 8),
                    FilledButton(
                      onPressed: (!widget.state.isManager ||
                              !isPost ||
                              isFullPaymentConfirmed ||
                              !hasFullPaymentProofImage)
                          ? null
                          : () async {
                              if (_compiledPostDraftAdditionalCostsTotal(includeWorkingPostStage: true) > 0.01 &&
                                  row.postAnalysis['additional_costs_payment_confirmed'] != true) {
                                appSnack(context, 'Confirm compiled additional costs payment (with proof) first.');
                                return;
                              }
                              final balanceDue =
                                  totalComputed - (double.tryParse(downPaymentPaidController.text.trim()) ?? 0);
                              final fullPaid = double.tryParse(fullPaymentController.text.trim()) ?? balanceDue;
                              if (!await confirmManagerPaymentAmountMismatch(
                                context,
                                paymentLabel: 'Full payment',
                                amountEntered: fullPaid,
                                amountDue: balanceDue,
                              )) {
                                return;
                              }
                              final ok = await showDialog<bool>(
                                context: context,
                                builder: (dlgCtx) => AlertDialog(
                                  title: const Text('Confirm full payment'),
                                  content: Text(
                                    'Confirm that full payment of PHP ${fullPaid.toStringAsFixed(2)} has been received (balance due: PHP ${balanceDue.toStringAsFixed(2)})?',
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
                              _showManagerBlockingProgress('Confirming full payment…');
                              try {
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
                              } finally {
                                if (mounted) _hideManagerBlockingProgress();
                              }
                            },
                      child: Text(isFullPaymentConfirmed ? 'FULLY PAID' : 'Confirm Full Payment'),
                    ),
                  ],
                ),
              ),
            ),
          if (isCompleted)
            Card(
              color: Colors.green.shade50,
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const Text('Payments', style: TextStyle(fontWeight: FontWeight.w800)),
                    const SizedBox(height: 6),
                    Text(
                      'Total Cost: PHP ${totalComputed.toStringAsFixed(2)}',
                      style: const TextStyle(fontWeight: FontWeight.w700),
                    ),
                    const SizedBox(height: 10),
                    TextField(
                      controller: downPaymentPaidController,
                      readOnly: true,
                      decoration: InputDecoration(
                        labelText: 'Down payment paid',
                        suffixIcon: _paymentProofSuffixIcon(
                          context,
                          localBytes: _managerDownPaymentProofBytes,
                          proofB64Key: 'manager_down_payment_proof_b64',
                          title: 'Down payment proof',
                        ),
                      ),
                    ),
                    const SizedBox(height: 8),
                    TextField(
                      controller: fullPaymentController,
                      readOnly: true,
                      decoration: InputDecoration(
                        labelText: 'Full payment paid',
                        suffixIcon: _paymentProofSuffixIcon(
                          context,
                          localBytes: _managerFullPaymentProofBytes,
                          proofB64Key: 'manager_full_payment_proof_b64',
                          title: 'Full payment proof',
                        ),
                      ),
                    ),
                    if (_compiledPostDraftAdditionalCostsTotal() > 0.01) ...[
                      const SizedBox(height: 8),
                      TextField(
                        readOnly: true,
                        controller: additionalCostsPaidController,
                        decoration: InputDecoration(
                          labelText: 'Additional costs paid',
                          prefixText: 'PHP ',
                          suffixIcon: _paymentProofSuffixIcon(
                            context,
                            localBytes: _managerAdditionalCostsProofBytes,
                            proofB64Key: 'manager_additional_costs_proof_b64',
                            title: 'Additional costs proof',
                          ),
                        ),
                      ),
                      if (row.postAnalysis['additional_costs_payment_confirmed'] == true)
                        Padding(
                          padding: const EdgeInsets.only(top: 4),
                          child: Text(
                            'Additional costs: PAID',
                            style: TextStyle(
                              color: Colors.green.shade800,
                              fontWeight: FontWeight.w900,
                              fontSize: 14,
                            ),
                          ),
                        ),
                    ],
                    const SizedBox(height: 8),
                    Text(
                      'Total amount paid: PHP ${(row.downPaymentAmount + row.fullPaymentAmount).toStringAsFixed(2)}',
                      style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 15),
                    ),
                    if (isFullPaymentConfirmed) ...[
                      const SizedBox(height: 10),
                      Text(
                        'PAID',
                        style: TextStyle(
                          color: Colors.green.shade800,
                          fontWeight: FontWeight.w900,
                          fontSize: 18,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          if (!isDraftStage && (isDownPaymentSubstage || isOngoingSubstage || isPost || isCompleted))
            Card(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(
                      'Order summary',
                      style: Theme.of(context).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w800),
                    ),
                    const SizedBox(height: 8),
                    Builder(
                      builder: (ctx) {
                        final showBeforeDownPayment =
                            isDownPaymentSubstage || isOngoingSubstage || isPost || isCompleted;
                        final showAfterDownPayment = isOngoingSubstage || isPost || isCompleted;
                        final showAdditionalCosts = !isCompleted && _hasAdditionalCostsSectionInput();
                        final showFullyPaid = isPost || isCompleted;
                        return Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Wrap(
                              spacing: 8,
                              runSpacing: 8,
                              children: [
                                if (showBeforeDownPayment)
                                  OutlinedButton(
                                    onPressed: () => _previewManagerOrderSummary(
                                      _ManagerOrderSummaryPdfVariant.beforeDownPayment,
                                    ),
                                    child: const Text('Order Summary before Down Payment'),
                                  ),
                                if (showAfterDownPayment)
                                  OutlinedButton(
                                    onPressed: () => _previewManagerOrderSummary(
                                      _ManagerOrderSummaryPdfVariant.afterDownPayment,
                                    ),
                                    child: const Text('Order Summary after Down Payment'),
                                  ),
                                if (showAdditionalCosts)
                                  OutlinedButton(
                                    onPressed: () async {
                                      if (_additionalCostsSheetPdfBytes != null) {
                                        await _openOrderSummaryPdfBytes(_additionalCostsSheetPdfBytes!);
                                        return;
                                      }
                                      await _previewManagerOrderSummary(
                                        _ManagerOrderSummaryPdfVariant.additionalCostsSheet,
                                        postAnalysis2Only: true,
                                      );
                                    },
                                    child: Text(
                                      _additionalCostsSheetPdfGenerating
                                          ? 'Generating Additional Costs…'
                                          : 'Order Summary | Additional Costs',
                                    ),
                                  ),
                                if (showFullyPaid)
                                  OutlinedButton(
                                    onPressed: () => _previewManagerOrderSummary(
                                      _ManagerOrderSummaryPdfVariant.fullyPaid,
                                    ),
                                    child: const Text('Order Summary Fully Paid'),
                                  ),
                              ],
                            ),
                            if (isOngoingSubstage) ...[
                              const SizedBox(height: 8),
                              OutlinedButton.icon(
                                onPressed: () async {
                                  await _sendOrderSummaryPdfToCustomer();
                                },
                                icon: const Icon(Icons.send_outlined),
                                label: const Text('Send order summary PDF to customer'),
                              ),
                            ],
                            if (isPost || isCompleted) ...[
                              const SizedBox(height: 8),
                              Text(
                                isCompleted
                                    ? 'These summaries reflect saved amounts and costs for this completed order.'
                                    : 'Previews use current costing on this screen. The Additional Costs sheet lists only costs from For Down Payment, On Going, and For Full Payment (not draft inquiries).',
                                style: TextStyle(
                                  fontSize: 12,
                                  height: 1.35,
                                  color: Colors.black.withValues(alpha: 0.72),
                                ),
                              ),
                            ],
                          ],
                        );
                      },
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
                    Text(
                      'Order type: ${row.orderType == 'catering_event' || row.orderKind == 'event' ? 'Catering + Event' : 'Catering Only'}',
                    ),
                    if (row.transactionNo.trim().isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 2),
                        child: Text(
                          'Transaction No.: ${row.transactionNo}',
                          style: const TextStyle(fontWeight: FontWeight.w600),
                        ),
                      ),
                    Text('Event: ${row.eventTitle.trim().isEmpty ? row.customerName : row.eventTitle}'),
                    Text('Customer: ${row.customerName}'),
                    Text('Contact person: ${row.contactPerson}'),
                    Text('Contact number: ${row.contactNumber}'),
                    Text('Email: ${row.emailAddress}'),
                    buildEventVenueAddressLink(context, row.address, prefix: 'Address'),
                    if (!isAllowedCateringAddressInCoverage(row.address))
                      Text(
                        cateringCoverageErrorText(),
                        style: TextStyle(color: Colors.red.shade700, fontWeight: FontWeight.w700),
                      ),
                    Text('Guests: ${row.guestCount}'),
                    Text('Payment method: ${row.paymentMethod}'),
                    if (row.formalityLevel.trim().isNotEmpty)
                      Text('Formality: ${row.formalityLevel}'),
                    if (isCompleted) ...[
                      const SizedBox(height: 8),
                      _laborTravelPlainTextSection(row),
                    ],
                    if (row.scheduleSlots.isNotEmpty) ...[
                      const SizedBox(height: 6),
                      if (isProcessing || isPost || isCompleted) ...[
                        Text(
                          'Date & time of event',
                          style: Theme.of(context).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700),
                        ),
                        const SizedBox(height: 6),
                        ..._buildLabeledScheduleRows(row.scheduleSlots),
                        if (isProcessing && row.processingScheduleOverlaps > 0) ...[
                          const SizedBox(height: 8),
                          Text(
                            'This date and time conflicts with another event in For Down Payment / On Going.',
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
                              })
                          : null,
                    ),
                    const SizedBox(height: 8),
                    TextField(
                      controller: managerCustomerNameController,
                      readOnly: !canEditStage,
                      decoration: const InputDecoration(
                        labelText: 'Customer',
                        helperText: 'Required',
                      ),
                    ),
                    const SizedBox(height: 2),
                    CheckboxListTile(
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      value: _managerCustomerSameAsContact,
                      onChanged: !canEditStage
                          ? null
                          : (v) {
                              setState(() {
                                _managerCustomerSameAsContact = v ?? false;
                                if (_managerCustomerSameAsContact) {
                                  managerCustomerNameController.text = managerContactPersonController.text;
                                }
                              });
                            },
                      title: const Text('Same as contact person'),
                      controlAffinity: ListTileControlAffinity.leading,
                    ),
                    const SizedBox(height: 8),
                    TextField(
                      controller: managerDraftEventTitleController,
                      readOnly: !canEditStage,
                      decoration: InputDecoration(
                        labelText: 'Event title',
                        helperText: widget.stage == 'new_event' ? 'Required' : null,
                      ),
                    ),
                    const SizedBox(height: 8),
                    TextField(
                      controller: managerContactPersonController,
                      readOnly: !canEditStage,
                      decoration: const InputDecoration(labelText: 'Contact person'),
                    ),
                    const SizedBox(height: 8),
                    TextField(
                      controller: managerContactNumberController,
                      readOnly: !canEditStage,
                      keyboardType: TextInputType.phone,
                      maxLength: 11,
                      inputFormatters: [
                        FilteringTextInputFormatter.digitsOnly,
                        LengthLimitingTextInputFormatter(11),
                      ],
                      decoration: const InputDecoration(labelText: 'Contact number', counterText: ''),
                    ),
                    const SizedBox(height: 8),
                    TextField(
                      controller: managerEmailController,
                      readOnly: !canEditStage,
                      decoration: const InputDecoration(labelText: 'Email address'),
                    ),
                    const SizedBox(height: 8),
                    TextField(
                      controller: managerAddressController,
                      readOnly: !canEditStage,
                      onTap: canEditStage
                          ? null
                          : () => showEventVenueMapPreview(context, managerAddressController.text),
                      decoration: InputDecoration(
                        labelText: 'Event venue',
                        helperText: canEditStage
                            ? 'Type to search, pin on map, or pick a suggestion'
                            : 'Tap the map icon or address preview to open the location',
                        suffixIcon: IconButton(
                          tooltip: canEditStage ? 'Pin on map' : 'View on map',
                          icon: Icon(canEditStage ? Icons.place_outlined : Icons.map_outlined),
                          onPressed: canEditStage
                              ? _pickManagerVenueOnMap
                              : () => showEventVenueMapPreview(context, managerAddressController.text),
                        ),
                      ),
                    ),
                    if (canEditStage && _managerVenueSuggestions.isNotEmpty)
                      Container(
                        margin: const EdgeInsets.only(top: 6),
                        decoration: BoxDecoration(
                          border: Border.all(color: Colors.grey.shade300),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Column(
                          children: _managerVenueSuggestions
                              .map(
                                (s) => ListTile(
                                  dense: true,
                                  title: Text(s, maxLines: 2, overflow: TextOverflow.ellipsis),
                                  onTap: () => setState(() {
                                    managerAddressController.text = s;
                                    _managerVenueSuggestions.clear();
                                  }),
                                ),
                              )
                              .toList(),
                        ),
                      ),
                    if (!isAllowedCateringAddressInCoverage(managerAddressController.text.trim()))
                      Padding(
                        padding: const EdgeInsets.only(top: 6),
                        child: Text(
                          cateringCoverageErrorText(),
                          style: TextStyle(color: Colors.red.shade700, fontWeight: FontWeight.w700),
                        ),
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
                              'Conflicts detected with an existing event in For Down Payment / On Going.',
                              style: TextStyle(
                                color: Colors.red.shade700,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    if (_isManagerDraftDetailStage) ...[
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
                                })
                            : null,
                      ),
                      const SizedBox(height: 8),
                      const Text('Allergens', style: TextStyle(fontWeight: FontWeight.w800)),
                      const SizedBox(height: 6),
                      buildGuestAllergenSelector(
                        catalog: widget.state.allergenCatalog,
                        selected: managerGuestAllergens,
                        enabled: canEditStage,
                        onChanged: (next) => setState(() {
                          managerGuestAllergens
                            ..clear()
                            ..addAll(next);
                        }),
                      ),
                      const SizedBox(height: 8),
                    ],
                    TextField(
                      controller: managerGuestCountController,
                      keyboardType: TextInputType.number,
                      readOnly: !canEditStage,
                      decoration: const InputDecoration(labelText: 'Number of guests'),
                    ),
                    if (_isManagerDraftDetailStage) ...[
                      const SizedBox(height: 8),
                      TextField(
                        controller: managerPaxBufferController,
                        keyboardType: TextInputType.number,
                        readOnly: !canEditStage,
                        decoration: const InputDecoration(
                          labelText: 'Pax Buffer (optional)',
                          helperText: 'Extra pax for estimates only (₱500 per pax)',
                        ),
                      ),
                    ],
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
                    const SizedBox(height: 8),
                    buildManagerThemeDesignBlock(
                      themeDesign: row.themeDesign,
                      openEditorLabel: hasEventThemeDesign(row.themeDesign)
                          ? 'Edit theme design'
                          : 'Create my own theme design',
                      onOpenEditor: !isPost && !isCompleted
                          ? () async {
                              final email = managerEmailController.text.trim().isNotEmpty
                                  ? managerEmailController.text.trim()
                                  : row.emailAddress;
                              final updated = await Navigator.push<Map<String, dynamic>?>(
                                context,
                                MaterialPageRoute<Map<String, dynamic>?>(
                                  builder: (_) => EventThemeDesignScreen(
                                    apiBase: widget.state.apiBase,
                                    userEmail: email,
                                    orderId: row.id,
                                    orderKind: row.orderKind,
                                    initialEventType:
                                        row.eventType.isNotEmpty ? row.eventType : 'Birthday',
                                    initialThemeDesign: row.themeDesign,
                                    eventTitle: row.eventTitle,
                                    formalityLevel: managerFormalityLevel,
                                    eventSetting: managerEventSetting,
                                    cashierEmail: widget.state.userEmail,
                                    cashierPassword: widget.state.loginPassword,
                                    persistToOrder: true,
                                  ),
                                ),
                              );
                              if (updated != null && mounted) {
                                final m = await widget.state.loadManagerCateringItem(
                                  id: row.id,
                                  orderKind: row.orderKind,
                                );
                                if (m != null) setState(() => _loadedDetailRow = m);
                              }
                            }
                          : null,
                      showCostFields: isDraftStage,
                      noteController: managerInquiryNoteController,
                      costController: themeCostAmountController,
                      readOnlyCostFields: isThemeReadOnly || !canEditStage,
                    ),
                    if (!isDraftStage && themeDesignCosts.isNotEmpty) ...[
                      const SizedBox(height: 8),
                      ...themeDesignCosts.map(
                        (e) => ListTile(
                          dense: true,
                          contentPadding: EdgeInsets.zero,
                          title: Text(
                            '${e['label'] ?? ''}'.trim().isEmpty ? 'Theme cost' : '${e['label']}',
                          ),
                          trailing: Text('₱${jsonToDouble(e['amount']).toStringAsFixed(2)}'),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          if (row.orderKind == 'event' && canShowSeatingLayout(row.status))
            Card(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('Seating layout', style: TextStyle(fontWeight: FontWeight.w800)),
                    const SizedBox(height: 8),
                    buildManagerSeatingLayoutBlock(
                      seatingPlanJson: row.seatingPlan,
                      helperText: widget.stage == 'for_processing'
                          ? 'Edit table and chair placement while this order is in For Processing.'
                          : 'View the seating layout submitted with this inquiry.',
                      buttonLabel:
                          canEditSeatingLayout(row.status) ? 'Edit seating layout' : 'View seating layout',
                      onOpenEditor: () async {
                        final initialPlan = SeatingPlanData.fromJson(row.seatingPlan);
                        await Navigator.push<SeatingPlanData?>(
                          context,
                          MaterialPageRoute<SeatingPlanData?>(
                            builder: (_) => SeatingLayoutEditorScreen(
                              apiBase: widget.state.apiBase,
                              userEmail: row.emailAddress,
                              orderId: row.id,
                              orderKind: row.orderKind,
                              initialPlan: initialPlan.isEffectivelyEmpty ? null : initialPlan,
                              cashierEmail: widget.state.userEmail,
                              cashierPassword: widget.state.loginPassword,
                              readOnly: !canEditSeatingLayout(row.status),
                            ),
                          ),
                        );
                        if (!mounted) return;
                        final m = await widget.state.loadManagerCateringItem(
                          id: row.id,
                          orderKind: row.orderKind,
                        );
                        if (m != null) setState(() => _loadedDetailRow = m);
                      },
                    ),
                  ],
                ),
              ),
            ),
          if (!isCompleted) ...[
            _laborCostCard(
              allowLaborEdits: isDraftStage && canEditStage,
              showTravelReadOnly: !isDraftStage,
            ),
            _additionalCostsCard(
              draft: isDraftStage,
              processing: isProcessing && !isPost,
              post: isPost,
              row: row,
            ),
          ],
          if (isDraftStage) ...[
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
          if (isDraftStage)
            Card(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(
                      'Order summary',
                      style: Theme.of(context).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w800),
                    ),
                    const SizedBox(height: 8),
                    OutlinedButton(
                      onPressed: _generateInvoicePdf,
                      child: const Text('Generate order summary PDF'),
                    ),
                  ],
                ),
              ),
            ),
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
          ),
          if (isCompleted)
            Material(
              elevation: 8,
              shadowColor: Colors.black26,
              color: Theme.of(context).scaffoldBackgroundColor,
              child: SafeArea(
                top: false,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const Text('Total Cost', style: TextStyle(fontWeight: FontWeight.w800, fontSize: 16)),
                      Text(
                        '₱${(row.totalCost > 0 ? row.totalCost : totalComputed).toStringAsFixed(2)}',
                        style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 22),
                      ),
                    ],
                  ),
                ),
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
                          const Text(
                            'Total Cost',
                            style: TextStyle(fontWeight: FontWeight.w800),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            '₱${(isProcessing ? displayInvoiceTotal : totalComputed).toStringAsFixed(2)}',
                            style: const TextStyle(fontSize: 24, fontWeight: FontWeight.w800),
                          ),
                        ],
                      ),
                    ),
                    if (!(isDownPaymentSubstage || isOngoingSubstage || isDraftStage || isPost)) ...[
                      const SizedBox(height: 8),
                      OutlinedButton(
                        onPressed: () async {
                          if (isPost) {
                            if (_postAnalysisPdf2Bytes != null) {
                              await _openOrderSummaryPdfBytes(_postAnalysisPdf2Bytes!);
                              return;
                            }
                            if (_postAnalysisPdfGenerating) {
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
                    ],
                    if (isDraftStage || isProcessing || isPost) ...[
                      const SizedBox(height: 8),
                      OutlinedButton(
                        onPressed: () async {
                          await saveCurrentStage();
                        },
                        child: Text(isDraftStage ? 'Save draft' : 'Save'),
                      ),
                    ],
                    if (isDraftStage && !managerDraftCanAdvanceToNext) ...[
                      const SizedBox(height: 6),
                      Text(
                        'Save and confirm your draft before moving to the next stage.',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontSize: 12,
                          height: 1.3,
                          color: Colors.black.withValues(alpha: 0.65),
                        ),
                      ),
                    ],
                    if (isDraftStage || isProcessing || isPost) ...[
                      const SizedBox(height: 8),
                      FilledButton(
                        onPressed: (isDraftStage && !managerDraftCanAdvanceToNext) ? null : submitNext,
                        child: Text(
                          isDraftStage
                              ? 'Move to For Down Payment'
                              : (isPost
                                  ? 'Complete Order'
                                  : (isDownPaymentSubstage
                                      ? 'Continue to On Going'
                                      : (isOngoingSubstage ? 'Continue to For Full Payment' : 'Submit to Next Stage'))),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            )
          : null,
      ),
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
      if (!_tab.indexIsChanging) {
        if (_tab.index == 1) {
          widget.state.loadCashierOnlineOrders(force: true);
        }
        if (_tab.index == 2) {
          widget.state.loadCashierWalkInQueues(force: true);
        }
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
            leading: _buildCashierHamburgerLeading(context, widget.state),
            title: Text(name, style: const TextStyle(fontWeight: FontWeight.w700, letterSpacing: 0.5)),
            actions: [
              if (_tab.index == 0)
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: Builder(
                    builder: (context) {
                      final n = widget.state.tray.fold<int>(0, (a, e) => a + e.qty);
                      if (n <= 0) return const SizedBox.shrink();
                      return Container(
                        constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
                        padding: const EdgeInsets.symmetric(horizontal: 7),
                        alignment: Alignment.center,
                        decoration: const BoxDecoration(color: Colors.red, shape: BoxShape.circle),
                        child: Text(
                          '$n',
                          style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w800, fontSize: 12),
                        ),
                      );
                    },
                  ),
                ),
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
                              : 'WALK-IN ORDERS',
                      style: const TextStyle(color: AppColors.ink, fontWeight: FontWeight.w800, fontSize: 12),
                    ),
                  ),
                ),
              ),
            ],
            bottom: PreferredSize(
              preferredSize: const Size.fromHeight(48),
              child: Material(
                color: Colors.white,
                elevation: 2,
                shadowColor: Colors.black26,
                child: TabBar(
                  controller: _tab,
                  indicatorColor: AppColors.brand,
                  labelColor: AppColors.brand,
                  unselectedLabelColor: Colors.grey.shade700,
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
                    const Tab(text: 'Walk-In Orders'),
                  ],
                ),
              ),
            ),
          ),
          drawer: CashierRoleDrawer(state: widget.state, tabController: _tab),
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
                      onPressed: () => widget.state.promptAndAddRestaurantDish(context, item),
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
                        child: Padding(
                          padding: const EdgeInsets.fromLTRB(8, 8, 8, 8),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              Text(e.menu.name, maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w700)),
                              const SizedBox(height: 4),
                              Text(
                                cartLineDetailSubtitle(e),
                                style: TextStyle(fontSize: 11, height: 1.25, color: Colors.grey.shade800),
                              ),
                              Row(
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
                              if (e.dip.trim().isNotEmpty)
                                Row(
                                  mainAxisAlignment: MainAxisAlignment.end,
                                  children: [
                                    IconButton(
                                      padding: EdgeInsets.zero,
                                      constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
                                      icon: const Icon(Icons.remove_circle_outline, size: 20),
                                      onPressed: e.dipQty > 0 ? () => widget.state.changeDipQty(e, -1) : null,
                                    ),
                                    Padding(
                                      padding: const EdgeInsets.symmetric(horizontal: 4),
                                      child: Text('${e.dipQty}', style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 13)),
                                    ),
                                    IconButton(
                                      padding: EdgeInsets.zero,
                                      constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
                                      icon: const Icon(Icons.add_circle_outline, size: 20),
                                      onPressed: () => widget.state.changeDipQty(e, 1),
                                    ),
                                  ],
                                ),
                            ],
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
        final subtotal = widget.state.tray.fold<double>(0, (s, e) => s + cartLineSubtotal(e));
        final trayDishQty = widget.state.tray.fold<int>(0, (s, e) => s + e.qty);
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
                          child: Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              const Text('YOUR TRAY'),
                              if (trayDishQty > 0) ...[
                                const SizedBox(width: 10),
                                Container(
                                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                  constraints: const BoxConstraints(minWidth: 22, minHeight: 22),
                                  alignment: Alignment.center,
                                  decoration: const BoxDecoration(color: Colors.red, shape: BoxShape.circle),
                                  child: Text(
                                    '$trayDishQty',
                                    style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.w900),
                                  ),
                                ),
                              ],
                            ],
                          ),
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
                        child: Padding(
                          padding: const EdgeInsets.fromLTRB(8, 10, 8, 10),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              Row(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  SizedBox(
                                    width: 56,
                                    height: 56,
                                    child: ClipRRect(
                                      borderRadius: BorderRadius.circular(8),
                                      child: _MenuThumb(item: e.menu),
                                    ),
                                  ),
                                  const SizedBox(width: 10),
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment: CrossAxisAlignment.start,
                                      children: [
                                        Text(e.menu.name, style: const TextStyle(fontWeight: FontWeight.w700)),
                                        const SizedBox(height: 4),
                                        Text(
                                          cartLineDetailSubtitle(e),
                                          style: TextStyle(fontSize: 12, height: 1.3, color: Colors.grey.shade800),
                                        ),
                                      ],
                                    ),
                                  ),
                                  Text(
                                    '₱${cartLineSubtotal(e).toStringAsFixed(2)}',
                                    style: const TextStyle(fontWeight: FontWeight.w800),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 8),
                              Row(
                                children: [
                                  const Text('Main qty', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 12)),
                                  const Spacer(),
                                  IconButton(
                                    onPressed: () => state.changeQty(e, 1),
                                    icon: const Icon(Icons.add_circle, color: AppColors.success),
                                  ),
                                  Text('${e.qty}', style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 16)),
                                  IconButton(
                                    onPressed: () => state.changeQty(e, -1),
                                    icon: const Icon(Icons.remove_circle, color: AppColors.accent),
                                  ),
                                ],
                              ),
                              if (e.dip.trim().isNotEmpty)
                                Row(
                                  children: [
                                    const Text('Add-on qty', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 12)),
                                    const Spacer(),
                                    IconButton(
                                      onPressed: e.dipQty > 0 ? () => state.changeDipQty(e, -1) : null,
                                      icon: const Icon(Icons.remove_circle_outline),
                                    ),
                                    Text('${e.dipQty}', style: const TextStyle(fontWeight: FontWeight.w800)),
                                    IconButton(
                                      onPressed: () => state.changeDipQty(e, 1),
                                      icon: const Icon(Icons.add_circle_outline),
                                    ),
                                  ],
                                ),
                            ],
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
                            '${e.menu.name}\n${cartLineDetailSubtitle(e)}',
                            style: const TextStyle(height: 1.25),
                          ),
                        ),
                        Text(
                          '₱${cartLineSubtotal(e).toStringAsFixed(2)}',
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
              showDialog<void>(
                context: context,
                barrierDismissible: false,
                builder: (ctx) => const AlertDialog(
                  content: Row(
                    children: [
                      SizedBox(width: 8),
                      CircularProgressIndicator(),
                      SizedBox(width: 20),
                      Expanded(child: Text('Processing walk-in sale…')),
                    ],
                  ),
                ),
              );
              final err = await widget.state.submitPosWalkInOrder(
                paymentMethod: paymentMethod,
                amountReceived: arNum,
                note: note.text.trim(),
                posCustomerLabel: customerLabel.text.trim(),
                paymentProofBase64: gcashProofBytes != null ? base64Encode(gcashProofBytes!) : '',
              );
              if (context.mounted) Navigator.of(context).pop();
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
  String _search = '';
  /// Preparing tab: `all` | `cash` | `gcash`
  String _walkPreparingFilter = 'all';
  /// Complete / Cancelled: `all` | `past_30` | `cash` | `gcash`
  String _walkHistoryFilter = 'all';

  @override
  void initState() {
    super.initState();
    _walkTab = TabController(length: 3, vsync: this);
    _walkTab.addListener(() {
      if (mounted) setState(() {});
    });
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
        title: Text(uiOrderNo(o.orderNo)),
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
              ...o.lines.map(
                (l) => Text(
                  '• ${l.itemName} — ${orderLineDetailSubtitle(l).replaceAll('\n', ' ')}',
                  style: const TextStyle(height: 1.35),
                ),
              ),
              if (o.paymentProofBase64 != null && o.paymentProofBase64!.trim().isNotEmpty) ...[
                const SizedBox(height: 12),
                const Text('Payment proof', style: TextStyle(fontWeight: FontWeight.w800)),
                const SizedBox(height: 8),
                ...(() {
                  try {
                    final bytes = Uint8List.fromList(base64Decode(o.paymentProofBase64!.trim()));
                    return [
                      InkWell(
                        onTap: () => showProofFullScreen(context, bytes, title: 'Payment proof'),
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(10),
                          child: Image.memory(bytes, height: 160, fit: BoxFit.contain),
                        ),
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
            if (widget.state.cashierDataLoadError != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    widget.state.cashierDataLoadError!,
                    style: TextStyle(color: Colors.red.shade800, fontWeight: FontWeight.w600),
                  ),
                ),
              ),
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 10, 12, 6),
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      decoration: const InputDecoration(
                        hintText: 'Search order no, walk-in label…',
                        isDense: true,
                        border: OutlineInputBorder(),
                      ),
                      onChanged: (v) => setState(() => _search = v),
                    ),
                  ),
                  if (_walkTab.index == 0)
                    PopupMenuButton<String>(
                      tooltip: 'Filter',
                      icon: Icon(
                        Icons.filter_list,
                        color: _walkPreparingFilter == 'all' ? null : AppColors.accent,
                      ),
                      onSelected: (v) => setState(() => _walkPreparingFilter = v),
                      itemBuilder: (ctx) => [
                        PopupMenuItem<String>(
                          value: 'all',
                          child: Row(
                            children: [
                              if (_walkPreparingFilter == 'all')
                                Icon(Icons.check, size: 18, color: Theme.of(ctx).colorScheme.primary),
                              if (_walkPreparingFilter == 'all') const SizedBox(width: 4),
                              const Text('All'),
                            ],
                          ),
                        ),
                        PopupMenuItem<String>(
                          value: 'cash',
                          child: Row(
                            children: [
                              if (_walkPreparingFilter == 'cash')
                                Icon(Icons.check, size: 18, color: Theme.of(ctx).colorScheme.primary),
                              if (_walkPreparingFilter == 'cash') const SizedBox(width: 4),
                              const Text('Cash'),
                            ],
                          ),
                        ),
                        PopupMenuItem<String>(
                          value: 'gcash',
                          child: Row(
                            children: [
                              if (_walkPreparingFilter == 'gcash')
                                Icon(Icons.check, size: 18, color: Theme.of(ctx).colorScheme.primary),
                              if (_walkPreparingFilter == 'gcash') const SizedBox(width: 4),
                              const Text('GCash'),
                            ],
                          ),
                        ),
                      ],
                    ),
                  if (_walkTab.index == 1 || _walkTab.index == 2)
                    PopupMenuButton<String>(
                      tooltip: 'Filter',
                      icon: Icon(
                        Icons.filter_list,
                        color: _walkHistoryFilter == 'all' ? null : AppColors.accent,
                      ),
                      onSelected: (v) => setState(() => _walkHistoryFilter = v),
                      itemBuilder: (ctx) => [
                        PopupMenuItem<String>(
                          value: 'all',
                          child: Row(
                            children: [
                              if (_walkHistoryFilter == 'all')
                                Icon(Icons.check, size: 18, color: Theme.of(ctx).colorScheme.primary),
                              if (_walkHistoryFilter == 'all') const SizedBox(width: 4),
                              const Text('All'),
                            ],
                          ),
                        ),
                        PopupMenuItem<String>(
                          value: 'past_30',
                          child: Row(
                            children: [
                              if (_walkHistoryFilter == 'past_30')
                                Icon(Icons.check, size: 18, color: Theme.of(ctx).colorScheme.primary),
                              if (_walkHistoryFilter == 'past_30') const SizedBox(width: 4),
                              const Text('Past 30 days'),
                            ],
                          ),
                        ),
                        PopupMenuItem<String>(
                          value: 'cash',
                          child: Row(
                            children: [
                              if (_walkHistoryFilter == 'cash')
                                Icon(Icons.check, size: 18, color: Theme.of(ctx).colorScheme.primary),
                              if (_walkHistoryFilter == 'cash') const SizedBox(width: 4),
                              const Text('Cash'),
                            ],
                          ),
                        ),
                        PopupMenuItem<String>(
                          value: 'gcash',
                          child: Row(
                            children: [
                              if (_walkHistoryFilter == 'gcash')
                                Icon(Icons.check, size: 18, color: Theme.of(ctx).colorScheme.primary),
                              if (_walkHistoryFilter == 'gcash') const SizedBox(width: 4),
                              const Text('GCash'),
                            ],
                          ),
                        ),
                      ],
                    ),
                ],
              ),
            ),
            Material(
              color: Colors.white,
              elevation: 2,
              shadowColor: Colors.black26,
              child: TabBar(
                controller: _walkTab,
                labelColor: AppColors.brand,
                unselectedLabelColor: Colors.grey.shade700,
                indicatorColor: AppColors.brand,
                tabs: const [
                  Tab(text: 'Preparing'),
                  Tab(text: 'Complete'),
                  Tab(text: 'Cancelled'),
                ],
              ),
            ),
            Expanded(
              child: TabBarView(
                controller: _walkTab,
                children: [
                  RefreshIndicator(
                    onRefresh: () => widget.state.loadCashierWalkInQueues(force: true),
                    child: _walkList(widget.state.cashierWalkInPreparing, showClaim: true, tabIndex: 0),
                  ),
                  RefreshIndicator(
                    onRefresh: () => widget.state.loadCashierWalkInQueues(force: true),
                    child: _walkList(widget.state.cashierWalkInComplete, showClaim: false, tabIndex: 1),
                  ),
                  RefreshIndicator(
                    onRefresh: () => widget.state.loadCashierWalkInQueues(force: true),
                    child: _walkList(widget.state.cashierWalkInCancelled, showClaim: false, isCancelledList: true, tabIndex: 2),
                  ),
                ],
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _walkList(
    List<OrderData> rows, {
    required bool showClaim,
    bool isCancelledList = false,
    int tabIndex = 0,
  }) {
    var filtered = rows;
    if (tabIndex == 1 || tabIndex == 2) {
      if (_walkHistoryFilter == 'past_30') {
        filtered = filtered.where((o) => isWithinPast30Days(o.createdAt)).toList();
      }
    }
    final q = _search.trim().toLowerCase();
    if (q.isNotEmpty) {
      filtered = filtered
          .where(
            (o) =>
                o.orderNo.toLowerCase().contains(q) ||
                uiOrderNo(o.orderNo).toLowerCase().contains(q) ||
                o.posCustomerLabel.toLowerCase().contains(q) ||
                statusReadable(o.status).toLowerCase().contains(q),
          )
          .toList();
    }
    if (tabIndex == 0) {
      if (_walkPreparingFilter == 'gcash') {
        filtered = filtered.where((o) => o.paymentMode.toUpperCase().contains('GCASH')).toList();
      } else if (_walkPreparingFilter == 'cash') {
        filtered = filtered.where((o) {
          final pm = o.paymentMode.toUpperCase();
          return pm.contains('CASH') && !pm.contains('GCASH');
        }).toList();
      }
    } else {
      if (_walkHistoryFilter == 'gcash') {
        filtered = filtered.where((o) => o.paymentMode.toUpperCase().contains('GCASH')).toList();
      } else if (_walkHistoryFilter == 'cash') {
        filtered = filtered.where((o) {
          final pm = o.paymentMode.toUpperCase();
          return pm.contains('CASH') && !pm.contains('GCASH');
        }).toList();
      }
    }
    if (filtered.isEmpty) {
      return ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        children: const [
          SizedBox(height: 120, child: Center(child: Text('No orders in this stage.'))),
        ],
      );
    }
    return ListView.builder(
      padding: const EdgeInsets.all(12),
      itemCount: filtered.length,
      itemBuilder: (context, i) {
        final o = filtered[i];
        final submitted = formatDateTimeLocal(o.createdAt);
        final completed =
            o.updatedAt != null ? formatDateTimeLocal(o.updatedAt!) : '';
        return Card(
          elevation: 2,
          color: Colors.white,
          shadowColor: Colors.black26,
          child: InkWell(
            onTap: () => _showWalkInDetail(o),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(uiOrderNo(o.orderNo), style: const TextStyle(fontWeight: FontWeight.w700)),
                        const SizedBox(height: 4),
                        Text(
                          [
                            'Submitted: $submitted',
                            if (isCancelledList) 'Status: ${statusReadable(o.status)}',
                            if (!isCancelledList && !showClaim && completed.isNotEmpty) 'Completed: $completed',
                            if (!isCancelledList && !showClaim && o.loyaltyPointsEarned > 0)
                              'Loyalty earned: +${o.loyaltyPointsEarned} pts',
                            if (o.posCustomerLabel.trim().isNotEmpty) o.posCustomerLabel.trim(),
                            if (o.paymentMode.trim().isNotEmpty) o.paymentMode.toUpperCase(),
                          ].where((s) => s.isNotEmpty).join('\n'),
                          style: TextStyle(fontSize: 13, color: Colors.grey.shade800, height: 1.25),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      Text(
                        '₱${o.total.toStringAsFixed(2)}',
                        style: TextStyle(fontSize: 13, fontWeight: FontWeight.w400, color: Colors.grey.shade900),
                      ),
                      if (showClaim) ...[
                        const SizedBox(height: 6),
                        Wrap(
                          spacing: 6,
                          runSpacing: 4,
                          alignment: WrapAlignment.end,
                          children: [
                            TextButton(
                              onPressed: () async {
                                final yes = await showDialog<bool>(
                                  context: context,
                                  builder: (ctx) => AlertDialog(
                                    title: const Text('Cancel this walk-in order?'),
                                    content: Text('${uiOrderNo(o.orderNo)} will move to Cancelled.'),
                                    actions: [
                                      TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('No')),
                                      FilledButton(
                                        onPressed: () => Navigator.pop(ctx, true),
                                        child: const Text('Yes, cancel'),
                                      ),
                                    ],
                                  ),
                                );
                                if (yes != true || !context.mounted) return;
                                final err = await withCashierBlockingProgress<String?>(
                                  context,
                                  'Cancelling order…',
                                  widget.state.cancelWalkInOrder(o.id),
                                );
                                if (mounted && err != null) appSnack(context, err);
                              },
                              child: const Text('Cancel'),
                            ),
                            FilledButton(
                              onPressed: () async {
                                final yes = await showDialog<bool>(
                                  context: context,
                                  builder: (ctx) => AlertDialog(
                                    title: const Text('Mark order claimed?'),
                                    content: Text(
                                      'Confirm when ${uiOrderNo(o.orderNo)} has been picked up by the customer. It will move to Complete here and appear in Order history.',
                                    ),
                                    actions: [
                                      TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
                                      FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Confirm')),
                                    ],
                                  ),
                                );
                                if (yes != true || !context.mounted) return;
                                final err = await withCashierBlockingProgress<String?>(
                                  context,
                                  'Marking order complete…',
                                  widget.state.claimWalkInOrder(o.id),
                                );
                                if (mounted && err != null) appSnack(context, err);
                              },
                              child: const Text('Claim'),
                            ),
                          ],
                        ),
                      ] else
                        Padding(
                          padding: const EdgeInsets.only(top: 6),
                          child: Icon(
                            isCancelledList ? Icons.cancel_outlined : Icons.check_circle_outline,
                            color: isCancelledList ? Colors.redAccent : AppColors.success,
                          ),
                        ),
                    ],
                  ),
                ],
              ),
            ),
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
  /// Pending tab: `all` | `past_30` | `wait_payment` | `payment_insufficient` | `wait_balance`
  String _onlinePendingFilter = 'all';
  /// Preparing: `all` | `payment_confirmed` | `overpayment`
  String _onlinePreparingFilter = 'all';
  /// Delivered: `all` | `past_30` | `balance_proof` | `cash` | `gcash`
  String _onlineDeliveredFilter = 'all';
  /// Cancelled: `all` | `past_30`
  String _onlineCancelledFilter = 'all';
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

  PopupMenuItem<String> _filterMenuRow(BuildContext ctx, String value, String label, String current) {
    return PopupMenuItem<String>(
      value: value,
      child: Row(
        children: [
          if (current == value) Icon(Icons.check, size: 18, color: Theme.of(ctx).colorScheme.primary),
          if (current == value) const SizedBox(width: 4),
          Expanded(child: Text(label)),
        ],
      ),
    );
  }

  @override
  void initState() {
    super.initState();
    _fulTab = TabController(length: 5, vsync: this);
    _fulTab.addListener(() {
      if (mounted) setState(() {});
    });
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
        showStaffPosNotification('Online orders', '${uiOrderNo(o.orderNo)} is still awaiting cashier action.');
      } else if (mins >= 5 && st < 1) {
        _pendingAlertStage[o.id] = 1;
        showStaffPosNotification('Online orders', '${uiOrderNo(o.orderNo)} — please review when ready.');
      }
    }
  }

  static const _stages = [
    'PENDING_CASHIER',
    'IN_PREPARATION',
    'OUT_FOR_DELIVERY',
    'DELIVERED',
  ];

  bool _isCancelledOnline(OrderData o) => o.status.toUpperCase().contains('CANCEL');

  bool get _onlineFilterIconAccent {
    switch (_fulTab.index) {
      case 0:
        return _onlinePendingFilter != 'all';
      case 1:
        return _onlinePreparingFilter != 'all';
      case 2:
        return false;
      case 3:
        return _onlineDeliveredFilter != 'all';
      case 4:
        return _onlineCancelledFilter != 'all';
      default:
        return false;
    }
  }

  List<OrderData> _forIndex(int i) {
    List<OrderData> base;
    if (i == 4) {
      base = widget.state.cashierOnlineOrders.where(_isCancelledOnline).toList();
    } else {
      final want = _stages[i];
      base = widget.state.cashierOnlineOrders
          .where((o) => !_isCancelledOnline(o))
          .where((o) => o.fulfillmentStage.toUpperCase() == want)
          .toList();
    }
    var out = base.where((o) {
      final q = _search.trim().toLowerCase();
      if (q.isEmpty) return true;
      return o.orderNo.toLowerCase().contains(q) ||
          uiOrderNo(o.orderNo).toLowerCase().contains(q) ||
          (o.userEmail ?? '').toLowerCase().contains(q) ||
          cashierCustomerLabel(o).toLowerCase().contains(q) ||
          statusReadable(o.status).toLowerCase().contains(q) ||
          statusReadableForOrder(o).toLowerCase().contains(q);
    }).toList();

    bool extra(OrderData o) {
      switch (i) {
        case 0:
          return orderMatchesCashierOnlinePendingFilter(o, _onlinePendingFilter);
        case 1:
          return orderMatchesCashierOnlinePreparingFilter(o, _onlinePreparingFilter);
        case 2:
          return true;
        case 3:
          return orderMatchesCashierOnlineDeliveredFilter(o, _onlineDeliveredFilter);
        case 4:
          if (_onlineCancelledFilter == 'past_30') return isWithinPast30Days(o.createdAt);
          return true;
        default:
          return true;
      }
    }

    out = out.where(extra).toList();
    if (i == 0) {
      out.sort((a, b) {
        final c = cashierOnlinePendingSortPriority(a).compareTo(cashierOnlinePendingSortPriority(b));
        if (c != 0) return c;
        return b.createdAt.compareTo(a.createdAt);
      });
    }
    return out;
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: widget.state,
      builder: (context, _) {
        return Column(
          children: [
            if (widget.state.cashierDataLoadError != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    widget.state.cashierDataLoadError!,
                    style: TextStyle(color: Colors.red.shade800, fontWeight: FontWeight.w600),
                  ),
                ),
              ),
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 12, 12, 6),
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      decoration: const InputDecoration(
                        hintText: 'SEARCH ORDER NO / EMAIL / STATUS',
                        isDense: true,
                        border: OutlineInputBorder(),
                      ),
                      onChanged: (v) => setState(() => _search = v),
                    ),
                  ),
                  if (_fulTab.index != 2)
                    PopupMenuButton<String>(
                      tooltip: 'Filter',
                      icon: Icon(
                        Icons.filter_list,
                        color: _onlineFilterIconAccent ? AppColors.accent : null,
                      ),
                      onSelected: (v) {
                        setState(() {
                          switch (_fulTab.index) {
                            case 0:
                              _onlinePendingFilter = v;
                              break;
                            case 1:
                              _onlinePreparingFilter = v;
                              break;
                            case 3:
                              _onlineDeliveredFilter = v;
                              break;
                            case 4:
                              _onlineCancelledFilter = v;
                              break;
                          }
                        });
                      },
                      itemBuilder: (ctx) {
                        switch (_fulTab.index) {
                          case 0:
                            return [
                              _filterMenuRow(ctx, 'all', 'All', _onlinePendingFilter),
                              _filterMenuRow(ctx, 'past_30', 'Past 30 days', _onlinePendingFilter),
                              _filterMenuRow(ctx, 'wait_payment', 'Waiting for Payment Confirmation', _onlinePendingFilter),
                              _filterMenuRow(ctx, 'payment_insufficient', 'Payment Insufficient', _onlinePendingFilter),
                              _filterMenuRow(
                                ctx,
                                'wait_balance',
                                'Waiting for Balance Payment Confirmation',
                                _onlinePendingFilter,
                              ),
                            ];
                          case 1:
                            return [
                              _filterMenuRow(ctx, 'all', 'All', _onlinePreparingFilter),
                              _filterMenuRow(ctx, 'payment_confirmed', 'Payment Confirmed', _onlinePreparingFilter),
                              _filterMenuRow(ctx, 'overpayment', 'Overpayment', _onlinePreparingFilter),
                            ];
                          case 3:
                            return [
                              _filterMenuRow(ctx, 'all', 'All', _onlineDeliveredFilter),
                              _filterMenuRow(ctx, 'past_30', 'Past 30 days', _onlineDeliveredFilter),
                              _filterMenuRow(ctx, 'balance_proof', 'With balance proof of payment', _onlineDeliveredFilter),
                              _filterMenuRow(ctx, 'cash', 'Cash', _onlineDeliveredFilter),
                              _filterMenuRow(ctx, 'gcash', 'GCash', _onlineDeliveredFilter),
                            ];
                          case 4:
                            return [
                              _filterMenuRow(ctx, 'all', 'All', _onlineCancelledFilter),
                              _filterMenuRow(ctx, 'past_30', 'Past 30 days', _onlineCancelledFilter),
                            ];
                          default:
                            return const [];
                        }
                      },
                    ),
                ],
              ),
            ),
            Material(
              color: Colors.white,
              elevation: 2,
              shadowColor: Colors.black26,
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
                  Tab(text: 'Cancelled'),
                ],
              ),
            ),
            Expanded(
              child: TabBarView(
                controller: _fulTab,
                children: List.generate(5, (idx) {
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
                              final st = o.status.toUpperCase();
                              final fu = o.fulfillmentStage.toUpperCase();
                              final showLoyalty = o.loyaltyPointsEarned > 0 &&
                                  (st.contains('ORDER CONFIRMED') ||
                                      st.contains('OVERPAYMENT') ||
                                      fu == 'DELIVERED');
                              final hasBalProof =
                                  orderPaymentReferenceBalance(o) != null || orderHasBalancePaymentProofImage(o);
                              final track = o.deliveryTrackingUrl.trim();
                              return Card(
                                elevation: 2,
                                color: Colors.white,
                                shadowColor: Colors.black26,
                                child: ListTile(
                                  leading: o.balanceProofPendingReview
                                      ? Icon(Icons.notifications_active, color: Colors.deepOrange.shade700)
                                      : null,
                                  title: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      Align(
                                        alignment: Alignment.centerLeft,
                                        child: Container(
                                          constraints: const BoxConstraints(maxWidth: 220),
                                          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                                          decoration: BoxDecoration(
                                            color: _statusBadgeBg(o.status),
                                            borderRadius: BorderRadius.circular(999),
                                          ),
                                          child: Text(
                                            statusReadableForOrder(o),
                                            maxLines: 2,
                                            overflow: TextOverflow.ellipsis,
                                            style: TextStyle(
                                              fontSize: 10.5,
                                              fontWeight: FontWeight.w700,
                                              color: _statusBadgeFg(o.status),
                                            ),
                                          ),
                                        ),
                                      ),
                                      const SizedBox(height: 6),
                                      Text(uiOrderNo(o.orderNo), style: const TextStyle(fontWeight: FontWeight.w700)),
                                    ],
                                  ),
                                  subtitle: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Text(
                                        '${cashierCustomerLabel(o)}'
                                        '${showLoyalty ? '\nLoyalty: +${o.loyaltyPointsEarned} pts' : ''}',
                                        style: TextStyle(fontSize: 13, color: Colors.grey.shade800, height: 1.25),
                                      ),
                                      if (idx == 2 && track.isNotEmpty) ...[
                                        const SizedBox(height: 8),
                                        InkWell(
                                          onTap: () async {
                                            final u = Uri.tryParse(track);
                                            if (u != null && await canLaunchUrl(u)) {
                                              await launchUrl(u, mode: LaunchMode.externalApplication);
                                            }
                                          },
                                          child: Text(
                                            track,
                                            style: TextStyle(
                                              color: Colors.blue.shade800,
                                              decoration: TextDecoration.underline,
                                              fontSize: 12.5,
                                            ),
                                          ),
                                        ),
                                      ],
                                      if (hasBalProof) ...[
                                        if (orderPaymentReferenceBalance(o) != null)
                                          Text(
                                            'Balance ref: ${orderPaymentReferenceBalance(o)}',
                                            style: TextStyle(fontSize: 12, color: Colors.grey.shade800),
                                          ),
                                        if (orderHasBalancePaymentProofImage(o))
                                          TextButton(
                                            style: TextButton.styleFrom(
                                              padding: EdgeInsets.zero,
                                              minimumSize: Size.zero,
                                              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                                            ),
                                            onPressed: () {
                                              try {
                                                final bytes = base64Decode(o.supplementalPaymentProofBase64!.trim());
                                                showProofFullScreen(
                                                  context,
                                                  Uint8List.fromList(bytes),
                                                  title: 'Balance payment proof',
                                                );
                                              } catch (_) {
                                                appSnack(context, 'Could not display image');
                                              }
                                            },
                                            child: const Text('View balance payment proof'),
                                          ),
                                      ],
                                      if (orderPaymentReferenceInitial(o) != null)
                                        Text(
                                          'Payment ref: ${orderPaymentReferenceInitial(o)}',
                                          style: TextStyle(fontSize: 12, color: Colors.grey.shade800),
                                        ),
                                    ],
                                  ),
                                  trailing: Text(
                                    '₱${o.total.toStringAsFixed(2)}',
                                    style: const TextStyle(fontWeight: FontWeight.w600),
                                  ),
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

  Widget _buildCancelledOnlineDetail(BuildContext context, OrderData o) {
    final pm = (o.paymentMode.isEmpty ? 'GCASH ONLY' : o.paymentMode).toUpperCase();
    final track = o.deliveryTrackingUrl.trim();
    return Scaffold(
      appBar: AppBar(
        backgroundColor: Colors.black87,
        foregroundColor: Colors.white,
        title: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          decoration: BoxDecoration(color: AppColors.brand, borderRadius: BorderRadius.circular(10)),
          child: Text(
            'Cancelled + ${uiOrderNo(o.orderNo)}',
            textAlign: TextAlign.center,
            style: const TextStyle(color: AppColors.ink, fontWeight: FontWeight.w800, fontSize: 12),
          ),
        ),
        centerTitle: true,
      ),
      body: ListView(
        padding: const EdgeInsets.all(12),
        children: [
          _OrderNoCard(displayNo: uiOrderNo(o.orderNo)),
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
            expanded: true,
            onToggle: () {},
            hideToggleIcon: true,
            child: Column(
              children: [
                LockedField(label: 'NAME', value: o.deliveryName.isEmpty ? '—' : o.deliveryName),
                LockedField(label: 'CONTACT NUMBER', value: o.deliveryContact.isEmpty ? '—' : o.deliveryContact),
                LockedField(label: 'DELIVERY ADDRESS', value: o.deliveryAddress.isEmpty ? '—' : o.deliveryAddress),
                LockedField(label: 'TIME OF DELIVERY', value: o.deliveryTime.isEmpty ? 'NOW' : o.deliveryTime),
                if (track.isNotEmpty) LockedField(label: 'TRACKING LINK', value: track),
              ],
            ),
          ),
          const SizedBox(height: 10),
          ToggleSection(
            title: 'PAYMENT',
            expanded: true,
            onToggle: () {},
            hideToggleIcon: true,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                LockedField(label: 'PAYMENT METHOD', value: pm),
                LockedField(
                  label: 'AMOUNT RECEIVED (first)',
                  value: (o.cashierAmountReceived ?? 0).toStringAsFixed(2),
                ),
                if (o.cashierSecondaryAmountReceived != null && o.cashierSecondaryAmountReceived! > 0)
                  LockedField(
                    label: 'ADDITIONAL AMOUNT (balance)',
                    value: o.cashierSecondaryAmountReceived!.toStringAsFixed(2),
                  ),
                LockedField(label: 'AMOUNT DUE', value: o.total.toStringAsFixed(2)),
                const SizedBox(height: 10),
                ...cashierPaymentProofAndReferenceSection(context, o),
              ],
            ),
          ),
          const SizedBox(height: 10),
          ToggleSection(
            title: 'YOUR TRAY',
            expanded: true,
            onToggle: () {},
            hideToggleIcon: true,
            child: o.lines.isEmpty
                ? const Text('No dishes on file.')
                : Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: o.lines
                        .map(
                          (l) => ListTile(
                            dense: true,
                            title: Text(l.itemName),
                            subtitle: Text(l.dip.isEmpty ? '—' : '${l.dip} × ${l.dipQty}'),
                            trailing: Text('x${l.qty}  ₱${orderLineSubtotal(l).toStringAsFixed(2)}'),
                          ),
                        )
                        .toList(),
                  ),
          ),
          const SizedBox(height: 10),
          ToggleSection(
            title: 'ORDER NOTE',
            expanded: true,
            onToggle: () {},
            hideToggleIcon: true,
            child: Text(o.note.isEmpty ? '—' : o.note),
          ),
        ],
      ),
    );
  }

  String _onlineDetailHeaderLabel(OrderData o) {
    final st = o.status.toUpperCase();
    if (st.contains('CANCEL')) return 'Cancelled + ${uiOrderNo(o.orderNo)}';
    switch (o.fulfillmentStage.toUpperCase()) {
      case 'PENDING_CASHIER':
        return 'Pending';
      case 'IN_PREPARATION':
        return 'Preparing';
      case 'OUT_FOR_DELIVERY':
        return 'For Delivery';
      case 'DELIVERED':
        return 'Delivered + ${uiOrderNo(o.orderNo)}';
      default:
        return 'Order';
    }
  }

  Future<void> _submitInsufficientPayment(
    OrderData o, {
    required bool forBalance,
    required double? initialAmount,
    required double? balanceAmount,
  }) async {
    if (forBalance && balanceAmount == null) {
      appSnack(context, 'Enter the additional amount received for the balance.');
      return;
    }
    if (!forBalance && initialAmount == null) {
      appSnack(context, 'Enter a valid amount.');
      return;
    }
    if (!await _confirmDialog('Insufficient payment?', 'Notify the customer that payment is short?')) return;
    final err = await withCashierBlockingProgress<String?>(
      context,
      'Updating payment…',
      widget.state.cashierReviewOrder(
        orderId: o.id,
        action: 'insufficient',
        amountReceived: forBalance ? null : initialAmount,
        supplementalAmountReceived: forBalance ? balanceAmount : null,
      ),
    );
    if (!context.mounted) return;
    if (err != null) {
      appSnack(context, err);
      return;
    }
    appSnack(context, 'Customer notified (insufficient payment)');
    Navigator.pop(context);
  }

  Future<void> _submitOverpayment(
    OrderData o, {
    required bool forBalance,
    required double? initialAmount,
    required double? balanceAmount,
  }) async {
    if (forBalance && balanceAmount == null) {
      appSnack(context, 'Enter the additional amount received for the balance.');
      return;
    }
    if (!forBalance && initialAmount == null) {
      appSnack(context, 'Enter a valid amount.');
      return;
    }
    if (!await _confirmDialog('Overpayment?', 'Confirm order with overpayment notice?')) return;
    final err = await withCashierBlockingProgress<String?>(
      context,
      'Updating payment…',
      widget.state.cashierReviewOrder(
        orderId: o.id,
        action: 'overpayment',
        amountReceived: forBalance ? null : initialAmount,
        supplementalAmountReceived: forBalance ? balanceAmount : null,
      ),
    );
    if (!context.mounted) return;
    if (err != null) {
      appSnack(context, err);
      return;
    }
    appSnack(context, 'Customer notified (overpayment)');
    Navigator.pop(context);
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
        if (o.status.toUpperCase().contains('CANCEL')) {
          return _buildCancelledOnlineDetail(context, o);
        }
        final proofOk = orderHasPaymentOnFile(o);
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
        final hasSupProof =
            orderPaymentReferenceBalance(o) != null || orderHasBalancePaymentProofImage(o);
        final awaitingBalanceConfirm =
            statusUp.contains('WAITING FOR BALANCE') || statusUp.contains('BALANCE PAYMENT CONFIRMATION');
        final pendingBalReview = hasSupProof && (o.balanceProofPendingReview || awaitingBalanceConfirm);
        final waitingCustomerBalance = insufficientStatus && !hasSupProof && stage == 'PENDING_CASHIER';
        final firstPaid = o.cashierAmountReceived ?? 0;
        final balanceDue = o.total > firstPaid ? o.total - firstPaid : 0.0;
        final entered = parsed;
        final amountClassified = entered != null;
        final exactAmount = amountClassified && (entered - o.total).abs() <= 0.009;
        final insufficientAmount = amountClassified && entered + 0.009 < o.total;
        final overAmount = amountClassified && entered - o.total > 0.009;
        final balanceClassified = parsedSupp != null;
        final exactBalance = pendingBalReview && balanceClassified && (parsedSupp - balanceDue).abs() <= 0.009;
        final insufficientBalance = pendingBalReview && balanceClassified && parsedSupp + 0.009 < balanceDue;
        final overBalance = pendingBalReview && balanceClassified && parsedSupp - balanceDue > 0.009;
        final showInsufficientBtn = pendingBalReview ? insufficientBalance : insufficientAmount;
        final showOverBtn = pendingBalReview ? overBalance : overAmount;

        final paymentAtTop = stage == 'PENDING_CASHIER';
        final forDeliveryAtTop = stage == 'IN_PREPARATION';
        final trackingAtTop = stage == 'OUT_FOR_DELIVERY';

        return Scaffold(
      appBar: AppBar(
        backgroundColor: Colors.black87,
        foregroundColor: Colors.white,
        title: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          decoration: BoxDecoration(color: AppColors.brand, borderRadius: BorderRadius.circular(10)),
          child: Text(
            _onlineDetailHeaderLabel(o),
            textAlign: TextAlign.center,
            style: const TextStyle(color: AppColors.ink, fontWeight: FontWeight.w800, fontSize: 12),
          ),
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
                              helperText: 'Adjust if needed, then mark insufficient or overpayment.',
                            ),
                            onChanged: (_) => setState(() {}),
                          ),
                        ] else ...[
                          TextField(
                            controller: amountReceived,
                            keyboardType: TextInputType.number,
                            readOnly: waitingCustomerBalance,
                            decoration: InputDecoration(
                              labelText: 'AMOUNT RECEIVED',
                              helperText: waitingCustomerBalance
                                  ? 'Waiting for customer balance proof in the app.'
                                  : (insufficientStatus
                                      ? 'Adjust if needed, then mark insufficient or overpayment.'
                                      : null),
                            ),
                            onChanged: (_) => setState(() {}),
                          ),
                        ],
                        LockedField(
                          label: pendingBalReview ? 'REMAINING BALANCE DUE' : 'AMOUNT DUE',
                          value: pendingBalReview ? balanceDue.toStringAsFixed(2) : o.total.toStringAsFixed(2),
                        ),
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
                        ...cashierPaymentProofAndReferenceSection(context, o),
                        if (!paymentLocked && !waitingCustomerBalance) ...[
                          const SizedBox(height: 8),
                          FilledButton(
                            style: FilledButton.styleFrom(backgroundColor: AppColors.accent, foregroundColor: Colors.white),
                            onPressed: showInsufficientBtn
                                ? () => _submitInsufficientPayment(
                                      o,
                                      forBalance: pendingBalReview,
                                      initialAmount: ar,
                                      balanceAmount: parsedSupp,
                                    )
                                : null,
                            child: const Text('INSUFFICIENT PAYMENT'),
                          ),
                          const SizedBox(height: 8),
                          FilledButton(
                            style: FilledButton.styleFrom(backgroundColor: AppColors.brand, foregroundColor: AppColors.ink),
                            onPressed: showOverBtn
                                ? () => _submitOverpayment(
                                      o,
                                      forBalance: pendingBalReview,
                                      initialAmount: ar,
                                      balanceAmount: parsedSupp,
                                    )
                                : null,
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
                              final err = await withCashierBlockingProgress<String?>(
                                context,
                                'Saving tracking link…',
                                widget.state.cashierPatchFulfillment(
                                  orderId: o.id,
                                  fulfillmentStage: 'OUT_FOR_DELIVERY',
                                  deliveryTrackingUrl: trackingUrl.text.trim(),
                                ),
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
                        Builder(
                          builder: (ctx) {
                            final t = o.deliveryTrackingUrl.trim();
                            if (t.isEmpty) return const SelectableText('—');
                            final u = Uri.tryParse(t);
                            if (u != null && u.hasScheme) {
                              return InkWell(
                                onTap: () async {
                                  if (await canLaunchUrl(u)) {
                                    await launchUrl(u, mode: LaunchMode.externalApplication);
                                  }
                                },
                                child: Text(
                                  t,
                                  style: TextStyle(
                                    color: Colors.blue.shade800,
                                    decoration: TextDecoration.underline,
                                  ),
                                ),
                              );
                            }
                            return SelectableText(t);
                          },
                        ),
                        const SizedBox(height: 10),
                        FilledButton(
                          onPressed: () async {
                            if (!await _confirmDialog('Mark delivered?', 'Mark this order as delivered?')) return;
                            final err = await withCashierBlockingProgress<String?>(
                              context,
                              'Marking delivered…',
                              widget.state.cashierPatchFulfillment(
                                orderId: o.id,
                                fulfillmentStage: 'DELIVERED',
                                deliveryTrackingUrl: o.deliveryTrackingUrl,
                              ),
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
                _OrderNoCard(displayNo: uiOrderNo(o.orderNo)),
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
                              helperText: 'Adjust if needed, then mark insufficient or overpayment.',
                            ),
                            onChanged: (_) => setState(() {}),
                          ),
                        ] else ...[
                          TextField(
                            controller: amountReceived,
                            keyboardType: TextInputType.number,
                            readOnly: waitingCustomerBalance,
                            decoration: InputDecoration(
                              labelText: 'AMOUNT RECEIVED',
                              helperText: waitingCustomerBalance
                                  ? 'Waiting for customer balance proof in the app.'
                                  : (insufficientStatus
                                      ? 'Adjust if needed, then mark insufficient or overpayment.'
                                      : null),
                            ),
                            onChanged: (_) => setState(() {}),
                          ),
                        ],
                        LockedField(
                          label: pendingBalReview ? 'REMAINING BALANCE DUE' : 'AMOUNT DUE',
                          value: pendingBalReview ? balanceDue.toStringAsFixed(2) : o.total.toStringAsFixed(2),
                        ),
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
                        ...cashierPaymentProofAndReferenceSection(context, o),
                        if (!paymentLocked && !waitingCustomerBalance) ...[
                          const SizedBox(height: 8),
                          FilledButton(
                            style: FilledButton.styleFrom(backgroundColor: AppColors.accent, foregroundColor: Colors.white),
                            onPressed: showInsufficientBtn
                                ? () => _submitInsufficientPayment(
                                      o,
                                      forBalance: pendingBalReview,
                                      initialAmount: ar,
                                      balanceAmount: parsedSupp,
                                    )
                                : null,
                            child: const Text('INSUFFICIENT PAYMENT'),
                          ),
                          const SizedBox(height: 8),
                          FilledButton(
                            style: FilledButton.styleFrom(backgroundColor: AppColors.brand, foregroundColor: AppColors.ink),
                            onPressed: showOverBtn
                                ? () => _submitOverpayment(
                                      o,
                                      forBalance: pendingBalReview,
                                      initialAmount: ar,
                                      balanceAmount: parsedSupp,
                                    )
                                : null,
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
                            subtitle: Text(
                              l.dip.isEmpty ? '—' : '${l.dip} × ${l.dipQty}',
                            ),
                            trailing: Text('x${l.qty}  ₱${orderLineSubtotal(l).toStringAsFixed(2)}'),
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
                        final err = await withCashierBlockingProgress<String?>(
                          context,
                          'Sending follow-up…',
                          widget.state.cashierRemindInsufficientOrder(orderId: o.id),
                        );
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
                  SummaryLine('Remaining balance due', '₱${balanceDue.toStringAsFixed(2)}'),
                  SummaryLine('Order total', '₱${o.total.toStringAsFixed(2)}', isTotal: true),
                ],
                actionLabel: 'CONFIRM ORDER',
                onAction: exactBalance
                    ? () async {
                        if (supplementalAmount.text.trim().isEmpty || parsedSupp == null) {
                          appSnack(context, 'Enter the additional amount received for the balance.');
                          return;
                        }
                        final suppAmt = parsedSupp;
                        if (suppAmt < 0) return;
                        if ((suppAmt - balanceDue).abs() > 0.009) {
                          appSnack(context, 'Additional amount must exactly match the remaining balance due.');
                          return;
                        }
                        if (!await _confirmDialog(
                          'Confirm order?',
                          'Confirm ${uiOrderNo(o.orderNo)} with an additional ₱${suppAmt.toStringAsFixed(2)} recorded toward payment?',
                        )) {
                          return;
                        }
                        final err = await withCashierBlockingProgress<String?>(
                          context,
                          'Confirming order…',
                          widget.state.cashierReviewOrder(
                            orderId: o.id,
                            action: 'confirm',
                            supplementalAmountReceived: suppAmt,
                          ),
                        );
                        if (!context.mounted) return;
                        if (err != null) {
                          appSnack(context, err);
                          return;
                        }
                        appSnack(context, 'Order confirmed — customer notified');
                        Navigator.pop(context);
                      }
                    : null,
              )
            else
              SummaryFooter(
                lines: [
                  SummaryLine('TOTAL', '₱${o.total.toStringAsFixed(2)}', isTotal: true),
                ],
                actionLabel: 'CONFIRM ORDER',
                onAction: exactAmount
                    ? () async {
                        if (amountReceived.text.trim().isEmpty) {
                          appSnack(context, 'Enter amount received.');
                          return;
                        }
                        if (parsed == null) {
                          appSnack(context, 'Enter a valid amount.');
                          return;
                        }
                        if ((ar! - o.total).abs() > 0.009) {
                          appSnack(context, 'Amount received must exactly match the amount due.');
                          return;
                        }
                        if (isGcash && !proofOk) {
                          appSnack(context, 'Customer payment proof must be received before confirming.');
                          return;
                        }
                        if (!await _confirmDialog(
                          'Confirm order?',
                          'Confirm ${uiOrderNo(o.orderNo)} for ₱${o.total.toStringAsFixed(2)} and notify the customer?',
                        )) {
                          return;
                        }
                        final err = await withCashierBlockingProgress<String?>(
                          context,
                          'Confirming order…',
                          widget.state.cashierReviewOrder(
                            orderId: o.id,
                            action: 'confirm',
                            amountReceived: ar,
                          ),
                        );
                        if (!context.mounted) return;
                        if (err != null) {
                          appSnack(context, err);
                          return;
                        }
                        appSnack(context, 'Order confirmed — customer notified');
                        Navigator.pop(context);
                      }
                    : null,
              ),
          ],
        ],
      ),
    );
      },
    );
  }
}
