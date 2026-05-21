import 'package:flutter/material.dart';

/// Prevents duplicate pages/dialogs from rapid double-taps on buttons and tiles.
class NavigationGuard {
  NavigationGuard._();
  static final NavigationGuard instance = NavigationGuard._();

  static const Duration _tapCooldown = Duration(milliseconds: 700);

  bool _pushBusy = false;
  DateTime? _lastPushAt;
  String? _lastPushKey;
  final Set<String> _activeRouteKeys = <String>{};
  final Set<String> _openDialogKeys = <String>{};

  bool isDialogOpen(String key) => _openDialogKeys.contains(key);

  Future<T?> push<T extends Object?>(
    BuildContext context,
    Route<T> route, {
    required String routeKey,
    bool useRootNavigator = false,
  }) async {
    final key = routeKey.trim();
    if (key.isEmpty) return null;
    final now = DateTime.now();
    if (_pushBusy) return null;
    if (_activeRouteKeys.contains(key)) return null;
    if (_lastPushKey == key &&
        _lastPushAt != null &&
        now.difference(_lastPushAt!) < _tapCooldown) {
      return null;
    }
    _pushBusy = true;
    _activeRouteKeys.add(key);
    _lastPushKey = key;
    _lastPushAt = now;
    try {
      final navigator = useRootNavigator
          ? Navigator.of(context, rootNavigator: true)
          : Navigator.of(context);
      return await navigator.push<T>(route);
    } finally {
      _pushBusy = false;
      _activeRouteKeys.remove(key);
    }
  }

  Future<T?> pushPage<T extends Object?>(
    BuildContext context,
    Widget page, {
    bool useRootNavigator = false,
    String? routeKey,
  }) {
    final key = routeKey ?? page.runtimeType.toString();
    return push<T>(
      context,
      MaterialPageRoute<T>(
        settings: RouteSettings(name: key),
        builder: (_) => page,
      ),
      routeKey: key,
      useRootNavigator: useRootNavigator,
    );
  }
}

/// Push a screen once per [routeKey] / widget type (blocks double-tap duplicates).
Future<T?> pushMaterialPage<T extends Object?>(
  BuildContext context,
  Widget page, {
  String? routeKey,
  bool useRootNavigator = false,
}) {
  return NavigationGuard.instance.pushPage<T>(
    context,
    page,
    routeKey: routeKey,
    useRootNavigator: useRootNavigator,
  );
}

Future<T?> pushGuardedRoute<T extends Object?>(
  BuildContext context,
  Route<T> route, {
  String? routeKey,
  bool useRootNavigator = false,
}) {
  final key = routeKey ?? route.settings.name ?? route.runtimeType.toString();
  return NavigationGuard.instance.push<T>(
    context,
    route,
    routeKey: key,
    useRootNavigator: useRootNavigator,
  );
}

Future<T?> showGuardedDialog<T>({
  required BuildContext context,
  required WidgetBuilder builder,
  bool barrierDismissible = true,
  Color? barrierColor,
  bool useRootNavigator = false,
  String? dialogKey,
}) {
  final key = dialogKey ?? 'dialog';
  if (NavigationGuard.instance.isDialogOpen(key)) {
    return Future<T?>.value(null);
  }
  NavigationGuard.instance._openDialogKeys.add(key);
  return showDialog<T>(
    context: context,
    barrierDismissible: barrierDismissible,
    barrierColor: barrierColor,
    useRootNavigator: useRootNavigator,
    builder: builder,
  ).whenComplete(() {
    NavigationGuard.instance._openDialogKeys.remove(key);
  });
}

extension GuardedNavigation on BuildContext {
  Future<T?> pushPage<T extends Object?>(Widget page, {String? routeKey}) {
    return pushMaterialPage<T>(this, page, routeKey: routeKey);
  }
}
