import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'core/qc_theme.dart';
import 'core/qc_animate.dart';
import 'core/translations.dart';
import 'services/device_images.dart';
import 'services/image_refs.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final store = AppStore();
  await store.load();
  runApp(MrCardsApp(store: store));
}

enum QuestionType { flashcard, multipleChoice, trueFalse, written, fillBlank, ordering, matching, imageChoice }

enum StudyMode { review, random, exam, marathon }

enum Rating { again, hard, good, easy }

enum RandomOrder { random, difficult, leastStudied, due }

enum CardState { idle, answering, correct, incorrect, revealed, hint, completed }

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

/// Lógica pura de reencolado intra-sesión (§13), testeable sin UI.
/// again -> 1-2 preguntas después, hard -> 3-5 después.
/// Devuelve null si no debe reencolarse (examen/marathon, good/easy, o tope reintentos).
int? reinsertIndex({
  required StudyMode mode,
  required Rating rating,
  required int currentIndex,
  required int queueLength,
  required int retriesForQuestion,
}) {
  if (mode == StudyMode.exam || mode == StudyMode.marathon) return null;
  if (retriesForQuestion >= 2) return null;
  final offset = switch (rating) {
    Rating.again => 2 + Random().nextInt(2), // 2..3 (1-2 intermedias)
    Rating.hard => 4 + Random().nextInt(2), // 4..5 (3-5 intermedias)
    _ => null,
  };
  if (offset == null) return null;
  final target = currentIndex + offset;
  return target > queueLength ? queueLength : target;
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
String localizedLevelName(int level, String lang) {
  final names = levelNamesMap[lang] ?? levelNamesMap['es']!;
  return names[(level - 1).clamp(0, names.length - 1)];
}

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

enum AppThemeMode { system, light, dark }

class AppSettings {
  AppThemeMode themeMode;
  bool soundsEnabled;
  bool hapticsEnabled;
  bool animationsEnabled;
  bool remindersEnabled;
  int reminderHour;
  int reminderMinute;
  String language; // es,en,pt,fr,de,zh
  AppSettings({
    this.themeMode = AppThemeMode.dark,
    this.soundsEnabled = true,
    this.hapticsEnabled = true,
    this.animationsEnabled = true,
    this.remindersEnabled = false,
    this.reminderHour = 20,
    this.reminderMinute = 0,
    this.language = 'es',
  });
  Map<String, dynamic> json() => {
    'themeMode': themeMode.name,
    'sounds': soundsEnabled,
    'haptics': hapticsEnabled,
    'animations': animationsEnabled,
    'reminders': remindersEnabled,
    'hour': reminderHour,
    'minute': reminderMinute,
    'language': language,
  };
  factory AppSettings.from(Map<String, dynamic> x) {
    final rawLang = (x['language'] ?? 'es').toString();
    final lang = supportedLanguages.contains(rawLang) ? rawLang : 'es';
    return AppSettings(
      themeMode: AppThemeMode.values.asNameMap()[x['themeMode']] ??
          AppThemeMode.system,
      soundsEnabled: x['sounds'] ?? true,
      hapticsEnabled: x['haptics'] ?? true,
      animationsEnabled: x['animations'] ?? true,
      remindersEnabled: x['reminders'] ?? false,
      reminderHour: x['hour'] ?? 20,
      reminderMinute: x['minute'] ?? 0,
      language: lang,
    );
  }
}

/// Feedback sonoro + háptico configurable, sin dependencias extra.
class FeedbackService {
  static void correct(AppSettings s) {
    if (s.hapticsEnabled) HapticFeedback.lightImpact();
    if (s.soundsEnabled) SystemSound.play(SystemSoundType.click);
  }

  static void wrong(AppSettings s) {
    if (s.hapticsEnabled) HapticFeedback.mediumImpact();
  }

  static void achievement(AppSettings s) {
    if (s.hapticsEnabled) HapticFeedback.heavyImpact();
    if (s.soundsEnabled) SystemSound.play(SystemSoundType.alert);
  }

  static void select(AppSettings s) {
    if (s.hapticsEnabled) HapticFeedback.selectionClick();
  }
}

class Achievement {
  final String id, icon;
  final String titleEs, titleEn, descEs, descEn;
  const Achievement({
    required this.id,
    required this.icon,
    required this.titleEs,
    required this.titleEn,
    required this.descEs,
    required this.descEn,
  });
  String title(String lang) => achievementTitles[id]?[lang] ?? achievementTitles[id]?['en'] ?? titleEs;
  String desc(String lang) => achievementDescs[id]?[lang] ?? achievementDescs[id]?['en'] ?? descEs;
}

const achievementsCatalog = [
  Achievement(
    id: 'first_session',
    icon: '🏆',
    titleEs: 'Primera sesión',
    titleEn: 'First session',
    descEs: 'Completa tu primera sesión.',
    descEn: 'Complete your first session.',
  ),
  Achievement(
    id: 'week_streak',
    icon: '🔥',
    titleEs: 'Una semana',
    titleEn: 'One week',
    descEs: 'Estudia 7 días consecutivos.',
    descEn: 'Study 7 days in a row.',
  ),
  Achievement(
    id: 'brain_100',
    icon: '🧠',
    titleEs: 'Cerebro activo',
    titleEn: 'Active brain',
    descEs: 'Responde 100 preguntas.',
    descEn: 'Answer 100 questions.',
  ),
  Achievement(
    id: 'precise_90',
    icon: '🎯',
    titleEs: 'Preciso',
    titleEn: 'Sharp',
    descEs: 'Obtén 90% de aciertos (mín. 20).',
    descEn: 'Get 90% accuracy (min. 20).',
  ),
  Achievement(
    id: 'collector_10',
    icon: '📚',
    titleEs: 'Coleccionista',
    titleEn: 'Collector',
    descEs: 'Crea 10 cuestionarios.',
    descEn: 'Create 10 decks.',
  ),
  Achievement(
    id: 'persistent_50',
    icon: '💪',
    titleEs: 'Persistente',
    titleEn: 'Persistent',
    descEs: 'Corrige 50 preguntas difíciles.',
    descEn: 'Fix 50 hard questions.',
  ),
];

/// Devuelve ids recién desbloqueados.
List<String> checkAchievements(AppStore store) {
  final p = store.profile;
  final unlocked = p.achievements.toSet();
  final newly = <String>[];
  bool cond(String id) {
    switch (id) {
      case 'first_session':
        return p.sessionsCompleted >= 1;
      case 'week_streak':
        return p.longestStreak >= 7;
      case 'brain_100':
        return p.answered >= 100;
      case 'precise_90':
        return p.answered >= 20 && p.right / p.answered >= 0.9;
      case 'collector_10':
        return store.decks.length >= 10;
      case 'persistent_50':
        return p.difficultFixed >= 50;
    }
    return false;
  }

  for (final a in achievementsCatalog) {
    if (!unlocked.contains(a.id) && cond(a.id)) {
      p.achievements.add(a.id);
      newly.add(a.id);
    }
  }
  return newly;
}

class Deck {
  Deck({
    required this.id,
    required this.title,
    this.description = '',
    this.category = 'General',
    this.icon = '📚',
    this.color = 0xff6c4df6,
    DateTime? createdAt,
    DateTime? updatedAt,
  }) : createdAt = createdAt ?? DateTime.now(),
       updatedAt = updatedAt ?? DateTime.now();
  String id, title, description, category, icon;
  int color;
  DateTime createdAt, updatedAt;
  Map<String, dynamic> json() => {
    'id': id,
    'title': title,
    'description': description,
    'category': category,
    'icon': icon,
    'color': color,
    'createdAt': createdAt.toIso8601String(),
    'updatedAt': updatedAt.toIso8601String(),
  };
  factory Deck.from(Map<String, dynamic> x) => Deck(
    id: x['id'],
    title: x['title'],
    description: x['description'] ?? '',
    category: x['category'] ?? 'General',
    icon: x['icon'] ?? '📚',
    color: x['color'] ?? 0xff6c4df6,
    createdAt: x['createdAt'] == null
        ? null
        : DateTime.tryParse(x['createdAt']),
    updatedAt: x['updatedAt'] == null
        ? null
        : DateTime.tryParse(x['updatedAt']),
  );
}

class Question {
  Question({
    required this.id,
    required this.deckId,
    required this.type,
    required this.prompt,
    required this.answer,
    this.options = const [],
    this.accepted = const [],
    this.explanation = '',
    this.tags = const [],
    this.hints = const [],
    this.imageUrls = const [],
    this.pairs = const [],
    this.isFavorite = false,
    this.repetitions = 0,
    this.interval = 0,
    this.ease = 2.5,
    DateTime? next,
    this.correct = 0,
    this.incorrect = 0,
    DateTime? createdAt,
    DateTime? updatedAt,
  }) : nextReview = next ?? DateTime.now(),
       createdAt = createdAt ?? DateTime.now(),
       updatedAt = updatedAt ?? DateTime.now();
  String id, deckId, prompt, answer, explanation;
  QuestionType type;
  List<String> options, accepted, tags, hints, imageUrls;
  /// Para matching: lista de "izq|der" ej: ["Agua|CO2", "Oxígeno|O2"]
  List<String> pairs;
  bool isFavorite;
  int repetitions, interval, correct, incorrect;
  double ease;
  DateTime nextReview, createdAt, updatedAt;
  bool get difficult => incorrect > correct && (incorrect + correct) > 0;
  bool get mastered => repetitions >= 3 && interval >= 7;
  Map<String, dynamic> json() => {
    'id': id,
    'deckId': deckId,
    'type': type.name,
    'prompt': prompt,
    'answer': answer,
    'options': options,
    'accepted': accepted,
    'explanation': explanation,
    'tags': tags,
    'hints': hints,
    'imageUrls': imageUrls,
    'pairs': pairs,
    'isFavorite': isFavorite,
    'repetitions': repetitions,
    'interval': interval,
    'ease': ease,
    'next': nextReview.toIso8601String(),
    'correct': correct,
    'incorrect': incorrect,
    'createdAt': createdAt.toIso8601String(),
    'updatedAt': updatedAt.toIso8601String(),
  };
  factory Question.from(Map<String, dynamic> x) => Question(
    id: x['id'],
    deckId: x['deckId'],
    type: QuestionType.values.byName(x['type']),
    prompt: x['prompt'],
    answer: x['answer'],
    options: List<String>.from(x['options'] ?? []),
    accepted: List<String>.from(x['accepted'] ?? []),
    explanation: x['explanation'] ?? '',
    tags: List<String>.from(x['tags'] ?? []),
    hints: List<String>.from(x['hints'] ?? []),
    imageUrls: List<String>.from(x['imageUrls'] ?? []),
    pairs: List<String>.from(x['pairs'] ?? []),
    isFavorite: x['isFavorite'] ?? false,
    repetitions: x['repetitions'] ?? 0,
    interval: x['interval'] ?? 0,
    ease: (x['ease'] ?? 2.5).toDouble(),
    next: DateTime.parse(x['next']),
    correct: x['correct'] ?? 0,
    incorrect: x['incorrect'] ?? 0,
    createdAt: x['createdAt'] == null
        ? null
        : DateTime.tryParse(x['createdAt']),
    updatedAt: x['updatedAt'] == null
        ? null
        : DateTime.tryParse(x['updatedAt']),
  );
}

class Profile {
  static const profileAvatars = [
    '🧑‍🎓',
    '👩‍🎓',
    '👨‍🎓',
    '🧑‍💻',
    '👩‍💻',
    '👨‍💻',
    '🦊',
    '🐼',
    '🐯',
    '🦁',
    '🐸',
    '🚀',
  ];
  static const profileGenders = ['unspecified', 'female', 'male', 'other'];

  static bool isValidProfileName(String v) {
    final t = v.trim();
    return t.length >= 2 && t.length <= 30;
  }

  static bool isValidProfileAge(String v) {
    final t = v.trim();
    if (t.isEmpty) return true; // opcional
    final n = int.tryParse(t);
    return n != null && n >= 5 && n <= 120;
  }
  int xp, answered, right, currentStreak, longestStreak;
  int marathonBest, sessionsCompleted, timeStudiedSeconds;
  int difficultFixed;
  String name;
  int? age;
  String gender; // 'unspecified' | 'female' | 'male' | 'other'
  String avatar; // emoji preset
  String? avatarPath; // foto local futura (hoy siempre null)
  List<String> achievements;
  Map<String, int> dailyAnswered;
  DateTime? lastStudy;
  DateTime? lastStudyDay;
  List<String> studyDays;
  Profile({
    this.xp = 0,
    this.answered = 0,
    this.right = 0,
    this.lastStudy,
    this.lastStudyDay,
    this.currentStreak = 0,
    this.longestStreak = 0,
    this.marathonBest = 0,
    this.sessionsCompleted = 0,
    this.timeStudiedSeconds = 0,
    this.difficultFixed = 0,
    this.name = 'Estudiante',
    this.age,
    this.gender = 'unspecified',
    this.avatar = '🧑‍🎓',
    this.avatarPath,
    List<String>? achievements,
    Map<String, int>? dailyAnswered,
    List<String>? studyDays,
  }) : studyDays = studyDays ?? [],
       achievements = achievements ?? [],
       dailyAnswered = dailyAnswered ?? {};
  int get level => levelForXp(xp);
  String get levelName => levelNames[(level - 1).clamp(0, levelNames.length - 1)];
  String levelNameForLang(String lang) => localizedLevelName(level, lang);
  // Compat: streak anterior siempre era 0/1.
  int get streak => currentStreak;
  /// Registra un día de estudio. Devuelve true si es un día nuevo (para +25 XP).
  bool registerStudyDay(DateTime now) {
    final today = dateOnly(now);
    final todayKey = dateKey(today);
    if (lastStudyDay != null && dateOnly(lastStudyDay!) == today) {
      lastStudy = now;
      if (!studyDays.contains(todayKey)) studyDays.add(todayKey);
      return false;
    }
    if (lastStudyDay == null) {
      currentStreak = 1;
    } else {
      final diff = today.difference(dateOnly(lastStudyDay!)).inDays;
      if (diff == 1) {
        currentStreak += 1;
      } else if (diff > 1) {
        currentStreak = 1;
      }
    }
    if (currentStreak > longestStreak) longestStreak = currentStreak;
    lastStudyDay = today;
    lastStudy = now;
    if (!studyDays.contains(todayKey)) {
      studyDays.add(todayKey);
      if (studyDays.length > 60) {
        studyDays = studyDays.sublist(studyDays.length - 60);
      }
    }
    return true;
  }

  bool studiedOn(DateTime day) => studyDays.contains(dateKey(dateOnly(day)));

  void recordAnswer({required bool correct, required DateTime now}) {
    answered++;
    if (correct) right++;
    final k = dateKey(dateOnly(now));
    dailyAnswered[k] = (dailyAnswered[k] ?? 0) + 1;
  }

  String get displayName => name.trim().isEmpty ? 'Estudiante' : name.trim();

  String genderLabel(String lang) {
    return genderMap[gender]?[lang] ?? genderMap[gender]?['en'] ?? genderMap['unspecified']!['es']!;
  }

  String metaLine(String lang) {
    final parts = <String>[];
    if (age != null) {
      final y = (lang == 'en' || lang == 'pt') ? 'y/o' : (lang == 'zh' ? '岁' : (lang == 'fr' ? 'ans' : (lang == 'de' ? 'Jahre' : 'años')));
      parts.add(lang == 'zh' ? '$age$y' : '$age $y');
    }
    if (gender != 'unspecified') parts.add(genderLabel(lang));
    return parts.join(' · ');
  }

  String get levelNameLocalized => localizedLevelName(level, 'es');
  String levelNameFor(String lang) => localizedLevelName(level, lang);

  Map<String, dynamic> json() => {
    'xp': xp,
    'answered': answered,
    'right': right,
    'last': lastStudy?.toIso8601String(),
    'lastStudyDay': lastStudyDay?.toIso8601String(),
    'currentStreak': currentStreak,
    'longestStreak': longestStreak,
    'studyDays': studyDays,
    'marathonBest': marathonBest,
    'sessionsCompleted': sessionsCompleted,
    'timeStudiedSeconds': timeStudiedSeconds,
    'difficultFixed': difficultFixed,
    'achievements': achievements,
    'dailyAnswered': dailyAnswered,
    'name': name,
    'age': age,
    'gender': gender,
    'avatar': avatar,
    'avatarPath': avatarPath,
  };
  factory Profile.from(Map<String, dynamic> x) {
    DateTime? legacyLast;
    if (x['last'] != null) {
      legacyLast = DateTime.tryParse(x['last']);
    }
    final explicitDay = x['lastStudyDay'] == null
        ? null
        : DateTime.tryParse(x['lastStudyDay']);
    // Migración: si había lastStudy pero sin racha, arrancar en 1.
    var cur = x['currentStreak'] ?? 0;
    var longest = x['longestStreak'] ?? 0;
    List<String> days = [];
    if (x['studyDays'] != null) {
      days = List<String>.from(x['studyDays']);
    }
    if (legacyLast != null && explicitDay == null && cur == 0) {
      cur = 1;
      longest = longest < 1 ? 1 : longest;
      final k = dateKey(dateOnly(legacyLast));
      if (!days.contains(k)) days.add(k);
    }
    return Profile(
      xp: x['xp'] ?? 0,
      answered: x['answered'] ?? 0,
      right: x['right'] ?? 0,
      lastStudy: legacyLast,
      lastStudyDay: explicitDay ?? legacyLast,
      currentStreak: cur,
      longestStreak: longest,
      studyDays: days,
      marathonBest: x['marathonBest'] ?? 0,
      sessionsCompleted: x['sessionsCompleted'] ?? 0,
      timeStudiedSeconds: x['timeStudiedSeconds'] ?? 0,
      difficultFixed: x['difficultFixed'] ?? 0,
      name: (x['name'] ?? 'Estudiante').toString(),
      age: x['age'] == null ? null : (x['age'] as num).toInt(),
      gender: (x['gender'] ?? 'unspecified').toString(),
      avatar: (x['avatar'] ?? '🧑‍🎓').toString(),
      avatarPath: x['avatarPath']?.toString(),
      achievements: x['achievements'] == null
          ? []
          : List<String>.from(x['achievements']),
      dailyAnswered: x['dailyAnswered'] == null
          ? {}
          : Map<String, int>.from(
              (x['dailyAnswered'] as Map).map(
                (k, v) => MapEntry(k.toString(), (v as num).toInt()),
              ),
            ),
    );
  }
}

/// A UI-independent, SM-2-inspired scheduling service.
class SpacedRepetitionService {
  void record(Question q, Rating r) {
    if (r == Rating.again) {
      q.repetitions = 0;
      q.interval = 1;
      q.ease = max(1.3, q.ease - .2);
      q.incorrect++;
    } else {
      q.correct++;
      q.repetitions++;
      q.ease = r == Rating.easy
          ? min(3, q.ease + .15)
          : r == Rating.hard
          ? max(1.3, q.ease - .15)
          : q.ease;
      q.interval = q.repetitions == 1
          ? 1
          : q.repetitions == 2
          ? 3
          : max(1, (q.interval * (r == Rating.hard ? 1.2 : q.ease)).round());
    }
    q.nextReview = DateTime.now().add(Duration(days: q.interval));
  }

  List<Question> due(List<Question> all, {DateTime? now}) {
    final n = now ?? DateTime.now();
    return all.where((q) => !q.nextReview.isAfter(n)).toList();
  }
}

/// Motor de sesiones §38: selección, mezcla y prioridad. Puro, testeable.
class StudySessionEngine {
  List<Question> buildQueue({
    required List<Question> all,
    required StudyMode mode,
    Deck? deck,
    int? limit,
    Set<QuestionType>? types,
    RandomOrder order = RandomOrder.random,
    bool onlyFavorites = false,
    String? tag,
    String? query,
    DateTime? now,
  }) {
    var pool = deck == null
        ? List<Question>.from(all)
        : all.where((q) => q.deckId == deck.id).toList();
    final n = now ?? DateTime.now();

    if (types != null && types.isNotEmpty) {
      pool = pool.where((q) => types.contains(q.type)).toList();
    }
    if (onlyFavorites) {
      pool = pool.where((q) => q.isFavorite).toList();
    }
    if (tag != null && tag.trim().isNotEmpty) {
      final t = normalizeAnswer(tag.trim());
      pool = pool
          .where((q) => q.tags.any((e) => normalizeAnswer(e) == t))
          .toList();
    }
    if (query != null && query.trim().isNotEmpty) {
      final qn = normalizeAnswer(query.trim());
      pool = pool
          .where(
            (q) =>
                normalizeAnswer(q.prompt).contains(qn) ||
                normalizeAnswer(q.answer).contains(qn),
          )
          .toList();
    }

    switch (mode) {
      case StudyMode.review:
        // Prioridad §39: vencidas > difíciles > nuevas > dominadas.
        pool.sort((a, b) {
          final aDue = !a.nextReview.isAfter(n) ? 0 : 1;
          final bDue = !b.nextReview.isAfter(n) ? 0 : 1;
          if (aDue != bDue) return aDue.compareTo(bDue);
          final aDiff = (a.incorrect - a.correct);
          final bDiff = (b.incorrect - b.correct);
          if (aDiff != bDiff) return bDiff.compareTo(aDiff);
          final aNew = (a.correct + a.incorrect) == 0 ? 0 : 1;
          final bNew = (b.correct + b.incorrect) == 0 ? 0 : 1;
          if (aNew != bNew) return aNew.compareTo(bNew);
          return a.nextReview.compareTo(b.nextReview);
        });
        break;
      case StudyMode.random:
        switch (order) {
          case RandomOrder.random:
            pool.shuffle();
            break;
          case RandomOrder.difficult:
            pool.sort(
              (a, b) => (b.incorrect - b.correct).compareTo(
                a.incorrect - a.correct,
              ),
            );
            break;
          case RandomOrder.leastStudied:
            pool.sort(
              (a, b) => (a.correct + a.incorrect).compareTo(
                b.correct + b.incorrect,
              ),
            );
            break;
          case RandomOrder.due:
            pool.sort((a, b) => a.nextReview.compareTo(b.nextReview));
            break;
        }
        break;
      case StudyMode.exam:
        pool.shuffle();
        break;
      case StudyMode.marathon:
        pool.shuffle();
        break;
    }

    if (limit != null && limit > 0 && pool.length > limit) {
      pool = pool.take(limit).toList();
    }
    return pool;
  }
}

class QueueStats {
  final int due, mastered, difficult, total;
  const QueueStats({
    required this.due,
    required this.mastered,
    required this.difficult,
    required this.total,
  });
}

QueueStats queueStats(List<Question> qs, {DateTime? now}) {
  final n = now ?? DateTime.now();
  return QueueStats(
    due: qs.where((q) => !q.nextReview.isAfter(n)).length,
    mastered: qs.where((q) => q.mastered).length,
    difficult: qs.where((q) => q.difficult).length,
    total: qs.length,
  );
}

/// Callback de estudio simple (compat). Para filtros usar StudySessionEngine directo.
typedef StudyFn = void Function(StudyMode mode, [Deck? deck]);

class StudySession {
  final String id;
  final String? deckId;
  final StudyMode mode;
  final DateTime startedAt;
  final DateTime finishedAt;
  final int questionsAnswered;
  final int correctAnswers;
  final int xpEarned;
  StudySession({
    required this.id,
    this.deckId,
    required this.mode,
    required this.startedAt,
    required this.finishedAt,
    required this.questionsAnswered,
    required this.correctAnswers,
    required this.xpEarned,
  });
  int get incorrectAnswers => questionsAnswered - correctAnswers;
  int get accuracy =>
      questionsAnswered == 0 ? 0 : (correctAnswers * 100 ~/ questionsAnswered);
  Map<String, dynamic> json() => {
    'id': id,
    'deckId': deckId,
    'mode': mode.name,
    'startedAt': startedAt.toIso8601String(),
    'finishedAt': finishedAt.toIso8601String(),
    'questionsAnswered': questionsAnswered,
    'correctAnswers': correctAnswers,
    'xpEarned': xpEarned,
  };
  factory StudySession.from(Map<String, dynamic> x) => StudySession(
    id: x['id'] ?? DateTime.now().microsecondsSinceEpoch.toString(),
    deckId: x['deckId'],
    mode: StudyMode.values.asNameMap()[x['mode']] ?? StudyMode.review,
    startedAt: DateTime.tryParse(x['startedAt'] ?? '') ?? DateTime.now(),
    finishedAt: DateTime.tryParse(x['finishedAt'] ?? '') ?? DateTime.now(),
    questionsAnswered: x['questionsAnswered'] ?? 0,
    correctAnswers: x['correctAnswers'] ?? 0,
    xpEarned: x['xpEarned'] ?? 0,
  );
}

class ReminderService {
  /// Calcula próximo recordatorio diario. Puro y testeable.
  /// Devuelve null si desactivado.
  static DateTime? nextReminder({
    required bool enabled,
    required int hour,
    required int minute,
    required DateTime now,
  }) {
    if (!enabled) return null;
    var next = DateTime(now.year, now.month, now.day, hour, minute);
    if (!next.isAfter(now)) next = next.add(const Duration(days: 1));
    return next;
  }

  static String label(DateTime? next, String lang) {
    if (next == null) {
      return tr(lang, 'disabled');
    }
    final h = next.hour.toString().padLeft(2, '0');
    final m = next.minute.toString().padLeft(2, '0');
    return '${tr(lang, 'nextAt')} $h:$m';
  }
}

class CsvCodec {
  /// Espera cabecera deckId,type,prompt,answer,options,accepted
  /// options separados por |, accepted por |. Devuelve preguntas.
  static List<Question> decode(String deckFallbackId, String raw) {
    final lines = const LineSplitter().convert(raw.trim());
    if (lines.isEmpty) return [];
    var start = 0;
    if (lines.first.toLowerCase().contains('prompt')) start = 1;
    final out = <Question>[];
    for (var k = start; k < lines.length; k++) {
      final parts = _splitCsvLine(lines[k]);
      if (parts.length < 2) continue;
      // Soporta 2 formatos: con deckId/type (6 cols) o simple prompt,answer
      String deckId = deckFallbackId;
      String typeName = 'flashcard';
      String prompt = '';
      String answer = '';
      String optionsRaw = '';
      String acceptedRaw = '';
      if (parts.length >= 6) {
        deckId = parts[0].isEmpty ? deckFallbackId : parts[0];
        typeName = parts[1].isEmpty ? 'flashcard' : parts[1];
        prompt = parts[2];
        answer = parts[3];
        optionsRaw = parts[4];
        acceptedRaw = parts[5];
      } else if (parts.length == 2) {
        prompt = parts[0];
        answer = parts[1];
      } else {
        continue;
      }
      if (prompt.trim().isEmpty || answer.trim().isEmpty) continue;
      QuestionType type;
      try {
        type = QuestionType.values.byName(typeName);
      } catch (_) {
        type = QuestionType.flashcard;
      }
      out.add(
        Question(
          id: '${DateTime.now().microsecondsSinceEpoch}-csv$k',
          deckId: deckId,
          type: type,
          prompt: prompt.trim(),
          answer: answer.trim(),
          options: optionsRaw.isEmpty
              ? <String>[]
              : optionsRaw
                    .split('|')
                    .map((e) => e.trim())
                    .where((e) => e.isNotEmpty)
                    .toList(),
          accepted: acceptedRaw.isEmpty
              ? <String>[]
              : acceptedRaw
                    .split('|')
                    .map((e) => e.trim())
                    .where((e) => e.isNotEmpty)
                    .toList(),
        ),
      );
    }
    return out;
  }

  static List<String> _splitCsvLine(String line) {
    final res = <String>[];
    final sb = StringBuffer();
    var inQuotes = false;
    for (var i = 0; i < line.length; i++) {
      final ch = line[i];
      if (ch == '"') {
        if (inQuotes && i + 1 < line.length && line[i + 1] == '"') {
          sb.write('"');
          i++;
        } else {
          inQuotes = !inQuotes;
        }
      } else if (ch == ',' && !inQuotes) {
        res.add(sb.toString().trim());
        sb.clear();
      } else {
        sb.write(ch);
      }
    }
    res.add(sb.toString().trim());
    return res;
  }
}

/// Contratos de repositorio §33: hoy implementación local SharedPreferences,
/// mañana Drift/SQLite o nube sin cambiar UI. Estructura futura:
/// lib/core/, lib/data/, lib/domain/, lib/presentation/ (ver carpetas creadas).
abstract class DeckRepository {
  List<Deck> get decks;
  Future<void> addDeck(Deck deck);
  Future<void> updateDeck(Deck deck);
  Future<void> removeDeck(String id);
}

abstract class QuestionRepository {
  List<Question> get questions;
  List<Question> byDeck(String deckId);
  Future<void> addQuestion(Question q);
  Future<void> updateQuestion(Question q);
  Future<void> removeQuestion(String id);
}

abstract class SessionRepository {
  List<StudySession> get sessions;
  Future<void> addSession(StudySession s);
}

class AppStore extends ChangeNotifier
    implements DeckRepository, QuestionRepository, SessionRepository {
  @override
  Future<void> addDeck(Deck deck) async {
    decks.add(deck);
    await save();
  }

  @override
  Future<void> updateDeck(Deck deck) async {
    deck.updatedAt = DateTime.now();
    await save();
  }

  @override
  Future<void> removeDeck(String id) async {
    decks.removeWhere((d) => d.id == id);
    questions.removeWhere((q) => q.deckId == id);
    await save();
  }

  @override
  List<Question> byDeck(String deckId) => deckQuestions(deckId);

  @override
  Future<void> addQuestion(Question q) async {
    questions.add(q);
    await save();
  }

  @override
  Future<void> updateQuestion(Question q) async {
    q.updatedAt = DateTime.now();
    await save();
  }

  @override
  Future<void> removeQuestion(String id) async {
    questions.removeWhere((q) => q.id == id);
    await save();
  }

  @override
  Future<void> addSession(StudySession s) async {
    sessions.add(s);
    await save();
  }

  @override
  final decks = <Deck>[];
  @override
  final questions = <Question>[];
  @override
  final sessions = <StudySession>[];
  Profile profile = Profile();
  AppSettings settings = AppSettings();
  bool onboardingSeen = false;
  SharedPreferences? _prefs;
  Future<void> load() async {
    _prefs = await SharedPreferences.getInstance();
    // Migración MrCards: lee nueva clave, fallback a antigua flashcards.v1
    var raw = _prefs!.getString('mrcards.v1') ?? _prefs!.getString('flashcards.v1');
    if (raw != null) {
      try {
        final x = jsonDecode(raw);
        decks.addAll((x['decks'] as List).map((e) => Deck.from(e)));
        questions.addAll((x['questions'] as List).map((e) => Question.from(e)));
        profile = Profile.from(x['profile'] ?? {});
        if (x['sessions'] != null) {
          sessions.addAll(
            (x['sessions'] as List).map((e) => StudySession.from(e)),
          );
        }
      } catch (_) {}
    }
    var sraw = _prefs!.getString('mrcards.settings.v1') ?? _prefs!.getString('flashcards.settings.v1');
    if (sraw != null) {
      try {
        settings = AppSettings.from(jsonDecode(sraw));
      } catch (_) {}
    }
    currentLang = settings.language;
    onboardingSeen = _prefs!.getBool('mrcards.onboarding.v1') ?? _prefs!.getBool('flashcards.onboarding.v1') ?? false;
  }

  Future<void> save() async {
    final prefs = _prefs ?? await SharedPreferences.getInstance();
    _prefs = prefs;
    // Recorta historial a 50 para no crecer sin límite.
    final kept = sessions.length > 50
        ? sessions.sublist(sessions.length - 50)
        : List<StudySession>.from(sessions);
    if (sessions.length > 50) {
      sessions
        ..clear()
        ..addAll(kept);
    }
    await prefs.setString(
      'mrcards.v1',
      jsonEncode({
        'decks': decks.map((x) => x.json()).toList(),
        'questions': questions.map((x) => x.json()).toList(),
        'profile': profile.json(),
        'sessions': kept.map((x) => x.json()).toList(),
      }),
    );
    // Mantener antigua clave para compatibilidad temporal
    await prefs.setString(
      'flashcards.v1',
      jsonEncode({
        'decks': decks.map((x) => x.json()).toList(),
        'questions': questions.map((x) => x.json()).toList(),
        'profile': profile.json(),
        'sessions': kept.map((x) => x.json()).toList(),
      }),
    );
    notifyListeners();
  }

  Future<void> saveSettings() async {
    currentLang = settings.language;
    final prefs = _prefs ?? await SharedPreferences.getInstance();
    _prefs = prefs;
    await prefs.setString(
      'mrcards.settings.v1',
      jsonEncode(settings.json()),
    );
    await prefs.setString(
      'flashcards.settings.v1',
      jsonEncode(settings.json()),
    );
    notifyListeners();
  }

  Future<void> completeOnboarding() async {
    onboardingSeen = true;
    final prefs = _prefs ?? await SharedPreferences.getInstance();
    await prefs.setBool('mrcards.onboarding.v1', true);
    await prefs.setBool('flashcards.onboarding.v1', true);
    notifyListeners();
  }

  List<Question> deckQuestions(String id) =>
      questions.where((x) => x.deckId == id).toList();

  List<Question> search(String query) {
    final q = query.trim();
    if (q.isEmpty) return [];
    return StudySessionEngine().buildQueue(
      all: questions,
      mode: StudyMode.random,
      order: RandomOrder.random,
      query: q,
    );
  }

  String exportJson() => jsonEncode({
    'app': 'mrcards',
    'version': 2,
    'exportedAt': DateTime.now().toIso8601String(),
    'decks': decks.map((x) => x.json()).toList(),
    'questions': questions.map((x) => x.json()).toList(),
    'profile': profile.json(),
    'sessions': sessions.map((x) => x.json()).toList(),
  });

  /// Devuelve número de preguntas importadas.
  int importJson(String raw, {bool replace = false}) {
    final x = jsonDecode(raw);
    final importedDecks =
        ((x['decks'] ?? []) as List).map((e) => Deck.from(e)).toList();
    final importedQs =
        ((x['questions'] ?? []) as List).map((e) => Question.from(e)).toList();
    if (replace) {
      decks
        ..clear()
        ..addAll(importedDecks);
      questions
        ..clear()
        ..addAll(importedQs);
      if (x['sessions'] != null) {
        sessions
          ..clear()
          ..addAll((x['sessions'] as List).map((e) => StudySession.from(e)));
      }
    } else {
      final deckIds = decks.map((d) => d.id).toSet();
      for (final d in importedDecks) {
        if (!deckIds.contains(d.id)) decks.add(d);
      }
      final qIds = questions.map((q) => q.id).toSet();
      for (final q in importedQs) {
        if (qIds.contains(q.id)) continue;
        // Si el deck no existe, igual se importa (queda huérfana pero visible en global).
        questions.add(q);
      }
    }
    notifyListeners();
    return importedQs.length;
  }

  int importCsv(String deckFallbackId, String raw) {
    final list = CsvCodec.decode(deckFallbackId, raw);
    questions.addAll(list);
    final deckExists = decks.any((d) => d.id == deckFallbackId);
    if (!deckExists && list.isNotEmpty) {
      decks.add(Deck(id: deckFallbackId, title: 'Importado'));
    }
    notifyListeners();
    return list.length;
  }

  String exportCsv() {
    final sb = StringBuffer('deckId,type,prompt,answer,options,accepted\n');
    String esc(String s) => '"${s.replaceAll('"', '""')}"';
    for (final q in questions) {
      sb.writeln(
        '${q.deckId},${q.type.name},${esc(q.prompt)},${esc(q.answer)},${esc(q.options.join('|'))},${esc(q.accepted.join('|'))}',
      );
    }
    return sb.toString();
  }

  /// Crea preguntas rápidas "Pregunta | Respuesta" en un deck.
  List<Question> bulkAdd(String deckId, String raw) {
    final out = <Question>[];
    for (final line in raw.split('\n')) {
      final t = line.trim();
      if (t.isEmpty) continue;
      final sep = t.contains('|') ? '|' : (t.contains('\t') ? '\t' : null);
      if (sep == null) continue;
      final parts = t.split(sep);
      if (parts.length < 2) continue;
      final prompt = parts.first.trim();
      final answer = parts.sublist(1).join(sep).trim();
      if (prompt.isEmpty || answer.isEmpty) continue;
      out.add(
        Question(
          id: '${DateTime.now().microsecondsSinceEpoch}-${out.length}',
          deckId: deckId,
          type: QuestionType.flashcard,
          prompt: prompt,
          answer: answer,
        ),
      );
    }
    questions.addAll(out);
    notifyListeners();
    return out;
  }
}

class MrCardsApp extends StatelessWidget {
  const MrCardsApp({super.key, required this.store});
  final AppStore store;
  @override
  Widget build(BuildContext c) => AnimatedBuilder(
    animation: store,
    builder: (context, _) {
      final themeMode = switch (store.settings.themeMode) {
        AppThemeMode.light => ThemeMode.light,
        AppThemeMode.dark => ThemeMode.dark,
        AppThemeMode.system => ThemeMode.system,
      };
      return MaterialApp(
        debugShowCheckedModeBanner: false,
        title: 'MrCards',
        theme: _theme(Brightness.light),
        darkTheme: _theme(Brightness.dark),
        themeMode: themeMode,
        home: store.onboardingSeen
            ? Shell(store: store)
            : OnboardingScreen(store: store),
      );
    },
  );
  ThemeData _theme(Brightness b) => ThemeData(
    useMaterial3: true,
    brightness: b,
    colorScheme: ColorScheme.fromSeed(
      seedColor: const Color(0xff6c4df6),
      brightness: b,
    ),
    scaffoldBackgroundColor: b == Brightness.dark
        ? const Color(0xff0b1020)
        : const Color(0xfff7f8fc),
    inputDecorationTheme: InputDecorationTheme(
      border: OutlineInputBorder(
        borderRadius: BorderRadius.all(Radius.circular(14)),
      ),
    ),
  );
}

typedef FlashCards = MrCardsApp;

class OnboardingScreen extends StatefulWidget {
  const OnboardingScreen({super.key, required this.store});
  final AppStore store;
  @override
  State<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends State<OnboardingScreen> {
  final controller = PageController();
  final profileForm = GlobalKey<FormState>();
  late final nameCtrl = TextEditingController(text: _initialName());
  late final ageCtrl = TextEditingController(
    text: widget.store.profile.age?.toString() ?? '',
  );
  late String gender = Profile.profileGenders.contains(
    widget.store.profile.gender,
  )
      ? widget.store.profile.gender
      : 'unspecified';
  late String avatar = Profile.profileAvatars.contains(
    widget.store.profile.avatar,
  )
      ? widget.store.profile.avatar
      : Profile.profileAvatars.first;
  bool? createSamples;
  bool samplesCreated = false;
  int page = 0;
  static const totalPages = 5;

  String _initialName() {
    final n = widget.store.profile.name;
    return n == 'Estudiante' ? '' : n;
  }

  String _genderLabel(String g) {
    const map = {
      'female': 'Femenino',
      'male': 'Masculino',
      'other': 'Otro',
      'unspecified': 'Prefiero no decir',
    };
    return map[g] ?? map['unspecified']!;
  }

  Future<void> _saveProfile() async {
    final p = widget.store.profile;
    final n = nameCtrl.text.trim();
    if (n.isNotEmpty) p.name = n;
    final at = ageCtrl.text.trim();
    p.age = at.isEmpty ? null : int.tryParse(at);
    p.gender = gender;
    p.avatar = avatar;
    await widget.store.save();
  }

  Future<void> _ensureSampleDeck() async {
    if (samplesCreated) return;
    samplesCreated = true;
    final base = DateTime.now().microsecondsSinceEpoch;
    final math = Deck(
      id: 'starter-$base-math',
      title: 'Matemáticas',
      description: 'Ejemplos de matemáticas',
      category: 'Matemáticas',
      icon: '➗',
      color: 0xff3b82f6,
    );
    final sci = Deck(
      id: 'starter-$base-sci',
      title: 'Ciencias',
      description: 'Ejemplos de ciencias',
      category: 'Ciencias',
      icon: '🧬',
      color: 0xff22c55e,
    );
    final hist = Deck(
      id: 'starter-$base-hist',
      title: 'Historia',
      description: 'Ejemplos de historia',
      category: 'Historia',
      icon: '🏛️',
      color: 0xfff59e0b,
    );
    final tec = Deck(
      id: 'starter-$base-tec',
      title: 'Técnicas',
      description: 'Ordenar, relacionar e imágenes',
      category: 'General',
      icon: '🧩',
      color: 0xff8b5cf6,
    );
    widget.store.decks.addAll([math, sci, hist, tec]);
    widget.store.questions.addAll([
      // Matemáticas
      Question(
        id: '$base-m1',
        deckId: math.id,
        type: QuestionType.multipleChoice,
        prompt: '¿Cuánto es 7 × 8?',
        answer: '56',
        options: ['54', '56', '58', '64'],
        explanation: '7 por 8 son 56.',
      ),
      Question(
        id: '$base-m2',
        deckId: math.id,
        type: QuestionType.written,
        prompt: '¿Cuál es la raíz cuadrada de 144?',
        answer: '12',
        accepted: ['doce'],
        explanation: '12 × 12 = 144.',
      ),
      Question(
        id: '$base-m3',
        deckId: math.id,
        type: QuestionType.trueFalse,
        prompt: 'El valor de π es aproximadamente 3.14.',
        answer: 'Verdadero',
        explanation: 'π ≈ 3.1416.',
      ),
      // Ciencias
      Question(
        id: '$base-s1',
        deckId: sci.id,
        type: QuestionType.written,
        prompt: '¿Cuál es la fórmula química del agua?',
        answer: 'H2O',
        accepted: ['H₂O', 'h2o'],
        explanation: 'Dos átomos de hidrógeno y uno de oxígeno.',
      ),
      Question(
        id: '$base-s2',
        deckId: sci.id,
        type: QuestionType.multipleChoice,
        prompt: '¿Qué planeta es conocido como el planeta rojo?',
        answer: 'Marte',
        options: ['Venus', 'Marte', 'Júpiter', 'Saturno'],
        explanation: 'Marte tiene óxido de hierro en su superficie.',
      ),
      Question(
        id: '$base-s3',
        deckId: sci.id,
        type: QuestionType.trueFalse,
        prompt: 'La fotosíntesis produce oxígeno.',
        answer: 'Verdadero',
        explanation: 'Las plantas liberan O₂ al convertir luz en energía.',
      ),
      Question(
        id: '$base-s4',
        deckId: sci.id,
        type: QuestionType.flashcard,
        prompt: '¿Qué animal es conocido como el "rey de la selva"?',
        answer: 'León',
        explanation: 'El león es el "rey" por su melena y comportamiento social.',
        hints: ['Es un mamífero.', 'Vive en la sabana.', 'Tiene melena.'],
      ),
      // Historia
      Question(
        id: '$base-h1',
        deckId: hist.id,
        type: QuestionType.written,
        prompt: '¿En qué año llegó el ser humano a la Luna?',
        answer: '1969',
        explanation: 'Apolo 11 alunizó el 20 de julio de 1969.',
      ),
      Question(
        id: '$base-h2',
        deckId: hist.id,
        type: QuestionType.multipleChoice,
        prompt: '¿Qué imperio tuvo su capital en Cuzco?',
        answer: 'Inca',
        options: ['Azteca', 'Maya', 'Inca', 'Olmeca'],
        explanation: 'El Tahuantinsuyo con capital en Cuzco.',
      ),
      Question(
        id: '$base-h3',
        deckId: hist.id,
        type: QuestionType.trueFalse,
        prompt: 'La Revolución Francesa inició en 1789.',
        answer: 'Verdadero',
        explanation: 'Con la toma de la Bastilla el 14 de julio de 1789.',
      ),
      // Técnicas — cubre los mockups 5-8
      Question(
        id: '$base-t1',
        deckId: tec.id,
        type: QuestionType.ordering,
        prompt: 'Ordena las fases del ciclo del agua:',
        answer: 'Evaporación,Condensación,Precipitación,Acumulación',
        options: ['Evaporación', 'Condensación', 'Precipitación', 'Acumulación'],
        explanation: 'El agua se evapora, condensa, precipita y se acumula.',
      ),
      Question(
        id: '$base-t2',
        deckId: tec.id,
        type: QuestionType.matching,
        prompt: 'Une cada elemento con su pareja.',
        answer: '',
        pairs: ['Agua|CO₂', 'Dióxido de carbono|H₂O', 'Oxígeno|C₆H₁₂O₆', 'Glucosa|O₂'],
        explanation: 'Relaciona cada compuesto con su símbolo.',
      ),
      Question(
        id: '$base-t3',
        deckId: tec.id,
        type: QuestionType.imageChoice,
        prompt: '¿Cuál de estos animales es un delfín?',
        answer: 'dolphin',
        imageUrls: ['dog', 'dolphin', 'cat', 'shark'],
        explanation: 'El delfín es el segundo de arriba a la derecha.',
      ),
    ]);
    await widget.store.save();
  }

  Future<void> _next() async {
    FeedbackService.select(widget.store.settings);
    final anim = widget.store.settings.animationsEnabled;
    if (page == 2) {
      if (!(profileForm.currentState?.validate() ?? false)) return;
      await _saveProfile();
    }
    if (page == 3 && createSamples == true) {
      await _ensureSampleDeck();
    }
    if (page < totalPages - 1) {
      controller.nextPage(
        duration: Duration(milliseconds: anim ? 300 : 1),
        curve: Curves.easeOut,
      );
    } else {
      await widget.store.completeOnboarding();
    }
  }

  Future<void> _skip() async {
    FeedbackService.select(widget.store.settings);
    await widget.store.completeOnboarding();
  }

  void _back() {
    FeedbackService.select(widget.store.settings);
    controller.previousPage(
      duration: const Duration(milliseconds: 250),
      curve: Curves.easeOut,
    );
  }

  String _nextLabel() {
    if (page == totalPages - 1) return t('startStudy');
    if (page == 2) return t('saveContinue');
    if (page == 3) return createSamples == null ? 'Continuar' : 'Continuar';
    return t('next');
  }

  bool get _canContinue {
    if (page == 2) return true; // valida al pulsar
    return true;
  }

  @override
  Widget build(BuildContext c) {
    final p = widget.store.profile;
    return Scaffold(
      appBar: AppBar(
        automaticallyImplyLeading: false,
        title: Text('${t('step')} ${page + 1} ${t('of')} $totalPages'),
        actions: [
          if (page < totalPages - 1)
            TextButton(onPressed: _skip, child: Text(t('skip'))),
        ],
      ),
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: PageView(
                controller: controller,
                physics: page == 2
                    ? const NeverScrollableScrollPhysics()
                    : null,
                onPageChanged: (v) => setState(() => page = v),
                children: [
                  _OnboardPage(
                    emoji: '👋',
                    title: t('welcomeTitle'),
                    subtitle:
                        t('welcomeSub'),
                  ),
                  _OnboardHowItWorks(),
                  _OnboardProfileForm(
                    formKey: profileForm,
                    nameCtrl: nameCtrl,
                    ageCtrl: ageCtrl,
                    gender: gender,
                    avatar: avatar,
                    onGender: (v) => setState(() => gender = v),
                    onAvatar: (v) => setState(() => avatar = v),
                    genderLabel: _genderLabel,
                  ),
                  _OnboardFirstDeck(
                    selected: createSamples,
                    onSelect: (v) => setState(() => createSamples = v),
                  ),
                  _OnboardReady(
                    name: nameCtrl.text.trim().isEmpty
                        ? p.displayName
                        : nameCtrl.text.trim(),
                    avatar: avatar,
                    withSamples: createSamples == true,
                  ),
                ],
              ),
            ),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: List.generate(
                totalPages,
                (k) => Container(
                  margin: const EdgeInsets.all(4),
                  width: page == k ? 24 : 8,
                  height: 8,
                  decoration: BoxDecoration(
                    color: page == k
                        ? Theme.of(c).colorScheme.primary
                        : Colors.grey.shade400,
                    borderRadius: BorderRadius.circular(8),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 12),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: Row(
                children: [
                  if (page > 0)
                    Expanded(
                      child: OutlinedButton(
                        onPressed: _back,
                        child: Text(t('back')),
                      ),
                    ),
                  if (page > 0) const SizedBox(width: 12),
                  Expanded(
                    flex: 2,
                    child: FilledButton(
                      onPressed: _canContinue ? _next : null,
                      child: Text(_nextLabel()),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
          ],
        ),
      ),
    );
  }
}

class _OnboardHowItWorks extends StatelessWidget {
  _OnboardHowItWorks();
  @override
  Widget build(BuildContext c) => Padding(
    padding: EdgeInsets.all(28),
    child: Column(
      mainAxisAlignment: MainAxisAlignment.center,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Center(child: Text('🧠', style: TextStyle(fontSize: 64))),
        SizedBox(height: 16),
        Center(
          child: Text(
            t('howTitle'),
            style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold),
            textAlign: TextAlign.center,
          ),
        ),
        SizedBox(height: 20),
        Text(t('how1')),
        SizedBox(height: 10),
        Text(t('how2')),
        SizedBox(height: 10),
        Text(t('how3')),
      ],
    ),
  );
}

class _OnboardProfileForm extends StatelessWidget {
  const _OnboardProfileForm({
    required this.formKey,
    required this.nameCtrl,
    required this.ageCtrl,
    required this.gender,
    required this.avatar,
    required this.onGender,
    required this.onAvatar,
    required this.genderLabel,
  });
  final GlobalKey<FormState> formKey;
  final TextEditingController nameCtrl, ageCtrl;
  final String gender, avatar;
  final void Function(String) onGender, onAvatar;
  final String Function(String) genderLabel;
  @override
  Widget build(BuildContext c) => Form(
    key: formKey,
    child: ListView(
      padding: const EdgeInsets.all(24),
      children: [
        Center(child: Text('🧑‍🎓', style: TextStyle(fontSize: 48))),
        const SizedBox(height: 8),
        Center(child: Text(t('createUser'),
            style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold),
          ),
        ),
        Center(child: Text(t('profileLocal'))),
        const SizedBox(height: 16),
        Center(
          child: ProfileAvatar(avatar, radius: 36),
        ),
        const SizedBox(height: 10),
        Wrap(
          alignment: WrapAlignment.center,
          spacing: 6,
          runSpacing: 6,
          children: Profile.profileAvatars
              .map(
                (e) => ChoiceChip(
                  label: Text(e),
                  selected: avatar == e,
                  onSelected: (_) => onAvatar(e),
                ),
              )
              .toList(),
        ),
        const SizedBox(height: 14),
        TextFormField(
          controller: nameCtrl,
          decoration: InputDecoration(labelText: 'Nombre *'),
          validator: (x) => Profile.isValidProfileName(x ?? '')
              ? null
              : 'Nombre de 2 a 30 caracteres',
        ),
        const SizedBox(height: 12),
        TextFormField(
          controller: ageCtrl,
          keyboardType: TextInputType.number,
          decoration: InputDecoration(labelText: 'Edad (opcional)'),
          validator: (x) => Profile.isValidProfileAge(x ?? '')
              ? null
              : 'Edad válida de 5 a 120',
        ),
        const SizedBox(height: 12),
        DropdownButtonFormField<String>(
          initialValue: gender,
          decoration: InputDecoration(labelText: 'Género'),
          items: Profile.profileGenders
              .map((g) => DropdownMenuItem(value: g, child: Text(genderLabel(g))))
              .toList(),
          onChanged: (v) => onGender(v ?? 'unspecified'),
        ),
      ],
    ),
  );
}

class _OnboardFirstDeck extends StatelessWidget {
  const _OnboardFirstDeck({required this.selected, required this.onSelect});
  final bool? selected;
  final void Function(bool) onSelect;
  @override
  Widget build(BuildContext c) => Padding(
    padding: const EdgeInsets.all(24),
    child: Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        const Text('📚', style: TextStyle(fontSize: 64)),
        const SizedBox(height: 12),
        const Text(
          'Tu primer cuestionario',
          style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold),
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 8),
        const Text(
          'Empieza con ejemplos para probar el repaso o desde cero.',
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 16),
        Card(
          child: ListTile(
            leading: const Text('🚀', style: TextStyle(fontSize: 28)),
            title: Text(t('createWithExamples')),
            subtitle: Text(t('cardsReady')),
            trailing: Icon(
              selected == true
                  ? Icons.radio_button_checked
                  : Icons.radio_button_unchecked,
              color: selected == true
                  ? Theme.of(c).colorScheme.primary
                  : null,
            ),
            onTap: () => onSelect(true),
          ),
        ),
        Card(
          child: ListTile(
            leading: const Text('📝', style: TextStyle(fontSize: 28)),
            title: Text(t('startEmpty')),
            subtitle: Text(t('createLater')),
            trailing: Icon(
              selected == false
                  ? Icons.radio_button_checked
                  : Icons.radio_button_unchecked,
              color: selected == false
                  ? Theme.of(c).colorScheme.primary
                  : null,
            ),
            onTap: () => onSelect(false),
          ),
        ),
      ],
    ),
  );
}

