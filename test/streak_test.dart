import 'package:flutter_test/flutter_test.dart';
import 'package:mrcards/main.dart';

void main() {
  test('primer día inicia racha en 1', () {
    final p = Profile();
    final isNew = p.registerStudyDay(DateTime(2026, 1, 5, 10));
    expect(isNew, isTrue);
    expect(p.currentStreak, 1);
    expect(p.longestStreak, 1);
  });

  test('día consecutivo suma racha', () {
    final p = Profile();
    p.registerStudyDay(DateTime(2026, 1, 5));
    p.registerStudyDay(DateTime(2026, 1, 6));
    expect(p.currentStreak, 2);
    expect(p.longestStreak, 2);
  });

  test('mismo día no suma doble', () {
    final p = Profile();
    p.registerStudyDay(DateTime(2026, 1, 5, 9));
    final again = p.registerStudyDay(DateTime(2026, 1, 5, 20));
    expect(again, isFalse);
    expect(p.currentStreak, 1);
  });

  test('salto de días reinicia racha pero conserva mejor', () {
    final p = Profile();
    p.registerStudyDay(DateTime(2026, 1, 5));
    p.registerStudyDay(DateTime(2026, 1, 6));
    p.registerStudyDay(DateTime(2026, 1, 10));
    expect(p.currentStreak, 1);
    expect(p.longestStreak, 2);
  });

  test('studiedOn detecta semana', () {
    final p = Profile();
    p.registerStudyDay(DateTime(2026, 1, 6));
    expect(p.studiedOn(DateTime(2026, 1, 6)), isTrue);
    expect(p.studiedOn(DateTime(2026, 1, 7)), isFalse);
  });
}
