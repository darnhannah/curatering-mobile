import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:image_picker/image_picker.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

void main() {
  runApp(const CurateringApp());
}

class CurateringApp extends StatefulWidget {
  const CurateringApp({super.key});

  @override
  State<CurateringApp> createState() => _CurateringAppState();
}

class _CurateringAppState extends State<CurateringApp> {
  final appState = AppState();

  @override
  void initState() {
    super.initState();
    SharedPreferences.getInstance().then((p) {
      final saved = p.getString('api_base')?.trim();
      if (saved != null && saved.isNotEmpty) {
        appState.setApiBase(saved);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: appState,
      builder: (context, _) {
        return MaterialApp(
          debugShowCheckedModeBanner: false,
          title: 'Curatering',
          theme: ThemeData(
            useMaterial3: true,
            scaffoldBackgroundColor: AppColors.canvas,
            colorScheme: ColorScheme.fromSeed(seedColor: AppColors.brand),
            inputDecorationTheme: InputDecorationTheme(
              filled: true,
              fillColor: Colors.white,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(10),
              ),
            ),
          ),
          home: appState.userEmail == null
              ? AuthScreen(state: appState)
              : RestaurantMenuScreen(state: appState),
        );
      },
    );
  }
}

const Duration _apiTimeout = Duration(seconds: 30);

/// Local Node backend is HTTP-only; [https] to these hosts breaks TLS handshakes.
bool _devBackendHttpHost(String host) {
  final h = host.toLowerCase();
  if (h == 'localhost' || h == '127.0.0.1' || h == '10.0.2.2') return true;
  if (h.startsWith('192.168.')) return true;
  return false;
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

const int kMinCateringPax = 50;
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

  bool get isRestaurantDish => category.toLowerCase().trim() == 'restaurant';
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
  });

  String fullName;
  String contactNumber;
  String deliveryAddress;
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

class OrderData {
  OrderData({
    required this.id,
    required this.orderNo,
    required this.status,
    required this.total,
    required this.createdAt,
    this.paymentUploaded = false,
    this.lines = const [],
  });

  final int id;
  final String orderNo;
  final String status;
  final double total;
  final DateTime createdAt;
  final bool paymentUploaded;
  final List<OrderLineItem> lines;
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
  String apiBase = const String.fromEnvironment(
    'API_BASE',
    defaultValue: 'http://localhost:8080',
  );
  String? userEmail;
  String loginPassword = '';
  ProfileData profile = ProfileData();
  final List<MenuItemData> menu = [];
  final List<CartItem> tray = [];
  final List<OrderData> orders = [];
  final List<InquiryRecord> inquiries = [];
  final List<SetMenuData> setMenus = [];
  String checkoutNote = '';

  void setApiBase(String value) {
    apiBase = normalizeApiBase(value);
    notifyListeners();
    SharedPreferences.getInstance().then((p) => p.setString('api_base', apiBase));
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
      userEmail = email.trim().toLowerCase();
      loginPassword = password;
      await Future.wait([
        loadMenu(),
        loadSetMenus(),
        loadProfile(),
        loadOrders(),
        loadInquiries(),
      ]);
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
            price: (map['price'] as num).toDouble(),
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
      final order = OrderData(
        id: (map['id'] as num).toInt(),
        orderNo: '${map['order_no']}',
        status: 'WAITING FOR ORDER CONFIRMATION',
        total: (map['total'] as num).toDouble(),
        createdAt: DateTime.now(),
      );
      tray.clear();
      checkoutNote = '';
      await loadOrders();
      notifyListeners();
      return SubmitOrderResult(order: order);
    } catch (e) {
      return SubmitOrderResult(error: describeApiNetworkError(e, normalizeApiBase(apiBase)));
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
    orders
      ..clear()
      ..addAll(
        body.map((e) {
          final map = e as Map<String, dynamic>;
          final rawItems = map['items'];
          final lines = <OrderLineItem>[];
          if (rawItems is List) {
            for (final it in rawItems) {
              final m = it as Map<String, dynamic>;
              lines.add(
                OrderLineItem(
                  itemName: '${m['item_name']}',
                  dip: '${m['dip']}',
                  qty: (m['qty'] as num).toInt(),
                  price: (m['price'] as num).toDouble(),
                ),
              );
            }
          }
          return OrderData(
            id: (map['id'] as num).toInt(),
            orderNo: '${map['order_no']}',
            status: '${map['status']}',
            total: (map['total'] as num).toDouble(),
            createdAt: DateTime.parse('${map['created_at']}'),
            paymentUploaded: map['payment_uploaded'] == true,
            lines: lines,
          );
        }),
      );
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
    inquiries
      ..clear()
      ..addAll(
        body.map((e) {
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
          return InquiryRecord(
            id: (map['id'] as num).toInt(),
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
            curateOwnMenu: map['curate_own_menu'] == true,
            selectedSetMenu: '${map['selected_set_menu']}',
            selectedDishes: dishes,
            includeEventTheme: map['include_event_theme'] == true,
            guestCount: (map['guest_count'] as num?)?.toInt() ?? 0,
            menuSuggestionNote: '${map['menu_suggestion_note'] ?? ''}',
            themeSuggestionNote: '${map['theme_suggestion_note'] ?? ''}',
            estimatedTotal: (map['estimated_total'] as num?)?.toDouble() ?? 0,
            status: '${map['status']}',
            createdAt: DateTime.parse('${map['created_at']}'),
          );
        }),
      );
    notifyListeners();
  }
}

