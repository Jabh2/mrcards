import 'package:flutter_test/flutter_test.dart';
import 'package:mrcards/main.dart';

void main() {
  test('again reencola 1-2 preguntas después', () {
    for (var k = 0; k < 20; k++) {
      final idx = reinsertIndex(
        mode: StudyMode.review,
        rating: Rating.again,
        currentIndex: 2,
        queueLength: 10,
        retriesForQuestion: 0,
      );
      expect(idx, isNotNull);
      expect(idx! >= 4 && idx <= 5, isTrue, reason: 'idx=$idx');
    }
  });

  test('hard reencola 3-5 después', () {
    final idx = reinsertIndex(
      mode: StudyMode.review,
      rating: Rating.hard,
      currentIndex: 0,
      queueLength: 10,
      retriesForQuestion: 0,
    );
    expect(idx, isNotNull);
    expect(idx! >= 4 && idx <= 5, isTrue);
  });

  test('good/easy no reencolan', () {
    expect(
        reinsertIndex(
          mode: StudyMode.review,
          rating: Rating.good,
          currentIndex: 0,
          queueLength: 10,
          retriesForQuestion: 0,
        ),
        isNull);
    expect(
        reinsertIndex(
          mode: StudyMode.random,
          rating: Rating.easy,
          currentIndex: 0,
          queueLength: 10,
          retriesForQuestion: 0,
        ),
        isNull);
  });

  test('examen nunca reencola', () {
    expect(
        reinsertIndex(
          mode: StudyMode.exam,
          rating: Rating.again,
          currentIndex: 0,
          queueLength: 10,
          retriesForQuestion: 0,
        ),
        isNull);
  });

  test('tope 2 reintentos evita loop infinito', () {
    expect(
        reinsertIndex(
          mode: StudyMode.review,
          rating: Rating.again,
          currentIndex: 0,
          queueLength: 10,
          retriesForQuestion: 2,
        ),
        isNull);
  });

  test('niveles por XP SDD', () {
    expect(levelForXp(0), 1);
    expect(levelForXp(99), 1);
    expect(levelForXp(100), 2);
    expect(levelForXp(350), 3);
    expect(levelForXp(1600), 6);
  });
}
