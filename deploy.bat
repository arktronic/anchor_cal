@echo off
flutter build apk --release && adb install build\app\outputs\flutter-apk\app-release.apk
