import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:hive_ce_flutter/hive_flutter.dart';
import 'package:path_provider/path_provider.dart';

import 'gemini_service.dart';
import 'podcast_service.dart';

/// Résultat d'une opération de nettoyage.
class CleanupReport {
  final int filesDeleted;
  final int bytesFreed;
  final int dirsDeleted;
  const CleanupReport({
    required this.filesDeleted,
    required this.bytesFreed,
    required this.dirsDeleted,
  });

  static const empty = CleanupReport(filesDeleted: 0, bytesFreed: 0, dirsDeleted: 0);

  String get humanBytes {
    if (bytesFreed < 1024) return '$bytesFreed B';
    if (bytesFreed < 1024 * 1024) {
      return '${(bytesFreed / 1024).toStringAsFixed(1)} KB';
    }
    if (bytesFreed < 1024 * 1024 * 1024) {
      return '${(bytesFreed / 1024 / 1024).toStringAsFixed(1)} MB';
    }
    return '${(bytesFreed / 1024 / 1024 / 1024).toStringAsFixed(2)} GB';
  }
}

/// Stockage local des podcasts générés (historique).
///
/// Implémentation :
/// - Hive CE, une seule box `podcasts_history`.
/// - Chaque session est stockée comme String JSON, clé = session.id.
/// - On migre plus tard vers Supabase en uploadant le même JSON.
class HistoryService {
  static const _boxName = 'podcasts_history';
  static Box<String>? _box;

  /// À appeler UNE fois au démarrage de l'app (dans main.dart) avant
  /// toute utilisation de HistoryService.
  static Future<void> init() async {
    await Hive.initFlutter();
    _box = await Hive.openBox<String>(_boxName);
    debugPrint('📚 HistoryService : box ouverte (${_box!.length} sessions)');
  }

  static Box<String> get _b {
    final b = _box;
    if (b == null) {
      throw StateError(
          'HistoryService.init() doit être appelé avant utilisation');
    }
    return b;
  }

  /// Sauvegarde / met à jour une session.
  static Future<void> save(PodcastSession session) async {
    try {
      final json = jsonEncode(session.toJson());
      await _b.put(session.id, json);
      debugPrint(
          '💾 Session sauvegardée : ${session.id} ("${session.titre}")');
      // Invalide le cache de suggestions de la catégorie concernée :
      // un sujet vient d'être "consommé", on ne veut pas le re-proposer
      // au prochain tap sur la catégorie.
      if (session.categorie != null) {
        GeminiService.invalidateCache(categorie: session.categorie);
      }
    } catch (e, st) {
      debugPrint('❌ Erreur sauvegarde session ${session.id} : $e\n$st');
    }
  }

  /// Met à jour juste la position de lecture d'une session existante.
  /// Plus légère que `save()` : ne log pas, utilisée fréquemment (toutes
  /// les ~5s pendant la lecture + à la pause + au changement de chapitre).
  /// Silencieuse si la session n'existe pas (cas d'une génération en cours
  /// qui n'a pas encore appelé save()).
  static Future<void> updatePosition(
    String id, {
    required int chapterIdx,
    required int positionMs,
  }) async {
    try {
      final existing = loadOne(id);
      if (existing == null) return;
      final updated = existing.copyWith(
        lastChapterIdx: chapterIdx,
        lastPositionMs: positionMs,
      );
      final json = jsonEncode(updated.toJson());
      await _b.put(id, json);
    } catch (e) {
      debugPrint('⚠️ updatePosition($id) : $e');
    }
  }

  /// Retourne toutes les sessions, triées de la plus récente à la plus ancienne.
  static List<PodcastSession> loadAll() {
    final sessions = <PodcastSession>[];
    for (final key in _b.keys) {
      final raw = _b.get(key);
      if (raw == null) continue;
      try {
        final json = jsonDecode(raw) as Map<String, dynamic>;
        sessions.add(PodcastSession.fromJson(json));
      } catch (e) {
        debugPrint('⚠️ Session corrompue (clé $key) : $e');
      }
    }
    sessions.sort((a, b) => b.createdAt.compareTo(a.createdAt));
    return sessions;
  }

  /// Charge une session précise, ou null si introuvable.
  static PodcastSession? loadOne(String id) {
    final raw = _b.get(id);
    if (raw == null) return null;
    try {
      return PodcastSession.fromJson(jsonDecode(raw) as Map<String, dynamic>);
    } catch (e) {
      debugPrint('⚠️ Session corrompue ($id) : $e');
      return null;
    }
  }

  /// Retourne tous les sujets déjà générés pour une catégorie donnée.
  /// Utilisé par les suggestions Gemini pour éviter de re-proposer
  /// des sujets que l'utilisateur a déjà écoutés.
  ///
  /// Ne tient compte que des sessions qui ont au moins un chapitre `ready`
  /// — un podcast qui a foiré dès le début ne "consomme" pas son sujet.
  static List<String> getSubjectsByCategory(String categorie) {
    final subjects = <String>[];
    for (final session in loadAll()) {
      if (session.categorie != categorie) continue;
      // Au moins un chapitre généré pour considérer que le sujet a été "consommé"
      if (!session.chapters.any((c) => c.status == ChapterStatus.ready)) {
        continue;
      }
      subjects.add(session.sujet);
    }
    return subjects;
  }

  /// Supprime une session et ses fichiers audio associés.
  static Future<void> delete(String id) async {
    final session = loadOne(id);
    if (session != null) {
      // Supprime les WAV (best-effort)
      for (final ch in session.chapters) {
        final path = ch.wavPath;
        if (path != null) {
          try {
            final f = File(path);
            if (await f.exists()) await f.delete();
          } catch (_) {}
        }
      }
      // Essaie aussi de retirer le dossier de session (vide à ce stade)
      await _tryDeleteSessionDir(session);
    }
    await _b.delete(id);
    debugPrint('🗑 Session supprimée : $id');
  }