class _OnboardReady extends StatelessWidget {
  const _OnboardReady({
    required this.name,
    required this.avatar,
    required this.withSamples,
  });
  final String name, avatar;
  final bool withSamples;
  @override
  Widget build(BuildContext c) => Padding(
    padding: const EdgeInsets.all(32),
    child: Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        const Text('🎉', style: TextStyle(fontSize: 64)),
        const SizedBox(height: 12),
        Text(
          '¡Listo, $name! $avatar',
          style: const TextStyle(fontSize: 22, fontWeight: FontWeight.bold),
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 8),
        Text(
          withSamples
              ? 'Tu usuario está creado y tienes 4 cuestionarios listos (Matemáticas, Ciencias, Historia, Técnicas). ¡Pulsa abajo para estudiar!'
              : 'Tu usuario está creado. Pulsa abajo para crear tu primer cuestionario.',
          textAlign: TextAlign.center,
        ),
      ],
    ),
  );
}

class _OnboardPage extends StatelessWidget {
  _OnboardPage({
    required this.emoji,
    required this.title,
    required this.subtitle,
  });
  final String emoji, title, subtitle;
  @override
  Widget build(BuildContext c) => Padding(
    padding: const EdgeInsets.all(32),
    child: Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Text(emoji, style: const TextStyle(fontSize: 72)),
        const SizedBox(height: 24),
        Text(
          title,
          style: Theme.of(c).textTheme.headlineSmall?.copyWith(
            fontWeight: FontWeight.bold,
          ),
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 12),
        Text(subtitle, textAlign: TextAlign.center),
      ],
    ),
  );
}

