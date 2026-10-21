# Rasklad

**English** · [Русский](README.ru.md)

A macOS menu bar utility, a replacement for Punto Switcher: fixes text typed in the wrong keyboard
layout (RU ↔ EN), small typos and an accidental Caps Lock, switches layouts instantly with Fn/🌐
and shows word definitions from the macOS dictionaries. Swift, no third-party dependencies.

## Features

- **Auto-switch on space:** `ghbdtn` → «привет», `рщц` → "how"; short words are decided by lists
  of common words; words that exist in both languages («руку» / "here") — by the language of the phrase.
- **Typos:** `првиет` → «привет», including together with a wrong layout (`ghbtdn` → «привет»).
- **A word typed in two layouts** (`ска;b` → «скажи») and **accidental Caps Lock** (`правописанИЕ` → «правописание»).
- **Correction key** (right ⌥ by default; also left ⌥, right/left ⌘, ⌃): undo the last fix,
  retype the current word or the selection; with ⇧ — a definition popup styled like the system "Look Up".
- **Fn/🌐** switches the layout without the macOS delay (the stock 🌐 action is turned off in Settings).
- **Leaves code alone:** IDEs and terminals, code editors in the browser, text inside ``` and `…`.
- **Leaves passwords alone:** password fields, the lock screen, system password dialogs.
- Word and app exceptions, per-app layout, hints at the caret, a first-run setup window.
- **"IT-термины" dictionary** for macOS Dictionary: FOLDOC (~15k English terms) plus Russian IT terms.

Typed text is never sent anywhere and is not written to the log (`~/Library/Logs/Rasklad.log`).

## Requirements

- macOS 13+ (Apple Silicon and Intel), "ABC" and "Russian" input sources.
- To build — Command Line Tools (`xcode-select --install`); Xcode is not required.
- For the "IT-термины" dictionary — Dictionary Development Kit from "Additional Tools for Xcode"
  (developer.apple.com/download/all) in `~/Developer/DictionaryDevelopmentKit` (no spaces in the path).

## Build

```bash
./build.sh test   # self-test, no frameworks
./build.sh        # build, install to /Applications and launch
./build.sh dist   # build/Rasklad.dmg and build/Rasklad.zip for another Mac
python3 -I ItDict/build.py --install   # rebuild and install the "IT-термины" dictionary
python3 -I ItDict/test_build.py        # dictionary builder test
```

Signing: `build.sh` signs with the "Rasklad Dev" certificate from the keychain if present
(self-signed, code signing only), so macOS permissions survive rebuilds; otherwise it signs ad-hoc
and permissions have to be granted again after every build. The app is not notarized: on another Mac
the first launch goes through Privacy & Security → "Open Anyway".

## Install

From `build/Rasklad.dmg` or `.zip` — see [INSTALL.txt](INSTALL.txt) (Russian; also covers uninstalling).
The Accessibility and Input Monitoring permissions are requested step by step in the first-run window.

## Layout

| File | Contents |
|---|---|
| `Sources/main.swift` | menu, setup window, converting the selection, definitions, login item |
| `Sources/KeyTap.swift` | keystroke tap (CGEventTap), word check on space, retyping |
| `Sources/Detector.swift` | rules: layout, short words, phrases, typos, case, code, keys |
| `Sources/Layouts.swift` | character tables from system layouts, switching that keeps Caps Lock |
| `Sources/Settings.swift` | settings, exceptions, code apps, log |
| `Sources/Hint.swift` | hints at the caret, Accessibility queries to the text field |
| `Sources/Dictionary.swift` | system dictionary entries, the bundled "IT-термины" dictionary |
| `Sources/Onboarding.swift` | first-run window |
| `Tests/main.swift` | rule self-test |
| `ItDict/` | "IT-термины" dictionary build (FOLDOC + `ru_terms.tsv`) |
| `Tools/icon.swift` | icon generator |

Docs (Russian): [AUDIT.md](AUDIT.md) — audit and fixes; `*_WINDOWS.md` — notes for porting hints,
dictionaries and typo fixing to Windows; [PROJECT_STATE.md](PROJECT_STATE.md) — project state.

## License

Code — MIT (see [LICENSE](LICENSE)); third-party content — [NOTICE](NOTICE). `ItDict/foldoc/Dictionary.txt` — FOLDOC, © Denis Howe,
GNU Free Documentation License 1.1+.
