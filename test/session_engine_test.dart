import 'package:flutter_test/flutter_test.dart';
import 'package:mrcards/main.dart';

Question _q(String id, {int correct = 0, int incorrect = 0, DateTime? next}) {
  return Question(
    id: id,
    deckId: 'd',
    type: QuestionType.flashcard,
    prompt: 'Q $id',
    answer: 'A',
    correct: correct,
    incorrect: incorrect,
    next: next,
  );
}

void main() {
  test('review prioriza vencidas > difíciles > nuevas', () {
    final now = DateTime(2026, 1, 10);
    final due = _q('due', next: now.subtract(const Duration(days: 1)));
    final hard = _q('hard',
        correct: 1, incorrect: 5, next: now.add(const Duration(days: 5)));
    final fresh = _q('new', next: now.add(const Duration(days: 5)));
    final engine = StudySessionEngine();
    final queue = engine.buildQueue(
      all: [fresh, hard, due],
      mode: StudyMode.review,
      now: now,
    );
    expect(queue.first.id, 'due');
    expect(queue[1].id, 'hard');
  });

  test('random respeta tipos y favoritas y límite', () {
    final qs = [
      Question(
          id: '1',
          deckId: 'd',
          type: QuestionType.flashcard,
          prompt: 'a',
          answer: 'b',
          isFavorite: true),
      Question(
          id: '2', deckId: 'd', type: QuestionType.written, prompt: 'c', answer: 'd'),
    ];
    final engine = StudySessionEngine();
    final onlyFav = engine.buildQueue(
      all: qs,
      mode: StudyMode.random,
      onlyFavorites: true,
    );
    expect(onlyFav.length, 1);
    expect(onlyFav.first.id, '1');

    final onlyWritten = engine.buildQueue(
      all: qs,
      mode: StudyMode.random,
      types: {QuestionType.written},
    );
    expect(onlyWritten.length, 1);
    expect(onlyWritten.first.id, '2');

    final limited = engine.buildQueue(
      all: qs,
      mode: StudyMode.random,
      limit: 1,
    );
    expect(limited.length, 1);
  });

  test('bulkAdd crea desde líneas con |', () {
    final store = AppStore();
    final out = store.bulkAdd('d', '¿Qué es ADN? | Material genético\nMala línea\nQ2 | A2');
    expect(out.length, 2);
    expect(out.first.prompt, '¿Qué es ADN?');
    expect(out.first.answer, 'Material genético');
  });

  test('marathon y examen no reencolan', () {
    expect(
        reinsertIndex(
          mode: StudyMode.marathon,
          rating: Rating.again,
          currentIndex: 0,
          queueLength: 10,
          retriesForQuestion: 0,
        ),
        isNull);
    expect(
        reinsertIndex(
          mode: StudyMode.exam,
          rating: Rating.hard,
          currentIndex: 0,
          queueLength: 10,
          retriesForQuestion: 0,
        ),
        isNull);
  });
}