class Shell extends StatefulWidget {
  const Shell({super.key, required this.store});
  final AppStore store;
  @override
  State<Shell> createState() => _ShellState();
}

class _ShellState extends State<Shell> {
  int tab = 0;
  @override
  Widget build(BuildContext c) {
    final pages = [
      Home(store: widget.store, study: _study),
      StudyChoices(store: widget.store, study: _study),
      DeckList(store: widget.store, study: _study),
      Stats(store: widget.store),
    ];
    return Scaffold(
      body: SafeArea(child: pages[tab.clamp(0, pages.length - 1)]),
      bottomNavigationBar: NavigationBar(
        selectedIndex: tab.clamp(0, pages.length - 1),
        onDestinationSelected: (x) {
          FeedbackService.select(widget.store.settings);
          setState(() => tab = x);
        },
        destinations: [
          NavigationDestination(
            icon: Icon(Icons.home_outlined),
            selectedIcon: Icon(Icons.home),
            label: t('shellHome'),
          ),
          NavigationDestination(
            icon: Icon(Icons.school_outlined),
            selectedIcon: Icon(Icons.school),
            label: t('studyAction'),
          ),
          NavigationDestination(
            icon: Icon(Icons.collections_bookmark_outlined),
            selectedIcon: Icon(Icons.collections_bookmark),
            label: t('shellDecks'),
          ),
          NavigationDestination(
            icon: Icon(Icons.bar_chart_outlined),
            selectedIcon: Icon(Icons.bar_chart),
            label: t('shellStats'),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _addDeck,
        icon: const Icon(Icons.add),
        label: Text(t('create')),
      ),
    );
  }

  Future<void> _addDeck() async {
    final d = await Navigator.push<Deck>(
      context,
      MaterialPageRoute(builder: (_) => const DeckForm()),
    );
    if (d != null) {
      widget.store.decks.add(d);
      FeedbackService.select(widget.store.settings);
      final newly = checkAchievements(widget.store);
      await widget.store.save();
      if (!mounted) return;
      if (newly.contains('collector_10')) {
        FeedbackService.achievement(widget.store.settings);
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('🏆 ¡Logro: Coleccionista!')),
        );
      }
    }
  }

  void _study(StudyMode mode, [Deck? deck]) {
    final engine = StudySessionEngine();
    final q = engine.buildQueue(
      all: widget.store.questions,
      mode: mode,
      deck: deck,
    );
    if (q.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Agrega preguntas para comenzar.')),
      );
      return;
    }
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => StudyScreen(
          store: widget.store,
          mode: mode,
          questions: q,
          deck: deck,
        ),
      ),
    );
  }
}

/// Avatar de perfil con emoji siempre contenido en el círculo,
/// incluso con fuentes grandes o emojis compuestos (ZWJ).
class ProfileAvatar extends StatelessWidget {
  const ProfileAvatar(this.emoji, {super.key, this.radius = 20});
  final String emoji;
  final double radius;
  @override
  Widget build(BuildContext c) => CircleAvatar(
    radius: radius,
    child: SizedBox(
      width: radius * 2,
      height: radius * 2,
      child: Padding(
        padding: EdgeInsets.all(radius * 0.18),
        child: FittedBox(
          fit: BoxFit.scaleDown,
          child: Text(
            emoji,
            style: TextStyle(fontSize: radius),
            textScaler: const TextScaler.linear(1.0),
          ),
        ),
      ),
    ),
  );
}

class TitleBar extends StatelessWidget {
  const TitleBar(this.text, {super.key, this.action});
  final String text;
  final Widget? action;
  @override
  Widget build(BuildContext c) => Padding(
    padding: const EdgeInsets.fromLTRB(20, 20, 20, 12),
    child: Row(
      children: [
        Expanded(
          child: Text(
            text,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(c).textTheme.headlineMedium
               ?.copyWith(fontWeight: FontWeight.bold),
          ),
        ),
        action ?? const SizedBox.shrink(),
      ],
    ),
  );
}

class TinyStat extends StatelessWidget {
  const TinyStat(this.icon, this.value, this.label, {super.key});
  final IconData icon;
  final String value, label;
  @override
  Widget build(BuildContext c) => Expanded(
    child: Card(
      child: Padding(
        padding: const EdgeInsets.all(10),
        child: Column(
          children: [
            Icon(icon, color: Theme.of(c).colorScheme.primary),
            Text(
              value,
              style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 18),
            ),
            Text(
              label,
              style: Theme.of(c).textTheme.labelSmall,
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    ),
  );
}

class StreakWeek extends StatelessWidget {
  const StreakWeek({super.key, required this.profile});
  final Profile profile;
  @override
  Widget build(BuildContext c) {
    final now = DateTime.now();
    // Lunes como inicio de semana.
    final monday = dateOnly(now).subtract(Duration(days: now.weekday - 1));
    const labels = ['L', 'M', 'X', 'J', 'V', 'S', 'D'];
    // Adaptable: en pantallas angostas los círculos se encogen en vez de desbordar.
    return LayoutBuilder(
      builder: (context, constraints) {
        final maxW = constraints.maxWidth.isFinite
            ? constraints.maxWidth
            : MediaQuery.of(context).size.width;
        final d = (maxW / 7 - 10).clamp(24.0, 34.0);
        return Row(
          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
          children: List.generate(7, (k) {
            final day = monday.add(Duration(days: k));
            final done = profile.studiedOn(day);
            final isToday = dateOnly(day) == dateOnly(now);
            return Flexible(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: d,
                    height: d,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: done
                          ? Theme.of(c).colorScheme.primary
                          : Theme.of(c).colorScheme.surfaceContainerHighest,
                      border: isToday
                          ? Border.all(
                              color: Theme.of(c).colorScheme.primary,
                              width: 2,
                            )
                          : null,
                    ),
                    child: Center(
                      child: FittedBox(
                        fit: BoxFit.scaleDown,
                        child: Text(
                          done ? '✓' : labels[k],
                          style: TextStyle(
                            color: done
                                ? Theme.of(c).colorScheme.onPrimary
                                : Theme.of(c).colorScheme.onSurface,
                            fontWeight: FontWeight.bold,
                          ),
                          textScaler: const TextScaler.linear(1.0),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    labels[k],
                    style: Theme.of(c).textTheme.labelSmall,
                    maxLines: 1,
                  ),
                ],
              ),
            );
          }),
        );
      },
    );
  }
}

class Home extends StatelessWidget {
  const Home({super.key, required this.store, required this.study});
  final AppStore store;
  final StudyFn study;
  @override
  Widget build(BuildContext c) {
    final stats = queueStats(store.questions);
    final difficult = store.questions.where((q) => q.difficult).toList();
    return ListView(
      children: [
        TitleBar(
          'Hola, ${store.profile.displayName} 👋',
          action: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              GestureDetector(
                onTap: () {
                  FeedbackService.select(store.settings);
                  Navigator.push(
                    c,
                    MaterialPageRoute(
                      builder: (_) => ProfilePage(store: store),
                    ),
                  );
                },
                child: Tooltip(
                  message: 'Mi perfil',
                  child: ProfileAvatar(store.profile.avatar, radius: 18),
                ),
              ),
              IconButton(
                icon: const Icon(Icons.search),
                tooltip: t('search'),
                onPressed: () {
                  FeedbackService.select(store.settings);
                  Navigator.push(
                    c,
                    MaterialPageRoute(
                      builder: (_) => SearchScreen(store: store, study: study),
                    ),
                  );
                },
              ),
            ],
          ),
        ),
        const Padding(
          padding: EdgeInsets.symmetric(horizontal: 20),
          child: Text(
            '¡Listo para aprender hoy?',
            style: TextStyle(fontSize: 17),
          ),
        ),
        Padding(
          padding: const EdgeInsets.all(20),
          child: Row(
            children: [
              TinyStat(
                Icons.local_fire_department,
                '${store.profile.currentStreak}',
                'racha',
              ),
              const SizedBox(width: 8),
              TinyStat(Icons.stars, '${store.profile.xp}', 'XP'),
              const SizedBox(width: 8),
              TinyStat(
                Icons.workspace_premium,
                'Nv ${store.profile.level}',
                store.profile.levelName,
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20),
          child: Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '🔥 ${store.profile.currentStreak} días · Mejor: ${store.profile.longestStreak}',
                    style: const TextStyle(fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 12),
                  StreakWeek(profile: store.profile),
                ],
              ),
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20),
          child: Card(
            color: Theme.of(c).colorScheme.primaryContainer,
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Repasos pendientes',
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                  ),
                  Text(
                    '${stats.due} preguntas',
                    style: Theme.of(c).textTheme.headlineSmall,
                  ),
                  const SizedBox(height: 8),
                  Text(
                    '🟢 ${stats.mastered} dominadas · 🔴 ${stats.difficult} difíciles',
                  ),
                  const SizedBox(height: 12),
                  Wrap(
                    spacing: 8,
                    children: [
                      FilledButton.icon(
                        onPressed: stats.total == 0
                            ? null
                            : () => study(StudyMode.review),
                        icon: const Icon(Icons.play_arrow),
                        label: Text(t('startReview')),
                      ),
                      OutlinedButton.icon(
                        onPressed: stats.total == 0
                            ? null
                            : () => study(
                                StudyMode.marathon,
                                null,
                              ),
                        icon: const Icon(Icons.local_fire_department),
                        label: Text(t('marathon')),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
        if (difficult.length >= 3)
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
            child: Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      '💡 Recomendación',
                      style: TextStyle(fontWeight: FontWeight.bold),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      'Tienes ${difficult.length} preguntas que has fallado varias veces. Te recomendamos practicar estas antes de continuar.',
                    ),
                    const SizedBox(height: 10),
                    FilledButton(
                      onPressed: () => Navigator.push(
                        c,
                        MaterialPageRoute(
                          builder: (_) => ReviewErrorsScreen(
                            store: store,
                            questions: difficult,
                          ),
                        ),
                      ),
                      child: Text(t('practiceNow')),
                    ),
                  ],
                ),
              ),
            ),
          ),
        const TitleBar('Mis cuestionarios'),
        if (store.decks.isEmpty)
          const Padding(
            padding: EdgeInsets.all(40),
            child: Text(
              '📚\nTodavía no tienes cuestionarios.\nCrea el primero para comenzar.',
              textAlign: TextAlign.center,
            ),
          )
        else
          ...store.decks
              .take(4)
              .map((d) => DeckTile(store: store, deck: d, study: study)),
      ],
    );
  }
}

class DeckList extends StatelessWidget {
  const DeckList({super.key, required this.store, required this.study});
  final AppStore store;
  final StudyFn study;
  @override
  Widget build(BuildContext c) => ListView(
    children: [
      TitleBar(
        'Cuestionarios',
        action: IconButton(
          icon: const Icon(Icons.add_circle_outline),
          onPressed: () async {
            final d = await Navigator.push<Deck>(
              c,
              MaterialPageRoute(builder: (_) => const DeckForm()),
            );
            if (d != null) {
              store.decks.add(d);
              checkAchievements(store);
              await store.save();
            }
          },
        ),
      ),
      if (store.decks.isEmpty)
        const Padding(
          padding: EdgeInsets.all(45),
          child: Text(
            'Crea un cuestionario para organizar tus tarjetas.',
            textAlign: TextAlign.center,
          ),
        )
      else
        ...store.decks.map(
          (d) => DeckTile(store: store, deck: d, study: study),
        ),
    ],
  );
}

class DeckTile extends StatelessWidget {
  const DeckTile({
    super.key,
    required this.store,
    required this.deck,
    required this.study,
  });
  final AppStore store;
  final Deck deck;
  final StudyFn study;
  @override
  Widget build(BuildContext c) {
    final q = store.deckQuestions(deck.id);
    final progress = q.isEmpty
        ? 0.0
        : q.where((e) => e.mastered).length / q.length;
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 7),
      child: ListTile(
        leading: CircleAvatar(
          backgroundColor: Color(deck.color),
          child: Text(deck.icon),
        ),
        title: Text(
          deck.title,
          style: const TextStyle(fontWeight: FontWeight.bold),
        ),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('${q.length} preguntas · ${deck.category}'),
            const SizedBox(height: 6),
            LinearProgressIndicator(value: progress),
          ],
        ),
        trailing: const Icon(Icons.chevron_right),
        onTap: () => Navigator.push(
          c,
          MaterialPageRoute(
            builder: (_) => DeckDetail(store: store, deck: deck, study: study),
          ),
        ),
      ),
    );
  }
}

class StudyChoices extends StatefulWidget {
  const StudyChoices({super.key, required this.store, required this.study});
  final AppStore store;
  final StudyFn study;
  @override
  State<StudyChoices> createState() => _StudyChoicesState();
}

