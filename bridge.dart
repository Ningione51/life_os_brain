import 'dart:convert';
import 'dart:io';

const int bridgePort = 8080;
const String ollamaBaseUrl = 'http://127.0.0.1:11434';

void main() async {
  final server = await HttpServer.bind(InternetAddress.anyIPv4, bridgePort);
  print('=== Life_OS Micro-Bridge attivo su http://0.0.0.0:$bridgePort ===');

  await for (HttpRequest request in server) {
    // Gestione CORS
    request.response.headers.add('Access-Control-Allow-Origin', '*');
    request.response.headers.add('Access-Control-Allow-Methods', 'POST, GET, OPTIONS');
    request.response.headers.add('Access-Control-Allow-Headers', 'Content-Type');

    if (request.method == 'OPTIONS') {
      request.response.statusCode = HttpStatus.ok;
      await request.response.close();
      continue;
    }

    if (request.method == 'POST' && request.uri.path == '/sync') {
      await _handleSync(request);
    } else {
      request.response.statusCode = HttpStatus.notFound;
      request.response.write(jsonEncode({'error': 'Endpoint non trovato'}));
      await request.response.close();
    }
  }
}

Future<void> _handleSync(HttpRequest request) async {
  try {
    final bodyString = await utf8.decoder.bind(request).join();
    final payload = jsonDecode(bodyString) as Map<String, dynamic>;

    final String noteId = (payload['note_id'] ?? '').toString();
    String content = (payload['content'] ?? payload['text'] ?? '').toString();
    final String? base64Image = payload['image_base64'] as String?;
    final List<dynamic> existingNodes = payload['existing_nodes'] as List<dynamic>? ?? [];

    print('\n[SYNC] Ricevuta nota: $noteId (${existingNodes.length} nodi esistenti nel contesto)');

    if (base64Image != null && base64Image.isNotEmpty) {
      print('[VISION] Analisi immagine con qwen2.5vl:7b...');
      final visionDescription = await _analyzeImageWithQwenVL(base64Image, content);
      if (visionDescription.isNotEmpty) {
        content = '$content\n[Dettagli Immagine]: $visionDescription'.trim();
      }
    }

    print('[KG] Estrazione Knowledge Graph con qwen2.5:7b...');
    final kgData = await _extractKnowledgeGraph(content, existingNodes);

    print('[EMBED] Generazione embedding con nomic-embed-text...');
    final embedding = await _generateEmbedding(content);

    final responsePayload = {
      'status': 'ok',
      'note_id': noteId,
      'enriched_content': content,
      'knowledge_graph': kgData,
      'embedding': embedding,
    };

    request.response.statusCode = HttpStatus.ok;
    request.response.headers.contentType = ContentType.json;
    request.response.write(jsonEncode(responsePayload));
    await request.response.close();
    print('[OK] Sincronizzazione completata per nota $noteId');
  } catch (e, stack) {
    print('[ERRORE] $e\n$stack');
    request.response.statusCode = HttpStatus.internalServerError;
    request.response.headers.contentType = ContentType.json;
    request.response.write(jsonEncode({'error': e.toString()}));
    await request.response.close();
  }
}

