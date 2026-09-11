import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mrcards/main.dart';
import 'package:mrcards/services/pdf_parse.dart';

void main() {
  group('segmentBlocks', () {
    test('separa por numeración', () {
      const t = '1. ¿Capital de Francia?\nRespuesta: París\n\n2. ¿2+2?\nRespuesta: 4';
      final b = segmentBlocks(t);
      expect(b.length, 2);
      expect(b.first, contains('Francia'));
    });
    test('descarta ruido corto', () {
      expect(segmentBlocks('Hola'), isEmpty);
    });
  });

  group('classifyBlock', () {
    test('verdadero/falso', () {
      final d = classifyBlock('3. El agua hierve a 100°C (V/F)');
      expect(d.kind, 'trueFalse');
    });
    test('opción múltiple con respuesta por letra', () {
      final d = classifyBlock(
          '2. ¿Capital de Perú?\na) Lima\nb) Quito\nc) Bogotá\nRespuesta: a');
      expect(d.kind, 'multipleChoice');
      expect(d.options, ['Lima', 'Quito', 'Bogotá']);
      expect(d.answer, 'Lima');
    });
    test('opción múltiple sin respuesta', () {
      final d = classifyBlock(
          '¿Color del cielo?\na) Verde\nb) Azul\nc) Rojo');
      expect(d.kind, 'multipleChoice');
      expect(d.needsAnswer, isTrue);
    });
    test('completar huecos', () {
      final d = classifyBlock(
          'Completa: la fotosíntesis ocurre en los ___.');
      expect(d.kind, 'fillBlank');
    });
    test('relacionar', () {
      final d = classifyBlock(
          'Relaciona cada país con su capital:\nFrancia → París\nItalia → Roma');
      expect(d.kind, 'matching');
      expect(d.pairs.length, 2);
    });
    test('flashcard por defecto', () {
      final d = classifyBlock('Define mitosis y sus fases.');
      expect(d.kind, 'flashcard');
      expect(d.needsAnswer, isTrue);
    });
  });

  group('PdfImportReviewScreen', () {
    testWidgets('bloquea sin respuestas y guarda al completar',
        (t) async {
      final drafts = [
        PdfDraft(
            kind: 'trueFalse',
            prompt: 'El agua hierve a 100°C',
            answer: 'Verdadero',
            confidence: 0.85),
        PdfDraft(kind: 'flashcard', prompt: 'Define ósmosis'),
      ];
      List<Question>? result;
      await t.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (c) => FilledButton(
              onPressed: () async {
                result = await Navigator.push<List<Question>>(
                  c,
                  MaterialPageRoute(
                    builder: (_) => PdfImportReviewScreen(
                        deckId: 'd1', drafts: drafts),
                  ),
                );
              },
              child: const Text('open'),
            ),
          ),
        ),
      );
      await t.tap(find.text('open'));
      await t.pumpAndSettle();
      expect(find.text('Revisar PDF (2)'), findsOneWidget);
      // Sin respuesta en la 2ª: guardar bloqueado.
      await t.scrollUntilVisible(find.text('Guardar 2 en el cuestionario'),
          300,
          scrollable: find.byType(Scrollable).first);
      await t.tap(find.text('Guardar 2 en el cuestionario'));
      await t.pumpAndSettle();
      expect(result, isNull);
      expect(find.text('Falta la respuesta'), findsOneWidget);
      // Dejar que expire el SnackBar para que no tape el botón.
      await t.pump(const Duration(seconds: 5));
      await t.pumpAndSettle();
      // Completar respuesta (4º TextField: respuesta de la 2ª tarjeta).
      await t.enterText(find.byType(TextField).at(3), 'Difusión simple');
      await t.pump();
      await t.tap(find.text('Guardar 2 en el cuestionario'));
      await t.pumpAndSettle();
      expect(result?.length, 2);
      expect(result!.first.type, QuestionType.trueFalse);
      expect(result!.last.answer, 'Difusión simple');
    });
  });

  group('draftsFromText', () {
    test('texto mixto produce varios borradores', () {
      const t = '1. El sol es una estrella (V/F)\n\n2. ¿Símbolo del oro?\na) Au\nb) Ag\nRespuesta: a';
      final ds = draftsFromText(t);
      expect(ds.length, 2);
      expect(ds.map((d) => d.kind), ['trueFalse', 'multipleChoice']);
    });
  });
}
