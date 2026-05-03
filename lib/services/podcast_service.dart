import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

// ─── Modèles ───────────────────────────────────────────

class Replique {
  final String voice;
  final String text;
  const Replique({required this.voice, required this.text});

  Map<String, dynamic> toJson() => {'voice': voice, 'text': text};
  factory Replique.fromJson(Map<String, dynamic> j) => Replique(
        voice: j['voice'] as String,
        text: j['text'] as String,
      );
}

class PlanBloc {
  final int numero;
  final String titre;
  final String description;
  const PlanBloc({
    required this.numero,
    required this.titre,
    required this.description,
  });

  Map<String, dynamic> toJson() => {
        'numero': numero,
        'titre': titre,
        'description': description,
      };
  factory PlanBloc.fromJson(Map<String, dynamic> j) => PlanBloc(
        numero: j['numero'] as int,
        titre: j['titre'] as String,
        description: j['description'] as String,
      );
}

/// État d'un chapitre dans le pipeline streaming
enum ChapterStatus { pending, generatingScript, generatingAudio, ready, error }

/// Niveau éditorial demandé au LLM pour générer les scripts.
/// Affecte le style de dialogue, le jargon, et la profondeur d'analyse.
enum NiveauEditorial { vulgarisation, standard, pointu }

class Chapter {
  final int index;
  final PlanBloc plan;
  ChapterStatus status;
  String? wavPath;
  List<Replique> script;
  String? errorMessage;

  Chapter({
    required this.index,
    required this.plan,
    this.status = ChapterStatus.pending,
    this.wavPath,
    List<Replique>? script,
    this.errorMessage,
  }) : script = script ?? [];

  Chapter copy() => Chapter(
        index: index,
        plan: plan,
        status: status,
        wavPath: wavPath,
        script: List.of(script),
        errorMessage: errorMessage,
      );

  Map<String, dynamic> toJson() => {
        'index': index,
        'plan': plan.toJson(),
        'status': status.name,
        'wavPath': wavPath,
        'script': script.map((r) => r.toJson()).toList(),
        'errorMessage': errorMessage,
      };

  factory Chapter.fromJson(Map<String, dynamic> j) => Chapter(
        index: j['index'] as int,
        plan: PlanBloc.fromJson(j['plan'] as Map<String, dynamic>),
        status: ChapterStatus.values.firstWhere(
          (s) => s.name == j['status'],
          orElse: () => ChapterStatus.pending,
        ),
        wavPath: j['wavPath'] as String?,
        script: (j['script'] as List)
            .map((e) => Replique.fromJson(e as Map<String, dynamic>))
            .toList(),
        errorMessage: j['errorMessage'] as String?,
      );
}

/// État global d'une session de génération, exposé via ValueNotifier
class PodcastSession {
  /// Identifiant unique de la session (stable entre runs, utilisé comme
  /// clé Hive pour l'historique). Généré à la création.
  final String id;
  final String sujet;
  final String? categorie; // Histoire, Économie, Droit, Science, ou null
  final NiveauEditorial niveau;
  final int dureeMin;
  final String titre;
  final DateTime createdAt;
  final List<Chapter> chapters;
  final Map<String, dynamic> fiche;
  final List<Map<String, dynamic>> qcm;
  final bool planReady;
  final bool allChaptersReady;
  final String? globalError;

  /// Index du dernier chapitre joué (0-based). Null = jamais ouvert.
  final int? lastChapterIdx;

  /// Position dans ce dernier chapitre (en millisecondes). Défaut 0.
  final int lastPositionMs;

  const PodcastSession({
    required this.id,
    required this.sujet,
    required this.categorie,
    required this.niveau,
    required this.dureeMin,
    required this.titre,
    required this.createdAt,
    required this.chapters,
    required this.fiche,
    required this.qcm,
    required this.planReady,
    required this.allChaptersReady,
    this.globalError,
    this.lastChapterIdx,
    this.lastPositionMs = 0,
  });

  factory PodcastSession.initial(
    String sujet,
    int dureeMin, {
    String? categorie,
    NiveauEditorial niveau = NiveauEditorial.standard,
  }) {
    final now = DateTime.now();
    return PodcastSession(
      id: 'session_${now.millisecondsSinceEpoch}',
      sujet: sujet,
      categorie: categorie,
      niveau: niveau,
      dureeMin: dureeMin,
      titre: sujet,
      createdAt: now,
      chapters: const [],
      fiche: const {},
      qcm: const [],
      planReady: false,
      allChaptersReady: false,
    );
  }

  PodcastSession copyWith({
    String? titre,
    List<Chapter>? chapters,
    Map<String, dynamic>? fiche,
    List<Map<String, dynamic>>? qcm,
    bool? planReady,
    bool? allChaptersReady,
    String? globalError,
    bool clearError = false,
    int? lastChapterIdx,
    int? lastPositionMs,
  }) {
    return PodcastSession(
      id: id,
      sujet: sujet,
      categorie: categorie,
      niveau: niveau,
      dureeMin: dureeMin,
      titre: titre ?? this.titre,
      createdAt: createdAt,
      chapters: chapters ?? this.chapters,
      fiche: fiche ?? this.fiche,
      qcm: qcm ?? this.qcm,
      planReady: planReady ?? this.planReady,
      allChaptersReady: allChaptersReady ?? this.allChaptersReady,
      globalError: clearError ? null : (globalError ?? this.globalError),
      lastChapterIdx: lastChapterIdx ?? this.lastChapterIdx,
      lastPositionMs: lastPositionMs ?? this.lastPositionMs,
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'sujet': sujet,
        'categorie': categorie,
        'niveau': niveau.name,
        'dureeMin': dureeMin,
        'titre': titre,
        'createdAt': createdAt.toIso8601String(),
        'chapters': chapters.map((c) => c.toJson()).toList(),
        'fiche': fiche,
        'qcm': qcm,
        'planReady': planReady,
        'allChaptersReady': allChaptersReady,
        'globalError': globalError,
        'lastChapterIdx': lastChapterIdx,
        'lastPositionMs': lastPositionMs,
      };

  factory PodcastSession.fromJson(Map<String, dynamic> j) => PodcastSession(
        id: j['id'] as String,
        sujet: j['sujet'] as String,
        categorie: j['categorie'] as String?,
        niveau: NiveauEditorial.values.firstWhere(
          (n) => n.name == j['niveau'],
          orElse: () => NiveauEditorial.standard,
        ),
        dureeMin: j['dureeMin'] as int,
        titre: j['titre'] as String,
        createdAt: DateTime.parse(j['createdAt'] as String),
        chapters: (j['chapters'] as List)
            .map((e) => Chapter.fromJson(e as Map<String, dynamic>))
            .toList(),
        fiche: Map<String, dynamic>.from(j['fiche'] as Map? ?? {}),
        qcm: ((j['qcm'] as List?) ?? [])
            .map((e) => Map<String, dynamic>.from(e as Map))
            .toList(),
        planReady: j['planReady'] as bool? ?? true,
        allChaptersReady: j['allChaptersReady'] as bool? ?? true,
        globalError: j['globalError'] as String?,
        lastChapterIdx: j['lastChapterIdx'] as int?,
        lastPositionMs: j['lastPositionMs'] as int? ?? 0,
      );

  /// Progression grossière pour l'écran de génération initial
  /// (uniquement pertinente tant que le premier chapitre n'est pas prêt)
  double get initialProgress {
    if (!planReady) return 0.05;
    if (chapters.isEmpty) return 0.10;
    final first = chapters.first;
    switch (first.status) {
      case ChapterStatus.pending:
        return 0.15;
      case ChapterStatus.generatingScript:
        return 0.40;
      case ChapterStatus.generatingAudio:
        return 0.75;
      case ChapterStatus.ready:
        return 1.0;
      case ChapterStatus.error:
        return 1.0;
    }
  }

  /// Étape lisible pour l'UI (utilisée avant la bascule vers le player)
  String get initialEtape {
    if (globalError != null) return globalError!;
    if (!planReady) return 'Structuration du plan...';
    if (chapters.isEmpty) return 'Préparation des chapitres...';
    final first = chapters.first;
    switch (first.status) {
      case ChapterStatus.pending:
        return 'Préparation du premier chapitre...';
      case ChapterStatus.generatingScript:
        return 'Écriture du premier chapitre...';
      case ChapterStatus.generatingAudio:
        return 'Synthèse de la voix...';
      case ChapterStatus.ready:
        return 'Prêt !';
      case ChapterStatus.error:
        return first.errorMessage ?? 'Erreur';
    }
  }

  bool get firstChapterReady =>
      chapters.isNotEmpty && chapters.first.status == ChapterStatus.ready;
}

// ─── Service ───────────────────────────────────────────

class PodcastService {
  // Clé API chargée depuis .env au démarrage de l'app (voir main.dart).
  // Étape suivante : remplacer par un proxy backend (Supabase Edge Function)
  // pour que la clé ne soit plus embarquée dans l'APK.
  static String get _apiKey => dotenv.env['GEMINI_API_KEY']!;
  static const _modelScript = 'gemini-2.5-flash';
  static const _modelTts = 'gemini-2.5-flash-preview-tts';
  static const _baseUrl =
      'https://generativelanguage.googleapis.com/v1beta/models';

