import 'package:flutter/material.dart';
import '../services/history_service.dart';
import '../services/podcast_service.dart';
import '../theme.dart';
import 'player_screen.dart';

const _categorieEmojis = {
  'Histoire': '🏛️',
  'Économie': '📈',
  'Droit': '⚖️',
  'Science': '🔬',
  'Littérature': '📖',
  'Géographie': '🗺️',
  'Cinéma': '🎬',
  'Musique': '🎼',
  'Politique': '🏛',
  'Sport': '🏃',
};

class HistoryScreen extends StatefulWidget {
  const HistoryScreen({super.key});

  @override
  State<HistoryScreen> createState() => _HistoryScreenState();
}

class _HistoryScreenState extends State<HistoryScreen> {
  late List<PodcastSession> _sessions;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  void _reload() {
    setState(() {
      _sessions = HistoryService.loadAll();
    });
  }

  Future<void> _openSession(PodcastSession session) async {
    final notifier = ValueNotifier<PodcastSession>(session);
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => PlayerScreen(sessionNotifier: notifier),
      ),
    );
    _reload();
  }

  Future<void> _confirmDelete(PodcastSession session) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Supprimer ce podcast ?'),
        content: Text(
          'Cette action est définitive. Les fichiers audio associés seront '
          'aussi supprimés.\n\n"${session.titre}"',
          style: const TextStyle(fontSize: 13),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            style:
                TextButton.styleFrom(foregroundColor: KnowNowColors.textHigh),
            child: const Text('Annuler'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: TextButton.styleFrom(
                foregroundColor: KnowNowColors.accentVioletSoft),
            child: const Text('Supprimer'),
          ),
        ],
      ),
    );
    if (ok == true) {
      await HistoryService.delete(session.id);
      _reload();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: KnowNowColors.background,
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _buildHeader(),
            if (_sessions.isEmpty)
              const Expanded(child: _EmptyState())
            else
              Expanded(child: _buildGrid()),
          ],
        ),
      ),
    );
  }

  Widget _buildHeader() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 18),
      child: Row(
        children: [
          GestureDetector(
            onTap: () => Navigator.pop(context),
            child: Container(
              padding: const EdgeInsets.all(7),
              decoration: BoxDecoration(
                color: KnowNowColors.surface,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: KnowNowColors.surfaceBorder),
              ),
              child: const Icon(Icons.arrow_back_ios_new,
                  size: 14, color: KnowNowColors.textHigh),
            ),
          ),
          const SizedBox(width: 14),
          const Text(
            'MES PODCASTS',
            style: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w900,
              color: KnowNowColors.textPrimary,
              letterSpacing: 3,
              fontFamily: 'Georgia',
            ),
          ),
          const Spacer(),
          if (_sessions.isNotEmpty) ...[
            Text(
              '${_sessions.length}',
              style: const TextStyle(
                fontSize: 13,
                color: KnowNowColors.textSecondary,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(width: 6),
            _buildMenuButton(),
          ],
        ],
      ),
    );
  }

  Widget _buildMenuButton() {
    return PopupMenuButton<String>(
      icon: const Icon(Icons.more_vert,
          color: KnowNowColors.textHigh, size: 20),
      padding: EdgeInsets.zero,
      color: const Color(0xFF14172E),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      onSelected: (value) {
        if (value == 'delete_all') _confirmDeleteAll();
      },
      itemBuilder: (_) => [
        PopupMenuItem(
          value: 'delete_all',
          child: Row(
            children: const [
              Icon(Icons.delete_sweep_outlined,
                  size: 17, color: KnowNowColors.accentVioletSoft),
              SizedBox(width: 10),
              Text(
                'Tout supprimer',
                style: TextStyle(
                  color: KnowNowColors.accentVioletSoft,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Future<void> _confirmDeleteAll() async {
    final diskBytes = await HistoryService.getAudioDiskUsageBytes();
    final humanSize = _humanBytes(diskBytes);

    if (!mounted) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Tout supprimer ?'),
        content: Text(
          'Tous les podcasts de votre historique (${_sessions.length}) '
          'et leurs fichiers audio ($humanSize) seront supprimés '
          'définitivement.\n\nCette action est irréversible.',
          style: const TextStyle(fontSize: 13),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            style:
                TextButton.styleFrom(foregroundColor: KnowNowColors.textHigh),
            child: const Text('Annuler'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: TextButton.styleFrom(
                foregroundColor: KnowNowColors.accentVioletSoft),
            child: const Text('Tout supprimer'),
          ),
        ],
      ),
    );

    if (ok != true || !mounted) return;

    final report = await HistoryService.deleteAll();
    _reload();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('Historique vidé — ${report.humanBytes} libérés'),
        duration: const Duration(seconds: 3),
      ),
    );
  }

  String _humanBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / 1024 / 1024).toStringAsFixed(1)} MB';
    }
    return '${(bytes / 1024 / 1024 / 1024).toStringAsFixed(2)} GB';
  }

  Widget _buildGrid() {
    return GridView.builder(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 2,
        crossAxisSpacing: 10,
        mainAxisSpacing: 10,
        childAspectRatio: 0.85,
      ),
      itemCount: _sessions.length,
      itemBuilder: (_, i) => _PodcastCard(
        session: _sessions[i],
        onTap: () => _openSession(_sessions[i]),
        onLongPress: () => _confirmDelete(_sessions[i]),
      ),
    );
  }
}

