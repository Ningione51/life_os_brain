import 'cipher_database.dart';
import 'package:sqflite_sqlcipher/sqflite.dart';

class NoteDao {
  static final NoteDao instance = NoteDao._init();
  NoteDao._init();

  factory NoteDao() => instance;

  String _normalizeId(String raw) {
    return raw
        .replaceAll('#', '')
        .trim()
        .toLowerCase()
        .replaceAll(RegExp(r'\s+'), '_');
  }

  String _formatLabel(String raw, String fallbackId) {
    final clean = raw.replaceAll('#', '').trim();
    if (clean.isEmpty) return fallbackId;
    return clean[0].toUpperCase() + clean.substring(1);
  }

  Future<List<Map<String, dynamic>>> getAllNotes() async {
    final db = await CipherDatabase.instance.database;
    return await db.query('notes', orderBy: 'created_at DESC');
  }

  Future<List<Map<String, dynamic>>> getPendingNotes() async {
    final db = await CipherDatabase.instance.database;
    return await db.query(
      'notes',
      where: 'status = ?',
      whereArgs: ['PENDING'],
    );
  }

  Future<List<Map<String, dynamic>>> getUnsyncedAiNotes() async {
    final db = await CipherDatabase.instance.database;
    return await db.query(
      'notes',
      where: 'ai_synced = ?',
      whereArgs: [0],
      orderBy: 'created_at ASC',
    );
  }

