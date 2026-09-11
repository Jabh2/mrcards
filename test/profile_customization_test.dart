import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:mrcards/main.dart';

void main() {
  test('validación nombre 2-30', () {
    expect(Profile.isValidProfileName(''), isFalse);
    expect(Profile.isValidProfileName('A'), isFalse);
    expect(Profile.isValidProfileName('Ana'), isTrue);
    expect(Profile.isValidProfileName('  Luis  '), isTrue);
    expect(Profile.isValidProfileName(List.filled(31, 'a').join()), isFalse);
  });

  test('edad opcional 5-120', () {
    expect(Profile.isValidProfileAge(''), isTrue);
    expect(Profile.isValidProfileAge('16'), isTrue);
    expect(Profile.isValidProfileAge('4'), isFalse);
    expect(Profile.isValidProfileAge('abc'), isFalse);
    expect(Profile.isValidProfileAge('200'), isFalse);
  });

  test('roundtrip JSON conserva perfil', () {
    final p = Profile(name: 'Ana', age: 16, gender: 'female', avatar: '🦊');
    final back = Profile.from(p.json());
    expect(back.name, 'Ana');
    expect(back.age, 16);
    expect(back.gender, 'female');
    expect(back.avatar, '🦊');
    expect(back.displayName, 'Ana');
    expect(back.metaLine('es'), contains('16'));
  });

  test('migración defaults para datos viejos', () {
    final back = Profile.from({'xp': 10});
    expect(back.name, 'Estudiante');
    expect(back.age, isNull);
    expect(back.gender, 'unspecified');
    expect(back.avatar, '🧑‍🎓');
  });

  testWidgets('Editar perfil guarda nombre y avatar', (t) async {
    SharedPreferences.setMockInitialValues({});
    final store = AppStore();
    await store.load();
    await t.pumpWidget(MaterialApp(home: ProfileEditScreen(store: store)));
    await t.pumpAndSettle();
    await t.enterText(find.widgetWithText(TextFormField, 'Nombre'), 'Ana');
    await t.enterText(find.widgetWithText(TextFormField, 'Edad (opcional)'), '16');
    await t.tap(find.text('🦊'));
    await t.pump();
    await t.ensureVisible(find.text('Guardar'));
    await t.pumpAndSettle();
    await t.tap(find.text('Guardar'));
    await t.pumpAndSettle();
    expect(store.profile.name, 'Ana');
    expect(store.profile.age, 16);
    expect(store.profile.avatar, '🦊');
  });

  testWidgets('ProfilePage muestra avatar, nombre y accesos editar',
      (t) async {
    SharedPreferences.setMockInitialValues({});
    final store = AppStore();
    await store.load();
    store.profile
      ..name = 'Ana'
      ..avatar = '🦊';
    await t.pumpWidget(MaterialApp(home: ProfilePage(store: store)));
    await t.pumpAndSettle();
    expect(find.text('Ana'), findsWidgets);
    expect(find.text('🦊'), findsOneWidget);
    // Botón texto + icono lápiz en la barra
    expect(find.text('Editar perfil'), findsWidgets);
    expect(find.byTooltip('Editar perfil'), findsOneWidget);
    // Tap en icono abre edición
    await t.tap(find.byTooltip('Editar perfil'));
    await t.pumpAndSettle();
    expect(find.text('Editar perfil').last, findsOneWidget);
    expect(find.widgetWithText(TextFormField, 'Nombre'), findsOneWidget);
  });

  testWidgets('ProfilePage no desborda en pantalla angosta + fuente grande',
      (t) async {
    SharedPreferences.setMockInitialValues({});
    final store = AppStore();
    await store.load();
    store.profile
      ..name = 'Alejandra Con Nombre Muy Largo Para Probar'
      ..age = 16
      ..gender = 'female'
      ..avatar = '🧑‍🎓';
    // Simula móvil angosto con fuente al 300% (caso extremo tipo Android 16)
    t.view.physicalSize = const Size(640, 1280);
    t.view.devicePixelRatio = 2.0;
    addTearDown(t.view.reset);
    await t.pumpWidget(
      MediaQuery(
        data: const MediaQueryData(textScaler: TextScaler.linear(3.0)),
        child: MaterialApp(home: ProfilePage(store: store)),
      ),
    );
    await t.pumpAndSettle();
    expect(find.textContaining('Alejandra'), findsWidgets);
    // El botón puede quedar bajo el fold con fuente 2x: scroll hasta verlo
    await t.scrollUntilVisible(find.text('Editar perfil'), 200);
    await t.pumpAndSettle();
    expect(find.text('Editar perfil'), findsWidgets);
    expect(t.takeException(), isNull);
  });
}
