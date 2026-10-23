#!/bin/zsh
# ./build.sh        — собрать build/Rasklad.app, установить в /Applications и запустить
# ./build.sh test   — самопроверка
# ./build.sh dist   — собрать установщик build/Rasklad.dmg для другого Mac (без установки здесь)
set -e
cd "${0:A:h}"
mkdir -p build

if [[ "$1" == test ]]; then
  swiftc -swift-version 5 Sources/Layouts.swift Sources/Detector.swift Sources/Settings.swift Sources/Hint.swift Sources/Dictionary.swift Tests/main.swift -o build/selftest
  exec build/selftest
fi

APP=build/Rasklad.app
rm -rf $APP
mkdir -p $APP/Contents/MacOS $APP/Contents/Resources
cp Info.plist $APP/Contents/
cp Rasklad.icns $APP/Contents/Resources/ # иконка: swift Tools/icon.swift build/Rasklad.iconset && iconutil -c icns …
# Словарь «IT-термины» внутри приложения — его ставит шаг окна настройки
DICT=ItDict/out/objects/ITTerms.dictionary
[[ -d $DICT ]] || python3 -I ItDict/build.py
ditto $DICT $APP/Contents/Resources/ITTerms.dictionary
# Универсальный бинарник: Apple Silicon и Intel, macOS 13+ (SMAppService).
for arch in arm64 x86_64; do
  swiftc -O -swift-version 5 -target $arch-apple-macos13 Sources/*.swift -o build/Rasklad-$arch
done
lipo -create build/Rasklad-arm64 build/Rasklad-x86_64 -output $APP/Contents/MacOS/Rasklad
rm build/Rasklad-arm64 build/Rasklad-x86_64

# Постоянный сертификат «Rasklad Dev» сохраняет права между пересборками;
# без него ad-hoc подпись, и после каждой сборки права надо выдавать заново.
if security find-identity -p codesigning | grep -q '"Rasklad Dev"'; then
  codesign --force -s "Rasklad Dev" $APP
else
  codesign --force -s - $APP
  echo "внимание: нет сертификата «Rasklad Dev», подпись ad-hoc — права слетят"
fi
echo "готово: $APP"

if [[ "$1" == dist ]]; then
  STAGE=build/dmg
  rm -rf $STAGE build/Rasklad.dmg build/Rasklad.zip
  mkdir -p $STAGE
  ditto $APP $STAGE/Rasklad.app
  ln -s /Applications $STAGE/Applications
  cp INSTALL.txt "$STAGE/Установка.txt"
  cp INSTALL.en.txt "$STAGE/Install.txt"
  hdiutil create -volname Rasklad -srcfolder $STAGE -format UDZO -quiet build/Rasklad.dmg
  rm -rf $STAGE
  echo "установщик: build/Rasklad.dmg"
  exit 0
fi

# Одно место установки — то же, что при установке из DMG (права привязаны к подписи, не к пути).
pkill -x Rasklad || true
# ждём, пока старая копия завершится: иначе open лишь активирует её, и после выхода ничего не запустится
for _ in {1..50}; do pgrep -x Rasklad >/dev/null || break; sleep 0.1; done
rm -rf /Applications/Rasklad.app && ditto $APP /Applications/Rasklad.app
echo "установлено: /Applications/Rasklad.app"
open /Applications/Rasklad.app
