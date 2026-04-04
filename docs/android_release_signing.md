# Android Release Signing Notu

Bu proje Android `release` paketini imzali uretecek sekilde ayarlanmistir.

## Dosyalar

- Keystore: `android/app/lifeos_gate_upload.jks`
- Key config: `android/key.properties`
- Gradle signing config: `android/app/build.gradle.kts`

`android/.gitignore` icinde `key.properties` ve `*.jks` disarida birakildigi icin bu hassas dosyalar repoya gitmez.

## Kullanilan Alias

- `keyAlias=lifeos_gate_upload`

## Release Alma

```bash
flutter build apk --release
```

Cikti:

- `build/app/outputs/flutter-apk/app-release.apk`

## Not

Sifreler (`storePassword`, `keyPassword`) sadece `android/key.properties` dosyasinda tutulur. Guvenlik icin sifreleri dokumana duz metin olarak tekrar yazmiyoruz.