class _StudyChoicesState extends State<StudyChoices> {
  int randomCount = 20;
  RandomOrder randomOrder = RandomOrder.random;
  Set<QuestionType> randomTypes = {...QuestionType.values};
  bool onlyFavorites = false;
  int examCount = 20;
  int examMinutes = 15;
  bool examTimed = true;

  void _launch(
    StudyMode mode, {
    int? limit,
    Set<QuestionType>? types,
    RandomOrder order = RandomOrder.random,
    bool favs = false,
    int? timeLimitSeconds,
  }) {
    final q = StudySessionEngine().buildQueue(
      all: widget.store.questions,
      mode: mode,
      limit: limit,
      types: types,
      order: order,
      onlyFavorites: favs,
    );
    if (q.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Agrega preguntas para comenzar.')),
      );
      return;
    }
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => StudyScreen(
          store: widget.store,
          mode: mode,
          questions: q,
          timeLimitSeconds: timeLimitSeconds,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext c) {
    final stats = queueStats(widget.store.questions);
    return ListView(
      children: [
        const TitleBar('¿Cómo quieres estudiar?'),
        Choice(
          Icons.bolt,
          'Repaso rápido',
          '${stats.due} pendientes · prioriza vencidas y difíciles',
          () => widget.study(StudyMode.review),
        ),
        Card(
          margin: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                ListTile(contentPadding: EdgeInsets.zero,
                  leading: CircleAvatar(child: Icon(Icons.shuffle)),
                  title: Text(
                    'Preguntas aleatorias',
                    style: TextStyle(fontWeight: FontWeight.bold),
                  ),
                  subtitle: Text(t('mixKnowledge')),
                ),
                Text(t('amount')),
                Wrap(
                  spacing: 8,
                  children: [10, 20, 30, -1]
                      .map(
                        (n) => ChoiceChip(
                          label: Text(n == -1 ? 'Todas' : '$n'),
                          selected: randomCount == n,
                          onSelected: (_) =>
                              setState(() => randomCount = n),
                        ),
                      )
                      .toList(),
                ),
                const SizedBox(height: 8),
                Text(t('order')),
                Wrap(
                  spacing: 8,
                  children: RandomOrder.values
                      .map(
                        (o) => ChoiceChip(
                          label: Text(
                            {
                              RandomOrder.random: t('randomAction'),
                              RandomOrder.difficult: 'Difíciles',
                              RandomOrder.leastStudied: 'Menos estudiadas',
                              RandomOrder.due: 'Pendientes',
                            }[o]!,
                          ),
                          selected: randomOrder == o,
                          onSelected: (_) =>
                              setState(() => randomOrder = o),
                        ),
                      )
                      .toList(),
                ),
                const SizedBox(height: 8),
                Text(t('types')),
                Wrap(
                  spacing: 6,
                  children: QuestionType.values
                      .map(
                        (t) => FilterChip(
                          label: Text(_typeName(t)),
                          selected: randomTypes.contains(t),
                          onSelected: (sel) => setState(() {
                            if (sel) {
                              randomTypes.add(t);
                            } else {
                              randomTypes.remove(t);
                            }
                          }),
                        ),
                      )
                      .toList(),
                ),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text(t('onlyFavorites')),
                  value: onlyFavorites,
                  onChanged: (v) => setState(() => onlyFavorites = v),
                ),
                FilledButton.icon(
                  onPressed: randomTypes.isEmpty
                      ? null
                      : () => _launch(
                          StudyMode.random,
                          limit: randomCount == -1 ? null : randomCount,
                          types: {...randomTypes},
                          order: randomOrder,
                          favs: onlyFavorites,
                        ),
                  icon: const Icon(Icons.play_arrow),
                  label: Text(t('startRandom')),
                ),
              ],
            ),
          ),
        ),
        Card(
          margin: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                ListTile(contentPadding: EdgeInsets.zero,
                  leading: CircleAvatar(child: Icon(Icons.timer_outlined)),
                  title: Text(
                    t('examAction'),
                    style: TextStyle(fontWeight: FontWeight.bold),
                  ),
                  subtitle: Text(t('noRepeat')),
                ),
                Text(t('questionsCount')),
                Wrap(
                  spacing: 8,
                  children: [10, 20, 30]
                      .map(
                        (n) => ChoiceChip(
                          label: Text('$n'),
                          selected: examCount == n,
                          onSelected: (_) => setState(() => examCount = n),
                        ),
                      )
                      .toList(),
                ),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text(t('withTime')),
                  value: examTimed,
                  onChanged: (v) => setState(() => examTimed = v),
                ),
                if (examTimed)
                  Wrap(
                    spacing: 8,
                    children: [5, 10, 15, 30]
                        .map(
                          (m) => ChoiceChip(
                            label: Text('$m min'),
                            selected: examMinutes == m,
                            onSelected: (_) =>
                                setState(() => examMinutes = m),
                          ),
                        )
                        .toList(),
                  ),
                const SizedBox(height: 10),
                FilledButton.icon(
                  onPressed: () => _launch(
                    StudyMode.exam,
                    limit: examCount,
                    timeLimitSeconds: examTimed ? examMinutes * 60 : null,
                  ),
                  icon: const Icon(Icons.play_arrow),
                  label: Text(t('startExam')),
                ),
              ],
            ),
          ),
        ),
        Choice(
          Icons.local_fire_department,
          'Maratón 🔥',
          widget.store.profile.marathonBest > 0
              ? 'Mejor racha: ${widget.store.profile.marathonBest}'
              : 'Racha continua hasta fallar',
          () => widget.study(StudyMode.marathon, null),
        ),
        Choice(
          Icons.star_outline,
          'Mis favoritas ★',
          'Solo preguntas marcadas',
          () => _launch(StudyMode.random, favs: true),
        ),
      ],
    );
  }
}

class Choice extends StatelessWidget {
  const Choice(this.icon, this.title, this.subtitle, this.tap, {super.key});
  final IconData icon;
  final String title, subtitle;
  final VoidCallback tap;
  @override
  Widget build(BuildContext c) => Card(
    margin: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
    child: ListTile(
      contentPadding: const EdgeInsets.all(16),
      leading: CircleAvatar(child: Icon(icon)),
      title: Text(title, style: const TextStyle(fontWeight: FontWeight.bold)),
      subtitle: Text(subtitle),
      trailing: const Icon(Icons.arrow_forward),
      onTap: tap,
    ),
  );
}

class DeckDetail extends StatelessWidget {
  const DeckDetail({
    super.key,
    required this.store,
    required this.deck,
    required this.study,
  });
  final AppStore store;
  final Deck deck;
  final StudyFn study;
  @override
  Widget build(BuildContext c) {
    final qs = store.deckQuestions(deck.id);
    return Scaffold(
      appBar: AppBar(
        title: Text(deck.title),
        actions: [
          IconButton(
            icon: const Icon(Icons.edit_outlined),
            tooltip: 'Editar',
            onPressed: () => _editDeck(c),
          ),
          IconButton(
            icon: const Icon(Icons.delete_outline),
            onPressed: () => _deleteDeck(c),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _add(c),
        icon: const Icon(Icons.add),
        label: Text(t('questionLabel')),
      ),
      body: ListView(
        children: [
          Padding(
            padding: const EdgeInsets.all(20),
            child: Text(
              '${qs.length} preguntas · ${qs.where((x) => x.mastered).length} dominadas',
              style: Theme.of(c).textTheme.titleMedium,
            ),
          ),
          Wrap(
            alignment: WrapAlignment.center,
            spacing: 8,
            runSpacing: 8,
            children: [
              FilledButton(
                onPressed: qs.isEmpty ? null : () => study(StudyMode.review, deck),
                child: Text(t('studyAction')),
              ),
              OutlinedButton(
                onPressed: qs.isEmpty ? null : () => study(StudyMode.exam, deck),
                child: Text(t('examAction')),
              ),
              OutlinedButton(
                onPressed: qs.isEmpty
                    ? null
                    : () => study(StudyMode.random, deck),
                child: Text(t('randomAction')),
              ),
              OutlinedButton(
                onPressed: qs.isEmpty
                    ? null
                    : () => study(StudyMode.marathon, deck),
                child: Text(t('marathon')),
              ),
              TextButton.icon(
                onPressed: () => _bulkAdd(c),
                icon: const Icon(Icons.playlist_add),
                label: Text(t('addBulk')),
              ),
            ],
          ),
          const SizedBox(height: 16),
          if (qs.isEmpty)
            const Padding(
              padding: EdgeInsets.all(30),
              child: Text(
                '🧠 Este cuestionario todavía está vacío.\nAgrega algunas preguntas para comenzar.',
                textAlign: TextAlign.center,
              ),
            )
          else
            ...qs.map(
              (q) => ListTile(
                leading: IconButton(
                  icon: Icon(
                    q.isFavorite ? Icons.star : Icons.star_border,
                    color: q.isFavorite ? Colors.amber : null,
                  ),
                  tooltip: 'Favorita',
                  onPressed: () async {
                    q.isFavorite = !q.isFavorite;
                    q.updatedAt = DateTime.now();
                    await store.save();
                  },
                ),
                title: Text(q.prompt),
                subtitle: Text(
                  '${_typeName(q.type)}${q.difficult ? ' · necesita práctica' : ''}',
                ),
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    IconButton(
                      icon: const Icon(Icons.edit_outlined),
                      onPressed: () => _edit(c, q),
                    ),
                    IconButton(
                      icon: const Icon(Icons.delete_outline),
                      onPressed: () => _deleteQuestion(c, q),
                    ),
                  ],
                ),
                onTap: () => _edit(c, q),
              ),
            ),
        ],
      ),
    );
  }

  Future<void> _add(BuildContext c) async {
    final q = await Navigator.push<Question>(
      c,
      MaterialPageRoute(builder: (_) => QuestionForm(deckId: deck.id)),
    );
    if (q != null) {
      store.questions.add(q);
      deck.updatedAt = DateTime.now();
      await store.save();
    }
  }

  Future<void> _bulkAdd(BuildContext c) async {
    final controller = TextEditingController();
    final created = await showDialog<int>(
      context: c,
      builder: (_) => AlertDialog(
        title: Text(t('addBulk')),
        content: SizedBox(
          width: 400,
          child: TextField(
            controller: controller,
            maxLines: 8,
            decoration: InputDecoration(
              hintText: '¿Qué es ADN? | Material genético\n'
                  '¿Qué es ARN? | Ácido ribonucleico',
              border: OutlineInputBorder(),
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c),
            child: Text(t('cancel')),
          ),
          FilledButton(
            onPressed: () {
              final list = store.bulkAdd(deck.id, controller.text);
              deck.updatedAt = DateTime.now();
              store.save();
              Navigator.pop(c, list.length);
            },
            child: Text(t('add')),
          ),
        ],
      ),
    );
    if (c.mounted && created != null && created > 0) {
      ScaffoldMessenger.of(
        c,
      ).showSnackBar(SnackBar(content: Text('$created preguntas agregadas')));
    }
  }

  Future<void> _edit(BuildContext c, Question q) async {
    final updated = await Navigator.push<Question>(
      c,
      MaterialPageRoute(
        builder: (_) => QuestionForm(deckId: deck.id, existing: q),
      ),
    );
    if (updated != null) {
      deck.updatedAt = DateTime.now();
      await store.save();
    }
  }

  void _deleteQuestion(BuildContext c, Question q) => showDialog(
    context: c,
    builder: (_) => AlertDialog(
      title: Text(t('deleteQuestionTitle')),
      content: Text(t('deleteAllContent')),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(c),
          child: Text(t('cancel')),
        ),
        FilledButton(
          onPressed: () async {
            for (final r in q.imageUrls.where(isLocalImageRef)) {
              await deleteImageRef(r);
            }
            store.questions.remove(q);
            deck.updatedAt = DateTime.now();
            await store.save();
            if (c.mounted) Navigator.pop(c);
          },
          child: Text(t('delete')),
        ),
      ],
    ),
  );

  Future<void> _editDeck(BuildContext c) async {
    final updated = await Navigator.push<Deck>(
      c,
      MaterialPageRoute(builder: (_) => DeckForm(existing: deck)),
    );
    if (updated != null) {
      await store.save();
    }
  }

  void _deleteDeck(BuildContext c) => showDialog(
    context: c,
    builder: (_) => AlertDialog(
      title: Text(t('deleteDeckTitle')),
      content: Text(t('deleteDeckContent')),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(c),
          child: Text(t('cancel')),
        ),
        FilledButton(
          onPressed: () async {
            final refs = store.questions
                .where((x) => x.deckId == deck.id)
                .expand((x) => x.imageUrls)
                .where(isLocalImageRef)
                .toList();
            store.decks.remove(deck);
            store.questions.removeWhere((q) => q.deckId == deck.id);
            for (final r in refs) {
              await deleteImageRef(r);
            }
            await store.save();
            if (c.mounted) {
              Navigator.pop(c);
              Navigator.pop(c);
            }
          },
          child: Text(t('delete')),
        ),
      ],
    ),
  );
}

String _typeName(QuestionType t) => const {
  QuestionType.flashcard: 'Flashcard',
  QuestionType.multipleChoice: 'Selección múltiple',
  QuestionType.trueFalse: 'Verdadero/Falso',
  QuestionType.written: 'Respuesta escrita',
  QuestionType.fillBlank: 'Completar espacio',
  QuestionType.ordering: 'Ordenar',
  QuestionType.matching: 'Relacionar',
  QuestionType.imageChoice: 'Imágenes',
}[t]!;

class DeckForm extends StatefulWidget {
  const DeckForm({super.key, this.existing});
  final Deck? existing;
  @override
  State<DeckForm> createState() => _DeckFormState();
}

const deckCategories = [
  'General',
  'Matemáticas',
  'Ciencias',
  'Historia',
  'Inglés',
  'Programación',
  'Medicina',
  'Derecho',
  'Administración',
];

const deckIcons = ['📚', '🧬', '📖', '➗', '🌍', '💻', '🧠', '⚖️', '💡', '🔬'];

/// Iconos de cuestionario agrupados por área/materia.
/// `deckIcons` se mantiene por compatibilidad (iconos originales).
const deckIconGroups = <String, List<String>>{
  'Letras e Idiomas': ['📚', '📖', '🔤', '💬', '🗣️', '✍️', '📝'],
  'Ciencias': ['🔬', '🧬', '🧪', '⚗️', '🔭', '🧲'],
  'Matemáticas': ['➗', '📐', '📊', '📈', '🧮'],
  'Tecnología': ['💻', '🖥️', '⌨️', '🌐', '🤖', '⚙️'],
  'Salud': ['🩺', '💊', '🧠', '🦷', '🩻', '🚑'],
  'Leyes y Negocios': ['⚖️', '💼', '💰', '📑', '🏦'],
  'Historia y Geo': ['🏛️', '🌍', '🗺️', '🏺', '🕰️'],
  'Artes': ['🎨', '🎭', '🎵', '🎸', '📷', '✏️'],
  'Otros': ['🌱', '⚽', '🍳', '✈️', '💡', '🎯', '🏆'],
};

const deckColors = [
  0xff6c4df6,
  0xff3b82f6,
  0xff22c55e,
  0xffef4444,
  0xfff59e0b,
  0xffec4899,
  0xff14b8a6,
  0xfff97316,
];

