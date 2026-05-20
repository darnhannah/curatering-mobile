import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import '../../utils/image_pick_limits.dart';
import 'seating_plan.dart';
import 'venue_floor_shapes.dart';

/// Normalized seat position on an ellipse around the table (matches server expectations).
Offset seatNormOnEllipse(SeatingTableSpec t, SeatingSeatSpec s) {
  final cx = t.xNorm + t.wNorm / 2;
  final cy = t.yNorm + t.hNorm / 2;
  final rx = t.wNorm / 2 + 0.018;
  final ry = t.hNorm / 2 + 0.018;
  final ang = s.perimeterT * 2 * math.pi - math.pi / 2;
  return Offset(cx + rx * math.cos(ang), cy + ry * math.sin(ang));
}

enum _TableResizeCorner { nw, ne, sw, se }

/// Map a normalized canvas point to ellipse parameter [perimeterT] in [0, 1).
double perimeterTFromNormPoint(SeatingTableSpec t, double nx, double ny) {
  final rcx = t.xNorm + t.wNorm / 2;
  final rcy = t.yNorm + t.hNorm / 2;
  final rx = t.wNorm / 2 + 0.018;
  final ry = t.hNorm / 2 + 0.018;
  if (rx < 1e-6 || ry < 1e-6) return 0;
  final ang = math.atan2((ny - rcy) / ry, (nx - rcx) / rx);
  var pt = (ang + math.pi / 2) / (2 * math.pi);
  while (pt < 0) {
    pt += 1;
  }
  while (pt >= 1) {
    pt -= 1;
  }
  return pt;
}

class SeatingPlanInteractive extends StatefulWidget {
  final SeatingPlanData plan;
  final bool editable;
  final ValueChanged<SeatingPlanData>? onChanged;
  /// Venue reference photos from event theme design (base64) — selectable as floor background.
  final List<String> venueReferencePhotosBase64;

  const SeatingPlanInteractive({
    super.key,
    required this.plan,
    this.editable = false,
    this.onChanged,
    this.venueReferencePhotosBase64 = const [],
  });

  @override
  State<SeatingPlanInteractive> createState() => _SeatingPlanInteractiveState();
}

class _SeatingPlanInteractiveState extends State<SeatingPlanInteractive> {
  String? _selectedTableId;
  String? _selectedSeatId;
  final Map<String, TextEditingController> _labelCtrls = {};
  final Map<String, TextEditingController> _seatLabelCtrls = {};

  @override
  void dispose() {
    for (final c in _labelCtrls.values) {
      c.dispose();
    }
    for (final c in _seatLabelCtrls.values) {
      c.dispose();
    }
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant SeatingPlanInteractive oldWidget) {
    super.didUpdateWidget(oldWidget);
    final ids = widget.plan.tables.map((t) => t.id).toSet();
    _labelCtrls.removeWhere((id, c) {
      if (!ids.contains(id)) {
        c.dispose();
        return true;
      }
      return false;
    });
    for (final t in widget.plan.tables) {
      final c = _labelCtrls[t.id];
      // Do not overwrite the field while this table is selected (user may be typing).
      if (c != null && c.text != t.label && t.id != _selectedTableId) {
        c.value = TextEditingValue(
          text: t.label,
          selection: TextSelection.collapsed(offset: t.label.length),
        );
      }
    }
    final seatIds = widget.plan.seats.map((s) => s.id).toSet();
    _seatLabelCtrls.removeWhere((id, c) {
      if (!seatIds.contains(id)) {
        c.dispose();
        return true;
      }
      return false;
    });
    for (final s in widget.plan.seats) {
      final c = _seatLabelCtrls[s.id];
      if (c != null && c.text != s.label && s.id != _selectedSeatId) {
        c.value = TextEditingValue(
          text: s.label,
          selection: TextSelection.collapsed(offset: s.label.length),
        );
      }
    }
    if (_selectedSeatId != null && !seatIds.contains(_selectedSeatId)) {
      _selectedSeatId = null;
    }
  }

  TextEditingController _labelCtrl(String tableId, String initial) {
    return _labelCtrls.putIfAbsent(
      tableId,
      () => TextEditingController(text: initial),
    );
  }

