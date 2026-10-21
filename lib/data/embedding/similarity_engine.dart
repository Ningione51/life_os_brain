import 'dart:convert';
import 'dart:math';

class SimilarityEngine {
  static const Set<String> _stopWords = {
    'il', 'lo', 'la', 'i', 'gli', 'le', 'un', 'uno', 'una', 'di', 'a', 'da',
    'in', 'con', 'su', 'per', 'tra', 'fra', 'al', 'allo', 'alla', 'ai', 'agli',
    'alle', 'dal', 'dallo', 'dalla', 'nel', 'nella', 'sul', 'sulla', 'che',
    'chi', 'cosa', 'come', 'dove', 'quando', 'perche', 'perché', 'quale',
    'quali', 'quanto', 'sono', 'sei', 'è', 'e', 'ed', 'o', 'ma', 'se', 'non',
    'mi', 'ti', 'si', 'ci', 'vi', 'ho', 'hai', 'ha', 'abbiamo', 'hanno', 'del',
    'della', 'dei', 'degli', 'delle', 'questo', 'questa', 'quello', 'quella',
    'molto', 'poco', 'più', 'meno', 'anche', 'solo', 'fare', 'fatto', 'dire',
    'detto', 'stato', 'stata', 'essere', 'avere', 'suo', 'sua', 'suoi', 'sue',
    'mio', 'mia', 'miei', 'mie', 'tuo', 'tua', 'piace', 'piacciono', 'nato', 'nata'
  };

  // Mappa sinonimi/diminutivi -> Nome Canonico Unificato
  static const Map<String, String> _personAliases = {
    'manu': 'Manu',
    'manuela': 'Manu',
    'emanuela': 'Manu',
    'paolo': 'Paolo',
    'luca': 'Luca',
    'marco': 'Marco',
    'giulia': 'Giulia',
    'sara': 'Sara',
    'ale': 'Ale',
    'alessandro': 'Ale',
    'alessandra': 'Ale',
    'fra': 'Fra',
    'francesco': 'Fra',
    'francesca': 'Fra',
    'mamma': 'Mamma',
    'papà': 'Papà',
    'papa': 'Papà',
  };

  static const Set<String> _genericLinkBlockers = {
    'nat', 'ann', 'giorn', 'mes', 'or', 'volt', 'cos', 'vit', 'cas', 'not',
    'fot', 'immagin', 'audi', 'vocal', 'marz', 'april', 'maggi', 'giugn',
    'lugli', 'agost', 'settembr', 'ottobr', 'novembr', 'dicembr', 'gennai', 'febbrai'
  };

  static const Map<String, List<String>> _semanticDomains = {
    'Compleanno': [
      'compleann', 'nat', 'nascit', 'fest', 'età', 'gennai', 'febbrai',
      'marz', 'april', 'maggi', 'giugn', 'lugli', 'agost', 'settembr', 'ottobr',
      'novembr', 'dicembr'
    ],
    'Gusti': [
      'piac', 'ador', 'am', 'prefer', 'gust', 'passion', 'ghiott', 'regal',
      'desider', 'kindle', 'cioccolat', 'libr', 'film', 'music'
    ],
    'Spesa': [
      'mangi', 'cib', 'piatt', 'pizz', 'ristorant', 'spes',
      'compr', 'supermercat', 'latt', 'biscott', 'ricett', 'cen', 'pranz'
    ],
    'Lavoro': [
      'lavor', 'uffi', 'progett', 'aziend', 'carrier', 'esam', 'studi',
      'universit', 'lezion', 'appunt', 'riunion', 'scadenz'
    ],
    'Coordinate': [
      'coordinat', 'posizion', 'luog', 'minecraft', 'villaggi', 'bas',
      'diamant', 'mapp', 'indirizz', 'viaggi'
    ],
  };

  static String stripMediaMarkers(String rawContent) {
    return rawContent
        .replaceAll(RegExp(r'\[\[IMG:[^\]]+\]\]'), '')
        .replaceAll(RegExp(r'\[\[AUDIO:[^\]]+\]\]'), '')
        .trim();
  }

