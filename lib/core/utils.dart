import 'dart:math';

/// Normalización flexible para respuesta escrita: minúsculas,
/// espacios y signos colapsados, sin acentos (incluye ñ→n).
/// "París." y "paris", "hola,  mundo" y "Hola Mundo" coinciden.
String normalizeAnswer(String x) => x
    .toLowerCase()
    .trim()
    .replaceAll('ß', 'ss')
    .replaceAll('œ', 'oe')
    .replaceAll(RegExp('[áàäâãå]'), 'a')
    .replaceAll(RegExp('[éèëê]'), 'e')
    .replaceAll(RegExp('[íìïî]'), 'i')
    .replaceAll(RegExp('[óòöôõø]'), 'o')
    .replaceAll(RegExp('[úùüû]'), 'u')
    .replaceAll(RegExp('[ñ]'), 'n')
    .replaceAll(RegExp('[ç]'), 'c')
    .replaceAll(RegExp('[ýÿ]'), 'y')
    .replaceAll(
        RegExp(r'''[.,;:!?¿¡'"«»“”‘’()\[\]{}\-_/|@#$%^&*+=~`<>]'''), ' ')
    .replaceAll(RegExp(r'\s+'), ' ')
    .trim();

/// Distancia Damerau-Levenshtein (sustitución, inserción, borrado y
/// transposición cuentan 1). Pura Dart, testeable.
int editDistance(String a, String b) {
  if (a == b) return 0;
  final m = a.length, n = b.length;
  if (m == 0) return n;
  if (n == 0) return m;
  var prevPrev = List<int>.filled(n + 1, 0);
  var prev = List<int>.generate(n + 1, (j) => j);
  var curr = List<int>.filled(n + 1, 0);
  for (var i = 1; i <= m; i++) {
    curr[0] = i;
    for (var j = 1; j <= n; j++) {
      final cost = a.codeUnitAt(i - 1) == b.codeUnitAt(j - 1) ? 0 : 1;
      var v = prev[j] + 1;
      final ins = curr[j - 1] + 1;
      if (ins < v) v = ins;
      final sub = prev[j - 1] + cost;
      if (sub < v) v = sub;
      if (i > 1 &&
          j > 1 &&
          a.codeUnitAt(i - 1) == b.codeUnitAt(j - 2) &&
          a.codeUnitAt(i - 2) == b.codeUnitAt(j - 1)) {
        final transp = prevPrev[j - 2] + 1;
        if (transp < v) v = transp;
      }
      curr[j] = v;
    }
    final tmp = prevPrev;
    prevPrev = prev;
    prev = curr;
    curr = tmp;
  }
  return prev[n];
}

/// Umbral de typos según largo: ≤4 exacto, 5-9 un error, ≥10 dos.
int typoThreshold(int len) => len <= 4 ? 0 : (len <= 9 ? 1 : 2);

bool fuzzyAnswerEqual(String a, String b) {
  if (a == b) return true;
  final t =
      typoThreshold(a.length > b.length ? a.length : b.length);
  if (t == 0 || (a.length - b.length).abs() > t) return false;
  return editDistance(a, b) <= t;
}

bool checkWrittenAnswer(String given, String expected, List<String> accepted) {
  final got = normalizeAnswer(given);
  if (fuzzyAnswerEqual(got, normalizeAnswer(expected))) return true;
  return accepted.any((x) => fuzzyAnswerEqual(got, normalizeAnswer(x)));
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
