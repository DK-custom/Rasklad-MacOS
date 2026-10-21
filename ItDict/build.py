# Словарь macOS «IT-термины»: FOLDOC (английский) + ru_terms.tsv (русский) → Dictionary Development Kit.
#   python3 -I ItDict/build.py            — собрать ItDict/out/objects/ITTerms.dictionary
#   python3 -I ItDict/build.py --install  — и установить в ~/Library/Dictionaries
import datetime, hashlib, html, os, plistlib, re, shutil, subprocess, sys
from dataclasses import dataclass, field
from pathlib import Path

KIT = Path.home() / "Developer/DictionaryDevelopmentKit"
NAME = "ITTerms"


@dataclass
class Entry:
    head: str
    paras: list
    aliases: list = field(default_factory=list)


def parse_foldoc(text):
    """Заголовок — с начала строки, текст — с отступа, абзацы через пустую строку.
    Первая статья — вступление (лицензия). Статьи вида «API → {Application Program Interface}»
    становятся вторым именем основной статьи. Возвращает (абзацы вступления, статьи)."""
    raw, cur, para = [], None, []

    def flush():
        if para:
            cur.paras.append(" ".join(para))
            para.clear()

    for line in text.splitlines():
        if line and not line[0].isspace():
            if cur:
                flush()
            cur = Entry(line.strip(), [])
            raw.append(cur)
        elif not line.strip():
            if cur:
                flush()
        elif cur:
            para.append(line.strip())
    if cur:
        flush()
    if not raw:
        return [], []

    front, raw = raw[0].paras, raw[1:]
    by_head = {e.head: e for e in raw}
    by_lower = {e.head.lower(): e for e in raw}
    entries = []
    for e in raw:
        m = re.fullmatch(r"\{([^{}]+)\}\.?", e.paras[0]) if len(e.paras) == 1 else None
        target = m and (by_head.get(m.group(1)) or by_lower.get(m.group(1).lower()))
        if target and target is not e:
            target.aliases.append(e.head)
        else:
            entries.append(e)
    return front, entries


def _xref(m):
    inner = m.group(1)
    u = re.fullmatch(r"(.*?)\s*\(([^()\s]*[./:][^()\s]*)\)", inner)  # {ABI (abi.html)} — ссылка на сайт, оставляем текст
    text = u.group(1) if u else inner
    href = text.replace('"', "&quot;")  # текст уже экранирован без кавычек, а в атрибуте они ломают XML
    return f'<a href="x-dictionary:d:{href}">{text}</a>'


def render_para(p):
    """Абзац FOLDOC → HTML: <категория>, {перекрёстная ссылка}, (дата правки)."""
    if m := re.fullmatch(r"\((\d{4}-\d{2}-\d{2})\)", p):
        return f'<span class="date">{m.group(1)}</span>'
    cat = ""
    if m := re.match(r"<([^<>]+)>\s*", p):
        cat, p = f'<span class="cat">{html.escape(m.group(1))}</span> ', p[m.end():]
    date = ""
    if m := re.search(r"\s*\((\d{4}-\d{2}-\d{2})\)$", p):
        date, p = f' <span class="date">{m.group(1)}</span>', p[:m.start()]
    body = re.sub(r"\{([^{}]+)\}", _xref, html.escape(p, quote=False))
    return cat + body + date


@dataclass
class RuTerm:
    head: str
    text: str
    aliases: list


def parse_ru(text):
    """Строка: «термин|синоним<TAB>пояснение[<TAB>доп. слова для поиска через |]»
    или «термин|синоним — пояснение» (первое « — »); # — комментарий."""
    out = []
    for line in text.splitlines():
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        cols = line.split("\t") if "\t" in line else line.split(" — ", 1)  # в TextEdit табуляцию не видно
        if len(cols) < 2:
            continue
        names = [n.strip() for n in cols[0].split("|") if n.strip()]
        extra = [n.strip() for n in cols[2].split("|") if n.strip()] if len(cols) > 2 else []
        out.append(RuTerm(names[0], cols[1].strip(), names[1:] + extra))
    return out


_BAD = re.compile(r"[\x00-\x08\x0b\x0c\x0e-\x1f]")


