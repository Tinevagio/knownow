import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../services/gemini_service.dart';
import '../services/history_service.dart';
import '../services/podcast_service.dart';
import '../theme.dart';
import 'generation_screen.dart';
import 'history_screen.dart';

// ─── Données ───────────────────────────────────────────
const categories = [
  {'label': 'Histoire', 'emoji': '🏛️'},
  {'label': 'Économie', 'emoji': '📈'},
  {'label': 'Droit', 'emoji': '⚖️'},
  {'label': 'Science', 'emoji': '🔬'},
  {'label': 'Littérature', 'emoji': '📖'},
  {'label': 'Géographie', 'emoji': '🗺️'},
  {'label': 'Cinéma', 'emoji': '🎬'},
  {'label': 'Musique', 'emoji': '🎼'},
  {'label': 'Politique', 'emoji': '🏛'},
  {'label': 'Sport', 'emoji': '🏃'},
];

const durees = [15, 30, 45];

// ─── Providers ─────────────────────────────────────────
final categorieSelectionneeProvider = StateProvider<String?>((ref) => null);
final sujetSelectionneeProvider = StateProvider<String?>((ref) => null);
final dureeSelectionneeProvider = StateProvider<int>((ref) => 30);
final niveauSelectionneProvider = StateProvider<NiveauEditorial>(
  (ref) => NiveauEditorial.standard,
);
final promptLibreProvider = StateProvider<String>((ref) => '');
final suggestionsProvider = StateProvider<List<String>>((ref) => []);
final suggestionsLoadingProvider = StateProvider<bool>((ref) => false);

