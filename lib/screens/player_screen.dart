import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:just_audio/just_audio.dart';
import '../services/history_service.dart';
import '../services/podcast_service.dart';
import '../theme.dart';

class PlayerScreen extends StatefulWidget {
  /// Notifier maintenu par PodcastService. Sa `.value` est toujours la
  /// session la plus récente, même au moment où le player s'abonne.
  /// Le player est responsable de le dispose() quand il est terminé.
  final ValueNotifier<PodcastSession> sessionNotifier;

  const PlayerScreen({
    super.key,
    required this.sessionNotifier,
  });

  @override
  State<PlayerScreen> createState() => _PlayerScreenState();
}

class _PlayerScreenState extends State<PlayerScreen> {
  late AudioPlayer _player;

  /// Index du chapitre actuellement chargé dans le player (au sens de notre
  /// liste de Chapter). -1 si rien chargé.
  int _currentChapterIdx = -1;

  PodcastSession _session = _stub();

  bool _isPlaying = false;
  Duration _position = Duration.zero;
  Duration _duration = Duration.zero;
  double _speed = 1.0;
  int _onglet = 0; // 0 = player, 1 = fiche, 2 = qcm

  /// Vrai si le player est en pause parce que le prochain chapitre
  /// n'est pas encore prêt (rattrapage de la génération).
  bool _waitingForNextChapter = false;

  /// Vrai dès que le premier chapitre a été chargé avec succès.
  /// Avant ce flag, on ignore les events `completed` du player (qui sont
  /// des résidus de l'état initial vide / des transitions entre setFilePath).
  bool _firstChapterLoaded = false;

  /// Vrai pendant qu'un chapitre est en cours de chargement (entre stop()
  /// et play()). Pendant cette fenêtre, ExoPlayer peut émettre un
  /// `completed` parasite hérité de l'état du fichier précédent — on
  /// l'ignore pour éviter de sauter un chapitre.
  bool _isLoadingChapter = false;

  /// Position à appliquer au chargement du premier chapitre (reprise depuis
  /// l'historique). Consommé une seule fois dans _loadAndPlayChapter.
  int? _pendingResumePositionMs;

  /// Timer de sauvegarde périodique de la position (toutes les 5s pendant
  /// la lecture, pour que si l'user tue l'app on ne perde qu'au max 5s).
  Timer? _positionSaveTimer;

  static const _speeds = [1.0, 1.25, 1.5, 1.75, 2.0, 2.5];

  static PodcastSession _stub() => PodcastSession.initial('', 0);

  @override
  void initState() {
    super.initState();
    _session = widget.sessionNotifier.value;
    _player = AudioPlayer();
    widget.sessionNotifier.addListener(_onSessionChanged);
    _init();
  }

  Future<void> _init() async {
    // Listeners audio
    _player.positionStream.listen((p) {
      if (mounted) setState(() => _position = p);
    });
    _player.durationStream.listen((d) {
      if (d != null && mounted) setState(() => _duration = d);
    });
    _player.playerStateStream.listen((state) {
      if (!mounted) return;
      setState(() => _isPlaying = state.playing);
      debugPrint(
          '🎛  playerState: playing=${state.playing} processing=${state.processingState}');
      if (state.processingState == ProcessingState.completed) {
        // Garde anti-race au démarrage : ignore les `completed` parasites
        // émis avant que le premier chapitre soit vraiment chargé.
        if (!_firstChapterLoaded) {
          debugPrint('   (completed ignoré : premier chapitre pas encore chargé)');
          return;
        }
        // Garde anti-saut : pendant un chargement (stop+setFilePath),
        // ExoPlayer peut émettre un completed hérité du fichier précédent.
        // On l'ignore pour ne pas enchaîner d'un coup vers le N+2.
        if (_isLoadingChapter) {
          debugPrint('   (completed ignoré : chargement en cours)');
          return;
        }
        _onCurrentChapterFinished();
      }
    });

    // Détermine quel chapitre charger au démarrage :
    // - Si la session a un `lastChapterIdx` et que ce chapitre est prêt,
    //   on reprend là-bas (avec la position mémorisée)
    // - Sinon on charge le premier chapitre prêt depuis le début
    int? targetIdx;
    final saved = _session.lastChapterIdx;
    if (saved != null &&
        saved >= 0 &&
        saved < _session.chapters.length &&
        _session.chapters[saved].status == ChapterStatus.ready &&
        _session.chapters[saved].wavPath != null) {
      targetIdx = saved;
      _pendingResumePositionMs = _session.lastPositionMs;
      debugPrint(
          '⏯  Reprise : chapitre ${saved + 1} à ${_session.lastPositionMs}ms');
    } else {
      targetIdx = _firstReadyChapterIndex();
    }

    if (targetIdx != null) {
      debugPrint('🚀 _init() charge chapitre ${targetIdx + 1}');
      await _loadAndPlayChapter(targetIdx);
    } else {
      debugPrint('⚠️ Aucun chapitre prêt au démarrage du player');
    }

    // Sauvegarde périodique de la position (seulement pendant la lecture)
    _positionSaveTimer = Timer.periodic(
      const Duration(seconds: 5),
      (_) => _saveCurrentPosition(),
    );
  }