class AuthScreen extends StatefulWidget {
  const AuthScreen({super.key, required this.state});
  final AppState state;

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
                      if (signupMode) ...[
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
          decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(12)),
          padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 16),
          child: Text(title, style: const TextStyle(fontWeight: FontWeight.w800)),
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
                const Text('Curatering', style: TextStyle(fontSize: 28, fontWeight: FontWeight.w900)),
                if (greet.isNotEmpty) Text('Hi, $greet!', style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
              ],
            ),
          ),
          ListTile(title: const Text('Restaurant'), onTap: () => open(context, RestaurantMenuScreen(state: state))),
          ListTile(title: const Text('Your Tray'), onTap: () => open(context, TrayScreen(state: state))),
          ListTile(title: const Text('My Orders'), onTap: () => open(context, MyOrdersScreen(state: state))),
          ListTile(title: const Text('My Profile'), onTap: () => open(context, MyProfileScreen(state: state))),
          ListTile(title: const Text('Catering Inquiry'), onTap: () => open(context, InquiryScreen(state: state))),
          ListTile(title: const Text('My Inquiries'), onTap: () => open(context, MyInquiriesScreen(state: state))),
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
  const _MenuThumb({required this.item});
  final MenuItemData item;

  @override
  Widget build(BuildContext context) {
    final raw = item.imageBase64?.trim();
    if (raw != null && raw.isNotEmpty) {
      try {
        final bytes = base64Decode(raw);
        return Image.memory(Uint8List.fromList(bytes), fit: BoxFit.cover);
      } catch (_) {}
    }
    return const Icon(Icons.fastfood, size: 60);
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
                _OrderNoCard(orderNo: 'Generated automatically after you confirm'),
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
  bool paymentUploaded = false;
  bool showPayment = true;
  bool showNotes = true;
  bool showDelivery = true;
  XFile? uploadedFile;

  @override
  Widget build(BuildContext context) {
    final s = widget.state;
    final p = s.profile;
    return AppScaffold(
      state: s,
      title: 'PAYMENT',
      body: Column(
        children: [
          Expanded(
            child: ListView(
              padding: const EdgeInsets.all(12),
              children: [
                _OrderNoCard(orderNo: widget.order.orderNo),
                const SizedBox(height: 10),
                ToggleSection(
                  title: 'PAYMENT',
                  titleColor: paymentUploaded ? AppColors.brand : AppColors.accent,
                  expanded: showPayment,
                  onToggle: () => setState(() => showPayment = !showPayment),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text('Please scan the QR code below to pay'),
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
                          const Expanded(child: Text('Once paid, upload proof of payment')),
                          OutlinedButton(
                            onPressed: () async {
                              final picker = ImagePicker();
                              final file = await picker.pickImage(source: ImageSource.gallery);
                              if (file == null) return;
                              await s.uploadPaymentProof(widget.order.id, file);
                              if (!mounted) return;
                              setState(() {
                                uploadedFile = file;
                                paymentUploaded = true;
                              });
                              appSnack(context, 'Payment proof uploaded');
                            },
                            child: Text(uploadedFile == null ? 'UPLOAD' : 'UPLOADED'),
                          ),
                        ],
                      ),
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
            lines: [SummaryLine('YOUR ORDER', '₱${widget.order.total.toStringAsFixed(2)}'), SummaryLine('TOTAL', '₱${widget.order.total.toStringAsFixed(2)}', isTotal: true)],
            secondaryLabel: 'BACK',
            actionLabel: 'VIEW ORDER STATUS',
            onSecondary: () => Navigator.of(context).pop(),
            onAction: () {
              Navigator.of(context).pushReplacement(
                MaterialPageRoute<void>(
                  builder: (_) => OrderStatusScreen(state: s, order: widget.order, paymentUploaded: paymentUploaded),
                ),
              );
            },
          ),
        ],
      ),
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

class _MyOrdersScreenState extends State<MyOrdersScreen> {
  /// false = payment / proof still pending; true = proof uploaded
  bool showPaymentDone = false;

  @override
  Widget build(BuildContext context) {
    final filtered = widget.state.orders.where((o) => showPaymentDone ? o.paymentUploaded : !o.paymentUploaded).toList();
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
                  child: FilterChip(
                    label: const Text('PAYMENT PENDING'),
                    selected: !showPaymentDone,
                    onSelected: (_) => setState(() => showPaymentDone = false),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: FilterChip(
                    label: const Text('PAYMENT SENT'),
                    selected: showPaymentDone,
                    onSelected: (_) => setState(() => showPaymentDone = true),
                  ),
                ),
              ],
            ),
          ),
          Expanded(
            child: RefreshIndicator(
              onRefresh: widget.state.loadOrders,
              child: ListView.builder(
                itemCount: filtered.length,
                itemBuilder: (context, index) {
                  final o = filtered[index];
                  return Card(
                    margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                    child: ListTile(
                      title: Text(o.orderNo),
                      subtitle: Text('${o.status}\n${o.createdAt.toLocal()}'),
                      trailing: Text('₱${o.total.toStringAsFixed(2)}'),
                      onTap: () {
                        final lines = o.lines
                            .map((l) => '${l.itemName} (${l.dip.isEmpty ? 'no dip' : l.dip}) ×${l.qty}  ₱${(l.qty * l.price).toStringAsFixed(2)}')
                            .join('\n');
                        showDialog<void>(
                          context: context,
                          builder: (_) => AlertDialog(
                            title: Text(o.orderNo),
                            content: SingleChildScrollView(
                              child: Text(
                                'Status: ${o.status}\n'
                                'Placed: ${o.createdAt.toLocal()}\n'
                                'Payment proof uploaded: ${o.paymentUploaded ? 'Yes' : 'No'}\n\n'
                                'Items:\n$lines\n\n'
                                'Total: ₱${o.total.toStringAsFixed(2)}',
                              ),
                            ),
                            actions: [TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Close'))],
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

  @override
  void initState() {
    super.initState();
    final p = widget.state.profile;
    nameController = TextEditingController(text: p.fullName);
    contactController = TextEditingController(text: p.contactNumber);
    addressController = TextEditingController(text: p.deliveryAddress);
  }

  Future<void> _openMaps() async {
    final q = Uri.encodeComponent(addressController.text.trim());
    if (q.isEmpty) {
      appSnack(context, 'Enter a delivery address first');
      return;
    }
    final u = Uri.parse('https://www.google.com/maps/search/?api=1&query=$q');
    if (await canLaunchUrl(u)) {
      await launchUrl(u, mode: LaunchMode.externalApplication);
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
                  OutlinedButton.icon(
                    onPressed: _openMaps,
                    icon: const Icon(Icons.map_outlined),
                    label: const Text('OPEN ADDRESS IN GOOGLE MAPS'),
                  ),
                  const SizedBox(height: 8),
                  const Text(
                    'Pins your saved address in the Google Maps app or browser.',
                    style: TextStyle(fontSize: 12),
                  ),
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

class InquiryScreen extends StatefulWidget {
  const InquiryScreen({super.key, required this.state});
  final AppState state;
  @override
  State<InquiryScreen> createState() => _InquiryScreenState();
}

class _InquiryScreenState extends State<InquiryScreen> {
  String inquiryType = 'CATERING';
  bool curateOwn = false;
  String selectedSetMenu = 'All Dishes';
  final selectedDishes = <String>{};
  final guestCount = TextEditingController(text: '$kMinCateringPax');
  String menuSuggestionNote = '';
  String themeSuggestionNote = '';
  final eventTitle = TextEditingController();
  final eventType = TextEditingController();
  final customer = TextEditingController();
  final contactPerson = TextEditingController();
  final contactNumber = TextEditingController();
  final inquiryEmail = TextEditingController();
  final dateOfEvent = TextEditingController();
  final note = TextEditingController();

  @override
  void initState() {
    super.initState();
    final p = widget.state.profile;
    customer.text = p.fullName;
    contactPerson.text = p.fullName;
    contactNumber.text = p.contactNumber;
    inquiryEmail.text = widget.state.userEmail ?? '';
  }

  @override
  void dispose() {
    guestCount.dispose();
    eventTitle.dispose();
    eventType.dispose();
    customer.dispose();
    contactPerson.dispose();
    contactNumber.dispose();
    inquiryEmail.dispose();
    dateOfEvent.dispose();
    note.dispose();
    super.dispose();
  }

  double _estimateTotal(AppState state, List<MenuItemData> cateringMenu) {
    final guests = int.tryParse(guestCount.text.trim()) ?? 0;
    final billablePax = guests < kMinCateringPax ? kMinCateringPax : guests;
    var dishSum = 0.0;
    for (final n in selectedDishes) {
      final matches = cateringMenu.where((x) => x.name == n);
      if (matches.isNotEmpty) dishSum += matches.first.price;
    }
    return billablePax * kPesosPerPax + dishSum;
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
    final estimate = _estimateTotal(state, cateringMenu);
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
                const SizedBox(height: 10),
                Text(
                  'Minimum number of guests for catering and events is $kMinCateringPax pax. Estimates use ₱${kPesosPerPax.toStringAsFixed(0)} per guest (billable pax is at least $kMinCateringPax) plus selected dish prices.',
                  style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 10),
                ToggleSection(
                  title: 'EVENT INFORMATION',
                  expanded: true,
                  onToggle: () {},
                  hideToggleIcon: true,
                  child: Column(
                    children: [
                      TextField(controller: eventTitle, decoration: const InputDecoration(labelText: 'Event Title')),
                      const SizedBox(height: 8),
                      TextField(controller: eventType, decoration: const InputDecoration(labelText: 'Event Type')),
                      const SizedBox(height: 8),
                      TextField(controller: customer, decoration: const InputDecoration(labelText: 'Customer')),
                      const SizedBox(height: 8),
                      TextField(controller: contactPerson, decoration: const InputDecoration(labelText: 'Contact Person')),
                      const SizedBox(height: 8),
                      TextField(controller: contactNumber, decoration: const InputDecoration(labelText: 'Contact Number')),
                      const SizedBox(height: 8),
                      TextField(controller: inquiryEmail, decoration: const InputDecoration(labelText: 'Email')),
                      const SizedBox(height: 8),
                      TextField(controller: dateOfEvent, decoration: const InputDecoration(labelText: 'Date of Event')),
                      const SizedBox(height: 8),
                      TextField(
                        controller: guestCount,
                        decoration: const InputDecoration(labelText: 'Number of guests'),
                        keyboardType: TextInputType.number,
                        onChanged: (_) => setState(() {}),
                      ),
                      const SizedBox(height: 8),
                      TextField(controller: note, decoration: const InputDecoration(labelText: 'Note')),
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
                        Wrap(
                          spacing: 8,
                          runSpacing: 8,
                          children: availableDishes.map((dishName) {
                            MenuItemData? dish;
                            for (final c in cateringMenu) {
                              if (c.name == dishName) {
                                dish = c;
                                break;
                              }
                            }
                            return SizedBox(
                              width: 120,
                              child: FilterChip(
                                label: Column(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    SizedBox(
                                      height: 48,
                                      width: double.infinity,
                                      child: dish != null ? _MenuThumb(item: dish) : const Icon(Icons.fastfood),
                                    ),
                                    Text(dishName, textAlign: TextAlign.center, style: const TextStyle(fontSize: 11)),
                                  ],
                                ),
                                selected: selectedDishes.contains(dishName),
                                onSelected: (v) => setState(() {
                                  if (v) {
                                    selectedDishes.add(dishName);
                                  } else {
                                    selectedDishes.remove(dishName);
                                  }
                                }),
                              ),
                            );
                          }).toList(),
                        ),
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
              SummaryLine('Estimated total (incl. menu selections)', '₱${estimate.toStringAsFixed(2)}', isTotal: true),
            ],
            secondaryLabel: 'CANCEL',
            actionLabel: 'SUBMIT',
            onSecondary: () => Navigator.of(context).pop(),
            onAction: () async {
              final guests = int.tryParse(guestCount.text.trim()) ?? 0;
              if (guests < kMinCateringPax) {
                appSnack(context, 'Please enter at least $kMinCateringPax guests (minimum for catering/events).');
                return;
              }
              final err = await state.submitInquiry({
                'inquiry_type': inquiryType,
                'event_title': eventTitle.text.trim(),
                'event_type': eventType.text.trim(),
                'customer': customer.text.trim(),
                'contact_person': contactPerson.text.trim(),
                'contact_number': contactNumber.text.trim(),
                'inquiry_email': inquiryEmail.text.trim(),
                'date_of_event': dateOfEvent.text.trim(),
                'note': note.text.trim(),
                'curate_own_menu': curateOwn,
                'selected_set_menu': selectedSetMenu,
                'selected_dishes': selectedDishes.toList(),
                'include_event_theme': inquiryType == 'CATERING AND EVENT',
                'guest_count': guests,
                'estimated_total': estimate,
                'menu_suggestion_note': menuSuggestionNote,
                'theme_suggestion_note': themeSuggestionNote,
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

  void _showDetail(InquiryRecord r) {
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(r.inquiryNo),
        content: SingleChildScrollView(
          child: Text(
            'Type: ${r.inquiryType}\n'
            'Status: ${r.status}\n'
            'Event: ${r.eventTitle}\n'
            'Event type: ${r.eventType}\n'
            'Guests: ${r.guestCount}\n'
            'Customer: ${r.customer}\n'
            'Contact: ${r.contactPerson} / ${r.contactNumber}\n'
            'Email: ${r.inquiryEmail}\n'
            'Date: ${r.dateOfEvent}\n'
            'Note: ${r.note}\n'
            'Curate menu: ${r.curateOwnMenu}\n'
            'Set menu: ${r.selectedSetMenu}\n'
            'Dishes: ${r.selectedDishes.join(', ')}\n'
            'Menu note: ${r.menuSuggestionNote}\n'
            'Theme note: ${r.themeSuggestionNote}\n'
            'Est. total: ₱${r.estimatedTotal.toStringAsFixed(2)}\n'
            'Submitted: ${r.createdAt.toLocal()}',
          ),
        ),
        actions: [TextButton(onPressed: () => Navigator.of(ctx).pop(), child: const Text('Close'))],
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
                      onTap: () => _showDetail(i),
                    ),
                  );
                },
              ),
      );
    }

    return AppScaffold(
      state: s,
      title: 'MY INQUIRIES',
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
        MaterialPageRoute<void>(builder: (_) => AuthScreen(state: widget.state)),
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
    return AppScaffold(
      state: widget.state,
      title: 'SETTINGS',
      body: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
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
  const _OrderNoCard({required this.orderNo});
  final String orderNo;
  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(12), border: Border.all(color: AppColors.brand)),
      child: Text('ORDER NO. $orderNo', style: const TextStyle(fontWeight: FontWeight.w700)),
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
