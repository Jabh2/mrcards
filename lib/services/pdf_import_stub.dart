/// Stub web de importación PDF (sin picker nativo ni pdfrx).
library;

Future<String?> pickPdfFile() async => null;

Future<String> extractPdfText(String path) async =>
    throw UnsupportedError('Importar PDF solo está disponible en móvil.');