  TextEditingController _seatLabelCtrl(String seatId, String initial) {
    return _seatLabelCtrls.putIfAbsent(
      seatId,
      () => TextEditingController(text: initial),
    );
  }

  void _emit(SeatingPlanData next) {
    widget.onChanged?.call(next);
  }

  Future<void> _pickFloorImage() async {
    final added = await pickImagesBase64(context: context, allowMultiple: false);
    if (!mounted || added.isEmpty) return;
    _emit(
      widget.plan.copyWith(
        floorImageBase64: added.first,
        clearFloorImageUrl: true,
        clearVenueFloorShape: true,
      ),
    );
  }

  void _useVenueReferenceAsFloor(String b64) {
    _emit(
      widget.plan.copyWith(
        floorImageBase64: b64,
        clearFloorImageUrl: true,
        clearVenueFloorShape: true,
      ),
    );
  }

  void _clearFloor() {
    _emit(
      widget.plan.copyWith(
        clearFloorImageBase64: true,
        clearFloorImageUrl: true,
        clearVenueFloorShape: true,
      ),
    );
  }

  void _applyVenueFloorShape(String shapeId) {
    _emit(
      widget.plan.copyWith(
        venueFloorShape: shapeId,
        clearFloorImageBase64: true,
        clearFloorImageUrl: true,
      ),
    );
  }

