import 'dart:convert';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

/// Max attachment size for customer/manager image uploads (event theme, seating floor, etc.).
const int kMaxImageAttachmentBytes = 25 * 1024 * 1024;

String imageAttachmentTooLargeMessage(int maxMb) =>
    'Each image must be $maxMb MB or smaller.';

/// Downscale a venue photo for AI generation so RunPod jobs finish faster.
Future<String> shrinkBase64ForAi(
  String raw, {
  int maxSide = 1280,
}) async {
  var s = raw.trim();
  if (s.startsWith('data:')) {
    final comma = s.indexOf(',');
    if (comma >= 0) s = s.substring(comma + 1);
  }
  s = s.replaceAll(RegExp(r'\s+'), '');
  if (s.isEmpty) return raw;
  // Already small enough (~900KB raw → ~1.2MB b64) — skip decode cost.
  if (s.length < 900000) return s;
  try {
    final bytes = base64Decode(s);
    final codec = await ui.instantiateImageCodec(bytes, targetWidth: maxSide);
    final frame = await codec.getNextFrame();
    final image = frame.image;
    final bd = await image.toByteData(format: ui.ImageByteFormat.png);
    image.dispose();
    codec.dispose();
    if (bd == null) return s;
    return base64Encode(Uint8List.view(bd.buffer));
  } catch (_) {
    return s;
  }
}

/// Pick one or more gallery images; skips files over [maxBytes]. Returns base64 strings.
Future<List<String>> pickImagesBase64({
  required BuildContext context,
  bool allowMultiple = true,
  int maxBytes = kMaxImageAttachmentBytes,
  int imageQuality = 88,
  int? maxWidth,
}) async {
  final picker = ImagePicker();
  final List<XFile> files;
  if (allowMultiple) {
    final multi = await picker.pickMultiImage(
      imageQuality: imageQuality,
      maxWidth: maxWidth?.toDouble(),
    );
    if (multi.isEmpty) return [];
    files = multi;
  } else {
    final one = await picker.pickImage(
      source: ImageSource.gallery,
      imageQuality: imageQuality,
      maxWidth: maxWidth?.toDouble(),
    );
    if (one == null) return [];
    files = [one];
  }

  final out = <String>[];
  var skipped = 0;
  for (final f in files) {
    final bytes = await f.readAsBytes();
    if (bytes.length > maxBytes) {
      skipped++;
      continue;
    }
    out.add(base64Encode(bytes));
  }
  if (skipped > 0 && context.mounted) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(imageAttachmentTooLargeMessage(maxBytes ~/ (1024 * 1024)))),
    );
  }
  return out;
}