  static String _buildSystemPrompt(NiveauEditorial niveau) {
    switch (niveau) {
      case NiveauEditorial.vulgarisation:
        return '''
Tu es un scénariste de podcast de vulgarisation, accessible à tout public
cultivé, style "France Inter". Ton objectif : rendre le sujet clair et
captivant pour quelqu'un qui court et ne peut pas prendre de notes.

NIVEAU D'EXIGENCE :
- Analyses claires, comparables à un bon article de Libération ou France Info.
- L'Expert explique simplement, en utilisant des analogies du quotidien.
- Le Curieux joue le rôle de l'auditeur qui découvre le sujet : il pose
  des questions naïves mais justes, demande des clarifications, reformule.
- Un néophyte cultivé doit tout comprendre sans effort.
- Privilégie les exemples concrets et les anecdotes aux concepts abstraits.

RYTHME DU DIALOGUE :
- L'Expert développe ses idées sur 2 à 3 échanges avant relance.
- Les répliques de l'Expert font 60 à 120 mots.
- Les répliques du Curieux font 15 à 40 mots — questions franches, réactions.
- INTERDIT : les répliques de moins de 8 mots sauf exception.
- Ratio cible : 65% Expert / 35% Curieux en volume de mots.
- Chaque bloc de 5 minutes doit comporter entre 700 et 750 mots.

INTERDICTIONS ABSOLUES :
- INTERDIT en début de réplique : Exactement, Absolument, Précisément,
  Effectivement, Tout à fait, En effet.
- INTERDIT : enchaîner deux répliques longues de suite.
- INTERDIT : Alors, Donc en tout début de réplique.
- INTERDIT : jargon technique non expliqué, abréviations obscures.
''';

      case NiveauEditorial.standard:
        return '''
Tu es un scénariste de podcast pédagogique de qualité, type France Culture.
Ton objectif : rendre le sujet stimulant et structuré pour quelqu'un
qui court et ne peut pas prendre de notes.

NIVEAU D'EXIGENCE :
- Analyses solides, comparables à un article du Monde ou de L'Express.
- L'Expert présente des concepts précis, cite quelques auteurs et dates clés.
- Le Curieux est cultivé mais non spécialiste : il pose de vraies questions
  de clarification, challenge avec bon sens, demande des exemples.
- L'auditeur doit apprendre des choses nouvelles, pas une révision.
- Équilibre entre rigueur et accessibilité.

RYTHME DU DIALOGUE :
- L'Expert développe ses idées sur 2 à 4 échanges avant d'être relancé.
- Les répliques de l'Expert font 70 à 140 mots.
- Les répliques du Curieux font 20 à 45 mots — questions structurantes.
- INTERDIT : les répliques de moins de 10 mots sauf exception dramatique.
- Ratio cible : 70% Expert / 30% Curieux en volume de mots.
- Chaque bloc de 5 minutes doit comporter entre 700 et 750 mots.

INTERDICTIONS ABSOLUES :
- INTERDIT en début de réplique : Exactement, Absolument, Précisément,
  Effectivement, Tout à fait, En effet.
- INTERDIT : enchaîner deux répliques longues de suite.
- INTERDIT : Alors, Donc en tout début de réplique.
''';

      case NiveauEditorial.pointu:
        return '''
Tu es un scénariste de podcast pédagogique d'élite, au niveau d'exigence
intellectuelle d'une grande école (ENA, Sciences Po, HEC).
Ton objectif : rendre un sujet complexe IRRÉSISTIBLE pour quelqu'un
qui court et ne peut pas prendre de notes.

NIVEAU D'EXIGENCE :
- Les analyses doivent avoir la profondeur d'un article du Monde diplomatique
  ou d'une revue académique grand-public (Esprit, Commentaire).
- L'Expert cite des auteurs, des théoriciens, des dates précises, des chiffres
  sourcés. Il mobilise des concepts techniques.
- Le Curieux est lui-même cultivé — il ne joue pas le rôle du novice ignorant,
  mais celui d'un pair qui challenge, nuance et approfondit.
- Les sujets traités doivent avoir une vraie densité historique, économique
  ou scientifique. Pas d'analogies triviales.

RYTHME DU DIALOGUE :
- L'Expert développe ses idées sur 3 à 5 échanges avant d'être interrompu.
- Les répliques de l'Expert font 80 à 150 mots — assez pour développer un argument.
- Les répliques du Curieux font 20 à 50 mots — il relance, nuance, challenge.
- INTERDIT : les répliques de moins de 10 mots sauf exception dramatique.
- Ratio cible : 70% Expert / 30% Curieux en volume de mots.
- Chaque bloc de 5 minutes doit impérativement comporter entre 700 et 750 mots.
  Si le dialogue est trop court, développe les exemples historiques et les analyses.

INTERDICTIONS ABSOLUES :
- INTERDIT en début de réplique : Exactement, Absolument, Précisément,
  Effectivement, Tout à fait, En effet.
- INTERDIT : enchaîner deux répliques longues de suite.
- INTERDIT : Alors, Donc en tout début de réplique.
''';
    }
  }

