import 'dart:convert';
import 'dart:math' as math;

/// Floor plan + tables + seats (normalized 0–1 coordinates). Matches server `seating_plan` JSONB.
class SeatingTableSpec {
  final String id;
  final String shape;
  final double xNorm;
  final double yNorm;
  final double wNorm;
  final double hNorm;
  final double rotationDeg;
  final String label;
  final int seatCount;

  const SeatingTableSpec({
    required this.id,
    required this.shape,
    required this.xNorm,
    required this.yNorm,
    required this.wNorm,
    required this.hNorm,
    required this.rotationDeg,
    required this.label,
    required this.seatCount,
  });

  SeatingTableSpec copyWith({
    String? id,
    String? shape,
    double? xNorm,
    double? yNorm,
    double? wNorm,
    double? hNorm,
    double? rotationDeg,
    String? label,
    int? seatCount,
  }) {
    return SeatingTableSpec(
      id: id ?? this.id,
      shape: shape ?? this.shape,
      xNorm: xNorm ?? this.xNorm,
      yNorm: yNorm ?? this.yNorm,
      wNorm: wNorm ?? this.wNorm,
      hNorm: hNorm ?? this.hNorm,
      rotationDeg: rotationDeg ?? this.rotationDeg,
      label: label ?? this.label,
      seatCount: seatCount ?? this.seatCount,
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'shape': shape,
        'xNorm': xNorm,
        'yNorm': yNorm,
        'wNorm': wNorm,
        'hNorm': hNorm,
        'rotationDeg': rotationDeg,
        'label': label,
        'seatCount': seatCount,
      };

  static SeatingTableSpec fromJson(Map<String, dynamic> m) {
    return SeatingTableSpec(
      id: (m['id'] ?? '').toString(),
      shape: (m['shape'] ?? 'rect').toString(),
      xNorm: _toDouble(m['xNorm'], 0.4),
      yNorm: _toDouble(m['yNorm'], 0.4),
      wNorm: _toDouble(m['wNorm'], 0.14),
      hNorm: _toDouble(m['hNorm'], 0.1),
      rotationDeg: _toDouble(m['rotationDeg'], 0),
      label: (m['label'] ?? 'Table').toString(),
      seatCount: math.max(0, math.min(100, _toInt(m['seatCount'], 6))),
    );
  }
}

class SeatingSeatSpec {
  final String id;
  final String tableId;
  final int index;
  final String label;
  final double perimeterT;
  final String? guestId;

  const SeatingSeatSpec({
    required this.id,
    required this.tableId,
    required this.index,
    required this.label,
    required this.perimeterT,
    this.guestId,
  });

  SeatingSeatSpec copyWith({
    String? id,
    String? tableId,
    int? index,
    String? label,
    double? perimeterT,
    String? guestId,
  }) {
    return SeatingSeatSpec(
      id: id ?? this.id,
      tableId: tableId ?? this.tableId,
      index: index ?? this.index,
      label: label ?? this.label,
      perimeterT: perimeterT ?? this.perimeterT,
      guestId: guestId ?? this.guestId,
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'tableId': tableId,
        'index': index,
        'label': label,
        'perimeterT': perimeterT,
        if (guestId != null && guestId!.isNotEmpty) 'guestId': guestId,
      };

  static SeatingSeatSpec fromJson(Map<String, dynamic> m) {
    return SeatingSeatSpec(
      id: (m['id'] ?? '').toString(),
      tableId: (m['tableId'] ?? '').toString(),
      index: _toInt(m['index'], 0),
      label: (m['label'] ?? '').toString(),
      perimeterT: _toDouble(m['perimeterT'], 0),
      guestId: m['guestId']?.toString(),
    );
  }
}

class SeatingPlanData {
  final int version;
  final String? floorImageUrl;
  final String? floorImageBase64;
  /// Preset venue footprint (e.g. banquet_rect). Mutually exclusive with floor images in the UI.
  final String? venueFloorShape;
  final List<SeatingTableSpec> tables;
  final List<SeatingSeatSpec> seats;

  const SeatingPlanData({
    this.version = 1,
    this.floorImageUrl,
    this.floorImageBase64,
    this.venueFloorShape,
    this.tables = const [],
    this.seats = const [],
  });

  static const SeatingPlanData empty = SeatingPlanData();

  bool get isEffectivelyEmpty =>
      tables.isEmpty &&
      seats.isEmpty &&
      (floorImageUrl == null || floorImageUrl!.trim().isEmpty) &&
      (floorImageBase64 == null || floorImageBase64!.trim().isEmpty) &&
      (venueFloorShape == null || venueFloorShape!.trim().isEmpty);

