import 'package:flutter_test/flutter_test.dart';
import 'package:mrcards/main.dart';

void main() {
  test('spaced repetition schedules an incorrect answer for tomorrow', () {
    final question = Question(
      id: 'q',
      deckId: 'd',
      type: QuestionType.flashcard,
      prompt: 'Q',
      answer: 'A',
    );
    SpacedRepetitionService().record(question, Rating.again);
    expect(question.interval, 1);
    expect(question.incorrect, 1);
  });

  test('easy answers improve their review interval', () {
    final question = Question(
      id: 'q',
      deckId: 'd',
      type: QuestionType.flashcard,
      prompt: 'Q',
      answer: 'A',
    );
    final service = SpacedRepetitionService();
    service.record(question, Rating.good);
    service.record(question, Rating.easy);
    expect(question.interval, greaterThanOrEqualTo(3));
    expect(question.correct, 2);
  });
}
