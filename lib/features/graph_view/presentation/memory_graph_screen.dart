import 'dart:collection';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../../core/background/background_worker.dart';
import '../../../core/theme/app_colors.dart';
import '../../../data/database/note_dao.dart';
import '../../../data/embedding/similarity_engine.dart';

class _GraphNode {
  final String id;
  final String label;
  final String fullText;
  final String nodeType;
  final int
      depth; // Profondità dinamica (0 = Soggetto Radice, 1..N = salti logici)
  final int connectionCount;
  Offset position;

  _GraphNode({
    required this.id,
    required this.label,
    required this.fullText,
    required this.nodeType,
    required this.depth,
    required this.connectionCount,
    required this.position,
  });

  bool get isPrimaryHub =>
      depth == 0 || nodeType.contains('person') || nodeType.contains('soggett');
  bool get isBranchHub => depth > 0 && connectionCount >= 2;
}

class _GraphEdge {
  final String sourceId;
  final String targetId;
  final String predicate;
  final double weight;

  _GraphEdge(
    this.sourceId,
    this.targetId, {
    this.predicate = '',
    this.weight = 1.0,
  });
}

class MemoryGraphScreen extends StatefulWidget {
  const MemoryGraphScreen({super.key});

  @override
  State<MemoryGraphScreen> createState() => _MemoryGraphScreenState();
}

class _MemoryGraphScreenState extends State<MemoryGraphScreen> {
  final NoteDao _noteDao = NoteDao.instance;
  final List<_GraphNode> _nodes = [];
  final List<_GraphEdge> _edges = [];
  _GraphNode? _selectedNode;
  _GraphNode? _draggedNode;

  double _nodeRepulsion = 260000.0;
  double _edgeRepulsion = 180000.0;
  double _minNodeDistance = 160.0;
  double _minEdgeDistance = 110.0;

  Offset _cameraOffset = Offset.zero;
  double _cameraScale = 1.0;
  double _cameraRotation = 0.0;

  double _baseScale = 1.0;
  double _baseRotation = 0.0;
  Offset _lastFocalPoint = Offset.zero;
  bool _rotationUnlocked = false;
  bool _isHorizonSnapped = true;

  static const double _rotationUnlockThresholdRad = 14.0 * pi / 180.0;
  static const double _horizonSnapRad = 7.0 * pi / 180.0;

  @override
  void initState() {
    super.initState();
    BackgroundWorker.syncCompletedNotifier.addListener(_buildGraph);
    _buildGraph();
  }

  @override
  void dispose() {
    BackgroundWorker.syncCompletedNotifier.removeListener(_buildGraph);
    super.dispose();
  }

  Offset _screenToWorld(Offset screenPoint, Size viewportSize) {
    final screenCenter =
        Offset(viewportSize.width / 2, viewportSize.height / 2);
    final centered = screenPoint - screenCenter - _cameraOffset;
    final unscaled = centered / _cameraScale;
    final cosA = cos(-_cameraRotation);
    final sinA = sin(-_cameraRotation);
    return Offset(
      unscaled.dx * cosA - unscaled.dy * sinA,
      unscaled.dx * sinA + unscaled.dy * cosA,
    );
  }

  void _resetCamera() {
    HapticFeedback.lightImpact();
    setState(() {
      _cameraOffset = Offset.zero;
      _cameraScale = 1.0;
      _cameraRotation = 0.0;
      _isHorizonSnapped = true;
    });
  }

