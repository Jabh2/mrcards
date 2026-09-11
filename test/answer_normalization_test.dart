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

  test('acepta respuestas alternativas', () {
    expect(checkWrittenAnswer('CDMX', 'Ciudad de México', ['CDMX']), isTrue);
    expect(
        checkWrittenAnswer('Mexico City', 'Ciudad de México',
            ['CDMX', 'Mexico City']),
        isTrue);
    expect(checkWrittenAnswer('Madrid', 'París', []), isFalse);
  });
}
