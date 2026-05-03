import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../services/history_service.dart';
import '../services/podcast_service.dart';
import '../theme.dart';
import 'player_screen.dart';

class GenerationScreen extends ConsumerStatefulWidget {
  final String sujet;
  final int dureeMin;
  final String? categorie;
  final NiveauEditorial niveau;

  const GenerationScreen({
    super.key,
    required this.sujet,
    required this.dureeMin,
    this.categorie,
    this.niveau = NiveauEditorial.standard,
  });

  @override
  ConsumerState<GenerationScreen> createState() => _GenerationScreenState();
}

class _GenerationScreenState extends ConsumerState<GenerationScreen>
    with TickerProviderStateMixin {
  ValueNotifier<PodcastSession>? _sessionNotifier;

  double _progress = 0.0;
  String _etape = 'Initialisation...';
  bool _erreur = false;
  String _messageErreur = '';
  bool _handedOffToPlayer = false;

  late AnimationController _pulseController;
  late Animation<double> _pulseAnimation;

  @override
  void initState() {
    super.initState();

    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 2),
    )..repeat(reverse: true);

    _pulseAnimation = Tween<double>(begin: 0.8, end: 1.0).animate(
      CurvedAnimation(parent: _pulseController, curve: Curves.easeInOut),
    );

    _lancerGeneration();
  }

  @override
  void dispose() {
    _pulseController.dispose();
    // Si on a cédé la main au player, c'est lui qui dispose le notifier.
    if (!_handedOffToPlayer) {
      _sessionNotifier?.removeListener(_onSessionUpdate);
      _sessionNotifier?.dispose();
    } else {
      _sessionNotifier?.removeListener(_onSessionUpdate);
    }
    super.dispose();
  }

  void _lancerGeneration() {
    _sessionNotifier = PodcastService.generer(
      sujet: widget.sujet,
      dureeMin: widget.dureeMin,
      categorie: widget.categorie,
      niveau: widget.niveau,
      onSessionUpdate: (session) {
        // Sauvegarde incrémentale dans l'historique local.
        // Appelé à chaque chapitre prêt + une dernière fois à la fin.
        // L'opération est idempotente (même clé = écrasement).
        HistoryService.save(session);
      },
    );
    _sessionNotifier!.addListener(_onSessionUpdate);
    // Lecture initiale de la valeur (au cas où la pipeline ait déjà émis
    // quelque chose entre le `generer()` et le `addListener`)
    _onSessionUpdate();
  }

  void _onSessionUpdate() {
    final session = _sessionNotifier?.value;
    if (session == null || !mounted) return;

    if (session.globalError != null) {
      setState(() {
        _erreur = true;
        _messageErreur = session.globalError!;
        _progress = 1.0;
      });
      return;
    }

    setState(() {
      _progress = session.initialProgress;
      _etape = session.initialEtape;
    });

    if (session.firstChapterReady && !_handedOffToPlayer) {
      _handedOffToPlayer = true;
      // On retire ce listener maintenant — le player va prendre le relais
      // et écouter directement le notifier.
      _sessionNotifier!.removeListener(_onSessionUpdate);
      Navigator.pushReplacement(
        context,
        MaterialPageRoute(
          builder: (_) => PlayerScreen(
            sessionNotifier: _sessionNotifier!,
          ),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: KnowNowColors.background,
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              _buildAnimation(),
              const SizedBox(height: 48),
              _buildSujet(),
              const SizedBox(height: 40),
              if (!_erreur) ...[
                _buildProgressBar(),
                const SizedBox(height: 16),
                _buildEtape(),
              ] else
                _buildErreur(),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildAnimation() {
    return AnimatedBuilder(
      animation: _pulseAnimation,
      builder: (_, __) => Transform.scale(
        scale: _pulseAnimation.value,
        child: Container(
          width: 120,
          height: 120,
          decoration: const BoxDecoration(
            shape: BoxShape.circle,
            gradient: RadialGradient(
              colors: [
                Color(0x4D7B5CFF), // accent violet 30%
                Color(0x1A3CC0FF), // accent blue 10%
                Color(0x000A0D20), // transparent
              ],
              stops: [0.0, 0.7, 1.0],
            ),
          ),
          child: Container(
            margin: const EdgeInsets.all(24),
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              border: Border.all(
                color: KnowNowColors.accentVioletSoft.withOpacity(0.4),
                width: 1.5,
              ),
            ),
            child: const Center(
              child: Icon(Icons.mic_outlined,
                  size: 36, color: KnowNowColors.accentVioletSoft),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildSujet() {
    return Column(
      children: [
        const Text(
          'EN COURS DE CRÉATION',
          style: TextStyle(
            fontSize: 11,
            color: KnowNowColors.textSecondary,
            letterSpacing: 2.5,
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 12),
        Text(
          widget.sujet,
          textAlign: TextAlign.center,
          style: const TextStyle(
            fontSize: 20,
            color: KnowNowColors.textPrimary,
            fontWeight: FontWeight.w700,
            height: 1.3,
          ),
        ),
        const SizedBox(height: 8),
        Text(
          widget.categorie != null
              ? '${widget.categorie} · ${widget.dureeMin} minutes'
              : '${widget.dureeMin} minutes',
          style: const TextStyle(
            fontSize: 13,
            color: KnowNowColors.textSecondary,
          ),
        ),
      ],
    );
  }

  Widget _buildProgressBar() {
    return Column(
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(8),
          child: Stack(
            children: [
              Container(
                height: 4,
                decoration: BoxDecoration(
                  color: KnowNowColors.surface,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              FractionallySizedBox(
                widthFactor: _progress.clamp(0.0, 1.0),
                child: Container(
                  height: 4,
                  decoration: BoxDecoration(
                    gradient: KnowNowColors.accentGradient,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 10),
        Text(
          _etape,
          textAlign: TextAlign.center,
          style: const TextStyle(
            fontSize: 12,
            color: KnowNowColors.accentVioletSoft,
          ),
        ),
      ],
    );
  }

  Widget _buildEtape() {
    return const SizedBox.shrink();
  }

  Widget _buildErreur() {
    return Column(
      children: [
        const Icon(Icons.error_outline,
            color: KnowNowColors.accentVioletSoft, size: 48),
        const SizedBox(height: 16),
        const Text(
          'Une erreur est survenue',
          style: TextStyle(
              color: KnowNowColors.textPrimary,
              fontSize: 16,
              fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 8),
        Text(
          _messageErreur,
          textAlign: TextAlign.center,
          style: const TextStyle(
              color: KnowNowColors.textSecondary, fontSize: 12),
          maxLines: 3,
          overflow: TextOverflow.ellipsis,
        ),
        const SizedBox(height: 24),
        GestureDetector(
          onTap: () => Navigator.pop(context),
          child: Container(
            padding:
                const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
            decoration: BoxDecoration(
              color: KnowNowColors.surface,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: KnowNowColors.surfaceBorder),
            ),
            child: const Text(
              'Retour',
              style: TextStyle(
                  color: KnowNowColors.textHigh,
                  fontWeight: FontWeight.w600),
            ),
          ),
        ),
      ],
    );
  }
}