  Future<void> _buildGraph() async {
    final notes = await _noteDao.getAllNotes();
    final kgNodes = await _noteDao.getAllKgNodes();
    final kgRelations = await _noteDao.getAllKgRelations();

    final nodes = <_GraphNode>[];
    final edges = <_GraphEdge>[];

    if (kgNodes.isNotEmpty && kgRelations.isNotEmpty) {
      final outChildren = <String, List<String>>{};
      final inParents = <String, List<String>>{};
      final totalDegree = <String, int>{};

      for (final rel in kgRelations) {
        final s = rel['source_node'] as String;
        final t = rel['target_node'] as String;
        outChildren.putIfAbsent(s, () => []).add(t);
        inParents.putIfAbsent(t, () => []).add(s);
        totalDegree[s] = (totalDegree[s] ?? 0) + 1;
        totalDegree[t] = (totalDegree[t] ?? 0) + 1;
      }

      final nodeById = <String, Map<String, dynamic>>{
        for (final n in kgNodes) (n['id'] as String): n
      };

      // 1. Individua le radici logiche (Persone o nodi da cui partono le catene senza genitori)
      final roots = <String>[];
      if (nodeById.containsKey('io') && (totalDegree['io'] ?? 0) > 0) {
        roots.add('io');
      }
      for (final n in kgNodes) {
        final id = n['id'] as String;
        if (id == 'io' || (totalDegree[id] ?? 0) == 0) continue;
        final type = (n['type'] as String).toLowerCase();
        final hasNoParents = (inParents[id]?.isEmpty ?? true);
        if (type.contains('person') ||
            type.contains('soggett') ||
            hasNoParents) {
          roots.add(id);
        }
      }

      if (roots.isEmpty && nodeById.isNotEmpty) {
        roots.add(nodeById.keys.first);
      }

      // 2. Calcola la profondità (depth 0, 1, 2, ... N) e il genitore principale tramite BFS
      final depthMap = <String, int>{};
      final primaryParent = <String, String>{};
      final queue = Queue<String>();

      for (final r in roots) {
        depthMap[r] = 0;
        queue.add(r);
      }

      while (queue.isNotEmpty) {
        final current = queue.removeFirst();
        final currentDepth = depthMap[current] ?? 0;
        for (final child in (outChildren[current] ?? const <String>[])) {
          if (!depthMap.containsKey(child)) {
            depthMap[child] = currentDepth + 1;
            primaryParent[child] = current;
            queue.add(child);
          }
        }
      }

      // Eventuali nodi rimasti in componenti sconnesse
      for (final id in nodeById.keys) {
        if ((totalDegree[id] ?? 0) > 0 && !depthMap.containsKey(id)) {
          depthMap[id] = 1;
        }
      }

      // Raggruppa i nodi per livello di profondità (0..MaxDepth)
      final maxDepth = depthMap.values.fold<int>(0, max);
      final posMap = <String, Offset>{};

      for (int d = 0; d <= maxDepth; d++) {
        final idsAtDepth = depthMap.entries
            .where((e) => e.value == d)
            .map((e) => e.key)
            .toList();

        if (d == 0) {
          for (int i = 0; i < idsAtDepth.length; i++) {
            final id = idsAtDepth[i];
            final angle = (2 * pi * i) / max(1, idsAtDepth.length);
            final radius = idsAtDepth.length == 1 ? 0.0 : 180.0;
            posMap[id] = Offset(radius * cos(angle), radius * sin(angle));
          }
        } else {
          // Raggruppa i fratelli che condividono lo stesso nodo genitore
          final byParent = <String, List<String>>{};
          for (final id in idsAtDepth) {
            final p = primaryParent[id] ?? '';
            byParent.putIfAbsent(p, () => []).add(id);
          }

          byParent.forEach((pId, siblings) {
            final parentPos = posMap[pId] ?? Offset.zero;
            final grandParentId = primaryParent[pId];
            final grandParentPos =
                grandParentId != null ? posMap[grandParentId] : null;

            double baseAngle;
            if (grandParentPos != null) {
              // Prosegue nella direzione esterna del ramo
              baseAngle = atan2(parentPos.dy - grandParentPos.dy,
                  parentPos.dx - grandParentPos.dx);
            } else if (parentPos != Offset.zero) {
              baseAngle = atan2(parentPos.dy, parentPos.dx);
            } else {
              baseAngle = 0.0;
            }

            final stepDist = d == 1 ? 165.0 : 145.0;
            for (int i = 0; i < siblings.length; i++) {
              final childId = siblings[i];
              double angle;
              if (parentPos == Offset.zero && grandParentPos == null) {
                angle = (2 * pi * i) / max(1, siblings.length);
              } else {
                final spread = (i - (siblings.length - 1) / 2.0) * 0.62;
                angle = baseAngle + spread;
              }
              posMap[childId] = parentPos +
                  Offset(stepDist * cos(angle), stepDist * sin(angle));
            }
          });
        }
      }

      // Costruisce gli oggetti _GraphNode
      for (final entry in depthMap.entries) {
        final id = entry.key;
        final d = entry.value;
        final n = nodeById[id];
        if (n == null) continue;

        final cleanLabel =
            (n['label'] as String).replaceAll(RegExp(r'^#+'), '');
        final type = (n['type'] as String).toLowerCase();

        final summaryLines = kgRelations
            .where((r) => r['source_node'] == id || r['target_node'] == id)
            .map((r) =>
                '${r['source_node']} ➔ ${r['predicate']} ➔ ${r['target_node']}')
            .toSet()
            .join('\n');

        final isPerson =
            d == 0 || type.contains('person') || type.contains('soggett');

        nodes.add(_GraphNode(
          id: 'kg_$id',
          label: isPerson ? '#$cleanLabel' : cleanLabel,
          fullText: summaryLines,
          nodeType: type,
          depth: d,
          connectionCount: totalDegree[id] ?? 1,
          position: posMap[id] ?? Offset.zero,
        ));
      }

      // Costruisce gli archi orientati senza duplicati
      final seenEdges = <String>{};
      for (final rel in kgRelations) {
        final src = 'kg_${rel['source_node']}';
        final dst = 'kg_${rel['target_node']}';
        final pred = rel['predicate'] as String;
        if (seenEdges.add('$src|$pred|$dst')) {
          edges.add(_GraphEdge(src, dst, predicate: pred, weight: 0.95));
        }
      }
    } else {
      // Fallback locale se il PC non ha ancora sincronizzato
      final entityMap = <String, List<String>>{};
      for (final n in notes) {
        final id = n['id'] as String;
        final content = n['content'] as String;
        for (final ent in SimilarityEngine.extractEntities(content)) {
          final cleanEnt = ent.replaceAll(RegExp(r'^#+'), '').trim();
          if (cleanEnt.isNotEmpty) {
            entityMap.putIfAbsent(cleanEnt, () => []).add(id);
          }
        }
      }

      final entries = entityMap.entries.toList();
      for (int i = 0; i < entries.length; i++) {
        final ent = entries[i].key;
        final linked = entries[i].value;
        final angle = (2 * pi * i) / max(1, entries.length);
        nodes.add(_GraphNode(
          id: 'ent_${ent.toLowerCase()}',
          label: '#$ent',
          fullText: 'Presente in ${linked.length} memorie',
          nodeType: 'persona',
          depth: 0,
          connectionCount: linked.length,
          position: Offset(120 * cos(angle), 120 * sin(angle)),
        ));
      }
    }

    _applyForceRelaxation(nodes, edges);

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

  void _applyForceRelaxation(List<_GraphNode> nodes, List<_GraphEdge> edges) {
    const int iterations = 60;
    // Rimuovi le vecchie costanti "const double nodeRepulsion = ..."

    final nodeMap = {for (var n in nodes) n.id: n};

    for (int step = 0; step < iterations; step++) {
      // 1. Repulsione NODO contro NODO
      for (int i = 0; i < nodes.length; i++) {
        for (int j = i + 1; j < nodes.length; j++) {
          final delta = nodes[i].position - nodes[j].position;
          final dist = max(14.0, delta.distance);
          if (dist < _minNodeDistance * 1.5) {
            // Usa _minNodeDistance
            final force = (_nodeRepulsion / (dist * dist))
                .clamp(0.5, 25.0); // Usa _nodeRepulsion
            final dir = delta / dist;
            if (!nodes[i].isPrimaryHub) nodes[i].position += dir * force;
            if (!nodes[j].isPrimaryHub) nodes[j].position -= dir * force;
          }
        }
      }

      // 2. Repulsione NODO contro ARCO
      for (final node in nodes) {
        if (node.isPrimaryHub) continue;

        for (final edge in edges) {
          if (edge.sourceId == node.id || edge.targetId == node.id) continue;

          final source = nodeMap[edge.sourceId];
          final target = nodeMap[edge.targetId];
          if (source == null || target == null) continue;

          final v = target.position - source.position;
          final w = node.position - source.position;

          final c1 = w.dx * v.dx + w.dy * v.dy;
          if (c1 <= 0) continue;

          final c2 = v.dx * v.dx + v.dy * v.dy;
          if (c2 <= c1) continue;

          final b = c1 / c2;
          final proj = source.position + Offset(v.dx * b, v.dy * b);

          final deltaP = node.position - proj;
          final d = deltaP.distance;

          if (d > 0 && d < _minEdgeDistance) {
            // Usa _minEdgeDistance
            final force = (_edgeRepulsion / (d * d))
                .clamp(0.5, 22.0); // Usa _edgeRepulsion
            node.position += (deltaP / d) * force;
          }
        }
      }
    }
  }

  void _showGraphSettings() {
    showModalBottomSheet(
      context: context,
      backgroundColor: AppColors.cardSurface, // Usa i colori della tua app
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setModalState) {
            return Padding(
              padding: const EdgeInsets.all(24.0),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('Fisica del Grafo',
                      style: TextStyle(
                          fontSize: 20,
                          fontWeight: FontWeight.bold,
                          color: Colors.white)),
                  const SizedBox(height: 20),

                  // Slider Repulsione Nodi
                  Text('Repulsione Nodi: ${_nodeRepulsion.toInt()}',
                      style: const TextStyle(color: Colors.white70)),
                  Slider(
                    value: _nodeRepulsion,
                    min: 50000,
                    max: 600000,
                    divisions: 55,
                    activeColor: AppColors.accentCoral,
                    onChanged: (val) =>
                        setModalState(() => _nodeRepulsion = val),
                    onChangeEnd: (_) => _buildGraph(),
                  ),

                  // Slider Repulsione Archi
                  Text('Repulsione Archi: ${_edgeRepulsion.toInt()}',
                      style: const TextStyle(color: Colors.white70)),
                  Slider(
                    value: _edgeRepulsion,
                    min: 10000,
                    max: 400000,
                    divisions: 39,
                    activeColor: AppColors.accentCoral,
                    onChanged: (val) =>
                        setModalState(() => _edgeRepulsion = val),
                    onChangeEnd: (_) => _buildGraph(),
                  ),

                  // Slider Distanza Minima Nodi
                  Text('Distanza Minima Nodi: ${_minNodeDistance.toInt()}',
                      style: const TextStyle(color: Colors.white70)),
                  Slider(
                    value: _minNodeDistance,
                    min: 50,
                    max: 400,
                    divisions: 35,
                    activeColor: AppColors.statusGreen,
                    onChanged: (val) =>
                        setModalState(() => _minNodeDistance = val),
                    onChangeEnd: (_) => _buildGraph(),
                  ),

                  // Slider Distanza Minima Archi
                  Text('Distanza Minima Archi: ${_minEdgeDistance.toInt()}',
                      style: const TextStyle(color: Colors.white70)),
                  Slider(
                    value: _minEdgeDistance,
                    min: 50,
                    max: 300,
                    divisions: 25,
                    activeColor: AppColors.statusGreen,
                    onChanged: (val) =>
                        setModalState(() => _minEdgeDistance = val),
                    onChangeEnd: (_) => _buildGraph(),
                  ),
                ],
              ),
            );
          },
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_nodes.isEmpty) {
      return const Center(
        child: Text(
          'Il grafo è vuoto.\nScrivi una nota per generare i collegamenti!',
          textAlign: TextAlign.center,
          style: TextStyle(color: AppColors.textSecondary),
        ),
      );
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        final viewportSize = Size(constraints.maxWidth, constraints.maxHeight);

        final relatedNodes = <_GraphNode>[];
        if (_selectedNode != null) {
          for (final edge in _edges) {
            String? otherId;
            if (edge.sourceId == _selectedNode!.id) otherId = edge.targetId;
            if (edge.targetId == _selectedNode!.id) otherId = edge.sourceId;
            if (otherId != null) {
              final found = _nodes.where((n) => n.id == otherId);
              if (found.isNotEmpty &&
                  !relatedNodes.any((r) => r.id == otherId)) {
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
                final worldPos =
                    _screenToWorld(details.localPosition, viewportSize);
                _GraphNode? tapped;
                for (final node in _nodes) {
                  final hitRadius = (node.isPrimaryHub ? 38.0 : 30.0) /
                      _cameraScale.clamp(0.5, 2.0);
                  if ((node.position - worldPos).distance <= hitRadius) {
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
              onScaleStart: (details) {
                _baseScale = _cameraScale;
                _baseRotation = _cameraRotation;
                _lastFocalPoint = details.localFocalPoint;
                _rotationUnlocked = false;
                _draggedNode = null;

                if (details.pointerCount == 1) {
                  final worldPos =
                      _screenToWorld(details.localFocalPoint, viewportSize);
                  for (final node in _nodes) {
                    if ((node.position - worldPos).distance <=
                        36.0 / _cameraScale.clamp(0.5, 2.0)) {
                      _draggedNode = node;
                      _selectedNode = node;
                      HapticFeedback.selectionClick();
                      break;
                    }
                  }
                }
              },
              onScaleUpdate: (details) {
                setState(() {
                  if (details.pointerCount == 1 && _draggedNode != null) {
                    final deltaScreen =
                        details.localFocalPoint - _lastFocalPoint;
                    _lastFocalPoint = details.localFocalPoint;
                    final unscaled = deltaScreen / _cameraScale;
                    final cosA = cos(-_cameraRotation);
                    final sinA = sin(-_cameraRotation);
                    final worldDelta = Offset(
                      unscaled.dx * cosA - unscaled.dy * sinA,
                      unscaled.dx * sinA + unscaled.dy * cosA,
                    );
                    _draggedNode!.position += worldDelta;
                    return;
                  }

                  final focalDelta = details.localFocalPoint - _lastFocalPoint;
                  _lastFocalPoint = details.localFocalPoint;
                  _cameraOffset += focalDelta;

                  if (details.pointerCount >= 2) {
                    _cameraScale =
                        (_baseScale * details.scale).clamp(0.25, 3.8);

                    if (!_rotationUnlocked) {
                      if (details.rotation.abs() >
                          _rotationUnlockThresholdRad) {
                        _rotationUnlocked = true;
                        HapticFeedback.selectionClick();
                      }
                    }

                    if (_rotationUnlocked) {
                      final rawDiff = details.rotation -
                          (details.rotation.sign * _rotationUnlockThresholdRad);
                      double candidateRot =
                          (_baseRotation + rawDiff) % (2 * pi);
                      if (candidateRot > pi) candidateRot -= 2 * pi;
                      if (candidateRot < -pi) candidateRot += 2 * pi;

                      if (candidateRot.abs() < _horizonSnapRad) {
                        if (!_isHorizonSnapped) {
                          HapticFeedback.lightImpact();
                          _isHorizonSnapped = true;
                        }
                        _cameraRotation = 0.0;
                      } else {
                        _isHorizonSnapped = false;
                        _cameraRotation = candidateRot;
                      }
                    }
                  }
                });
              },
              onScaleEnd: (_) {
                _draggedNode = null;
                _rotationUnlocked = false;
              },
              child: SizedBox(
                width: viewportSize.width,
                height: viewportSize.height,
                child: CustomPaint(
                  painter: _ObsidianGraphPainter(
                    nodes: _nodes,
                    edges: _edges,
                    selectedNode: _selectedNode,
                    cameraOffset: _cameraOffset,
                    cameraScale: _cameraScale,
                    cameraRotation: _cameraRotation,
                  ),
                ),
              ),
            ),
            Positioned(
              top: 60,
              right: 20, // O dove preferisci nella tua UI
              child: FloatingActionButton(
                heroTag: 'graph_settings',
                mini: true,
                backgroundColor: AppColors.cardSurface,
                onPressed: _showGraphSettings,
                child: const Icon(Icons.tune, color: AppColors.accentCoral),
              ),
            ),
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
                    if (_cameraRotation.abs() > 0.01)
                      IconButton(
                        tooltip: 'Raddrizza Orizzonte',
                        icon: Transform.rotate(
                          angle: _cameraRotation,
                          child: const Icon(Icons.explore_outlined,
                              color: AppColors.accentCoral, size: 19),
                        ),
                        onPressed: () {
                          HapticFeedback.mediumImpact();
                          setState(() {
                            _cameraRotation = 0.0;
                            _isHorizonSnapped = true;
                          });
                        },
                      ),
                    IconButton(
                      tooltip: 'Centra Mappa',
                      icon: const Icon(Icons.center_focus_strong_outlined,
                          color: AppColors.statusGreen, size: 18),
                      onPressed: _resetCamera,
                    ),
                    IconButton(
                      tooltip: 'Ricalcola Grafo col PC',
                      icon: const Icon(Icons.auto_fix_high_rounded,
                          color: AppColors.accentCoral, size: 18),
                      onPressed: () async {
                        HapticFeedback.heavyImpact();
                        await _noteDao.resetAllAiSyncForRebuild();
                        await BackgroundWorker.processPendingNotes();
                        await _buildGraph();
                      },
                    ),
                  ],
                ),
              ),
            ),
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
                      color: _selectedNode!.isPrimaryHub
                          ? AppColors.accentCoral
                          : AppColors.statusGreen,
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
                                _selectedNode!.isPrimaryHub
                                    ? Icons.person_pin_circle_rounded
                                    : (_selectedNode!.isBranchHub
                                        ? Icons.account_tree_outlined
                                        : Icons.label_outline),
                                color: _selectedNode!.isPrimaryHub
                                    ? AppColors.accentCoral
                                    : AppColors.statusGreen,
                                size: 18,
                              ),
                              const SizedBox(width: 8),
                              Text(
                                _selectedNode!.label,
                                style: const TextStyle(
                                  color: AppColors.textPrimary,
                                  fontWeight: FontWeight.bold,
                                  fontSize: 15,
                                ),
                              ),
                            ],
                          ),
                          GestureDetector(
                            onTap: () => setState(() => _selectedNode = null),
                            child: const Icon(Icons.close_rounded,
                                color: AppColors.textSecondary, size: 18),
                          ),
                        ],
                      ),
                      const SizedBox(height: 6),
                      Text(
                        _selectedNode!.fullText,
                        maxLines: 4,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                            color: AppColors.textPrimary,
                            fontSize: 12.5,
                            height: 1.4),
                      ),
                      if (relatedNodes.isNotEmpty) ...[
                        const SizedBox(height: 10),
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
                                  padding: const EdgeInsets.symmetric(
                                      horizontal: 10, vertical: 6),
                                  decoration: BoxDecoration(
                                    color: AppColors.background,
                                    borderRadius: BorderRadius.circular(12),
                                    border: Border.all(
                                        color: AppColors.accentCoral
                                            .withOpacity(0.5)),
                                  ),
                                  child: Text(
                                    rNode.label,
                                    style: const TextStyle(
                                        color: AppColors.textPrimary,
                                        fontSize: 12),
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
      },
    );
  }
}