  /// Estrae Soggetti (Persone anche scritte in minuscolo come "la manu", #Tag e Temi)
  static List<String> extractEntities(String rawText) {
    final text = stripMediaMarkers(rawText);
    if (text.isEmpty) return [];

    final entities = <String>{};
    final lowerText = text.toLowerCase();

    // 1. Estrae #Tag espliciti
    final hashtagMatches = RegExp(r'#([a-zA-Z0-9àèéìòùÀÈÉÌÒÙ_]+)').allMatches(text);
    for (final m in hashtagMatches) {
      final tag = m.group(1);
      if (tag != null && tag.length >= 2) {
        final lowerTag = tag.toLowerCase();
        entities.add(_personAliases[lowerTag] ?? _capitalize(tag));
      }
    }

    // 2. Rileva se il soggetto sei TU ("io", "mio", "sono nato")
    if (RegExp(r'\b(io|mio|mia|miei|mie|me)\b').hasMatch(lowerText) ||
        RegExp(r'\b(sono|ho)\s+(nato|nata|andato|andata|fatto|comprato)\b').hasMatch(lowerText)) {
      entities.add('Io');
    }

    // 3. Rileva Persone dal dizionario alias anche se scritte in minuscolo ("manu", "manuela", ecc.)
    for (final entry in _personAliases.entries) {
      if (RegExp('\\b${entry.key}\\b', caseSensitive: false).hasMatch(lowerText)) {
        entities.add(entry.value);
      }
    }

    // 4. Pattern grammaticali italiani per persone scritte in minuscolo:
    // es: "la manu è", "alla manu piace", "per manu", "con luca", "di giulia"
    final personPatterns = [
      RegExp(r'\b(?:alla|della|la|il|a|per|con|da)\s+([a-zàèéìòù]{3,12})\s+(?:è|piace|piacciono|ama|adora|vuole|compie|ha)\b', caseSensitive: false),
      RegExp(r'\b(?:compleanno|regalo)\s+(?:di|della|del|per)\s+([a-zàèéìòù]{3,12})\b', caseSensitive: false),
    ];
    for (final pat in personPatterns) {
      for (final match in pat.allMatches(lowerText)) {
        final candidate = match.group(1)?.toLowerCase();
        if (candidate != null && !_stopWords.contains(candidate)) {
          entities.add(_personAliases[candidate] ?? _capitalize(candidate));
        }
      }
    }

    // 5. Rileva Nomi Propri con l'iniziale Maiuscola nel testo
    final ignoreCapitals = {
      'oggi', 'ieri', 'domani', 'quando', 'sempre', 'forse', 'nota', 'alla',
      'della', 'nella', 'sulla', 'un', 'una', 'il', 'lo', 'la', 'le', 'gli',
      'scena', 'dettagli', 'testo', 'immagine', 'foto', 'documento', 'vision',
      'analisi', 'elementi', 'oggetto'
    };

    final sentences = text.split(RegExp(r'[.!?\n]+'));
    for (final s in sentences) {
      final words = s.trim().split(RegExp(r'\s+'));
      for (int i = 0; i < words.length; i++) {
        if (words[i].startsWith('#')) continue;
        final clean = words[i].replaceAll(RegExp(r'[^\wàèéìòùÀÈÉÌÒÙ]'), '');
        if (clean.length < 3) continue;

        final lower = clean.toLowerCase();
        if (_stopWords.contains(lower) || ignoreCapitals.contains(lower)) continue;

        final bool isCap = clean[0] == clean[0].toUpperCase() &&
            clean[0] != clean[0].toLowerCase();

        if (isCap) {
          entities.add(_personAliases[lower] ?? _capitalize(lower));
        }
      }
    }

    // 6. Aggiunge anche il Dominio Semantico (es. #Compleanno, #Gusti) SENZA sovrascrivere la Persona!
    final tokens = tokenize(text, forLinking: false);
    for (final entry in _semanticDomains.entries) {
      final domainName = entry.key;
      final keywords = entry.value;
      if (tokens.any((t) => keywords.any((k) => t.startsWith(k) || k.startsWith(t)))) {
        entities.add(domainName);
      }
    }

    // Rimuove eventuali tag di rumore generati da vecchie scansioni
    entities.removeWhere((e) => e.toLowerCase() == 'vision');

    return entities.take(6).toList();
  }

  static String _capitalize(String s) =>
      s.isEmpty ? s : '${s[0].toUpperCase()}${s.substring(1).toLowerCase()}';