  /// Génère un podcast en streaming.
  ///
  /// Retourne un [ValueNotifier] dont la valeur est mise à jour au fur
  /// et à mesure que les chapitres sont prêts. Tout listener qui s'abonne
  /// (même tardivement) voit immédiatement l'état le plus récent via
  /// `.value` — pas de race possible.
  ///
  /// L'appelant peut commencer la lecture dès que `session.firstChapterReady`
  /// est vrai. Les chapitres suivants continueront d'être générés en
  /// arrière-plan.
  ///
  /// Si [onSessionUpdate] est fourni, il est appelé à chaque fois qu'un
  /// chapitre passe à l'état `ready` (donc incrémentalement : ch1 ready, puis
  /// ch1+ch2 ready, etc.) et une dernière fois à la fin. C'est l'API de
  /// sauvegarde côté historique : à chaque appel, on écrase le même enregistrement
  /// Hive (clé = session.id), ce qui est idempotent. Si la pipeline crashe à
  /// mi-parcours, tout ce qui avait été sauvegardé reste.
  static ValueNotifier<PodcastSession> generer({
    required String sujet,
    required int dureeMin,
    String? categorie,
    NiveauEditorial niveau = NiveauEditorial.standard,
    void Function(PodcastSession)? onSessionUpdate,
  }) {
    final notifier = ValueNotifier<PodcastSession>(
      PodcastSession.initial(
        sujet,
        dureeMin,
        categorie: categorie,
        niveau: niveau,
      ),
    );

    // Pipeline indépendante du consommateur. Le notifier garde toujours
    // la dernière valeur ; la pipeline continue à tourner même si personne
    // n'écoute encore.
    () async {
      PodcastSession lastKnownSession = notifier.value;

      // Helper idempotent pour sauvegarder — protégé contre les erreurs
      // et contre le cas où le notifier aurait été disposé.
      void trySave(PodcastSession s) {
        if (onSessionUpdate == null) return;
        if (!s.chapters.any((c) => c.status == ChapterStatus.ready)) return;
        try {
          onSessionUpdate(s);
        } catch (e) {
          debugPrint('⚠️ onSessionUpdate error: $e');
        }
      }

      // Wakelock : empêche l'écran de s'éteindre pendant la génération.
      // Sans ça, Android entre en Doze mode et suspend les requêtes Gemini
      // au-delà de quelques dizaines de secondes en background.
      // Note : ce wakelock ne maintient PAS l'app vivante si l'utilisateur
      // verrouille manuellement le téléphone — pour ça il faudrait un
      // Foreground Service complet (chantier futur).
      try {
        await WakelockPlus.enable();
        debugPrint('🔒 Wakelock activé pour la génération');
      } catch (e) {
        debugPrint('⚠️ Wakelock enable failed: $e');
      }

      try {
        await _runPipeline(notifier, trySave);
        lastKnownSession = notifier.value;
      } catch (e, st) {
        debugPrint('💥 Pipeline crash : $e\n$st');
        // Tenter d'écrire l'erreur dans le notifier, mais si le notifier
        // a été disposé (ex: user a quitté le player), on ignore.
        try {
          notifier.value = notifier.value.copyWith(
            globalError: 'Erreur fatale : $e',
          );
          lastKnownSession = notifier.value;
        } catch (_) {
          debugPrint('   (notifier disposé, pas d\'update d\'erreur possible)');
        }
      } finally {
        debugPrint('🏁 Pipeline terminée');
        // Sauvegarde finale de ce qu'on a — même si la pipeline a crashé
        // ou si le notifier est disposé, lastKnownSession contient la
        // dernière valeur qu'on a pu lire avec succès.
        trySave(lastKnownSession);
        // Libère le wakelock — l'écran peut à nouveau s'éteindre.
        try {
          await WakelockPlus.disable();
          debugPrint('🔓 Wakelock relâché');
        } catch (e) {
          debugPrint('⚠️ Wakelock disable failed: $e');
        }
      }
    }();

    return notifier;
  }

