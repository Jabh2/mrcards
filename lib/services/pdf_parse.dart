/// Borrador de pregunta detectada en un PDF + heurísticas de
/// segmentación, filtrado de ruido y clasificación (puro Dart: testeable).
///
/// El flujo completo vive en `pdf_import.dart`:
/// pick (file_picker) → extract (pdfrx) → [draftsFromText] →
/// revisión humana → [Question].
///
/// Decisiones:
/// - El ruido claro (nº de página, encabezados, instrucciones sin
///   pregunta, pies, solucionario como bloque) se descarta y se cuenta
///   en [PdfImportResult.ignored].
/// - Lo dudoso entra como flashcard de baja confianza para revisión.
/// - La sección solucionario/clave se parsea y resuelve respuestas
///   por número de pregunta.
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

/// Bloque segmentado con su número de pregunta (si lo tenía).
class PdfBlock {
  PdfBlock(this.number, this.text);
  final int? number;
  final String text;
}

/// Resultado de importar: borradores + nº de bloques de ruido ignorados.
class PdfImportResult {
  PdfImportResult(this.drafts, this.ignored);
  final List<PdfDraft> drafts;
  final int ignored;
}

/// Parte el texto extraído en bloques conservando el nº de pregunta.
///
/// Separa por líneas numeradas (`1.`, `1)`, `P3:`), viñetas o párrafos
/// separados por línea en blanco.
List<PdfBlock> segmentBlocks(String text) {
  final lines =
      text.replaceAll('\r', '').split('\n').map((l) => l.trimRight()).toList();
  final blocks = <PdfBlock>[];
  final current = <String>[];
  int? currentNumber;
  final startRe =
      RegExp(r'^\s*(?:P\s?)?(\d{1,3})\s*[\.\)\:\-]\s+\S');
  final bulletRe = RegExp(r'^\s*(?:•|\-|\*)\s+\S');
  void flush() {
    final b = current.join('\n').trim();
    if (b.length >= 12) blocks.add(PdfBlock(currentNumber, b));
    current.clear();
    currentNumber = null;
  }

  for (final line in lines) {
    final t = line.trim();
    if (t.isEmpty) {
      if (current.isNotEmpty) flush();
      continue;
    }
    final m = startRe.firstMatch(t);
    if (m != null && current.isNotEmpty) flush();
    if (m != null && current.isEmpty) {
      currentNumber = int.tryParse(m.group(1)!);
    }
    if (bulletRe.hasMatch(t) && current.isNotEmpty) flush();
    current.add(t);
  }
  flush();
  return blocks;
}

/// Ruido estructural: nº de página, pies, encabezados administrativos.
final _pageNumberRe = RegExp(
    r'^\s*(?:p(?:á|a)g(?:ina)?\.?\s*)?\d{1,4}\s*(?:\/\s*\d{1,4}|de\s+\d{1,4})?\s*$',
    caseSensitive: false);
final _headerLabelRe = RegExp(
    r'^\s*(nombre|apellidos?|fecha|carrera|curso|asignatura|materia|grupo|aula|turno|semestre|ciclo|docente|profesor(a)?|estudiante|firma|dni|universidad|facultad|colegio|examen|parcial|evaluaci[oó]n|cuestionario|tema|duraci[oó]n|tiempo|puntaje|nota)\s*:[^?¿]{0,40}$',
    caseSensitive: false);

/// Instrucciones sin contenido preguntable (puro texto administrativo).
final _instructionRe = RegExp(
    r'instrucciones|indicaciones|lea\s+(cuidadosamente|atentamente)|responda\s+con|marque\s+la\s+hoja|seleccione\s+una\s+sola|tiempo\s+l[ií]mite|buena\s+suerte|[eé]xitos?|valor\s+\d+\s+puntos?|puntaje\s+total|total\s+de\s+puntos|no\s+se\s+aceptan|prohibido\s+el\s+uso',
    caseSensitive: false);

