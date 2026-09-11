import 'dart:math';

/// Normalización flexible para respuesta escrita (§9): minúsculas,
/// espacios colapsados y sin acentos.
String normalizeAnswer(String x) => x
    .toLowerCase()
    .trim()
    .replaceAll(RegExp(r'\s+'), ' ')
    .replaceAll(RegExp('[áàäâ]'), 'a')
    .replaceAll(RegExp('[éèëê]'), 'e')
    .replaceAll(RegExp('[íìïî]'), 'i')
    .replaceAll(RegExp('[óòöô]'), 'o')
    .replaceAll(RegExp('[úùüû]'), 'u');

bool checkWrittenAnswer(String given, String expected, List<String> accepted) {
  final got = normalizeAnswer(given);
  if (got == normalizeAnswer(expected)) return true;
  return accepted.any((x) => normalizeAnswer(x) == got);
}

const levelNames = [
  'Principiante',
  'Aprendiz',
  'Estudiante',
  'Investigador',
  'Experto',
  'Maestro',
  'Leyenda',
];

const levelThresholds = [0, 100, 300, 600, 1000, 1500, 2500];

int levelForXp(int xp) {
  var level = 1;
  for (var i = 0; i < levelThresholds.length; i++) {
    if (xp >= levelThresholds[i]) level = i + 1;
  }
  return level;
}

int xpForLevel(int level) {
  if (level <= 1) return 0;
  if (level - 1 < levelThresholds.length) return levelThresholds[level - 1];
  return levelThresholds.last + (level - levelThresholds.length) * 1000;
}

DateTime dateOnly(DateTime d) => DateTime(d.year, d.month, d.day);
String dateKey(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

int minInt(int a, int b) => min(a, b);
