import 'package:sqflite_sqlcipher/sqflite.dart';
import 'cipher_database.dart';

class NoteDao {
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

  Future<void> restoreNote(Map<String, dynamic> note) async {
    final db = await CipherDatabase.instance.database;
    await db.insert(
      'notes',
      {
        'id': note['id'],
        'content': note['content'],
        'vector_json': note['vector_json'],
        'status': note['status'] ?? 'PENDING',
        'ai_synced': note['ai_synced'] ?? 0,
        'created_at': note['created_at'] ?? DateTime.now().millisecondsSinceEpoch,
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<void> updateNote(String id, String newContent) async {
    final db = await CipherDatabase.instance.database;
    await db.delete(
      'note_connections',
      where: 'source_id = ? OR target_id = ?',
      whereArgs: [id, id],
    );
    await db.delete('kg_relations', where: 'note_id = ?', whereArgs: [id]);
    await _cleanOrphanKgNodes(db);
    await db.update(
      'notes',
      {
        'content': newContent,
        'status': 'PENDING',
        'ai_synced': 0,
        'vector_json': null,
      },
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  Future<void> deleteNote(String id) async {
    final db = await CipherDatabase.instance.database;
    await db.delete(
      'note_connections',
      where: 'source_id = ? OR target_id = ?',
      whereArgs: [id, id],
    );
    await db.delete('kg_relations', where: 'note_id = ?', whereArgs: [id]);
    await db.delete('notes', where: 'id = ?', whereArgs: [id]);
    await _cleanOrphanKgNodes(db);
  }

  /// Rimuove dalla tabella kg_nodes qualsiasi pallina/entità rimasta isolata senza relazioni (es. vecchio "#manu")
  Future<void> _cleanOrphanKgNodes(Database db) async {
    await db.execute('''
      DELETE FROM kg_nodes
      WHERE id NOT IN (SELECT source_node FROM kg_relations)
        AND id NOT IN (SELECT target_node FROM kg_relations)
    ''');
  }

  /// Forza la rigenerazione completa del Knowledge Graph da parte del PC
  Future<void> resetAllAiSyncForRebuild() async {
    final db = await CipherDatabase.instance.database;
    await db.delete('kg_relations');
    await db.delete('kg_nodes');
    await db.update('notes', {'ai_synced': 0});
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
      orderBy: 'created_at DESC',
    );
  }

  Future<List<Map<String, dynamic>>> getUnsyncedAiNotes() async {
    final db = await CipherDatabase.instance.database;
    return await db.query(
      'notes',
      where: 'ai_synced = 0',
      orderBy: 'created_at ASC',
    );
  }

  Future<List<Map<String, dynamic>>> getIndexedNotes() async {
    final db = await CipherDatabase.instance.database;
    return await db.query(
      'notes',
      where: 'status = ?',
      whereArgs: ['INDEXED'],
      orderBy: 'created_at DESC',
    );
  }

  Future<void> markAsIndexed(
    String id,
    String vectorJson, {
    bool aiSynced = false,
  }) async {
    final db = await CipherDatabase.instance.database;
    await db.update(
      'notes',
      {
        'vector_json': vectorJson,
        'status': 'INDEXED',
        if (aiSynced) 'ai_synced': 1,
      },
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  Future<void> saveConnection(
    String sourceId,
    String targetId,
    double score,
  ) async {
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

  Future<List<Map<String, dynamic>>> getAllConnections() async {
    final db = await CipherDatabase.instance.database;
    return await db.query('note_connections', orderBy: 'similarity_score DESC');
  }

  // Normalizza rimuovendo qualsiasi '#' iniziale e spazi extra: "#Manu" e "manu" diventano entrambi "manu"
  String _normalizeNodeId(String raw) {
    return raw
        .replaceAll(RegExp(r'^#+'), '')
        .trim()
        .toLowerCase()
        .replaceAll(RegExp(r'\s+'), ' ');
  }

  String _capitalizeLabel(String raw) {
    final clean = raw.replaceAll(RegExp(r'^#+'), '').trim();
    if (clean.isEmpty) return clean;
    return clean[0].toUpperCase() + clean.substring(1);
  }

  Future<void> saveKnowledgeGraphForNote({
    required String noteId,
    required List<Map<String, dynamic>> entities,
    required List<Map<String, dynamic>> relations,
  }) async {
    final db = await CipherDatabase.instance.database;
    await db.delete('kg_relations', where: 'note_id = ?', whereArgs: [noteId]);

    for (final ent in entities) {
      final rawName = (ent['name'] ?? ent['nome'] ?? '').toString().trim();
      final nodeId = _normalizeNodeId(rawName);
      if (nodeId.isEmpty) continue;
      final type = (ent['type'] ?? ent['tipo'] ?? 'concetto').toString().toLowerCase();

      await db.insert(
        'kg_nodes',
        {
          'id': nodeId,
          'label': _capitalizeLabel(rawName),
          'type': type,
        },
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
    }

    for (final rel in relations) {
      final srcRaw = (rel['source'] ?? rel['soggetto'] ?? rel['entita1'] ?? '').toString().trim();
      final predRaw = (rel['predicate'] ?? rel['relazione'] ?? rel['tipo'] ?? 'collegato a').toString().trim();
      final dstRaw = (rel['target'] ?? rel['oggetto'] ?? rel['entita2'] ?? '').toString().trim();

      final srcId = _normalizeNodeId(srcRaw);
      final dstId = _normalizeNodeId(dstRaw);
      if (srcId.isEmpty || dstId.isEmpty || srcId == dstId) continue;

      await db.insert(
        'kg_nodes',
        {'id': srcId, 'label': _capitalizeLabel(srcRaw), 'type': 'concetto'},
        conflictAlgorithm: ConflictAlgorithm.ignore,
      );
      await db.insert(
        'kg_nodes',
        {'id': dstId, 'label': _capitalizeLabel(dstRaw), 'type': 'concetto'},
        conflictAlgorithm: ConflictAlgorithm.ignore,
      );

      await db.insert('kg_relations', {
        'note_id': noteId,
        'source_node': srcId,
        'predicate': predRaw,
        'target_node': dstId,
      });
    }

    await _cleanOrphanKgNodes(db);
  }

  Future<List<Map<String, dynamic>>> getAllKgNodes() async {
    final db = await CipherDatabase.instance.database;
    await _cleanOrphanKgNodes(db);
    return await db.query('kg_nodes');
  }

  Future<List<Map<String, dynamic>>> getAllKgRelations() async {
    final db = await CipherDatabase.instance.database;
    return await db.query('kg_relations');
  }

  Future<List<Map<String, dynamic>>> getRelationsForNote(String noteId) async {
    final db = await CipherDatabase.instance.database;
    return await db.query(
      'kg_relations',
      where: 'note_id = ?',
      whereArgs: [noteId],
    );
  }
}