import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:mrcards/main.dart';

Future<AppStore> _emptyStore() async {
  SharedPreferences.setMockInitialValues({});
  final s = AppStore();
  await s.load();
  s.onboardingSeen = true;
  return s;
}

void main() {
  testWidgets('Home vacío muestra saludo y CTA crear', (t) async {
    final store = await _emptyStore();
    await t.pumpWidget(FlashCards(store: store));
    await t.pumpAndSettle();
    expect(find.text('Hola, Estudiante 👋'), findsOneWidget);
    expect(find.text('Comenzar repaso'), findsOneWidget);
    expect(find.text('¡Listo para aprender hoy?'), findsOneWidget);
    // Bottom nav de 4: sin Perfil abajo
    expect(find.text('Inicio'), findsOneWidget);
    expect(find.text('Estadísticas'), findsOneWidget);
    expect(find.text('Perfil'), findsNothing);
    // Avatar arriba abre Perfil
    expect(find.byTooltip('Mi perfil'), findsOneWidget);
    await t.tap(find.byTooltip('Mi perfil'));
    await t.pumpAndSettle();
    expect(find.text('Editar perfil'), findsWidgets);
  });

  testWidgets('DeckForm exige nombre', (t) async {
    await t.pumpWidget(const MaterialApp(home: DeckForm()));
    await t.pumpAndSettle();
    await t.tap(find.text('Guardar'));
    await t.pump();
    expect(find.text('Escribe un nombre'), findsOneWidget);
  });

  testWidgets('Flashcard: mostrar respuesta y calificar lleva a resumen',
      (t) async {
    final store = await _emptyStore();
    final deck = Deck(id: 'd1', title: 'Bio');
    store.decks.add(deck);
    store.questions.add(
      Question(
        id: 'q1',
        deckId: 'd1',
        type: QuestionType.flashcard,
        prompt: '¿Qué es ADN?',
        answer: 'Material genético',
      ),
    );
    await t.pumpWidget(
      MaterialApp(
        home: StudyScreen(store: store, mode: StudyMode.review, questions: List.of(store.questions)),
      ),
    );
    await t.pumpAndSettle();
    expect(find.text('¿Qué es ADN?'), findsOneWidget);
    await t.tap(find.text('Ver respuesta'));
    await t.pumpAndSettle();
    expect(find.text('Material genético'), findsOneWidget);
    await t.tap(find.text('🙂 Bien'));
    await t.pumpAndSettle();
    expect(find.text('¡Sesión completada!'), findsOneWidget);
    expect(find.textContaining('1 / 1'), findsOneWidget);
  });

  testWidgets('Home avatar no desborda con fuente grande', (t) async {
    final store = await _emptyStore();
    store.profile
      ..name = 'Alejandra Con Nombre Muy Largo Para Probar Ellipsis'
      ..avatar = '🧑‍🎓';
    await t.pumpWidget(
      MediaQuery(
        data: const MediaQueryData(textScaler: TextScaler.linear(2.0)),
        child: FlashCards(store: store),
      ),
    );
    await t.pumpAndSettle();
    expect(find.byType(ProfileAvatar), findsWidgets);
    expect(t.takeException(), isNull);
  });

  testWidgets('Stats muestra precisión y weekly', (t) async {
    final store = await _emptyStore();
    store.profile.recordAnswer(correct: true, now: DateTime.now());
    await t.pumpWidget(MaterialApp(home: Stats(store: store)));
    await t.pumpAndSettle();
    expect(find.text('Estadísticas'), findsOneWidget);
    expect(find.text('Esta semana'), findsOneWidget);
  });
}
