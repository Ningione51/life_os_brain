import 'dart:convert';
import 'dart:io';

class PcBridgeService {
  // Indirizzo IPv4 del tuo PC rilevato su scheda Wi-Fi 3
  static String pcIp = '192.168.1.3';
  static int pcPort = 8080;

  /// Controlla in 600 millisecondi se il tuo PC è acceso e raggiungibile sulla rete locale
  static Future<bool> isPcAvailable() async {
    final client = HttpClient()
      ..connectionTimeout = const Duration(milliseconds: 600);
    try {
      final req = await client.getUrl(Uri.parse('http://$pcIp:$pcPort/ping'));
      final resp = await req.close().timeout(const Duration(milliseconds: 600));
      client.close();
      return resp.statusCode == HttpStatus.ok;
    } catch (_) {
      client.close(force: true);
      return false;
    }
  }

  /// Invia la nota + i nodi attuali del grafo al PC per l'analisi contestuale con Qwen 2.5
  static Future<Map<String, dynamic>?> analyzeNoteOnPc({
    required String content,
    required List<String> existingEntities,
    String? imagePath,
  }) async {
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 4);
    try {
      String? base64Img;
      if (imagePath != null && imagePath.isNotEmpty) {
        final file = File(imagePath);
        if (await file.exists()) {
          final bytes = await file.readAsBytes();
          base64Img = base64Encode(bytes);
        }
      }

      final req = await client.postUrl(Uri.parse('http://$pcIp:$pcPort/sync'));
      req.headers.contentType = ContentType.json;

      final payload = jsonEncode({
        'content': content,
        'existing_entities': existingEntities,
        if (base64Img != null) 'image_base64': base64Img,
      });

      req.write(payload);
      final resp = await req.close().timeout(const Duration(seconds: 90));
      if (resp.statusCode != HttpStatus.ok) {
        client.close();
        return null;
      }

      final respBody = await utf8.decoder.bind(resp).join();
      client.close();
      return jsonDecode(respBody) as Map<String, dynamic>;
    } catch (_) {
      client.close(force: true);
      return null;
    }
  }
}