  Future<void> _pickVenueFloorShape() async {
    final chosen = await showDialog<String>(
      context: context,
      builder: (ctx) {
        return AlertDialog(
          title: const Text('Venue shape'),
          content: SizedBox(
            width: 420,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    'Pick a common room footprint instead of uploading a photo. '
                    'You can still drag tables on top of it.',
                    style: TextStyle(fontSize: 13, color: Colors.grey.shade700),
                  ),
                  const SizedBox(height: 16),
                  for (var i = 0; i < kVenueFloorShapeOptions.length; i++) ...[
                    InkWell(
                      onTap: () => Navigator.pop(ctx, kVenueFloorShapeOptions[i].id),
                      borderRadius: BorderRadius.circular(10),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 4),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Icon(
                              kVenueFloorShapeOptions[i].icon,
                              size: 28,
                              color: const Color(0xFF2E2E2E),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    kVenueFloorShapeOptions[i].title,
                                    style: const TextStyle(
                                      fontWeight: FontWeight.w700,
                                      fontSize: 15,
                                    ),
                                  ),
                                  const SizedBox(height: 2),
                                  Text(
                                    kVenueFloorShapeOptions[i].subtitle,
                                    style: TextStyle(
                                      fontSize: 12,
                                      color: Colors.grey.shade600,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            SizedBox(
                              width: 56,
                              height: 36,
                              child: CustomPaint(
                                painter: VenueFloorShapePainter(
                                  kVenueFloorShapeOptions[i].id,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                    if (i < kVenueFloorShapeOptions.length - 1) const Divider(height: 1),
                  ],
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Cancel'),
            ),
          ],
        );
      },
    );
    if (!mounted || chosen == null) return;
    _applyVenueFloorShape(chosen);
  }

  void _addChair() {
    final id = 'chair-${DateTime.now().millisecondsSinceEpoch}';
    final idx = widget.plan.tables.length + 1;
    final t = SeatingTableSpec(
      id: id,
      shape: 'chair',
      xNorm: 0.38 + (idx % 4) * 0.04,
      yNorm: 0.38 + (idx % 3) * 0.04,
      wNorm: 0.05,
      hNorm: 0.05,
      rotationDeg: 0,
      label: 'Chair $idx',
      seatCount: 1,
    );
    var next = widget.plan.copyWith(tables: [...widget.plan.tables, t]);
    next = next.withRegeneratedSeatsForTable(id, t);
    setState(() {
      _selectedTableId = id;
      _selectedSeatId = null;
    });
    _emit(next);
  }

  void _addTable(String shape) {
    final id = 'tbl-${DateTime.now().millisecondsSinceEpoch}';
    final idx = widget.plan.tables.length + 1;
    final t = SeatingTableSpec(
      id: id,
      shape: shape,
      xNorm: 0.32 + (idx % 3) * 0.06,
      yNorm: 0.28 + (idx % 2) * 0.08,
      wNorm: shape == 'round' ? 0.14 : 0.16,
      hNorm: shape == 'round' ? 0.14 : 0.11,
      rotationDeg: 0,
      label: 'Table $idx',
      seatCount: shape == 'round' ? 8 : 8,
    );
    var next = widget.plan.copyWith(tables: [...widget.plan.tables, t]);
    next = next.withRegeneratedSeatsForTable(id, t);
    setState(() {
      _selectedTableId = id;
      _selectedSeatId = null;
    });
    _emit(next);
  }

  void _deleteSelected() {
    final id = _selectedTableId;
    if (id == null) return;
    _labelCtrls.remove(id)?.dispose();
    final tables = widget.plan.tables.where((t) => t.id != id).toList();
    final seats = widget.plan.seats.where((s) => s.tableId != id).toList();
    for (final s in widget.plan.seats.where((s) => s.tableId == id)) {
      _seatLabelCtrls.remove(s.id)?.dispose();
    }
    setState(() {
      _selectedTableId = null;
      _selectedSeatId = null;
    });
    _emit(widget.plan.copyWith(tables: tables, seats: seats));
  }

  void _duplicateSelectedTable() {
    final id = _selectedTableId;
    if (id == null) return;
    final src = widget.plan.tables.firstWhere((t) => t.id == id);
    final newId = 'tbl-${DateTime.now().millisecondsSinceEpoch}';
    final t = src.copyWith(
      id: newId,
      xNorm: (src.xNorm + 0.04).clamp(0.0, 1.0 - src.wNorm),
      yNorm: (src.yNorm + 0.04).clamp(0.0, 1.0 - src.hNorm),
      label: src.label.contains('copy') ? src.label : '${src.label} copy',
    );
    final copiedSeats = widget.plan.seats
        .where((s) => s.tableId == id)
        .map(
          (s) => SeatingSeatSpec(
            id: '$newId-s-${s.index}',
            tableId: newId,
            index: s.index,
            label: s.label,
            perimeterT: s.perimeterT,
          ),
        )
        .toList();
    var next = widget.plan.copyWith(tables: [...widget.plan.tables, t], seats: [...widget.plan.seats, ...copiedSeats]);
    setState(() {
      _selectedTableId = newId;
      _selectedSeatId = null;
    });
    _emit(next);
  }

  void _duplicateSelectedSeat() {
    final sid = _selectedSeatId;
    if (sid == null) return;
    final found = widget.plan.seats.where((e) => e.id == sid).toList();
    if (found.isEmpty) return;
    final s = found.first;
    final tid = s.tableId;
    final atTable = widget.plan.seats.where((e) => e.tableId == tid).toList()
      ..sort((a, b) => a.index.compareTo(b.index));
    final newId = 'seat-${DateTime.now().millisecondsSinceEpoch}';
    final newPerimeter = (s.perimeterT + 1 / (atTable.length + 2)) % 1.0;
    final newSeat = SeatingSeatSpec(
      id: newId,
      tableId: tid,
      index: atTable.length,
      label: s.label.trim().isEmpty ? 'Seat ${atTable.length + 1}' : '${s.label} copy',
      perimeterT: newPerimeter,
    );
    final reindexed = <SeatingSeatSpec>[...atTable, newSeat];
    for (var i = 0; i < reindexed.length; i++) {
      reindexed[i] = reindexed[i].copyWith(index: i);
    }
    final tables = widget.plan.tables
        .map((t) => t.id == tid ? t.copyWith(seatCount: reindexed.length) : t)
        .toList();
    final allSeats = <SeatingSeatSpec>[
      ...widget.plan.seats.where((e) => e.tableId != tid),
      ...reindexed,
    ];
    setState(() => _selectedSeatId = newId);
    _emit(widget.plan.copyWith(tables: tables, seats: allSeats));
  }

  void _moveTable(String tableId, double dxNorm, double dyNorm) {
    final tables = widget.plan.tables.map((t) {
      if (t.id != tableId) return t;
      return t.copyWith(
        xNorm: (t.xNorm + dxNorm).clamp(0.0, 1.0 - t.wNorm),
        yNorm: (t.yNorm + dyNorm).clamp(0.0, 1.0 - t.hNorm),
      );
    }).toList();
    _emit(widget.plan.copyWith(tables: tables));
  }

  void _onPanTable(String tableId, DragUpdateDetails d, double cw, double ch) {
    _moveTable(tableId, d.delta.dx / cw, d.delta.dy / ch);
  }

  void _onResizeTable(String tableId, _TableResizeCorner corner, DragUpdateDetails d, double cw, double ch) {
    final ax = d.delta.dx / cw;
    final ay = d.delta.dy / ch;
    final tables = widget.plan.tables.map((t) {
      if (t.id != tableId) return t;
      double x = t.xNorm;
      double y = t.yNorm;
      double w = t.wNorm;
      double h = t.hNorm;
      switch (corner) {
        case _TableResizeCorner.se:
          w += ax;
          h += ay;
          break;
        case _TableResizeCorner.sw:
          x += ax;
          w -= ax;
          h += ay;
          break;
        case _TableResizeCorner.ne:
          y += ay;
          w += ax;
          h -= ay;
          break;
        case _TableResizeCorner.nw:
          x += ax;
          y += ay;
          w -= ax;
          h -= ay;
          break;
      }
      w = w.clamp(0.06, 1.0);
      h = h.clamp(0.06, 1.0);
      x = x.clamp(0.0, 1.0 - w);
      y = y.clamp(0.0, 1.0 - h);
      w = w.clamp(0.06, 1.0 - x);
      h = h.clamp(0.06, 1.0 - y);
      if (t.shape == 'round') {
        final cx = x + w / 2;
        final cy = y + h / 2;
        var side = math.max(w, h);
        side = side.clamp(0.06, 1.0);
        x = (cx - side / 2).clamp(0.0, 1.0 - side);
        y = (cy - side / 2).clamp(0.0, 1.0 - side);
        w = side;
        h = side;
      }
      return t.copyWith(xNorm: x, yNorm: y, wNorm: w, hNorm: h);
    }).toList();
    _emit(widget.plan.copyWith(tables: tables));
  }

  void _onPanSeat(String seatId, DragUpdateDetails d, SeatingTableSpec table, double cw, double ch) {
    final found = widget.plan.seats.where((e) => e.id == seatId).toList();
    if (found.isEmpty) return;
    final s = found.first;
    final pos = seatNormOnEllipse(table, s);
    const dragScale = 0.65;
    final nx = (pos.dx * cw + d.delta.dx * dragScale) / cw;
    final ny = (pos.dy * ch + d.delta.dy * dragScale) / ch;
    final pt = perimeterTFromNormPoint(table, nx, ny);
    final seats = widget.plan.seats
        .map((e) => e.id == seatId ? e.copyWith(perimeterT: pt) : e)
        .toList();
    _emit(widget.plan.copyWith(seats: seats));
  }

  void _bumpSeatCount(int delta) {
    final id = _selectedTableId;
    if (id == null) return;
    final tables = widget.plan.tables.map((t) {
      if (t.id != id) return t;
      final n = math.max(0, math.min(100, t.seatCount + delta));
      return t.copyWith(seatCount: n);
    }).toList();
    final t = tables.firstWhere((e) => e.id == id);
    var next = widget.plan.copyWith(tables: tables);
    next = next.withRegeneratedSeatsForTable(id, t);
    setState(() {
      _selectedSeatId = null;
    });
    _emit(next);
  }

  List<Widget> _buildResizeHandles(SeatingPlanData p, double w, double h) {
    if (!widget.editable || _selectedTableId == null) return <Widget>[];
    final list = p.tables.where((e) => e.id == _selectedTableId).toList();
    if (list.isEmpty) return <Widget>[];
    final t = list.first;
    return [
      for (final c in _TableResizeCorner.values) _resizeHandle(t.id, c, t, w, h),
    ];
  }

  Widget _resizeHandle(String tableId, _TableResizeCorner corner, SeatingTableSpec t, double cw, double ch) {
    final left = t.xNorm * cw;
    final top = t.yNorm * ch;
    final tw = t.wNorm * cw;
    final th = t.hNorm * ch;
    double dl = 0;
    double dt = 0;
    switch (corner) {
      case _TableResizeCorner.nw:
        dl = -7;
        dt = -7;
        break;
      case _TableResizeCorner.ne:
        dl = tw - 7;
        dt = -7;
        break;
      case _TableResizeCorner.sw:
        dl = -7;
        dt = th - 7;
        break;
      case _TableResizeCorner.se:
        dl = tw - 7;
        dt = th - 7;
        break;
    }
    return Positioned(
      left: left + dl,
      top: top + dt,
      width: 14,
      height: 14,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onPanUpdate: (d) => _onResizeTable(tableId, corner, d, cw, ch),
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: Colors.white,
            shape: BoxShape.circle,
            border: Border.all(color: const Color(0xFFF4511E), width: 2),
          ),
        ),
      ),
    );
  }