  Map<String, dynamic> toJson() => {
        'version': version,
        if (floorImageUrl != null && floorImageUrl!.trim().isNotEmpty)
          'floorImageUrl': floorImageUrl!.trim(),
        if (floorImageBase64 != null && floorImageBase64!.trim().isNotEmpty)
          'floorImageBase64': floorImageBase64!.trim(),
        if (venueFloorShape != null && venueFloorShape!.trim().isNotEmpty)
          'venueFloorShape': venueFloorShape!.trim(),
        'tables': tables.map((e) => e.toJson()).toList(),
        'seats': seats.map((e) => e.toJson()).toList(),
      };

  static SeatingPlanData fromJson(dynamic raw) {
    if (raw == null) return SeatingPlanData.empty;
    Map<String, dynamic> m;
    if (raw is Map<String, dynamic>) {
      m = raw;
    } else if (raw is String && raw.trim().isNotEmpty) {
      try {
        final d = jsonDecode(raw);
        if (d is Map<String, dynamic>) {
          m = d;
        } else {
          return SeatingPlanData.empty;
        }
      } catch (_) {
        return SeatingPlanData.empty;
      }
    } else {
      return SeatingPlanData.empty;
    }

    final tList = <SeatingTableSpec>[];
    for (final e in (m['tables'] is List ? m['tables'] as List : const [])) {
      if (e is Map) tList.add(SeatingTableSpec.fromJson(Map<String, dynamic>.from(e)));
    }
    final sList = <SeatingSeatSpec>[];
    for (final e in (m['seats'] is List ? m['seats'] as List : const [])) {
      if (e is Map) sList.add(SeatingSeatSpec.fromJson(Map<String, dynamic>.from(e)));
    }

    final rawFu = m['floorImageUrl'];
    String? fu;
    if (rawFu != null) {
      final s = rawFu.toString().trim();
      if (s.isNotEmpty) fu = s;
    }
    final rawB64 = m['floorImageBase64'];
    String? b64;
    if (rawB64 != null) {
      final s = rawB64.toString().trim();
      if (s.isNotEmpty) b64 = s;
    }
    final rawShape = m['venueFloorShape'];
    String? vshape;
    if (rawShape != null) {
      final s = rawShape.toString().trim();
      if (s.isNotEmpty) vshape = s;
    }

    return SeatingPlanData(
      version: math.max(1, _toInt(m['version'], 1)),
      floorImageUrl: fu,
      floorImageBase64: b64,
      venueFloorShape: vshape,
      tables: tList,
      seats: sList,
    );
  }

  SeatingPlanData copyWith({
    int? version,
    String? floorImageUrl,
    String? floorImageBase64,
    String? venueFloorShape,
    List<SeatingTableSpec>? tables,
    List<SeatingSeatSpec>? seats,
    bool clearFloorImageUrl = false,
    bool clearFloorImageBase64 = false,
    bool clearVenueFloorShape = false,
  }) {
    return SeatingPlanData(
      version: version ?? this.version,
      floorImageUrl: clearFloorImageUrl ? null : (floorImageUrl ?? this.floorImageUrl),
      floorImageBase64:
          clearFloorImageBase64 ? null : (floorImageBase64 ?? this.floorImageBase64),
      venueFloorShape:
          clearVenueFloorShape ? null : (venueFloorShape ?? this.venueFloorShape),
      tables: tables ?? this.tables,
      seats: seats ?? this.seats,
    );
  }

  /// Seats arranged on an ellipse around [table] (matches canvas placement).
  static List<SeatingSeatSpec> buildSeatsForTable(SeatingTableSpec table) {
    final n = table.seatCount;
    final out = <SeatingSeatSpec>[];
    for (var i = 0; i < n; i++) {
      final pt = n <= 1 ? 0.0 : i / n;
      out.add(
        SeatingSeatSpec(
          id: '${table.id}-s-$i',
          tableId: table.id,
          index: i,
          label: '${table.label}-${i + 1}',
          perimeterT: pt,
        ),
      );
    }
    return out;
  }

  /// Replace seats belonging to [tableId] and append new ones; keep other seats.
  SeatingPlanData withRegeneratedSeatsForTable(String tableId, SeatingTableSpec table) {
    final kept = seats.where((s) => s.tableId != tableId).toList();
    kept.addAll(buildSeatsForTable(table));
    kept.sort((a, b) {
      final ia = tables.indexWhere((t) => t.id == a.tableId);
      final ib = tables.indexWhere((t) => t.id == b.tableId);
      if (ia != ib) return ia.compareTo(ib);
      return a.index.compareTo(b.index);
    });
    return copyWith(seats: kept);
  }

  SeatingPlanData withAllSeatsRegenerated() {
    final next = <SeatingSeatSpec>[];
    for (final t in tables) {
      next.addAll(buildSeatsForTable(t));
    }
    return copyWith(seats: next);
  }
}

double _toDouble(dynamic v, double d) {
  if (v == null) return d;
  if (v is num) return v.toDouble();
  return double.tryParse(v.toString()) ?? d;
}

int _toInt(dynamic v, int d) {
  if (v == null) return d;
  if (v is num) return v.toInt();
  return int.tryParse(v.toString()) ?? d;
}
