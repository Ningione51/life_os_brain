import '../../data/database/cipher_database.dart';
import '../../data/database/note_dao.dart';
import '../../data/embedding/similarity_engine.dart';

class BackgroundWorker {
  static const String taskName = "indexPendingNotes";

  static Future<bool> processPendingNotes() async {
    try {
      final dao = NoteDao();
      final db = await CipherDatabase.instance.database;
      final allNotes = await dao.getAllNotes();
      if (allNotes.isEmpty) return true;

      // Pulisce e ricalcola la rete sinaptica evitando falsi positivi tra soggetti diversi
      await db.delete('note_connections');

      for (int i = 0; i < allNotes.length; i++) {
        final noteA = allNotes[i];
        final String idA = noteA['id'] as String;
        final String contentA = noteA['content'] as String;
        final vecA = SimilarityEngine.generateSimpleVector(contentA);

        for (int j = i + 1; j < allNotes.length; j++) {
          final noteB = allNotes[j];
          final String idB = noteB['id'] as String;
          final String contentB = noteB['content'] as String;

          final score = SimilarityEngine.computeNoteLinkScore(contentA, contentB);

          // Crea il collegamento solo se supera la soglia di vera affinità semantica/soggetto
          if (score >= 0.38) {
            await dao.saveConnection(idA, idB, score);
          }
        }

        if (noteA['status'] == 'PENDING') {
          await dao.markAsIndexed(idA, SimilarityEngine.encodeVector(vecA));
        }
      }
      return true;
    } catch (e) {
      return false;
    }
  }
}