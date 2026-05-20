/// API root for feature modules (matches [resolveInitialApiBase] in main.dart).
String featureApiBase(String configured) {
  var v = configured.trim().replaceAll(RegExp(r'/+$'), '');
  if (v.isEmpty) return v;
  return v;
}