  static List<String> tokenize(String rawText, {bool forLinking = false}) {
    final text = stripMediaMarkers(rawText);
    final cleaned = text
        .toLowerCase()
        .replaceAll(RegExp(r"['’]"), ' ')
        .replaceAll(RegExp(r'[^\w\sàèéìòù]'), ' ');

    final tokens = <String>[];
    for (final w in cleaned.split(RegExp(r'\s+'))) {
      if (w.length < 2 || _stopWords.contains(w)) continue;
      if (forLinking && RegExp(r'^\d+$').hasMatch(w)) continue;

      // Normalizza alias (es. "manuela" -> "manu")
      final canonical = _personAliases[w]?.toLowerCase() ?? w;
      final stemmed = _stem(canonical);
      if (forLinking && _genericLinkBlockers.contains(stemmed)) continue;
      tokens.add(stemmed);
    }
    return tokens;
  }

  static String _stem(String w) {
    if (w.length <= 3) return w;
    for (final s in [
      'zioni', 'zione', 'mente', 'avano', 'evano', 'ivano', 'iamo',
      'ano', 'ono', 'are', 'ere', 'ire', 'ato', 'uto', 'ito', 'ata', 'ite'
    ]) {
      if (w.endsWith(s) && w.length - s.length >= 3) {
        return w.substring(0, w.length - s.length);
      }
    }
    if (RegExp(r'[aeiouàèéìòù]$').hasMatch(w) && w.length > 3) {
      return w.substring(0, w.length - 1);
    }
    return w;
  }

  static List<double> generateSimpleVector(String rawText) {
    final vec = List<double>.filled(128, 0.0);
    final tokens = tokenize(rawText, forLinking: true);

    for (final t in tokens) {
      vec[t.hashCode.abs() % 128] += 2.5;
      for (int i = 0; i <= t.length - 3; i++) {
        final tri = t.substring(i, i + 3);
        vec[tri.hashCode.abs() % 128] += 0.6;
      }
    }

    double norm = sqrt(vec.fold(0.0, (sum, v) => sum + v * v));
    if (norm > 0) {
      for (int i = 0; i < vec.length; i++) {
        vec[i] /= norm;
      }
    }
    return vec;
  }

  /// Collega automaticamente due note se parlano della stessa Persona/Soggetto o dello stesso Argomento specifico
  static double computeNoteLinkScore(String contentA, String contentB) {
    final entitiesA = extractEntities(contentA).map((e) => e.toLowerCase()).toSet();
    final entitiesB = extractEntities(contentB).map((e) => e.toLowerCase()).toSet();

    // Separa le Persone/Soggetti dai Temi generici (#Compleanno, #Gusti)
    final domainNames = _semanticDomains.keys.map((k) => k.toLowerCase()).toSet();
    final subjectsA = entitiesA.difference(domainNames);
    final subjectsB = entitiesB.difference(domainNames);

    final sharedSubjects = subjectsA.intersection(subjectsB);

    // Se entrambe parlano della STESSA persona/oggetto (es. #Manu o #Walle), crea un link forte!
    if (sharedSubjects.isNotEmpty) {
      return (0.75 + 0.10 * sharedSubjects.length).clamp(0.0, 0.98);
    }

    // Se parlano di due persone diverse (es. #Manu vs #Io) senza soggetti in comune, blocca falsi link!
    if (subjectsA.isNotEmpty && subjectsB.isNotEmpty && sharedSubjects.isEmpty) {
      return 0.0;
    }

    final tokensA = tokenize(contentA, forLinking: true).toSet();
    final tokensB = tokenize(contentB, forLinking: true).toSet();
    final sharedConcepts = tokensA.intersection(tokensB);

    final vecA = generateSimpleVector(contentA);
    final vecB = generateSimpleVector(contentB);
    double sim = cosineSimilarity(vecA, vecB);

    if (sharedConcepts.isNotEmpty) {
      sim += 0.18 * sharedConcepts.length;
    }

    return sim.clamp(0.0, 1.0);
  }