class _DeckFormState extends State<DeckForm> {
  final form = GlobalKey<FormState>();
  late final title = TextEditingController(text: widget.existing?.title ?? '');
  late final description = TextEditingController(
    text: widget.existing?.description ?? '',
  );
  late String category = widget.existing?.category ?? 'General';
  late String icon = widget.existing?.icon ?? '📚';
  late int color = widget.existing?.color ?? 0xff6c4df6;
  @override
  Widget build(BuildContext c) {
    final isEdit = widget.existing != null;
    return Scaffold(
      appBar: AppBar(
        title: Text(isEdit ? 'Editar cuestionario' : 'Nuevo cuestionario'),
      ),
      body: Padding(
        padding: const EdgeInsets.all(20),
        child: Form(
          key: form,
          child: ListView(
            children: [
              TextFormField(
                controller: title,
                autofocus: !isEdit,
                decoration: InputDecoration(labelText: 'Nombre'),
                validator: (x) =>
                    x == null || x.trim().isEmpty ? 'Escribe un nombre' : null,
              ),
              const SizedBox(height: 14),
              TextFormField(
                controller: description,
                decoration: InputDecoration(labelText: 'Descripción'),
                maxLines: 2,
              ),
              const SizedBox(height: 14),
              DropdownButtonFormField<String>(
                initialValue: deckCategories.contains(category)
                    ? category
                    : 'General',
                decoration: InputDecoration(labelText: 'Categoría'),
                items: deckCategories
                    .map((x) => DropdownMenuItem(value: x, child: Text(x)))
                    .toList(),
                onChanged: (x) => setState(() => category = x ?? 'General'),
              ),
              const SizedBox(height: 16),
              Text(t('iconLabel')),
              const SizedBox(height: 8),
              for (final entry in deckIconGroups.entries) ...[
                Padding(
                  padding: const EdgeInsets.only(top: 4, bottom: 6),
                  child: Text(
                    entry.key,
                    style: const TextStyle(
                        fontSize: 12, fontWeight: FontWeight.w600),
                  ),
                ),
                Wrap(
                  spacing: 8,
                  runSpacing: 4,
                  children: entry.value
                      .map(
                        (e) => ChoiceChip(
                          label: Text(e),
                          selected: icon == e,
                          onSelected: (_) => setState(() => icon = e),
                        ),
                      )
                      .toList(),
                ),
              ],
              const SizedBox(height: 16),
              Text(t('colorLabel')),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                children: deckColors
                    .map(
                      (col) => GestureDetector(
                        onTap: () => setState(() => color = col),
                        child: Container(
                          width: 40,
                          height: 40,
                          decoration: BoxDecoration(
                            color: Color(col),
                            shape: BoxShape.circle,
                            border: color == col
                                ? Border.all(width: 3, color: Colors.white)
                                : null,
                          ),
                        ),
                      ),
                    )
                    .toList(),
              ),
              const SizedBox(height: 24),
              FilledButton(
                onPressed: () {
                  if (form.currentState!.validate()) {
                    if (isEdit) {
                      widget.existing!
                        ..title = title.text.trim()
                        ..description = description.text.trim()
                        ..category = category
                        ..icon = icon
                        ..color = color
                        ..updatedAt = DateTime.now();
                      Navigator.pop(c, widget.existing);
                    } else {
                      Navigator.pop(
                        c,
                        Deck(
                          id: DateTime.now().microsecondsSinceEpoch.toString(),
                          title: title.text.trim(),
                          description: description.text.trim(),
                          category: category,
                          icon: icon,
                          color: color,
                        ),
                      );
                    }
                  }
                },
                child: Text(isEdit ? 'Guardar cambios' : 'Guardar'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class QuestionForm extends StatefulWidget {
  const QuestionForm({super.key, required this.deckId, this.existing});
  final String deckId;
  final Question? existing;
  @override
  State<QuestionForm> createState() => _QuestionFormState();
}

class _QuestionFormState extends State<QuestionForm> {
  final form = GlobalKey<FormState>();
  late QuestionType type = widget.existing?.type ?? QuestionType.flashcard;
  late final prompt = TextEditingController(
    text: widget.existing?.prompt ?? '',
  );
  late final answer = TextEditingController(
    text: widget.existing?.answer ?? '',
  );
  late final options = TextEditingController(
    text: widget.existing?.options.join('\n') ?? '',
  );
  late final accepted = TextEditingController(
    text: widget.existing?.accepted.join(', ') ?? '',
  );
  late final explanation = TextEditingController(
    text: widget.existing?.explanation ?? '',
  );
  late final tags = TextEditingController(
    text: widget.existing?.tags.join(', ') ?? '',
  );
  late final hints = TextEditingController(
    text: widget.existing?.hints.join('\n') ?? '',
  );
  late final pairs = TextEditingController(
    text: widget.existing?.pairs.join('\n') ?? '',
  );
  late final images = TextEditingController(
    text: widget.existing?.imageUrls.join('\n') ?? '',
  );
  late String tfValue = (widget.existing?.type == QuestionType.trueFalse)
      ? widget.existing!.answer
      : 'Verdadero';
  // Fotos del dispositivo (refs `file:`) separadas del campo de texto/URL.
  List<String> deviceImgs = [];
  @override
  void initState() {
    super.initState();
    final all = images.text
        .split('\n')
        .where((x) => x.trim().isNotEmpty)
        .map((x) => x.trim())
        .toList();
    deviceImgs = all.where(isLocalImageRef).toList();
    images.text = all.where((x) => !isLocalImageRef(x)).join('\n');
  }
  List<String> _typedImgs() => images.text
      .split('\n')
      .where((x) => x.trim().isNotEmpty)
      .map((x) => x.trim())
      .toList();
  List<String> _combinedImgs() =>
      [...deviceImgs, ..._typedImgs()].take(kMaxImagesPerQuestion).toList();
  Future<void> _pickDeviceImage(Future<String?> Function() pick) async {
    if (_combinedImgs().length >= kMaxImagesPerQuestion) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
              content: Text('Máximo 4 imágenes por pregunta')),
        );
      }
      return;
    }
    final ref = await pick();
    if (ref == null || !mounted) return;
    setState(() => deviceImgs.add(ref));
  }
  @override
  Widget build(BuildContext c) {
    final isEdit = widget.existing != null;
    return Scaffold(
      appBar: AppBar(
        title: Text(isEdit ? 'Editar pregunta' : 'Nueva pregunta'),
      ),
      body: Form(
        key: form,
        child: ListView(
          padding: const EdgeInsets.all(20),
          children: [
            DropdownButtonFormField<QuestionType>(
              initialValue: type,
              decoration: InputDecoration(labelText: 'Tipo'),
              items: QuestionType.values
                  .map(
                    (x) => DropdownMenuItem(value: x, child: Text(_typeName(x))),
                  )
                  .toList(),
              onChanged: (x) => setState(() => type = x!),
            ),
            const SizedBox(height: 14),
            TextFormField(
              controller: prompt,
              maxLines: 3,
              decoration: InputDecoration(labelText: t('questionLabel')),
              validator: (x) => x == null || x.trim().isEmpty
                  ? 'La pregunta es obligatoria'
                  : null,
            ),
            const SizedBox(height: 14),
            if (type == QuestionType.multipleChoice || type == QuestionType.ordering) ...[
              TextFormField(
                controller: options,
                maxLines: 5,
                decoration: InputDecoration(
                  labelText: type == QuestionType.ordering
                      ? 'Elementos a ordenar (uno por línea, en orden correcto)'
                      : 'Opciones (una por línea, 2 a 6)',
                  helperText: type == QuestionType.ordering
                      ? 'Se mostrarán desordenados al estudiar'
                      : 'La respuesta correcta debe coincidir con una',
                ),
                validator: (x) {
                  if (type != QuestionType.multipleChoice && type != QuestionType.ordering) return null;
                  final list = (x ?? '')
                      .split('\n')
                      .where((e) => e.trim().isNotEmpty)
                      .toList();
                  if (list.length < 2) return 'Agrega al menos 2 opciones';
                  if (type == QuestionType.multipleChoice && list.length > 6) return 'Máximo 6 opciones';
                  return null;
                },
              ),
              const SizedBox(height: 14),
            ],
            if (type == QuestionType.matching) ...[
              TextFormField(
                controller: pairs,
                maxLines: 5,
                decoration: InputDecoration(
                  labelText: 'Pares (uno por línea, formato: izquierda|derecha)',
                  helperText: 'Ej: Agua|CO2',
                ),
                validator: (x) {
                  if (type != QuestionType.matching) return null;
                  final list = (x ?? '').split('\n').where((e) => e.trim().isNotEmpty).toList();
                  if (list.length < 2) return 'Agrega al menos 2 pares';
                  if (list.any((e) => !e.contains('|'))) return 'Cada línea debe contener |';
                  return null;
                },
              ),
              const SizedBox(height: 14),
            ],
            if (type == QuestionType.imageChoice) ...[
              // Fotos del dispositivo: vista previa, tap = marcar correcta.
              if (_combinedImgs().isNotEmpty)
                GridView.builder(
                  shrinkWrap: true,
                  physics: const NeverScrollableScrollPhysics(),
                  gridDelegate:
                      const SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: 2,
                    crossAxisSpacing: 8,
                    mainAxisSpacing: 8,
                    childAspectRatio: 1.1,
                  ),
                  itemCount: _combinedImgs().length,
                  itemBuilder: (ctx, idx) {
                    final ref = _combinedImgs()[idx];
                    final isMarked =
                        answer.text.trim().isNotEmpty &&
                            answer.text.trim() == ref;
                    return GestureDetector(
                      onTap: () => setState(() => answer.text = ref),
                      child: Stack(
                        fit: StackFit.expand,
                        children: [
                          Container(
                            decoration: BoxDecoration(
                              border: Border.all(
                                color: isMarked
                                    ? QCTokens.primary
                                    : Theme.of(c)
                                        .colorScheme
                                        .outlineVariant,
                                width: isMarked ? 3 : 1,
                              ),
                              borderRadius: BorderRadius.circular(12),
                            ),
                            clipBehavior: Clip.antiAlias,
                            child: imageRefThumb(ref),
                          ),
                          if (isMarked)
                            const Positioned(
                              top: 6,
                              left: 6,
                              child: CircleAvatar(
                                radius: 14,
                                backgroundColor: QCTokens.primary,
                                child: Icon(Icons.check,
                                    size: 18, color: Colors.white),
                              ),
                            ),
                          Positioned(
                            top: 2,
                            right: 2,
                            child: IconButton(
                              icon: const Icon(Icons.close, size: 20),
                              style: IconButton.styleFrom(
                                backgroundColor: Colors.black54,
                                foregroundColor: Colors.white,
                                minimumSize: const Size(32, 32),
                                tapTargetSize:
                                    MaterialTapTargetSize.shrinkWrap,
                              ),
                              onPressed: () async {
                                setState(() {
                                  deviceImgs.remove(ref);
                                  final typed = _typedImgs()
                                    ..remove(ref);
                                  images.text = typed.join('\n');
                                  if (answer.text.trim() == ref) {
                                    answer.text = '';
                                  }
                                });
                                await deleteImageRef(ref);
                              },
                            ),
                          ),
                        ],
                      ),
                    );
                  },
                ),
              if (_combinedImgs().isNotEmpty)
                const Padding(
                  padding: EdgeInsets.only(top: 6, bottom: 6),
                  child: Text(
                    'Toca una foto para marcarla como respuesta correcta.',
                    style: TextStyle(fontSize: 12, color: Colors.grey),
                  ),
                ),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: () =>
                          _pickDeviceImage(pickGalleryImage),
                      icon: const Icon(Icons.photo_library),
                      label: const Text('Galería'),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: () =>
                          _pickDeviceImage(pickCameraImage),
                      icon: const Icon(Icons.photo_camera),
                      label: const Text('Cámara'),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 14),
              TextFormField(
                controller: images,
                maxLines: 3,
                decoration: InputDecoration(
                  labelText: 'URLs o texto (una por línea, opcional)',
                  helperText:
                      'Máximo 4 en total con las fotos. Se muestran en grid 2x2',
                ),
                onChanged: (_) => setState(() {}),
              ),
              const SizedBox(height: 14),
            ],
            if (type == QuestionType.trueFalse)
              DropdownButtonFormField<String>(
                initialValue: ['Verdadero', 'Falso'].contains(tfValue)
                    ? tfValue
                    : 'Verdadero',
                decoration: InputDecoration(
                  labelText: 'Respuesta correcta',
                ),
                items: const ['Verdadero', 'Falso']
                    .map((x) => DropdownMenuItem(value: x, child: Text(x)))
                    .toList(),
                onChanged: (x) => setState(() => tfValue = x!),
              )
            else
              TextFormField(
                controller: answer,
                maxLines: 3,
                decoration: InputDecoration(
                  labelText: 'Respuesta correcta',
                ),
                validator: (x) {
                  if (type == QuestionType.trueFalse) return null;
                  if (x == null || x.trim().isEmpty) {
                    return 'La respuesta es obligatoria';
                  }
                  if (type == QuestionType.multipleChoice) {
                    final list = options.text
                        .split('\n')
                        .map((e) => e.trim())
                        .where((e) => e.isNotEmpty)
                        .toList();
                    if (list.isNotEmpty &&
                        !list.any(
                          (o) =>
                              normalizeAnswer(o) ==
                              normalizeAnswer(x.trim()),
                        )) {
                      return 'Debe coincidir con una de las opciones';
                    }
                  }
                  return null;
                },
              ),
            const SizedBox(height: 14),
            TextFormField(
              controller: explanation,
              maxLines: 2,
              decoration: InputDecoration(
                labelText: 'Explicación (opcional)',
              ),
            ),
            if (type == QuestionType.written ||
                type == QuestionType.fillBlank) ...[
              const SizedBox(height: 14),
              TextFormField(
                controller: accepted,
                decoration: InputDecoration(
                  labelText: 'Alternativas aceptadas (separadas por coma)',
                ),
              ),
            ],
            const SizedBox(height: 14),
            TextFormField(
              controller: tags,
              decoration: InputDecoration(
                labelText: 'Etiquetas (separadas por coma, ej: #examen)',
              ),
            ),
            const SizedBox(height: 14),
            TextFormField(
              controller: hints,
              maxLines: 3,
              decoration: InputDecoration(
                labelText: 'Pistas (una por línea, opcional)',
                helperText: 'Se revelan progresivamente con 💡',
              ),
            ),
            const SizedBox(height: 28),
            FilledButton(
              onPressed: () async {
                if (!form.currentState!.validate()) return;
                if (type == QuestionType.imageChoice &&
                    _combinedImgs().isEmpty) {
                  ScaffoldMessenger.of(c).showSnackBar(
                    const SnackBar(
                        content:
                            Text('Agrega al menos 1 imagen')),
                  );
                  return;
                }
                var finalAnswer = type == QuestionType.trueFalse
                    ? tfValue
                    : answer.text.trim();
                // Para ordenar, la respuesta es el orden correcto (options en orden)
                if (type == QuestionType.ordering) {
                  final orderOpts = options.text.split('\n').where((x) => x.trim().isNotEmpty).map((x) => x.trim()).toList();
                  finalAnswer = orderOpts.join(',');
                }
                final opts = options.text
                    .split('\n')
                    .where((x) => x.trim().isNotEmpty)
                    .map((x) => x.trim())
                    .toList();
                final acc = accepted.text
                    .split(',')
                    .where((x) => x.trim().isNotEmpty)
                    .map((x) => x.trim())
                    .toList();
                final tagList = tags.text
                    .split(',')
                    .where((x) => x.trim().isNotEmpty)
                    .map((x) => x.trim())
                    .toList();
                final hintList = hints.text
                    .split('\n')
                    .where((x) => x.trim().isNotEmpty)
                    .map((x) => x.trim())
                    .toList();
                final pairList = pairs.text.split('\n').where((x) => x.trim().isNotEmpty).map((x) => x.trim()).toList();
                final imgList = _combinedImgs();
                // Borra fotos locales que se quitaron al editar.
                final removedLocals = widget.existing?.imageUrls
                        .where(isLocalImageRef)
                        .where((r) => !imgList.contains(r))
                        .toList() ??
                    [];
                for (final r in removedLocals) {
                  await deleteImageRef(r);
                }
                if (!c.mounted) return;
                if (isEdit) {
                  widget.existing!
                    ..type = type
                    ..prompt = prompt.text.trim()
                    ..answer = finalAnswer
                    ..options = (type == QuestionType.multipleChoice || type == QuestionType.ordering)
                        ? opts
                        : <String>[]
                    ..accepted = acc
                    ..explanation = explanation.text.trim()
                    ..tags = tagList
                    ..hints = hintList
                    ..pairs = pairList
                    ..imageUrls = imgList
                    ..updatedAt = DateTime.now();
                  Navigator.pop(c, widget.existing);
                } else {
                  Navigator.pop(
                    c,
                    Question(
                      id: DateTime.now().microsecondsSinceEpoch.toString(),
                      deckId: widget.deckId,
                      type: type,
                      prompt: prompt.text.trim(),
                      answer: finalAnswer,
                      options: (type == QuestionType.multipleChoice || type == QuestionType.ordering)
                          ? opts
                          : <String>[],
                      accepted: acc,
                      explanation: explanation.text.trim(),
                      tags: tagList,
                      hints: hintList,
                      pairs: pairList,
                      imageUrls: imgList,
                    ),
                  );
                }
              },
              child: Text(isEdit ? 'Guardar cambios' : 'Guardar pregunta'),
            ),
          ],
        ),
      ),
    );
  }
}

/// ── Question Card System — lenguaje visual unificado ──

class QCCard extends StatelessWidget {
  const QCCard({
    super.key,
    required this.child,
    this.type,
    this.onTap,
  });
  final Widget child;
  final QuestionType? type;
  final VoidCallback? onTap;
  @override
  Widget build(BuildContext c) {
    final reduce = MediaQuery.of(c).disableAnimations;
    final isDark = Theme.of(c).brightness == Brightness.dark;
    final accent = type == null ? null : QCTokens.accentFor(c, type!.name);
    return AnimatedScale(
      scale: 1,
      duration: reduce ? Duration.zero : QCTokens.animFast,
      child: Card(
        elevation: isDark ? 0 : 2,
        shadowColor: isDark ? Colors.transparent : Colors.black12,
        surfaceTintColor: Colors.transparent,
        color: Theme.of(c).colorScheme.surface,
        clipBehavior: Clip.antiAlias,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(QCTokens.cardRadius),
          side: BorderSide(
            color: QCTokens.borderForCard(c),
            width: 1,
          ),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (accent != null)
              Container(
                height: 4,
                decoration: BoxDecoration(
                  gradient: LinearGradient(colors: [accent, accent.withValues(alpha: 0.7)]),
                ),
              ),
            Container(
              decoration: BoxDecoration(
                gradient: QCTokens.cardGradientOf(c),
              ),
              padding: const EdgeInsets.all(QCTokens.cardPadding),
              child: child,
            ),
          ],
        ),
      ),
    );
  }
}

class QCFeedback extends StatelessWidget {
  const QCFeedback({
    super.key,
    required this.correct,
    required this.answer,
    this.explanation = '',
    this.xp = 0,
  });
  final bool correct;
  final String answer, explanation;
  final int xp;
  @override
  Widget build(BuildContext c) {
    final isDark = Theme.of(c).brightness == Brightness.dark;
    final okColor = isDark ? const Color(0xff4ADE80) : QCTokens.success;
    final warnColor = isDark ? const Color(0xffFCD34D) : QCTokens.warning;
    return AnimatedOpacity(
    opacity: 1,
    duration: QCTokens.animFast,
    child: Column(
      children: [
        Icon(
          correct ? Icons.check_circle : Icons.lightbulb,
          color: correct ? okColor : warnColor,
          size: 48,
        ),
        const SizedBox(height: 8),
        Text(
          correct ? '✓ ¡Correcto!' : 'Casi...',
          style: Theme.of(c).textTheme.titleLarge?.copyWith(
            fontWeight: FontWeight.bold,
            color: correct ? okColor : warnColor,
          ),
          textAlign: TextAlign.center,
        ),
        if (xp > 0 && correct)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(
              '+$xp XP',
              style: TextStyle(
                color: okColor,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
        if (!correct)
          Padding(
            padding: const EdgeInsets.all(8),
            child: Text(
              'Respuesta correcta:\n"$answer"',
              style: Theme.of(c).textTheme.titleMedium,
              textAlign: TextAlign.center,
            ),
          ),
        if (explanation.trim().isNotEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            child: Text(
              explanation,
              style: Theme.of(c).textTheme.bodyMedium,
              textAlign: TextAlign.center,
            ),
          ),
        if (!correct)
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 16, vertical: 4),
            child: Text(
              'Esta pregunta volverá a aparecer para ayudarte a recordarla.',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 13),
            ),
          ),
      ],
    ),
  );
  }
}

class QCDifficulty extends StatelessWidget {
  const QCDifficulty({super.key, required this.onRate});
  final void Function(Rating) onRate;
  Color _colorFor(Rating r, BuildContext c) {
    final isDark = Theme.of(c).brightness == Brightness.dark;
    return switch (r) {
      Rating.again => isDark ? const Color(0xffF87171) : const Color(0xffEF4444),
      Rating.hard => const Color(0xff3B82F6),
      Rating.good => const Color(0xff60A5FA),
      Rating.easy => isDark ? const Color(0xff4ADE80) : const Color(0xff22C55E),
    };
  }

  @override
  Widget build(BuildContext c) => Wrap(
    alignment: WrapAlignment.center,
    spacing: 6,
    runSpacing: 6,
    children: Rating.values
        .map(
          (r) {
            final col = _colorFor(r, c);
            return OutlinedButton(
            onPressed: () => onRate(r),
            style: OutlinedButton.styleFrom(
              foregroundColor: col,
              side: BorderSide(color: col.withValues(alpha: 0.5)),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
            ),
            child: Text(
              const {
                Rating.again: '😵 Otra vez',
                Rating.hard: '🤔 Difícil',
                Rating.good: '🙂 Bien',
                Rating.easy: '😎 Fácil',
              }[r]!,
            ),
          );
          },
        )
        .toList(),
  );
}

class QCNextButton extends StatelessWidget {
  QCNextButton({super.key, required this.onPressed, this.label = 'Siguiente'});
  final VoidCallback onPressed;
  final String label;
  @override
  Widget build(BuildContext c) => SizedBox(
    width: double.infinity,
    height: 48,
    child: DecoratedBox(
      decoration: BoxDecoration(
        gradient: QCTokens.buttonGradient,
        borderRadius: BorderRadius.circular(14),
      ),
      child: FilledButton(
        onPressed: onPressed,
        style: FilledButton.styleFrom(
          backgroundColor: Colors.transparent,
          shadowColor: Colors.transparent,
          padding: const EdgeInsets.symmetric(vertical: 14),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14),
          ),
        ),
        child: Text(label, style: const TextStyle(fontWeight: FontWeight.bold)),
      ),
    ),
  );
}

class QCHint extends StatelessWidget {
  const QCHint({
    super.key,
    required this.hints,
    required this.revealed,
    required this.onReveal,
  });
  final List<String> hints;
  final int revealed;
  final VoidCallback onReveal;
  @override
  Widget build(BuildContext c) {
    if (hints.isEmpty) return const SizedBox.shrink();
    if (revealed >= hints.length) return const SizedBox.shrink();
    return Column(
      children: [
        ...hints.take(revealed).map(
          (h) => TweenAnimationBuilder<double>(
            tween: Tween(begin: 0, end: 1),
            duration: const Duration(milliseconds: 250),
            curve: Curves.easeOut,
            builder: (ctx, v, child) => Opacity(
              opacity: v,
              child: Transform.translate(
                offset: Offset(0, 8 * (1 - v)),
                child: child,
              ),
            ),
            child: Card(
              color: Theme.of(c).colorScheme.tertiaryContainer,
              margin: const EdgeInsets.only(bottom: 8),
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Row(
                children: [
                  const Text('💡'),
                  const SizedBox(width: 8),
                  Expanded(child: Text(h)),
                ],
              ),
            ),
          ),
          ),
        ),
        OutlinedButton.icon(
          onPressed: onReveal,
          icon: const Icon(Icons.lightbulb_outline, size: 18),
          label: Text(
            revealed == 0 ? 'Mostrar pista' : 'Otra pista (${revealed + 1}/${hints.length})',
          ),
        ),
      ],
    );
  }
}

/// Unidad interactiva múltiple elección — grande y fácil de tocar.
class QCMultiple extends StatelessWidget {
  const QCMultiple({
    super.key,
    required this.options,
    required this.selected,
    required this.correct,
    required this.revealed,
    required this.onSelect,
  });
  final List<String> options, correct;
  final String? selected;
  final bool revealed;
  final void Function(String) onSelect;
  @override
  Widget build(BuildContext c) {
    final isDark = Theme.of(c).brightness == Brightness.dark;
    return Column(
    children: options.asMap().entries.map((e) {
      final idx = e.key;
      final opt = e.value;
      final label = String.fromCharCode(65 + idx);
      final isSel = selected == opt;
      final isCorrect = correct.contains(opt);
      Color? border;
      Color? bg;
      IconData? icon;
      // Intensidad adaptada: en oscuro usa alpha mayor para contraste
      final aSuccess = isDark ? 0.14 : 0.08;
      final aError = isDark ? 0.14 : 0.06;
      final aPrimary = isDark ? 0.14 : 0.06;
      if (revealed) {
        if (isCorrect) {
          border = isDark ? const Color(0xff4ADE80) : QCTokens.success;
          bg = border.withValues(alpha: aSuccess);
          icon = Icons.check_circle;
        } else if (isSel) {
          border = isDark ? const Color(0xffF87171) : QCTokens.error;
          bg = border.withValues(alpha: aError);
          icon = Icons.cancel;
        }
      } else if (isSel) {
        border = QCTokens.accentFor(c, 'multipleChoice');
        bg = border.withValues(alpha: aPrimary);
        icon = Icons.radio_button_checked;
      }
      return Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Material(
          color: Colors.transparent,
          borderRadius: BorderRadius.circular(QCTokens.optionRadius),
          child: InkWell(
            borderRadius: BorderRadius.circular(QCTokens.optionRadius),
            onTap: revealed ? null : () => onSelect(opt),
            child: Container(
              padding: const EdgeInsets.all(QCTokens.optionPadding),
              decoration: BoxDecoration(
                gradient: isSel && !revealed ? QCTokens.buttonGradient : null,
                color: isSel && !revealed ? null : (bg ?? Theme.of(c).colorScheme.surface),
                border: Border.all(
                  color: isSel && !revealed ? Colors.transparent : (border ?? Theme.of(c).colorScheme.outlineVariant),
                  width: isSel || (revealed && isCorrect) ? 2 : 1,
                ),
                borderRadius: BorderRadius.circular(QCTokens.optionRadius),
              ),
              child: Row(
                children: [
                  CircleAvatar(
                    radius: 14,
                    backgroundColor: isSel && !revealed ? Colors.white.withValues(alpha: 0.9) : (border ?? Theme.of(c).colorScheme.surfaceContainerHighest),
                    child: isSel && !revealed
                        ? const Icon(Icons.check, size: 14, color: QCTokens.primary)
                        : Text(
                      label,
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.bold,
                        color: border != null ? Colors.white : Theme.of(c).colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(child: Text(opt, style: TextStyle(color: isSel && !revealed ? Colors.white : Theme.of(c).colorScheme.onSurface, fontWeight: isSel && !revealed ? FontWeight.bold : FontWeight.normal))),
                  if (icon != null) Icon(icon, size: 20, color: isSel && !revealed ? Colors.white : border),
                  if (!revealed && !isSel) Icon(Icons.circle_outlined, size: 20, color: Theme.of(c).colorScheme.onSurfaceVariant),
                ],
              ),
            ),
          ),
        ),
      );
    }).toList(),
  );
  }
}

class QCWritten extends StatelessWidget {
  const QCWritten({super.key, required this.controller, this.enabled = true});
  final TextEditingController controller;
  final bool enabled;
  @override
  Widget build(BuildContext c) => TextField(
    controller: controller,
    enabled: enabled,
    decoration: InputDecoration(
      labelText: 'Escribe tu respuesta',
      hintText: 'Escribe aquí…',
      filled: true,
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
      ),
    ),
  );
}

class QCTrueFalse extends StatelessWidget {
  const QCTrueFalse({
    super.key,
    required this.selected,
    required this.revealed,
    required this.correct,
    required this.onSelect,
  });
  final String? selected;
  final bool revealed;
  final String correct;
  final void Function(String) onSelect;
  @override
  Widget build(BuildContext c) {
    final isDark = Theme.of(c).brightness == Brightness.dark;
    return Row(
    children: ['Verdadero', 'Falso'].map((opt) {
      final isSel = selected == opt;
      final isCorrect = correct == opt;
      Color? col;
      Color? bg;
      Color? fg;
      if (revealed) {
        if (isCorrect) {
          col = isDark ? const Color(0xff4ADE80) : QCTokens.success;
          bg = col;
          fg = Colors.white;
        } else if (isSel) {
          col = isDark ? const Color(0xffF87171) : QCTokens.error;
          bg = col;
          fg = Colors.white;
        }
      } else if (isSel) {
        // Mockup: Verdadero verde, Falso rojo sólido
        col = opt == 'Verdadero' ? (isDark ? const Color(0xff4ADE80) : const Color(0xff22C55E)) : (isDark ? const Color(0xffF87171) : const Color(0xffEF4444));
        bg = col;
        fg = Colors.white;
      }
      final bgAlpha = isDark ? 0.14 : 0.08;
      return Expanded(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 6),
          child: SizedBox(
            height: 72,
            child: OutlinedButton(
              onPressed: revealed ? null : () => onSelect(opt),
              style: OutlinedButton.styleFrom(
                backgroundColor: bg ?? (col?.withValues(alpha: bgAlpha)),
                foregroundColor: fg ?? col ?? Theme.of(c).colorScheme.onSurface,
                side: BorderSide(color: (bg != null ? bg : col) ?? Theme.of(c).colorScheme.outlineVariant, width: isSel || (revealed && isCorrect) ? 2 : 1),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(16),
                ),
              ),
              child: Text(
                opt.toUpperCase(),
                style: const TextStyle(
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
          ),
        ),
      );
    }).toList(),
  );
  }
}

