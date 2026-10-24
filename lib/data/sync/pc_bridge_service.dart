import 'dart:convert';
import 'dart:io';
import 'package:http/http.dart' as http;
import '../embedding/similarity_engine.dart';

class PcBridgeService {
  static final PcBridgeService instance = PcBridgeService._init();
  PcBridgeService._init();

  factory PcBridgeService() => instance;

  String bridgeUrl = 'http://192.168.1.8:8080'; // Assicurati che l'IP sia quello del tuo PC

  Future<Map<String, dynamic>?> syncNoteWithPc({
    required String noteId,
    required String content,
    List<Map<String, dynamic>> existingNodes = const [],
  }) async {
    try {
      String? base64Image;
      final imgMatch = RegExp(r'\[\[IMG:([^\]]+)\]\]').firstMatch(content);
      if (imgMatch != null) {
        final imgFile = File(imgMatch.group(1)!);
        if (imgFile.existsSync()) {
          base64Image = base64Encode(await imgFile.readAsBytes());
        }
      }

      final cleanText = SimilarityEngine.stripMediaMarkers(content);

      final response = await http
          .post(
            Uri.parse('$bridgeUrl/sync'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({
              'note_id': noteId,
              'content': cleanText,
              'text': cleanText,
              'image_base64': base64Image,
              'existing_nodes': existingNodes,
            }),
          )
          .timeout(const Duration(seconds: 90));

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body) as Map<String, dynamic>;
        final kg = data['knowledge_graph'] as Map<String, dynamic>?;

        final rawNodes = kg?['nodes'] ?? data['nodes'] ?? data['entities'] ?? [];
        final rawRelations = kg?['relations'] ?? data['relations'] ?? [];

        return {
          'entities': rawNodes,
          'relations': rawRelations,
          'embedding': data['embedding'],
        };
      }
    } catch (_) {
      // Se il PC è spento o non raggiungibile, ignora silenziosamente e riprova al prossimo sync
    }
    return null;
  }
}