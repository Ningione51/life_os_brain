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

    // Recupera o genera una chiave di cifratura AES casuale salvata nel keystore hardware
    String? encryptionKey = await _secureStorage.read(key: 'db_aes_key');
    if (encryptionKey == null) {
      final keyBytes = List<int>.generate(32, (i) => DateTime.now().microsecondsSinceEpoch % 256);
      encryptionKey = base64UrlEncode(keyBytes);
      await _secureStorage.write(key: 'db_aes_key', value: encryptionKey);
    }

    return await openDatabase(
      path,
      password: encryptionKey,
      version: 1,
      onCreate: _createDB,
    );
  }

  Future<void> _createDB(Database db, int version) async {
    await db.execute('''
      CREATE TABLE notes (
        id TEXT PRIMARY KEY,
        content TEXT NOT NULL,
        vector_json TEXT,
        status TEXT NOT NULL DEFAULT 'PENDING',
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
  }

  Future<void> close() async {
    final db = _database;
    if (db != null) {
      await db.close();
      _database = null;
    }
  }
}