  /// Écrit la position actuelle dans Hive. No-op si rien à sauver
  /// (pas de chapitre chargé / durée inconnue).
  void _saveCurrentPosition() {
    if (_currentChapterIdx < 0) return;
    if (_session.id.isEmpty) return;
    HistoryService.updatePosition(
      _session.id,
      chapterIdx: _currentChapterIdx,
      positionMs: _position.inMilliseconds,
    );
  }

  /// Listener du ValueNotifier — toujours appelé avec la session la plus
  /// récente, accessible aussi via widget.sessionNotifier.value.
  void _onSessionChanged() {
    if (!mounted) return;
    final session = widget.sessionNotifier.value;
    setState(() => _session = session);
    debugPrint(
        '🎛  session update : ${_readyChaptersCount()}/${session.chapters.length} chapitres prêts');

    // Si on attendait un chapitre et qu'il vient d'arriver → relance
    if (_waitingForNextChapter) {
      final next = _currentChapterIdx + 1;
      if (next < session.chapters.length &&
          session.chapters[next].status == ChapterStatus.ready) {
        debugPrint(
            '▶️  Reprise après attente : chapitre ${next + 1} dispo (depuis _onSessionChanged)');
        _waitingForNextChapter = false;
        _loadAndPlayChapter(next);
      }
    }
  }

  int? _firstReadyChapterIndex() {
    for (int i = 0; i < _session.chapters.length; i++) {
      if (_session.chapters[i].status == ChapterStatus.ready &&
          _session.chapters[i].wavPath != null) {
        return i;
      }
    }
    return null;
  }

  int _readyChaptersCount() => _session.chapters
      .where((c) => c.status == ChapterStatus.ready)
      .length;

  /// Charge le chapitre [idx] dans le player et démarre la lecture.
  ///
  /// L'index UI est mis à jour IMMÉDIATEMENT (avant les awaits) pour que
  /// le titre du chapitre change sans délai visible. Le marqueur
  /// `_firstChapterLoaded` est aussi mis à true tout de suite — les vrais
  /// `completed` qu'on veut filtrer sont ceux émis par l'état initial du
  /// player AVANT toute demande de chargement, donc marquer le flag au
  /// début du premier chargement est suffisant et évite une race.
  Future<void> _loadAndPlayChapter(int idx) async {
    debugPrint('🎯 _loadAndPlayChapter($idx) appelé. État actuel : '
        'currentChapterIdx=$_currentChapterIdx, '
        'firstChapterLoaded=$_firstChapterLoaded, '
        'waitingForNextChapter=$_waitingForNextChapter');
    if (idx < 0 || idx >= _session.chapters.length) {
      debugPrint('❌ _loadAndPlayChapter($idx) : index hors limite');
      return;
    }
    final chapter = _session.chapters[idx];
    if (chapter.status != ChapterStatus.ready || chapter.wavPath == null) {
      debugPrint(
          '❌ _loadAndPlayChapter($idx) : chapitre pas prêt (status=${chapter.status})');
      return;
    }

    // Vérification que le WAV existe toujours sur disque. Le cas "fichier
    // manquant" peut arriver après un nettoyage manuel de l'historique ou
    // si l'app a été désinstallée/réinstallée entre-temps.
    final wavFile = File(chapter.wavPath!);
    if (!wavFile.existsSync()) {
      debugPrint(
          '❌ WAV manquant pour ch${idx + 1} : ${chapter.wavPath}');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'Fichier audio du chapitre ${idx + 1} introuvable. '
              'Ce podcast a probablement été nettoyé.',
            ),
            duration: const Duration(seconds: 4),
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
      return;
    }