  Widget _stepHeader(String title, {String subtitle = ''}) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8, top: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 14)),
          if (subtitle.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(subtitle, style: TextStyle(fontSize: 12, height: 1.3, color: Colors.grey.shade700)),
            ),
        ],
      ),
    );
  }

  Widget _buildSelectionPanelBelowCanvas() {
    if (!widget.editable || (_selectedTableId == null && _selectedSeatId == null)) {
      return const SizedBox.shrink();
    }
    final tid = _selectedTableId;
    SeatingTableSpec? selTable;
    if (tid != null) {
      for (final t in widget.plan.tables) {
        if (t.id == tid) {
          selTable = t;
          break;
        }
      }
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (tid != null && selTable != null) ...[
          Card(
            margin: EdgeInsets.zero,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              child: Wrap(
                spacing: 4,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  const Text('Nudge', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 13)),
                  IconButton(
                    tooltip: 'Nudge left',
                    onPressed: () => _moveTable(tid, -0.012, 0),
                    icon: const Icon(Icons.arrow_back),
                  ),
                  IconButton(
                    tooltip: 'Nudge right',
                    onPressed: () => _moveTable(tid, 0.012, 0),
                    icon: const Icon(Icons.arrow_forward),
                  ),
                  IconButton(
                    tooltip: 'Nudge up',
                    onPressed: () => _moveTable(tid, 0, -0.012),
                    icon: const Icon(Icons.arrow_upward),
                  ),
                  IconButton(
                    tooltip: 'Nudge down',
                    onPressed: () => _moveTable(tid, 0, 0.012),
                    icon: const Icon(Icons.arrow_downward),
                  ),
                  if (selTable.shape != 'chair') ...[
                    IconButton(
                      tooltip: 'Fewer chairs',
                      onPressed: selTable.seatCount <= 0 ? null : () => _bumpSeatCount(-1),
                      icon: const Icon(Icons.remove_circle_outline),
                    ),
                    Text('${selTable.seatCount}', style: const TextStyle(fontWeight: FontWeight.w800)),
                    IconButton(
                      tooltip: 'More chairs',
                      onPressed: selTable.seatCount >= 100 ? null : () => _bumpSeatCount(1),
                      icon: const Icon(Icons.add_circle_outline),
                    ),
                  ],
                  IconButton(tooltip: 'Duplicate', onPressed: _duplicateSelectedTable, icon: const Icon(Icons.copy_outlined)),
                  IconButton(
                    tooltip: 'Delete',
                    onPressed: _deleteSelected,
                    icon: const Icon(Icons.delete_outline, color: Colors.red),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 8),
          TextField(
            decoration: InputDecoration(
              labelText: selTable.shape == 'chair' ? 'Chair label' : 'Table label',
              border: const OutlineInputBorder(),
              isDense: true,
            ),
            controller: _labelCtrl(tid, selTable.label),
            onChanged: (v) {
              final tables = widget.plan.tables.map((tb) {
                if (tb.id != tid) return tb;
                return tb.copyWith(label: v);
              }).toList();
              _emit(widget.plan.copyWith(tables: tables));
            },
          ),
          const SizedBox(height: 8),
        ],
        if (_selectedSeatId != null) ...[
          Builder(
            builder: (context) {
              final sid = _selectedSeatId!;
              final s = widget.plan.seats.firstWhere((e) => e.id == sid);
              return TextField(
                decoration: const InputDecoration(
                  labelText: 'Seat label',
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
                controller: _seatLabelCtrl(sid, s.label),
                onChanged: (v) {
                  final seats = widget.plan.seats.map((e) {
                    if (e.id != sid) return e;
                    return e.copyWith(label: v);
                  }).toList();
                  _emit(widget.plan.copyWith(seats: seats));
                },
              );
            },
          ),
          if (_selectedSeatId != null && tid != null)
            Align(
              alignment: Alignment.centerLeft,
              child: IconButton(
                tooltip: 'Duplicate seat',
                onPressed: _duplicateSelectedSeat,
                icon: const Icon(Icons.event_seat_outlined),
              ),
            ),
        ],
        const SizedBox(height: 8),
      ],
    );
  }

  Widget _stepTile({
    required String title,
    String subtitle = '',
    required List<Widget> children,
  }) {
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.grey.shade300),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _stepHeader(title, subtitle: subtitle),
          ...children,
        ],
      ),
    );
  }

  Widget _buildCanvas() {
    final p = widget.plan;
    return AspectRatio(
          aspectRatio: 16 / 10,
          child: LayoutBuilder(
            builder: (context, c) {
              final w = c.maxWidth;
              final h = c.maxHeight;
              return GestureDetector(
                onTap: widget.editable
                    ? () => setState(() {
                          _selectedTableId = null;
                          _selectedSeatId = null;
                        })
                    : null,
                child: Container(
                  decoration: BoxDecoration(
                    color: Colors.grey.shade100,
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: Colors.grey.shade400),
                  ),
                  clipBehavior: Clip.antiAlias,
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      RepaintBoundary(child: _FloorBackground(plan: p)),
                      ...p.tables.map((t) {
                        final sel = t.id == _selectedTableId;
                        return Positioned(
                          left: t.xNorm * w,
                          top: t.yNorm * h,
                          width: t.wNorm * w,
                          height: t.hNorm * h,
                          child: GestureDetector(
                            behavior: HitTestBehavior.opaque,
                            onTap: () {
                              if (!widget.editable) return;
                              setState(() {
                                _selectedTableId = t.id;
                                _selectedSeatId = null;
                              });
                            },
                            onPanStart: widget.editable
                                ? (_) {
                                    setState(() {
                                      _selectedTableId = t.id;
                                      _selectedSeatId = null;
                                    });
                                  }
                                : null,
                            onPanUpdate: widget.editable
                                ? (d) => _onPanTable(t.id, d, w, h)
                                : null,
                            child: Container(
                              alignment: Alignment.center,
                              decoration: BoxDecoration(
                                color:
                                    sel
                                        ? const Color(0xFFFFF3D0)
                                        : Colors.white,
                                borderRadius: BorderRadius.circular(
                                  t.shape == 'round' ? 999 : 8,
                                ),
                                border: Border.all(
                                  color:
                                      sel
                                          ? const Color(0xFFF4511E)
                                          : Colors.black45,
                                  width: sel ? 2 : 1,
                                ),
                              ),
                              child: Padding(
                                padding: const EdgeInsets.all(2),
                                child: FittedBox(
                                  fit: BoxFit.scaleDown,
                                  child: Text(
                                    t.shape == 'chair'
                                        ? t.label
                                        : '${t.label}\n(${t.seatCount} chairs)',
                                    textAlign: TextAlign.center,
                                    maxLines: 3,
                                    style: const TextStyle(
                                      fontSize: 11,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ),
                        );
                      }),
                      ...p.seats.map((s) {
                        SeatingTableSpec? table;
                        for (final t in p.tables) {
                          if (t.id == s.tableId) {
                            table = t;
                            break;
                          }
                        }
                        final tbl = table;
                        if (tbl == null) return const SizedBox.shrink();
                        final pos = seatNormOnEllipse(tbl, s);
                        final selSeat = s.id == _selectedSeatId;
                        var chip = s.label.trim();
                        if (chip.isEmpty) chip = '${s.index + 1}';
                        final tableCenterY = tbl.yNorm + tbl.hNorm / 2;
                        final labelBelow = pos.dy >= tableCenterY;
                        final seatDot = GestureDetector(
                          behavior: HitTestBehavior.opaque,
                          onTap: () {
                            if (!widget.editable) return;
                            setState(() {
                              _selectedSeatId = s.id;
                              _selectedTableId = s.tableId;
                            });
                          },
                          onPanUpdate: widget.editable ? (d) => _onPanSeat(s.id, d, tbl, w, h) : null,
                          child: DecoratedBox(
                            decoration: BoxDecoration(
                              color: selSeat ? const Color(0xFF0D7A3A) : const Color(0xFF1DB954),
                              shape: BoxShape.circle,
                              border: Border.all(
                                color: selSeat ? const Color(0xFFFFF3D0) : Colors.white,
                                width: selSeat ? 2 : 1,
                              ),
                            ),
                            child: const SizedBox(width: 22, height: 22),
                          ),
                        );
                        final labelChip = chip.isEmpty
                            ? const SizedBox.shrink()
                            : ConstrainedBox(
                                constraints: const BoxConstraints(maxWidth: 72),
                                child: Container(
                                  padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                                  decoration: BoxDecoration(
                                    color: Colors.white.withValues(alpha: 0.92),
                                    borderRadius: BorderRadius.circular(4),
                                    border: Border.all(color: Colors.black26),
                                  ),
                                  child: Text(
                                    chip,
                                    textAlign: TextAlign.center,
                                    maxLines: 2,
                                    style: TextStyle(
                                      fontSize: 9,
                                      fontWeight: FontWeight.w700,
                                      color: selSeat ? const Color(0xFF0D7A3A) : Colors.black87,
                                    ),
                                  ),
                                ),
                              );
                        return Positioned(
                          left: pos.dx * w - 36,
                          top: pos.dy * h - (labelBelow ? 8 : 40),
                          child: SizedBox(
                            width: 72,
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: labelBelow
                                  ? [seatDot, const SizedBox(height: 2), labelChip]
                                  : [labelChip, const SizedBox(height: 2), seatDot],
                            ),
                          ),
                        );
                      }),
                      ..._buildResizeHandles(p, w, h),
                    ],
                  ),
                ),
              );
            },
          ),
        );
  }

  @override
  Widget build(BuildContext context) {
    final p = widget.plan;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (widget.editable) ...[
          _stepTile(
            title: 'Step 1: Add floor background',
            subtitle: 'Use a venue reference photo, upload a floor image, or pick a venue shape.',
            children: [
              if (widget.venueReferencePhotosBase64.isNotEmpty) ...[
                Text(
                  'Venue reference photos',
                  style: TextStyle(fontWeight: FontWeight.w700, fontSize: 13, color: Colors.grey.shade800),
                ),
                const SizedBox(height: 4),
                Text(
                  'Tap a photo to use it as the seating floor background.',
                  style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
                ),
                const SizedBox(height: 8),
                _VenueReferencePhotoStrip(
                  photos: widget.venueReferencePhotosBase64,
                  selectedB64: p.floorImageBase64,
                  onSelect: _useVenueReferenceAsFloor,
                ),
                const SizedBox(height: 12),
              ],
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  OutlinedButton.icon(
                    onPressed: _pickVenueFloorShape,
                    icon: const Icon(Icons.category_outlined, size: 18),
                    label: const Text('Venue shape'),
                  ),
                  OutlinedButton.icon(
                    onPressed: _pickFloorImage,
                    icon: const Icon(Icons.image, size: 18),
                    label: const Text('Floor image'),
                  ),
                  TextButton.icon(
                    onPressed: p.floorImageBase64 == null &&
                            p.floorImageUrl == null &&
                            (p.venueFloorShape == null || p.venueFloorShape!.isEmpty)
                        ? null
                        : _clearFloor,
                    icon: const Icon(Icons.hide_image_outlined, size: 18),
                    label: const Text('Clear floor'),
                  ),
                ],
              ),
            ],
          ),
          _stepTile(
            title: 'Step 2: Add tables and chairs',
            children: [
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  FilledButton.tonalIcon(
                    onPressed: () => _addTable('rect'),
                    icon: const Icon(Icons.table_restaurant, size: 18),
                    label: const Text('Add rectangle table'),
                  ),
                  FilledButton.tonalIcon(
                    onPressed: () => _addTable('round'),
                    icon: const Icon(Icons.circle_outlined, size: 18),
                    label: const Text('Add round table'),
                  ),
                  FilledButton.tonalIcon(
                    onPressed: _addChair,
                    icon: const Icon(Icons.event_seat, size: 18),
                    label: const Text('Add chair'),
                  ),
                ],
              ),
            ],
          ),
          _stepTile(
            title: 'Step 3: Arrange to your desire!',
            subtitle: 'Drag tables and chairs, then nudge and label your selection.',
            children: [
              _buildCanvas(),
              const SizedBox(height: 8),
              _buildSelectionPanelBelowCanvas(),
            ],
          ),
        ] else
          _buildCanvas(),
      ],
    );
  }
}

