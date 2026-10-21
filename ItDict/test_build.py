# Самопроверка разбора FOLDOC и русских терминов: python3 -I ItDict/test_build.py
import sys, pathlib
sys.path.insert(0, str(pathlib.Path(__file__).parent))
import build

SAMPLE = """Free On-line Dictionary of Computing

\t<introduction> FOLDOC is a dictionary.

\tCopyright 1985 by Denis Howe

API

\t{Application Program Interface}

Application Program Interface

\t<programming> (API) The interface by which an {application
\tprogram} accesses {operating system} services & a < b.

\tSee also {ABI (abi.html)}.

\t(1995-02-15)

cache

\t<memory management> /kash/ A small fast memory.

"""

def check(got, want):
    ok = got == want
    print("ok  " if ok else "FAIL", repr(got) if not ok else "", "" if ok else f"!= {want!r}")
    if not ok:
        sys.exit(1)

front, entries = build.parse_foldoc(SAMPLE)
check(front[0].startswith("<introduction> FOLDOC"), True)
check([e.head for e in entries], ["Application Program Interface", "cache"])   # API — не статья, а второе имя
check(entries[0].aliases, ["API"])
check(len(entries[0].paras), 3)

html = build.render_para(entries[0].paras[0])
check('<span class="cat">programming</span>' in html, True)
check('<a href="x-dictionary:d:application program">application program</a>' in html, True)  # перенос строки внутри {}
check("&amp; a &lt; b" in html, True)
check(build.render_para(entries[0].paras[1]), 'See also <a href="x-dictionary:d:ABI">ABI</a>.')  # (url) отбрасываем
check(build.render_para(entries[0].paras[2]), '<span class="date">1995-02-15</span>')
check(build.render_para('{Cook paper "X"}'), '<a href="x-dictionary:d:Cook paper &quot;X&quot;">Cook paper "X"</a>')  # кавычки в атрибуте

ru = build.parse_ru("""# комментарий
API|АПИ\tПрограммный интерфейс приложения.
ПО\tПрограммное обеспечение.\tсофт

""")
check([(t.head, t.aliases) for t in ru], [("API", ["АПИ"]), ("ПО", ["софт"])])
ru2 = build.parse_ru("деплой|деплоймент — Выкладка новой версии — с тире внутри.\nбаг\n")
check([(t.head, t.aliases, t.text) for t in ru2], [("деплой", ["деплоймент"], "Выкладка новой версии — с тире внутри.")])

xml = build.to_xml(entries[:1], ru[:1], front)
check('d:title="Application Program Interface"' in xml and '<d:index d:value="API"' in xml, True)
check('id="front_back_matter"' in xml, True)
check(xml.count("<d:entry") == 3, True)  # front matter + FOLDOC + русский
print("all ok")
