import 'package:flutter_test/flutter_test.dart';
import 'package:mrcards/main.dart';

AppStore _storeWith({int answered = 0, int right = 0, int sessions = 0, int streak = 0, int fixed = 0, int decks = 0}) {
  final s = AppStore();
  s.profile
    ..answered = answered
    ..right = right
    ..sessionsCompleted = sessions
    ..longestStreak = streak
    ..difficultFixed = fixed;
  for (var k = 0; k < decks; k++) {
    s.decks.add(Deck(id: 'd$k', title: 'D$k'));
  }
  return s;
}

void main() {
  test('first_session y brain_100 y precise', () {
    final s = _storeWith(answered: 100, right: 95, sessions: 1);
    final newly = checkAchievements(s);
    expect(newly, contains('first_session'));
    expect(newly, contains('brain_100'));
    expect(newly, contains('precise_90'));
    // Segunda vez no repite
    expect(checkAchievements(s), isEmpty);
  });

  test('week_streak y collector y persistent', () {
    final s = _storeWith(streak: 7, decks: 10, fixed: 50);
    final newly = checkAchievements(s);
    expect(newly, contains('week_streak'));
    expect(newly, contains('collector_10'));
    expect(newly, contains('persistent_50'));
  });

  test('settings json roundtrip', () {
    final s = AppSettings(
      themeMode: AppThemeMode.dark,
      soundsEnabled: false,
      language: 'en',
      reminderHour: 8,
    );
    final back = AppSettings.from(s.json());
    expect(back.themeMode, AppThemeMode.dark);
    expect(back.soundsEnabled, isFalse);
    expect(back.language, 'en');
    expect(back.reminderHour, 8);
  });

  test('recordAnswer actualiza dailyAnswered', () {
    final p = Profile();
    p.recordAnswer(correct: true, now: DateTime(2026, 1, 6, 10));
    p.recordAnswer(correct: false, now: DateTime(2026, 1, 6, 12));
    expect(p.answered, 2);
    expect(p.right, 1);
    expect(p.dailyAnswered['2026-01-06'], 2);
  });
}
