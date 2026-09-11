/// Borrador de pregunta detectada en un PDF + heurísticas de
/// segmentación y clasificación (puro Dart, sin IO: testeable).
///
/// El flujo completo vive en `pdf_import.dart`:
/// pick (file_picker) → extract (pdfrx) → [segmentBlocks] →
/// [classifyBlock] → revisión humana → [Question].
library;

/// Borrador editable antes de guardar en el mazo.
class PdfDraft {
  PdfDraft({
    required this.kind,
    required this.prompt,
    this.answer = '',
    this.options = const [],
    this.pairs = const [],
    this.confidence = 0.5,
  });

  /// Nombre de [QuestionType] (`flashcard`, `multipleChoice`, `trueFalse`,
  /// `written`, `fillBlank`, `ordering`, `matching`, `imageChoice`).
  String kind;
  String prompt;
  String answer;
  List<String> options;
  List<String> pairs;
  double confidence;

  bool get needsAnswer => answer.trim().isEmpty;
}

/// Parte el texto extraído en bloques (posibles preguntas).
///
/// Separa por líneas numeradas (`1.`, `1)`, `P1:`), viñetas o
/// párrafos separados por línea en blanco. Descarta encabezados
/// cortos típicos (título, nombre, fecha) de < 25 caracteres sin `?`
/// cuando van seguidos de más texto.
List<String> segmentBlocks(String text) {
  final lines = text
      .replaceAll('\r', '')
      .split('\n')
      .map((l) => l.trimRight())
      .toList();
  final blocks = <String>[];
  final current = <String>[];
  final startRe = RegExp(r'^\s*(?:\d{1,3}\s*[\.\)\:\-]|•|\-|\*)\s+\S');
  void flush() {
    final b = current.join('\n').trim();
    if (b.length >= 12) blocks.add(b);
    current.clear();
  }

  for (final line in lines) {
    final t = line.trim();
    if (t.isEmpty) {
      if (current.isNotEmpty) flush();
      continue;
    }
    if (startRe.hasMatch(t) && current.isNotEmpty) flush();
    current.add(t);
  }
  flush();
  return blocks;
}

// Solo letras (a-d): los pasos numerados (1. 2. 3.) pertenecen a la
// pregunta o al orden, no a opciones — evita falsos positivos.
final _optionLineRe =
    RegExp(r'^\s*(?:\(?([a-dA-D])\)?[\).\:\-]|\[([a-dA-D])\])\s+(.+)$');
final _answerLineRe = RegExp(
    r'^\s*(?:respuesta|answer|rpta|sol(?:ución|ucion)|clave)\s*[:\-]\s*(.+)$',
    caseSensitive: false);
final _trueFalseRe = RegExp(
    r'\(v\s*/\s*f\)|\bv\s+o\s+f\b|verdadero\s*(/|o)\s*falso|true\s*(/|or)\s*false|\(true\s*/\s*false\)',
    caseSensitive: false);
final _fillBlankRe = RegExp(
    r'_{2,}|\[ *…+ *\]|\[ *\.\.+ *\]|complet\w*\s+(la|el|las|siguientes)|rellen\w*\s+(los?\s+)?(huecos|espacios|blancos)|fill\s+in\s+the\s+blank|complete\s+the',
    caseSensitive: false);
final _orderingRe = RegExp(
    r'\borderden\w*\b|\bsecuenci\w*\b|\border\s+the\b|\bsequence\b|\b-steps\b|\bpasos\b.*\borderden',
    caseSensitive: false);
final _matchingRe = RegExp(
    r'\brelacion\w*\b|\bemparej\w*\b|\bmatch\b|\bune\s+con\b',
    caseSensitive: false);

