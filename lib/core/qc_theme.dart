import 'package:flutter/material.dart';

/// Tokens del Question Card System — mobile-first, premium, limpio.
class QCTokens {
  static const cardRadius = 24.0;
  static const optionRadius = 16.0;
  static const cardPadding = 20.0;
  static const optionPadding = 14.0;
  static const shadow = BoxShadow(
    color: Color(0x140B1020),
    blurRadius: 16,
    offset: Offset(0, 4),
  );
  static const questionSize = 22.0;
  static const questionSizeSmall = 20.0;
  static const questionMaxWidth = 320.0;

  static const primary = Color(0xff6c4df6);
  static const bg = Color(0xfff7f8fc);
  static const success = Color(0xff22c55e);
  static const error = Color(0xffef4444);
  static const warning = Color(0xfff59e0b);

  // Degradado juvenil 8% — velo violeta→rosa sobre blanco (claro)
  static const cardGradient = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [Color(0xffffffff), Color(0x146c4df6), Color(0x14ec4899)],
    stops: [0.0, 0.55, 1.0],
  );
  // Oscuro: velo más sutil 5-6% sobre superficie oscura, sin blanco
  static const darkCardGradient = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [Color(0xff1E293B), Color(0x0F6C4DF6), Color(0x0FEC4899)],
    stops: [0.0, 0.6, 1.0],
  );
  static const progressGradient = LinearGradient(
    colors: [Color(0xff6c4df6), Color(0xff06b6d4)],
  );
  static const darkProgressGradient = LinearGradient(
    colors: [Color(0xff7C6CF6), Color(0xff22D3EE)],
  );
  static const buttonGradient = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [Color(0xff6c4df6), Color(0xff8b5cf6)],
  );
  // Acento por tipo (banda superior de la tarjeta) — desaturado en oscuro
  static const typeAccents = {
    'flashcard': Color(0xff6c4df6),
    'multipleChoice': Color(0xff3b82f6),
    'trueFalse': Color(0xff06b6d4),
    'written': Color(0xff8b5cf6),
    'fillBlank': Color(0xffec4899),
    'ordering': Color(0xff0ea5e9),
    'matching': Color(0xff8b5cf6),
    'imageChoice': Color(0xfff59e0b),
  };
  static const darkTypeAccents = {
    'flashcard': Color(0xff7C6CF6),
    'multipleChoice': Color(0xff5B9EF6),
    'trueFalse': Color(0xff22D3EE),
    'written': Color(0xff9B7CF6),
    'fillBlank': Color(0xffF472B6),
    'ordering': Color(0xff38BDF8),
    'matching': Color(0xffA78BFA),
    'imageChoice': Color(0xffFBBF24),
  };

  static LinearGradient cardGradientOf(BuildContext c) =>
      Theme.of(c).brightness == Brightness.dark ? darkCardGradient : cardGradient;

  static LinearGradient progressGradientOf(BuildContext c) =>
      Theme.of(c).brightness == Brightness.dark ? darkProgressGradient : progressGradient;

  static Color accentFor(BuildContext c, String key) {
    final isDark = Theme.of(c).brightness == Brightness.dark;
    final map = isDark ? darkTypeAccents : typeAccents;
    return map[key] ?? (isDark ? darkTypeAccents['flashcard']! : typeAccents['flashcard']!);
  }

  static Color borderForCard(BuildContext c) =>
      Theme.of(c).brightness == Brightness.dark
          ? const Color(0xff2A3A57)
          : const Color(0xffE9E9F3);

  static List<BoxShadow> shadowsFor(BuildContext c) =>
      Theme.of(c).brightness == Brightness.dark
          ? [] // sin sombra en oscuro, usa borde + highlight
          : [shadow];

  static const animFast = Duration(milliseconds: 180);
  static const animMed = Duration(milliseconds: 220);
}

/// Barra de progreso con degradado violeta→cyan.
class QCProgressBar extends StatelessWidget {
  const QCProgressBar({super.key, required this.progress});
  final double progress; // 0..1
  @override
  Widget build(BuildContext c) {
    final v = progress.clamp(0.0, 1.0);
    return ClipRRect(
      borderRadius: BorderRadius.circular(8),
      child: Stack(
        children: [
          Container(
            height: 6,
            color: Theme.of(c).colorScheme.surfaceContainerHighest,
          ),
          FractionallySizedBox(
            widthFactor: v,
            child: Container(
              height: 6,
              decoration: BoxDecoration(
                gradient: QCTokens.progressGradientOf(c),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Header pequeño: categoría · número + progreso.
class QCHeader extends StatelessWidget {
  const QCHeader({
    super.key,
    required this.category,
    required this.index,
    required this.total,
    required this.progress,
  });
  final String category;
  final int index, total;
  final double progress;
  @override
  Widget build(BuildContext c) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Row(
        children: [
          Expanded(
            child: Text(
              category,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(c).textTheme.labelMedium?.copyWith(
                color: Theme.of(c).colorScheme.onSurfaceVariant,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          const SizedBox(width: 8),
          Text(
            '$index de $total',
            style: Theme.of(c).textTheme.labelMedium?.copyWith(
              color: Theme.of(c).colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
      const SizedBox(height: 8),
      QCProgressBar(progress: progress),
    ],
  );
}

/// Pregunta centrada, protagonista visual.
class QCQuestion extends StatelessWidget {
  const QCQuestion(this.text, {super.key, this.image});
  final String text;
  final Widget? image;
  @override
  Widget build(BuildContext c) {
    final small = MediaQuery.of(c).size.width < 360;
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: QCTokens.questionMaxWidth),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            text,
            textAlign: TextAlign.center,
            style: Theme.of(c).textTheme.headlineSmall?.copyWith(
              fontSize:
                  small ? QCTokens.questionSizeSmall : QCTokens.questionSize,
              fontWeight: FontWeight.bold,
              height: 1.3,
            ),
          ),
          if (image != null) ...[const SizedBox(height: 16), image!],
        ],
      ),
    );
  }
}
