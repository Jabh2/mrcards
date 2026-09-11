import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:mrcards/main.dart';

Future<AppStore> _freshStore() async {
  SharedPreferences.setMockInitialValues({});
  final s = AppStore();
  await s.load();
  expect(s.onboardingSeen, isFalse);
  return s;
}

void main() {
  testWidgets('Onboarding guiado crea usuario y deck de ejemplos', (t) async {
    final store = await _freshStore();
    await t.pumpWidget(MaterialApp(home: OnboardingScreen(store: store)));
    await t.pumpAndSettle();

    // Paso 1 -> 2 -> 3 (perfil)
    await t.tap(find.text('Siguiente'));
    await t.pumpAndSettle();
    await t.tap(find.text('Siguiente'));
    await t.pumpAndSettle();
    expect(find.text('Crea tu usuario'), findsOneWidget);

    // Sin nombre no avanza
    await t.tap(find.text('Guardar y continuar'));
    await t.pump();
    expect(find.text('Nombre de 2 a 30 caracteres'), findsOneWidget);
    expect(store.profile.name, 'Estudiante');

    // Completa perfil
    await t.enterText(find.widgetWithText(TextFormField, 'Nombre *'), 'Ana');
    await t.tap(find.text('🦊'));
    await t.pump();
    await t.tap(find.text('Guardar y continuar'));
    await t.pumpAndSettle();
    expect(store.profile.name, 'Ana');
    expect(store.profile.avatar, '🦊');
    expect(find.text('Tu primer cuestionario'), findsOneWidget);

    // Elige ejemplos y continúa
    await t.tap(find.text('Crear con ejemplos'));
    await t.pump();
    await t.tap(find.text('Continuar'));
    await t.pumpAndSettle();
    expect(find.textContaining('¡Listo, Ana!'), findsOneWidget);

    // Finaliza
    await t.tap(find.text('Empezar a estudiar'));
    await t.pumpAndSettle();
    expect(store.onboardingSeen, isTrue);
    expect(store.decks.length, 4);
    expect(store.decks.map((d) => d.title), containsAll(['Matemáticas', 'Ciencias', 'Historia', 'Técnicas']));
    expect(store.questions.length, 13);
  });

  testWidgets('Omitir deja usuario default', (t) async {
    final store = await _freshStore();
    await t.pumpWidget(MaterialApp(home: OnboardingScreen(store: store)));
    await t.pumpAndSettle();
    await t.tap(find.text('Omitir'));
    await t.pumpAndSettle();
    expect(store.onboardingSeen, isTrue);
    expect(store.profile.name, 'Estudiante');
  });
}