/// Cached venue reference thumbnails — avoids re-decode flicker when the plan changes.
class _VenueReferencePhotoStrip extends StatefulWidget {
  const _VenueReferencePhotoStrip({
    required this.photos,
    required this.selectedB64,
    required this.onSelect,
  });

  final List<String> photos;
  final String? selectedB64;
  final ValueChanged<String> onSelect;

  @override
  State<_VenueReferencePhotoStrip> createState() => _VenueReferencePhotoStripState();
}

class _VenueReferencePhotoStripState extends State<_VenueReferencePhotoStrip> {
  final Map<String, Uint8List> _cache = {};

  Uint8List? _bytesFor(String b64) {
    return _cache.putIfAbsent(b64, () {
      try {
        return Uint8List.fromList(base64Decode(b64));
      } catch (_) {
        return Uint8List(0);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 88,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        itemCount: widget.photos.length,
        separatorBuilder: (_, __) => const SizedBox(width: 8),
        itemBuilder: (context, i) {
          final b64 = widget.photos[i];
          final bytes = _bytesFor(b64);
          if (bytes == null || bytes.isEmpty) return const SizedBox.shrink();
          final selected = widget.selectedB64 == b64;
          return GestureDetector(
            onTap: () => widget.onSelect(b64),
            child: Stack(
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: Image.memory(
                    bytes,
                    width: 88,
                    height: 88,
                    fit: BoxFit.cover,
                    gaplessPlayback: true,
                    filterQuality: FilterQuality.medium,
                  ),
                ),
                if (selected)
                  Positioned.fill(
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(color: Theme.of(context).colorScheme.primary, width: 3),
                      ),
                    ),
                  ),
              ],
            ),
          );
        },
      ),
    );
  }
}

