import 'dart:convert';
import 'dart:math';

class SimilarityEngine {
  static const Set<String> _stopWords = {
    'il', 'lo', 'la', 'i', 'gli', 'le', 'un', 'uno', 'una', 'di', 'a', 'da',
    'in', 'con', 'su', 'per', 'tra', 'fra', 'al', 'allo', 'alla', 'ai', 'agli',
    'alle', 'dal', 'dallo', 'dalla', 'nel', 'nella', 'sul', 'sulla', 'che',
    'chi', 'cosa', 'come', 'dove', 'quando', 'perche', 'perché', 'quale',
    'quali', 'quanto', 'sono', 'sei', 'è', 'e', 'ed', 'o', 'ma', 'se', 'non',
    'ti', 'si', 'ci', 'vi', 'hai', 'ha', 'abbiamo', 'hanno', 'del', 'della',
    'dei', 'degli', 'delle', 'questo', 'questa', 'quello', 'quella', 'molto',
    'poco', 'più', 'meno', 'anche', 'solo', 'fare', 'fatto', 'dire', 'detto',
    'stato', 'stata', 'essere', 'avere', 'suo', 'sua', 'suoi', 'sue'
  };

  static const Map<String, String> _numberWords = {
    'zero': '0', 'uno': '1', 'due': '2', 'tre': '3', 'quattro': '4',
    'cinque': '5', 'sei': '6', 'sette': '7', 'otto': '8', 'nove': '9',
    'dieci': '10', 'undici': '11', 'dodici': '12', 'tredici': '13',
    'quattordici': '14', 'quindici': '15', 'sedici': '16', 'diciassette': '17',
    'diciotto': '18', 'diciannove': '19', 'venti': '20', 'duemila': '2000'
  };

  /// Normalizza qualsiasi testo convertendo numeri in cifre e uniformando maiuscole/minuscole
  static String normalizeText(String text) {
    var lower = text.toLowerCase();
    _numberWords.forEach((word, digit) {
      lower = lower.replaceAll(RegExp(r'\b' + word + r'\b'), digit);
    });
    return lower;
  }

  /// Estrae Soggetti / Entità indipendentemente da maiuscole/minuscole o formati
  static List<String> extractEntities(String text) {
    final entities = <String>{};
    final normalized = normalizeText(text);

    if (RegExp(r'\b(io|mio|mia|miei|mie|me|nato|nata)\b').hasMatch(normalized)) {
      entities.add('Io');
    }

    // Rileva nomi propri o soggetti indipendentemente dal maiuscolo/minuscolo iniziale
    final words = text.split(RegExp(r'[^\wàèéìòùÀÈÉÌÒÙ]+'));
    for (int i = 0; i < words.length; i++) {
      final w = words[i];
      if (w.length < 3) continue;
      final lower = w.toLowerCase();
      if (_stopWords.contains(lower) || lower == 'io' || lower == 'mio') continue;

      // Se è un nome proprio comune o scritto con maiuscola o menzionato dopo preposizioni (es. "di manu", "con giulia")
      bool isCap = w[0] == w[0].toUpperCase() && w[0] != w[0].toLowerCase();
      if (isCap || (i > 0 && ['di', 'a', 'da', 'in', 'con', 'su', 'per', 'alla', 'della', 'caro', 'cara'].contains(words[i - 1].toLowerCase()))) {
        entities.add(_capitalize(lower));
      }
    }

    return entities.toList();
  }

  static String _capitalize(String s) =>
      s.isEmpty ? s : '${s[0].toUpperCase()}${s.substring(1).toLowerCase()}';

  static List<String> tokenize(String text, {bool forLinking = false}) {
    final normalized = normalizeText(text);
    final cleaned = normalized.replaceAll(RegExp(r'[^\w\sàèéìòù]'), ' ');

    final tokens = <String>[];
    for (final w in cleaned.split(RegExp(r'\s+'))) {
      if (w.length < 2 || _stopWords.contains(w)) continue;
      final stemmed = _stem(w);
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

  static List<double> generateSimpleVector(String text) {
    final vec = List<double>.filled(128, 0.0);
    final tokens = tokenize(text, forLinking: true);

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

  /// Calcola l'affinità e previene falsi collegamenti tra soggetti differenti (es. Io vs Manu)
  static double computeNoteLinkScore(String contentA, String contentB) {
    final entitiesA = extractEntities(contentA).map((e) => e.toLowerCase()).toSet();
    final entitiesB = extractEntities(contentB).map((e) => e.toLowerCase()).toSet();

    final sharedEntities = entitiesA.intersection(entitiesB);
    final bool hasDifferentSubjects =
        entitiesA.isNotEmpty && entitiesB.isNotEmpty && sharedEntities.isEmpty;

    final tokensA = tokenize(contentA, forLinking: true).toSet();
    final tokensB = tokenize(contentB, forLinking: true).toSet();
    final sharedConcepts = tokensA.intersection(tokensB);

    if (hasDifferentSubjects && sharedConcepts.length < 2) {
      return 0.0;
    }

    final vecA = generateSimpleVector(contentA);
    final vecB = generateSimpleVector(contentB);
    double sim = cosineSimilarity(vecA, vecB);

    if (sharedEntities.isNotEmpty) {
      sim = max(sim, 0.45) + (0.25 * sharedEntities.length);
    }

    if (hasDifferentSubjects) {
      sim *= 0.35;
    }

    return sim.clamp(0.0, 1.0);
  }

  static Map<String, dynamic> queryDocument(String query, String content, String? vectorJson) {
    if (query.trim().isEmpty) {
      return {'score': 1.0, 'snippet': null};
    }

    final normalizedQuery = normalizeText(query);
    final qTokens = tokenize(normalizedQuery, forLinking: false);
    if (qTokens.isEmpty) {
      final contains = content.toLowerCase().contains(normalizedQuery);
      return {'score': contains ? 1.0 : 0.0, 'snippet': content};
    }

    final sentences = content
        .split(RegExp(r'(?<=[.!?])\s+|\n+'))
        .where((s) => s.trim().isNotEmpty)
        .toList();

    double bestSentenceScore = 0.0;
    String? bestSnippet;

    for (final sentence in sentences) {
      final normSentence = normalizeText(sentence);
      final sTokens = tokenize(normSentence, forLinking: false);
      if (sTokens.isEmpty) continue;

      int matchedQueryTerms = 0;
      double accumulatedWeight = 0.0;

      for (final qt in qTokens) {
        double bestMatchForTerm = 0.0;
        for (final st in sTokens) {
          if (st == qt || st.startsWith(qt) || qt.startsWith(st)) {
            bestMatchForTerm = max(bestMatchForTerm, 1.0);
          }
        }
        if (bestMatchForTerm > 0) {
          matchedQueryTerms++;
          accumulatedWeight += bestMatchForTerm;
        }
      }

      if (matchedQueryTerms > 0) {
        final double coverage = accumulatedWeight / qTokens.length;
        if (coverage > bestSentenceScore) {
          bestSentenceScore = coverage;
          bestSnippet = sentence.trim();
        }
      }
    }

    return {
      'score': bestSentenceScore.clamp(0.0, 1.0),
      'snippet': bestSentenceScore >= 0.2 ? bestSnippet : null,
    };
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