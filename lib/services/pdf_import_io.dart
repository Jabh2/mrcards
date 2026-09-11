/// Entrada PDF: picker + extracción de texto on-device.
///
/// Todo ocurre en el dispositivo (file_picker + pdfrx): el PDF nunca
/// sale del móvil. El parseo/clasificación vive en `pdf_parse.dart`.
library;

import 'package:file_picker/file_picker.dart';
import 'package:pdfrx/pdfrx.dart';

/// Abre el selector del sistema y devuelve la ruta del PDF, o null.
Future<String?> pickPdfFile() async {
  final res = await FilePicker.pickFile(
    type: FileType.custom,
    allowedExtensions: ['pdf'],
  );
  return res?.path;
}

/// Extrae el texto de todas las páginas, en orden.
Future<String> extractPdfText(String path) async {
  await pdfrxFlutterInitialize();
  final doc = await PdfDocument.openFile(path);
  try {
    final sb = StringBuffer();
    for (final page in doc.pages) {
      final t = await page.loadText();
      if (t != null) sb.writeln(t.fullText);
    }
    return sb.toString();
  } finally {
    await doc.dispose();
  }
}
