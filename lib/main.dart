import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'screens/home_screen.dart';
import 'services/history_service.dart';
import 'theme.dart';

Future<void> main() async {
  // Nécessaire avant tout accès asset en pré-runApp
  WidgetsFlutterBinding.ensureInitialized();

  // Status bar et navigation bar Android cohérentes avec le fond sombre
  SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
    statusBarColor: Colors.transparent,
    statusBarIconBrightness: Brightness.light,
    systemNavigationBarColor: KnowNowColors.background,
    systemNavigationBarIconBrightness: Brightness.light,
  ));

  // Charge les variables d'environnement depuis .env
  // (doit être dans pubspec.yaml comme asset)
  await dotenv.load(fileName: '.env');

  // Vérification immédiate que la clé est présente — on préfère crasher
  // au démarrage qu'au premier appel Gemini avec une clé nulle.
  final apiKey = dotenv.env['GEMINI_API_KEY'];
  if (apiKey == null || apiKey.isEmpty) {
    throw StateError(
      'GEMINI_API_KEY manquante. Vérifier que le fichier .env est présent '
      'à la racine et déclaré comme asset dans pubspec.yaml.',
    );
  }

  // Initialise le stockage local des podcasts
  await HistoryService.init();

  // Nettoyage des WAV orphelins (dossiers podcast_* sans session en base).
  // Non bloquant pour le démarrage : on fire-and-forget.
  // ignore: unawaited_futures
  HistoryService.cleanupOrphans();

  runApp(
    const ProviderScope(
      child: KnowNowApp(),
    ),
  );
}

class KnowNowApp extends StatelessWidget {
  const KnowNowApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'KnowNow',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        brightness: Brightness.dark,
        scaffoldBackgroundColor: KnowNowColors.background,
        colorScheme: ColorScheme.fromSeed(
          seedColor: KnowNowColors.accentViolet,
          brightness: Brightness.dark,
          surface: KnowNowColors.background,
          primary: KnowNowColors.accentViolet,
          secondary: KnowNowColors.accentBlue,
        ),
        // Police par défaut — on garde Georgia pour le côté éditorial
        // mais sur les éléments d'UI on overridera vers du sans-serif.
        fontFamily: 'Georgia',
        textTheme: const TextTheme(
          bodyLarge: TextStyle(color: KnowNowColors.textPrimary),
          bodyMedium: TextStyle(color: KnowNowColors.textHigh),
          bodySmall: TextStyle(color: KnowNowColors.textSecondary),
        ),
        snackBarTheme: const SnackBarThemeData(
          backgroundColor: Color(0xFF1A1E36),
          contentTextStyle: TextStyle(color: KnowNowColors.textPrimary),
          behavior: SnackBarBehavior.floating,
        ),
        dialogTheme: const DialogThemeData(
          backgroundColor: Color(0xFF14172E),
          titleTextStyle: TextStyle(
            color: KnowNowColors.textPrimary,
            fontSize: 18,
            fontWeight: FontWeight.w600,
          ),
          contentTextStyle: TextStyle(
            color: KnowNowColors.textHigh,
            fontSize: 14,
          ),
        ),
      ),
      home: const HomeScreen(),
    );
  }
}