  static Future<void> _runPipeline(
    ValueNotifier<PodcastSession> notifier,
    void Function(PodcastSession) onSessionUpdate,
  ) async {
    // La session initiale (avec id, sujet, categorie, niveau, createdAt) a
    // été construite par generer() et est déjà dans notifier.value.
    var session = notifier.value;
    final sujet = session.sujet;
    final dureeMin = session.dureeMin;
    final niveau = session.niveau;

    // emit() : met à jour le notifier (si pas disposé) ET la variable locale.
    // On conserve toujours `session` à jour localement, même si le notifier
    // a été disposé côté consommateur — comme ça la pipeline peut finir
    // proprement et sauvegarder le résultat final.
    void emit(PodcastSession s) {
      session = s;
      try {
        notifier.value = s;
      } catch (e) {
        // notifier disposé : le consommateur ne nous écoute plus, mais on
        // continue la pipeline pour sauvegarder en fin de parcours.
        debugPrint('   (notifier disposé, on continue en background)');
      }
    }

    emit(session);

    // ── Étape 0 : Plan ──────────────────────────────
    debugPrint('🚀 Pipeline : génération du plan...');
    List<PlanBloc> plan;
    try {
      plan = await _genererPlan(sujet, dureeMin);
    } catch (e) {
      debugPrint('❌ Erreur plan : $e');
      emit(session.copyWith(globalError: 'Erreur plan : $e'));
      return;
    }

    debugPrint('📋 Plan généré : ${plan.length} parties');
    for (final p in plan) {
      debugPrint('  ${p.numero}. ${p.titre} — ${p.description}');
    }

    session = session.copyWith(
      planReady: true,
      chapters: plan
          .map((p) => Chapter(index: p.numero - 1, plan: p))
          .toList(growable: false),
    );
    emit(session);

    // ── Préparation répertoire ──────────────────────
    final dir = await getApplicationDocumentsDirectory();
    final sessionDir = Directory(
        '${dir.path}/podcast_${DateTime.now().millisecondsSinceEpoch}');
    await sessionDir.create(recursive: true);
    debugPrint('📁 Session dir : ${sessionDir.path}');

    // ── Boucle chapitres ────────────────────────────
    String resumeContexte = '';
    String titre = sujet;
    Map<String, dynamic> fiche = const {};
    List<Map<String, dynamic>> qcm = const [];
    int totalMotsActuels = 0;
    // Budget total de mots, calibré sur l'observation réelle :
    // les voix Gemini TTS débitent environ 180 mots/min (pas 145 comme
    // initialement estimé). À 145, les podcasts sortaient ~25% trop courts.
    final budgetTotal = dureeMin * 180;

    for (int i = 0; i < plan.length; i++) {
      debugPrint('━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━');
      debugPrint('▶️  Démarrage chapitre ${i + 1}/${plan.length}');

      if (totalMotsActuels >= budgetTotal && i > 0) {
        debugPrint(
            '✂️ Budget mots atteint ($totalMotsActuels/$budgetTotal), arrêt');
        break;
      }

      // --- Script ---
      var chapters = session.chapters.map((c) => c.copy()).toList();
      chapters[i].status = ChapterStatus.generatingScript;
      session = session.copyWith(chapters: chapters);
      emit(session);

      // Cible de mots dynamique : le budget total (dureeMin * 145) est
      // réparti équitablement entre les chapitres. Le dernier vise ~11%
      // de moins pour laisser de la marge à la conclusion.
      // Exemples :
      // - 15 min / 3 blocs → ~725 mots par bloc (650 pour le dernier)
      // - 30 min / 6 blocs → ~725 mots par bloc
      // - 45 min / 8 blocs (clampé) → ~815 mots par bloc
      final motsParBloc = (budgetTotal / plan.length).round();
      final motsCible = i == plan.length - 1 && plan.length > 1
          ? (motsParBloc * 0.89).round()
          : motsParBloc;

      // Garde-fous :
      // - minimum 200 mots (sinon script vide / déstructuré → retry)
      // - maximum motsCible * 1.5 (sinon Gemini a dérapé → on tronque)
      const motsMinimum = 200;
      final motsMaximum = (motsCible * 1.5).round();
      List<Replique>? scriptBloc;
      Map<String, dynamic>? parsed;
      int motsBloc = 0;
      String? scriptError;

      for (int tentative = 1; tentative <= 2; tentative++) {
        try {
          debugPrint(
              '📝 Chapitre ${i + 1} : appel Gemini script (tentative $tentative/2)...');
          parsed = await _genererScriptBloc(
            sujet: sujet,
            dureeMin: 5,
            partie: i + 1,
            totalParties: plan.length,
            planBloc: plan[i],
            motsCible: motsCible,
            resumeContexte: resumeContexte,
            niveau: niveau,
          );
          scriptBloc = parsed['script'] as List<Replique>;
          motsBloc = scriptBloc
              .map((r) => r.text.split(' ').length)
              .fold(0, (a, b) => a + b);
          debugPrint(
              '📝 Chapitre ${i + 1} : ${scriptBloc.length} répliques, $motsBloc mots');

          // Script trop long : on tronque aux premières répliques jusqu'à
          // atteindre la cible. Pas de retry (Gemini pourrait faire pareil).
          if (motsBloc > motsMaximum) {
            debugPrint(
                '✂️ Script trop long ($motsBloc > $motsMaximum mots), troncature à ~$motsCible mots');
            final troncated = <Replique>[];
            int running = 0;
            for (final r in scriptBloc) {
              final w = r.text.split(' ').length;
              if (running + w > motsCible) break;
              troncated.add(r);
              running += w;
            }
            // Garantie d'au moins 1 réplique
            if (troncated.isEmpty && scriptBloc.isNotEmpty) {
              troncated.add(scriptBloc.first);
            }
            scriptBloc = troncated;
            motsBloc = running;
            debugPrint(
                '   → tronqué à ${scriptBloc.length} répliques, $motsBloc mots');
            scriptError = null;
            break;
          }

          if (motsBloc >= motsMinimum) {
            scriptError = null;
            break;
          }
          debugPrint(
              '⚠️ Script trop court ($motsBloc < $motsMinimum mots), retry...');
          scriptError = 'Script trop court ($motsBloc mots)';
        } catch (e) {
          debugPrint('❌ Erreur script chapitre ${i + 1} tentative $tentative : $e');
          scriptError = e.toString();
        }
      }

      if (scriptBloc == null ||
          parsed == null ||
          motsBloc < motsMinimum) {
        debugPrint(
            '❌ Chapitre ${i + 1} : script inexploitable après retry ($scriptError)');
        chapters = session.chapters.map((c) => c.copy()).toList();
        chapters[i].status = ChapterStatus.error;
        chapters[i].errorMessage = scriptError ?? 'Script invalide';
        session = session.copyWith(chapters: chapters);
        emit(session);
        if (i == 0) {
          emit(session.copyWith(
              globalError: 'Impossible de générer le podcast (script ch1 invalide)'));
          return;
        }
        continue;
      }

      if (parsed['fiche'] != null) {
        fiche = parsed['fiche'] as Map<String, dynamic>;
      }
      if (parsed['qcm'] != null) {
        qcm = parsed['qcm'] as List<Map<String, dynamic>>;
      }
      if (parsed['titre'] != null && (parsed['titre'] as String).isNotEmpty) {
        titre = parsed['titre'] as String;
      }

      debugPrint(
          '📝 Chapitre ${i + 1} "${plan[i].titre}" validé : $motsBloc mots (total ${totalMotsActuels + motsBloc}/$budgetTotal)');

      totalMotsActuels += motsBloc;

      chapters = session.chapters.map((c) => c.copy()).toList();
      chapters[i].script = scriptBloc;
      chapters[i].status = ChapterStatus.generatingAudio;
      session = session.copyWith(
        chapters: chapters,
        titre: titre,
        fiche: fiche,
        qcm: qcm,
      );
      emit(session);

      // Résumé conceptuel en parallèle (pour le chapitre suivant)
      final futureResume = _genererResume(scriptBloc, plan[i]);

      // --- Audio ---
      debugPrint('🎬 Chapitre ${i + 1} : démarrage génération audio...');
      String wavPath;
      try {
        wavPath = await _genererAudioChapitre(
          script: scriptBloc,
          index: i,
          dirPath: sessionDir.path,
        );
        debugPrint('🎵 Chapitre ${i + 1} : audio écrit dans $wavPath');
      } catch (e, st) {
        debugPrint('❌ Erreur audio chapitre ${i + 1} : $e\n$st');
        chapters = session.chapters.map((c) => c.copy()).toList();
        chapters[i].status = ChapterStatus.error;
        chapters[i].errorMessage = 'Audio : $e';
        session = session.copyWith(chapters: chapters);
        emit(session);
        if (i == 0) {
          emit(session.copyWith(
              globalError: 'Impossible de générer le podcast'));
          return;
        }
        continue;
      }

      chapters = session.chapters.map((c) => c.copy()).toList();
      chapters[i].wavPath = wavPath;
      chapters[i].status = ChapterStatus.ready;
      session = session.copyWith(chapters: chapters);
      emit(session);
      debugPrint('✅ Chapitre ${i + 1} prêt');

      // Sauvegarde incrémentale : on écrit dans l'historique dès qu'un
      // chapitre est prêt, pas juste à la fin. Idempotent (même clé).
      onSessionUpdate(session);

      try {
        resumeContexte = await futureResume;
      } catch (_) {
        resumeContexte = 'Partie ${i + 1} "${plan[i].titre}" couverte.';
      }
    }

    final allReady = session.chapters.every((c) => c.status == ChapterStatus.ready);
    final hasErrors = session.chapters.any((c) => c.status == ChapterStatus.error);
    session = session.copyWith(allChaptersReady: allReady);
    emit(session);
    if (allReady) {
      debugPrint('🎉 Pipeline complète : tous chapitres OK');
    } else if (hasErrors) {
      final errCount = session.chapters.where((c) => c.status == ChapterStatus.error).length;
      debugPrint('⚠️ Pipeline terminée avec $errCount chapitre(s) en erreur');
    } else {
      debugPrint('⚠️ Pipeline terminée (interrompue par budget mots ou autre)');
    }
  }