/// Ordenar: lista reordenable con números y handle
class QCOrdering extends StatefulWidget {
  const QCOrdering({super.key, required this.items, required this.onChanged, this.enabled = true});
  final List<String> items;
  final ValueChanged<List<String>> onChanged;
  final bool enabled;
  @override
  State<QCOrdering> createState() => _QCOrderingState();
}

class _QCOrderingState extends State<QCOrdering> {
  late List<String> _list;
  @override
  void initState() {
    super.initState();
    _list = List.of(widget.items);
  }

  @override
  void didUpdateWidget(covariant QCOrdering old) {
    super.didUpdateWidget(old);
    if (old.items != widget.items) _list = List.of(widget.items);
  }

  @override
  Widget build(BuildContext c) {
    final isDark = Theme.of(c).brightness == Brightness.dark;
    return ReorderableListView.builder(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      itemCount: _list.length,
      onReorder: widget.enabled
          ? (o, n) {
              setState(() {
                if (n > o) n--;
                final it = _list.removeAt(o);
                _list.insert(n, it);
              });
              widget.onChanged(List.of(_list));
            }
          : (_, __) {},
      itemBuilder: (ctx, idx) {
        final txt = _list[idx];
        final numColor = [const Color(0xff22C55E), const Color(0xff3B82F6), const Color(0xff06B6D4), const Color(0xff8B5CF6)][idx % 4];
        return Container(
          key: ValueKey(txt),
          margin: const EdgeInsets.only(bottom: 8),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
          decoration: BoxDecoration(
            color: isDark ? const Color(0xff1E293B) : Colors.white,
            border: Border.all(color: Theme.of(c).colorScheme.outlineVariant),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Row(
            children: [
              CircleAvatar(radius: 14, backgroundColor: numColor, child: Text('${idx + 1}', style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.bold))),
              const SizedBox(width: 12),
              Expanded(child: Text(txt)),
              const Icon(Icons.drag_handle, size: 18, color: Colors.grey),
            ],
          ),
        );
      },
    );
  }
}

/// Relacionar: dos columnas con conexiones de colores
class QCMatching extends StatefulWidget {
  const QCMatching({super.key, required this.pairs, this.enabled = true, this.onMatch});
  final List<String> pairs; // "izq|der"
  final bool enabled;
  final ValueChanged<Map<String, String>>? onMatch;
  @override
  State<QCMatching> createState() => _QCMatchingState();
}

class _QCMatchingState extends State<QCMatching> {
  String? selLeft;
  final Map<String, String> matches = {};
  final colors = const [Color(0xff22C55E), Color(0xff3B82F6), Color(0xffF59E0B), Color(0xffEF4444), Color(0xff8B5CF6)];

  @override
  Widget build(BuildContext c) {
    final lefts = widget.pairs.map((e) => e.split('|')[0]).toList();
    final rights = widget.pairs.map((e) => e.split('|').length > 1 ? e.split('|')[1] : '').toList()..shuffle();
    return Column(
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Column(
                children: lefts.map((l) {
                  final isSel = selLeft == l;
                  final isMatched = matches.containsKey(l);
                  final idx = lefts.indexOf(l);
                  final col = colors[idx % colors.length];
                  return Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: InkWell(
                      onTap: !widget.enabled || isMatched ? null : () => setState(() => selLeft = l),
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 14),
                        decoration: BoxDecoration(
                          color: isSel ? col.withValues(alpha: 0.12) : Theme.of(c).colorScheme.surface,
                          border: Border.all(color: isSel ? col : Theme.of(c).colorScheme.outlineVariant, width: isSel ? 2 : 1),
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Row(
                          children: [
                            CircleAvatar(radius: 6, backgroundColor: isMatched ? col : (isSel ? col : Colors.grey)),
                            const SizedBox(width: 8),
                            Expanded(child: Text(l, style: const TextStyle(fontSize: 13))),
                            AnimatedOpacity(
                              opacity: isSel ? 1 : 0,
                              duration: const Duration(milliseconds: 180),
                              child: AnimatedSlide(
                                offset: isSel ? Offset.zero : const Offset(-0.2, 0),
                                duration: const Duration(milliseconds: 180),
                                curve: Curves.easeOut,
                                child: Icon(Icons.arrow_forward, size: 16, color: col),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  );
                }).toList(),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                children: rights.map((r) {
                  final isMatched = matches.containsValue(r);
                  return Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: InkWell(
                      onTap: !widget.enabled || selLeft == null || isMatched ? null : () {
                        final left = selLeft!;
                        setState(() {
                          matches[left] = r;
                          selLeft = null;
                        });
                        widget.onMatch?.call(Map.of(matches));
                      },
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 14),
                        decoration: BoxDecoration(
                          color: Theme.of(c).colorScheme.surface,
                          border: Border.all(color: Theme.of(c).colorScheme.outlineVariant),
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Row(
                          children: [
                            Expanded(child: Text(r, style: const TextStyle(fontSize: 13))),
                            CircleAvatar(radius: 6, backgroundColor: isMatched ? Colors.grey : Theme.of(c).colorScheme.outline),
                          ],
                        ),
                      ),
                    ),
                  );
                }).toList(),
              ),
            ),
          ],
        ),
        if (matches.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Wrap(
              spacing: 6,
              children: matches.entries.map((e) {
                final idx = lefts.indexOf(e.key);
                final col = colors[idx % colors.length];
                return Chip(label: Text('${e.key} → ${e.value}', style: const TextStyle(fontSize: 12)), backgroundColor: col.withValues(alpha: 0.12), side: BorderSide(color: col));
              }).toList(),
            ),
          ),
      ],
    );
  }
}

/// Imágenes: grid 2x2 con selección y zoom
class QCImageChoice extends StatelessWidget {
  const QCImageChoice({super.key, required this.urls, required this.selected, required this.onSelect, this.enabled = true});
  final List<String> urls;
  final String? selected;
  final ValueChanged<String> onSelect;
  final bool enabled;
  @override
  Widget build(BuildContext c) => GridView.builder(
    shrinkWrap: true,
    physics: const NeverScrollableScrollPhysics(),
    gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(crossAxisCount: 2, crossAxisSpacing: 8, mainAxisSpacing: 8, childAspectRatio: 1.1),
    itemCount: urls.length.clamp(0, 4),
    itemBuilder: (ctx, idx) {
      final url = urls[idx];
      final isSel = selected == url;
      final kind = classifyImageRef(url);
      return GestureDetector(
        onTap: enabled ? () => onSelect(url) : null,
        child: AnimatedScale(
          scale: isSel ? 1.03 : 1,
          duration: const Duration(milliseconds: 180),
          child: Container(
            decoration: BoxDecoration(
              border: Border.all(color: isSel ? QCTokens.primary : Theme.of(c).colorScheme.outlineVariant, width: isSel ? 3 : 1),
              borderRadius: BorderRadius.circular(12),
              color: Theme.of(c).colorScheme.surface,
            ),
            clipBehavior: Clip.antiAlias,
            child: kind == ImageRefKind.placeholder
                ? Center(child: Icon([Icons.pets, Icons.water, Icons.forest, Icons.surfing][idx % 4], size: 48, color: isSel ? QCTokens.primary : Colors.grey))
                : imageRefThumb(url),
          ),
        ),
      );
    },
  );
}

class StudyScreen extends StatefulWidget {
  const StudyScreen({
    super.key,
    required this.store,
    required this.mode,
    required this.questions,
    this.deck,
    this.timeLimitSeconds,
  });
  final AppStore store;
  final StudyMode mode;
  final List<Question> questions;
  final Deck? deck;
  final int? timeLimitSeconds;
  @override
  State<StudyScreen> createState() => _StudyScreenState();
}

class _StudyScreenState extends State<StudyScreen> {
  late List<Question> queue;
  int i = 0, right = 0, xp = 0;
  int sessionBonus = 0;
  bool streakBonusApplied = false;
  DateTime sessionStart = DateTime.now();
  final Map<String, int> retries = {};
  final List<Question> wrong = [];
  bool reveal = false, checked = false;
  String? selected;
  final written = TextEditingController();
  List<String> orderingCurrent = [];
  Map<String, String> matchingCurrent = {};
  String? imageSelected;
  // Animaciones: triggers y dirección de salida
  int popTick = 0, shakeTick = 0, hintTick = 0;
  Offset exitDir = Offset.zero;
  bool isFlipping = false;
  // Examen / maratón
  Timer? timer;
  int? remainingSeconds;
  int marathonStreak = 0;
  bool finished = false;
  @override
  void initState() {
    super.initState();
    sessionStart = DateTime.now();
    queue = List.of(widget.questions);
    // La cola ya viene ordenada del engine; no re-mezclar aquí.
    if (widget.timeLimitSeconds != null) {
      remainingSeconds = widget.timeLimitSeconds;
      timer = Timer.periodic(const Duration(seconds: 1), (t) {
        if (!mounted || finished) return;
        setState(() {
          remainingSeconds = (remainingSeconds ?? 1) - 1;
        });
        if ((remainingSeconds ?? 0) <= 0) {
          _finish(timeUp: true);
        }
      });
    }
  }

  @override
  void dispose() {
    timer?.cancel();
    written.dispose();
    super.dispose();
  }

  Question get q => queue[i];
  bool get last => i == queue.length - 1;
  String _modeTitle() => switch (widget.mode) {
    StudyMode.review => 'Repaso',
    StudyMode.random => t('randomAction'),
    StudyMode.exam => t('examAction'),
    StudyMode.marathon => 'Maratón 🔥 $marathonStreak',
  };

  String _timeLabel(int s) =>
      '${(s ~/ 60).toString().padLeft(2, '0')}:${(s % 60).toString().padLeft(2, '0')}';

  // Hint index for progressive reveal
  int hintIndex = 0;

  @override
  Widget build(BuildContext c) {
    final cat = widget.deck?.title ?? 'Estudio';
    final progress = queue.isEmpty ? 0.0 : (i + 1) / queue.length;
    return Scaffold(
      appBar: AppBar(
        title: Text('${_modeTitle()} · ${i + 1} / ${queue.length}'),
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(4),
          child: LinearProgressIndicator(value: progress),
        ),
        actions: [
          if (remainingSeconds != null)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Center(
                child: Text(
                  _timeLabel(remainingSeconds!),
                  style: const TextStyle(
                    fontWeight: FontWeight.bold,
                    fontSize: 16,
                  ),
                ),
              ),
            ),
        ],
      ),
      body: Center(
        child: AnimatedSwitcher(
          duration: qcMed(c, widget.store.settings.animationsEnabled),
          layoutBuilder: (cur, prev) => Stack(
            alignment: Alignment.topCenter,
            children: [...prev, if (cur != null) cur],
          ),
          transitionBuilder: (child, anim) {
            final curved = CurvedAnimation(parent: anim, curve: Curves.easeOut, reverseCurve: Curves.easeIn);
            if (isFlipping) {
              final rot = Tween<double>(begin: 1.5, end: 0).animate(curved);
              return AnimatedBuilder(
                animation: rot,
                builder: (_, ch) => Transform(
                  transform: Matrix4.identity()
                    ..setEntry(3, 2, 0.001)
                    ..rotateY(rot.value),
                  alignment: Alignment.center,
                  child: ch,
                ),
                child: FadeTransition(opacity: anim, child: child),
              );
            }
            final slide = Tween<Offset>(begin: exitDir == Offset.zero ? const Offset(0, 0.08) : -exitDir, end: Offset.zero).animate(curved);
            return FadeTransition(
              opacity: anim,
              child: SlideTransition(position: slide, child: child),
            );
          },
          child: GestureDetector(
            key: ValueKey('card-${q.id}-$i'),
            onHorizontalDragEnd: q.type == QuestionType.trueFalse && !checked && !reveal
                ? (d) {
                    final v = d.primaryVelocity ?? 0;
                    if (v > 300) {
                      setState(() => selected = 'Verdadero');
                      _onTrueFalseSwipe('Verdadero');
                    } else if (v < -300) {
                      setState(() => selected = 'Falso');
                      _onTrueFalseSwipe('Falso');
                    } else if (v.abs() > 80) {
                      final dir = v > 0 ? 'Verdadero' : 'Falso';
                      setState(() => selected = dir);
                      _onTrueFalseSwipe(dir);
                    }
                  }
                : null,
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(16),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 520),
                child: QCCard(
                  key: ValueKey(q.id),
                  type: q.type,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      QCHeader(
                        category: cat,
                        index: i + 1,
                        total: queue.length,
                        progress: progress,
                      ),
                      const SizedBox(height: 16),
                      AnimatedSwitcher(
                        duration: qcFast(c, widget.store.settings.animationsEnabled),
                        child: QCQuestion(
                          _displayPrompt(q),
                          key: ValueKey(q.prompt),
                          image: q.type == QuestionType.flashcard
                              ? Container(
                                  padding: const EdgeInsets.all(12),
                                  decoration: BoxDecoration(
                                    color: Theme.of(c).colorScheme.primaryContainer.withValues(alpha: 0.6),
                                    shape: BoxShape.circle,
                                  ),
                                  child: Icon(
                                    Icons.psychology_outlined,
                                    size: 28,
                                    color: Theme.of(c).colorScheme.primary,
                                  ),
                                )
                              : null,
                        ),
                      ),
                      if (q.tags.isNotEmpty)
                        Padding(
                          padding: const EdgeInsets.only(top: 8),
                          child: Text(
                            q.tags.join('  '),
                            textAlign: TextAlign.center,
                            style: Theme.of(c).textTheme.labelMedium?.copyWith(
                              color: Theme.of(c).colorScheme.onSurfaceVariant,
                            ),
                          ),
                        ),
                      const SizedBox(height: 20),
                      if (q.hints.isNotEmpty && !checked && !reveal)
                        AnimatedSize(
                          duration: qcFast(c, widget.store.settings.animationsEnabled),
                          child: QCHint(
                            hints: q.hints,
                            revealed: hintIndex,
                            onReveal: () => setState(() => hintIndex++),
                          ),
                        ),
                      if (q.hints.isNotEmpty && !checked && !reveal) const SizedBox(height: 16),
                      AnimatedSwitcher(
                        duration: qcReduce(c, widget.store.settings.animationsEnabled) ? Duration.zero : const Duration(milliseconds: 250),
                        transitionBuilder: (ch, anim) => FadeTransition(
                          opacity: anim,
                          child: ScaleTransition(
                            scale: Tween<double>(begin: 0.97, end: 1).animate(CurvedAnimation(parent: anim, curve: Curves.easeOut)),
                            child: ch,
                          ),
                        ),
                        child: _interaction(c),
                      ),
                      const SizedBox(height: 12),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          if (xp > 0)
                            AnimatedSwitcher(
                              duration: qcFast(c, widget.store.settings.animationsEnabled),
                              child: Container(
                                key: ValueKey(xp),
                                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                                decoration: BoxDecoration(
                                  color: QCTokens.success.withValues(alpha: 0.12),
                                  borderRadius: BorderRadius.circular(20),
                                ),
                                child: Text(
                                  '⭐ +$xp XP',
                                  style: const TextStyle(
                                    fontSize: 12,
                                    fontWeight: FontWeight.bold,
                                    color: QCTokens.success,
                                  ),
                                ),
                              ),
                            ),
                          if (marathonStreak > 1) ...[
                            const SizedBox(width: 8),
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                              decoration: BoxDecoration(
                                color: QCTokens.warning.withValues(alpha: 0.12),
                                borderRadius: BorderRadius.circular(20),
                              ),
                              child: Text(
                                '🔥 $marathonStreak',
                                style: const TextStyle(
                                  fontSize: 12,
                                  fontWeight: FontWeight.bold,
                                  color: QCTokens.warning,
                                ),
                              ),
                            ),
                          ],
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  String _displayPrompt(Question qq) {
    if (qq.type == QuestionType.fillBlank && qq.prompt.contains('___')) {
      return qq.prompt.replaceAll('___', '____');
    }
    return qq.prompt;
  }

  Widget _interaction(BuildContext c) {
    // Flashcard
    if (q.type == QuestionType.flashcard) {
      if (!reveal) {
        return QCNextButton(
          label: 'Ver respuesta',
          onPressed: () {
            setState(() {
              isFlipping = true;
              reveal = true;
            });
            Future.delayed(const Duration(milliseconds: 600), () {
              if (mounted) setState(() => isFlipping = false);
            });
          },
        );
      }
      return Column(
        key: const ValueKey('flashcard-revealed'),
        children: [
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: Theme.of(c).colorScheme.primaryContainer.withOpacity(0.5),
              borderRadius: BorderRadius.circular(16),
            ),
            child: Text(
              q.answer,
              style: Theme.of(c).textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.bold,
              ),
              textAlign: TextAlign.center,
            ),
          ),
          if (q.explanation.trim().isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                q.explanation,
                textAlign: TextAlign.center,
                style: Theme.of(c).textTheme.bodyMedium,
              ),
            ),
          const SizedBox(height: 16),
          QCDifficulty(onRate: _rate),
        ],
      );
    }
    // Si ya se comprobó, muestra feedback unificado + dificultad/next
    if (checked) {
      final ok = _correct();
      final gain = ok ? (q.type == QuestionType.flashcard ? 0 : 10) : 0;
      return Column(
        key: ValueKey('feedback-$i-$ok'),
        children: [
          QCFeedback(
            correct: ok,
            answer: q.answer,
            explanation: q.explanation,
            xp: gain,
          ),
          const SizedBox(height: 16),
          if (ok)
            QCDifficulty(onRate: _rate)
          else
            Column(
              children: [
                QCDifficulty(onRate: _rate),
                const SizedBox(height: 8),
                Text(
                  'Elige qué tan bien la sabías para programar el repaso.',
                  style: Theme.of(c).textTheme.labelSmall,
                  textAlign: TextAlign.center,
                ),
              ],
            ),
        ],
      );
    }
    // Interacciones por tipo
    if (q.type == QuestionType.multipleChoice) {
      return Column(
        children: [
          QCShake(
            trigger: shakeTick,
            child: QCPop(
              trigger: popTick,
              child: QCMultiple(
                options: q.options,
                selected: selected,
                correct: [q.answer],
                revealed: false,
                onSelect: (v) => setState(() => selected = v),
              ),
            ),
          ),
          const SizedBox(height: 12),
          SizedBox(
            width: double.infinity,
            child: FilledButton(
              onPressed: selected == null ? null : _check,
              style: FilledButton.styleFrom(
                padding: const EdgeInsets.symmetric(vertical: 14),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(14),
                ),
              ),
              child: Text(t('check')),
            ),
          ),
        ],
      );
    }
    if (q.type == QuestionType.trueFalse) {
      return Column(
        children: [
          QCShake(
            trigger: shakeTick,
            child: QCPop(
              trigger: popTick,
              child: QCTrueFalse(
                selected: selected,
                revealed: false,
                correct: q.answer,
                onSelect: (v) => setState(() => selected = v),
              ),
            ),
          ),
          const SizedBox(height: 12),
          SizedBox(
            width: double.infinity,
            child: FilledButton(
              onPressed: selected == null ? null : _check,
              style: FilledButton.styleFrom(
                padding: const EdgeInsets.symmetric(vertical: 14),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(14),
                ),
              ),
              child: Text(t('check')),
            ),
          ),
        ],
      );
    }
    if (q.type == QuestionType.ordering) {
      if (orderingCurrent.isEmpty) orderingCurrent = List.of(q.options);
      return Column(
        children: [
          QCOrdering(
            items: orderingCurrent,
            onChanged: (v) => orderingCurrent = v,
          ),
          const SizedBox(height: 12),
          SizedBox(
            width: double.infinity,
            child: FilledButton(
              onPressed: _check,
              style: FilledButton.styleFrom(
                padding: const EdgeInsets.symmetric(vertical: 14),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
              ),
              child: Text(t('check')),
            ),
          ),
        ],
      );
    }
    if (q.type == QuestionType.matching) {
      return Column(
        children: [
          QCMatching(
            pairs: q.pairs.isNotEmpty ? q.pairs : q.options.map((e) => '$e|$e').toList(),
            onMatch: (m) {
              matchingCurrent = m;
              if (m.length == (q.pairs.isNotEmpty ? q.pairs.length : q.options.length) && !checked) {
                final reduce = qcReduce(context, widget.store.settings.animationsEnabled);
                Future.delayed(reduce ? Duration.zero : const Duration(milliseconds: 350), () {
                  if (mounted && !checked) _check();
                });
              }
            },
          ),
          const SizedBox(height: 12),
          SizedBox(
            width: double.infinity,
            child: FilledButton(
              onPressed: matchingCurrent.isEmpty ? null : _check,
              style: FilledButton.styleFrom(
                padding: const EdgeInsets.symmetric(vertical: 14),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
              ),
              child: Text(t('check')),
            ),
          ),
        ],
      );
    }
    if (q.type == QuestionType.imageChoice) {
      final urls = q.imageUrls.isNotEmpty ? q.imageUrls : q.options;
      return Column(
        children: [
          QCImageChoice(
            urls: urls,
            selected: imageSelected,
            onSelect: (v) => setState(() => imageSelected = v),
          ),
          const SizedBox(height: 12),
          SizedBox(
            width: double.infinity,
            child: FilledButton(
              onPressed: imageSelected == null ? null : _check,
              style: FilledButton.styleFrom(
                padding: const EdgeInsets.symmetric(vertical: 14),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
              ),
              child: Text(t('check')),
            ),
          ),
        ],
      );
    }
    // written + fillBlank comparten input
    return Column(
      children: [
        QCShake(
          trigger: shakeTick,
          child: QCPop(
            trigger: popTick,
            child: QCWritten(controller: written),
          ),
        ),
        const SizedBox(height: 12),
        SizedBox(
          width: double.infinity,
          child: FilledButton(
            onPressed: written.text.trim().isEmpty ? null : _check,
            style: FilledButton.styleFrom(
              padding: const EdgeInsets.symmetric(vertical: 14),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(14),
              ),
            ),
            child: Text(t('check')),
          ),
        ),
      ],
    );
  }

  // ignore: unused_element
  Widget _feedbackOld(BuildContext c) {
    final ok = _correct();
    return Column(
      children: [
        Icon(
          ok ? Icons.check_circle : Icons.lightbulb,
          color: ok ? Colors.green : Colors.orange,
          size: 50,
        ),
        Text(
          ok
              ? '¡Correcto!'
              : 'Casi. La respuesta correcta es:',
          style: Theme.of(c).textTheme.titleLarge,
          textAlign: TextAlign.center,
        ),
        if (!ok)
          Padding(
            padding: const EdgeInsets.all(8),
            child: Text(
              q.answer,
              style: Theme.of(c).textTheme.headlineSmall,
              textAlign: TextAlign.center,
            ),
          ),
        if (q.explanation.trim().isNotEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            child: Text(
              q.explanation,
              style: Theme.of(c).textTheme.bodyMedium,
              textAlign: TextAlign.center,
            ),
          ),
        if (!ok)
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 16, vertical: 4),
            child: Text(
              'Esta pregunta volverá a aparecer para ayudarte a recordarla.',
              textAlign: TextAlign.center,
            ),
          ),
        const SizedBox(height: 12),
        FilledButton(
          onPressed: () => _rate(ok ? Rating.good : Rating.again),
          child: Text(last ? 'Ver resumen' : t('next')),
        ),
      ],
    );
  }

  bool _correct() {
    if (q.type == QuestionType.multipleChoice || q.type == QuestionType.trueFalse) {
      return checkWrittenAnswer(selected ?? '', q.answer, q.accepted);
    }
    if (q.type == QuestionType.ordering) {
      final cur = orderingCurrent.isEmpty ? q.options : orderingCurrent;
      return cur.join(',') == q.answer;
    }
    if (q.type == QuestionType.matching) {
      if (matchingCurrent.length != q.pairs.length) return false;
      for (final p in q.pairs) {
        final parts = p.split('|');
        if (parts.length < 2) continue;
        if (matchingCurrent[parts[0]] != parts[1]) return false;
      }
      return true;
    }
    if (q.type == QuestionType.imageChoice) {
      return (imageSelected ?? '') == q.answer;
    }
    return checkWrittenAnswer(written.text, q.answer, q.accepted);
  }

  void _check() {
    final ok = _correct();
    final reduce = qcReduce(context, widget.store.settings.animationsEnabled);
    // Micro: pop/shake antes de feedback — deja que se vea
    if (q.type == QuestionType.multipleChoice || q.type == QuestionType.trueFalse) {
      if (ok) {
        popTick++;
      } else {
        shakeTick++;
      }
    } else {
      if (!ok) shakeTick++;
      if (ok) popTick++;
    }
    // Dirección de salida para transición de tarjeta
    if (q.type == QuestionType.trueFalse) {
      final sel = selected ?? '';
      exitDir = sel == 'Verdadero' ? const Offset(1, 0) : const Offset(-1, 0);
    } else if (!ok) {
      exitDir = const Offset(0, 0.06);
    } else {
      exitDir = const Offset(0, -0.06);
    }
    setState(() {});
    // Deja 220ms para que pop/shake se perciba antes del feedback
    final delay = reduce ? Duration.zero : Duration(milliseconds: ok ? 180 : 280);
    Future.delayed(delay, () {
      if (!mounted || checked) return;
      setState(() => checked = true);
    });
  }

  void _onTrueFalseSwipe(String value) {
    // Swipe representa solo la opción, no corrección
    exitDir = value == 'Verdadero' ? const Offset(1, 0) : const Offset(-1, 0);
    _check();
  }
  Future<void> _rate(Rating r) async {
    if (finished) return;
    final ok = r != Rating.again;
    final wasDifficult = q.difficult;
    SpacedRepetitionService().record(q, r);
    q.updatedAt = DateTime.now();
    widget.store.profile.recordAnswer(correct: ok, now: DateTime.now());
    if (ok) {
      right++;
      if (wasDifficult) widget.store.profile.difficultFixed++;
      final n = r == Rating.easy ? 15 : 10;
      final int gain = widget.mode == StudyMode.marathon
          ? 10 + min(marathonStreak, 10).toInt()
          : n;
      widget.store.profile.xp += gain;
      xp += gain;
      FeedbackService.correct(widget.store.settings);
      if (widget.mode == StudyMode.marathon) {
        marathonStreak++;
        if (marathonStreak > widget.store.profile.marathonBest) {
          widget.store.profile.marathonBest = marathonStreak;
        }
      }
    } else {
      FeedbackService.wrong(widget.store.settings);
      if (!wrong.any((e) => e.id == q.id)) wrong.add(q);
      if (widget.mode == StudyMode.marathon) {
        await widget.store.save();
        await _finish(marathonFail: true);
        return;
      }
    }
    // Racha: solo una vez por día nuevo (+25 XP).
    final isNewDay = widget.store.profile.registerStudyDay(DateTime.now());
    if (isNewDay && !streakBonusApplied) {
      streakBonusApplied = true;
      widget.store.profile.xp += 25;
      xp += 25;
    }
    await widget.store.save();
    if (!mounted || finished) return;

    // Reencolado intra-sesión §13 (no en examen/maratón).
    if (!ok || r == Rating.hard) {
      final used = retries[q.id] ?? 0;
      final idx = reinsertIndex(
        mode: widget.mode,
        rating: r,
        currentIndex: i,
        queueLength: queue.length,
        retriesForQuestion: used,
      );
      if (idx != null) {
        retries[q.id] = used + 1;
        // Insertar después: queue.insert clampa al final.
        queue.insert(idx, q);
      }
    }

    if (last) {
      await _finish();
    } else {
      setState(() {
        i++;
        reveal = false;
        checked = false;
        selected = null;
        hintIndex = 0;
        orderingCurrent = [];
        matchingCurrent = {};
        imageSelected = null;
        popTick = 0;
        shakeTick = 0;
        written.clear();
      });
    }
  }

  Future<void> _finish({bool timeUp = false, bool marathonFail = false}) async {
    if (finished) return;
    finished = true;
    timer?.cancel();
    final elapsed = DateTime.now().difference(sessionStart).inSeconds;
    // Bonus fin de sesión §19: +50 siempre, +100 en repaso, examen por nota.
    var bonus = 50;
    if (widget.mode == StudyMode.review) bonus = 100;
    if (widget.mode == StudyMode.marathon) {
      bonus = min(marathonStreak * 2, 100).toInt();
    }
    if (widget.mode == StudyMode.exam) {
      final pct = queue.isEmpty ? 0 : (right / queue.length * 100).round();
      bonus = pct >= 90
          ? 150
          : pct >= 70
          ? 100
          : 50;
    }
    sessionBonus = bonus;
    widget.store.profile.xp += bonus;
    xp += bonus;
    widget.store.profile.sessionsCompleted++;
    widget.store.profile.timeStudiedSeconds += elapsed;
    widget.store.sessions.add(
      StudySession(
        id: DateTime.now().microsecondsSinceEpoch.toString(),
        deckId: widget.deck?.id,
        mode: widget.mode,
        startedAt: sessionStart,
        finishedAt: DateTime.now(),
        questionsAnswered: queue.length,
        correctAnswers: right,
        xpEarned: xp,
      ),
    );
    final newly = checkAchievements(widget.store);
    if (newly.isNotEmpty) {
      FeedbackService.achievement(widget.store.settings);
    }
    await widget.store.save();
    if (!mounted) return;
    Navigator.pushReplacement(
      context,
      MaterialPageRoute(
        builder: (_) => Summary(
          total: queue.length,
          right: right,
          xp: xp,
          sessionBonus: sessionBonus,
          streakBonus: streakBonusApplied ? 25 : 0,
          mode: widget.mode,
          elapsedSeconds: elapsed,
          wrong: List.of(wrong),
          timeUp: timeUp,
          marathonStreak: marathonStreak,
          marathonBest: widget.store.profile.marathonBest,
          deck: widget.deck,
          newlyUnlocked: newly,
          store: widget.store,
        ),
      ),
    );
  }
}

