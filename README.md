# MrCards

MrCards — Estudia, Practica y Recuerda. App offline de flashcards con repetición espaciada, 6 idiomas (es, en, pt, fr, de, zh), sin internet.

## Características
- Mazos y preguntas (flashcard, opción múltiple, verdadero/falso, escrita, ordenar, emparejar, imagen)
- Modos: repaso, aleatorio, examen, maratón con reencolado inteligente
- Niveles, rachas, logros y estadísticas
- 100% offline — datos en SharedPreferences (`mrcards.v1`), compatible con `flashcards.v1` legado

## Icono
`assets/icon/mrcards_icon_1024.png` (1024x1024) + `mrcards_foreground_432.png`

## Build
```bash
flutter pub get
dart run flutter_launcher_icons
flutter build appbundle --release
flutter build apk --release
```

## Play Store
- `applicationId: com.mrcards.app`
- `version: 1.0.1+2`