/// Verbos imperativos que introducen una pregunta de desarrollo.
final _imperativeRe = RegExp(
    r'\b(explique|explique|defina|define|describa|describe|mencione|mention|indique|indicate|desarrolle|develop|analice|analyze|compare|enumere|list|cite|determine|determine|justifique|justify|fundamente|exponga|señale|clasifique|identify)\b',
    caseSensitive: false);

/// ¿Es ruido claro? (nunca entra ni a revisión).
bool isNoiseBlock(String text) {
  final t = text.trim();
  if (t.length < 20 && !t.contains('?') && !t.contains('¿')) return true;
  if (_pageNumberRe.hasMatch(t)) return true;
  if (_headerLabelRe.hasMatch(t.split('\n').first)) return true;
  // Instrucciones: solo ruido si no traen señales de pregunta.
  if (_instructionRe.hasMatch(t) &&
      !t.contains('?') &&
      !t.contains('___') &&
      !_trueFalseRe.hasMatch(t)) {
    return true;
  }
  return false;
}

/// ¿Parece pregunta aunque sea dudosa? (entra a revisión con baja confianza).
bool looksLikeQuestion(String text) {
  final t = text.trim();
  if (t.contains('?') || t.contains('¿')) return true;
  if (_imperativeRe.hasMatch(t) && t.length > 25) return true;
  return false;
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
final _numberPrefixRe =
    RegExp(r'^\s*(?:P\s?)?\d{1,3}\s*[\.\)\:\-]\s*');

/// Quita el nº de pregunta del inicio del prompt (`1.`, `P3:`…).
String stripNumber(String prompt) =>
    prompt.replaceFirst(_numberPrefixRe, '').trim();

/// Resuelve una respuesta de clave (`b`, `(C)`, `V`, `verdadero`…).
String resolveKeyAnswer(String raw, List<String> options) {
  var answer = raw.trim();
  final letter = RegExp(r'^\(?([a-dA-D])\)?\.?$').firstMatch(answer);
  if (letter != null && options.isNotEmpty) {
    final idx = letter.group(1)!.toLowerCase().codeUnitAt(0) - 97;
    if (idx >= 0 && idx < options.length) return options[idx];
    return answer;
  }
  final vf = answer.toLowerCase();
  if (vf == 'v' || vf == 'verdadero' || vf == 'true') return 'Verdadero';
  if (vf == 'f' || vf == 'falso' || vf == 'false') return 'Falso';
  return answer;
}

/// Extrae `Respuesta: X` del final del bloque (y la quita del texto).
String _extractAnswer(StringBuffer body, List<String> options) {
  var answer = '';
  final text = body.toString();
  final m = _answerLineRe.firstMatch(text.split('\n').last.trim());
  if (m != null) {
    answer = resolveKeyAnswer(m.group(1)!.trim(), options);
    final lines = text.split('\n')..removeLast();
    body
      ..clear()
      ..write(lines.join('\n').trim());
  }
  return answer;
}

/// Clasifica un bloque en un [PdfDraft], o null si no hay ni una señal
/// de pregunta (ni siquiera dudosa).
PdfDraft? classifyBlock(String block) {
  final body = StringBuffer(block.trim());
  final lines = block
      .split('\n')
      .map((l) => l.trim())
      .where((l) => l.isNotEmpty)
      .toList();

  // Opciones tipo a) b) c) / (A).
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
  final hasOptions = options.length >= 2;
  final hasVF = _trueFalseRe.hasMatch(block);
  final hasBlank = _fillBlankRe.hasMatch(block);

  // 1. Verdadero/Falso.
  if (hasVF) {
    return PdfDraft(
        kind: 'trueFalse', prompt: prompt, answer: answer, confidence: 0.85);
  }
  // 2. Opción múltiple.
  if (hasOptions) {
    return PdfDraft(
        kind: 'multipleChoice',
        prompt:
            rest.join(' ').trim().isEmpty ? prompt : rest.join(' ').trim(),
        answer: answer,
        options: options,
        confidence: answer.isEmpty ? 0.7 : 0.9);
  }
  // 3. Completar / rellenar huecos.
  if (hasBlank) {
    return PdfDraft(
        kind: 'fillBlank', prompt: prompt, answer: answer, confidence: 0.75);
  }
  // 4. Ordenar.
  if (_orderingRe.hasMatch(low)) {
    final steps = lines
        .where((l) => RegExp(r'^\s*\d+\s*[\.\)\:\-]').hasMatch(l))
        .map((l) =>
            l.replaceFirst(RegExp(r'^\s*\d+\s*[\.\)\:\-]\s*'), ''))
        .where((l) => l.trim().isNotEmpty)
        .toList();
    if (steps.length >= 2) {
      return PdfDraft(
          kind: 'ordering',
          prompt: prompt,
          answer: answer.isNotEmpty ? answer : steps.join(','),
          options: steps,
          confidence: 0.65);
    }
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
  // 6. Flashcard: solo si hay señal mínima (respuesta, ? o imperativo).
  // Lo dudoso entra a revisión con confianza baja; sin señales → null.
  if (answer.isNotEmpty || looksLikeQuestion(prompt)) {
    return PdfDraft(
        kind: 'flashcard',
        prompt: prompt,
        answer: answer,
        confidence: answer.isNotEmpty ? 0.6 : 0.35);
  }
  return null;
}

/// Encabezado de solucionario/clave de respuestas.
final _keyHeaderRe = RegExp(
    r'^\s*(solucionario|respuestas?\s+correctas?|clave\s+de\s+respuestas?|answer\s*key|respuestas)\s*:?\s*$',
    caseSensitive: false,
    multiLine: true);

/// Entradas de clave: `1-a`, `2. B`, `3) Verdadero`, `4-V`…
final _keyEntryRe = RegExp(
    r'(\d{1,3})\s*[\.\)\:\-]\s*(\(?[a-dA-D]\)?\.?|verdadero|falso|true|false|[VF])\b',
    caseSensitive: false);

/// Normaliza un prompt para dedup (minúsculas, sin nº, espacios colapsados).
String normalizePrompt(String prompt) => stripNumber(prompt)
    .toLowerCase()
    .replaceAll(RegExp(r'\s+'), ' ')
    .trim();

/// Convierte el texto completo de un PDF en borradores + conteo de ruido.
PdfImportResult draftsFromText(String text) {
  // 1. Separa y parsea la sección solucionario (no entra como preguntas).
  var body = text;
  final key = <int, String>{};
  final hm = _keyHeaderRe.firstMatch(body);
  if (hm != null) {
    final section = body.substring(hm.start);
    body = body.substring(0, hm.start);
    for (final m in _keyEntryRe.allMatches(section)) {
      key[int.parse(m.group(1)!)] = m.group(2)!.trim();
    }
  }

  // 2. Segmenta, filtra ruido, clasifica, resuelve clave y dedup.
  final drafts = <PdfDraft>[];
  var ignored = key.isEmpty ? 0 : 1; // la sección clave cuenta como ruido
  final seen = <String>{};
  for (final b in segmentBlocks(body)) {
    if (isNoiseBlock(b.text)) {
      ignored++;
      continue;
    }
    final d = classifyBlock(b.text);
    if (d == null) {
      ignored++;
      continue;
    }
    d.prompt = stripNumber(d.prompt);
    // 3. Resuelve respuesta desde la clave por nº de pregunta.
    if (d.needsAnswer &&
        b.number != null &&
        key.containsKey(b.number) &&
        (d.kind == 'trueFalse' ||
            d.kind == 'multipleChoice' ||
            d.kind == 'flashcard' ||
            d.kind == 'fillBlank')) {
      d.answer = resolveKeyAnswer(key[b.number]!, d.options);
      d.confidence = 0.9;
    }
    final norm = normalizePrompt(d.prompt);
    if (norm.length < 12 || seen.contains(norm)) {
      ignored++;
      continue;
    }
    seen.add(norm);
    drafts.add(d);
  }
  return PdfImportResult(drafts, ignored);
}