/// Cached floor background so dragging tables does not re-decode the floor image.
class _FloorBackground extends StatefulWidget {
  const _FloorBackground({required this.plan});

  final SeatingPlanData plan;

  @override
  State<_FloorBackground> createState() => _FloorBackgroundState();
}

class _FloorBackgroundState extends State<_FloorBackground> {
  String? _cacheKey;
  Uint8List? _cachedBytes;

  String _floorKey(SeatingPlanData p) {
    final b64 = p.floorImageBase64 ?? '';
    final url = p.floorImageUrl ?? '';
    final shape = p.venueFloorShape ?? '';
    return '$url|$b64|$shape';
  }

  @override
  void didUpdateWidget(covariant _FloorBackground oldWidget) {
    super.didUpdateWidget(oldWidget);
    final key = _floorKey(widget.plan);
    if (key != _cacheKey) {
      _cacheKey = key;
      _cachedBytes = null;
      final b64 = widget.plan.floorImageBase64;
      if (b64 != null && b64.isNotEmpty) {
        try {
          _cachedBytes = Uint8List.fromList(base64Decode(b64));
        } catch (_) {
          _cachedBytes = null;
        }
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final plan = widget.plan;
    final u = plan.floorImageUrl;
    if (u != null && u.isNotEmpty && (u.startsWith('http://') || u.startsWith('https://'))) {
      return Image.network(
        u,
        fit: BoxFit.contain,
        width: double.infinity,
        height: double.infinity,
        gaplessPlayback: true,
        errorBuilder: (_, __, ___) => const Center(child: Icon(Icons.broken_image, size: 48, color: Colors.grey)),
      );
    }
    final bytes = _cachedBytes;
    if (bytes != null && bytes.isNotEmpty) {
      return Image.memory(
        bytes,
        fit: BoxFit.contain,
        width: double.infinity,
        height: double.infinity,
        gaplessPlayback: true,
        errorBuilder: (_, __, ___) => const Center(child: Icon(Icons.broken_image, size: 48, color: Colors.grey)),
      );
    }
    final shape = plan.venueFloorShape;
    if (shape != null && shape.isNotEmpty && isKnownVenueFloorShape(shape)) {
      return CustomPaint(painter: VenueFloorShapePainter(shape));
    }
    return Center(
      child: Text(
        'No floor — use Venue shape or Floor image',
        textAlign: TextAlign.center,
        style: TextStyle(color: Colors.grey.shade600, fontSize: 13),
      ),
    );
  }
}
