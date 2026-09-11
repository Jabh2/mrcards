import 'package:flutter_test/flutter_test.dart';
import 'package:mrcards/main.dart';

void main() {
  test('StudySession accuracy e incorrect', () {
    final s = StudySession(
      id: '1',
      mode: StudyMode.exam,
      startedAt: DateTime(2026, 1, 1, 10),
      finishedAt: DateTime(2026, 1, 1, 10, 15),
      questionsAnswered: 20,
      correctAnswers: 17,
      xpEarned: 150,
    );
    expect(s.incorrectAnswers, 3);
    expect(s.accuracy, 85);
    final back = StudySession.from(s.json());
    expect(back.accuracy, 85);
    expect(back.mode, StudyMode.exam);
  });

  test('CsvCodec simple prompt,answer', () {
    final out = CsvCodec.decode('d1', '"¿Capital?","París"\nMadrid, España');
    expect(out.length, 2);
    expect(out.first.prompt, '¿Capital?');
    expect(out.first.answer, 'París');
  });

  test('CsvCodec con cabecera completa', () {
    final raw =
        'deckId,type,prompt,answer,options,accepted\n'
        'd1,multipleChoice,"¿2+2?","4","3|4|5","4"';
    final out = CsvCodec.decode('fallback', raw);
    expect(out.length, 1);
    expect(out.first.type, QuestionType.multipleChoice);
    expect(out.first.options, ['3', '4', '5']);
  });

  test('ReminderService calcula próximo', () {
    final now = DateTime(2026, 1, 5, 19, 0);
    final next = ReminderService.nextReminder(
      enabled: true,
      hour: 20,
      minute: 0,
      now: now,
    );
    expect(next, DateTime(2026, 1, 5, 20, 0));
    final tomorrow = ReminderService.nextReminder(
      enabled: true,
      hour: 8,
      minute: 0,
      now: now,
    );
    expect(tomorrow, DateTime(2026, 1, 6, 8, 0));
    expect(
      ReminderService.nextReminder(
        enabled: false,
        hour: 8,
        minute: 0,
        now: now,
      ),
      isNull,
    );
  });

  test('AppStore importCsv agrega y crea deck fallback', () {
    final store = AppStore();
    final n = store.importCsv('nuevo-deck', 'Q1,A1\nQ2,A2');
    expect(n, 2);
    expect(store.questions.length, 2);
    expect(store.decks.any((d) => d.id == 'nuevo-deck'), isTrue);
  });
}
