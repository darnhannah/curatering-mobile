import 'package:flutter_local_notifications/flutter_local_notifications.dart';

/// Local notifications for customer order attention (in addition to in-app badge).
/// True push when the app is killed requires FCM / APNs + server integration.
final FlutterLocalNotificationsPlugin customerLocalNotifications = FlutterLocalNotificationsPlugin();

bool _customerNotifsInitialized = false;
final Set<String> _notifiedOrderNos = <String>{};

Future<void> initCustomerLocalNotifications() async {
  if (_customerNotifsInitialized) return;
  const android = AndroidInitializationSettings('@mipmap/ic_launcher');
  const ios = DarwinInitializationSettings();
  await customerLocalNotifications.initialize(
    const InitializationSettings(android: android, iOS: ios),
  );
  _customerNotifsInitialized = true;
  final androidPlugin = customerLocalNotifications.resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>();
  await androidPlugin?.requestNotificationsPermission();
}

/// Shows at most once per order no. per app session (cleared on logout).
Future<void> showCashierReviewReminderIfNew(String orderNo) async {
  final key = orderNo.trim();
  if (key.isEmpty || _notifiedOrderNos.contains(key)) return;
  _notifiedOrderNos.add(key);
  const android = AndroidNotificationDetails(
    'cashier_review',
    'Order updates',
    channelDescription: 'Alerts when your order needs attention or cashier review',
    importance: Importance.high,
    priority: Priority.high,
  );
  const details = NotificationDetails(
    android: android,
    iOS: DarwinNotificationDetails(),
  );
  final id = key.hashCode & 0x7fffffff;
  await customerLocalNotifications.show(
    id,
    'Order update',
    '$orderNo — open the app and check My Orders (Pending confirmation).',
    details,
  );
}

void clearCustomerNotificationDedupe() {
  _notifiedOrderNos.clear();
}

/// Shown after payment proof is uploaded (order is pending cashier confirmation).
Future<void> showCustomerCheckoutCompleteNotification(String orderNo) async {
  await initCustomerLocalNotifications();
  const android = AndroidNotificationDetails(
    'customer_checkout',
    'Orders',
    channelDescription: 'Checkout and order status',
    importance: Importance.high,
    priority: Priority.high,
  );
  const details = NotificationDetails(
    android: android,
    iOS: DarwinNotificationDetails(),
  );
  final key = orderNo.trim();
  if (key.isEmpty) return;
  final id = key.hashCode & 0x7fffffff;
  await customerLocalNotifications.show(
    id,
    'Payment proof received',
    '$key — we received your payment proof. We will confirm your order after review.',
    details,
  );
}

/// POS / staff alerts (checkout validation, pending online orders, etc.).
Future<void> showStaffPosNotification(String title, String body) async {
  await initCustomerLocalNotifications();
  const android = AndroidNotificationDetails(
    'staff_pos',
    'Staff POS',
    channelDescription: 'Cashier and manager alerts while using the POS',
    importance: Importance.high,
    priority: Priority.high,
  );
  const details = NotificationDetails(
    android: android,
    iOS: DarwinNotificationDetails(),
  );
  final id = (title + body).hashCode & 0x7fffffff;
  await customerLocalNotifications.show(
    id,
    title,
    body,
    details,
  );
}