def _a(s):
    return html.escape(_BAD.sub("", s), quote=True)


def _entry(eid, head, aliases, body, lang):
    idx = "".join(f'<d:index d:value="{_a(k)}" d:title="{_a(k)}"/>' for k in [head] + aliases)
    sub = f' <span class="alias">{_a(", ".join(aliases))}</span>' if aliases else ""
    return (f'<d:entry id="{eid}" d:title="{_a(head)}" lang="{lang}">{idx}'
            f'<h1 class="it-head">{_a(head)}{sub}</h1>{body}</d:entry>\n')


def to_xml(entries, ru, front):
    parts = ['<?xml version="1.0" encoding="UTF-8"?>\n'
             '<d:dictionary xmlns="http://www.w3.org/1999/xhtml" '
             'xmlns:d="http://www.apple.com/DTDs/DictionaryService-1.0.rng">\n']
    about = ("<p>Английские термины — The Free On-line Dictionary of Computing, http://foldoc.org/, "
             "Editor Denis Howe; GNU Free Documentation License 1.1 или новее.</p>"
             "<p>Русские термины — собственный список (ItDict/ru_terms.tsv).</p>")
    parts.append(f'<d:entry id="front_back_matter" d:title="IT-термины"><h1>IT-термины</h1>{about}'
                 + "".join(f"<p>{_BAD.sub('', render_para(p))}</p>" for p in front) + "</d:entry>\n")
    for i, e in enumerate(entries):
        body = "".join(f'<p class="it-p">{_BAD.sub("", render_para(p))}</p>' for p in e.paras)
        parts.append(_entry(f"f{i}", e.head, e.aliases, body, "en"))
    for i, t in enumerate(ru):
        parts.append(_entry(f"r{i}", t.head, t.aliases, f'<p class="it-p">{_BAD.sub("", render_para(t.text))}</p>', "ru"))
    parts.append("</d:dictionary>\n")
    return "".join(parts)


def main():
    root = Path(__file__).resolve().parent
    front, entries = parse_foldoc((root / "foldoc/Dictionary.txt").read_text(encoding="utf-8"))
    ru = parse_ru((root / "ru_terms.tsv").read_text(encoding="utf-8"))
    out = root / "out"
    shutil.rmtree(out, ignore_errors=True)
    out.mkdir()
    xml = to_xml(entries, ru, front)
    (out / f"{NAME}.xml").write_text(xml, encoding="utf-8")
    shutil.copy(root / f"{NAME}.css", out / f"{NAME}.css")
    # версия меняется вместе с содержимым — по ней Rasklad обновляет установленный словарь
    css = (root / f"{NAME}.css").read_bytes()
    digest = hashlib.sha1(xml.encode() + css).hexdigest()[:8]
    info = plistlib.loads((root / f"{NAME}.plist").read_bytes())
    info["CFBundleShortVersionString"] = f"{datetime.date.today():%Y.%m.%d}-{digest}"
    (out / f"{NAME}.plist").write_bytes(plistlib.dumps(info))
    print(f"FOLDOC: {len(entries)} статей, {sum(len(e.aliases) for e in entries)} вторых имён; русских: {len(ru)}")
    subprocess.run([str(KIT / "bin/build_dict.sh"), NAME, f"{NAME}.xml", f"{NAME}.css", f"{NAME}.plist"],
                   cwd=out, check=True, env={**os.environ, "DICT_BUILD_TOOL_DIR": str(KIT)})
    built = out / "objects" / f"{NAME}.dictionary"
    print("собран:", built)
    print("версия:", info["CFBundleShortVersionString"])
    if "--install" in sys.argv:
        # папка словарей в контейнере «Словаря» — ссылка на ~/Library/Dictionaries, копия одна
        dest = Path.home() / "Library/Dictionaries" / f"{NAME}.dictionary"
        dest.parent.mkdir(parents=True, exist_ok=True)
        shutil.rmtree(dest, ignore_errors=True)
        shutil.copytree(built, dest)
        print("установлен:", dest, "— если «Словарь» открыт, перезапустите его")


if __name__ == "__main__":
    main()