  // ── Étape 0 : Génération du plan ────────────────────

  static Future<List<PlanBloc>> _genererPlan(String sujet, int duree) async {
    const blocDuree = 5;
    final nbBlocs = (duree / blocDuree).round().clamp(1, 8);

    // Format ultra-strict : pas de prose libre, uniquement les lignes PARTIE.
    // Chaque description courte (≤ 25 mots) pour rester sous le budget tokens.
    final prompt = '''
Génère un plan de podcast de $duree minutes sur : "$sujet"

EXACTEMENT $nbBlocs lignes au format strict ci-dessous, AUCUN texte avant ou après.
Chaque description fait MAXIMUM 25 mots.

PARTIE 1 | Titre court | Description courte
PARTIE 2 | Titre court | Description courte
${nbBlocs >= 3 ? 'PARTIE 3 | Titre court | Description courte' : ''}
${nbBlocs >= 4 ? 'PARTIE 4 | Titre court | Description courte' : ''}
${nbBlocs >= 5 ? 'PARTIE 5 | Titre court | Description courte' : ''}
${nbBlocs >= 6 ? 'PARTIE 6 | Titre court | Description courte' : ''}

Fil conducteur : contexte → analyse → enjeux → synthèse.
NE COMMENCE PAS par "Voici", "Bien sûr", ou tout autre préambule.
PREMIÈRE LIGNE de ta réponse = "PARTIE 1 | ..."
'''
        .trim();

    final response = await http
        .post(
          Uri.parse('$_baseUrl/$_modelScript:generateContent?key=$_apiKey'),
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode({
            'contents': [
              {
                'parts': [
                  {'text': prompt}
                ]
              }
            ],
            'generationConfig': {
              'temperature': 0.4,
              'maxOutputTokens': 4000, // large pour éviter toute troncature
            },
          }),
        )
        .timeout(const Duration(minutes: 2));

    if (response.statusCode != 200) {
      return List.generate(
        nbBlocs,
        (i) => PlanBloc(
          numero: i + 1,
          titre: 'Partie ${i + 1}',
          description: i == 0
              ? 'Introduction et contexte'
              : i == nbBlocs - 1
                  ? 'Synthèse et enjeux contemporains'
                  : 'Développement et analyse',
        ),
      );
    }

    final data = jsonDecode(response.body);
    final candidate = data['candidates'][0];
    final finishReason = candidate['finishReason'];
    final rawText = candidate['content']['parts'][0]['text'] as String;
    if (finishReason != null && finishReason != 'STOP') {
      debugPrint('⚠️ Plan finishReason = $finishReason (peut être tronqué)');
    }
    debugPrint('🔍 Plan brut Gemini :\n$rawText');
    return _parsePlan(rawText, nbBlocs);
  }

  static List<PlanBloc> _parsePlan(String rawText, int nbBlocs) {
    final blocs = <PlanBloc>[];

    // Regex tolérante : "PARTIE 1", "**PARTIE 1**", "Partie 1", "1.", "1)" en début de ligne
    final partieRegex = RegExp(
      r'^\s*(?:\*+\s*)?(?:PARTIE\s*)?(\d+)(?:\s*\*+)?\s*[:\-\.\)\|]?\s*',
      caseSensitive: false,
    );

    for (final line in rawText.split('\n')) {
      final trimmed = line.trim();
      if (trimmed.isEmpty) continue;

      final match = partieRegex.firstMatch(trimmed);
      if (match == null || match.start != 0) continue;

      var reste = trimmed.substring(match.end).trim();
      // Consomme un éventuel séparateur résiduel ("| titre" → "titre")
      reste = reste.replaceFirst(RegExp(r'^[\|\-—:]\s*'), '');
      if (reste.isEmpty) continue;

      // Sépare titre / description : on essaye successivement |, —, -, :
      String titre;
      String description;
      List<String>? parts;
      for (final sep in ['|', ' — ', ' - ', ' : ', ': ']) {
        if (reste.contains(sep)) {
          parts = reste.split(sep).map((s) => s.trim()).where((s) => s.isNotEmpty).toList();
          if (parts.length >= 2) break;
          parts = null;
        }
      }
      if (parts != null && parts.length >= 2) {
        titre = parts[0];
        description = parts.sublist(1).join(' — ');
      } else {
        titre = reste;
        description = '';
      }

      // Nettoie le markdown éventuel
      titre = titre.replaceAll(RegExp(r'^\*+|\*+$'), '').trim();
      description = description.replaceAll(RegExp(r'^\*+|\*+$'), '').trim();

      if (titre.isEmpty) continue;

      blocs.add(PlanBloc(
        numero: blocs.length + 1,
        titre: titre,
        description: description.isNotEmpty ? description : titre,
      ));
      if (blocs.length >= nbBlocs) break;
    }

    if (blocs.length < nbBlocs) {
      debugPrint(
          '⚠️ Parser plan : seulement ${blocs.length}/$nbBlocs parties détectées, complétion par fallback');
    }
    while (blocs.length < nbBlocs) {
      blocs.add(PlanBloc(
        numero: blocs.length + 1,
        titre: 'Partie ${blocs.length + 1}',
        description: 'Suite de l\'analyse',
      ));
    }
    return blocs;
  }

  // ── Étape 1 : Script d'un chapitre ──────────────────

  static Future<Map<String, dynamic>> _genererScriptBloc({
    required String sujet,
    required int dureeMin,
    required int partie,
    required int totalParties,
    required PlanBloc planBloc,
    required int motsCible,
    required String resumeContexte,
    required NiveauEditorial niveau,
  }) async {
    final prompt = _buildScriptPrompt(
      sujet: sujet,
      duree: dureeMin,
      partie: partie,
      totalParties: totalParties,
      planBloc: planBloc,
      motsCible: motsCible,
      resumeContexte: resumeContexte,
    );

    final response = await http
        .post(
          Uri.parse('$_baseUrl/$_modelScript:generateContent?key=$_apiKey'),
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode({
            'system_instruction': {
              'parts': [
                {'text': _buildSystemPrompt(niveau)}
              ]
            },
            'contents': [
              {
                'parts': [
                  {'text': prompt}
                ]
              }
            ],
            'generationConfig': {
              'temperature': 0.7,
              'maxOutputTokens': 24000,
            },
          }),
        )
        .timeout(const Duration(minutes: 3));

    if (response.statusCode != 200) {
      throw Exception('Gemini ${response.statusCode}');
    }

    final data = jsonDecode(response.body);
    final candidate = data['candidates'][0];
    final finishReason = candidate['finishReason'];
    final rawText = candidate['content']['parts'][0]['text'] as String;
    final result = _parseReponse(rawText);
    final scriptList = result['script'] as List;
    if (scriptList.isEmpty) {
      debugPrint(
          '⚠️ Script Gemini parsé à 0 répliques. finishReason=$finishReason');
      debugPrint(
          '   raw (300 premiers car) : ${rawText.substring(0, rawText.length.clamp(0, 300))}');
    }
    return result;
  }