/// Extrae `Respuesta: X` del final del bloque (y la quita del texto).
/// Si X es una letra de opción, la resuelve al texto de la opción.
String _extractAnswer(StringBuffer body, List<String> options) {
  var answer = '';
  final text = body.toString();
  final m = _answerLineRe.firstMatch(text.split('\n').last.trim());
  if (m != null) {
    answer = m.group(1)!.trim();
    final lines = text.split('\n')..removeLast();
    body
      ..clear()
      ..write(lines.join('\n').trim());
    final letter = RegExp(r'^\(?([a-dA-D])\)?\.?$').firstMatch(answer);
    if (letter != null && options.isNotEmpty) {
      final idx = letter.group(1)!.toLowerCase().codeUnitAt(0) - 97;
      if (idx >= 0 && idx < options.length) answer = options[idx];
    }
  }
  return answer;
}

/// Clasifica un bloque de texto en un [PdfDraft].
PdfDraft classifyBlock(String block) {
  final body = StringBuffer(block.trim());
  final lines =
      block.split('\n').map((l) => l.trim()).where((l) => l.isNotEmpty).toList();

  // Opciones tipo a) b) c) / (A) / 1.
  final options = <String>[];
  final rest = <String>[];
  for (final l in lines) {
    final m = _optionLineRe.firstMatch(l);
    if (m != null) {
      options.add((m.group(3) ?? m.group(2) ?? '').trim());
    } else {
      rest.add(l);
    }
  }
  final answer = _extractAnswer(body, options);
  final prompt = body.toString().trim();
  final low = block.toLowerCase();

  // 1. Verdadero/Falso.
  if (_trueFalseRe.hasMatch(block)) {
    return PdfDraft(
        kind: 'trueFalse', prompt: prompt, answer: answer, confidence: 0.85);
  }
  // 2. Opción múltiple.
  if (options.length >= 2) {
    return PdfDraft(
        kind: 'multipleChoice',
        prompt: rest.join(' ').trim().isEmpty ? prompt : rest.join(' ').trim(),
        answer: answer,
        options: options,
        confidence: answer.isEmpty ? 0.7 : 0.9);
  }
  // 3. Completar / rellenar huecos.
  if (_fillBlankRe.hasMatch(block)) {
    return PdfDraft(
        kind: 'fillBlank', prompt: prompt, answer: answer, confidence: 0.75);
  }
  // 4. Ordenar.
  if (_orderingRe.hasMatch(low)) {
    final steps = lines
        .where((l) => RegExp(r'^\s*\d+\s*[\.\)\:\-]').hasMatch(l))
        .map((l) => l.replaceFirst(
            RegExp(r'^\s*\d+\s*[\.\)\:\-]\s*'), ''))
        .where((l) => l.trim().isNotEmpty)
        .toList();
    return PdfDraft(
        kind: 'ordering',
        prompt: prompt,
        answer: steps.isNotEmpty ? steps.join(',') : answer,
        options: steps,
        confidence: 0.65);
  }
  // 5. Relacionar / emparejar.
  if (_matchingRe.hasMatch(low)) {
    final pairs = <String>[];
    for (final l in lines) {
      final pm = RegExp(r'^(.+?)\s*(?:→|->|\||\:|\-)\s*(.+)$').firstMatch(l);
      if (pm != null &&
          pm.group(1)!.trim().isNotEmpty &&
          pm.group(2)!.trim().isNotEmpty &&
          !_answerLineRe.hasMatch(l)) {
        pairs.add('${pm.group(1)!.trim()}|${pm.group(2)!.trim()}');
      }
    }
    if (pairs.length >= 2) {
      return PdfDraft(
          kind: 'matching',
          prompt: prompt,
          answer: answer,
          pairs: pairs,
          confidence: 0.7);
    }
  }
  // 6. Flashcard por defecto.
  return PdfDraft(
      kind: 'flashcard', prompt: prompt, answer: answer, confidence: 0.5);
}

/// Convierte el texto completo de un PDF en borradores clasificados.
List<PdfDraft> draftsFromText(String text) =>
    segmentBlocks(text).map(classifyBlock).toList();