  static Map<String, dynamic> queryDocument(String query, String rawContent, String? vectorJson) {
    final content = stripMediaMarkers(rawContent);
    if (query.trim().isEmpty) {
      return {'score': 1.0, 'snippet': null};
    }

    final lowerQuery = query.toLowerCase().trim();
    final lowerContent = content.toLowerCase();

    final qTokens = tokenize(query, forLinking: false);
    final qEntities = extractEntities(query).map((e) => e.toLowerCase()).toSet();
    final docEntities = extractEntities(content).map((e) => e.toLowerCase()).toSet();

    final expandedTerms = <String>{...qTokens};
    bool asksForDateOrBirthday = false;

    for (final entry in _semanticDomains.entries) {
      final domainKeywords = entry.value;
      if (qTokens.any((qt) => domainKeywords.any((dk) => qt.startsWith(dk) || dk.startsWith(qt)))) {
        expandedTerms.addAll(domainKeywords);
        if (entry.key == 'Compleanno') asksForDateOrBirthday = true;
      }
    }

    final bool noteHasDatePattern =
        RegExp(r'\b\d{1,2}[/-]\d{1,2}([/-]\d{2,4})?\b').hasMatch(lowerContent) ||
        RegExp(r'\b(19|20)\d{2}\b').hasMatch(lowerContent);

    final sentences = content
        .split(RegExp(r'(?<=[.!?])\s+|\n+'))
        .where((s) => s.trim().isNotEmpty)
        .toList();

    double bestSentenceScore = 0.0;
    String? bestSnippet;

    for (final sentence in sentences) {
      final sLower = sentence.toLowerCase();
      final sTokens = tokenize(sentence, forLinking: false);
      if (sTokens.isEmpty && !sLower.contains(lowerQuery)) continue;

      double score = 0.0;
      if (sLower.contains(lowerQuery)) score += 0.9;

      int matchedQueryRoots = 0;
      for (final qt in qTokens) {
        bool matchedThis = false;
        for (final st in sTokens) {
          if (st == qt || st.startsWith(qt) || qt.startsWith(st)) {
            score += 0.55;
            matchedThis = true;
            break;
          } else if (_diceCoefficient(qt, st) >= 0.68) {
            score += 0.4;
            matchedThis = true;
            break;
          }
        }
        if (!matchedThis &&
            sTokens.any((st) => expandedTerms.any((et) => st.startsWith(et) || et.startsWith(st)))) {
          score += 0.45;
          matchedThis = true;
        }
        if (matchedThis) matchedQueryRoots++;
      }

      if (qTokens.isNotEmpty) {
        score += (matchedQueryRoots / qTokens.length) * 0.5;
      }

      if (asksForDateOrBirthday && noteHasDatePattern) {
        score += 0.45;
      }

      if (qEntities.isNotEmpty) {
        if (docEntities.intersection(qEntities).isNotEmpty) {
          score += 0.45;
        } else {
          score *= 0.3;
        }
      }

      if (score > bestSentenceScore) {
        bestSentenceScore = score;
        bestSnippet = sentence.trim();
      }
    }

    final finalScore = bestSentenceScore.clamp(0.0, 1.0);
    return {
      'score': finalScore,
      'snippet': finalScore >= 0.22 ? (bestSnippet ?? content) : null,
    };
  }

  static double _diceCoefficient(String a, String b) {
    if (a == b) return 1.0;
    if (a.length < 2 || b.length < 2) return 0.0;
    final bigramsA = <String>{};
    for (int i = 0; i < a.length - 1; i++) {
      bigramsA.add(a.substring(i, i + 2));
    }
    int matches = 0;
    for (int i = 0; i < b.length - 1; i++) {
      if (bigramsA.contains(b.substring(i, i + 2))) matches++;
    }
    return (2.0 * matches) / ((a.length - 1) + (b.length - 1));
  }

  static double cosineSimilarity(List<double> v1, List<double> v2) {
    if (v1.length != v2.length || v1.isEmpty) return 0.0;
    double dot = 0.0, normA = 0.0, normB = 0.0;
    for (int i = 0; i < v1.length; i++) {
      dot += v1[i] * v2[i];
      normA += v1[i] * v1[i];
      normB += v2[i] * v2[i];
    }
    if (normA == 0.0 || normB == 0.0) return 0.0;
    return dot / (sqrt(normA) * sqrt(normB));
  }

  static String encodeVector(List<double> vector) => jsonEncode(vector);

  static List<double> decodeVector(String jsonStr) {
    final List<dynamic> decoded = jsonDecode(jsonStr);
    return decoded.map((e) => (e as num).toDouble()).toList();
  }
}