class _PodcastCard extends StatelessWidget {
  final PodcastSession session;
  final VoidCallback onTap;
  final VoidCallback onLongPress;

  const _PodcastCard({
    required this.session,
    required this.onTap,
    required this.onLongPress,
  });

  @override
  Widget build(BuildContext context) {
    final gradient = KnowNowColors.gradientFor(session.categorie);
    final emoji = _categorieEmojis[session.categorie] ?? '🎧';
    final dateStr = _formatDate(session.createdAt);
    final nbChapRead = session.chapters
        .where((c) => c.status == ChapterStatus.ready)
        .length;

    return GestureDetector(
      onTap: onTap,
      onLongPress: onLongPress,
      child: Container(
        decoration: BoxDecoration(
          gradient: gradient,
          borderRadius: BorderRadius.circular(14),
        ),
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(emoji, style: const TextStyle(fontSize: 20)),
                  Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 8, vertical: 3),
                    decoration: BoxDecoration(
                      color: Colors.white.withOpacity(0.15),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Text(
                      '${session.dureeMin} min',
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 10,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ],
              ),
              const Spacer(),
              Text(
                session.titre,
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                  height: 1.25,
                ),
              ),
              const SizedBox(height: 6),
              if (session.categorie != null)
                Text(
                  session.categorie!.toUpperCase(),
                  style: TextStyle(
                    color: Colors.white.withOpacity(0.65),
                    fontSize: 9,
                    fontWeight: FontWeight.w600,
                    letterSpacing: 1.5,
                  ),
                ),
              const SizedBox(height: 8),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    dateStr,
                    style: TextStyle(
                      color: Colors.white.withOpacity(0.65),
                      fontSize: 10,
                    ),
                  ),
                  Text(
                    '$nbChapRead chap.',
                    style: TextStyle(
                      color: Colors.white.withOpacity(0.65),
                      fontSize: 10,
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  String _formatDate(DateTime d) {
    final now = DateTime.now();
    final diff = now.difference(d);
    if (diff.inMinutes < 60) return "à l'instant";
    if (diff.inHours < 24) return 'il y a ${diff.inHours} h';
    if (diff.inDays < 7) return 'il y a ${diff.inDays} j';
    return '${d.day.toString().padLeft(2, '0')}/${d.month.toString().padLeft(2, '0')}';
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState();

  @override
  Widget build(BuildContext context) {
    return const Center(
      child: Padding(
        padding: EdgeInsets.all(32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.library_music_outlined,
                size: 60, color: KnowNowColors.textDisabled),
            SizedBox(height: 16),
            Text(
              'Aucun podcast pour le moment',
              style: TextStyle(
                color: KnowNowColors.textHigh,
                fontSize: 15,
                fontWeight: FontWeight.w600,
              ),
            ),
            SizedBox(height: 6),
            Text(
              'Les podcasts que vous générez apparaîtront ici.',
              textAlign: TextAlign.center,
              style: TextStyle(color: KnowNowColors.textSecondary, fontSize: 12),
            ),
          ],
        ),
      ),
    );
  }
}
