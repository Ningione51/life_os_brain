import 'dart:convert';
import 'dart:io';

void main() async {
  final server = await HttpServer.bind(InternetAddress.anyIPv4, 8080);
  stdout.writeln('=== Life_Os Micro-Bridge Dinamico attivo su 0.0.0.0:8080 ===');

  await for (HttpRequest request in server) {
    if (request.method == 'GET' && request.uri.path == '/ping') {
      request.response
        ..statusCode = HttpStatus.ok
        ..write('ok');
      await request.response.close();
      continue;
    }

    if (request.method == 'POST' && request.uri.path == '/sync') {
      try {
        final bodyRaw = await utf8.decoder.bind(request).join();
        final Map<String, dynamic> data = jsonDecode(bodyRaw);

        final String noteContent = data['content'] ?? '';
        final List<dynamic> existingEntities = data['existing_entities'] ?? [];
        final String? base64Image = data['image_base64'];

        String imageContext = '';

        if (base64Image != null && base64Image.isNotEmpty) {
          stdout.writeln('[Bridge] Analisi immagine con qwen2.5vl:7b...');
          final visionResp = await _callOllama({
            'model': 'qwen2.5vl:7b',
            'prompt':
                'Descrivi in modo preciso cosa vedi, estrai eventuale testo, coordinate, oggetti o prodotti.',
            'images': [base64Image],
            'stream': false,
          });
          imageContext = visionResp['response'] ?? '';
        }

        final fullText = imageContext.isNotEmpty
            ? '$noteContent\n[Contenuto Immagine: $imageContext]'
            : noteContent;

        final existingListStr = existingEntities.isEmpty
            ? 'Nessun nodo preesistente'
            : existingEntities.join(', ');

        final systemPrompt = '''
Sei il motore di Knowledge Graph logico e dinamico di Life_Os.
Analizza la nota ed estrai un grafo di concetti e relazioni di profondità variabile (da 1 a N salti) seguendo la logica naturale del testo, SENZA forzare un numero fisso di livelli.

REGOLE LOGICHE FONDAMENTALI:
1. RIUTILIZZO DEL CONTESTO: Se un concetto corrisponde a uno già presente nel grafo dell'utente [$existingListStr], usa ESATTAMENTE lo stesso nome per collegarti ad esso. Non usare MAI il simbolo "#".
2. ANCORAGGIO AL SOGGETTO: Ogni informazione che riguarda una persona (es. "Manu") o l'autore ("Io") deve partire dal nodo di quella persona.
3. PROFONDITÀ DINAMICA (NON FORZARE LIVELLI INUTILI):
   - Usa 1 SOLO SALTO (Relazione Diretta) per attributi o fatti atomici:
     Esempio: "La Manu è nata il 24/04/2003" -> ("Manu" --[data di nascita]--> "24/04/2003"). NON creare nodi intermedi inutili se il fatto è diretto.
   - Usa 2 SALTI quando esiste un vero contenitore logico, una sfera di preferenze o un evento specifico:
     Esempio: "Regali laurea Manu: Kindle, profumo Narciso Rodriguez" -> ("Manu" --[evento]--> "Laurea"), ("Laurea" --[idea regalo]--> "Kindle"), ("Laurea" --[idea regalo]--> "Profumo Narciso Rodriguez").
     Esempio: "Alla Manu piace il cioccolato e odia i mandarini" -> ("Manu" --[sfera]--> "Gusti"), ("Gusti" --[adora]--> "Cioccolato"), ("Gusti" --[odia]--> "Mandarini").
   - Usa 3 O PIÙ SALTI quando un oggetto ha a sua volta dettagli, luoghi o sotto-attributi:
     Esempio: "Per la laurea di Manu camera all'Hotel della Cioccolata a Perugia" -> ("Manu" --[evento]--> "Laurea" --[idea regalo]--> "Camera Hotel della Cioccolata" --[luogo]--> "Perugia").
4. ENTITÀ COMPOSTE INTATTE: Non spezzare mai i nomi propri di prodotti, libri o luoghi (es. "Profumo Narciso Rodriguez" è un singolo nodo di tipo "oggetto", NON una persona di nome Rodriguez).
5. Rispondi ESCLUSIVAMENTE con un oggetto JSON valido con questa struttura:
{
  "entities": [
    {"name": "Nome Entità", "type": "persona | evento | categoria | oggetto | luogo | data | concetto"}
  ],
  "relations": [
    {"source": "Entità Origine", "predicate": "verbo o relazione", "target": "Entità Destinazione"}
  ]
}
''';

        DateTime oraAttuale = DateTime.now();
        String messaggio = "[Bridge] Estrazione grafo con qwen2.5:7b, ora attuale: "+ oraAttuale.toString();
        stdout.writeln(messaggio);
        final llmResp = await _callOllama({
          'model': 'qwen2.5:7b',
          'system': systemPrompt,
          'prompt': 'Testo della nota:\n"$fullText"',
          'stream': false,
          'format': 'json',
        });

        final Map<String, dynamic> graphJson =
            jsonDecode(llmResp['response'] ?? '{"entities":[],"relations":[]}');

        final embedResp = await _callOllamaEndpoint('/api/embeddings', {
          'model': 'nomic-embed-text',
          'prompt': fullText,
        });

        final responsePayload = jsonEncode({
          'entities': graphJson['entities'] ?? [],
          'relations': graphJson['relations'] ?? [],
          'embedding': embedResp['embedding'] ?? [],
          'image_extracted_text': imageContext,
        });

        request.response
          ..statusCode = HttpStatus.ok
          ..headers.contentType = ContentType.json
          ..write(responsePayload);
      } catch (e) {
        stdout.writeln('[Errore Bridge]: $e');
        request.response
          ..statusCode = HttpStatus.internalServerError
          ..headers.contentType = ContentType.json
          ..write(jsonEncode({'error': e.toString()}));
      } finally {
        await request.response.close();
      }
    } else {
      request.response.statusCode = HttpStatus.notFound;
      await request.response.close();
    }
  }
}

Future<Map<String, dynamic>> _callOllama(Map<String, dynamic> payload) async {
  return _callOllamaEndpoint('/api/generate', payload);
}

Future<Map<String, dynamic>> _callOllamaEndpoint(
    String path, Map<String, dynamic> payload) async {
  final client = HttpClient();
  final req = await client.postUrl(Uri.parse('http://127.0.0.1:11434$path'));
  req.headers.contentType = ContentType.json;
  req.write(jsonEncode(payload));
  final resp = await req.close();
  final body = await utf8.decoder.bind(resp).join();
  client.close();
  return jsonDecode(body) as Map<String, dynamic>;
}