Future<Map<String, dynamic>> _extractKnowledgeGraph(
  String text,
  List<dynamic> existingNodes,
) async {
  final compactExistingNodes = existingNodes.map((n) {
    if (n is Map) {
      return '${n['id']} (label: "${n['label']}", tipo: ${n['type']})';
    }
    return n.toString();
  }).join(', ');

  final systemPrompt = '''
Sei il motore di Knowledge Graph di Life_OS. Estrai Nodi (entità) e Relazioni (triplette orientate) dalla nota in formato JSON rigoroso.

NODI GIÀ ESISTENTI NEL DATABASE:
[${compactExistingNodes.isEmpty ? 'Nessun nodo salvato, inizia creando "io"' : compactExistingNodes}]

REGOLE ONTOLOGICHE (SEGUI ALLA LETTERA):
1. ANCORAGGIO: L'utente che scrive è SEMPRE id: "io". Non creare collegamenti inventati tra "io" e oggetti se non esplicitamente descritti da un'azione nella nota.
2. IDEE E IPOTESI: Se qualcosa è un'idea per un regalo o un piano futuro non ancora realizzato, usa predicati come "IDEA_REGALO_PER". Non usare "HA_RICEVUTO".
3. EVENTI: Gli eventi (es. lauree, compleanni) DEVONO essere collegati al soggetto protagonista usando "PROTAGONISTA". Es: laurea_martina -> PROTAGONISTA -> martina.
4. ECCEZIONI E NEGAZIONI: Crea un nodo padre per la categoria generale e un nodo figlio per l'eccezione (SOTTOCATEGORIA_DI). Applica il verbo positivo al padre e il verbo negativo (NON_AMA) ESCLUSIVAMENTE al figlio. Mai creare contraddizioni sullo stesso nodo.
5. FORMATO: id e source/target_node in snake_case minuscolo. predicate in MAIUSCOLO_SNAKE_CASE. type: persona, animale, oggetto, concetto, evento, luogo, data.

ESEMPI DI RIFERIMENTO (Output Atteso):
Input: "Manu e Martina sono sorelle. Il 26/10/2024 io e Manu dobbiamo andare alla laurea di Martina."
Output:
{
  "nodes": [
    {"id": "io", "label": "Io", "type": "persona"},
    {"id": "manu", "label": "Manu", "type": "persona"},
    {"id": "martina", "label": "Martina", "type": "persona"},
    {"id": "laurea_martina", "label": "Laurea di Martina", "type": "evento"},
    {"id": "26_10_2024", "label": "26/10/2024", "type": "data"}
  ],
  "relations": [
    {"source_node": "manu", "predicate": "SORELLA_DI", "target_node": "martina"},
    {"source_node": "io", "predicate": "PARTECIPERA_A", "target_node": "laurea_martina"},
    {"source_node": "manu", "predicate": "PARTECIPERA_A", "target_node": "laurea_martina"},
    {"source_node": "laurea_martina", "predicate": "PROTAGONISTA", "target_node": "martina"},
    {"source_node": "laurea_martina", "predicate": "PROGRAMMATO_IL", "target_node": "26_10_2024"}
  ]
}

Input: "A Manu piace il cioccolato ma a Manu non piace il cioccolato Lidl."
Output:
{
  "nodes": [
    {"id": "manu", "label": "Manu", "type": "persona"},
    {"id": "cioccolato", "label": "Cioccolato", "type": "concetto"},
    {"id": "cioccolato_lidl", "label": "Cioccolato Lidl", "type": "concetto"}
  ],
  "relations": [
    {"source_node": "manu", "predicate": "AMA", "target_node": "cioccolato"},
    {"source_node": "cioccolato_lidl", "predicate": "SOTTOCATEGORIA_DI", "target_node": "cioccolato"},
    {"source_node": "manu", "predicate": "NON_AMA", "target_node": "cioccolato_lidl"}
  ]
}

Input: "Idea regali laurea Manu: Kindle, profumo Narciso Rodriguez. Il Kindle costa 474."
Output:
{
  "nodes": [
    {"id": "manu", "label": "Manu", "type": "persona"},
    {"id": "laurea_manu", "label": "Laurea di Manu", "type": "evento"},
    {"id": "kindle", "label": "Kindle", "type": "oggetto"},
    {"id": "profumo_narciso_rodriguez", "label": "Profumo Narciso Rodriguez", "type": "oggetto"},
    {"id": "474_euro", "label": "474 Euro", "type": "concetto"}
  ],
  "relations": [
    {"source_node": "laurea_manu", "predicate": "PROTAGONISTA", "target_node": "manu"},
    {"source_node": "kindle", "predicate": "IDEA_REGALO_PER", "target_node": "laurea_manu"},
    {"source_node": "profumo_narciso_rodriguez", "predicate": "IDEA_REGALO_PER", "target_node": "laurea_manu"},
    {"source_node": "kindle", "predicate": "COSTA", "target_node": "474_euro"}
  ]
}
''';

  final response = await _postToOllama('/api/chat', {
    'model': 'qwen2.5:7b',
    'messages': [
      {'role': 'system', 'content': systemPrompt},
      {'role': 'user', 'content': 'Estrai il Knowledge Graph da questa nota:\n"$text"'},
    ],
    'format': 'json',
    'stream': false,
    'options': {
      'temperature': 0.0, // Impostato a 0.0 per massima rigidità strutturale
    },
  });

  final messageContent = response['message']?['content']?.toString() ?? '{}';
  try {
    return jsonDecode(messageContent) as Map<String, dynamic>;
  } catch (_) {
    return {'nodes': [], 'relations': []};
  }
}

Future<String> _analyzeImageWithQwenVL(String base64Image, String userPrompt) async {
  try {
    final response = await _postToOllama('/api/chat', {
      'model': 'qwen2.5vl:7b',
      'messages': [
        {
          'role': 'user',
          'content': userPrompt.isNotEmpty
              ? 'Descrivi gli elementi chiave, testi, date, persone o oggetti presenti in questa immagine in relazione a: $userPrompt'
              : 'Estrai il testo e descrivi in modo conciso gli elementi chiave di questa immagine.',
          'images': [base64Image],
        }
      ],
      'stream': false,
    });
    return response['message']?['content']?.toString().trim() ?? '';
  } catch (e) {
    print('[VISION WARN] Impossibile analizzare immagine: $e');
    return '';
  }
}

Future<List<double>> _generateEmbedding(String text) async {
  try {
    final response = await _postToOllama('/api/embeddings', {
      'model': 'nomic-embed-text',
      'prompt': text,
    });
    if (response['embedding'] is List) {
      return (response['embedding'] as List)
          .map((e) => (e as num).toDouble())
          .toList();
    }
    return [];
  } catch (e) {
    print('[EMBED WARN] Impossibile generare embedding: $e');
    return [];
  }
}

Future<Map<String, dynamic>> _postToOllama(
  String endpoint,
  Map<String, dynamic> body,
) async {
  final client = HttpClient();
  final request = await client.postUrl(Uri.parse('$ollamaBaseUrl$endpoint'));
  request.headers.contentType = ContentType.json;
  request.add(utf8.encode(jsonEncode(body)));

  final response = await request.close();
  final responseBody = await utf8.decoder.bind(response).join();
  client.close();

  if (response.statusCode != 200) {
    // Fix: Corretta l'interpolazione della stringa di errore su più righe
    throw Exception('Errore Ollama ($endpoint): ${response.statusCode}\n$responseBody');
  }
  return jsonDecode(responseBody) as Map<String, dynamic>;
}