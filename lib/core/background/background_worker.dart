import 'dart:convert';
import 'package:flutter/foundation.dart';
import '../../data/database/note_dao.dart';
import '../../data/embedding/similarity_engine.dart';
import '../../data/sync/pc_bridge_service.dart';

class BackgroundWorker {
  static final ValueNotifier<int> syncCompletedNotifier = ValueNotifier<int>(0);
  static bool _isProcessing = false;

  static Future<void> processPendingNotes() async {
    if (_isProcessing) return;
    _isProcessing = true;

    try {
      final dao = NoteDao.instance;

      // 1. Indicizzazione vettoriale locale immediata per le note in stato PENDING
      final pending = await dao.getPendingNotes();
      for (final note in pending) {
        final String id = note['id'] as String;
        final String content = note['content'] as String;
        final vector = SimilarityEngine.generateSimpleVector(content);
        await dao.markAsIndexed(id, jsonEncode(vector), aiSynced: false);
      }

      // 2. Sincronizzazione con il Micro-Bridge su PC (Ollama) per le note con ai_synced = 0
      final unsynced = await dao.getUnsyncedAiNotes();
      for (final note in unsynced) {
        final String id = note['id'] as String;
        final String content = note['content'] as String;
        final String vectorJson = (note['vector_json'] as String?) ?? '[]';

        final existingNodes = await dao.getAllKgNodes();

        final result = await PcBridgeService.instance.syncNoteWithPc(
          noteId: id,
          content: content,
          existingNodes: existingNodes,
        );

        if (result != null) {
          final entities = (result['entities'] as List<dynamic>? ?? [])
              .map((e) => Map<String, dynamic>.from(e as Map))
              .toList();
          final relations = (result['relations'] as List<dynamic>? ?? [])
              .map((r) => Map<String, dynamic>.from(r as Map))
              .toList();

          await dao.saveKnowledgeGraphForNote(
            noteId: id,
            entities: entities,
            relations: relations,
          );

          final String updatedVector = result['embedding'] != null
              ? jsonEncode(result['embedding'])
              : vectorJson;

          await dao.markAsIndexed(id, updatedVector, aiSynced: true);
        }
      }

      // 3. Ricalcolo connessioni semantiche tra le note
      final allNotes = await dao.getAllNotes();
      for (int i = 0; i < allNotes.length; i++) {
        for (int j = i + 1; j < allNotes.length; j++) {
          final n1 = allNotes[i];
          final n2 = allNotes[j];
          final score = SimilarityEngine.computeNoteLinkScore(
              n1['content'] as String, n2['content'] as String);
          if (score >= 0.35) {
            await dao.saveConnection(
              n1['id'] as String,
              n2['id'] as String,
              score,
            );
          }
        }
      }

      // Notifica la UI (QuickNoteScreen e MemoryGraphScreen)
      syncCompletedNotifier.value++;
    } catch (e) {
      debugPrint('BackgroundWorker error: $e');
    } finally {
      _isProcessing = false;
    }
  }
}
