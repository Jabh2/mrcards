/// Clasificación de referencias de imagen en preguntas tipo imagen.
///
/// Una referencia puede ser:
/// - URL de red (`http://` / `https://`) → se muestra con [Image.network].
/// - Archivo local (`file:<ruta absoluta>`) → foto del dispositivo guardada
///   por [DeviceImages] en el directorio privado de la app.
/// - Cualquier otro texto → placeholder con icono (comportamiento heredado).
library;

enum ImageRefKind { network, local, placeholder }

ImageRefKind classifyImageRef(String ref) {
  final r = ref.trim();
  if (r.startsWith('http://') || r.startsWith('https://')) {
    return ImageRefKind.network;
  }
  if (r.startsWith('file:')) return ImageRefKind.local;
  return ImageRefKind.placeholder;
}

bool isLocalImageRef(String ref) =>
    classifyImageRef(ref) == ImageRefKind.local;