  // ── Résumé conceptuel pour le chapitre suivant ──────

  static Future<String> _genererResume(
    List<Replique> script,
    PlanBloc plan,
  ) async {
    final resumePrompt = '''
Résume en 3 lignes maximum les concepts clés abordés dans ce dialogue :

${script.map((r) => '${r.voice == "expert" ? "Expert" : "Curieux"}: ${r.text}').join('\n')}

Résumé (3 lignes max, concepts clés uniquement) :''';

    final response = await http
        .post(
          Uri.parse('$_baseUrl/$_modelScript:generateContent?key=$_apiKey'),
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode({
            'contents': [
              {
                'parts': [
                  {'text': resumePrompt}
                ]
              }
            ],
            'generationConfig': {'temperature': 0.3, 'maxOutputTokens': 200},
          }),
        )
        .timeout(const Duration(seconds: 30));

    if (response.statusCode != 200) {
      return 'Partie ${plan.numero} "${plan.titre}" couverte.';
    }

    final rd = jsonDecode(response.body);
    final rTxt = rd['candidates'][0]['content']['parts'][0]['text'] as String;
    return 'RÉSUMÉ PARTIE ${plan.numero} "${plan.titre}" :\n${rTxt.trim()}';
  }

  // ── Étape 2 : Audio d'un chapitre ────────────────────

  /// Un fichier WAV par chapitre (concaténation interne des sous-blocs TTS).
  /// Ce format est conçu pour marcher avec ConcatenatingAudioSource côté
  /// player : un AudioSource par chapitre, qu'on ajoute à la playlist au
  /// fur et à mesure.
  static Future<String> _genererAudioChapitre({
    required List<Replique> script,
    required int index,
    required String dirPath,
  }) async {
    // Sous-blocs plus petits = appels TTS plus courts, moins de risque
    // de timeout/hang côté Gemini sur les gros chapitres.
    const maxRepliquesParSousBloc = 8;
    final nbSousBlocs =
        (script.length / maxRepliquesParSousBloc).ceil().clamp(1, 99);
    final tailleSousBloc = (script.length / nbSousBlocs).ceil();
    final sousBlocs = List.generate(nbSousBlocs, (i) {
      final debut = i * tailleSousBloc;
      final fin = (debut + tailleSousBloc).clamp(0, script.length);
      return script.sublist(debut, fin);
    });

    debugPrint(
        '🎬 Chapitre ${index + 1} : ${script.length} répliques en $nbSousBlocs sous-blocs TTS');

    // Parallélisation avec concurrence limitée à 2.
    // Pourquoi 2 et pas plus : au-delà on risque le rate limit Gemini TTS
    // (~2 req/s sur le quota gratuit). 2 donne un gain substantiel (50% sur
    // les chapitres à 2 sous-blocs, le cas typique) sans saturer.
    // L'ordre des résultats est préservé via l'index dans la liste.
    final pcmResults = List<Uint8List?>.filled(nbSousBlocs, null);
    const maxConcurrent = 2;

    for (int start = 0; start < nbSousBlocs; start += maxConcurrent) {
      final end = (start + maxConcurrent).clamp(0, nbSousBlocs);
      final batch = <Future<void>>[];
      for (int j = start; j < end; j++) {
        batch.add(_ttsSousBloc(sousBlocs[j], index, j).then((pcm) {
          pcmResults[j] = pcm;
        }));
      }
      // On attend que le batch entier finisse avant le prochain.
      // eagerError=true : si une future throw, on propage immédiatement
      // sans attendre les autres (les autres continueront en fond mais
      // le résultat est déjà compromis).
      await Future.wait(batch, eagerError: true);
    }

    // Concaténation dans l'ordre d'origine (pcmResults est indexée par j)
    final allPcm = <int>[];
    for (int j = 0; j < nbSousBlocs; j++) {
      final pcm = pcmResults[j];
      if (pcm == null) {
        throw Exception(
            'TTS chapitre ${index + 1} sous-bloc $j : résultat manquant');
      }
      allPcm.addAll(pcm);
    }

    final wavPath = '$dirPath/chapitre_$index.wav';
    final wavBytes = _pcmToWav(Uint8List.fromList(allPcm), 24000, 1, 16);
    await File(wavPath).writeAsBytes(wavBytes);

    final dureeSec = allPcm.length / (24000 * 2);
    debugPrint(
        '🎵 Chapitre ${index + 1} terminé : ${dureeSec.toStringAsFixed(1)}s, ${(allPcm.length / 1024 / 1024).toStringAsFixed(1)}MB');
    return wavPath;
  }

