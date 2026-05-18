import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';
import 'package:share_plus/share_plus.dart';

import 'seating_plan.dart';
import 'seating_plan_canvas.dart';

/// Build a landscape PDF of the seating layout (tables + seat counts).
Future<Uint8List> buildSeatingLayoutPdfBytes({
  required SeatingPlanData plan,
  String eventTitle = '',
  String transactionNo = '',
}) async {
  final doc = pw.Document();
  const pageW = 792.0;
  const pageH = 612.0;
  const margin = 36.0;
  final drawW = pageW - margin * 2;
  final drawH = pageH - margin * 2 - 48;

  doc.addPage(
    pw.Page(
      pageFormat: PdfPageFormat(pageW, pageH, marginAll: margin),
      build: (ctx) {
        return pw.Column(
          crossAxisAlignment: pw.CrossAxisAlignment.start,
          children: [
            pw.Text(
              'Seating layout',
              style: pw.TextStyle(fontSize: 18, fontWeight: pw.FontWeight.bold),
            ),
            if (eventTitle.trim().isNotEmpty) pw.Text('Event: ${eventTitle.trim()}'),
            if (transactionNo.trim().isNotEmpty) pw.Text('Reference: ${transactionNo.trim()}'),
            pw.Text('Generated: ${DateTime.now().toLocal()}'),
            pw.SizedBox(height: 12),
            pw.Container(
              width: drawW,
              height: drawH,
              decoration: pw.BoxDecoration(
                border: pw.Border.all(color: PdfColors.grey500, width: 0.5),
              ),
              child: pw.Stack(
                children: [
                  for (final t in plan.tables)
                    pw.Transform.translate(
                      offset: PdfPoint(t.xNorm * drawW, t.yNorm * drawH),
                      child: pw.Container(
                        width: t.wNorm * drawW,
                        height: t.hNorm * drawH,
                        decoration: pw.BoxDecoration(
                          border: pw.Border.all(color: PdfColors.black, width: 0.8),
                          color: PdfColors.grey200,
                        ),
                        alignment: pw.Alignment.center,
                        child: pw.Text(
                          '${t.label}\n${t.seatCount} seats',
                          textAlign: pw.TextAlign.center,
                          style: const pw.TextStyle(fontSize: 8),
                        ),
                      ),
                    ),
                ],
              ),
            ),
            pw.SizedBox(height: 8),
            pw.Text(
              'Tables: ${plan.tables.length} · Seats: ${plan.seats.length}',
              style: const pw.TextStyle(fontSize: 9, color: PdfColors.grey700),
            ),
          ],
        );
      },
    ),
  );
  return doc.save();
}

Future<void> previewSeatingLayoutPdf({
  required SeatingPlanData plan,
  String eventTitle = '',
  String transactionNo = '',
}) async {
  final bytes = await buildSeatingLayoutPdfBytes(
    plan: plan,
    eventTitle: eventTitle,
    transactionNo: transactionNo,
  );
  await Printing.layoutPdf(onLayout: (_) async => bytes);
}

Future<void> shareSeatingLayoutPdf({
  required SeatingPlanData plan,
  String eventTitle = '',
  String transactionNo = '',
  String filename = 'seating-layout.pdf',
}) async {
  final bytes = await buildSeatingLayoutPdfBytes(
    plan: plan,
    eventTitle: eventTitle,
    transactionNo: transactionNo,
  );
  await Printing.sharePdf(bytes: bytes, filename: filename);
}

/// Capture the interactive canvas as PNG and open the system share sheet.
Future<void> shareSeatingLayoutImage({
  required BuildContext context,
  required SeatingPlanData plan,
  String filename = 'seating-layout.png',
}) async {
  if (!context.mounted) return;
  final boundaryKey = GlobalKey();
  await showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (dialogCtx) {
      WidgetsBinding.instance.addPostFrameCallback((_) async {
        await Future<void>.delayed(const Duration(milliseconds: 80));
        try {
          final boundary = boundaryKey.currentContext?.findRenderObject();
          if (boundary is! RenderRepaintBoundary) {
            throw StateError('Could not capture seating layout image');
          }
          final image = await boundary.toImage(pixelRatio: 2);
          final byteData = await image.toByteData(format: ui.ImageByteFormat.png);
          if (byteData == null) throw StateError('Could not encode seating layout PNG');
          final bytes = byteData.buffer.asUint8List();
          if (dialogCtx.mounted) Navigator.of(dialogCtx).pop();
          final xfile = XFile.fromData(bytes, mimeType: 'image/png', name: filename);
          await Share.shareXFiles([xfile], text: 'Seating layout');
        } catch (e) {
          if (dialogCtx.mounted) {
            Navigator.of(dialogCtx).pop();
            ScaffoldMessenger.maybeOf(context)?.showSnackBar(
              SnackBar(content: Text('$e'), backgroundColor: Colors.red.shade700),
            );
          }
        }
      });
      return Center(
        child: Material(
          color: Colors.transparent,
          child: RepaintBoundary(
            key: boundaryKey,
            child: Container(
              width: 900,
              height: 620,
              color: Colors.white,
              padding: const EdgeInsets.all(8),
              child: SeatingPlanInteractive(plan: plan, editable: false),
            ),
          ),
        ),
      );
    },
  );
}
