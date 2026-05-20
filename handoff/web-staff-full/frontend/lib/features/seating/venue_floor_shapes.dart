import 'dart:math' as math;

import 'package:flutter/material.dart';

/// Preset venue footprints (alternative to uploading a floor photo).
/// IDs are stored in [SeatingPlanData.venueFloorShape] and validated on the server.
class VenueFloorShapeOption {
  final String id;
  final String title;
  final String subtitle;
  final IconData icon;

  const VenueFloorShapeOption({
    required this.id,
    required this.title,
    required this.subtitle,
    required this.icon,
  });
}

/// Five common event-venue layouts (rectangular hall, theater, round, U, L).
const List<VenueFloorShapeOption> kVenueFloorShapeOptions = [
  VenueFloorShapeOption(
    id: 'banquet_rect',
    title: 'Rectangular hall',
    subtitle: 'Banquet / ballroom',
    icon: Icons.crop_free,
  ),
  VenueFloorShapeOption(
    id: 'theater',
    title: 'Theater / auditorium',
    subtitle: 'Stage at front, fan seating',
    icon: Icons.theater_comedy_outlined,
  ),
  VenueFloorShapeOption(
    id: 'round_hall',
    title: 'Round / oval hall',
    subtitle: 'Rotunda, marquee, dome',
    icon: Icons.radio_button_unchecked,
  ),
  VenueFloorShapeOption(
    id: 'u_shape',
    title: 'U-shape room',
    subtitle: 'Hollow square, conference U',
    icon: Icons.view_column_outlined,
  ),
  VenueFloorShapeOption(
    id: 'l_shape',
    title: 'L-shaped room',
    subtitle: 'Corner wing layout',
    icon: Icons.turn_slight_right_outlined,
  ),
];

bool isKnownVenueFloorShape(String? id) {
  if (id == null || id.isEmpty) return false;
  for (final o in kVenueFloorShapeOptions) {
    if (o.id == id) return true;
  }
  return false;
}

/// Paints a light floor footprint for the seating canvas (normalized box is caller’s clip).
class VenueFloorShapePainter extends CustomPainter {
  VenueFloorShapePainter(this.shapeId);

  final String shapeId;

  static const Color _fill = Color(0xFFE8E4DC);
  static const Color _stroke = Color(0xFF8D8578);

  @override
  void paint(Canvas canvas, Size size) {
    final pad = size.shortestSide * 0.035;
    final r = Rect.fromLTRB(pad, pad, size.width - pad, size.height - pad);
    final fill = Paint()
      ..color = _fill
      ..style = PaintingStyle.fill;
    final stroke = Paint()
      ..color = _stroke
      ..style = PaintingStyle.stroke
      ..strokeWidth = math.max(1.5, size.shortestSide * 0.004);

    switch (shapeId) {
      case 'banquet_rect':
        final rr = RRect.fromRectAndRadius(r, Radius.circular(r.shortestSide * 0.02));
        canvas.drawRRect(rr, fill);
        canvas.drawRRect(rr, stroke);
        break;
      case 'theater':
        _paintTheater(canvas, r, fill, stroke);
        break;
      case 'round_hall':
        final oval = Rect.fromCenter(
          center: r.center,
          width: r.width * 0.94,
          height: r.height * 0.88,
        );
        final path = Path()..addOval(oval);
        canvas.drawPath(path, fill);
        canvas.drawPath(path, stroke);
        break;
      case 'u_shape':
        _paintUShape(canvas, r, fill, stroke);
        break;
      case 'l_shape':
        _paintLShape(canvas, r, fill, stroke);
        break;
      default:
        canvas.drawRect(r, fill);
        canvas.drawRect(r, stroke);
    }
  }

  void _paintTheater(Canvas canvas, Rect r, Paint fill, Paint stroke) {
    final stageW = r.width * 0.38;
    final cx = r.center.dx;
    final path = Path()
      ..moveTo(cx - stageW / 2, r.bottom)
      ..lineTo(cx + stageW / 2, r.bottom)
      ..lineTo(r.right - r.width * 0.02, r.top + r.height * 0.08)
      ..lineTo(r.left + r.width * 0.02, r.top + r.height * 0.08)
      ..close();
    canvas.drawPath(path, fill);
    canvas.drawPath(path, stroke);
    final stage = RRect.fromRectAndRadius(
      Rect.fromCenter(
        center: Offset(cx, r.bottom - r.height * 0.045),
        width: stageW * 1.05,
        height: r.height * 0.09,
      ),
      Radius.circular(3),
    );
    canvas.drawRRect(
      stage,
      Paint()
        ..color = const Color(0xFFD0CCC4)
        ..style = PaintingStyle.fill,
    );
    canvas.drawRRect(
      stage,
      Paint()
        ..color = _stroke
        ..style = PaintingStyle.stroke
        ..strokeWidth = math.max(1.0, stroke.strokeWidth * 0.85),
    );
  }

  void _paintUShape(Canvas canvas, Rect r, Paint fill, Paint stroke) {
    final t = math.min(r.width, r.height) * 0.14;
    final path = Path()
      ..addRect(Rect.fromLTRB(r.left, r.top, r.left + t, r.bottom))
      ..addRect(Rect.fromLTRB(r.right - t, r.top, r.right, r.bottom))
      ..addRect(Rect.fromLTRB(r.left, r.bottom - t, r.right, r.bottom));
    canvas.drawPath(path, fill);
    canvas.drawPath(path, stroke);
  }

  void _paintLShape(Canvas canvas, Rect r, Paint fill, Paint stroke) {
    final t = math.min(r.width, r.height) * 0.2;
    final path = Path()
      ..moveTo(r.left, r.bottom)
      ..lineTo(r.right, r.bottom)
      ..lineTo(r.right, r.bottom - t)
      ..lineTo(r.left + t, r.bottom - t)
      ..lineTo(r.left + t, r.top)
      ..lineTo(r.left, r.top)
      ..close();
    canvas.drawPath(path, fill);
    canvas.drawPath(path, stroke);
  }

  @override
  bool shouldRepaint(covariant VenueFloorShapePainter oldDelegate) {
    return oldDelegate.shapeId != shapeId;
  }
}
