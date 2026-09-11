/// API pública de imágenes del dispositivo.
///
/// En plataformas con `dart:io` delega en `device_images_io.dart`;
/// en web usa el stub sin-op (las preguntas con foto son solo móvil).
library;

export 'device_images_stub.dart'
    if (dart.library.io) 'device_images_io.dart';
