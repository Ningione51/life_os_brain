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
  final TransformationController _transformController = TransformationController();
  final List<_GraphNode> _nodes = [];
  final List<_GraphEdge> _edges = [];
  _GraphNode? _selectedNode;

  static const double _canvasSize = 1600.0;
  static const Offset _canvasCenter = Offset(_canvasSize / 2, _canvasSize / 2);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _centerView(animate: false));
    _buildGraph();
  }

  @override
  void dispose() {
    _transformController.dispose();
    super.dispose();
  }

  void _centerView({bool animate = true}) {
    if (!mounted) return;
    if (animate) HapticFeedback.lightImpact();
    final screenSize = MediaQuery.of(context).size;
    final dx = (screenSize.width / 2) - _canvasCenter.dx;
    final dy = (screenSize.height / 2.5) - _canvasCenter.dy;

    _transformController.value = Matrix4.identity()..translate(dx, dy);
  }

  void _zoomBy(double factor) {
    HapticFeedback.selectionClick();
    final matrix = _transformController.value.clone();
    matrix.scale(factor);
    setState(() {
      _transformController.value = matrix;
    });
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
      final radius = entityEntries.length == 1 ? 0.0 : 130.0;
      final pos = _canvasCenter + Offset(radius * cos(angle), radius * sin(angle));

      nodes.add(_GraphNode(
        id: entId,
        label: '#$entName',
        fullText: 'Soggetto presente in ${linkedIds.length} memorie.',
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
      final content = n['content'] as String;
      final noteEntities = SimilarityEngine.extractEntities(content);

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
            position: _canvasCenter,
          ),
        );
        final angle = (2 * pi * i) / max(1, totalNotes) + (i * 0.7);
        startPos = hubNode.position + Offset(150 * cos(angle), 150 * sin(angle));
      } else {
        final angle = (2 * pi * i) / max(1, totalNotes);
        startPos = _canvasCenter + Offset(260 * cos(angle), 260 * sin(angle));
      }

      final cleanLine = content.split('\n').first.trim();
      final shortLabel = cleanLine.length > 20 ? '${cleanLine.substring(0, 20)}…' : cleanLine;

      final linkCount = connections.where((c) => c['source_id'] == id || c['target_id'] == id).length;

      nodes.add(_GraphNode(
        id: id,
        label: shortLabel,
        fullText: content,
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
        // InteractiveViewer completo per Pinch-to-Zoom e Pan con le dita (stile mappa)
        InteractiveViewer(
          transformationController: _transformController,
          boundaryMargin: const EdgeInsets.all(800),
          minScale: 0.15,
          maxScale: 4.0,
          constrained: false,
          child: GestureDetector(
            onTapUp: (details) {
              _GraphNode? tapped;
              for (final node in _nodes) {
                final hitRadius = node.isEntity ? 38.0 : 32.0;
                if ((node.position - details.localPosition).distance <= hitRadius) {
                  tapped = node;
                  break;
                }
              }
              if (tapped != null) {
                HapticFeedback.mediumImpact();
              } else {
                HapticFeedback.selectionClick();
              }
              setState(() => _selectedNode = tapped);
            },
            child: SizedBox(
              width: _canvasSize,
              height: _canvasSize,
              child: CustomPaint(
                painter: _ObsidianGraphPainter(
                  nodes: _nodes,
                  edges: _edges,
                  selectedNode: _selectedNode,
                ),
              ),
            ),
          ),
        ),

        // Pulsanti di controllo zoom e centratura in alto
        Positioned(
          top: 8,
          right: 16,
          child: Container(
            decoration: BoxDecoration(
              color: AppColors.cardSurface.withOpacity(0.92),
              borderRadius: BorderRadius.circular(22),
              border: Border.all(color: AppColors.cardSurfaceLight),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                IconButton(
                  icon: const Icon(Icons.remove_rounded, color: AppColors.textPrimary, size: 18),
                  onPressed: () => _zoomBy(0.75),
                ),
                IconButton(
                  icon: const Icon(Icons.center_focus_strong_outlined, color: AppColors.accentCoral, size: 18),
                  onPressed: () => _centerView(animate: true),
                ),
                IconButton(
                  icon: const Icon(Icons.add_rounded, color: AppColors.textPrimary, size: 18),
                  onPressed: () => _zoomBy(1.35),
                ),
              ],
            ),
          ),
        ),

        // Scheda ispettore in basso quando tocchi un nodo
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
                      'COLLEGATO A:',
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

class _ObsidianGraphPainter extends CustomPainter {
  final List<_GraphNode> nodes;
  final List<_GraphEdge> edges;
  final _GraphNode? selectedNode;

  _ObsidianGraphPainter({
    required this.nodes,
    required this.edges,
    required this.selectedNode,
  });

  @override
  void paint(Canvas canvas, Size size) {
    // Sfondo a griglia puntinata stile Obsidian / Notion
    final dotPaint = Paint()..color = const Color(0xFF242020);
    const double step = 50.0;
    for (double x = 0; x < size.width; x += step) {
      for (double y = 0; y < size.height; y += step) {
        canvas.drawCircle(Offset(x, y), 1.3, dotPaint);
      }
    }

    final nodeMap = {for (var n in nodes) n.id: n};

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
                ? AppColors.accentCoral.withOpacity(isDimmed ? 0.08 : 0.4)
                : AppColors.statusGreen.withOpacity(isDimmed ? 0.08 : 0.35))
        ..strokeWidth = isHighlighted ? 2.8 : 1.4
        ..style = PaintingStyle.stroke;

      canvas.drawLine(source.position, target.position, paint);
    }

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
          Paint()..color = mainColor.withOpacity(isSelected ? 0.35 : 0.12),
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

      final pillRect = RRect.fromRectAndRadius(
        Rect.fromCenter(
          center: node.position + Offset(0, baseRadius + 14),
          width: tp.width + 14,
          height: tp.height + 6,
        ),
        const Radius.circular(10),
      );

      canvas.drawRRect(
        pillRect,
        Paint()..color = AppColors.cardSurface.withOpacity(isDimmed ? 0.3 : 0.9),
      );
      tp.paint(canvas, node.position + Offset(-tp.width / 2, baseRadius + 14 - tp.height / 2));
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => true;
}