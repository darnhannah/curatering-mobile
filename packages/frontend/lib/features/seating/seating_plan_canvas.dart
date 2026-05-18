import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

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

  const SeatingPlanInteractive({
    super.key,
    required this.plan,
    this.editable = false,
    this.onChanged,
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
    final x = await ImagePicker().pickImage(source: ImageSource.gallery, imageQuality: 85);
    if (!mounted) return;
    if (x == null) return;
    final bytes = await x.readAsBytes();
    if (bytes.isEmpty) return;
    final b64 = base64Encode(bytes);
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

  @override
  Widget build(BuildContext context) {
    final p = widget.plan;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (widget.editable) ...[
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
                onPressed:
                    p.floorImageBase64 == null &&
                            p.floorImageUrl == null &&
                            (p.venueFloorShape == null || p.venueFloorShape!.isEmpty)
                        ? null
                        : _clearFloor,
                icon: const Icon(Icons.hide_image_outlined, size: 18),
                label: const Text('Clear floor'),
              ),
              if (_selectedTableId != null) ...[
                Builder(
                  builder: (context) {
                    final tid = _selectedTableId!;
                    final t = widget.plan.tables.firstWhere((e) => e.id == tid);
                    final isChair = t.shape == 'chair';
                    return Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (!isChair) ...[
                          IconButton(
                            tooltip: 'Fewer chairs',
                            onPressed: t.seatCount <= 0 ? null : () => _bumpSeatCount(-1),
                            icon: const Icon(Icons.remove_circle_outline),
                          ),
                          Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 4),
                            child: Text(
                              '${t.seatCount}',
                              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w800),
                            ),
                          ),
                          IconButton(
                            tooltip: 'More chairs',
                            onPressed: t.seatCount >= 100 ? null : () => _bumpSeatCount(1),
                            icon: const Icon(Icons.add_circle_outline),
                          ),
                        ],
                        IconButton(
                          tooltip: 'Duplicate',
                          onPressed: _duplicateSelectedTable,
                          icon: const Icon(Icons.copy_outlined),
                        ),
                        IconButton(
                          tooltip: 'Delete',
                          onPressed: _deleteSelected,
                          icon: const Icon(Icons.delete_outline, color: Colors.red),
                        ),
                      ],
                    );
                  },
                ),
              ],
              if (_selectedSeatId != null) ...[
                IconButton(
                  tooltip: 'Duplicate seat',
                  onPressed: _duplicateSelectedSeat,
                  icon: const Icon(Icons.event_seat_outlined),
                ),
              ],
            ],
          ),
          if (_selectedTableId != null)
            Padding(
              padding: const EdgeInsets.only(top: 6, bottom: 4),
              child: Card(
                margin: EdgeInsets.zero,
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  child: Row(
                    children: [
                      const Text('Nudge', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 13)),
                      const SizedBox(width: 4),
                      IconButton(
                        tooltip: 'Nudge left',
                        onPressed: () => _moveTable(_selectedTableId!, -0.012, 0),
                        icon: const Icon(Icons.arrow_back),
                      ),
                      IconButton(
                        tooltip: 'Nudge right',
                        onPressed: () => _moveTable(_selectedTableId!, 0.012, 0),
                        icon: const Icon(Icons.arrow_forward),
                      ),
                      IconButton(
                        tooltip: 'Nudge up',
                        onPressed: () => _moveTable(_selectedTableId!, 0, -0.012),
                        icon: const Icon(Icons.arrow_upward),
                      ),
                      IconButton(
                        tooltip: 'Nudge down',
                        onPressed: () => _moveTable(_selectedTableId!, 0, 0.012),
                        icon: const Icon(Icons.arrow_downward),
                      ),
                      const Spacer(),
                      const Text(
                        'Drag on canvas or use arrows',
                        style: TextStyle(fontSize: 11, color: Colors.black54),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          if (_selectedTableId != null || _selectedSeatId != null)
            Padding(
              padding: const EdgeInsets.only(top: 4, bottom: 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (_selectedTableId != null)
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(
                          child: Builder(
                            builder: (context) {
                              final tid = _selectedTableId!;
                              final t = widget.plan.tables.firstWhere((e) => e.id == tid);
                              final ctrl = _labelCtrl(tid, t.label);
                              return TextField(
                                decoration: InputDecoration(
                                  labelText: t.shape == 'chair' ? 'Chair label' : 'Table label',
                                  hintText: t.shape == 'chair'
                                      ? 'e.g. Bride, Guest 12'
                                      : 'e.g. Head table, VIP 1',
                                  border: const OutlineInputBorder(),
                                  isDense: true,
                                  counterText: '',
                                ),
                                controller: ctrl,
                                textCapitalization: TextCapitalization.sentences,
                                keyboardType: TextInputType.text,
                                onChanged: (v) {
                                  final tables = widget.plan.tables.map((tb) {
                                    if (tb.id != tid) return tb;
                                    return tb.copyWith(label: v);
                                  }).toList();
                                  _emit(widget.plan.copyWith(tables: tables));
                                },
                                onEditingComplete: () {
                                  final trimmed = ctrl.text.trim();
                                  if (trimmed.isEmpty) {
                                    final fallback = t.shape == 'chair' ? 'Chair' : 'Table';
                                    ctrl.text = fallback;
                                    final tables = widget.plan.tables.map((tb) {
                                      if (tb.id != tid) return tb;
                                      return tb.copyWith(label: fallback);
                                    }).toList();
                                    _emit(widget.plan.copyWith(tables: tables));
                                  } else if (trimmed != ctrl.text) {
                                    ctrl.text = trimmed;
                                    final tables = widget.plan.tables.map((tb) {
                                      if (tb.id != tid) return tb;
                                      return tb.copyWith(label: trimmed);
                                    }).toList();
                                    _emit(widget.plan.copyWith(tables: tables));
                                  }
                                },
                              );
                            },
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Text(
                            'Drag tables and chairs on the floor plan. '
                            'Drag green seat markers around a table. Resize with corner handles.',
                            style: TextStyle(fontSize: 12, color: Colors.grey.shade700),
                          ),
                        ),
                      ],
                    ),
                  if (_selectedSeatId != null) ...[
                    if (_selectedTableId != null) const SizedBox(height: 10),
                    Builder(
                      builder: (context) {
                        final sid = _selectedSeatId!;
                        final s = widget.plan.seats.firstWhere((e) => e.id == sid);
                        final ctrl = _seatLabelCtrl(sid, s.label);
                        return TextField(
                          decoration: const InputDecoration(
                            labelText: 'Seat label',
                            hintText: 'e.g. A1, Guest of honor',
                            border: OutlineInputBorder(),
                            isDense: true,
                          ),
                          controller: ctrl,
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
                  ],
                ],
              ),
            ),
          const SizedBox(height: 8),
        ],
        AspectRatio(
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
                      _FloorLayer(plan: p),
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
                              child: Text(
                                t.shape == 'chair'
                                    ? t.label
                                    : '${t.label}\n(${t.seatCount} chairs)',
                                textAlign: TextAlign.center,
                                style: const TextStyle(
                                  fontSize: 11,
                                  fontWeight: FontWeight.w600,
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
                        if (chip.length > 5) chip = '${chip.substring(0, 4)}…';
                        return Positioned(
                          left: pos.dx * w - 22,
                          top: pos.dy * h - 34,
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              if (chip.isNotEmpty)
                                Container(
                                  padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                                  decoration: BoxDecoration(
                                    color: Colors.white.withValues(alpha: 0.92),
                                    borderRadius: BorderRadius.circular(4),
                                    border: Border.all(color: Colors.black26),
                                  ),
                                  child: Text(
                                    chip,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                      fontSize: 9,
                                      fontWeight: FontWeight.w700,
                                      color: selSeat ? const Color(0xFF0D7A3A) : Colors.black87,
                                    ),
                                  ),
                                ),
                              const SizedBox(height: 2),
                              GestureDetector(
                                behavior: HitTestBehavior.opaque,
                                onTap: () {
                                  if (!widget.editable) return;
                                  setState(() {
                                    _selectedSeatId = s.id;
                                    _selectedTableId = s.tableId;
                                  });
                                },
                                onPanUpdate: widget.editable
                                    ? (d) => _onPanSeat(s.id, d, tbl, w, h)
                                    : null,
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
                              ),
                            ],
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
        ),
      ],
    );
  }
}

class _FloorLayer extends StatelessWidget {
  final SeatingPlanData plan;

  const _FloorLayer({required this.plan});

  @override
  Widget build(BuildContext context) {
    final u = plan.floorImageUrl;
    if (u != null && u.isNotEmpty) {
      if (u.startsWith('http://') || u.startsWith('https://')) {
        return Image.network(
          u,
          fit: BoxFit.contain,
          width: double.infinity,
          height: double.infinity,
          errorBuilder:
              (_, __, ___) => const Center(
                child: Icon(Icons.broken_image, size: 48, color: Colors.grey),
              ),
        );
      }
    }
    final b64 = plan.floorImageBase64;
    if (b64 != null && b64.isNotEmpty) {
      try {
        return Image.memory(
          base64Decode(b64),
          fit: BoxFit.contain,
          width: double.infinity,
          height: double.infinity,
          errorBuilder:
              (_, __, ___) => const Center(
                child: Icon(Icons.broken_image, size: 48, color: Colors.grey),
              ),
        );
      } catch (_) {
        return const Center(child: Icon(Icons.broken_image));
      }
    }
    final shape = plan.venueFloorShape;
    if (shape != null && shape.isNotEmpty) {
      if (isKnownVenueFloorShape(shape)) {
        return CustomPaint(painter: VenueFloorShapePainter(shape));
      }
      return Center(
        child: Text(
          'Saved floor shape is not recognized',
          textAlign: TextAlign.center,
          style: TextStyle(color: Colors.grey.shade600, fontSize: 13),
        ),
      );
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
