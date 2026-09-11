import 'package:flutter_test/flutter_test.dart';
import 'package:mrcards/main.dart';

void main() {
  test('AppStore cumple contratos repositorio', () async {
    final store = AppStore();
    expect(store, isA<DeckRepository>());
    expect(store, isA<QuestionRepository>());
    expect(store, isA<SessionRepository>());

    final deck = Deck(id: 'd1', title: 'T');
    // Usamos listas directas para no requerir SharedPreferences en test.
    store.decks.add(deck);
    store.questions.add(
      Question(id: 'q1', deckId: 'd1', type: QuestionType.flashcard, prompt: 'P', answer: 'A'),
    );
    expect(store.byDeck('d1').length, 1);
    expect(store.decks.length, 1);

    store.sessions.add(
      StudySession(
        id: 's1',
        mode: StudyMode.review,
        startedAt: DateTime(2026, 1, 1),
        finishedAt: DateTime(2026, 1, 1),
        questionsAnswered: 5,
        correctAnswers: 4,
        xpEarned: 60,
      ),
    );
    expect(store.sessions.first.accuracy, 80);
  });
}
