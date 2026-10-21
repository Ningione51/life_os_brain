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
    'mio', 'mia', 'miei', 'mie', 'tuo', 'tua'
  };

  // Parole troppo generiche che da sole NON devono mai collegare due persone diverse
  static const Set<String> _genericLinkBlockers = {
    'nat', 'ann', 'giorn', 'mes', 'or', 'volt', 'cos', 'vit', 'cas', 'not',
    'fot', 'immagin', 'audi', 'vocal', 'marz', 'april', 'maggi', 'giugn',
    'lugli', 'agost', 'settembr', 'ottobr', 'novembr', 'dicembr', 'gennai', 'febbrai'
  };

  // Domini concettuali per capire il significato delle frasi e delle ricerche
  static const Map<String, List<String>> _semanticDomains = {
    'Compleanno / Nascita': [
      'compleann', 'nat', 'nascit', 'fest', 'ann', 'età', 'gennai', 'febbrai',
      'marz', 'april', 'maggi', 'giugn', 'lugli', 'agost', 'settembr', 'ottobr',
      'novembr', 'dicembr'
    ],
    'Gusti / Regali': [
      'piac', 'ador', 'am', 'prefer', 'gust', 'passion', 'ghiott', 'regal',
      'desider', 'kindle', 'cioccolat', 'libr', 'film', 'music'
    ],
    'Cibo / Spesa': [
      'mangi', 'cib', 'piatt', 'cioccolat', 'pizz', 'ristorant', 'spes',
      'compr', 'supermercat', 'latt', 'biscott', 'ricett', 'cen', 'pranz'
    ],
    'Lavoro / Studio': [
      'lavor', 'uffi', 'progett', 'aziend', 'carrier', 'esam', 'studi',
      'universit', 'lezion', 'appunt', 'riunion', 'scadenz'
    ],
    'Sport / Salute': [
      'allenament', 'cors', 'palestr', 'sport', 'chilometr', 'salut', 'medic',
      'visit', 'peso', 'dieta', 'esercizi'
    ],
    'Posizione / Coordinate': [
      'coordinat', 'posizion', 'luog', 'minecraft', 'villaggi', 'bas',
      'diamant', 'mapp', 'indirizz', 'viaggi', 'hotel'
    ],
  };

  /// Rimuove i marcatori tecnici di file ([[IMG:...]], [[AUDIO:...]])
  static String stripMediaMarkers(String rawContent) {
    return rawContent
        .replaceAll(RegExp(r'\[\[IMG:[^\]]+\]\]'), '')
        .replaceAll(RegExp(r'\[\[AUDIO:[^\]]+\]\]'), '')
        .trim();
  }

  /// Estrae i Soggetti (#Tag, Persone come "Manu", "Io", o Categorie principali)
  static List<String> extractEntities(String rawText) {
    final text = stripMediaMarkers(rawText);
    if (text.isEmpty) return [];

    final entities = <String>{};
    final lowerText = text.toLowerCase();

    // 1. Estrae #Tag espliciti scritti dall'utente o dalla Vision AI
    final hashtagMatches = RegExp(r'#([a-zA-Z0-9àèéìòùÀÈÉÌÒÙ_]+)').allMatches(text);
    for (final m in hashtagMatches) {
      final tag = m.group(1);
      if (tag != null && tag.length >= 2) {
        entities.add(_capitalize(tag));
      }
    }

    // 2. Rileva se il soggetto della nota sei TU ("io", "mio", "sono nato", "ho fatto")
    if (RegExp(r'\b(io|mio|mia|miei|mie|me)\b').hasMatch(lowerText) ||
        RegExp(r'\b(sono|ho)\s+(nato|nata|andato|andata|fatto|visto|comprato|preso)\b')
            .hasMatch(lowerText)) {
      entities.add('Io');
    }

    // 3. Rileva Nomi Propri di Persona o Entità (parole con iniziale Maiuscola)
    final commonStartWords = {
      'oggi', 'ieri', 'domani', 'quando', 'sempre', 'forse', 'nota', 'alla',
      'della', 'nella', 'sulla', 'dallo', 'dalla', 'un', 'una', 'il', 'lo',
      'la', 'le', 'gli', 'scena', 'dettagli', 'testo', 'immagine', 'foto',
      'documento', 'schermata', 'registrazione', 'memoria'
    };

    final sentences = text.split(RegExp(r'[.!?\n]+'));
    for (final s in sentences) {
      final words = s.trim().split(RegExp(r'\s+'));
      for (int i = 0; i < words.length; i++) {
        if (words[i].startsWith('#')) continue;
        final clean = words[i].replaceAll(RegExp(r'[^\wàèéìòùÀÈÉÌÒÙ]'), '');
        if (clean.length < 3) continue;

        final lower = clean.toLowerCase();
        if (_stopWords.contains(lower) || commonStartWords.contains(lower)) continue;

        final bool isCap = clean[0] == clean[0].toUpperCase() &&
            clean[0] != clean[0].toLowerCase();

        if (isCap && i > 0) {
          // Maiuscola nel mezzo della frase -> quasi certamente Nome Proprio (es. "della Manu", "a Luca")
          entities.add(_capitalize(lower));
        } else if (isCap && i == 0 && words.length > 1) {
          entities.add(_capitalize(lower));
        }
      }
    }

    // 4. Se non c'è una persona specifica, assegna il tema semantico principale se presente
    if (entities.isEmpty) {
      final tokens = tokenize(text, forLinking: false);
      for (final entry in _semanticDomains.entries) {
        final domainName = entry.key.split('/').first.trim();
        final keywords = entry.value;
        if (tokens.any((t) => keywords.any((k) => t.startsWith(k) || k.startsWith(t)))) {
          entities.add(domainName);
          break;
        }
      }
    }

    return entities.take(5).toList();
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
      // Nel linking tra note ignora i numeri puri (così 2003 e 2004 non creano falsi link)
      if (forLinking && RegExp(r'^\d+$').hasMatch(w)) continue;

      final stemmed = _stem(w);
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

  /// Decide se due note hanno davvero senso collegate insieme
  static double computeNoteLinkScore(String contentA, String contentB) {
    final entitiesA = extractEntities(contentA).map((e) => e.toLowerCase()).toSet();
    final entitiesB = extractEntities(contentB).map((e) => e.toLowerCase()).toSet();

    final sharedEntities = entitiesA.intersection(entitiesB);

    // Se parlano di due soggetti diversi (es. "Manu" vs "Io") e non hanno soggetti in comune:
    final bool hasDifferentSubjects =
        entitiesA.isNotEmpty && entitiesB.isNotEmpty && sharedEntities.isEmpty;

    final tokensA = tokenize(contentA, forLinking: true).toSet();
    final tokensB = tokenize(contentB, forLinking: true).toSet();
    final sharedConcepts = tokensA.intersection(tokensB);

    // Blocca i falsi positivi: se i soggetti sono diversi e non hanno almeno 2 concetti specifici in comune, 0!
    if (hasDifferentSubjects && sharedConcepts.length < 2) {
      return 0.0;
    }

    // Se condividono lo stesso Soggetto (es. entrambe parlano di #Manu), il collegamento è fortissimo e sensato!
    if (sharedEntities.isNotEmpty) {
      return (0.65 + 0.15 * sharedEntities.length).clamp(0.0, 0.98);
    }

    final vecA = generateSimpleVector(contentA);
    final vecB = generateSimpleVector(contentB);
    double sim = cosineSimilarity(vecA, vecB);

    if (sharedConcepts.isNotEmpty) {
      sim += 0.18 * sharedConcepts.length;
    }

    if (hasDifferentSubjects) {
      sim *= 0.35;
    }

    return sim.clamp(0.0, 1.0);
  }

  /// Ricerca Semantica Intelligente: capisce domande naturali, date, compleanni, gusti e soggetti
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

    // 1. Espansione concettuale: capisce se stai cercando una data/compleanno, un gusto/regalo, ecc.
    final expandedTerms = <String>{...qTokens};
    bool asksForDateOrBirthday = false;

    for (final entry in _semanticDomains.entries) {
      final domainKeywords = entry.value;
      if (qTokens.any((qt) => domainKeywords.any((dk) => qt.startsWith(dk) || dk.startsWith(qt)))) {
        expandedTerms.addAll(domainKeywords);
        if (entry.key.contains('Compleanno')) {
          asksForDateOrBirthday = true;
        }
      }
    }

    // Se la query chiede "compleanno" o "quando è nato/a", controlla se nella nota c'è una data numerica (es. 4/12/2004)
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

      // Match diretto di sottostringa
      if (sLower.contains(lowerQuery)) {
        score += 0.9;
      }

      // Match sui token della query ed espansioni semantiche
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
        if (!matchedThis) {
          // Controlla se la frase contiene un concetto affine del dominio (es. cerchi "compleanno" e trova "nato il 4/12/2004")
          if (sTokens.any((st) => expandedTerms.any((et) => st.startsWith(et) || et.startsWith(st)))) {
            score += 0.45;
            matchedThis = true;
          }
        }
        if (matchedThis) matchedQueryRoots++;
      }

      if (qTokens.isNotEmpty) {
        score = (score + (matchedQueryRoots / qTokens.length) * 0.5);
      }

      // Bonus se chiedi "compleanno / quando è nato" e la frase contiene una data + "nato/a"
      if (asksForDateOrBirthday && noteHasDatePattern) {
        score += 0.45;
      }

      // Se nella domanda hai specificato una persona (es. "Manu"), premia le note su Manu e penalizza le altre!
      if (qEntities.isNotEmpty) {
        if (docEntities.intersection(qEntities).isNotEmpty) {
          score += 0.4;
        } else {
          score *= 0.35;
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