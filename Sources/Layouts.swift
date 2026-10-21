import Carbon
import Foundation
import IOKit.hid

/// Раскладки RU/EN, таблицы символов из системных раскладок (UCKeyTranslate),
/// чтобы не держать захардкоженную таблицу (Russian vs Russian–PC отличаются пунктуацией).
struct Layouts {
    let en: TISInputSource
    let ru: TISInputSource
    let enToRu: [Character: Character]
    let ruToEn: [Character: Character]
    /// keycode*2+shift -> символ в каждой раскладке
    let enChars: [Int: Character]
    let ruChars: [Int: Character]

    init?() {
        guard let en = Layouts.find("en"), let ru = Layouts.find("ru") else { return nil }
        self.en = en
        self.ru = ru
        let e = Layouts.chars(en), r = Layouts.chars(ru)
        enChars = e
        ruChars = r
        var er = [Character: Character](), re = [Character: Character]()
        for (key, ec) in e.sorted(by: { $0.key < $1.key }) {
            guard let rc = r[key], rc != ec else { continue }
            if er[ec] == nil { er[ec] = rc }
            if re[rc] == nil { re[rc] = ec }
        }
        enToRu = er
        ruToEn = re
    }

    func current() -> Lang? {
        let id = Layouts.id(TISCopyCurrentKeyboardInputSource().takeRetainedValue())
        return id == Layouts.id(en) ? .en : id == Layouts.id(ru) ? .ru : nil
    }

    func source(_ lang: Lang) -> TISInputSource { lang == .en ? en : ru }
    func chars(_ lang: Lang) -> [Int: Character] { lang == .en ? enChars : ruChars }

    /// Клавиша, дающая символ в раскладке: (keycode, ⇧). Для набора с настоящими кодами клавиш.
    func key(for ch: Character, in lang: Lang) -> (code: Int, shift: Bool)? {
        chars(lang).filter { $0.value == ch }.map(\.key).min().map { ($0 / 2, $0 % 2 == 1) }
    }

    static func id(_ s: TISInputSource) -> String {
        Unmanaged<CFString>.fromOpaque(TISGetInputSourceProperty(s, kTISPropertyInputSourceID)).takeUnretainedValue() as String
    }

    /// Первая включённая раскладка (не метод ввода) с данным основным языком.
    static func find(_ lang: String) -> TISInputSource? {
        let filter = [kTISPropertyInputSourceType: kTISTypeKeyboardLayout] as CFDictionary
        guard let list = TISCreateInputSourceList(filter, false)?.takeRetainedValue() as? [TISInputSource] else { return nil }
        return list.first { src in
            guard let p = TISGetInputSourceProperty(src, kTISPropertyInputSourceLanguages) else { return false }
            let langs = Unmanaged<CFArray>.fromOpaque(p).takeUnretainedValue() as? [String]
            return langs?.first == lang
        }
    }

    /// keycode*2+shift -> символ, только основной блок клавиш (0...50), без цифрового блока.
    static func chars(_ src: TISInputSource) -> [Int: Character] {
        guard let p = TISGetInputSourceProperty(src, kTISPropertyUnicodeKeyLayoutData) else { return [:] }
        let data = Unmanaged<CFData>.fromOpaque(p).takeUnretainedValue() as Data
        var out = [Int: Character]()
        data.withUnsafeBytes { raw in
            let layout = raw.baseAddress!.assumingMemoryBound(to: UCKeyboardLayout.self)
            for code in 0...50 {
                for shift in 0...1 {
                    var dead: UInt32 = 0, len = 0
                    var buf = [UniChar](repeating: 0, count: 4)
                    let mods = UInt32(shift == 1 ? (shiftKey >> 8) & 0xFF : 0)
                    UCKeyTranslate(layout, UInt16(code), UInt16(kUCKeyActionDown), mods,
                                   UInt32(LMGetKbdType()), OptionBits(1 << kUCKeyTranslateNoDeadKeysBit),
                                   &dead, buf.count, &len, &buf)
                    let s = String(utf16CodeUnits: buf, count: len)
                    if s.count == 1, let c = s.first, !c.isWhitespace, c.asciiValue.map({ $0 >= 32 }) ?? true {
                        out[code * 2 + shift] = c
                    }
                }
            }
        }
        return out
    }
}

enum Direction { case enToRu, ruToEn }

enum Lang: String {
    case en, ru
    var other: Lang { self == .en ? .ru : .en }
}

/// Направление — по преобладающему алфавиту в тексте.
func detectDirection(_ text: String) -> Direction {
    var cyr = 0, lat = 0
    for u in text.unicodeScalars {
        if (0x0400...0x04FF).contains(u.value) { cyr += 1 }
        else if u.isASCII, u.properties.isAlphabetic { lat += 1 }
    }
    return cyr > lat ? .ruToEn : .enToRu
}

func convert(_ text: String, _ map: [Character: Character]) -> String {
    String(text.map { map[$0] ?? $0 })
}

/// Переключить раскладку, сохранив Caps Lock: macOS сбрасывает его при TISSelectInputSource.
func selectLayout(_ src: TISInputSource) {
    let caps = capsLock()
    TISSelectInputSource(src)
    guard caps else { return }
    setCapsLock(true)
    // сброс иногда приходит асинхронно, уже после возврата — проверяем ещё раз
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { if !capsLock() { setCapsLock(true) } }
}

private let hidConnect: io_connect_t = {
    var c: io_connect_t = 0
    let svc = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching(kIOHIDSystemClass))
    IOServiceOpen(svc, mach_task_self_, UInt32(kIOHIDParamConnectType), &c)
    IOObjectRelease(svc)
    return c
}()

func capsLock() -> Bool {
    var on = false
    IOHIDGetModifierLockState(hidConnect, Int32(kIOHIDCapsLockState), &on)
    return on
}

func setCapsLock(_ on: Bool) { IOHIDSetModifierLockState(hidConnect, Int32(kIOHIDCapsLockState), on) }
