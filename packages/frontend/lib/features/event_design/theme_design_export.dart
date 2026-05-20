import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:gal/gal.dart';
import 'package:http/http.dart' as http;
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:permission_handler/permission_handler.dart';
import 'package:printing/printing.dart';

Future<Uint8List?> themeDesignImageBytes(Map<String, dynamic> themeDesign) async {
  final b64 = '${themeDesign['image'] ?? themeDesign['imageBase64'] ?? themeDesign['output'] ?? ''}'.trim();
  if (b64.isNotEmpty) {
    try {
      return Uint8List.fromList(base64Decode(b64));
    } catch (_) {}
  }
  final url = '${themeDesign['generatedImageUrl'] ?? themeDesign['imageUrl'] ?? themeDesign['url'] ?? ''}'.trim();
  if (url.isEmpty) return null;
  try {
    final res = await http.get(Uri.parse(url)).timeout(const Duration(seconds: 45));
    if (res.statusCode == 200 && res.bodyBytes.isNotEmpty) return res.bodyBytes;
  } catch (_) {}
  return null;
}

Future<void> showThemeDesignFullscreen(BuildContext context, Map<String, dynamic> themeDesign) async {
  final bytes = await themeDesignImageBytes(themeDesign);
  final url = '${themeDesign['generatedImageUrl'] ?? themeDesign['imageUrl'] ?? ''}'.trim();
  if (bytes == null && url.isEmpty) return;
  if (!context.mounted) return;
  await showDialog<void>(
    context: context,
    barrierColor: Colors.black87,
    builder: (ctx) => Dialog(
      insetPadding: const EdgeInsets.all(16),
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 4, 0),
            child: Row(
              children: [
                const Expanded(
                  child: Text('Theme design', style: TextStyle(fontWeight: FontWeight.w800, fontSize: 16)),
                ),
                IconButton(icon: const Icon(Icons.close), onPressed: () => Navigator.pop(ctx)),
              ],
            ),
          ),
          Expanded(
            child: InteractiveViewer(
              child: bytes != null
                  ? Image.memory(bytes, fit: BoxFit.contain)
                  : Image.network(url, fit: BoxFit.contain),
            ),
          ),
        ],
      ),
    ),
  );
}

Future<bool> _ensureGalleryPermission() async {
  if (!await Gal.hasAccess()) {
    await Gal.requestAccess();
  }
  if (await Gal.hasAccess()) return true;
  final photos = await Permission.photos.request();
  if (photos.isGranted || photos.isLimited) return true;
  final storage = await Permission.storage.request();
  return storage.isGranted;
}

Future<void> saveThemeDesignImageToGallery({
  required BuildContext context,
  required Map<String, dynamic> themeDesign,
  String album = 'Curatering',
}) async {
  if (!context.mounted) return;
  final bytes = await themeDesignImageBytes(themeDesign);
  if (bytes == null || bytes.isEmpty) {
    throw StateError('No theme design image to save.');
  }
  final granted = await _ensureGalleryPermission();
  if (!granted) {
    throw StateError('Photo library permission is required to save the image.');
  }
  await Gal.putImageBytes(bytes, album: album);
}

Future<Uint8List> buildThemeDesignPdfBytes({
  required Map<String, dynamic> themeDesign,
  String eventTitle = '',
  String transactionNo = '',
}) async {
  final bytes = await themeDesignImageBytes(themeDesign);
  if (bytes == null || bytes.isEmpty) {
    throw StateError('No theme design image for PDF.');
  }
  final doc = pw.Document();
  final image = pw.MemoryImage(bytes);
  final header = [
    if (transactionNo.trim().isNotEmpty) transactionNo.trim(),
    if (eventTitle.trim().isNotEmpty) eventTitle.trim(),
  ].join(' — ');
  doc.addPage(
    pw.Page(
      pageFormat: PdfPageFormat.a4.landscape,
      margin: const pw.EdgeInsets.all(24),
      build: (_) => pw.Column(
        crossAxisAlignment: pw.CrossAxisAlignment.stretch,
        children: [
          if (header.isNotEmpty)
            pw.Padding(
              padding: const pw.EdgeInsets.only(bottom: 8),
              child: pw.Text(header, style: pw.TextStyle(fontSize: 11, fontWeight: pw.FontWeight.bold)),
            ),
          pw.Expanded(
            child: pw.Center(child: pw.Image(image, fit: pw.BoxFit.contain)),
          ),
        ],
      ),
    ),
  );
  return doc.save();
}

Future<void> previewThemeDesignPdf({
  required BuildContext context,
  required Map<String, dynamic> themeDesign,
  String eventTitle = '',
  String transactionNo = '',
}) async {
  final bytes = await buildThemeDesignPdfBytes(
    themeDesign: themeDesign,
    eventTitle: eventTitle,
    transactionNo: transactionNo,
  );
  await Printing.layoutPdf(onLayout: (_) async => bytes);
}