    // Évite les doubles-chargements quand l'enchaînement auto et l'action
    // utilisateur se déclenchent en parallèle sur le même chapitre
    if (_currentChapterIdx == idx && _firstChapterLoaded) {
      debugPrint('↪️  Chapitre ${idx + 1} déjà en cours de chargement');
      return;
    }

    // MISE À JOUR UI IMMÉDIATE : le titre et le numéro de chapitre changent
    // avant les awaits pour éviter l'effet "il faut cliquer 2 fois".
    // Avant de switch, on flush la position du chapitre sortant (sauf au
    // tout premier chargement, où _currentChapterIdx == -1).
    if (_firstChapterLoaded && _currentChapterIdx >= 0 && _currentChapterIdx != idx) {
      _saveCurrentPosition();
    }
    if (mounted) {
      setState(() {
        _currentChapterIdx = idx;
        _firstChapterLoaded = true;
      });
    }

    try {
      debugPrint('📥 Chargement chapitre ${idx + 1} depuis ${chapter.wavPath}');
      _isLoadingChapter = true;
      // Stop explicite avant de charger le nouveau fichier.
      // Sans ça, si on enchaîne depuis un état 'completed', just_audio
      // peut laisser le player dans un état bizarre où il "joue" mais
      // saute directement à la fin du nouveau fichier.
      await _player.stop();
      await _player.setFilePath(chapter.wavPath!);
      await _player.setSpeed(_speed);
      // Position de départ : soit la reprise depuis l'historique (premier
      // chargement uniquement), soit 0 (changement manuel ou auto de chapitre)
      final startMs = _pendingResumePositionMs ?? 0;
      _pendingResumePositionMs = null; // Consommé une seule fois
      await _player.seek(Duration(milliseconds: startMs));
      // ATTENTION : on ne doit PAS `await _player.play()`. Sur certains
      // devices (Android / ExoPlayer), `play()` ne retourne qu'à la fin
      // du fichier (au lieu de retourner dès le démarrage). Du coup le
      // `finally` qui remet `_isLoadingChapter = false` ne s'exécute qu'à
      // la fin du chapitre, et le `completed` réel est ignoré → l'auto-
      // enchaînement ne se fait jamais.
      // Solution : fire-and-forget. Le `play()` lance la lecture, on
      // remet le flag tout de suite, et l'event completed naturel pourra
      // être traité.
      // ignore: unawaited_futures
      _player.play();
      debugPrint('▶️  Lecture chapitre ${idx + 1} démarrée'
          '${startMs > 0 ? " (reprise à ${startMs}ms)" : ""}');
    } catch (e) {
      debugPrint('❌ Erreur chargement chapitre ${idx + 1} : $e');
    } finally {
      _isLoadingChapter = false;
    }
  }

  /// Appelé quand le chapitre courant termine sa lecture.
  /// Décide : enchaîner le suivant si prêt, ou attendre.
  Future<void> _onCurrentChapterFinished() async {
    final nextIdx = _currentChapterIdx + 1;
    // Toujours lire la session la plus à jour via le notifier
    final session = widget.sessionNotifier.value;
    final totalPlanned = session.chapters.length;

    if (nextIdx >= totalPlanned) {
      debugPrint(
          '🏁 Fin du podcast (chapitre ${_currentChapterIdx + 1}/$totalPlanned)');
      return;
    }

    final nextChapter = session.chapters[nextIdx];
    if (nextChapter.status == ChapterStatus.ready &&
        nextChapter.wavPath != null) {
      debugPrint(
          '⏭  Enchaînement chapitre ${_currentChapterIdx + 1} → ${nextIdx + 1} (depuis _onCurrentChapterFinished)');
      await _loadAndPlayChapter(nextIdx);
    } else if (nextChapter.status == ChapterStatus.error) {
      debugPrint('⚠️  Chapitre ${nextIdx + 1} en erreur, on saute au suivant');
      _currentChapterIdx = nextIdx;
      await _onCurrentChapterFinished();
    } else {
      debugPrint(
          '⏸  En attente du chapitre ${nextIdx + 1} (status=${nextChapter.status})');
      if (mounted) setState(() => _waitingForNextChapter = true);
    }
  }

  // ── Navigation inter-chapitres ──────────────────────

  bool _canGoToPreviousChapter() => _currentChapterIdx > 0;

  bool _canGoToNextChapter() {
    final next = _currentChapterIdx + 1;
    final session = widget.sessionNotifier.value;
    return next < session.chapters.length &&
        session.chapters[next].status == ChapterStatus.ready;
  }

  Future<void> _goToPreviousChapter() async {
    if (!_canGoToPreviousChapter()) return;
    final prev = _currentChapterIdx - 1;
    debugPrint('⏪ Retour au chapitre ${prev + 1} (manuel)');
    setState(() => _waitingForNextChapter = false);
    await _loadAndPlayChapter(prev);
  }

  Future<void> _goToNextChapter() async {
    if (!_canGoToNextChapter()) return;
    final next = _currentChapterIdx + 1;
    debugPrint('⏩ Avance au chapitre ${next + 1} (manuel)');
    setState(() => _waitingForNextChapter = false);
    await _loadAndPlayChapter(next);
  }

  @override
  void dispose() {
    // IMPORTANT : on ne dispose PAS le notifier ici. Le notifier est la
    // propriété de PodcastService (côté generer()) et peut être encore
    // en cours d'alimentation par la pipeline qui tourne en background.
    // Le disposer ici ferait crasher les futurs `notifier.value = ...` de
    // la pipeline, et on perdrait les chapitres non encore générés.
    // Si la session vient de l'historique (pas de pipeline en cours), le
    // notifier reste en mémoire jusqu'à ce que le GC le ramasse — pas
    // de fuite significative, c'est un petit objet.
    _positionSaveTimer?.cancel();
    _saveCurrentPosition(); // Flush final avant de partir
    widget.sessionNotifier.removeListener(_onSessionChanged);
    _player.dispose();
    super.dispose();
  }

  String _formatDuration(Duration d) {
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  void _cycleSpeed() {
    final idx = _speeds.indexOf(_speed);
    setState(() => _speed = _speeds[(idx + 1) % _speeds.length]);
    _player.setSpeed(_speed);
  }

  /// Nombre de chapitres en cours (script ou audio)
  int get _chaptersInProgress => _session.chapters
      .where((c) =>
          c.status == ChapterStatus.generatingScript ||
          c.status == ChapterStatus.generatingAudio)
      .length;

  /// Nombre de chapitres restants à générer (pending + in progress)
  int get _chaptersRemaining => _session.chapters
      .where((c) =>
          c.status != ChapterStatus.ready && c.status != ChapterStatus.error)
      .length;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: KnowNowColors.background,
      body: SafeArea(
        child: Column(
          children: [
            _buildHeader(),
            _buildOnglets(),
            Expanded(
              child: _onglet == 0
                  ? _buildPlayer()
                  : _onglet == 1
                      ? _buildFiche()
                      : _buildQcm(),
            ),
          ],
        ),
      ),
    );
  }

  // ── Header ──────────────────────────────────────────
  Widget _buildHeader() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 0),
      child: Row(
        children: [
          GestureDetector(
            onTap: () async {
              await _player.stop();
              if (mounted) Navigator.pop(context);
            },
            child: const Icon(Icons.arrow_back_ios,
                color: Colors.white54, size: 20),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              _session.titre.isNotEmpty ? _session.titre : _session.sujet,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 16,
                fontWeight: FontWeight.w700,
              ),
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }

  // ── Onglets ─────────────────────────────────────────
  Widget _buildOnglets() {
    const onglets = ['▶  Lecture', '📋  Fiche', '🧪  QCM'];
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 20, 20, 0),
      child: Row(
        children: List.generate(onglets.length, (i) {
          final isActive = _onglet == i;
          return Expanded(
            child: GestureDetector(
              onTap: () => setState(() => _onglet = i),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 150),
                margin: const EdgeInsets.only(right: 8),
                padding: const EdgeInsets.symmetric(vertical: 10),
                decoration: BoxDecoration(
                  color: isActive ? KnowNowColors.accentViolet : Colors.white10,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  onglets[i],
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 12,
                    color: isActive ? Colors.white : Colors.white54,
                    fontWeight: isActive ? FontWeight.w700 : FontWeight.normal,
                  ),
                ),
              ),
            ),
          );
        }),
      ),
    );
  }

  // ── Player ──────────────────────────────────────────
  Widget _buildPlayer() {
    final progress = _duration.inSeconds > 0
        ? _position.inSeconds / _duration.inSeconds
        : 0.0;

    final totalChapters = _session.chapters.length;
    final displayIdx = _currentChapterIdx >= 0 ? _currentChapterIdx : 0;
    final currentChapterDisplay =
        totalChapters > 0 ? '${displayIdx + 1} / $totalChapters' : '';
    final currentTitle = (displayIdx < _session.chapters.length)
        ? _session.chapters[displayIdx].plan.titre
        : '';

    return Padding(
      padding: const EdgeInsets.all(32),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          // Badge chapitre courant
          if (totalChapters > 1) ...[
            Text(
              'CHAPITRE $currentChapterDisplay',
              style: const TextStyle(
                color: Colors.white38,
                fontSize: 10,
                letterSpacing: 2,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              currentTitle,
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 16,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 20),
          ],

          // Statut génération en arrière-plan
          _buildBackgroundStatus(),
          const SizedBox(height: 24),

          // Durée effective selon vitesse
          Text(
            'Durée à ${_speed}x : ${_formatDuration(
              Duration(seconds: (_duration.inSeconds / _speed).round()),
            )}',
            style: const TextStyle(color: Colors.white38, fontSize: 12),
          ),
          const SizedBox(height: 20),

          // Barre de progression
          GestureDetector(
            onTapDown: (details) {
              final box = context.findRenderObject() as RenderBox;
              final localPos = box.globalToLocal(details.globalPosition);
              final percent = (localPos.dx - 32) / (box.size.width - 64);
              final newPos = Duration(
                seconds: (_duration.inSeconds * percent.clamp(0, 1)).round(),
              );
              _player.seek(newPos);
            },
            child: Column(
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(4),
                  child: LinearProgressIndicator(
                    value: progress.clamp(0.0, 1.0),
                    minHeight: 6,
                    backgroundColor: Colors.white12,
                    valueColor: const AlwaysStoppedAnimation<Color>(
                      KnowNowColors.accentViolet,
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(_formatDuration(_position),
                        style: const TextStyle(
                            color: Colors.white38, fontSize: 12)),
                    Text(_formatDuration(_duration),
                        style: const TextStyle(
                            color: Colors.white38, fontSize: 12)),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(height: 32),

          // Navigation inter-chapitres
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              _buildChapterNavButton(
                icon: '⏪ Chap.',
                enabled: _canGoToPreviousChapter(),
                onTap: _goToPreviousChapter,
              ),
              _buildChapterNavButton(
                icon: 'Chap. ⏩',
                enabled: _canGoToNextChapter(),
                onTap: _goToNextChapter,
              ),
            ],
          ),
          const SizedBox(height: 20),

          // Contrôles principaux : -30s / play-pause / +30s
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              _buildControlButton(
                icon: '⏮ 30s',
                size: 16,
                onTap: () => _player.seek(
                  Duration(
                      seconds: (_position.inSeconds - 30)
                          .clamp(0, _duration.inSeconds)),
                ),
              ),
              GestureDetector(
                onTap: () {
                  if (_isPlaying) {
                    _player.pause();
                    _saveCurrentPosition(); // Flush à la pause
                  } else {
                    _player.play();
                  }
                },
                child: Container(
                  width: 72,
                  height: 72,
                  decoration: const BoxDecoration(
                    gradient: KnowNowColors.accentGradient,
                    shape: BoxShape.circle,
                  ),
                  child: Center(
                    child: Icon(
                      _isPlaying ? Icons.pause : Icons.play_arrow,
                      size: 36,
                      color: Colors.white,
                    ),
                  ),
                ),
              ),
              _buildControlButton(
                icon: '30s ⏭',
                size: 16,
                onTap: () => _player.seek(
                  Duration(
                      seconds: (_position.inSeconds + 30)
                          .clamp(0, _duration.inSeconds)),
                ),
              ),
            ],
          ),
          const SizedBox(height: 24),

          // Vitesse
          GestureDetector(
            onTap: _cycleSpeed,
            child: Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
              decoration: BoxDecoration(
                color: Colors.white10,
                borderRadius: BorderRadius.circular(20),
              ),
              child: Text(
                '⚡ ${_speed}x',
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// Affiche un petit badge indiquant ce qui se passe en arrière-plan
  Widget _buildBackgroundStatus() {
    if (_waitingForNextChapter) {
      return _statusPill(
        color: KnowNowColors.accentViolet,
        icon: '⏳',
        text: 'Chapitre suivant en cours de génération...',
      );
    }
    if (_session.allChaptersReady) {
      return _statusPill(
        color: const Color(0xFF2D6A4F).withOpacity(0.3),
        icon: '✓',
        text: 'Tous les chapitres sont prêts',
      );
    }
    final remaining = _chaptersRemaining;
    if (remaining > 0) {
      return _statusPill(
        color: Colors.white10,
        icon: '⚡',
        text: remaining == 1
            ? 'Dernier chapitre en cours...'
            : '$remaining chapitres en préparation',
      );
    }
    return const SizedBox.shrink();
  }

  Widget _statusPill(
      {required Color color, required String icon, required String text}) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(icon, style: const TextStyle(fontSize: 11)),
          const SizedBox(width: 6),
          Text(
            text,
            style: const TextStyle(
              color: Colors.white70,
              fontSize: 11,
              fontWeight: FontWeight.w500,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildControlButton({
    required String icon,
    required double size,
    required VoidCallback onTap,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: Colors.white10,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Text(icon, style: TextStyle(color: Colors.white, fontSize: size)),
      ),
    );
  }

  Widget _buildChapterNavButton({
    required String icon,
    required bool enabled,
    required VoidCallback onTap,
  }) {
    return GestureDetector(
      onTap: enabled ? onTap : null,
      child: AnimatedOpacity(
        duration: const Duration(milliseconds: 150),
        opacity: enabled ? 1.0 : 0.3,
        child: Container(
          padding:
              const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          decoration: BoxDecoration(
            color: Colors.white10,
            borderRadius: BorderRadius.circular(10),
          ),
          child: Text(
            icon,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 13,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      ),
    );
  }

  // ── Fiche ────────────────────────────────────────────
  Widget _buildFiche() {
    final fiche = _session.fiche;
    final points = List<String>.from(fiche['points_cles'] ?? []);
    final citation = (fiche['citation'] ?? '') as String;
    final chiffre = (fiche['chiffre_choc'] ?? '') as String;

    if (points.isEmpty && citation.isEmpty && chiffre.isEmpty) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(32),
          child: Text(
            'La fiche de synthèse sera disponible\nà la fin de la génération',
            textAlign: TextAlign.center,
            style: TextStyle(color: Colors.white54),
          ),
        ),
      );
    }

    return SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SizedBox(height: 8),
          if (points.isNotEmpty)
            _buildFicheSection(
              'POINTS CLÉS',
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: points
                    .asMap()
                    .entries
                    .map((e) => Padding(
                          padding: const EdgeInsets.only(bottom: 12),
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Container(
                                width: 24,
                                height: 24,
                                decoration: const BoxDecoration(
                                  color: KnowNowColors.accentViolet,
                                  shape: BoxShape.circle,
                                ),
                                child: Center(
                                  child: Text(
                                    '${e.key + 1}',
                                    style: const TextStyle(
                                        color: Colors.white,
                                        fontSize: 12,
                                        fontWeight: FontWeight.w700),
                                  ),
                                ),
                              ),
                              const SizedBox(width: 12),
                              Expanded(
                                child: Text(e.value,
                                    style: const TextStyle(
                                        color: Colors.white70,
                                        fontSize: 14,
                                        height: 1.5)),
                              ),
                            ],
                          ),
                        ))
                    .toList(),
              ),
            ),
          if (citation.isNotEmpty) ...[
            const SizedBox(height: 20),
            _buildFicheSection(
              'CITATION',
              Text(
                '« $citation »',
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 15,
                  fontStyle: FontStyle.italic,
                  height: 1.5,
                ),
              ),
            ),
          ],
          if (chiffre.isNotEmpty) ...[
            const SizedBox(height: 20),
            _buildFicheSection(
              'CHIFFRE CLÉ',
              Text(
                chiffre,
                style: const TextStyle(
                  color: KnowNowColors.accentViolet,
                  fontSize: 15,
                  fontWeight: FontWeight.w700,
                  height: 1.5,
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildFicheSection(String titre, Widget content) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          titre,
          style: const TextStyle(
            color: Colors.white38,
            fontSize: 11,
            letterSpacing: 2,
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 12),
        content,
      ],
    );
  }

  // ── QCM ─────────────────────────────────────────────
  Widget _buildQcm() {
    final qcm = _session.qcm;
    if (qcm.isEmpty) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(32),
          child: Text(
            'Le QCM sera disponible\nà la fin de la génération',
            textAlign: TextAlign.center,
            style: TextStyle(color: Colors.white54),
          ),
        ),
      );
    }
    return _QcmWidget(qcm: qcm);
  }
}