class _ObsidianGraphPainter extends CustomPainter {
  final List<_GraphNode> nodes;
  final List<_GraphEdge> edges;
  final _GraphNode? selectedNode;
  final Offset cameraOffset;
  final double cameraScale;
  final double cameraRotation;

  _ObsidianGraphPainter({
    required this.nodes,
    required this.edges,
    required this.selectedNode,
    required this.cameraOffset,
    required this.cameraScale,
    required this.cameraRotation,
  });

  Offset _worldToScreen(Offset worldPos, Offset screenCenter) {
    final cosA = cos(cameraRotation);
    final sinA = sin(cameraRotation);
    final rotated = Offset(
      worldPos.dx * cosA - worldPos.dy * sinA,
      worldPos.dx * sinA + worldPos.dy * cosA,
    );
    return screenCenter + cameraOffset + (rotated * cameraScale);
  }

  @override
  void paint(Canvas canvas, Size size) {
    final screenCenter = Offset(size.width / 2, size.height / 2);

    // Sfondo a puntini
    final dotPaint = Paint()..color = const Color(0xFF242020);
    const double step = 55.0;
    for (double x = -700; x <= 700; x += step) {
      for (double y = -700; y <= 700; y += step) {
        final pt = _worldToScreen(Offset(x, y), screenCenter);
        if (pt.dx >= 0 &&
            pt.dx <= size.width &&
            pt.dy >= 0 &&
            pt.dy <= size.height) {
          canvas.drawCircle(pt, 1.3, dotPaint);
        }
      }
    }

    final nodeMap = {for (var n in nodes) n.id: n};

    // 1. DIMENSIONI NODI RIDOTTE
    final screenNodes = <String, Rect>{};
    double getRadius(_GraphNode n) {
      final rawR = n.isPrimaryHub
          ? 14.0
          : (n.isBranchHub ? 11.0 : max(7.0, 9.5 - n.depth));
      return rawR * cameraScale.clamp(0.65, 1.5) + 4.0;
    }

    for (final node in nodes) {
      final pos = _worldToScreen(node.position, screenCenter);
      final r = getRadius(node);
      screenNodes[node.id] = Rect.fromCircle(center: pos, radius: r + 10.0);
    }

    final List<Rect> occupiedRects = screenNodes.values.toList();

    // 2. ARCHI A SINGOLA CURVA E SCHIVATA OSTACOLI
    for (int i = 0; i < edges.length; i++) {
      final edge = edges[i];
      final source = nodeMap[edge.sourceId];
      final target = nodeMap[edge.targetId];
      if (source == null || target == null) continue;

      final p1 = _worldToScreen(source.position, screenCenter);
      final p2 = _worldToScreen(target.position, screenCenter);

      final r1 = getRadius(source);
      final r2 = getRadius(target);

      final dx = p2.dx - p1.dx;
      final dy = p2.dy - p1.dy;
      final distance = sqrt(dx * dx + dy * dy);

      if (distance < (r1 + r2)) continue;

      final dirX = dx / distance;
      final dirY = dy / distance;

      final startPt = Offset(p1.dx + dirX * r1, p1.dy + dirY * r1);
      final endPt = Offset(p2.dx - dirX * r2, p2.dy - dirY * r2);

      // Calcolo del vettore perpendicolare per la curva
      final perpX = -dirY;
      final perpY = dirX;

      // Spinta di base per separare gli archi tra loro (Effetto "Corsie")
      final laneOffset = ((i % 5) - 2) * 15.0;

      // Spinta dinamica per schivare i nodi in mezzo al tragitto
      double obstacleRepulsion = 0.0;
      final midLinePoint =
          Offset((startPt.dx + endPt.dx) / 2, (startPt.dy + endPt.dy) / 2);

      for (final node in nodes) {
        if (node.id == source.id || node.id == target.id) continue;

        final nPos = _worldToScreen(node.position, screenCenter);
        final distToMid = (nPos - midLinePoint).distance;
        final nRadius = getRadius(node);

        if (distToMid < nRadius + 50.0) {
          final crossProduct =
              (endPt.dx - startPt.dx) * (nPos.dy - startPt.dy) -
                  (endPt.dy - startPt.dy) * (nPos.dx - startPt.dx);
          final sign = crossProduct > 0 ? -1.0 : 1.0;
          obstacleRepulsion += sign * (80.0 - distToMid).clamp(30.0, 100.0);
        }
      }

      // Punto di controllo unico (curva dolce a U, non a S)
      final totalCurve = laneOffset + obstacleRepulsion;
      final cp = Offset(
        midLinePoint.dx + perpX * totalCurve,
        midLinePoint.dy + perpY * totalCurve,
      );

      final bool isHighlighted = selectedNode != null &&
          (selectedNode!.id == source.id || selectedNode!.id == target.id);
      final bool isDimmed = selectedNode != null && !isHighlighted;

      final paint = Paint()
        ..color = isHighlighted
            ? AppColors.accentCoral
            : AppColors.statusGreen.withOpacity(isDimmed ? 0.12 : 0.48)
        ..strokeWidth = isHighlighted ? 2.2 : 1.4
        ..style = PaintingStyle.stroke;

      final path = Path()
        ..moveTo(startPt.dx, startPt.dy)
        ..quadraticBezierTo(cp.dx, cp.dy, endPt.dx, endPt.dy);

      canvas.drawPath(path, paint);

      // Posizionamento del testo a metà dell'arco
      if ((!isDimmed || isHighlighted) &&
          edge.predicate.isNotEmpty &&
          cameraScale > 0.65) {
        // Punto medio esatto della curva di Bézier quadratica
        final midX = 0.25 * startPt.dx + 0.5 * cp.dx + 0.25 * endPt.dx;
        final midY = 0.25 * startPt.dy + 0.5 * cp.dy + 0.25 * endPt.dy;

        Offset textPoint = Offset(midX, midY);

        final predSpan = TextSpan(
          text: edge.predicate,
          style: TextStyle(
            color:
                isHighlighted ? AppColors.accentCoral : AppColors.textSecondary,
            fontSize: isHighlighted ? 9.5 : 8.0, // Testo archi più piccolo
            fontWeight: isHighlighted ? FontWeight.bold : FontWeight.w500,
          ),
        );
        final tp = TextPainter(text: predSpan, textDirection: TextDirection.ltr)
          ..layout();

        Rect labelRect = Rect.fromCenter(
            center: textPoint, width: tp.width + 10, height: tp.height + 6);

        int attempts = 0;
        double shiftRadius = 10.0;
        double angle = 0.0;

        while (attempts < 8) {
          bool hasCollision = false;
          for (final rect in occupiedRects) {
            if (rect.overlaps(labelRect)) {
              hasCollision = true;
              break;
            }
          }

          if (!hasCollision) break;

          attempts++;
          textPoint = Offset(
              midX + cos(angle) * shiftRadius, midY + sin(angle) * shiftRadius);
          labelRect = Rect.fromCenter(
              center: textPoint, width: tp.width + 10, height: tp.height + 6);

          angle += (pi / 3);
          if (attempts % 6 == 0) shiftRadius += 12.0;
        }

        occupiedRects.add(labelRect);

        canvas.drawRRect(
          RRect.fromRectAndRadius(labelRect, const Radius.circular(5)),
          Paint()..color = AppColors.background.withOpacity(0.95),
        );
        tp.paint(canvas, textPoint - Offset(tp.width / 2, tp.height / 2));
      }
    }

    // 3. DISEGNO DEI NODI (Ridimensionato)
    for (final node in nodes) {
      final pos = _worldToScreen(node.position, screenCenter);

      final bool isSelected = selectedNode?.id == node.id;
      final bool isConnectedToSelected = selectedNode != null &&
          edges.any((e) =>
              (e.sourceId == selectedNode!.id && e.targetId == node.id) ||
              (e.targetId == selectedNode!.id && e.sourceId == node.id));
      final bool isDimmed =
          selectedNode != null && !isSelected && !isConnectedToSelected;

      final double baseRadius = getRadius(node);

      final Color mainColor = node.isPrimaryHub
          ? AppColors.accentCoral
          : (node.isBranchHub
              ? const Color(0xFF66BB9A)
              : AppColors.statusGreen);

      if (isSelected || node.isPrimaryHub) {
        canvas.drawCircle(
          pos,
          baseRadius + 5,
          Paint()..color = mainColor.withOpacity(isSelected ? 0.35 : 0.15),
        );
      }

      canvas.drawCircle(
        pos,
        baseRadius,
        Paint()..color = isDimmed ? mainColor.withOpacity(0.2) : mainColor,
      );

      canvas.drawCircle(
        pos,
        baseRadius * 0.48,
        Paint()..color = AppColors.background,
      );

      final textSpan = TextSpan(
        text: node.label,
        style: TextStyle(
          color: isDimmed
              ? AppColors.textSecondary.withOpacity(0.3)
              : (isSelected ? AppColors.accentCoral : AppColors.textPrimary),
          fontSize: node.isPrimaryHub
              ? 11.0
              : (node.isBranchHub ? 9.5 : 9.0), // Testo nodi ridotto
          fontWeight: node.isPrimaryHub || node.isBranchHub || isSelected
              ? FontWeight.bold
              : FontWeight.w500,
        ),
      );
      final tp = TextPainter(text: textSpan, textDirection: TextDirection.ltr)
        ..layout();

      final pillRect = RRect.fromRectAndRadius(
        Rect.fromCenter(
          center: pos + Offset(0, baseRadius + 12),
          width: tp.width + 12,
          height: tp.height + 4,
        ),
        const Radius.circular(8),
      );

      canvas.drawRRect(
        pillRect,
        Paint()
          ..color = AppColors.cardSurface.withOpacity(isDimmed ? 0.3 : 0.92),
      );
      tp.paint(
          canvas, pos + Offset(-tp.width / 2, baseRadius + 12 - tp.height / 2));
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => true;
}