  /// Supprime TOUT : toutes les sessions de Hive + tous les WAV sur disque,
  /// même les orphelins. Retourne des stats pour affichage UI.
  static Future<CleanupReport> deleteAll() async {
    int filesDeleted = 0;
    int bytesFreed = 0;
    int dirsDeleted = 0;

    // 1. Suppression récursive de tous les dossiers podcast_*
    //    (plus simple et plus sûr que de boucler sur les sessions connues :
    //    ça nettoie aussi les orphelins d'un seul coup)
    try {
      final docs = await getApplicationDocumentsDirectory();
      await for (final entity in docs.list(followLinks: false)) {
        final name = entity.path.split(Platform.pathSeparator).last;
        if (!name.startsWith('podcast_')) continue;
        if (entity is Directory) {
          final stats = await _dirStats(entity);
          filesDeleted += stats.$1;
          bytesFreed += stats.$2;
          try {
            await entity.delete(recursive: true);
            dirsDeleted++;
          } catch (e) {
            debugPrint('⚠️ Impossible de supprimer ${entity.path} : $e');
          }
        }
      }
    } catch (e) {
      debugPrint('❌ deleteAll filesystem : $e');
    }

    // 2. Vide la box Hive
    try {
      await _b.clear();
    } catch (e) {
      debugPrint('❌ deleteAll Hive : $e');
    }

    final report = CleanupReport(
      filesDeleted: filesDeleted,
      bytesFreed: bytesFreed,
      dirsDeleted: dirsDeleted,
    );
    debugPrint(
        '🧹 Nettoyage complet : $dirsDeleted dossiers, $filesDeleted fichiers, ${report.humanBytes} libérés');
    return report;
  }

  /// Nettoie les WAV orphelins : dossiers podcast_* sur disque qui ne
  /// correspondent à aucune session dans Hive. À appeler au démarrage.
  ///
  /// Ne touche JAMAIS aux WAV référencés par une session de l'historique.
  static Future<CleanupReport> cleanupOrphans() async {
    int filesDeleted = 0;
    int bytesFreed = 0;
    int dirsDeleted = 0;

    try {
      // Collecte les chemins de WAV connus (référencés dans Hive)
      final knownPaths = <String>{};
      for (final session in loadAll()) {
        for (final ch in session.chapters) {
          if (ch.wavPath != null) knownPaths.add(ch.wavPath!);
        }
      }

      // Pour chaque dossier podcast_* sur disque, on vérifie si AU MOINS
      // UN de ses WAV est connu. Si aucun n'est connu, tout le dossier est
      // orphelin → on supprime.
      final docs = await getApplicationDocumentsDirectory();
      await for (final entity in docs.list(followLinks: false)) {
        final name = entity.path.split(Platform.pathSeparator).last;
        if (!name.startsWith('podcast_')) continue;
        if (entity is! Directory) continue;

        bool hasKnown = false;
        await for (final f in entity.list(followLinks: false)) {
          if (knownPaths.contains(f.path)) {
            hasKnown = true;
            break;
          }
        }
        if (hasKnown) continue;

        final stats = await _dirStats(entity);
        filesDeleted += stats.$1;
        bytesFreed += stats.$2;
        try {
          await entity.delete(recursive: true);
          dirsDeleted++;
          debugPrint('🧹 Orphelin supprimé : ${entity.path}');
        } catch (e) {
          debugPrint('⚠️ Impossible de supprimer ${entity.path} : $e');
        }
      }
    } catch (e) {
      debugPrint('❌ cleanupOrphans : $e');
    }

    final report = CleanupReport(
      filesDeleted: filesDeleted,
      bytesFreed: bytesFreed,
      dirsDeleted: dirsDeleted,
    );
    if (dirsDeleted > 0) {
      debugPrint(
          '🧹 Orphelins nettoyés : $dirsDeleted dossiers, ${report.humanBytes}');
    } else {
      debugPrint('🧹 Pas d\'orphelins à nettoyer');
    }
    return report;
  }

  /// Retourne la taille totale sur disque des WAV connus (référencés par
  /// l'historique). Utile pour afficher à l'utilisateur.
  static Future<int> getAudioDiskUsageBytes() async {
    int total = 0;
    for (final session in loadAll()) {
      for (final ch in session.chapters) {
        final path = ch.wavPath;
        if (path == null) continue;
        try {
          final f = File(path);
          if (await f.exists()) {
            total += await f.length();
          }
        } catch (_) {}
      }
    }
    return total;
  }

  // ── Helpers internes ───────────────────────────────

  /// Retourne (nombre de fichiers, somme des tailles) d'un dossier.
  static Future<(int, int)> _dirStats(Directory dir) async {
    int count = 0;
    int bytes = 0;
    try {
      await for (final f in dir.list(recursive: true, followLinks: false)) {
        if (f is File) {
          count++;
          try {
            bytes += await f.length();
          } catch (_) {}
        }
      }
    } catch (_) {}
    return (count, bytes);
  }

  /// Tente de supprimer le dossier parent commun des WAV d'une session.
  static Future<void> _tryDeleteSessionDir(PodcastSession session) async {
    final paths = session.chapters
        .map((c) => c.wavPath)
        .whereType<String>()
        .toList();
    if (paths.isEmpty) return;
    // Tous les WAV d'une session sont dans le même dossier parent
    final parent = Directory(paths.first).parent;
    try {
      if (await parent.exists()) {
        final remaining = parent.listSync();
        if (remaining.isEmpty) {
          await parent.delete();
        }
      }
    } catch (_) {}
  }
}

