import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:http/http.dart' as http;

import 'podcast_service.dart';

class GeminiService {
  static const _model = 'gemini-2.5-flash';

  static String get _apiKey => dotenv.env['GEMINI_API_KEY']!;
  static String get _url =>
      'https://generativelanguage.googleapis.com/v1beta/models/$_model:generateContent?key=$_apiKey';

  /// Cache : clé = "categorie::niveau". Un même sujet suggéré pour
  /// "Histoire/Vulgarisation" et "Histoire/Pointu" sont distincts car
  /// l'angle, le vocabulaire et l'ambition du titre diffèrent.
  static final Map<String, List<String>> _cache = {};

  static String _cacheKey(String categorie, NiveauEditorial niveau) =>
      '$categorie::${niveau.name}';

  /// Force un refresh. Si [categorie] est fourni, invalide toutes les
  /// entrées pour cette catégorie (tous niveaux confondus). Sinon vide tout.
  static void invalidateCache({String? categorie}) {
    if (categorie == null) {
      _cache.clear();
    } else {
      _cache.removeWhere((k, _) => k.startsWith('$categorie::'));
    }
  }

  /// Génère 6 suggestions de sujets adaptées à la catégorie ET au niveau.
  /// La 6e est utilisée comme "Surprise" côté UI ; les 5 premières sont
  /// affichées.
  ///
  /// [excludeSubjects] : liste de sujets déjà écoutés à NE PAS re-proposer.
  /// Si non vide, le cache est bypassé (les exclusions changent à chaque appel).
  ///
  /// [forceRefresh] : ignore le cache, force un nouveau call Gemini. Utile
  /// pour le bouton "Rafraîchir".
  static Future<List<String>> genererSuggestions(
    String categorie, {
    NiveauEditorial niveau = NiveauEditorial.standard,
    List<String> excludeSubjects = const [],
    bool forceRefresh = false,
  }) async {
    final key = _cacheKey(categorie, niveau);
    // Le cache est utilisé uniquement quand il n'y a rien à exclure ET
    // qu'on ne force pas le refresh. Sinon on appelle toujours Gemini :
    // les exclusions et le force-refresh sont par définition incompatibles
    // avec un cache stable.
    if (excludeSubjects.isEmpty && !forceRefresh) {
      final cached = _cache[key];
      if (cached != null) {
        debugPrint('💡 Suggestions "$key" : cache hit');
        return cached;
      }
    }

    final t0 = DateTime.now();
    debugPrint(
        '💡 Suggestions "$key" : appel Gemini'
        '${excludeSubjects.isNotEmpty ? " (exclude=${excludeSubjects.length})" : ""}'
        '${forceRefresh ? " (refresh)" : ""}...');

    final prompt = _buildSuggestionPrompt(categorie, niveau, excludeSubjects);

    try {
      final response = await http.post(
        Uri.parse(_url),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'contents': [
            {'parts': [{'text': prompt}]}
          ],
          'generationConfig': {
            // Temperature plus haute pour varier les suggestions entre
            // deux appels (évite que Vulgarisation/Standard/Pointu proposent
            // le même genre de sujet, même sur des prompts différents)
            'temperature': 1.0,
            'maxOutputTokens': 400,
            'thinkingConfig': {'thinkingBudget': 0},
          },
        }),
      );

      if (response.statusCode != 200) {
        debugPrint('❌ Suggestions HTTP ${response.statusCode}');
        return _fallback(categorie);
      }

      final data = jsonDecode(response.body);
      final parts = data['candidates']?[0]?['content']?['parts'] as List?;
      if (parts == null || parts.isEmpty) {
        debugPrint('❌ Suggestions : pas de parts dans la réponse');
        return _fallback(categorie);
      }
      final rawText = parts[0]['text'] as String;

      final clean = rawText
          .trim()
          .replaceAll('```json', '')
          .replaceAll('```', '')
          .trim();

      final liste = List<String>.from(jsonDecode(clean))
          .map((s) => s.toString().trim())
          .where((s) => s.isNotEmpty)
          .toList();