class HomeScreen extends ConsumerWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final categorie = ref.watch(categorieSelectionneeProvider);
    final sujet = ref.watch(sujetSelectionneeProvider);
    final duree = ref.watch(dureeSelectionneeProvider);
    final niveau = ref.watch(niveauSelectionneProvider);

    return Scaffold(
      backgroundColor: KnowNowColors.background,
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 32),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _buildHeader(context),
              const SizedBox(height: 28),
              _buildSectionTitle('CHOISISSEZ UN THÈME'),
              const SizedBox(height: 12),
              _buildCategories(ref, categorie),
              if (categorie != null) ...[
                const SizedBox(height: 24),
                _buildSuggestionsHeader(ref, categorie),
                const SizedBox(height: 12),
                _buildSuggestions(ref, categorie, sujet),
                const SizedBox(height: 16),
                _buildPromptLibre(ref),
              ],
              const SizedBox(height: 28),
              _buildSectionTitle('NIVEAU'),
              const SizedBox(height: 12),
              _buildNiveaux(ref, niveau),
              const SizedBox(height: 28),
              _buildSectionTitle('DURÉE DE VOTRE RUN'),
              const SizedBox(height: 12),
              _buildDurees(ref, duree),
              const SizedBox(height: 32),
              _buildBoutonGenerer(
                  context, ref, categorie, sujet, duree, niveau),
            ],
          ),
        ),
      ),
    );
  }

  // ── Helpers ─────────────────────────────────────────

  Future<void> _fetchSuggestions(
    WidgetRef ref,
    String categorie, {
    bool forceRefresh = false,
  }) async {
    final niveau = ref.read(niveauSelectionneProvider);
    final exclude = HistoryService.getSubjectsByCategory(categorie);
    ref.read(suggestionsProvider.notifier).state = [];
    ref.read(suggestionsLoadingProvider.notifier).state = true;
    try {
      final suggestions = await GeminiService.genererSuggestions(
        categorie,
        niveau: niveau,
        excludeSubjects: exclude,
        forceRefresh: forceRefresh,
      );
      ref.read(suggestionsProvider.notifier).state = suggestions;
    } catch (_) {
      ref.read(suggestionsProvider.notifier).state = [];
    } finally {
      ref.read(suggestionsLoadingProvider.notifier).state = false;
    }
  }

  // ── Header ──────────────────────────────────────────
  Widget _buildHeader(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Container(
              width: 4,
              height: 24,
              decoration: BoxDecoration(
                gradient: KnowNowColors.accentGradient,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            const SizedBox(width: 10),
            const Text(
              'KNOWNOW',
              style: TextStyle(
                fontSize: 22,
                fontWeight: FontWeight.w900,
                color: KnowNowColors.textPrimary,
                letterSpacing: 4,
                fontFamily: 'Georgia',
              ),
            ),
            const Spacer(),
            GestureDetector(
              onTap: () => Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const HistoryScreen()),
              ),
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
                decoration: BoxDecoration(
                  color: KnowNowColors.accentGhost,
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(color: KnowNowColors.accentGhostBorder),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: const [
                    Icon(Icons.library_music_outlined,
                        size: 13, color: KnowNowColors.accentVioletSoft),
                    SizedBox(width: 5),
                    Text(
                      'Mes podcasts',
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                        color: KnowNowColors.accentVioletSoft,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 6),
        const Padding(
          padding: EdgeInsets.only(left: 14),
          child: Text(
            'Le savoir, maintenant.',
            style: TextStyle(
              fontSize: 13,
              color: KnowNowColors.textSecondary,
              fontStyle: FontStyle.italic,
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildSectionTitle(String title) {
    return Text(
      title,
      style: const TextStyle(
        fontSize: 11,
        fontWeight: FontWeight.w700,
        color: KnowNowColors.textSecondary,
        letterSpacing: 1.5,
        fontFamily: 'Georgia',
      ),
    );
  }

  // ── Catégories ──────────────────────────────────────
  Widget _buildCategories(WidgetRef ref, String? categorieActive) {
    return GridView.count(
      crossAxisCount: 2,
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      crossAxisSpacing: 8,
      mainAxisSpacing: 8,
      childAspectRatio: 3.0,
      children: categories.map((cat) {
        final isSelected = categorieActive == cat['label'];
        final label = cat['label'] as String;
        return GestureDetector(
          onTap: () async {
            ref.read(categorieSelectionneeProvider.notifier).state = label;
            ref.read(sujetSelectionneeProvider.notifier).state = null;
            ref.read(promptLibreProvider.notifier).state = '';
            await _fetchSuggestions(ref, label);
          },
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 200),
            decoration: BoxDecoration(
              gradient: isSelected ? KnowNowColors.gradientFor(label) : null,
              color: isSelected ? null : KnowNowColors.surface,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(
                color: isSelected
                    ? Colors.transparent
                    : KnowNowColors.surfaceBorder,
                width: 1,
              ),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(cat['emoji'] as String,
                    style: const TextStyle(fontSize: 16)),
                const SizedBox(width: 6),
                Flexible(
                  child: Text(
                    label,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: isSelected
                          ? KnowNowColors.textPrimary
                          : KnowNowColors.textHigh,
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      }).toList(),
    );
  }

  // ── Suggestions ─────────────────────────────────────
  Widget _buildSuggestionsHeader(WidgetRef ref, String categorie) {
    final loading = ref.watch(suggestionsLoadingProvider);
    return Row(
      children: [
        _buildSectionTitle('SUGGESTIONS'),
        const SizedBox(width: 12),
        GestureDetector(
          onTap: loading
              ? null
              : () => _fetchSuggestions(ref, categorie, forceRefresh: true),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            decoration: BoxDecoration(
              color: KnowNowColors.surface,
              borderRadius: BorderRadius.circular(11),
              border: Border.all(color: KnowNowColors.surfaceBorder),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  Icons.refresh,
                  size: 12,
                  color: loading
                      ? KnowNowColors.textDisabled
                      : KnowNowColors.accentVioletSoft,
                ),
                const SizedBox(width: 4),
                Text(
                  'Rafraîchir',
                  style: TextStyle(
                    fontSize: 10,
                    fontWeight: FontWeight.w600,
                    color: loading
                        ? KnowNowColors.textDisabled
                        : KnowNowColors.accentVioletSoft,
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildSuggestions(
      WidgetRef ref, String categorie, String? sujetActif) {
    final liste = ref.watch(suggestionsProvider);
    final loading = ref.watch(suggestionsLoadingProvider);

    if (loading) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 16),
        child: Center(
          child: SizedBox(
            width: 22,
            height: 22,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              valueColor:
                  AlwaysStoppedAnimation<Color>(KnowNowColors.accentVioletSoft),
            ),
          ),
        ),
      );
    }

    if (liste.isEmpty) return const SizedBox.shrink();

    final visibles = liste.take(5).toList();
    final surprise = liste.length >= 6 ? liste[5] : null;

    return Wrap(
      spacing: 7,
      runSpacing: 7,
      children: [
        ...visibles.map((s) {
          final isSelected = sujetActif == s;
          return GestureDetector(
            onTap: () {
              ref.read(sujetSelectionneeProvider.notifier).state = s;
              ref.read(promptLibreProvider.notifier).state = '';
            },
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 150),
              padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 7),
              decoration: BoxDecoration(
                gradient: isSelected ? KnowNowColors.accentGradient : null,
                color: isSelected ? null : KnowNowColors.surface,
                borderRadius: BorderRadius.circular(16),
                border: Border.all(
                  color: isSelected
                      ? Colors.transparent
                      : KnowNowColors.surfaceBorder,
                ),
              ),
              child: Text(
                s,
                style: TextStyle(
                  fontSize: 12,
                  color: isSelected
                      ? KnowNowColors.textPrimary
                      : KnowNowColors.textHigh,
                  fontWeight:
                      isSelected ? FontWeight.w600 : FontWeight.normal,
                ),
              ),
            ),
          );
        }),
        // Bouton Surprise
        GestureDetector(
          onTap: () {
            String? pick = surprise;
            if (pick == null) {
              if (visibles.isEmpty) return;
              pick = (List<String>.from(visibles)..shuffle()).first;
            }
            ref.read(sujetSelectionneeProvider.notifier).state = pick;
            ref.read(promptLibreProvider.notifier).state = '';
          },
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 7),
            decoration: BoxDecoration(
              gradient: KnowNowColors.accentGradient,
              borderRadius: BorderRadius.circular(16),
            ),
            child: const Text(
              '🎲 Surprise',
              style: TextStyle(
                fontSize: 12,
                color: KnowNowColors.textPrimary,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ),
      ],
    );
  }

  // ── Prompt libre ────────────────────────────────────
  Widget _buildPromptLibre(WidgetRef ref) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
      decoration: BoxDecoration(
        color: KnowNowColors.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: KnowNowColors.surfaceBorder),
      ),
      child: TextField(
        onChanged: (value) {
          ref.read(promptLibreProvider.notifier).state = value;
          if (value.trim().isNotEmpty) {
            ref.read(sujetSelectionneeProvider.notifier).state = value.trim();
          }
        },
        cursorColor: KnowNowColors.accentVioletSoft,
        style: const TextStyle(
          color: KnowNowColors.textPrimary,
          fontSize: 13,
        ),
        decoration: const InputDecoration(
          hintText: 'Ou saisis ton propre sujet...',
          hintStyle: TextStyle(
            color: KnowNowColors.textSecondary,
            fontSize: 13,
          ),
          border: InputBorder.none,
        ),
      ),
    );
  }

  // ── Niveau éditorial ────────────────────────────────
  Widget _buildNiveaux(WidgetRef ref, NiveauEditorial niveauActif) {
    const niveaux = [
      (NiveauEditorial.vulgarisation, 'Vulgarisation', 'Grand public'),
      (NiveauEditorial.standard, 'Standard', 'France Culture'),
      (NiveauEditorial.pointu, 'Pointu', 'Grande école'),
    ];
    return Row(
      children: niveaux.map((n) {
        final isSelected = niveauActif == n.$1;
        return Expanded(
          child: GestureDetector(
            onTap: () async {
              if (isSelected) return;
              ref.read(niveauSelectionneProvider.notifier).state = n.$1;
              final categorie = ref.read(categorieSelectionneeProvider);
              if (categorie != null) {
                ref.read(sujetSelectionneeProvider.notifier).state = null;
                await _fetchSuggestions(ref, categorie);
              }
            },
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 150),
              margin: const EdgeInsets.only(right: 6),
              padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 6),
              decoration: BoxDecoration(
                gradient: isSelected ? KnowNowColors.accentGradient : null,
                color: isSelected ? null : KnowNowColors.surface,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(
                  color: isSelected
                      ? Colors.transparent
                      : KnowNowColors.surfaceBorder,
                ),
              ),
              child: Column(
                children: [
                  Text(
                    n.$2,
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                      color: isSelected
                          ? KnowNowColors.textPrimary
                          : KnowNowColors.textHigh,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    n.$3,
                    textAlign: TextAlign.center,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 9,
                      color: isSelected
                          ? Colors.white.withOpacity(0.7)
                          : KnowNowColors.textSecondary,
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      }).toList(),
    );
  }

  // ── Durée ────────────────────────────────────────────
  Widget _buildDurees(WidgetRef ref, int dureeActive) {
    return Row(
      children: durees.map((d) {
        final isSelected = dureeActive == d;
        return Expanded(
          child: GestureDetector(
            onTap: () =>
                ref.read(dureeSelectionneeProvider.notifier).state = d,
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 150),
              margin: const EdgeInsets.only(right: 6),
              padding: const EdgeInsets.symmetric(vertical: 14),
              decoration: BoxDecoration(
                gradient: isSelected ? KnowNowColors.accentGradient : null,
                color: isSelected ? null : KnowNowColors.surface,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(
                  color: isSelected
                      ? Colors.transparent
                      : KnowNowColors.surfaceBorder,
                ),
              ),
              child: Column(
                children: [
                  Text(
                    '$d',
                    style: TextStyle(
                      fontSize: 22,
                      fontWeight: FontWeight.w700,
                      color: isSelected
                          ? KnowNowColors.textPrimary
                          : KnowNowColors.textHigh,
                    ),
                  ),
                  Text(
                    'min',
                    style: TextStyle(
                      fontSize: 10,
                      color: isSelected
                          ? Colors.white.withOpacity(0.7)
                          : KnowNowColors.textSecondary,
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      }).toList(),
    );
  }

  // ── Bouton Générer ──────────────────────────────────
  Widget _buildBoutonGenerer(BuildContext context, WidgetRef ref,
      String? categorie, String? sujet, int duree, NiveauEditorial niveau) {
    final pret = sujet != null && sujet.isNotEmpty;
    return GestureDetector(
      onTap: pret
          ? () {
              Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => GenerationScreen(
                    sujet: sujet,
                    dureeMin: duree,
                    categorie: categorie,
                    niveau: niveau,
                  ),
                ),
              );
            }
          : null,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        width: double.infinity,
        padding: const EdgeInsets.symmetric(vertical: 16),
        decoration: BoxDecoration(
          gradient: pret ? KnowNowColors.accentGradient : null,
          color: pret ? null : KnowNowColors.surface,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color:
                pret ? Colors.transparent : KnowNowColors.surfaceBorder,
          ),
        ),
        child: Center(
          child: Text(
            pret ? 'Générer le podcast' : 'Choisis un sujet',
            style: TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.w600,
              color: pret
                  ? KnowNowColors.textPrimary
                  : KnowNowColors.textSecondary,
            ),
          ),
        ),
      ),
    );
  }
}
