/// Stub web: sin `dart:io`. Las fotos del dispositivo son solo móvil.
/// La clasificación y URLs de red siguen funcionando igual.
library;

import 'package:flutter/material.dart';

const kMaxImagesPerQuestion = 4;

Future<String?> pickGalleryImage() async => null;

Future<String?> pickCameraImage() async => null;

String localImagePath(String ref) =>
    ref.startsWith('file:') ? ref.substring(5) : ref;

Future<void> deleteImageRef(String ref) async {}

Future<int> sweepOrphanImages(Set<String> usedRefs,
    {dynamic dir}) async {
  return 0;
}

Widget imageRefThumb(String ref,
    {BoxFit fit = BoxFit.cover, double iconSize = 40}) {
  final r = ref.trim();
  if (r.startsWith('http://') || r.startsWith('https://')) {
    return Image.network(r,
        fit: fit,
        errorBuilder: (_, _, _) => Icon(Icons.image, size: iconSize));
  }
  return Icon(Icons.image, size: iconSize);
}