      final dt = DateTime.now().difference(t0).inMilliseconds;
      debugPrint(
          '✅ Suggestions "$key" : ${liste.length} items en ${dt}ms');

      if (liste.isEmpty) return _fallback(categorie);

      // On ne met en cache que les résultats "purs" (sans exclusion ni
      // refresh forcé) — sinon le cache deviendrait incohérent avec le
      // contexte de l'appel.
      if (excludeSubjects.isEmpty && !forceRefresh) {
        _cache[key] = liste;
      }
      return liste;
    } catch (e) {
      debugPrint('❌ Erreur suggestions : $e');
      return _fallback(categorie);
    }
  }

  static String _buildSuggestionPrompt(
    String categorie,
    NiveauEditorial niveau,
    List<String> excludeSubjects,
  ) {
    // Suffixe d'exclusion : injecté UNIQUEMENT si la liste n'est pas vide.
    // On limite à 30 sujets pour ne pas faire exploser le prompt sur un
    // utilisateur très assidu (~30 sujets suffisent à forcer la diversité,
    // au-delà Gemini va de toute façon devoir explorer ailleurs).
    String exclusionSuffix = '';
    if (excludeSubjects.isNotEmpty) {
      final sample = excludeSubjects.length > 30
          ? excludeSubjects.sublist(excludeSubjects.length - 30)
          : excludeSubjects;
      final liste = sample.map((s) => '- "$s"').join('\n');
      exclusionSuffix = '''

L'utilisateur a déjà écouté les sujets suivants — propose des sujets DIFFÉRENTS, sur d'autres époques, courants ou angles :
$liste''';
    }

    switch (niveau) {
      case NiveauEditorial.vulgarisation:
        return '''
6 sujets de podcast accessible sur "$categorie", pour un public curieux mais non spécialiste.

Critères :
- Entrée concrète, quotidien, anecdote — angle très engageant type France Inter / Brut
- Titres accrocheurs, 5 à 9 mots, questions ou formules parlantes
- En français
- Pas de jargon technique dans les titres
- Les 6 sujets doivent être distincts les uns des autres

Exemples de ton : "Pourquoi le lundi existe-t-il ?", "Les dessous du prix du café", "Ces virus qui ont changé l'Histoire".$exclusionSuffix

Retourne UNIQUEMENT un JSON array de 6 strings, rien d'autre.''';

      case NiveauEditorial.standard:
        return '''
6 sujets de podcast sur "$categorie", pour un public cultivé type auditeur France Culture.

Critères :
- Angle original ou contre-intuitif, avec une vraie densité
- Titres de 6 à 10 mots, style titre du Monde / Le Point
- En français
- Sujets qui stimulent sans être austères
- Les 6 sujets doivent être distincts les uns des autres

Exemples de ton : "La doctrine Monroe, matrice de l'empire américain", "Keynes contre Hayek : un siècle de querelle", "Quand Rome a inventé la finance".$exclusionSuffix

Retourne UNIQUEMENT un JSON array de 6 strings, rien d'autre.''';

      case NiveauEditorial.pointu:
        return '''
6 sujets de podcast pour "$categorie", niveau grande école (Sciences Po, ENA, HEC).

Critères :
- Densité conceptuelle, angle académique ou controverse historiographique
- Titres de 7 à 12 mots, style titre d'article du Monde diplomatique ou d'une revue type Esprit / Commentaire
- En français
- On peut citer des concepts, auteurs, doctrines si pertinent
- Les 6 sujets doivent être distincts les uns des autres

Exemples de ton : "L'école de Francfort et la dialectique de la raison", "L'hystérésis monétaire selon Blanchard", "Clausewitz relu par Aron : penser la guerre froide".$exclusionSuffix

Retourne UNIQUEMENT un JSON array de 6 strings, rien d'autre.''';
    }
  }

  /// Sujets de secours si Gemini échoue ou retourne quelque chose
  /// d'inexploitable — évite un écran vide côté user.
  static List<String> _fallback(String categorie) {
    return [
      'Saisis ton propre sujet sur "$categorie"',
    ];
  }
}