class Summary extends StatefulWidget {
  const Summary({
    super.key,
    required this.total,
    required this.right,
    required this.xp,
    this.sessionBonus = 0,
    this.streakBonus = 0,
    this.mode = StudyMode.review,
    this.elapsedSeconds = 0,
    this.wrong = const [],
    this.timeUp = false,
    this.marathonStreak = 0,
    this.marathonBest = 0,
    this.deck,
    this.newlyUnlocked = const [],
    this.store,
  });
  final int total, right, xp, sessionBonus, streakBonus;
  final StudyMode mode;
  final int elapsedSeconds;
  final List<Question> wrong;
  final bool timeUp;
  final int marathonStreak, marathonBest;
  final Deck? deck;
  final List<String> newlyUnlocked;
  final AppStore? store;

  @override
  State<Summary> createState() => _SummaryState();
}

class _SummaryState extends State<Summary> {
  Timer? _timer;
  int _remaining = 3;

  String _timeLabel(int s) =>
      '${(s ~/ 60).toString().padLeft(2, '0')}:${(s % 60).toString().padLeft(2, '0')}';

  @override
  void initState() {
    super.initState();
    final reduce = widget.store?.settings.animationsEnabled ?? true;
    // Sianimations off, cierra casi inmediato pero deja ver el resumen 1s
    final totalMs = reduce ? 2500 : 1000;
    const tick = 100;
    _timer = Timer.periodic(const Duration(milliseconds: tick), (t) {
      if (!mounted) return;
      setState(() => _remaining = ((totalMs - t.tick * tick) / 1000).ceil().clamp(0, 3));
      if (t.tick * tick >= totalMs) {
        t.cancel();
        if (!mounted) return;
        // Vuelve a Inicio cerrando tarjetas
        Navigator.of(context).popUntil((r) => r.isFirst);
      }
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  void _cancelTimerAndStay() => _timer?.cancel();

  @override
  Widget build(BuildContext c) {
    final pct = widget.total == 0 ? 0 : (widget.right / widget.total * 100).round();
    final isMarathon = widget.mode == StudyMode.marathon;
    final isExam = widget.mode == StudyMode.exam;
    final grade = !isExam
        ? null
        : pct >= 90
        ? 'Excelente 🎉'
        : pct >= 70
        ? 'Bien 🙂'
        : pct >= 50
        ? 'Puedes mejorar 💪'
        : 'Sigue practicando 📚';
    return Scaffold(
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(28),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Text(
                isMarathon ? '🔥' : '🎉',
                style: const TextStyle(fontSize: 64),
              ),
              Text(
                isMarathon
                    ? '¡Maratón terminado!'
                    : widget.timeUp
                    ? '⏱ ¡Tiempo agotado!'
                    : '¡Sesión completada!',
                style: Theme.of(c).textTheme.headlineSmall
                    ?.copyWith(fontWeight: FontWeight.bold),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 16),
              if (isMarathon) ...[
                Text(
                  '${widget.marathonStreak} correctas seguidas',
                  style: Theme.of(c).textTheme.titleLarge,
                ),
                Text('Mejor racha: ${widget.marathonBest}'),
              ] else ...[
                Text(
                  '${widget.right} / ${widget.total} correctas',
                  style: Theme.of(c).textTheme.titleLarge,
                ),
                Text('$pct% de precisión'),
                if (grade != null) ...[
                  const SizedBox(height: 6),
                  Text(
                    grade,
                    style: const TextStyle(fontWeight: FontWeight.bold),
                  ),
                ],
              ],
              const SizedBox(height: 8),
              Text('⏱ ${_timeLabel(widget.elapsedSeconds)}'),
              const SizedBox(height: 12),
              Text(
                '+${widget.xp} XP',
                style: const TextStyle(fontSize: 22, color: Colors.green),
              ),
              if (widget.sessionBonus > 0 || widget.streakBonus > 0) ...[
                const SizedBox(height: 8),
                Text(
                  [
                    if (widget.sessionBonus > 0) 'Sesión +${widget.sessionBonus}',
                    if (widget.streakBonus > 0) 'Racha +${widget.streakBonus}',
                  ].join(' · '),
                  style: Theme.of(c).textTheme.bodyMedium,
                  textAlign: TextAlign.center,
                ),
              ],
              if (widget.wrong.isNotEmpty) ...[
                const SizedBox(height: 16),
                Text(
                  '🔴 ${widget.wrong.length} para repasar',
                  style: const TextStyle(fontWeight: FontWeight.bold),
                ),
              ],
              if (widget.newlyUnlocked.isNotEmpty) ...[
                const SizedBox(height: 16),
                ...widget.newlyUnlocked.map((id) {
                  final a = achievementsCatalog.firstWhere(
                    (e) => e.id == id,
                    orElse: () => achievementsCatalog.first,
                  );
                  return Card(
                    color: Theme.of(
                      c,
                    ).colorScheme.tertiaryContainer,
                    margin: const EdgeInsets.only(bottom: 8),
                    child: ListTile(
                      leading: Text(
                        a.icon,
                        style: const TextStyle(fontSize: 28),
                      ),
                      title: Text('¡Logro: ${a.title('es')}!'),
                      subtitle: Text(a.desc('es')),
                    ),
                  );
                }),
              ],
              const SizedBox(height: 24),
              if (widget.wrong.isNotEmpty)
                FilledButton.icon(
                  onPressed: () {
                    _cancelTimerAndStay();
                    Navigator.pushReplacement(
                      c,
                      MaterialPageRoute(
                        builder: (_) => ReviewErrorsScreen(
                          store: widget.store,
                          questions: widget.wrong,
                        ),
                      ),
                    );
                  },
                  icon: const Icon(Icons.refresh),
                  label: Text(t('reviewErrors')),
                ),
              const SizedBox(height: 10),
              OutlinedButton(
                onPressed: () {
                  _timer?.cancel();
                  Navigator.of(c).popUntil((r) => r.isFirst);
                },
                child: Text('Volver al inicio ($_remaining)'),
              ),
              const SizedBox(height: 8),
              LinearProgressIndicator(
                value: (3 - _remaining) / 3,
                minHeight: 4,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class ReviewErrorsScreen extends StatelessWidget {
  const ReviewErrorsScreen({super.key, this.store, required this.questions});
  final AppStore? store;
  final List<Question> questions;
  @override
  Widget build(BuildContext c) => Scaffold(
    appBar: AppBar(title: Text(t('reviewErrors'))),
    body: questions.isEmpty
        ? Center(child: Text(t('noErrors')))
        : ListView(
            padding: const EdgeInsets.all(16),
            children: [
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: Text(
                  '🔴 ${questions.length} preguntas que debes repasar',
                  style: Theme.of(c).textTheme.titleMedium,
                ),
              ),
              ...questions.map(
                (q) => Card(
                  margin: const EdgeInsets.only(bottom: 10),
                  child: ListTile(
                    leading: const Text('🔴'),
                    title: Text(q.prompt),
                    subtitle: Text(
                      '${_typeName(q.type)}\nRespuesta: ${q.answer}${q.explanation.trim().isNotEmpty ? '\n${q.explanation}' : ''}',
                    ),
                    isThreeLine: true,
                  ),
                ),
              ),
              const SizedBox(height: 12),
              if (store != null)
                FilledButton.icon(
                  onPressed: () => Navigator.pushReplacement(
                    c,
                    MaterialPageRoute(
                      builder: (_) => StudyScreen(
                        store: store!,
                        mode: StudyMode.review,
                        questions: List.of(questions),
                      ),
                    ),
                  ),
                  icon: const Icon(Icons.play_arrow),
                  label: const Text('Repasar ahora'),
                ),
            ],
          ),
  );
}

class SearchScreen extends StatefulWidget {
  const SearchScreen({super.key, required this.store, required this.study});
  final AppStore store;
  final StudyFn study;
  @override
  State<SearchScreen> createState() => _SearchScreenState();
}

class _SearchScreenState extends State<SearchScreen> {
  final controller = TextEditingController();
  String query = '';
  bool onlyFav = false;
  @override
  Widget build(BuildContext c) {
    final results = query.trim().isEmpty
        ? <Question>[]
        : widget.store.search(query).where((q) {
            if (onlyFav && !q.isFavorite) return false;
            return true;
          }).toList();
    return Scaffold(
      appBar: AppBar(title: Text(t('search'))),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          TextField(
            controller: controller,
            autofocus: true,
            decoration: InputDecoration(
              labelText: '🔍 Buscar preguntas...',
              hintText: 'mitosis',
            ),
            onChanged: (v) => setState(() => query = v),
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Solo favoritas'),
            value: onlyFav,
            onChanged: (v) => setState(() => onlyFav = v),
          ),
          if (query.trim().isNotEmpty && results.isEmpty)
            const Padding(
              padding: EdgeInsets.all(24),
              child: Text(
                'Sin resultados. Prueba con otra palabra.',
                textAlign: TextAlign.center,
              ),
            ),
          ...results.map(
            (q) => ListTile(
              leading: Text(
                widget.store.decks
                    .where((d) => d.id == q.deckId)
                    .map((d) => d.icon)
                    .firstOrNull ??
                    '📚',
              ),
              title: Text(q.prompt),
              subtitle: Text(q.answer),
              trailing: IconButton(
                icon: Icon(
                  q.isFavorite ? Icons.star : Icons.star_border,
                  color: q.isFavorite ? Colors.amber : null,
                ),
                onPressed: () async {
                  q.isFavorite = !q.isFavorite;
                  await widget.store.save();
                  setState(() {});
                },
              ),
            ),
          ),
          if (results.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: FilledButton.icon(
                onPressed: () => Navigator.push(
                  c,
                  MaterialPageRoute(
                    builder: (_) => StudyScreen(
                      store: widget.store,
                      mode: StudyMode.random,
                      questions: results,
                    ),
                  ),
                ),
                icon: const Icon(Icons.play_arrow),
                label: Text('Estudiar ${results.length} resultados'),
              ),
            ),
        ],
      ),
    );
  }
}

class DataScreen extends StatefulWidget {
  const DataScreen({super.key, required this.store});
  final AppStore store;
  @override
  State<DataScreen> createState() => _DataScreenState();
}

class _DataScreenState extends State<DataScreen> {
  final ioController = TextEditingController();
  @override
  Widget build(BuildContext c) => Scaffold(
    appBar: AppBar(title: Text(t('backupTitle'))),
    body: ListView(
      padding: const EdgeInsets.all(20),
      children: [
        const Text(
          'Exportar / importar tus datos localmente. Todo permanece offline.',
          style: TextStyle(fontSize: 15),
        ),
        const SizedBox(height: 16),
        FilledButton.icon(
          onPressed: () {
            setState(() => ioController.text = widget.store.exportJson());
            HapticFeedback.lightImpact();
            ScaffoldMessenger.of(c).showSnackBar(
              const SnackBar(
                content: Text('JSON generado abajo. Cópialo donde quieras.'),
              ),
            );
          },
          icon: const Icon(Icons.upload),
          label: Text(t('exportJson')),
        ),
        const SizedBox(height: 8),
        OutlinedButton.icon(
          onPressed: () async {
            try {
              final n = widget.store.importJson(
                ioController.text,
                replace: false,
              );
              await widget.store.save();
              if (!c.mounted) return;
              ScaffoldMessenger.of(
                c,
              ).showSnackBar(SnackBar(content: Text('$n preguntas importadas')));
              setState(() {});
            } catch (e) {
              if (!c.mounted) return;
              ScaffoldMessenger.of(
                c,
              ).showSnackBar(SnackBar(content: Text('Error al importar: $e')));
            }
          },
          icon: const Icon(Icons.download),
          label: Text(t('importJsonCombine')),
        ),
        const SizedBox(height: 8),
        TextButton.icon(
          onPressed: () async {
            final ok = await showDialog<bool>(
              context: c,
              builder: (_) => AlertDialog(
                title: Text(t('replaceAllTitle')),
                content: const Text(
                  'Se reemplazarán cuestionarios y preguntas actuales.',
                ),
                actions: [
                  TextButton(
                    onPressed: () => Navigator.pop(c, false),
                    child: Text(t('cancel')),
                  ),
                  FilledButton(
                    onPressed: () => Navigator.pop(c, true),
                    child: const Text('Reemplazar'),
                  ),
                ],
              ),
            );
            if (ok != true) return;
            try {
              widget.store.importJson(ioController.text, replace: true);
              await widget.store.save();
              if (!c.mounted) return;
              ScaffoldMessenger.of(
                c,
              ).showSnackBar(const SnackBar(content: Text('Datos reemplazados')));
              setState(() {});
            } catch (e) {
              if (!c.mounted) return;
              ScaffoldMessenger.of(
                c,
              ).showSnackBar(SnackBar(content: Text('Error: $e')));
            }
          },
          icon: const Icon(Icons.warning_amber),
          label: Text(t('importJsonReplace')),
        ),
        const SizedBox(height: 16),
        TextField(
          controller: ioController,
          maxLines: 10,
          decoration: InputDecoration(
            labelText: 'JSON de respaldo / CSV para importar',
            hintText: 'Pega JSON exportado o CSV: prompt,answer',
            border: OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: 8),
        OutlinedButton.icon(
          onPressed: () async {
            try {
              final targetDeck = widget.store.decks.isEmpty
                  ? 'importado'
                  : widget.store.decks.first.id;
              final n = widget.store.importCsv(targetDeck, ioController.text);
              await widget.store.save();
              if (!c.mounted) return;
              ScaffoldMessenger.of(
                c,
              ).showSnackBar(SnackBar(content: Text('$n preguntas CSV importadas')));
              setState(() {});
            } catch (e) {
              if (!c.mounted) return;
              ScaffoldMessenger.of(
                c,
              ).showSnackBar(SnackBar(content: Text('Error CSV: $e')));
            }
          },
          icon: const Icon(Icons.table_chart_outlined),
          label: const Text('Importar como CSV (prompt,answer)'),
        ),
        const SizedBox(height: 4),
        const Text(
          'CSV: "pregunta","respuesta" o cabecera deckId,type,prompt,answer,options,accepted (options con |).',
        ),
        const SizedBox(height: 16),
        TextButton.icon(
          onPressed: () => showDialog(
            context: c,
            builder: (_) => AlertDialog(
              title: Text(t('deleteAllTitle')),
              content: Text(t('deleteAllContent')),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(c),
                  child: Text(t('cancel')),
                ),
                FilledButton(
                  onPressed: () async {
                    widget.store.decks.clear();
                    widget.store.questions.clear();
                    widget.store.sessions.clear();
                    widget.store.profile = Profile();
                    await widget.store.save();
                    if (c.mounted) Navigator.pop(c);
                    setState(() {});
                  },
                  child: const Text('Eliminar todo'),
                ),
              ],
            ),
          ),
          icon: const Icon(Icons.delete_forever_outlined, color: Colors.red),
          label: const Text(
            'Eliminar todos los datos',
            style: TextStyle(color: Colors.red),
          ),
        ),
      ],
    ),
  );
}

class Stats extends StatelessWidget {
  const Stats({super.key, required this.store});
  final AppStore store;
  String _timeLabel(int s) {
    final h = s ~/ 3600;
    final m = (s % 3600) ~/ 60;
    if (h > 0) return '${h}h ${m}m';
    return '${m}min';
  }

  @override
  Widget build(BuildContext c) {
    final p = store.profile;
    final precision = p.answered == 0
        ? 0
        : (p.right / p.answered * 100).round();
    final stats = queueStats(store.questions);
    return ListView(
      children: [
        TitleBar(
          'Estadísticas',
          action: IconButton(
            icon: const Icon(Icons.backup_outlined),
            tooltip: t('backupTitle'),
            onPressed: () => Navigator.push(
              c,
              MaterialPageRoute(builder: (_) => DataScreen(store: store)),
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            children: [
              Row(
                children: [
                  TinyStat(
                    Icons.check_circle_outline,
                    '$precision%',
                    'precisión',
                  ),
                  const SizedBox(width: 10),
                  TinyStat(Icons.quiz_outlined, '${p.answered}', 'respondidas'),
                ],
              ),
              const SizedBox(height: 10),
              Row(
                children: [
                  TinyStat(
                    Icons.timer_outlined,
                    _timeLabel(p.timeStudiedSeconds),
                    'estudiado',
                  ),
                  const SizedBox(width: 10),
                  TinyStat(
                    Icons.local_fire_department,
                    '${p.marathonBest}',
                    'maratón',
                  ),
                ],
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20),
          child: Card(
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Esta semana',
                    style: TextStyle(fontWeight: FontWeight.bold, fontSize: 18),
                  ),
                  const SizedBox(height: 12),
                  WeeklyChart(profile: p),
                  const SizedBox(height: 8),
                  Text(
                    '🔥 ${p.currentStreak} días · Mejor: ${p.longestStreak} · ${p.sessionsCompleted} sesiones',
                  ),
                ],
              ),
            ),
          ),
        ),
        const SizedBox(height: 10),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20),
          child: Card(
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Tu progreso',
                    style: TextStyle(fontWeight: FontWeight.bold, fontSize: 18),
                  ),
                  const SizedBox(height: 16),
                  Text(
                    '🟢 ${stats.mastered} preguntas dominadas',
                  ),
                  const SizedBox(height: 8),
                  Text(
                    '🔴 ${stats.difficult} necesitan práctica',
                  ),
                  const SizedBox(height: 8),
                  Text('📚 ${p.sessionsCompleted} sesiones completadas'),
                  const SizedBox(height: 16),
                  const Text(
                    'Dominio por cuestionario',
                    style: TextStyle(fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 8),
                  if (store.decks.isEmpty)
                    const Text('Crea un cuestionario para ver tu dominio.'),
                  ...store.decks.map((d) {
                    final qs = store.deckQuestions(d.id);
                    final mastered = qs.where((e) => e.mastered).length;
                    final pct = qs.isEmpty
                        ? 0
                        : (mastered / qs.length * 100).round();
                    return Padding(
                      padding: const EdgeInsets.only(bottom: 10),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('${d.icon} ${d.title} · $pct%'),
                          const SizedBox(height: 4),
                          LinearProgressIndicator(
                            value: qs.isEmpty ? 0 : mastered / qs.length,
                          ),
                        ],
                      ),
                    );
                  }),
                  const SizedBox(height: 16),
                  const Text(
                    'Últimas sesiones',
                    style: TextStyle(fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 8),
                  if (store.sessions.isEmpty)
                    const Text('Aún no hay sesiones. ¡Empieza un repaso!'),
                  ...store.sessions.reversed.take(5).map((s) {
                    final modeName = switch (s.mode) {
                      StudyMode.review => 'Repaso',
                      StudyMode.random => t('randomAction'),
                      StudyMode.exam => t('examAction'),
                      StudyMode.marathon => t('marathon'),
                    };
                    return ListTile(
                      contentPadding: EdgeInsets.zero,
                      dense: true,
                      leading: const Icon(Icons.history),
                      title: Text('$modeName · ${s.accuracy}% · +${s.xpEarned} XP'),
                      subtitle: Text(
                        '${s.correctAnswers}/${s.questionsAnswered} · ${s.finishedAt.day}/${s.finishedAt.month} ${s.finishedAt.hour.toString().padLeft(2, '0')}:${s.finishedAt.minute.toString().padLeft(2, '0')}',
                      ),
                    );
                  }),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class ProfilePage extends StatelessWidget {
  const ProfilePage({super.key, required this.store});
  final AppStore store;
  String _timeLabel(int s) {
    final h = s ~/ 3600;
    final m = (s % 3600) ~/ 60;
    if (h > 0) return '${h}h ${m}m';
    return '${m}min';
  }

  @override
  Widget build(BuildContext c) {
    final p = store.profile;
    final currentFloor = xpForLevel(p.level);
    final nextFloor = p.level >= levelNames.length
        ? currentFloor + 1000
        : xpForLevel(p.level + 1);
    final progress = nextFloor <= currentFloor
        ? 1.0
        : ((p.xp - currentFloor) / (nextFloor - currentFloor)).clamp(0.0, 1.0);
    Future<void> openEdit() async {
      FeedbackService.select(store.settings);
      await Navigator.push(
        c,
        MaterialPageRoute(builder: (_) => ProfileEditScreen(store: store)),
      );
    }

    return ListView(
      children: [
        TitleBar(
          'Perfil',
          action: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              IconButton(
                icon: const Icon(Icons.edit_outlined),
                tooltip: 'Editar perfil',
                onPressed: openEdit,
              ),
              IconButton(
                icon: const Icon(Icons.settings_outlined),
                tooltip: 'Configuración',
                onPressed: () {
                  FeedbackService.select(store.settings);
                  Navigator.push(
                    c,
                    MaterialPageRoute(
                      builder: (_) => SettingsScreen(store: store),
                    ),
                  );
                },
              ),
            ],
          ),
        ),
        const SizedBox(height: 20),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20),
          child: Card(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 20, 16, 16),
              child: Column(
                children: [
                  Center(
                    child: GestureDetector(
                      onTap: openEdit,
                      child: Tooltip(
                        message: 'Toca para editar',
                        child: ProfileAvatar(p.avatar, radius: 40),
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  Center(
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 320),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 8),
                        child: FittedBox(
                          fit: BoxFit.scaleDown,
                          child: Text(
                            p.displayName,
                            style: TextStyle(
                              fontSize: 22,
                              fontWeight: FontWeight.bold,
                              height: 1.2,
                              color: Theme.of(c).colorScheme.onSurface,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            textAlign: TextAlign.center,
                            softWrap: false,
                            textScaler: TextScaler.linear(1.0),
                          ),
                        ),
                      ),
                    ),
                  ),
                  if (p.metaLine(store.settings.language).isNotEmpty)
                    Center(
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 300),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 8),
                          child: FittedBox(
                            fit: BoxFit.scaleDown,
                            child: Text(
                              p.metaLine(store.settings.language),
                              style: Theme.of(
                                c,
                              ).textTheme.bodyMedium?.copyWith(
                                color: Theme.of(
                                  c,
                                ).colorScheme.onSurfaceVariant,
                              ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              textAlign: TextAlign.center,
                              softWrap: false,
                              textScaler: TextScaler.linear(1.0),
                            ),
                          ),
                        ),
                      ),
                    ),
                  Center(
                    child: TextButton.icon(
                      onPressed: openEdit,
                      icon: const Icon(Icons.edit_outlined, size: 18),
                      label: const Text('Editar perfil'),
                    ),
                  ),
                  Center(
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 280),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 8),
                        child: FittedBox(
                          fit: BoxFit.scaleDown,
                          child: Text(
                            '${p.levelName} · Nivel ${p.level}',
                            style: Theme.of(c).textTheme.titleSmall?.copyWith(
                              fontWeight: FontWeight.w600,
                              color: Theme.of(c).colorScheme.onSurface,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            textAlign: TextAlign.center,
                            softWrap: false,
                            textScaler: TextScaler.linear(1.0),
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.all(20),
          child: Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('${p.xp} / $nextFloor XP'),
                  const SizedBox(height: 8),
                  LinearProgressIndicator(value: progress),
                  const SizedBox(height: 16),
                  StreakWeek(profile: p),
                ],
              ),
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20),
          child: Card(
            child: Column(
              children: [
                ListTile(
                  leading: const Icon(Icons.workspace_premium),
                  title: Text('Nivel ${p.level} — ${p.levelName}'),
                  subtitle: Text('${p.xp} XP acumulado'),
                ),
                ListTile(
                  leading: const Icon(Icons.local_fire_department),
                  title: Text(
                    'Racha: ${p.currentStreak} día${p.currentStreak == 1 ? '' : 's'}',
                  ),
                  subtitle: Text('Mejor racha: ${p.longestStreak} días'),
                ),
                ListTile(
                  leading: const Icon(Icons.timer_outlined),
                  title: Text('Tiempo estudiado: ${_timeLabel(p.timeStudiedSeconds)}'),
                  subtitle: Text('${p.sessionsCompleted} sesiones · ${p.answered} preguntas'),
                ),
                ListTile(
                  leading: const Icon(Icons.bolt),
                  title: Text('Maratón: ${p.marathonBest} seguidas'),
                  subtitle: Text(
                    p.answered == 0
                        ? 'Sin precisión aún'
                        : 'Precisión ${(p.right / p.answered * 100).round()}%',
                  ),
                ),
                ListTile(
                  leading: const Icon(Icons.backup_outlined),
                  title: Text(t('backupTitle')),
                  subtitle: const Text('Exportar / importar JSON'),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () {
                    FeedbackService.select(store.settings);
                    Navigator.push(
                      c,
                      MaterialPageRoute(builder: (_) => DataScreen(store: store)),
                    );
                  },
                ),
                ListTile(
                  leading: const Icon(Icons.emoji_events_outlined),
                  title: Text(
                    'Logros (${p.achievements.length}/${achievementsCatalog.length})',
                  ),
                  subtitle: const Text('Desbloquea medallas estudiando'),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () {
                    FeedbackService.select(store.settings);
                    Navigator.push(
                      c,
                      MaterialPageRoute(
                        builder: (_) => AchievementsScreen(store: store),
                      ),
                    );
                  },
                ),
                ListTile(
                  leading: const Icon(Icons.settings_outlined),
                  title: const Text('Configuración'),
                  subtitle: const Text('Tema, sonidos, recordatorios, idioma'),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () {
                    FeedbackService.select(store.settings);
                    Navigator.push(
                      c,
                      MaterialPageRoute(
                        builder: (_) => SettingsScreen(store: store),
                      ),
                    );
                  },
                ),
                const ListTile(
                  leading: Icon(Icons.privacy_tip_outlined),
                  title: Text('Datos locales'),
                  subtitle: Text('Tus datos permanecen en este dispositivo'),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class WeeklyChart extends StatelessWidget {
  const WeeklyChart({super.key, required this.profile});
  final Profile profile;
  @override
  Widget build(BuildContext c) {
    final now = DateTime.now();
    final monday = dateOnly(now).subtract(Duration(days: now.weekday - 1));
    const labels = ['L', 'M', 'X', 'J', 'V', 'S', 'D'];
    final values = List.generate(7, (k) {
      final day = monday.add(Duration(days: k));
      if (day.isAfter(dateOnly(now))) return 0;
      return profile.dailyAnswered[dateKey(day)] ?? 0;
    });
    final maxV = values.fold<int>(1, (a, b) => b > a ? b : a);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.end,
      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
      children: List.generate(7, (k) {
        final v = values[k];
        final h = 8.0 + (v / maxV) * 72.0;
        final isToday = dateOnly(monday.add(Duration(days: k))) == dateOnly(now);
        return Flexible(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.end,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                v > 0 ? '$v' : '',
                style: Theme.of(c).textTheme.labelSmall,
                maxLines: 1,
              ),
              const SizedBox(height: 4),
              Container(
                width: 26,
                height: h,
                decoration: BoxDecoration(
                  color: v > 0
                      ? Theme.of(c).colorScheme.primary
                      : Theme.of(c).colorScheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(8),
                  border: isToday
                      ? Border.all(color: Theme.of(c).colorScheme.primary, width: 2)
                      : null,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                labels[k],
                style: Theme.of(c).textTheme.labelSmall,
                maxLines: 1,
              ),
            ],
          ),
        );
      }),
    );
  }
}

class AchievementsScreen extends StatelessWidget {
  const AchievementsScreen({super.key, required this.store});
  final AppStore store;
  @override
  Widget build(BuildContext c) {
    final lang = store.settings.language;
    final unlocked = store.profile.achievements.toSet();
    return Scaffold(
      appBar: AppBar(title: Text(tr(lang, 'achievements'))),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: Text(
              '${unlocked.length}/${achievementsCatalog.length} ${tr(lang, 'unlocked')}',
              style: Theme.of(c).textTheme.titleMedium,
            ),
          ),
          ...achievementsCatalog.map((a) {
            final has = unlocked.contains(a.id);
            return Card(
              margin: const EdgeInsets.only(bottom: 10),
              child: ListTile(
                leading: Text(
                  a.icon,
                  style: TextStyle(
                    fontSize: 30,
                    color: has ? null : Colors.grey,
                  ),
                ),
                title: Text(a.title(lang)),
                subtitle: Text(a.desc(lang)),
                trailing: Icon(
                  has ? Icons.check_circle : Icons.lock_outline,
                  color: has ? Colors.green : Colors.grey,
                ),
              ),
            );
          }),
        ],
      ),
    );
  }
}

class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key, required this.store});
  final AppStore store;
  Future<void> _pickTime(BuildContext c) async {
    final s = store.settings;
    final picked = await showTimePicker(
      context: c,
      initialTime: TimeOfDay(hour: s.reminderHour, minute: s.reminderMinute),
    );
    if (picked != null) {
      s.reminderHour = picked.hour;
      s.reminderMinute = picked.minute;
      await store.saveSettings();
    }
  }

  @override
  Widget build(BuildContext c) {
    final s = store.settings;
    final lang = s.language;
    return Scaffold(
      appBar: AppBar(title: Text(tr(lang, 'settings'))),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Card(
            child: ListTile(
              leading: ProfileAvatar(store.profile.avatar, radius: 20),
              title: Text(store.profile.displayName),
              subtitle: Text(
                store.profile.metaLine(s.language).isEmpty
                    ? tr(lang, 'myProfile')
                    : '${tr(lang, 'myProfilePrefix')}${store.profile.metaLine(s.language)}',
              ),
              trailing: const Icon(Icons.chevron_right),
              onTap: () {
                FeedbackService.select(s);
                Navigator.push(
                  c,
                  MaterialPageRoute(
                    builder: (_) => ProfilePage(store: store),
                  ),
                );
              },
            ),
          ),
          _SectionTitle(tr(lang, 'study')),
          SwitchListTile(
            title: Text(tr(lang, 'sounds')),
            subtitle: Text(tr(lang, 'soundsSub')),
            value: s.soundsEnabled,
            onChanged: (v) async {
              s.soundsEnabled = v;
              await store.saveSettings();
              FeedbackService.select(s);
            },
          ),
          SwitchListTile(
            title: Text(tr(lang, 'vibration')),
            subtitle: Text(tr(lang, 'vibrationSub')),
            value: s.hapticsEnabled,
            onChanged: (v) async {
              s.hapticsEnabled = v;
              await store.saveSettings();
              FeedbackService.select(s);
            },
          ),
          SwitchListTile(
            title: Text(tr(lang, 'animations')),
            value: s.animationsEnabled,
            onChanged: (v) async {
              s.animationsEnabled = v;
              await store.saveSettings();
            },
          ),
          _SectionTitle(tr(lang, 'appearance')),
          ListTile(
            title: Text(tr(lang, 'theme')),
            trailing: DropdownButton<AppThemeMode>(
              value: s.themeMode,
              items: [
                DropdownMenuItem(
                  value: AppThemeMode.system,
                  child: Text(tr(lang, 'themeSystem')),
                ),
                DropdownMenuItem(
                  value: AppThemeMode.light,
                  child: Text(tr(lang, 'themeLight')),
                ),
                DropdownMenuItem(value: AppThemeMode.dark, child: Text(tr(lang, 'themeDark'))),
              ],
              onChanged: (v) async {
                if (v == null) return;
                s.themeMode = v;
                await store.saveSettings();
              },
            ),
          ),
          ListTile(
            title: Text(tr(s.language, 'language')),
            subtitle: Text(tr(s.language, 'languageSub')),
            trailing: DropdownButton<String>(
              value: supportedLanguages.contains(s.language) ? s.language : 'es',
              items: supportedLanguages.map((code) => DropdownMenuItem(value: code, child: Text(languageNames[code]!))).toList(),
              onChanged: (v) async {
                if (v == null) return;
                s.language = v;
                await store.saveSettings();
              },
            ),
          ),
          _SectionTitle(tr(lang, 'reminders')),
          SwitchListTile(
            title: Text(tr(lang, 'dailyReminder')),
            subtitle: Text(
              ReminderService.label(
                ReminderService.nextReminder(
                  enabled: s.remindersEnabled,
                  hour: s.reminderHour,
                  minute: s.reminderMinute,
                  now: DateTime.now(),
                ),
                s.language,
              ),
            ),
            value: s.remindersEnabled,
            onChanged: (v) async {
              s.remindersEnabled = v;
              await store.saveSettings();
            },
          ),
          if (s.remindersEnabled)
            ListTile(
              title: Text(tr(lang, 'time')),
              subtitle: Text(tr(lang, 'timeSub')),
              trailing: Text(
                '${s.reminderHour.toString().padLeft(2, '0')}:${s.reminderMinute.toString().padLeft(2, '0')}',
                style: const TextStyle(fontWeight: FontWeight.bold),
              ),
              onTap: () => _pickTime(c),
            ),
          _SectionTitle(tr(lang, 'data')),
          ListTile(
            leading: const Icon(Icons.backup_outlined),
            title: Text(tr(lang, 'backup')),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.push(
              c,
              MaterialPageRoute(builder: (_) => DataScreen(store: store)),
            ),
          ),
          _SectionTitle(tr(lang, 'about')),
          ListTile(
            title: Text(tr(lang, 'versionInfo')),
            subtitle: Text(tr(lang, 'versionSub')),
          ),
        ],
      ),
    );
  }
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle(this.text);
  final String text;
  @override
  Widget build(BuildContext c) => Padding(
    padding: const EdgeInsets.fromLTRB(4, 18, 4, 4),
    child: Text(
      text,
      style: Theme.of(
        c,
      ).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.bold),
    ),
  );
}

