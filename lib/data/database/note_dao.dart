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
        'created_at': DateTime.now().millisecondsSinceEpoch,
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
    return id;
  }

  /// Ripristina una nota appena eliminata tramite "ANNULLA"
  Future<void> restoreNote(Map<String, dynamic> noteData) async {
    final db = await CipherDatabase.instance.database;
    await db.insert(
      'notes',
      {
        'id': noteData['id'],
        'content': noteData['content'],
        'vector_json': noteData['vector_json'],
        'status': 'PENDING',
        'created_at': noteData['created_at'] ?? DateTime.now().millisecondsSinceEpoch,
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
    await db.update(
      'notes',
      {
        'content': newContent,
        'status': 'PENDING',
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
    await db.delete(
      'notes',
      where: 'id = ?',
      whereArgs: [id],
    );
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

  Future<List<Map<String, dynamic>>> getIndexedNotes() async {
    final db = await CipherDatabase.instance.database;
    return await db.query(
      'notes',
      where: 'status = ?',
      whereArgs: ['INDEXED'],
      orderBy: 'created_at DESC',
    );
  }

  Future<void> markAsIndexed(String id, String vectorJson) async {
    final db = await CipherDatabase.instance.database;
    await db.update(
      'notes',
      {
        'vector_json': vectorJson,
        'status': 'INDEXED',
      },
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  Future<void> saveConnection(String sourceId, String targetId, double score) async {
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
}