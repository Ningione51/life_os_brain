import 'dart:convert';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path/path.dart';
import 'package:sqflite_sqlcipher/sqflite.dart';

class CipherDatabase {
  static final CipherDatabase instance = CipherDatabase._init();
  static Database? _database;
  final _secureStorage = const FlutterSecureStorage();

  CipherDatabase._init();

  Future<Database> get database async {
    if (_database != null) return _database!;
    _database = await _initDB('life_os_brain.db');
    return _database!;
  }

  Future<Database> _initDB(String filePath) async {
    final dbPath = await getDatabasesPath();
    final path = join(dbPath, filePath);

    String? encryptionKey = await _secureStorage.read(key: 'db_aes_key');
    if (encryptionKey == null) {
      final keyBytes = List<int>.generate(
        32,
        (i) => (DateTime.now().microsecondsSinceEpoch + i * 31) % 256,
      );
      encryptionKey = base64UrlEncode(keyBytes);
      await _secureStorage.write(key: 'db_aes_key', value: encryptionKey);
    }

    return await openDatabase(
      path,
      password: encryptionKey,
      version: 2,
      onCreate: _createDB,
      onUpgrade: _upgradeDB,
    );
  }

  Future<void> _createDB(Database db, int version) async {
    await db.execute('''
      CREATE TABLE notes (
        id TEXT PRIMARY KEY,
        content TEXT NOT NULL,
        vector_json TEXT,
        status TEXT NOT NULL DEFAULT 'PENDING',
        ai_synced INTEGER NOT NULL DEFAULT 0,
        created_at INTEGER NOT NULL
      )
    ''');

    await db.execute('''
      CREATE TABLE note_connections (
        source_id TEXT NOT NULL,
        target_id TEXT NOT NULL,
        similarity_score REAL NOT NULL,
        PRIMARY KEY (source_id, target_id),
        FOREIGN KEY (source_id) REFERENCES notes(id) ON DELETE CASCADE,
        FOREIGN KEY (target_id) REFERENCES notes(id) ON DELETE CASCADE
      )
    ''');

    await _createKnowledgeGraphTables(db);
  }

  Future<void> _upgradeDB(Database db, int oldVersion, int newVersion) async {
    if (oldVersion < 2) {
      try {
        await db.execute(
          'ALTER TABLE notes ADD COLUMN ai_synced INTEGER NOT NULL DEFAULT 0',
        );
      } catch (_) {}
      await _createKnowledgeGraphTables(db);
    }
  }

  Future<void> _createKnowledgeGraphTables(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS kg_nodes (
        id TEXT PRIMARY KEY,
        label TEXT NOT NULL,
        type TEXT NOT NULL DEFAULT 'concetto'
      )
    ''');

    await db.execute('''
      CREATE TABLE IF NOT EXISTS kg_relations (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        note_id TEXT NOT NULL,
        source_node TEXT NOT NULL,
        predicate TEXT NOT NULL,
        target_node TEXT NOT NULL,
        FOREIGN KEY (note_id) REFERENCES notes(id) ON DELETE CASCADE
      )
    ''');
  }

  Future<void> close() async {
    final db = _database;
    if (db != null) {
      await db.close();
      _database = null;
    }
  }
}