// ── Widget QCM interactif (inchangé) ─────────────────
class _QcmWidget extends StatefulWidget {
  final List<Map<String, dynamic>> qcm;
  const _QcmWidget({required this.qcm});

  @override
  State<_QcmWidget> createState() => _QcmWidgetState();
}

class _QcmWidgetState extends State<_QcmWidget> {
  int _questionIndex = 0;
  int? _reponseSelectionnee;
  int _score = 0;
  bool _termine = false;

  void _repondre(int index) {
    if (_reponseSelectionnee != null) return;
    setState(() => _reponseSelectionnee = index);
    if (index == widget.qcm[_questionIndex]['correct']) _score++;
  }

  void _suivant() {
    if (_questionIndex < widget.qcm.length - 1) {
      setState(() {
        _questionIndex++;
        _reponseSelectionnee = null;
      });
    } else {
      setState(() => _termine = true);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_termine) return _buildResultat();

    final q = widget.qcm[_questionIndex];
    final reponses = List<String>.from(q['reponses']);
    final correct = q['correct'] as int;

    return SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'QUESTION ${_questionIndex + 1} / ${widget.qcm.length}',
            style: const TextStyle(
                color: Colors.white38, fontSize: 11, letterSpacing: 2),
          ),
          const SizedBox(height: 16),
          LinearProgressIndicator(
            value: (_questionIndex + 1) / widget.qcm.length,
            backgroundColor: Colors.white12,
            valueColor:
                const AlwaysStoppedAnimation<Color>(KnowNowColors.accentViolet),
          ),
          const SizedBox(height: 24),
          Text(
            q['question'] as String,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 18,
              fontWeight: FontWeight.w600,
              height: 1.4,
            ),
          ),
          const SizedBox(height: 24),
          ...reponses.asMap().entries.map((e) {
            final i = e.key;
            final rep = e.value;
            Color bg = Colors.white10;
            Color border = Colors.transparent;

            if (_reponseSelectionnee != null) {
              if (i == correct) {
                bg = const Color(0xFF2D6A4F).withOpacity(0.3);
                border = const Color(0xFF2D6A4F);
              } else if (i == _reponseSelectionnee && i != correct) {
                bg = KnowNowColors.accentViolet.withOpacity(0.3);
                border = KnowNowColors.accentViolet;
              }
            }

            return GestureDetector(
              onTap: () => _repondre(i),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 200),
                margin: const EdgeInsets.only(bottom: 12),
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: bg,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: border, width: 1.5),
                ),
                child: Row(
                  children: [
                    Container(
                      width: 28,
                      height: 28,
                      decoration: BoxDecoration(
                        color: Colors.white10,
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: Center(
                        child: Text(
                          String.fromCharCode(65 + i),
                          style: const TextStyle(
                              color: Colors.white70,
                              fontWeight: FontWeight.w700),
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(rep,
                          style: const TextStyle(
                              color: Colors.white,
                              fontSize: 14,
                              height: 1.3)),
                    ),
                  ],
                ),
              ),
            );
          }),
          if (_reponseSelectionnee != null) ...[
            const SizedBox(height: 16),
            GestureDetector(
              onTap: _suivant,
              child: Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(vertical: 16),
                decoration: BoxDecoration(
                  color: KnowNowColors.accentViolet,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Text(
                  _questionIndex < widget.qcm.length - 1
                      ? 'Question suivante →'
                      : 'Voir les résultats',
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.w700,
                      fontSize: 15),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildResultat() {
    final pct = (_score / widget.qcm.length * 100).round();
    return Padding(
      padding: const EdgeInsets.all(32),
      child: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(
              '$_score / ${widget.qcm.length}',
              style: const TextStyle(
                color: Colors.white,
                fontSize: 56,
                fontWeight: FontWeight.w900,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              '$pct% de réussite',
              style:
                  const TextStyle(color: Colors.white54, fontSize: 16),
            ),
            const SizedBox(height: 32),
            Text(
              pct >= 80
                  ? '🏆 Excellent !'
                  : pct >= 60
                      ? '👍 Bien joué !'
                      : '📚 À retravailler',
              style: const TextStyle(fontSize: 24),
            ),
          ],
        ),
      ),
    );
  }
}