  /// Appel TTS brut avec retry et timeout strict, retourne le PCM sans header WAV.
  static Future<Uint8List> _ttsSousBloc(
    List<Replique> bloc,
    int chapterIndex,
    int subIndex,
  ) async {
    final lignes = bloc.map((r) {
      final prefix = r.voice == 'expert' ? 'Expert' : 'Curieux';
      return '$prefix: ${r.text}';
    }).join('\n');

    final motsBloc =
        bloc.map((r) => r.text.split(' ').length).fold(0, (a, b) => a + b);

    final prompt =
        'Génère ce podcast pédagogique en français avec deux voix distinctes.\n'
        'Expert est une voix masculine grave, posée, passionnée et pédagogue.\n'
        'Curieux est une voix féminine vive, spontanée, curieuse et réactive.\n'
        'Le ton est naturel, comme une vraie conversation captivante.\n\n'
        '$lignes';

    final body = jsonEncode({
      'contents': [
        {
          'parts': [
            {'text': prompt}
          ]
        }
      ],
      'generationConfig': {
        'responseModalities': ['AUDIO'],
        'speechConfig': {
          'multiSpeakerVoiceConfig': {
            'speakerVoiceConfigs': [
              {
                'speaker': 'Expert',
                'voiceConfig': {
                  'prebuiltVoiceConfig': {'voiceName': 'Charon'}
                }
              },
              {
                'speaker': 'Curieux',
                'voiceConfig': {
                  'prebuiltVoiceConfig': {'voiceName': 'Aoede'}
                }
              },
            ]
          }
        }
      },
    });

    const maxAttempts = 3;
    for (int attempt = 1; attempt <= maxAttempts; attempt++) {
      final stopwatch = Stopwatch()..start();
      debugPrint(
          '🔊 TTS ch${chapterIndex + 1}.$subIndex tentative $attempt/$maxAttempts ($motsBloc mots, ${bloc.length} répliques)...');

      try {
        final response = await http
            .post(
              Uri.parse('$_baseUrl/$_modelTts:generateContent?key=$_apiKey'),
              headers: {'Content-Type': 'application/json'},
              body: body,
            )
            .timeout(const Duration(minutes: 4));

        stopwatch.stop();

        if (response.statusCode == 429) {
          // Rate limit Gemini — backoff exponentiel
          final wait = Duration(seconds: 5 * attempt * attempt);
          debugPrint(
              '⏱  TTS ch${chapterIndex + 1}.$subIndex rate-limited (429), retry dans ${wait.inSeconds}s');
          await Future.delayed(wait);
          continue;
        }

        if (response.statusCode != 200) {
          debugPrint(
              '❌ TTS ch${chapterIndex + 1}.$subIndex HTTP ${response.statusCode} après ${stopwatch.elapsed.inSeconds}s');
          debugPrint('   body: ${response.body.substring(0, response.body.length.clamp(0, 500))}');
          if (attempt == maxAttempts) {
            throw Exception(
                'TTS HTTP ${response.statusCode} (chapitre $chapterIndex sous-bloc $subIndex)');
          }
          await Future.delayed(Duration(seconds: 3 * attempt));
          continue;
        }

        // Parsing — peut échouer si la réponse n'a pas le format attendu
        final data = jsonDecode(response.body);
        final candidates = data['candidates'] as List?;
        if (candidates == null || candidates.isEmpty) {
          debugPrint(
              '❌ TTS ch${chapterIndex + 1}.$subIndex : pas de candidates dans la réponse');
          debugPrint('   body: ${response.body.substring(0, response.body.length.clamp(0, 500))}');
          if (attempt == maxAttempts) {
            throw Exception('TTS réponse vide (chapitre $chapterIndex sous-bloc $subIndex)');
          }
          continue;
        }

        final parts = candidates[0]['content']?['parts'] as List?;
        if (parts == null || parts.isEmpty) {
          debugPrint(
              '❌ TTS ch${chapterIndex + 1}.$subIndex : pas de parts dans content');
          debugPrint('   finishReason: ${candidates[0]['finishReason']}');
          if (attempt == maxAttempts) {
            throw Exception('TTS réponse sans audio (chapitre $chapterIndex sous-bloc $subIndex)');
          }
          continue;
        }

        final inlineData = parts[0]['inlineData'];
        if (inlineData == null || inlineData['data'] == null) {
          debugPrint(
              '❌ TTS ch${chapterIndex + 1}.$subIndex : pas d\'inlineData');
          if (attempt == maxAttempts) {
            throw Exception('TTS pas d\'audio (chapitre $chapterIndex sous-bloc $subIndex)');
          }
          continue;
        }

        final audioB64 = inlineData['data'] as String;
        final pcm = base64Decode(audioB64);
        debugPrint(
            '✅ TTS ch${chapterIndex + 1}.$subIndex OK en ${stopwatch.elapsed.inSeconds}s (${(pcm.length / 1024 / 1024).toStringAsFixed(1)}MB)');
        return pcm;
      } on TimeoutException {
        stopwatch.stop();
        debugPrint(
            '⏱  TTS ch${chapterIndex + 1}.$subIndex TIMEOUT après ${stopwatch.elapsed.inSeconds}s (tentative $attempt)');
        if (attempt == maxAttempts) {
          throw Exception(
              'TTS timeout après $maxAttempts tentatives (chapitre $chapterIndex sous-bloc $subIndex)');
        }
      } catch (e) {
        stopwatch.stop();
        final errStr = e.toString();
        // Erreurs réseau "transitoires" (DNS, socket, connection closed) :
        // typiquement dues à l'app passée en arrière-plan. Backoff plus long
        // pour laisser la connexion revenir.
        final isNetworkError = errStr.contains('SocketException') ||
            errStr.contains('Failed host lookup') ||
            errStr.contains('Connection closed') ||
            errStr.contains('Connection refused') ||
            errStr.contains('Network is unreachable');
        debugPrint(
            '❌ TTS ch${chapterIndex + 1}.$subIndex erreur après ${stopwatch.elapsed.inSeconds}s : $e');
        if (attempt == maxAttempts) rethrow;
        final waitSec = isNetworkError ? 15 * attempt : 2 * attempt;
        debugPrint(
            '   ${isNetworkError ? "(réseau)" : ""} retry dans ${waitSec}s...');
        await Future.delayed(Duration(seconds: waitSec));
      }
    }

    throw Exception('TTS échec inattendu (chapitre $chapterIndex sous-bloc $subIndex)');
  }

  // ── WAV header ───────────────────────────────────────

  static Uint8List _pcmToWav(
    List<int> pcm,
    int sampleRate,
    int channels,
    int bitsPerSample,
  ) {
    final byteRate = sampleRate * channels * bitsPerSample ~/ 8;
    final blockAlign = channels * bitsPerSample ~/ 8;
    final dataSize = pcm.length;
    final buffer = ByteData(44 + dataSize);

    buffer.setUint8(0, 0x52);
    buffer.setUint8(1, 0x49);
    buffer.setUint8(2, 0x46);
    buffer.setUint8(3, 0x46); // RIFF
    buffer.setUint32(4, 36 + dataSize, Endian.little);
    buffer.setUint8(8, 0x57);
    buffer.setUint8(9, 0x41);
    buffer.setUint8(10, 0x56);
    buffer.setUint8(11, 0x45); // WAVE
    buffer.setUint8(12, 0x66);
    buffer.setUint8(13, 0x6D);
    buffer.setUint8(14, 0x74);
    buffer.setUint8(15, 0x20); // fmt
    buffer.setUint32(16, 16, Endian.little);
    buffer.setUint16(20, 1, Endian.little); // PCM
    buffer.setUint16(22, channels, Endian.little);
    buffer.setUint32(24, sampleRate, Endian.little);
    buffer.setUint32(28, byteRate, Endian.little);
    buffer.setUint16(32, blockAlign, Endian.little);
    buffer.setUint16(34, bitsPerSample, Endian.little);
    buffer.setUint8(36, 0x64);
    buffer.setUint8(37, 0x61);
    buffer.setUint8(38, 0x74);
    buffer.setUint8(39, 0x61); // data
    buffer.setUint32(40, dataSize, Endian.little);

    final result = buffer.buffer.asUint8List();
    for (int i = 0; i < dataSize; i++) {
      result[44 + i] = pcm[i];
    }
    return result;
  }

  // ── Parser ───────────────────────────────────────────

