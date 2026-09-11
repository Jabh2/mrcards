import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mrcards/services/device_images_io.dart'
    show sweepOrphanImages;
import 'package:mrcards/services/image_refs.dart';

void main() {
  group('classifyImageRef', () {
    test('URLs http/https son network', () {
      expect(classifyImageRef('http://x.com/a.jpg'), ImageRefKind.network);
      expect(
          classifyImageRef('https://x.com/a.jpg'), ImageRefKind.network);
    });
    test('refs file: son local', () {
      expect(classifyImageRef('file:/data/a.jpg'), ImageRefKind.local);
      expect(isLocalImageRef('file:/data/a.jpg'), isTrue);
    });
    test('texto o vacío es placeholder (legacy)', () {
      expect(classifyImageRef('dog'), ImageRefKind.placeholder);
      expect(classifyImageRef(''), ImageRefKind.placeholder);
      expect(isLocalImageRef('dog'), isFalse);
      expect(isLocalImageRef('https://x.com/a.jpg'), isFalse);
    });
  });

  group('sweepOrphanImages', () {
    test('borra solo archivos no usados', () async {
      final dir =
          await Directory.systemTemp.createTemp('mrcards_img_test_');
      try {
        final keep = File('${dir.path}/keep.jpg')..writeAsBytesSync([1]);
        final drop = File('${dir.path}/drop.jpg')..writeAsBytesSync([2]);
        final removed =
            await sweepOrphanImages({'file:${keep.path}'}, dir: dir);
        expect(removed, 1);
        expect(keep.existsSync(), isTrue);
        expect(drop.existsSync(), isFalse);
      } finally {
        if (await dir.exists()) await dir.delete(recursive: true);
      }
    });
  });
}
