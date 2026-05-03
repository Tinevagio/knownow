import 'package:flutter/material.dart';

/// Palette KnowNow — mode sombre cohérent avec le logo.
///
/// Les couleurs sont centralisées ici pour éviter de répandre des
/// constantes hexa partout. Si on veut un jour faire un mode clair
/// ou changer le branding, c'est ici qu'on touche.
class KnowNowColors {
  KnowNowColors._();

  // Fond principal (marine très sombre du logo)
  static const background = Color(0xFF0A0D20);

  // Surface secondaire pour cards/inputs au repos
  static const surface = Color(0x0AFFFFFF); // rgba(255,255,255,0.04)
  static const surfaceBorder = Color(0x1AFFFFFF); // rgba(255,255,255,0.10)

  // Surface tertiaire (un peu plus visible, pour fields et hover)
  static const surfaceElevated = Color(0x14FFFFFF); // rgba(255,255,255,0.08)

  // Textes
  static const textPrimary = Color(0xFFFFFFFF);
  static const textHigh = Color(0xFFE8EAF0);
  static const textSecondary = Color(0xFF8B8FA8);
  static const textDisabled = Color(0xFF5A5E72);

  // Accent — utilisé pour boutons primaires, sélection, progress
  static const accentViolet = Color(0xFF7B5CFF);
  static const accentBlue = Color(0xFF3CC0FF);
  static const accentVioletSoft = Color(0xFFB7A3FF);

  // Dégradé principal (violet → bleu, comme dans le logo)
  static const accentGradient = LinearGradient(
    colors: [accentViolet, accentBlue],
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
  );

  // Variantes "ghost" (fond + bordure violet à faible opacité, pour tags)
  static const accentGhost = Color(0x267B5CFF); // ~15% violet
  static const accentGhostBorder = Color(0x667B5CFF); // ~40% violet

  // Couleurs par catégorie (re-colorisées en palette KnowNow)
  // Chaque catégorie = un dégradé de 2 couleurs cohérentes avec le logo
  static const Map<String, List<Color>> categoryGradients = {
    'Histoire': [Color(0xFF7B5CFF), Color(0xFF3CC0FF)], // violet → bleu (signature)
    'Économie': [Color(0xFF1F8B5C), Color(0xFF3CC0FF)], // vert → bleu
    'Droit': [Color(0xFFC33C5A), Color(0xFF7B5CFF)], // rouge bordeaux → violet
    'Science': [Color(0xFF1C4F72), Color(0xFF3CC0FF)], // bleu profond → cyan
    'Littérature': [Color(0xFF8B5A2B), Color(0xFFC4915A)], // brun ambre
    'Géographie': [Color(0xFF4A8C3F), Color(0xFF8AC569)], // vert nature
    'Cinéma': [Color(0xFF6B3FA0), Color(0xFFC33C9A)], // violet → magenta
    'Musique': [Color(0xFFD17A28), Color(0xFFFFB74D)], // ambre vibrant
    'Politique': [Color(0xFF3E3A4D), Color(0xFF7E7A8F)], // gris sobre
    'Sport': [Color(0xFF2F8E8E), Color(0xFF52D9C4)], // teal énergique
  };

  static const categoryGradientDefault = [
    Color(0xFF555870),
    Color(0xFF8B8FA8),
  ];

  /// Retourne le LinearGradient correspondant à une catégorie, ou un
  /// dégradé neutre si la catégorie est inconnue.
  static LinearGradient gradientFor(String? categorie) {
    final colors = categoryGradients[categorie] ?? categoryGradientDefault;
    return LinearGradient(
      colors: colors,
      begin: Alignment.topLeft,
      end: Alignment.bottomRight,
    );
  }
}
