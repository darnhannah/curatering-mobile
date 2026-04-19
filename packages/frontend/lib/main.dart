import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:http/http.dart' as http;
import 'package:image_picker/image_picker.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:url_launcher/url_launcher.dart';

/// When `true` (pass `--dart-define=POS_LOGIN=true`), login hides sign-up — for cashier POS builds.
const bool kPosLoginBuild = bool.fromEnvironment('POS_LOGIN', defaultValue: false);

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final prefs = await SharedPreferences.getInstance();
  final savedApiBase = prefs.getString('api_base');
  final savedThemeMode = prefs.getString('theme_mode');
  runApp(CurateringApp(savedApiBase: savedApiBase, savedThemeMode: savedThemeMode));
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

class CurateringApp extends StatefulWidget {
  const CurateringApp({super.key, this.savedApiBase, this.savedThemeMode});

  /// Loaded from SharedPreferences in [main] before the first frame (so API calls never briefly use localhost).
  final String? savedApiBase;
  /// `'light'` / `'dark'` from [SharedPreferences]; default is light.
  final String? savedThemeMode;

  @override
  State<CurateringApp> createState() => _CurateringAppState();
}

class _CurateringAppState extends State<CurateringApp> {
  late final AppState appState;

  @override
  void initState() {
    super.initState();
    appState = AppState(savedApiBase: widget.savedApiBase, savedThemeMode: widget.savedThemeMode);
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: appState,
      builder: (context, _) {
        return MaterialApp(
          debugShowCheckedModeBanner: false,
          title: "Macrina's Kitchen and Catering",
          theme: buildAppLightTheme(),
          darkTheme: buildAppDarkTheme(),
          themeMode: appState.themeMode,
          home: appState.userEmail == null
              ? AuthScreen(state: appState, cashierMode: kPosLoginBuild)
              : _PostLoginWelcomeScope(
                  state: appState,
                  child: appState.isCashier
                      ? PosShellScreen(state: appState)
                      : RestaurantMenuScreen(state: appState),
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

/// Local Node backend is HTTP-only; [https] to these hosts breaks TLS handshakes.
bool _devBackendHttpHost(String host) {
  final h = host.toLowerCase();
  if (h == 'localhost' || h == '127.0.0.1' || h == '10.0.2.2') return true;
  if (h.startsWith('192.168.')) return true;
  return false;
}

/// Order: saved preference from install → `--dart-define=API_BASE` → localhost default.
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

/// OpenStreetMap Nominatim requires a descriptive User-Agent.
const String kNominatimUserAgent = 'CurateringMobile/1.0 (support@macrina.local)';

String resolveInitialApiBase(String? savedFromPrefs) {
  final s = savedFromPrefs?.trim();
  if (s != null && s.isNotEmpty) {
    return normalizeApiBase(s);
  }
  const env = String.fromEnvironment('API_BASE', defaultValue: '');
  if (env.isNotEmpty) {
    return normalizeApiBase(env);
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

class AppColors {
  static const brand = Color(0xFFFFC233);
  static const canvas = Color(0xFFF1F1F1);
  static const accent = Color(0xFFEE4B3C);
  static const border = Color(0xFF9B8F82);
  static const success = Color(0xFF2FCB76);
  static const ink = Color(0xFF201B16);
}

class MenuItemData {
  const MenuItemData({
    required this.id,
    required this.name,
    required this.description,
    required this.price,
    required this.dips,
    this.category = '',
    this.imageBase64,
  });

  final String id;
  final String name;
  final String description;
  final double price;
  final List<String> dips;
  final String category;
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

  /// Bucket for POS filter chips: ALL uses empty filter; otherwise keys match display labels lowercased.
  String get restaurantMenuBucket {
    final c = category.toLowerCase().trim();
    if (c.contains('drink') || c.contains('beverage')) return 'drinks';
    if (c.contains('sandwich')) return 'sandwiches';
    if (c.contains('pasta')) return 'pasta';
    if (c.contains('silog')) return 'silog meals';
    if (c.contains('rice')) return 'rice meals';
    return 'others';
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
  });

  String fullName;
  String contactNumber;
  String deliveryAddress;
  bool deliveryMapConfirmed;
  double? deliveryLat;
  double? deliveryLng;
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
  });

  final int id;
  final String orderNo;
  final String status;
  final double total;
  final DateTime createdAt;
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
  );
}

bool orderLooksCompleted(OrderData o) {
  if (o.fulfillmentStage.toUpperCase() == 'DELIVERED') return true;
  final u = o.status.toUpperCase();
  return u.contains('COMPLETE') ||
      u.contains('DELIVERED') ||
      u.contains('DONE') ||
      u.contains('CLOSED');
}

bool customerOrderPendingTab(OrderData o) {
  if (orderLooksCompleted(o)) return false;
  final u = o.status.toUpperCase();
  return u.contains('WAITING FOR ORDER CONFIRMATION') ||
      u.contains('WAITING FOR ORDER') ||
      u.contains('PAYMENT INSUFFICIENT') ||
      u.contains('INSUFFICIENT');
}

bool customerOrderConfirmedTab(OrderData o) {
  if (orderLooksCompleted(o)) return false;
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
  });

  final int id;
  final String inquiryNo;
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

  bool get isWaiting => status.toUpperCase() == 'SUBMITTED' || status.toUpperCase() == 'PENDING';
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

class AppState extends ChangeNotifier {
  AppState({String? savedApiBase, String? savedThemeMode})
      : apiBase = resolveInitialApiBase(savedApiBase),
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
  /// `customer` or `cashier` from login API.
  String userRole = 'customer';
  String cashierDisplayName = '';
  final List<OrderData> cashierOnlineOrders = [];
  final List<OrderData> cashierOrderHistory = [];
  final List<OrderData> cashierWalkInPreparing = [];
  final List<OrderData> cashierWalkInComplete = [];
  bool showLoginWelcomeDialog = false;

  bool get isCashier => userRole == 'cashier';

  void setApiBase(String value) {
    apiBase = normalizeApiBase(value);
    notifyListeners();
    SharedPreferences.getInstance().then((p) => p.setString('api_base', apiBase));
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
        await loadMenu();
        await loadCashierOnlineOrders();
        await loadCashierWalkInQueues();
      } else {
        await Future.wait([
          loadMenu(),
          loadSetMenus(),
          loadProfile(),
          loadOrders(),
          loadInquiries(),
        ]);
      }
      showLoginWelcomeDialog = true;
      notifyListeners();
      return null;
    } catch (e) {
      return describeApiNetworkError(e, normalizeApiBase(apiBase));
    }
  }

  /// Returns null on success.
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

  void logout() {
    userEmail = null;
    loginPassword = '';
    userRole = 'customer';
    cashierDisplayName = '';
    cashierOnlineOrders.clear();
    cashierOrderHistory.clear();
    cashierWalkInPreparing.clear();
    cashierWalkInComplete.clear();
    showLoginWelcomeDialog = false;
    profile = ProfileData();
    menu.clear();
    tray.clear();
    orders.clear();
    inquiries.clear();
    setMenus.clear();
    checkoutNote = '';
    notifyListeners();
  }