class ProfileEditScreen extends StatefulWidget {
  const ProfileEditScreen({super.key, required this.store});
  final AppStore store;
  @override
  State<ProfileEditScreen> createState() => _ProfileEditScreenState();
}

class _ProfileEditScreenState extends State<ProfileEditScreen> {
  final form = GlobalKey<FormState>();
  late final name = TextEditingController(text: widget.store.profile.name);
  late final age = TextEditingController(
    text: widget.store.profile.age?.toString() ?? '',
  );
  late String gender = Profile.profileGenders.contains(
    widget.store.profile.gender,
  )
      ? widget.store.profile.gender
      : 'unspecified';
  late String avatar = Profile.profileAvatars.contains(
    widget.store.profile.avatar,
  )
      ? widget.store.profile.avatar
      : Profile.profileAvatars.first;

  String _genderLabel(String g) {
    final lang = widget.store.settings.language;
    return genderMap[g]?[lang] ?? genderMap[g]?['en'] ?? g;
  }

  @override
  Widget build(BuildContext c) {
    final lang = widget.store.settings.language;
    return Scaffold(
      appBar: AppBar(title: Text(tr(lang, 'editProfile'))),
    body: Form(
      key: form,
      child: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          Center(
            child: ProfileAvatar(avatar, radius: 40),
          ),
          const SizedBox(height: 12),
          Text(tr(lang, 'avatar')),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: Profile.profileAvatars
                .map(
                  (e) => ChoiceChip(
                    label: Text(e, style: const TextStyle(fontSize: 22)),
                    selected: avatar == e,
                    onSelected: (_) => setState(() => avatar = e),
                  ),
                )
                .toList(),
          ),
          const SizedBox(height: 8),
          OutlinedButton.icon(
            onPressed: null,
            icon: const Icon(Icons.photo_outlined),
            label: Text(tr(lang, 'addPhotoSoon')),
          ),
          const SizedBox(height: 16),
          TextFormField(
            controller: name,
            decoration: InputDecoration(labelText: tr(lang, 'name')),
            validator: (x) => Profile.isValidProfileName(x ?? '')
                ? null
                : tr(lang, 'nameValidation'),
          ),
          const SizedBox(height: 14),
          TextFormField(
            controller: age,
            keyboardType: TextInputType.number,
            decoration: InputDecoration(
              labelText: tr(lang, 'age'),
              hintText: tr(lang, 'ageHint'),
            ),
            validator: (x) => Profile.isValidProfileAge(x ?? '')
                ? null
                : tr(lang, 'ageValidation'),
          ),
          const SizedBox(height: 14),
          DropdownButtonFormField<String>(
            initialValue: gender,
            decoration: InputDecoration(labelText: tr(lang, 'gender')),
            items: Profile.profileGenders
                .map((g) => DropdownMenuItem(value: g, child: Text(_genderLabel(g))))
                .toList(),
            onChanged: (v) => setState(() => gender = v ?? 'unspecified'),
          ),
          const SizedBox(height: 24),
          FilledButton(
            onPressed: () async {
              if (!form.currentState!.validate()) return;
              final p = widget.store.profile;
              p.name = name.text.trim();
              final at = age.text.trim();
              p.age = at.isEmpty ? null : int.tryParse(at);
              p.gender = gender;
              p.avatar = avatar;
              FeedbackService.select(widget.store.settings);
              await widget.store.save();
              if (!c.mounted) return;
              Navigator.pop(c);
              ScaffoldMessenger.of(
                c,
              ).showSnackBar(SnackBar(content: Text(tr(lang, 'profileUpdated'))));
            },
            child: Text(tr(lang, 'save')),
          ),
        ],
      ),
    ),
  );
  }
}