  Future<int> markAsIndexed(String id, String vectorJson,
      {required bool aiSynced}) async {
    final db = await CipherDatabase.instance.database;
    return await db.update(
      'notes',
      {
        'vector_json': vectorJson,
        'status': 'INDEXED',
        'ai_synced': aiSynced ? 1 : 0,
      },
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  Future<List<Map<String, dynamic>>> getAllConnections() async {
    final db = await CipherDatabase.instance.database;
    return await db.query('note_connections');
  }

  Future<String> insertQuickNote(String content) async {
    final db = await CipherDatabase.instance.database;
    final id = DateTime.now().millisecondsSinceEpoch.toString();
    await db.insert(
      'notes',
      {
        'id': id,
        'content': content,
        'status': 'PENDING',
        'ai_synced': 0,
        'created_at': DateTime.now().millisecondsSinceEpoch,
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
    return id;
  }

  Future<int> updateNote(String id, String content) async {
    final db = await CipherDatabase.instance.database;
    return await db.update(
      'notes',
      {
        'content': content,
        'status': 'PENDING',
        'ai_synced': 0,
      },
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  Future<int> deleteNote(String id) async {
    final db = await CipherDatabase.instance.database;

    // 1. Elimina prima tutte le relazioni nel Knowledge Graph create da questa nota
    await db.delete(
      'kg_relations',
      where: 'note_id = ?',
      whereArgs: [id],
    );

    // 2. Elimina la nota vera e propria
    final result = await db.delete(
      'notes',
      where: 'id = ?',
      whereArgs: [id],
    );

    // 3. Avvia la pulizia per cancellare i nodi rimasti senza collegamenti
    await cleanUpOrphanNodes();

    return result;
  }

  Future<void> restoreNote(Map<String, dynamic> note) async {
    final db = await CipherDatabase.instance.database;
    await db.insert(
      'notes',
      {
        'id': note['id'],
        'content': note['content'],
        'vector_json': note['vector_json'],
        'status': 'PENDING',
        'ai_synced': 0,
        'created_at':
            note['created_at'] ?? DateTime.now().millisecondsSinceEpoch,
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<void> resetAllAiSyncForRebuild() async {
    final db = await CipherDatabase.instance.database;
    await db.transaction((txn) async {
      await txn.delete('kg_relations');
      await txn.delete('kg_nodes');
      await txn.update('notes', {'ai_synced': 0, 'status': 'PENDING'});
    });
  }

  Future<List<Map<String, dynamic>>> getAllKgNodes() async {
    final db = await CipherDatabase.instance.database;
    return await db.query('kg_nodes');
  }

  Future<List<Map<String, dynamic>>> getAllKgRelations() async {
    final db = await CipherDatabase.instance.database;
    return await db.query('kg_relations');
  }

  Future<void> saveKnowledgeGraphForNote({
    required String noteId,
    required List<Map<String, dynamic>> entities,
    required List<Map<String, dynamic>> relations,
  }) async {
    final db = await CipherDatabase.instance.database;
    await db.transaction((txn) async {
      // Pulisce le vecchie relazioni di questa nota (utile se la nota è stata modificata)
      await txn
          .delete('kg_relations', where: 'note_id = ?', whereArgs: [noteId]);

      // 1. Garantisce sempre l'esistenza del nodo radice dell'utente (#Io)
      await txn.insert(
        'kg_nodes',
        {'id': 'io', 'label': 'Io', 'type': 'persona'},
        conflictAlgorithm: ConflictAlgorithm.ignore,
      );

      // 2. Inserisce o fonde dinamicamente i nodi
      for (final ent in entities) {
        final rawName =
            (ent['id'] ?? ent['name'] ?? ent['nome'] ?? ent['label'] ?? '')
                .toString();
        final rawLabel =
            (ent['label'] ?? ent['name'] ?? ent['nome'] ?? rawName).toString();
        final type = (ent['type'] ?? ent['tipo'] ?? 'concetto')
            .toString()
            .trim()
            .toLowerCase();

        final cleanId = _normalizeId(rawName);
        if (cleanId.isNotEmpty) {
          await txn.insert(
            'kg_nodes',
            {
              'id': cleanId,
              'label': cleanId == 'io' ? 'Io' : _formatLabel(rawLabel, cleanId),
              'type': cleanId == 'io' ? 'persona' : type,
            },
            conflictAlgorithm: ConflictAlgorithm.replace,
          );
        }
      }

      // 3. Inserisce le relazioni normalizzando gli estremi e rispettando UNIQUE
      for (final rel in relations) {
        final rawSource =
            (rel['source_node'] ?? rel['source'] ?? rel['sorgente'] ?? '')
                .toString();
        final rawPred =
            (rel['predicate'] ?? rel['predicato'] ?? rel['type'] ?? '')
                .toString();
        final rawTarget =
            (rel['target_node'] ?? rel['target'] ?? rel['destinazione'] ?? '')
                .toString();

        final source = _normalizeId(rawSource);
        final target = _normalizeId(rawTarget);
        final predicate =
            rawPred.trim().toUpperCase().replaceAll(RegExp(r'\s+'), '_');

        if (source.isNotEmpty &&
            predicate.isNotEmpty &&
            target.isNotEmpty &&
            source != target) {
          await txn.insert(
            'kg_nodes',
            {
              'id': source,
              'label': source == 'io' ? 'Io' : _formatLabel(rawSource, source),
              'type': source == 'io' ? 'persona' : 'concetto',
            },
            conflictAlgorithm: ConflictAlgorithm.ignore,
          );
          await txn.insert(
            'kg_nodes',
            {
              'id': target,
              'label': target == 'io' ? 'Io' : _formatLabel(rawTarget, target),
              'type': target == 'io' ? 'persona' : 'concetto',
            },
            conflictAlgorithm: ConflictAlgorithm.ignore,
          );

          await txn.insert(
            'kg_relations',
            {
              'note_id': noteId,
              'source_node': source,
              'predicate': predicate,
              'target_node': target,
            },
            conflictAlgorithm: ConflictAlgorithm.replace,
          );
        }
      }
    });
    await cleanUpOrphanNodes();
  }

  Future<void> saveConnection(
      String sourceId, String targetId, double score) async {
    final db = await CipherDatabase.instance.database;
    await db.insert(
      'note_connections',
      {
        'source_id': sourceId,
        'target_id': targetId,
        'similarity_score': score,
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<void> cleanUpOrphanNodes() async {
    final db = await CipherDatabase.instance.database;

    // Elimina i nodi il cui ID non è presente in nessuna relazione (salvando il nodo radice 'io')
    await db.rawDelete('''
      DELETE FROM kg_nodes 
      WHERE id NOT IN (
        SELECT source_node FROM kg_relations 
        UNION 
        SELECT target_node FROM kg_relations
      ) AND id != 'io'
    ''');
  }
}
