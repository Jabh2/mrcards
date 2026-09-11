import 'package:flutter_test/flutter_test.dart';
import 'package:mrcards/main.dart';

void main() {
  test('normaliza mayúsculas, espacios y acentos', () {
    expect(checkWrittenAnswer('tokio', 'Tokio', []), isTrue);
    expect(checkWrittenAnswer('  TOKIO  ', 'tokio', []), isTrue);
    expect(checkWrittenAnswer('Mexico', 'México', []), isTrue);
    expect(checkWrittenAnswer('  ciudad   de mexico ', 'Ciudad de México', []),
        isTrue);
  });

  test('ignora signos de puntuación y espacios', () {
    expect(checkWrittenAnswer('París.', 'París', []), isTrue);
    expect(checkWrittenAnswer('hola,  mundo', 'Hola Mundo', []), isTrue);
    expect(checkWrittenAnswer('¿Qué es?', 'que es', []), isTrue);
    expect(checkWrittenAnswer('"cita textual"', 'cita textual', []), isTrue);
    expect(checkWrittenAnswer('(entre paréntesis)', 'entre paréntesis', []),
        isTrue);
    expect(checkWrittenAnswer('bien-estar', 'bien estar', []), isTrue);
  });

  test('ñ y caracteres especiales', () {
    expect(checkWrittenAnswer('nino', 'niño', []), isTrue);
    expect(checkWrittenAnswer('ano', 'año', []), isTrue);
    expect(checkWrittenAnswer('canon', 'cañón', []), isTrue);
  });

  test('tolera 1-2 letras erradas según largo', () {
    // Transposición, inserción y borrado (5-9 letras: 1 error).
    expect(checkWrittenAnswer('parsi', 'París', []), isTrue);
    expect(checkWrittenAnswer('pariss', 'París', []), isTrue);
    expect(checkWrittenAnswer('pari', 'París', []), isTrue);
    expect(checkWrittenAnswer('fotosintesi', 'fotosíntesis', []), isTrue);
    // Largas (≥10): hasta 2 errores.
    expect(checkWrittenAnswer('electromagnetizmo', 'electromagnetismo', []),
        isTrue);
    // Respuestas distintas siguen siendo incorrectas.
    expect(checkWrittenAnswer('Madrid', 'París', []), isFalse);
    expect(
        checkWrittenAnswer(
            'revolución francesa', 'revolución industrial', []),
        isFalse);
  });

  test('palabras cortas exigen coincidencia exacta', () {
    expect(checkWrittenAnswer('sal', 'sol', []), isFalse);
    expect(checkWrittenAnswer('sol', 'sol.', []), isTrue);
    expect(checkWrittenAnswer('rosa', 'risa', []), isFalse);
  });

  test('acepta respuestas alternativas', () {
    expect(checkWrittenAnswer('CDMX', 'Ciudad de México', ['CDMX']), isTrue);
    expect(
        checkWrittenAnswer('Mexico City', 'Ciudad de México',
            ['CDMX', 'Mexico City']),
        isTrue);
    expect(checkWrittenAnswer('Madrid', 'París', []), isFalse);
  });
}