  static Map<String, dynamic> _parseReponse(String rawText) {
    // Normalise le markdown courant : **EXPERT:** → EXPERT:, **Expert :** → EXPERT:
    // On retire les ** et on ne garde que le label + deux-points + le reste.
    String normalized = rawText.replaceAllMapped(
      RegExp(r'\*+\s*(EXPERT|CURIEUX|FICHE|QCM|TITRE|CITATION|CHIFFRE|CORRECT)\s*:?\s*\*+\s*:?',
          caseSensitive: false),
      (m) => '${m.group(1)!.toUpperCase()}:',
    );

    // Détection des labels qui matchent en insensible à la casse (au cas où
    // Gemini écrit "Expert:" ou "expert:" au lieu de "EXPERT:")
    final labelExpert = RegExp(r'^EXPERT\s*:', caseSensitive: false);
    final labelCurieux = RegExp(r'^CURIEUX\s*:', caseSensitive: false);
    final labelFiche = RegExp(r'^FICHE\s*:?\s*$', caseSensitive: false);
    final labelQcm = RegExp(r'^QCM\s*:?\s*$', caseSensitive: false);
    final labelTitre = RegExp(r'^TITRE\s*:', caseSensitive: false);
    final labelCitation = RegExp(r'^CITATION\s*:', caseSensitive: false);
    final labelChiffre = RegExp(r'^CHIFFRE\s*:', caseSensitive: false);
    final labelCorrect = RegExp(r'^CORRECT\s*:', caseSensitive: false);
    final labelQ = RegExp(r'^Q\s*:', caseSensitive: false);
    final labelAnswer = RegExp(r'^[ABC]\s*:', caseSensitive: false);

    final lines = normalized.split('\n');
    final script = <Replique>[];
    final pointsCles = <String>[];
    String citation = '';
    String chiffre = '';
    final qcm = <Map<String, dynamic>>[];
    Map<String, dynamic>? qcmCurrent;
    String titre = '';
    String mode = 'script';

    // État pour agréger les lignes suivantes d'une réplique dont le label
    // était seul sur sa ligne (ex: "EXPERT:\nDepuis des siècles...").
    String? pendingVoice;
    final pendingText = StringBuffer();

    void flushPending() {
      if (pendingVoice != null && pendingText.isNotEmpty) {
        script.add(Replique(
          voice: pendingVoice!,
          text: pendingText.toString().trim(),
        ));
      }
      pendingVoice = null;
      pendingText.clear();
    }

    for (var raw in lines) {
      final line = raw.trim();
      if (line.isEmpty) continue;

      // Changements de mode
      if (labelFiche.hasMatch(line)) {
        flushPending();
        mode = 'fiche';
        continue;
      }
      if (labelQcm.hasMatch(line)) {
        flushPending();
        mode = 'qcm';
        continue;
      }
      if (labelTitre.hasMatch(line)) {
        flushPending();
        titre = line.replaceFirst(labelTitre, '').trim();
        continue;
      }

      if (mode == 'script') {
        if (labelExpert.hasMatch(line)) {
          flushPending();
          final inline = line.replaceFirst(labelExpert, '').trim();
          pendingVoice = 'expert';
          if (inline.isNotEmpty) pendingText.write(inline);
        } else if (labelCurieux.hasMatch(line)) {
          flushPending();
          final inline = line.replaceFirst(labelCurieux, '').trim();
          pendingVoice = 'learner';
          if (inline.isNotEmpty) pendingText.write(inline);
        } else if (pendingVoice != null) {
          // Continuation de la réplique courante sur la ligne suivante
          if (pendingText.isNotEmpty) pendingText.write(' ');
          pendingText.write(line);
        }
      } else if (mode == 'fiche') {
        if (line.startsWith('- ')) {
          pointsCles.add(line.substring(2).trim());
        } else if (line.startsWith('* ')) {
          pointsCles.add(line.substring(2).trim());
        } else if (labelCitation.hasMatch(line)) {
          citation = line.replaceFirst(labelCitation, '').trim();
        } else if (labelChiffre.hasMatch(line)) {
          chiffre = line.replaceFirst(labelChiffre, '').trim();
        }
      } else if (mode == 'qcm') {
        if (labelQ.hasMatch(line)) {
          if (qcmCurrent != null) qcm.add(qcmCurrent);
          qcmCurrent = {
            'question': line.replaceFirst(labelQ, '').trim(),
            'reponses': <String>[],
            'correct': 0,
          };
        } else if (labelAnswer.hasMatch(line)) {
          qcmCurrent?['reponses'].add(line.replaceFirst(labelAnswer, '').trim());
        } else if (labelCorrect.hasMatch(line)) {
          final letter = line.replaceFirst(labelCorrect, '').trim().toUpperCase();
          if (letter.isNotEmpty) {
            qcmCurrent?['correct'] = letter.codeUnitAt(0) - 'A'.codeUnitAt(0);
          }
        }
      }
    }
    flushPending();
    if (qcmCurrent != null) qcm.add(qcmCurrent);

    return {
      'script': script,
      'titre': titre.isNotEmpty ? titre : null,
      'fiche': pointsCles.isNotEmpty
          ? {
              'points_cles': pointsCles,
              'citation': citation,
              'chiffre_choc': chiffre,
            }
          : null,
      'qcm': qcm.isNotEmpty ? qcm : null,
    };
  }

  // ── Builder prompt ───────────────────────────────────

  static String _buildScriptPrompt({
    required String sujet,
    required int duree,
    required int partie,
    required int totalParties,
    required PlanBloc planBloc,
    required int motsCible,
    required String resumeContexte,
  }) {
    final contexteStr = resumeContexte.isNotEmpty
        ? '\nCONTEXTE DES PARTIES PRÉCÉDENTES (ne pas répéter, mais construire dessus) :\n$resumeContexte\n'
        : '';

    String position = '';
    if (totalParties > 1) {
      if (partie == 1) {
        position =
            'C\'est la PREMIÈRE partie : accroche forte, pose le contexte, crée l\'envie d\'écouter la suite.';
      } else if (partie == totalParties) {
        position =
            'C\'est la DERNIÈRE partie : conclus de manière mémorable, ouvre sur les enjeux contemporains.';
      } else {
        position =
            'C\'est la partie $partie/$totalParties : approfondis, ne répète pas ce qui précède.';
      }
    }

    final ficheQcm = partie == totalParties
        ? '''

Après le dialogue, ajoute obligatoirement :

FICHE:
- point cle 1 (concept central développé)
- point cle 2 (argument ou fait marquant)
- point cle 3 (enjeu ou perspective)
CITATION: une citation d'auteur mentionné dans le podcast
CHIFFRE: un chiffre ou date clé cité dans le podcast

QCM:
Q: question 1 basée sur le podcast
A: bonne reponse
B: mauvaise reponse
C: mauvaise reponse
CORRECT: A
Q: question 2
A: mauvaise reponse
B: bonne reponse
C: mauvaise reponse
CORRECT: B
Q: question 3
A: bonne reponse
B: mauvaise reponse
C: mauvaise reponse
CORRECT: A
Q: question 4
A: mauvaise reponse
B: mauvaise reponse
C: bonne reponse
CORRECT: C
Q: question 5
A: bonne reponse
B: mauvaise reponse
C: mauvaise reponse
CORRECT: A
'''
        : '';

    return '''
Sujet global du podcast : $sujet
$position

SECTION À COUVRIR DANS CETTE PARTIE :
Titre : ${planBloc.titre}
Contenu : ${planBloc.description}
$contexteStr
CONTRAINTE DE VOLUME :
- Cette partie dure $duree minutes à l'oral.
- Le texte total des répliques DOIT contenir entre ${motsCible - 50} et ${motsCible + 50} mots.
- À raison de 145 mots/minute, $duree minutes = $motsCible mots.
- COMPTE tes mots. NE T'ARRÊTE PAS avant d'avoir atteint $motsCible mots.
- L'Expert doit développer chaque argument sur plusieurs échanges.

Format de sortie STRICT (rien d'autre) :

EXPERT: [80 à 150 mots — développe un argument complet avec exemples et références]
CURIEUX: [20 à 50 mots — relance, nuance, ou challenge]
EXPERT: [80 à 150 mots]
...
$ficheQcm
''';
  }
}
