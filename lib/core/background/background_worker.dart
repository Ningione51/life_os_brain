import 'package:flutter/foundation.dart';
import '../../data/database/cipher_database.dart';
import '../../data/database/note_dao.dart';
import '../../data/embedding/similarity_engine.dart';
import '../../data/sync/pc_bridge_service.dart';

class BackgroundWorker {
  static const String taskName = "indexPendingNotes";

  static bool isThermalPaused = false;
  static bool _isRunning = false;

  /// Notifica automaticamente la UI (Lista Note e Grafo) quando il background ha aggiornato i dati
  static final ValueNotifier<int> syncCompletedNotifier = ValueNotifier<int>(0);

  static Future<bool> processPendingNotes() async {
    if (_isRunning || isThermalPaused) return false;
    _isRunning = true;

    try {
      final dao = NoteDao();
      final db = await CipherDatabase.instance.database;

      // FASE 1: Indicizzazione locale istantanea (< 5ms) per tutte le note PENDING
      // Così anche se il PC è spento, la nota è subito pronta e collegata localmente
      final pendingNotes = await dao.getPendingNotes();
      for (final pNote in pendingNotes) {
        if (isThermalPaused) break;
        final String id = pNote['id'] as String;
        final String content = pNote['content'] as String;
        final localVec = SimilarityEngine.generateSimpleVector(content);
        await dao.markAsIndexed(
          id,
          SimilarityEngine.encodeVector(localVec),
          aiSynced: false,
        );
      }

      if (pendingNotes.isNotEmpty) {
        await _rebuildConnections(dao, db);
        syncCompletedNotifier.value++;
      }

      // FASE 2: Se il PC è acceso (ping < 400ms), arricchisce in background con Qwen 2.5
      final bool pcOnline = await PcBridgeService.isPcAvailable();
      if (pcOnline && !isThermalPaused) {
        final unsyncedNotes = await dao.getUnsyncedAiNotes();
        if (unsyncedNotes.isNotEmpty) {
          final currentNodes = await dao.getAllKgNodes();
          final existingEntityNames =
              currentNodes.map((n) => n['label'] as String).toSet().toList();

          for (final note in unsyncedNotes) {
            if (isThermalPaused) break;

            final String noteId = note['id'] as String;
            final String content = note['content'] as String;

            String? imagePath;
            final imgMatch = RegExp(r'\[\[IMG:([^\]]+)\]\]').firstMatch(content);
            if (imgMatch != null) {
              imagePath = imgMatch.group(1);
            }

            final result = await PcBridgeService.analyzeNoteOnPc(
              content: SimilarityEngine.stripMediaMarkers(content),
              existingEntities: existingEntityNames,
              imagePath: imagePath,
            );

            if (result != null) {
              final rawEntities = (result['entities'] as List<dynamic>? ?? [])
                  .map((e) => Map<String, dynamic>.from(e as Map))
                  .toList();
              final rawRelations = (result['relations'] as List<dynamic>? ?? [])
                  .map((e) => Map<String, dynamic>.from(e as Map))
                  .toList();

              await dao.saveKnowledgeGraphForNote(
                noteId: noteId,
                entities: rawEntities,
                relations: rawRelations,
              );

              for (final ent in rawEntities) {
                final name = (ent['name'] ?? ent['nome'] ?? '').toString();
                if (name.isNotEmpty && !existingEntityNames.contains(name)) {
                  existingEntityNames.add(name);
                }
              }

              final pcEmbedding = (result['embedding'] as List<dynamic>? ?? [])
                  .map((e) => (e as num).toDouble())
                  .toList();

              final vectorToSave = pcEmbedding.isNotEmpty
                  ? pcEmbedding
                  : SimilarityEngine.generateSimpleVector(content);

              await dao.markAsIndexed(
                noteId,
                SimilarityEngine.encodeVector(vectorToSave),
                aiSynced: true,
              );

              await _rebuildConnections(dao, db);
              // Aggiorna la UI in tempo reale dopo ogni singola nota elaborata dal PC
              syncCompletedNotifier.value++;
            }
          }
        }
      }

      return true;
    } catch (e) {
      return false;
    } finally {
      _isRunning = false;
    }
  }

  static Future<void> _rebuildConnections(NoteDao dao, dynamic db) async {
    final allNotes = await dao.getAllNotes();
    final allRelations = await dao.getAllKgRelations();
    await db.delete('note_connections');

    for (int i = 0; i < allNotes.length; i++) {
      final noteA = allNotes[i];
      final String idA = noteA['id'] as String;
      final String contentA = noteA['content'] as String;

      final nodesA = allRelations
          .where((r) => r['note_id'] == idA)
          .expand((r) => [r['source_node'] as String, r['target_node'] as String])
          .toSet();

      for (int j = i + 1; j < allNotes.length; j++) {
        final noteB = allNotes[j];
        final String idB = noteB['id'] as String;
        final String contentB = noteB['content'] as String;

        final nodesB = allRelations
            .where((r) => r['note_id'] == idB)
            .expand((r) => [r['source_node'] as String, r['target_node'] as String])
            .toSet();

        double score = SimilarityEngine.computeNoteLinkScore(contentA, contentB);

        final sharedKgNodes = nodesA.intersection(nodesB);
        if (sharedKgNodes.isNotEmpty) {
          score = (score + 0.55).clamp(0.0, 1.0);
        }

        if (score >= 0.38) {
          await dao.saveConnection(idA, idB, score);
        }
      }
    }
  }
}