@echo off
for /f "tokens=2 delims==" %%I in ('wmic os get localdatetime /value') do set datetime=%%I
set BUILD_DATE=%datetime:~0,12%
echo Build date: %BUILD_DATE%
flutter build apk --debug --dart-define=BUILD_DATE=%BUILD_DATE% && adb install build\app\outputs\flutter-apk\app-debug.apk
