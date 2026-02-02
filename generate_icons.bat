@echo off
cd /d %~dp0
echo Converting SVG to PNG...
magick -background none -density 1024 assets\logo.svg -resize 1024x1024 assets\logo.png

echo Generating launcher icons...
dart run flutter_launcher_icons

echo Done!
