/// Imágenes del dispositivo (Android/iOS/desktop): galería + cámara.
///
/// Las fotos elegidas se copian al directorio privado de la app
/// (`mrcards_images/`) y se referencian como `file:<ruta>`.
/// Todo permanece en el dispositivo: sin subida, sin red.
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';

import 'image_refs.dart';

const _kImagesDirName = 'mrcards_images';

/// Ancho máximo al importar (reduce peso) y calidad JPEG 0-100.
const kMaxDeviceImageWidth = 1024.0;
const kDeviceImageQuality = 80;

/// Máximo de imágenes por pregunta (grid 2x2 en estudio).
const kMaxImagesPerQuestion = 4;

final _picker = ImagePicker();

Future<Directory> getDeviceImagesDir() async {
  final docs = await getApplicationDocumentsDirectory();
  final dir = Directory('${docs.path}/$_kImagesDirName');
  if (!await dir.exists()) await dir.create(recursive: true);
  return dir;
}

Future<String?> _storePicked(XFile? picked) async {
  if (picked == null) return null;
  final dir = await getDeviceImagesDir();
  final name = '${DateTime.now().microsecondsSinceEpoch}.jpg';
  final saved = await File(picked.path).copy('${dir.path}/$name');
  return 'file:${saved.path}';
}

/// Elige de la galería (selector del sistema, sin permiso extra).
Future<String?> pickGalleryImage() => _picker
    .pickImage(
      source: ImageSource.gallery,
      maxWidth: kMaxDeviceImageWidth,
      imageQuality: kDeviceImageQuality,
    )
    .then(_storePicked);

/// Toma foto con la cámara (requiere permiso CAMERA en Android).
Future<String?> pickCameraImage() => _picker
    .pickImage(
      source: ImageSource.camera,
      maxWidth: kMaxDeviceImageWidth,
      imageQuality: kDeviceImageQuality,
    )
    .then(_storePicked);

String localImagePath(String ref) =>
    ref.startsWith('file:') ? ref.substring(5) : ref;

/// Borra el archivo local de [ref]. No hace nada si no es local.
Future<void> deleteImageRef(String ref) async {
  if (!isLocalImageRef(ref)) return;
  try {
    final f = File(localImagePath(ref.trim()));
    if (await f.exists()) await f.delete();
  } catch (_) {}
}

/// Borra fotos locales que ninguna pregunta usa. Devuelve nº borrados.
Future<int> sweepOrphanImages(Set<String> usedRefs, {Directory? dir}) async {
  try {
    final target = dir ?? await getDeviceImagesDir();
    if (!await target.exists()) return 0;
    var removed = 0;
    await for (final e in target.list()) {
      if (e is File && !usedRefs.contains('file:${e.path}')) {
        try {
          await e.delete();
          removed++;
        } catch (_) {}
      }
    }
    return removed;
  } catch (_) {
    return 0;
  }
}

/// Widget para mostrar una referencia: red, archivo local o placeholder.
Widget imageRefThumb(String ref,
    {BoxFit fit = BoxFit.cover, double iconSize = 40}) {
  switch (classifyImageRef(ref)) {
    case ImageRefKind.network:
      return Image.network(ref.trim(),
          fit: fit,
          errorBuilder: (_, _, _) => Icon(Icons.image, size: iconSize));
    case ImageRefKind.local:
      return Image.file(File(localImagePath(ref.trim())),
          fit: fit,
          errorBuilder: (_, _, _) =>
              Icon(Icons.broken_image, size: iconSize));
    case ImageRefKind.placeholder:
      return Icon(Icons.image, size: iconSize);
  }
}
