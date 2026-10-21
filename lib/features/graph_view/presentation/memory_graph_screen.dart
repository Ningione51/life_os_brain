import 'dart:math';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../../core/theme/app_colors.dart';
import '../../../data/database/note_dao.dart';
import '../../../data/embedding/similarity_engine.dart';

class _GraphNode {
  final String id;
  final String label;
  final String fullText;
  final bool isEntity;
  final int connectionCount;
  Offset position;

  _GraphNode({
    required this.id,
    required this.label,
    required this.fullText,
    required this.isEntity,
    required this.connectionCount,
    required this.position,
  });
}

class _GraphEdge {
  final String sourceId;
  final String targetId;
  final double weight;
  final bool isEntityLink;

  _GraphEdge(this.sourceId, this.targetId, this.weight, {this.isEntityLink = false});
}

class MemoryGraphScreen extends StatefulWidget {
  const MemoryGraphScreen({super.key});

  @override
  State<MemoryGraphScreen> createState() => _MemoryGraphScreenState();
}

class _MemoryGraphScreenState extends State<MemoryGraphScreen> {
  final NoteDao _noteDao = NoteDao();
  final List<_GraphNode> _nodes = [];
  final List<_GraphEdge> _edges = [];

  _GraphNode? _selectedNode;
  _GraphNode? _draggedNode;

  // Stato Telecamera Stile Google Maps
  Offset _cameraOffset = Offset.zero;
  double _scale = 1.0;
  double _rotation = 0.0;