  Uri _uri(String path, [Map<String, String>? query]) =>
      Uri.parse('${normalizeApiBase(apiBase)}$path').replace(queryParameters: query);

  Future<void> loadMenu() async {
    final res = await http.get(_uri('/api/mobile/menu'));
    if (res.statusCode != 200) return;
    final List<dynamic> body = jsonDecode(res.body) as List<dynamic>;
    menu
      ..clear()
      ..addAll(
        body.map((e) {
          final map = e as Map<String, dynamic>;
          final dipValues = map['dips'] is List ? (map['dips'] as List<dynamic>).map((d) => '$d').toList() : <String>[];
          return MenuItemData(
            id: '${map['id']}',
            name: '${map['name']}',
            description: '${map['description']}',
            price: jsonToDouble(map['price']),
            dips: dipValues,
            category: '${map['category'] ?? ''}',
            imageBase64: map['image_base64'] != null ? '${map['image_base64']}' : null,
          );
        }),
      );
    notifyListeners();
  }

  Future<void> loadSetMenus() async {
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
    notifyListeners();
  }

  Future<void> loadProfile() async {
    if (userEmail == null) return;
    final res = await http.get(_uri('/api/mobile/profile', {'user_email': userEmail!}));
    if (res.statusCode != 200) return;
    final map = jsonDecode(res.body) as Map<String, dynamic>;
    profile = ProfileData(
      fullName: '${map['full_name'] ?? ''}',
      contactNumber: '${map['contact_number'] ?? ''}',
      deliveryAddress: '${map['delivery_address'] ?? ''}',
      deliveryMapConfirmed: jsonToBool(map['delivery_map_confirmed']),
      deliveryLat: map['delivery_lat'] != null ? jsonToDouble(map['delivery_lat']) : null,
      deliveryLng: map['delivery_lng'] != null ? jsonToDouble(map['delivery_lng']) : null,
    );
    notifyListeners();
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
      }),
    );
    if (res.statusCode == 200) {
      profile = updated;
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
  }

  void changeQty(CartItem item, int delta) {
    item.qty += delta;
    if (item.qty <= 0) {
      tray.remove(item);
    }
    notifyListeners();
  }

  void clearTray() {
    tray.clear();
    notifyListeners();
  }

  double get subtotal => tray.fold<double>(0, (sum, i) => sum + (i.qty * i.menu.price));

  Future<SubmitOrderResult> submitOrder() async {
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
        status: 'WAITING FOR ORDER CONFIRMATION',
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
        deliveryTime: 'NOW',
        orderSource: 'MOBILE_APP',
        fulfillmentStage: 'PENDING_CASHIER',
      );
      checkoutNote = '';
      clearTray();
      try {
        await loadOrders();
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

  Future<void> uploadPaymentProof(int orderId, XFile file) async {
    final encoded = base64Encode(await file.readAsBytes());
    await http.patch(
      _uri('/api/mobile/orders/$orderId/payment'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({'payment_proof': encoded}),
    );
    await loadOrders();
  }

  Future<void> loadOrders() async {
    if (userEmail == null) return;
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
    notifyListeners();
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
      await loadInquiries();
      notifyListeners();
      return null;
    } catch (e) {
      return describeApiNetworkError(e, normalizeApiBase(apiBase));
    }
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

  Future<void> loadInquiries() async {
    if (userEmail == null) return;
    final res = await http.get(_uri('/api/mobile/inquiries', {'user_email': userEmail!}));
    if (res.statusCode != 200) return;
    final List<dynamic> body = jsonDecode(res.body) as List<dynamic>;
    final parsed = <InquiryRecord>[];
    for (final e in body) {
      try {
        final map = e as Map<String, dynamic>;
        List<String> dishes = [];
        final sd = map['selected_dishes'];
        if (sd is String) {
          try {
            final dec = jsonDecode(sd);
            if (dec is List) dishes = dec.map((x) => '$x').toList();
          } catch (_) {}
        } else if (sd is List) {
          dishes = sd.map((x) => '$x').toList();
        }
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
          ),
        );
      } catch (_) {}
    }
    inquiries
      ..clear()
      ..addAll(parsed);
    notifyListeners();
  }

  Future<void> loadCashierOnlineOrders() async {
    if (userEmail == null || !isCashier) return;
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
      notifyListeners();
    } catch (_) {}
  }

  Future<void> loadCashierOrderHistory() async {
    if (userEmail == null || !isCashier) return;
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
      notifyListeners();
    } catch (_) {}
  }

  Future<void> loadCashierWalkInQueues() async {
    if (userEmail == null || !isCashier) return;
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
      notifyListeners();
    } catch (_) {}
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
      await loadCashierWalkInQueues();
      await loadCashierOrderHistory();
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
      await loadCashierOnlineOrders();
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
      await loadCashierOnlineOrders();
      notifyListeners();
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
  bool signupMode = false;
  bool otpSent = false;
  bool busy = false;

  @override
  void dispose() {
    emailController.dispose();
    passwordController.dispose();
    confirmPasswordController.dispose();
    otpController.dispose();
    super.dispose();
  }

  Future<void> _toast(String msg) async {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            const SizedBox(height: 50),
            const Text('WELCOME', style: TextStyle(fontSize: 26, fontWeight: FontWeight.w800)),
            const SizedBox(height: 30),
            const CircleAvatar(radius: 52, backgroundColor: Colors.white, child: Icon(Icons.restaurant, size: 42)),
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

class AppScaffold extends StatelessWidget {
  const AppScaffold({
    super.key,
    required this.state,
    required this.title,
    required this.body,
    this.showTrayShortcut = true,
    this.actions,
  });

  final AppState state;
  final String title;
  final Widget body;
  final bool showTrayShortcut;
  final List<Widget>? actions;

  @override
  Widget build(BuildContext context) {
    final qty = state.tray.fold<int>(0, (s, e) => s + e.qty);
    return Scaffold(
      appBar: AppBar(
        leading: Navigator.of(context).canPop()
            ? IconButton(icon: const Icon(Icons.arrow_back), onPressed: () => Navigator.of(context).pop())
            : Builder(
                builder: (context) => IconButton(
                  icon: const Icon(Icons.menu),
                  onPressed: () => Scaffold.of(context).openDrawer(),
                ),
              ),
        backgroundColor: AppColors.brand,
        title: Container(
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.surface,
            borderRadius: BorderRadius.circular(12),
          ),
          padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 16),
          child: Text(
            title,
            style: TextStyle(fontWeight: FontWeight.w800, color: Theme.of(context).colorScheme.onSurface),
          ),
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
                child: const Icon(Icons.shopping_cart_outlined),
              ),
            ),
          ...?actions,
        ],
      ),
      drawer: AppDrawer(state: state),
      body: body,
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
    final greet = state.profile.fullName.trim().isNotEmpty ? state.profile.fullName.trim() : (state.userEmail ?? '');
    return Drawer(
      child: ListView(
        children: [
          DrawerHeader(
            decoration: const BoxDecoration(color: AppColors.brand),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                const Text(
                  "Macrina's Kitchen\nand Catering",
                  style: TextStyle(fontSize: 20, fontWeight: FontWeight.w900, height: 1.15),
                ),
                if (greet.isNotEmpty) Text('Hi, $greet!', style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
              ],
            ),
          ),
          ListTile(title: const Text('My Profile'), onTap: () => open(context, MyProfileScreen(state: state))),
          ListTile(title: const Text('My Orders'), onTap: () => open(context, MyOrdersScreen(state: state))),
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

class RestaurantMenuScreen extends StatelessWidget {
  const RestaurantMenuScreen({super.key, required this.state});
  final AppState state;

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
    state.addToTray(item, dip: dip);
    appSnack(context, 'Added ${item.name} to tray');
  }

  @override
  Widget build(BuildContext context) {
    final restaurantItems = state.menu.where((m) => m.isRestaurantDish).toList();
    return AppScaffold(
      state: state,
      title: 'RESTAURANT',
      body: Column(
        children: [
          const Padding(
            padding: EdgeInsets.all(12),
            child: TextField(decoration: InputDecoration(hintText: 'SEARCH')),
          ),
          Expanded(
            child: restaurantItems.isEmpty
                ? const Center(child: Text('No restaurant menu items yet.\n(Tag dishes as category "restaurant" in the admin.)'))
                : GridView.builder(
                    padding: const EdgeInsets.all(12),
                    itemCount: restaurantItems.length,
                    gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                      crossAxisCount: 2,
                      crossAxisSpacing: 10,
                      mainAxisSpacing: 10,
                      childAspectRatio: 0.74,
                    ),
                    itemBuilder: (context, index) {
                      final item = restaurantItems[index];
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
                            Text(item.description.toUpperCase(), textAlign: TextAlign.center, style: const TextStyle(fontSize: 12)),
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
                    },
                  ),
          ),
        ],
      ),
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
          body: Column(
            children: [
              Expanded(
                child: state.tray.isEmpty
                    ? const Center(child: Text('Your tray is empty.'))
                    : ListView.builder(
                        padding: const EdgeInsets.all(12),
                        itemCount: state.tray.length,
                        itemBuilder: (context, index) {
                          final item = state.tray[index];
                          return Card(
                            child: ListTile(
                              title: Text(item.menu.name),
                              subtitle: Text('${item.dip.isEmpty ? 'No dip' : item.dip}\n₱${item.menu.price.toStringAsFixed(2)}'),
                              trailing: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  IconButton(
                                    onPressed: () {
                                      state.changeQty(item, 1);
                                      appSnack(context, 'Updated quantity');
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
                                      } else {
                                        appSnack(context, 'Updated quantity');
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
  bool showDelivery = true;
  bool showTray = true;
  bool showNotes = true;
  final noteController = TextEditingController();

  @override
  void initState() {
    super.initState();
    noteController.text = widget.state.checkoutNote;
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.state;
    return AppScaffold(
      state: s,
      title: 'CHECKOUT',
      body: Column(
        children: [
          Expanded(
            child: ListView(
              padding: const EdgeInsets.all(12),
              children: [
                const _OrderNoCard(),
                const SizedBox(height: 10),
                ToggleSection(
                  title: 'DELIVERY INFORMATION',
                  expanded: showDelivery,
                  onToggle: () => setState(() => showDelivery = !showDelivery),
                  child: Column(
                    children: [
                      LockedField(label: 'NAME', value: s.profile.fullName),
                      LockedField(label: 'CONTACT NUMBER', value: s.profile.contactNumber),
                      LockedField(label: 'DELIVERY ADDRESS', value: s.profile.deliveryAddress),
                      const LockedField(label: 'TIME OF DELIVERY', value: 'NOW'),
                      const LockedField(label: 'MODE OF PAYMENT', value: 'GCASH ONLY'),
                    ],
                  ),
                ),
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
                    onChanged: (v) => s.checkoutNote = v,
                  ),
                ),
              ],
            ),
          ),
          SummaryFooter(
            lines: [SummaryLine('YOUR ORDER', '₱${s.subtotal.toStringAsFixed(2)}'), SummaryLine('TOTAL', '₱${s.subtotal.toStringAsFixed(2)}', isTotal: true)],
            secondaryLabel: 'CANCEL',
            actionLabel: 'CONFIRM & PAY',
            onSecondary: () => Navigator.of(context).pop(),
            onAction: () async {
              if (s.profile.deliveryAddress.trim().isEmpty) {
                appSnack(context, 'Add a delivery address in My Profile first.');
                return;
              }
              if (!s.profile.deliveryMapConfirmed) {
                appSnack(context, 'Open the map from My Profile, pin your location, and confirm before ordering.');
                return;
              }
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
              showDialog<void>(
                context: context,
                barrierDismissible: false,
                builder: (_) => const Center(child: CircularProgressIndicator()),
              );
              final result = await s.submitOrder();
              if (!context.mounted) return;
              Navigator.of(context).pop();
              if (result.error != null) {
                appSnack(context, result.error!);
                return;
              }
              final order = result.order!;
              appSnack(context, 'Order ${order.orderNo} placed');
              Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => PaymentScreen(state: s, order: order, note: noteController.text)));
            },
          ),
        ],
      ),
    );
  }
}

class PaymentScreen extends StatefulWidget {
  const PaymentScreen({super.key, required this.state, required this.order, required this.note});
  final AppState state;
  final OrderData order;
  final String note;

  @override
  State<PaymentScreen> createState() => _PaymentScreenState();
}

class _PaymentScreenState extends State<PaymentScreen> {
  bool localProofUploaded = false;
  bool showPayment = true;
  bool showNotes = true;
  bool showDelivery = true;
  XFile? uploadedFile;
  Uint8List? _localProofBytes;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      await widget.state.loadOrders();
      if (mounted) setState(() {});
    });
  }

  OrderData? _syncedOrder(AppState s) {
    for (final o in s.orders) {
      if (o.id == widget.order.id) return o;
    }
    return null;
  }

  Widget _paymentProofPreview(OrderData? synced) {
    if (_localProofBytes != null) {
      return Padding(
        padding: const EdgeInsets.only(top: 10),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(10),
          child: Image.memory(_localProofBytes!, height: 160, fit: BoxFit.contain),
        ),
      );
    }
    final b64 = synced?.paymentProofBase64;
    if (b64 != null && b64.isNotEmpty) {
      try {
        final bytes = base64Decode(b64);
        return Padding(
          padding: const EdgeInsets.only(top: 10),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(10),
            child: Image.memory(Uint8List.fromList(bytes), height: 160, fit: BoxFit.contain),
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
        child: ClipRRect(
          borderRadius: BorderRadius.circular(10),
          child: Image.memory(Uint8List.fromList(bytes), height: 140, fit: BoxFit.contain),
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
        final synced = _syncedOrder(s);
        final orderForUi = synced ?? widget.order;
        final insufficient = orderForUi.status.toUpperCase().contains('INSUFFICIENT');
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
          body: Column(
            children: [
              Expanded(
                child: ListView(
                  padding: const EdgeInsets.all(12),
                  children: [
                    _OrderNoCard(displayNo: orderForUi.orderNo),
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
                            child: const Icon(Icons.qr_code_2, size: 80),
                          ),
                          const SizedBox(height: 12),
                          Row(
                            children: [
                              Expanded(
                                child: Text(
                                  insufficient
                                      ? 'After paying the remaining balance, upload proof here.'
                                      : 'Once paid, upload proof of payment',
                                ),
                              ),
                              OutlinedButton(
                                onPressed: () async {
                                  final picker = ImagePicker();
                                  final file = await picker.pickImage(source: ImageSource.gallery);
                                  if (file == null) return;
                                  final bytes = await file.readAsBytes();
                                  await s.uploadPaymentProof(widget.order.id, file);
                                  if (!mounted) return;
                                  setState(() {
                                    uploadedFile = file;
                                    _localProofBytes = bytes;
                                    localProofUploaded = true;
                                  });
                                  appSnack(context, insufficient ? 'Balance payment proof uploaded' : 'Payment proof uploaded');
                                },
                                child: Text(
                                  insufficient
                                      ? (proofDone ? 'CHANGE BALANCE PROOF' : 'UPLOAD BALANCE PROOF')
                                      : (uploadedFile == null && !proofDone ? 'UPLOAD' : 'CHANGE PHOTO'),
                                ),
                              ),
                            ],
                          ),
                          if (!insufficient) _paymentProofPreview(synced),
                          if (insufficient) ...[
                            if (synced?.paymentProofBase64?.isNotEmpty ?? false) ...[
                              const SizedBox(height: 10),
                              const Text('Original payment proof', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 12)),
                              Padding(
                                padding: const EdgeInsets.only(top: 6),
                                child: ClipRRect(
                                  borderRadius: BorderRadius.circular(10),
                                  child: Image.memory(
                                    Uint8List.fromList(base64Decode(synced!.paymentProofBase64!)),
                                    height: 120,
                                    fit: BoxFit.contain,
                                  ),
                                ),
                              ),
                            ],
                            const SizedBox(height: 10),
                            const Text('Balance payment proof', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 12)),
                            if (_localProofBytes != null)
                              Padding(
                                padding: const EdgeInsets.only(top: 6),
                                child: ClipRRect(
                                  borderRadius: BorderRadius.circular(10),
                                  child: Image.memory(_localProofBytes!, height: 160, fit: BoxFit.contain),
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
                      title: 'NOTES',
                      expanded: showNotes,
                      onToggle: () => setState(() => showNotes = !showNotes),
                      child: Text(widget.note),
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
              SummaryFooter(
                lines: [
                  SummaryLine('YOUR ORDER', '₱${orderForUi.total.toStringAsFixed(2)}'),
                  SummaryLine('TOTAL', '₱${orderForUi.total.toStringAsFixed(2)}', isTotal: true),
                ],
                secondaryLabel: 'BACK',
                actionLabel: 'CONFIRM PAYMENT',
                onSecondary: () => Navigator.of(context).pop(),
                onAction: () {
                  final syncedNow = _syncedOrder(s);
                  final ordNow = syncedNow ?? widget.order;
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
                  Navigator.of(context).pushReplacement(
                    MaterialPageRoute<void>(
                      builder: (_) => OrderStatusScreen(state: s, order: ordNow, paymentUploaded: true),
                    ),
                  );
                },
              ),
            ],
          ),
        );
      },
    );
  }
}

class OrderStatusScreen extends StatelessWidget {
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
  Widget build(BuildContext context) {
    final track = order.deliveryTrackingUrl.trim();
    return AppScaffold(
      state: state,
      title: 'ORDER STATUS',
      body: Padding(
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
                    Text('Status: ${order.status}'),
                    Text('Total: ₱${order.total.toStringAsFixed(2)}'),
                    Text('Payment proof: ${paymentUploaded ? 'Received' : 'Not uploaded yet'}'),
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
  late TabController _tab;

  @override
  void initState() {
    super.initState();
    _tab = TabController(length: 3, vsync: this);
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
        return all.where(customerOrderPendingTab).toList();
      case 1:
        return all.where(customerOrderConfirmedTab).toList();
      case 2:
        return all.where(orderLooksCompleted).toList();
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
    final filtered = _ordersForTab(tabIndex);
    return RefreshIndicator(
      onRefresh: widget.state.loadOrders,
      child: filtered.isEmpty
          ? ListView(
              physics: const AlwaysScrollableScrollPhysics(),
              children: const [
                SizedBox(height: 140, child: Center(child: Text('No orders in this list.'))),
              ],
            )
          : ListView.builder(
              padding: const EdgeInsets.only(bottom: 16),
              itemCount: filtered.length,
              itemBuilder: (context, index) {
                final o = filtered[index];
                return Card(
                  margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                  child: ListTile(
                    leading: _paymentThumb(o),
                    title: Text(o.orderNo),
                    subtitle: Text(
                      tabIndex == 1
                          ? '${fulfillmentStageReadable(o.fulfillmentStage)}\n${o.status}\n${o.createdAt.toLocal()}'
                          : '${o.status}\n${o.createdAt.toLocal()}',
                    ),
                    isThreeLine: true,
                    trailing: Text('₱${o.total.toStringAsFixed(2)}'),
                    onTap: () {
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
                                _detailLine('Status', o.status),
                                _detailLine('Fulfillment stage', fulfillmentStageReadable(o.fulfillmentStage)),
                                _detailLine('Placed', o.createdAt.toLocal().toString()),
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
                            if (o.status.toUpperCase().contains('INSUFFICIENT'))
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
      return [
        ClipRRect(
          borderRadius: BorderRadius.circular(10),
          child: Image.memory(Uint8List.fromList(bytes), height: 220, fit: BoxFit.contain),
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

  @override
  Widget build(BuildContext context) {
    return AppScaffold(
      state: widget.state,
      title: 'MY ORDERS',
      body: Column(
        children: [
          Material(
            color: Colors.white,
            child: TabBar(
              controller: _tab,
              isScrollable: true,
              labelColor: AppColors.ink,
              unselectedLabelColor: Colors.grey.shade700,
              indicatorColor: AppColors.brand,
              tabs: const [
                Tab(text: 'Pending Confirmation'),
                Tab(text: 'Confirmed Orders'),
                Tab(text: 'Completed'),
              ],
            ),
          ),
          Expanded(
            child: TabBarView(
              controller: _tab,
              children: [_tabBody(0), _tabBody(1), _tabBody(2)],
            ),
          ),
        ],
      ),
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

  @override
  void initState() {
    super.initState();
    final p = widget.state.profile;
    nameController = TextEditingController(text: p.fullName);
    contactController = TextEditingController(text: p.contactNumber);
    addressController = TextEditingController(text: p.deliveryAddress);
    deliveryMapConfirmedLocal = p.deliveryMapConfirmed;
    mapLat = p.deliveryLat;
    mapLng = p.deliveryLng;
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
      });
      appSnack(context, 'Location pinned. Save your profile to keep coordinates and address.');
    }
  }

  @override
  Widget build(BuildContext context) {
    return AppScaffold(
      state: widget.state,
      title: 'MY PROFILE',
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            Expanded(
              child: ListView(
                children: [
                  TextField(controller: nameController, decoration: const InputDecoration(labelText: 'Full Name')),
                  const SizedBox(height: 10),
                  TextField(controller: contactController, decoration: const InputDecoration(labelText: 'Contact Number')),
                  const SizedBox(height: 10),
                  TextField(
                    controller: addressController,
                    decoration: const InputDecoration(labelText: 'Delivery Address'),
                    minLines: 2,
                    maxLines: 4,
                  ),
                  const SizedBox(height: 12),
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton.tonalIcon(
                      onPressed: _openMapsDialog,
                      icon: const Icon(Icons.map_outlined),
                      label: const Text('OPEN MAP TO PIN LOCATION'),
                      style: FilledButton.styleFrom(
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        foregroundColor: AppColors.ink,
                      ),
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Tap the map to drop a pin. We resolve the street address using OpenStreetMap (same coordinates you can verify in Google Maps).',
                    style: TextStyle(fontSize: 12, color: Colors.grey.shade800),
                  ),
                  if (mapLat != null && mapLng != null) ...[
                    const SizedBox(height: 16),
                    const Text('Map preview', style: TextStyle(fontWeight: FontWeight.w800, fontSize: 15)),
                    const SizedBox(height: 8),
                    SizedBox(
                      height: 160,
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(12),
                        child: FlutterMap(
                          options: MapOptions(
                            initialCenter: LatLng(mapLat!, mapLng!),
                            initialZoom: 15,
                            interactionOptions: const InteractionOptions(flags: InteractiveFlag.none),
                          ),
                          children: [
                            TileLayer(
                              urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                              userAgentPackageName: 'com.curatering.mobile',
                            ),
                            MarkerLayer(
                              markers: [
                                Marker(
                                  point: LatLng(mapLat!, mapLng!),
                                  width: 40,
                                  height: 40,
                                  alignment: Alignment.center,
                                  child: const Icon(Icons.location_on, color: AppColors.accent, size: 40),
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ),
            FilledButton(
              onPressed: () async {
                await widget.state.saveProfile(
                  ProfileData(
                    fullName: nameController.text.trim(),
                    contactNumber: contactController.text.trim(),
                    deliveryAddress: addressController.text.trim(),
                    deliveryMapConfirmed: deliveryMapConfirmedLocal,
                    deliveryLat: mapLat,
                    deliveryLng: mapLng,
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
  late LatLng _pin;
  String _resolvedAddress = '';
  bool _busy = false;

  @override
  void initState() {
    super.initState();
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
  static const List<String> _eventTypeChoices = ['Wedding', 'Corporate', 'Birthday', 'Debut', 'Seminar', 'Other'];

  String inquiryType = 'CATERING';
  bool curateOwn = false;
  String selectedSetMenu = 'All Dishes';
  final selectedDishes = <String>{};
  final guestCount = TextEditingController();
  String menuSuggestionNote = '';
  String themeSuggestionNote = '';
  final eventTitle = TextEditingController();
  final eventTypeOther = TextEditingController();
  String eventTypeChoice = 'Wedding';
  final contactPerson = TextEditingController();
  final contactNumber = TextEditingController();
  final inquiryEmail = TextEditingController();
  final List<_InquiryEventWindow> _eventWindows = [_InquiryEventWindow()];
  final eventCity = TextEditingController();
  final note = TextEditingController();
  String eventSetting = 'open';
  String serviceIncluded = 'no';
  String formalityLevel = 'casual';
  bool foodTastingRequested = false;

  @override
  void initState() {
    super.initState();
    final p = widget.state.profile;
    contactPerson.text = p.fullName;
    contactNumber.text = p.contactNumber;
    inquiryEmail.text = widget.state.userEmail ?? '';
  }

  @override
  void dispose() {
    guestCount.dispose();
    eventTitle.dispose();
    eventTypeOther.dispose();
    contactPerson.dispose();
    contactNumber.dispose();
    inquiryEmail.dispose();
    eventCity.dispose();
    note.dispose();
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

  double _estimatedCost() => _billableGuestCountForPricing() * kPesosPerPax;

  String _resolvedEventType() {
    if (eventTypeChoice != 'Other') return eventTypeChoice;
    return eventTypeOther.text.trim();
  }

  /// Returns null if valid; otherwise an error message for the user.
  String? _validateInquiry() {
    if (contactPerson.text.trim().isEmpty) return 'Enter contact person.';
    if (contactNumber.text.trim().isEmpty) return 'Enter contact number.';
    if (inquiryEmail.text.trim().isEmpty) return 'Enter email address.';
    if (eventCity.text.trim().isEmpty) return 'Enter city of event.';
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
    final s = widget.state;
    if (curateOwn) {
      if (selectedDishes.isEmpty) return 'Select at least one dish for your curated menu.';
    } else {
      if (s.setMenus.isNotEmpty && selectedSetMenu == 'All Dishes') {
        return 'Choose a set menu, or tap YES! to curate your own dishes.';
      }
    }
    if (inquiryType == 'CATERING AND EVENT' && eventTitle.text.trim().isEmpty) return 'Enter event title.';
    if (eventTypeChoice == 'Other' && eventTypeOther.text.trim().isEmpty) {
      return 'Describe the event type for “Other”.';
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
          value: _eventTypeChoices.contains(eventTypeChoice) ? eventTypeChoice : 'Other',
          decoration: const InputDecoration(labelText: 'Event type'),
          items: _eventTypeChoices.map((e) => DropdownMenuItem(value: e, child: Text(e))).toList(),
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

  @override
  Widget build(BuildContext context) {
    final state = widget.state;
    final cateringMenu = state.menu.where((m) => m.isCateringDish).toList();
    final setMenuNames = ['All Dishes', ...state.setMenus.map((m) => m.name)];
    final effectiveSetMenu = setMenuNames.contains(selectedSetMenu) ? selectedSetMenu : 'All Dishes';
    List<String> availableDishes;
    if (effectiveSetMenu == 'All Dishes') {
      availableDishes = cateringMenu.map((m) => m.name).toList();
    } else {
      final matches = state.setMenus.where((m) => m.name == effectiveSetMenu).toList();
      final raw = matches.isEmpty ? <String>[] : matches.first.dishes;
      availableDishes = raw.where((n) => cateringMenu.any((c) => c.name == n)).toList();
    }
    final estimate = _estimatedCost();
    return AppScaffold(
      state: state,
      title: 'INQUIRE CATERING SERVICE',
      body: Column(
        children: [
          Expanded(
            child: ListView(
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
                      if (inquiryType == 'CATERING AND EVENT') ...[
                        TextField(controller: eventTitle, decoration: const InputDecoration(labelText: 'Event title')),
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
                      ],
                      TextField(controller: contactPerson, decoration: const InputDecoration(labelText: 'Contact person')),
                      const SizedBox(height: 8),
                      TextField(controller: contactNumber, decoration: const InputDecoration(labelText: 'Contact number')),
                      const SizedBox(height: 8),
                      TextField(controller: inquiryEmail, decoration: const InputDecoration(labelText: 'Email address')),
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
                                      onPressed: () => setState(() {
                                        if (_eventWindows.length > 1) _eventWindows.removeAt(index);
                                      }),
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
                      Align(
                        alignment: Alignment.centerLeft,
                        child: TextButton.icon(
                          onPressed: () => setState(() => _eventWindows.add(_InquiryEventWindow())),
                          icon: const Icon(Icons.add),
                          label: const Text('Add another day'),
                        ),
                      ),
                      const SizedBox(height: 8),
                      TextField(controller: eventCity, decoration: const InputDecoration(labelText: 'City of event')),
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
                  title: 'MENU',
                  expanded: true,
                  onToggle: () {},
                  hideToggleIcon: true,
                  child: Column(
                    children: [
                      const Text('WOULD YOU LIKE TO CURATE YOUR OWN MENU?'),
                      const SizedBox(height: 8),
                      Row(
                        children: [
                          Expanded(
                            child: OutlinedButton(
                              onPressed: () => setState(() {
                                curateOwn = true;
                                menuSuggestionNote = '';
                                selectedSetMenu = 'All Dishes';
                                selectedDishes.clear();
                              }),
                              child: const Text('YES!'),
                            ),
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            flex: 2,
                            child: OutlinedButton(
                              onPressed: () => setState(() {
                                curateOwn = false;
                                selectedDishes.clear();
                                menuSuggestionNote = 'No, suggest me a menu instead.';
                              }),
                              child: const Text('NO, SUGGEST ME A MENU INSTEAD', textAlign: TextAlign.center),
                            ),
                          ),
                        ],
                      ),
                      if (!curateOwn && menuSuggestionNote.isNotEmpty) ...[
                        const SizedBox(height: 8),
                        Text(menuSuggestionNote, style: const TextStyle(fontWeight: FontWeight.w700)),
                      ],
                      CheckboxListTile(
                        dense: true,
                        contentPadding: EdgeInsets.zero,
                        title: const Text('Request food tasting'),
                        value: foodTastingRequested,
                        onChanged: (v) => setState(() => foodTastingRequested = v ?? false),
                      ),
                      if (curateOwn) ...[
                        const SizedBox(height: 10),
                        DropdownButtonFormField<String>(
                          value: effectiveSetMenu,
                          items: setMenuNames
                              .map((name) => DropdownMenuItem(value: name, child: Text(name)))
                              .toList(),
                          onChanged: (v) {
                            final next = v ?? 'All Dishes';
                            setState(() {
                              selectedSetMenu = next;
                              selectedDishes.clear();
                              if (next != 'All Dishes') {
                                final rows = state.setMenus.where((m) => m.name == next).toList();
                                if (rows.isNotEmpty) {
                                  selectedDishes.addAll(rows.first.dishes);
                                }
                              }
                            });
                          },
                        ),
                        const SizedBox(height: 8),
                        ...availableDishes.map((dishName) {
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
                              color: sel ? AppColors.brand.withOpacity(0.35) : Colors.grey.shade100,
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
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Expanded(
                              child: OutlinedButton(
                                onPressed: () => setState(() => themeSuggestionNote = ''),
                                child: const Text('I HAVE A THEME IN MIND', textAlign: TextAlign.center),
                              ),
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: OutlinedButton(
                                onPressed: () => setState(() {
                                  themeSuggestionNote = 'No, suggest me a theme design instead.';
                                }),
                                child: const Text('NO, SUGGEST ME A THEME INSTEAD', textAlign: TextAlign.center),
                              ),
                            ),
                          ],
                        ),
                        if (themeSuggestionNote.isNotEmpty) ...[
                          const SizedBox(height: 8),
                          Text(themeSuggestionNote, style: const TextStyle(fontWeight: FontWeight.w700)),
                        ],
                        const SizedBox(height: 12),
                        const Text(
                          'Use this space to describe your preferred mood board: colour palette, linens and napery, florals and greenery, lighting (warm candlelight vs bright festoons), signage, stage or backdrop ideas, table layouts, and any motif or cultural elements you want reflected.',
                          style: TextStyle(height: 1.35),
                        ),
                        const SizedBox(height: 10),
                        const Text(
                          'You may attach inspiration links or filenames later with your coordinator; photos of the venue (indoor/outdoor, ceiling height) help us propose realistic installs.',
                          style: TextStyle(height: 1.35),
                        ),
                        const SizedBox(height: 10),
                        const Text(
                          'If you already have hired stylists or florists, note their contact windows here so we can align catering service timing with their setup and strike.',
                          style: TextStyle(height: 1.35),
                        ),
                      ],
                    ),
                  ),
                ],
              ],
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
                        Text('City: ${eventCity.text.trim()}'),
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
              final guestsSaved = _guestCountForSubmit();
              final err = await state.submitInquiry({
                'inquiry_type': inquiryType,
                'event_title': inquiryType == 'CATERING AND EVENT' ? eventTitle.text.trim() : '',
                'event_type': (inquiryType == 'CATERING' || inquiryType == 'CATERING AND EVENT') ? _resolvedEventType() : '',
                'customer': contactPerson.text.trim(),
                'contact_person': contactPerson.text.trim(),
                'contact_number': contactNumber.text.trim(),
                'inquiry_email': inquiryEmail.text.trim(),
                'date_of_event': _serializedEventDates(),
                'note': note.text.trim(),
                'curate_own_menu': curateOwn,
                'selected_set_menu': selectedSetMenu,
                'selected_dishes': selectedDishes.toList(),
                'include_event_theme': inquiryType == 'CATERING AND EVENT',
                'guest_count': guestsSaved,
                'estimated_total': est,
                'menu_suggestion_note': menuSuggestionNote,
                'theme_suggestion_note': themeSuggestionNote,
                'event_city': eventCity.text.trim(),
                'event_setting': eventSetting,
                'service_included': serviceIncluded,
                'formality_level': inquiryType == 'CATERING AND EVENT' ? formalityLevel : '',
                'food_tasting_requested': foodTastingRequested,
              });
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

  @override
  void initState() {
    super.initState();
    _tab = TabController(length: 2, vsync: this);
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
      line('Inquiry no.: ${r.inquiryNo}'),
      line('Type: ${r.inquiryType}'),
      line('Status: ${r.status}'),
    ];

    if (isFullEvent) {
      if (r.eventTitle.trim().isNotEmpty) lines.add(line('Event title: ${r.eventTitle}'));
      if (r.eventType.trim().isNotEmpty) lines.add(line('Event type: ${r.eventType}'));
      if (r.formalityLevel.trim().isNotEmpty) lines.add(line('Formality: ${r.formalityLevel}'));
      if (r.eventCity.trim().isNotEmpty) lines.add(line('City: ${r.eventCity}'));
      if (r.eventSetting.trim().isNotEmpty) lines.add(line('Setting: ${r.eventSetting}'));
      if (r.themeSuggestionNote.trim().isNotEmpty) lines.add(line('Theme / styling: ${r.themeSuggestionNote}'));
    }

    lines.add(line('Guests: ${r.guestCount}'));
    lines.add(line('Contact: ${r.contactPerson} / ${r.contactNumber}'));
    lines.add(line('Email: ${r.inquiryEmail}'));
    if (r.dateOfEvent.trim().isNotEmpty) lines.add(line('Date/time: ${r.dateOfEvent}'));
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
    if (r.estimatedTotal > 0) lines.add(line('Estimated cost: ₱${r.estimatedTotal.toStringAsFixed(2)}'));
    lines.add(line('Submitted: ${r.createdAt.toLocal()}'));

    return lines;
  }

  Future<void> _followUp(InquiryRecord r) async {
    final uri = Uri.parse(
      'mailto:?subject=${Uri.encodeComponent('Follow up: ${r.inquiryNo}')}'
      '&body=${Uri.encodeComponent('Inquiry: ${r.inquiryNo}\nType: ${r.inquiryType}\n')}',
    );
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri);
    } else if (mounted) {
      appSnack(context, 'Could not open your email app');
    }
  }

  void _showDetail(InquiryRecord r) {
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(r.inquiryNo),
        content: SingleChildScrollView(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: _inquiryDetailLines(r)),
        ),
        actions: [
          TextButton(onPressed: () => _followUp(r), child: const Text('Follow up')),
          TextButton(onPressed: () => Navigator.of(ctx).pop(), child: const Text('Close')),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.state;
    final waiting = s.inquiries.where((r) => r.isWaiting).toList();
    final responded = s.inquiries.where((r) => !r.isWaiting).toList();

    Widget buildList(List<InquiryRecord> list) {
      return RefreshIndicator(
        onRefresh: s.loadInquiries,
        child: list.isEmpty
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
                itemCount: list.length,
                itemBuilder: (context, index) {
                  final i = list[index];
                  return Card(
                    margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                    child: ListTile(
                      title: Text(i.inquiryNo),
                      subtitle: Text('${i.inquiryType} — ${i.eventTitle}\n${i.createdAt.toLocal()}'),
                      trailing: IconButton(
                        icon: const Icon(Icons.reply_outlined),
                        tooltip: 'Follow up',
                        onPressed: () => _followUp(i),
                      ),
                      onTap: () => _showDetail(i),
                    ),
                  );
                },
              ),
      );
    }

    return AppScaffold(
      state: s,
      title: 'MY CATERING INQUIRIES',
      body: Column(
        children: [
          TabBar(
            controller: _tab,
            tabs: const [
              Tab(text: 'WAITING FOR RESPONSE'),
              Tab(text: 'RESPONDED'),
            ],
          ),
          Expanded(
            child: TabBarView(
              controller: _tab,
              children: [
                buildList(waiting),
                buildList(responded),
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
      Navigator.of(context).pushAndRemoveUntil(
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
          body: Padding(
            padding: const EdgeInsets.all(14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
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
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => widget.state.loadCashierOrderHistory());
  }

  Widget _historyProofImage(String? b64) {
    if (b64 == null || b64.trim().isEmpty) return const SizedBox.shrink();
    try {
      return ClipRRect(
        borderRadius: BorderRadius.circular(10),
        child: Image.memory(
          Uint8List.fromList(base64Decode(b64.trim())),
          height: 200,
          fit: BoxFit.contain,
        ),
      );
    } catch (_) {
      return const Text('(Invalid image data)');
    }
  }

  void _showOrderDetail(OrderData o) {
    final p1 = _historyProofImage(o.paymentProofBase64);
    final p2 = _historyProofImage(o.supplementalPaymentProofBase64);
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
              Text('Placed: ${o.createdAt.toLocal()}'),
              Text('Source: ${o.orderSource}'),
              Text('Status: ${o.status}'),
              Text('Fulfillment: ${o.fulfillmentStage}'),
              if ((o.userEmail ?? '').trim().isNotEmpty) Text('Customer email: ${o.userEmail}'),
              if (o.posCustomerLabel.trim().isNotEmpty) Text('Walk-in label: ${o.posCustomerLabel}'),
              Text('Payment: ${o.paymentMode}'),
              Text('Total: ₱${o.total.toStringAsFixed(2)}'),
              if (o.cashierAmountReceived != null)
                Text('Amount received (recorded): ₱${o.cashierAmountReceived!.toStringAsFixed(2)}'),
              if (o.cashierSecondaryAmountReceived != null)
                Text('Additional amount (recorded): ₱${o.cashierSecondaryAmountReceived!.toStringAsFixed(2)}'),
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
            onRefresh: widget.state.loadCashierOrderHistory,
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
                          title: Text(o.orderNo),
                          subtitle: Text(
                            '${o.orderSource} · ${o.status}\n${o.createdAt.toLocal()}',
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
        widget.state.loadCashierWalkInQueues();
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
              builder: (ctx) => IconButton(
                icon: const Icon(Icons.menu, color: AppColors.brand),
                onPressed: () => Scaffold.of(ctx).openDrawer(),
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
              tabs: const [
                Tab(text: 'New Order'),
                Tab(text: 'Online Orders'),
                Tab(text: 'Walk-in ongoing'),
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
                      const Text(
                        "Macrina's Kitchen and Catering",
                        style: TextStyle(fontWeight: FontWeight.w800, fontSize: 15),
                      ),
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
        return Column(
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
                      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                        crossAxisCount: 2,
                        crossAxisSpacing: 10,
                        mainAxisSpacing: 10,
                        childAspectRatio: 0.72,
                      ),
                      itemCount: filtered.length,
                      itemBuilder: (context, i) {
                        final item = filtered[i];
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
                      },
                    ),
            ),
            Container(
              decoration: const BoxDecoration(color: Colors.white, border: Border(top: BorderSide(color: Color(0xFF8ADFC1)))),
              padding: const EdgeInsets.all(12),
              child: Row(
                children: [
                  Expanded(
                    child: FilledButton(
                      style: FilledButton.styleFrom(backgroundColor: AppColors.accent, foregroundColor: AppColors.ink),
                      onPressed: () => widget.state.clearTray(),
                      child: const Text('CANCEL'),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: FilledButton(
                      style: FilledButton.styleFrom(backgroundColor: AppColors.brand, foregroundColor: AppColors.ink),
                      onPressed: widget.state.tray.isEmpty
                          ? null
                          : () {
                              Navigator.of(context).push<void>(
                                MaterialPageRoute<void>(
                                  builder: (_) => PosWalkInCheckoutScreen(state: widget.state, subtotal: subtotal),
                                ),
                              );
                            },
                      child: const Text('NEXT'),
                    ),
                  ),
                ],
              ),
            ),
          ],
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

class _PosWalkInCheckoutScreenState extends State<PosWalkInCheckoutScreen> {
  String paymentMethod = 'CASH';
  final amountReceived = TextEditingController();
  final note = TextEditingController();
  final customerLabel = TextEditingController();
  Uint8List? gcashProofBytes;

  @override
  void dispose() {
    amountReceived.dispose();
    note.dispose();
    customerLabel.dispose();
    super.dispose();
  }

  Future<void> _pickGcashProof() async {
    final x = await ImagePicker().pickImage(source: ImageSource.gallery);
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
                const Divider(height: 28),
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
                  OutlinedButton.icon(
                    onPressed: _pickGcashProof,
                    icon: const Icon(Icons.upload_file),
                    label: const Text('UPLOAD PROOF OF PAYMENT'),
                  ),
                  if (gcashProofBytes != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 10),
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(10),
                        child: Image.memory(gcashProofBytes!, height: 140, fit: BoxFit.contain),
                      ),
                    ),
                ],
                const SizedBox(height: 12),
                TextField(controller: customerLabel, decoration: const InputDecoration(labelText: 'Customer name / reference (optional)')),
                TextField(controller: note, decoration: const InputDecoration(labelText: 'NOTE'), maxLines: 2),
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
                appSnack(context, 'Enter amount received.');
                return;
              }
              if (parsed == null) {
                appSnack(context, 'Enter a valid amount.');
                return;
              }
              if (arNum < widget.subtotal) {
                appSnack(context, 'Amount received is less than the total.');
                return;
              }
              if (isGcash && gcashProofBytes == null) {
                appSnack(context, 'Upload proof of payment for GCash.');
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
                appSnack(context, err);
                return;
              }
              appSnack(context, 'Walk-in order saved');
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
    widget.state.loadCashierWalkInQueues();
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
              Text('Status: ${o.status}'),
              Text('Placed: ${o.createdAt.toLocal()}'),
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
                    onRefresh: widget.state.loadCashierWalkInQueues,
                    child: _walkList(widget.state.cashierWalkInPreparing, showClaim: true),
                  ),
                  RefreshIndicator(
                    onRefresh: widget.state.loadCashierWalkInQueues,
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
        return Card(
          child: ListTile(
            title: Text(o.orderNo),
            subtitle: Text(
              [
                if (o.posCustomerLabel.trim().isNotEmpty) o.posCustomerLabel.trim(),
                if (o.paymentMode.trim().isNotEmpty) o.paymentMode.toUpperCase(),
              ].where((s) => s.isNotEmpty).join(' · '),
            ),
            isThreeLine: false,
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

  @override
  void initState() {
    super.initState();
    _fulTab = TabController(length: 4, vsync: this);
  }

  @override
  void dispose() {
    _fulTab.dispose();
    super.dispose();
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
        .toList();
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
                    onRefresh: widget.state.loadCashierOnlineOrders,
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
                                  title: Text(o.orderNo),
                                  subtitle: Text('${o.status}\n${o.userEmail ?? ''}'),
                                  isThreeLine: true,
                                  trailing: Text('₱${o.total.toStringAsFixed(2)}'),
                                  onTap: () async {
                                    await Navigator.of(context).push<void>(
                                      MaterialPageRoute<void>(
                                        builder: (_) => PosOnlineOrderDetailScreen(state: widget.state, order: o),
                                      ),
                                    );
                                    if (context.mounted) await widget.state.loadCashierOnlineOrders();
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
                _OrderNoCard(displayNo: o.orderNo),
                const SizedBox(height: 10),
                ToggleSection(
                  title: 'ORDER SUMMARY',
                  expanded: true,
                  onToggle: () {},
                  hideToggleIcon: true,
                  child: Column(
                    children: [
                      LockedField(label: 'CUSTOMER EMAIL', value: o.userEmail?.trim().isNotEmpty == true ? o.userEmail! : '—'),
                      LockedField(label: 'ORDER STATUS', value: o.status),
                      LockedField(label: 'FULFILLMENT STAGE', value: o.fulfillmentStage),
                      LockedField(label: 'ORDERED AT', value: o.createdAt.toLocal().toString()),
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
                          onPressed: () async {
                            if (amountReceived.text.trim().isEmpty || parsed == null) {
                              appSnack(context, 'Enter amount received first.');
                              return;
                            }
                            if ((ar ?? 0) >= o.total) {
                              appSnack(context, 'Use Confirm order when payment is sufficient.');
                              return;
                            }
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
                          },
                          child: const Text('INSUFFICIENT PAYMENT'),
                        ),
                        const SizedBox(height: 8),
                        FilledButton(
                          style: FilledButton.styleFrom(backgroundColor: AppColors.brand, foregroundColor: AppColors.ink),
                          onPressed: () async {
                            if (amountReceived.text.trim().isEmpty || parsed == null) {
                              appSnack(context, 'Enter amount received first.');
                              return;
                            }
                            if ((ar ?? 0) <= o.total) {
                              appSnack(context, 'Amount is not over the total.');
                              return;
                            }
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
                          },
                          child: const Text('OVERPAYMENT'),
                        ),
                      ],
                    ],
                  ),
                ),
                const SizedBox(height: 10),
                if (stage == 'IN_PREPARATION') ...[
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
                if (stage == 'OUT_FOR_DELIVERY') ...[
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
                child: Text(
                  'Waiting for the customer to upload balance payment proof in the app. You can confirm once it appears above.',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontWeight: FontWeight.w700, color: Colors.orange.shade900),
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
                onAction: () async {
                  if (amountReceived.text.trim().isEmpty) {
                    appSnack(context, 'Enter amount received.');
                    return;
                  }
                  if (parsed == null) {
                    appSnack(context, 'Enter a valid amount.');
                    return;
                  }
                  if ((ar ?? 0) < o.total) {
                    appSnack(context, 'Amount received is less than the total.');
                    return;
                  }
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
                },
              ),
          ],
        ],
      ),
    );
      },
    );
  }
}
