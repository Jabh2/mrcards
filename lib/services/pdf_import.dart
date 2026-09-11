/// API pública de importación PDF.
///
/// En plataformas con `dart:io` usa picker + pdfrx; en web, stub.
library;

export 'pdf_import_stub.dart'
    if (dart.library.io) 'pdf_import_io.dart';