  double _baseScale = 1.0;
  double _baseRotation = 0.0;
  Offset _lastFocalPoint = Offset.zero;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _resetCamera(animate: false));
    _buildGraph();
  }

  void _resetCamera({bool animate = true}) {
    if (!mounted) return;
    if (animate) HapticFeedback.lightImpact();
    final size = MediaQuery.of(context).size;
    setState(() {
      _cameraOffset = Offset(size.width / 2, size.height / 2.6);
      _scale = 1.0;
      _rotation = 0.0;
    });
  }

  Offset _screenToWorld(Offset screenPoint) {
    final translated = (screenPoint - _cameraOffset) / _scale;
    final cosR = cos(-_rotation);
    final sinR = sin(-_rotation);
    return Offset(
      translated.dx * cosR - translated.dy * sinR,
      translated.dx * sinR + translated.dy * cosR,
    );
  }

  Offset _screenDeltaToWorld(Offset screenDelta) {
    final scaled = screenDelta / _scale;
    final cosR = cos(-_rotation);
    final sinR = sin(-_rotation);
    return Offset(
      scaled.dx * cosR - scaled.dy * sinR,
      scaled.dx * sinR + scaled.dy * cosR,
    );
  }

  _GraphNode? _hitTestNode(Offset screenPos) {
    final worldPoint = _screenToWorld(screenPos);
    final adaptiveRadius = 32.0 / _scale.clamp(0.4, 2.0);
    for (final node in _nodes.reversed) {
      final hitRadius = node.isEntity ? adaptiveRadius * 1.25 : adaptiveRadius;
      if ((node.position - worldPoint).distance <= hitRadius) {
        return node;
      }
    }
    return null;
  }

  Future<void> _buildGraph() async {
    final notes = await _noteDao.getAllNotes();
    final connections = await _noteDao.getAllConnections();

    final nodes = <_GraphNode>[];
    final edges = <_GraphEdge>[];
    final entityMap = <String, List<String>>{};

    for (final n in notes) {
      final id = n['id'] as String;
      final content = n['content'] as String;
      for (final ent in SimilarityEngine.extractEntities(content)) {
        entityMap.putIfAbsent(ent, () => []).add(id);
      }
    }

    final entityEntries = entityMap.entries.toList();
    for (int i = 0; i < entityEntries.length; i++) {
      final entName = entityEntries[i].key;
      final linkedIds = entityEntries[i].value;
      final entId = 'entity_$entName';
      final angle = (2 * pi * i) / max(1, entityEntries.length);
      final radius = entityEntries.length == 1 ? 0.0 : 140.0;
      final pos = Offset(radius * cos(angle), radius * sin(angle));

      nodes.add(_GraphNode(
        id: entId,
        label: '#$entName',
        fullText: 'Soggetto collegato a ${linkedIds.length} memorie.',
        isEntity: true,
        connectionCount: linkedIds.length,
        position: pos,
      ));

      for (final nId in linkedIds) {
        edges.add(_GraphEdge(entId, nId, 0.95, isEntityLink: true));
      }
    }

    final int totalNotes = notes.length;
    for (int i = 0; i < totalNotes; i++) {
      final n = notes[i];
      final id = n['id'] as String;
      final rawContent = n['content'] as String;
      final cleanContent = SimilarityEngine.stripMediaMarkers(rawContent);
      final noteEntities = SimilarityEngine.extractEntities(rawContent);

      Offset startPos;
      if (noteEntities.isNotEmpty) {
        final hubNode = nodes.firstWhere(
          (node) => node.id == 'entity_${noteEntities.first}',
          orElse: () => _GraphNode(
            id: '',
            label: '',
            fullText: '',
            isEntity: false,
            connectionCount: 0,
            position: Offset.zero,
          ),
        );
        final angle = (2 * pi * i) / max(1, totalNotes) + (i * 0.7);
        startPos = hubNode.position + Offset(155 * cos(angle), 155 * sin(angle));
      } else {
        final angle = (2 * pi * i) / max(1, totalNotes);
        startPos = Offset(240 * cos(angle), 240 * sin(angle));
      }

      final cleanLine = cleanContent.split('\n').first.trim();
      final shortLabel = cleanLine.length > 20 ? '${cleanLine.substring(0, 20)}…' : cleanLine;
      final linkCount = connections.where((c) => c['source_id'] == id || c['target_id'] == id).length;

      nodes.add(_GraphNode(
        id: id,
        label: shortLabel.isEmpty ? 'Nota Multimediale' : shortLabel,
        fullText: cleanContent.isEmpty ? 'Nota Multimediale' : cleanContent,
        isEntity: false,
        connectionCount: linkCount,
        position: startPos,
      ));
    }

    for (final c in connections) {
      edges.add(_GraphEdge(
        c['source_id'] as String,
        c['target_id'] as String,
        (c['similarity_score'] as num).toDouble(),
      ));
    }

    if (mounted) {
      setState(() {
        _nodes
          ..clear()
          ..addAll(nodes);
        _edges
          ..clear()
          ..addAll(edges);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_nodes.isEmpty) {
      return const Center(
        child: Text(
          'Il grafo è vuoto.\nAggiungi qualche nota per esplorare le connessioni!',
          textAlign: TextAlign.center,
          style: TextStyle(color: AppColors.textSecondary),
        ),
      );
    }

    final relatedNodes = <_GraphNode>[];
    if (_selectedNode != null) {
      for (final edge in _edges) {
        String? otherId;
        if (edge.sourceId == _selectedNode!.id) otherId = edge.targetId;
        if (edge.targetId == _selectedNode!.id) otherId = edge.sourceId;
        if (otherId != null) {
          final found = _nodes.where((n) => n.id == otherId);
          if (found.isNotEmpty && !relatedNodes.any((r) => r.id == otherId)) {
            relatedNodes.add(found.first);
          }
        }
      }
    }

    return Stack(
      children: [
        GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapUp: (details) {
            final tapped = _hitTestNode(details.localPosition);
            if (tapped != null) {
              HapticFeedback.mediumImpact();
            } else if (_selectedNode != null) {
              HapticFeedback.selectionClick();
            }
            setState(() => _selectedNode = tapped);
          },
          onDoubleTapDown: (details) {
            HapticFeedback.lightImpact();
            final focal = details.localPosition;
            final newScale = (_scale * 1.45).clamp(0.2, 4.0);
            final scaleFactor = newScale / _scale;
            setState(() {
              _cameraOffset = focal + (_cameraOffset - focal) * scaleFactor;
              _scale = newScale;
            });
          },
          onScaleStart: (details) {
            _baseScale = _scale;
            _baseRotation = _rotation;
            _lastFocalPoint = details.localFocalPoint;

            if (details.pointerCount == 1) {
              final hit = _hitTestNode(details.localFocalPoint);
              if (hit != null) {
                HapticFeedback.selectionClick();
                setState(() {
                  _draggedNode = hit;
                  _selectedNode = hit;
                });
              } else {
                _draggedNode = null;
              }
            } else {
              _draggedNode = null;
            }
          },
          onScaleUpdate: (details) {
            final currentFocal = details.localFocalPoint;
            final focalDelta = currentFocal - _lastFocalPoint;
            _lastFocalPoint = currentFocal;

            setState(() {
              if (details.pointerCount == 1 && _draggedNode != null) {
                // 1 dito su un nodo -> sposta solo il nodo
                _draggedNode!.position += _screenDeltaToWorld(focalDelta);
              } else if (details.pointerCount == 1) {
                // 1 dito sullo sfondo -> muove tutta la mappa
                _cameraOffset += focalDelta;
              } else if (details.pointerCount >= 2) {
                // 2 dita -> Zoom + Rotazione a 2 dita + Pan simultaneo
                _draggedNode = null;
                final newScale = (_baseScale * details.scale).clamp(0.18, 4.5);
                final newRotation = _baseRotation + details.rotation;

                final scaleRatio = newScale / _scale;
                final rotDelta = newRotation - _rotation;

                _cameraOffset += focalDelta;

                final rel = _cameraOffset - currentFocal;
                final cosD = cos(rotDelta);
                final sinD = sin(rotDelta);
                final rotatedRel = Offset(
                  rel.dx * cosD - rel.dy * sinD,
                  rel.dx * sinD + rel.dy * cosD,
                );

                _cameraOffset = currentFocal + rotatedRel * scaleRatio;
                _scale = newScale;
                _rotation = newRotation;
              }
            });
          },
          onScaleEnd: (_) {
            _draggedNode = null;
          },
          child: SizedBox.expand(
            child: CustomPaint(
              painter: _MapGraphPainter(
                nodes: _nodes,
                edges: _edges,
                selectedNode: _selectedNode,
                cameraOffset: _cameraOffset,
                scale: _scale,
                rotation: _rotation,
              ),
            ),
          ),
        ),

        // Pulsanti Bussola / Ricentra / Aggiorna in alto a destra
        Positioned(
          top: 10,
          right: 16,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
            decoration: BoxDecoration(
              color: AppColors.cardSurface.withOpacity(0.92),
              borderRadius: BorderRadius.circular(24),
              border: Border.all(color: AppColors.cardSurfaceLight),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (_rotation.abs() > 0.03)
                  IconButton(
                    tooltip: 'Raddrizza Nord',
                    visualDensity: VisualDensity.compact,
                    icon: Transform.rotate(
                      angle: _rotation,
                      child: const Icon(Icons.explore_outlined, color: AppColors.accentCoral, size: 20),
                    ),
                    onPressed: () {
                      HapticFeedback.lightImpact();
                      setState(() => _rotation = 0.0);
                    },
                  ),
                IconButton(
                  tooltip: 'Centra Mappa',
                  visualDensity: VisualDensity.compact,
                  icon: const Icon(Icons.my_location_rounded, color: AppColors.statusGreen, size: 20),
                  onPressed: () => _resetCamera(animate: true),
                ),
                IconButton(
                  tooltip: 'Aggiorna Grafo',
                  visualDensity: VisualDensity.compact,
                  icon: const Icon(Icons.refresh_rounded, color: AppColors.textSecondary, size: 20),
                  onPressed: () {
                    HapticFeedback.selectionClick();
                    _buildGraph();
                  },
                ),
              ],
            ),
          ),
        ),

        // Scheda Ispettore in basso quando tocchi un Nodo
        if (_selectedNode != null)
          Positioned(
            bottom: 12,
            left: 16,
            right: 16,
            child: Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: AppColors.cardSurface.withOpacity(0.96),
                borderRadius: BorderRadius.circular(24),
                border: Border.all(
                  color: _selectedNode!.isEntity ? AppColors.accentCoral : AppColors.statusGreen,
                  width: 1.5,
                ),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Row(
                        children: [
                          Icon(
                            _selectedNode!.isEntity ? Icons.hub_rounded : Icons.article_outlined,
                            color: _selectedNode!.isEntity ? AppColors.accentCoral : AppColors.statusGreen,
                            size: 18,
                          ),
                          const SizedBox(width: 8),
                          Text(
                            _selectedNode!.isEntity ? 'Soggetto: ${_selectedNode!.label}' : 'Memoria',
                            style: const TextStyle(
                              color: AppColors.textPrimary,
                              fontWeight: FontWeight.bold,
                              fontSize: 14,
                            ),
                          ),
                        ],
                      ),
                      GestureDetector(
                        onTap: () {
                          HapticFeedback.selectionClick();
                          setState(() => _selectedNode = null);
                        },
                        child: const Icon(Icons.close_rounded, color: AppColors.textSecondary, size: 18),
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  Text(
                    _selectedNode!.fullText,
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: AppColors.textPrimary, fontSize: 13),
                  ),
                  if (relatedNodes.isNotEmpty) ...[
                    const SizedBox(height: 10),
                    const Text(
                      'COLLEGATO CON:',
                      style: TextStyle(
                        color: AppColors.textSecondary,
                        fontSize: 10,
                        fontWeight: FontWeight.bold,
                        letterSpacing: 0.8,
                      ),
                    ),
                    const SizedBox(height: 6),
                    SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      child: Row(
                        children: relatedNodes.map((rNode) {
                          return GestureDetector(
                            onTap: () {
                              HapticFeedback.selectionClick();
                              setState(() => _selectedNode = rNode);
                            },
                            child: Container(
                              margin: const EdgeInsets.only(right: 8),
                              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                              decoration: BoxDecoration(
                                color: AppColors.background,
                                borderRadius: BorderRadius.circular(12),
                                border: Border.all(
                                  color: rNode.isEntity
                                      ? AppColors.accentCoral.withOpacity(0.5)
                                      : AppColors.statusGreen.withOpacity(0.5),
                                ),
                              ),
                              child: Text(
                                rNode.fullText.length > 30
                                    ? '${rNode.fullText.substring(0, 30)}…'
                                    : rNode.fullText,
                                style: const TextStyle(color: AppColors.textPrimary, fontSize: 12),
                              ),
                            ),
                          );
                        }).toList(),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
      ],
    );
  }
}

class _MapGraphPainter extends CustomPainter {
  final List<_GraphNode> nodes;
  final List<_GraphEdge> edges;
  final _GraphNode? selectedNode;
  final Offset cameraOffset;
  final double scale;
  final double rotation;

  _MapGraphPainter({
    required this.nodes,
    required this.edges,
    required this.selectedNode,
    required this.cameraOffset,
    required this.scale,
    required this.rotation,
  });

  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();

    canvas.translate(cameraOffset.dx, cameraOffset.dy);
    canvas.scale(scale);
    canvas.rotate(rotation);

    // 1. Griglia puntinata del piano
    final dotPaint = Paint()..color = const Color(0xFF252121);
    const double step = 55.0;
    const double gridExtent = 1200.0;
    for (double x = -gridExtent; x <= gridExtent; x += step) {
      for (double y = -gridExtent; y <= gridExtent; y += step) {
        canvas.drawCircle(Offset(x, y), 1.4, dotPaint);
      }
    }

    final nodeMap = {for (var n in nodes) n.id: n};

    // 2. Archi
    for (final edge in edges) {
      final source = nodeMap[edge.sourceId];
      final target = nodeMap[edge.targetId];
      if (source == null || target == null) continue;

      final bool isHighlighted = selectedNode != null &&
          (selectedNode!.id == source.id || selectedNode!.id == target.id);
      final bool isDimmed = selectedNode != null && !isHighlighted;

      final paint = Paint()
        ..color = isHighlighted
            ? AppColors.accentCoral
            : (edge.isEntityLink
                ? AppColors.accentCoral.withOpacity(isDimmed ? 0.08 : 0.42)
                : AppColors.statusGreen.withOpacity(isDimmed ? 0.08 : 0.36))
        ..strokeWidth = isHighlighted ? 2.8 : 1.5
        ..style = PaintingStyle.stroke;

      canvas.drawLine(source.position, target.position, paint);
    }

    // 3. Nodi + Etichette sempre dritte anche quando ruoti con 2 dita
    for (final node in nodes) {
      final bool isSelected = selectedNode?.id == node.id;
      final bool isConnectedToSelected = selectedNode != null &&
          edges.any((e) =>
              (e.sourceId == selectedNode!.id && e.targetId == node.id) ||
              (e.targetId == selectedNode!.id && e.sourceId == node.id));
      final bool isDimmed = selectedNode != null && !isSelected && !isConnectedToSelected;

      final double baseRadius = node.isEntity ? 18.0 : 12.0;
      final Color mainColor = node.isEntity ? AppColors.accentCoral : AppColors.statusGreen;

      if (isSelected || node.isEntity) {
        canvas.drawCircle(
          node.position,
          baseRadius + 8,
          Paint()..color = mainColor.withOpacity(isSelected ? 0.35 : 0.14),
        );
      }

      canvas.drawCircle(
        node.position,
        baseRadius,
        Paint()..color = isDimmed ? mainColor.withOpacity(0.2) : mainColor,
      );

      canvas.drawCircle(
        node.position,
        baseRadius * 0.5,
        Paint()..color = AppColors.background,
      );

      canvas.save();
      canvas.translate(node.position.dx, node.position.dy);
      canvas.rotate(-rotation);

      final textSpan = TextSpan(
        text: node.label,
        style: TextStyle(
          color: isDimmed
              ? AppColors.textSecondary.withOpacity(0.3)
              : (isSelected ? AppColors.accentCoral : AppColors.textPrimary),
          fontSize: node.isEntity ? 12.5 : 11.0,
          fontWeight: node.isEntity || isSelected ? FontWeight.bold : FontWeight.w500,
        ),
      );
      final tp = TextPainter(text: textSpan, textDirection: TextDirection.ltr)..layout();

      final labelOffset = Offset(0, baseRadius + 14);
      final pillRect = RRect.fromRectAndRadius(
        Rect.fromCenter(
          center: labelOffset,
          width: tp.width + 14,
          height: tp.height + 6,
        ),
        const Radius.circular(10),
      );

      canvas.drawRRect(
        pillRect,
        Paint()..color = AppColors.cardSurface.withOpacity(isDimmed ? 0.3 : 0.9),
      );
      tp.paint(canvas, labelOffset - Offset(tp.width / 2, tp.height / 2));
      canvas.restore();
    }

    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _MapGraphPainter oldDelegate) => true;
}