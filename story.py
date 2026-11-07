"""Generate the story page: one self-contained HTML file from the marts.

    uv run python story.py   (or `just story`)

Writes out/story.html, to open in a browser. It contains your listening history: out/ is
gitignored, keep it local.
"""

import datetime as dt
import hashlib
import html
import pathlib

import duckdb

ROOT = pathlib.Path(__file__).parent
DB_PATH = ROOT / "spotify.duckdb"
OUT = ROOT / "out" / "story.html"


def q(sql: str) -> list[dict]:
    with duckdb.connect(str(DB_PATH), read_only=True) as con:
        rel = con.sql(sql)
        return [dict(zip(rel.columns, row)) for row in rel.fetchall()]


def esc(value) -> str:
    return html.escape(str(value))


# Data --------------------------------------------------------------------------------------


def load() -> dict:
    data = {}
    data["overview"] = q(
        """
        SELECT
            COUNT(*) FILTER (WHERE count_as_play) AS plays,
            round(SUM(ms_played) / 3600000) AS hours,
            COUNT(DISTINCT song_id) AS songs,
            COUNT(DISTINCT song_artist) AS artists,
            MIN(timestamp)::DATE AS first_play,
            MAX(timestamp)::DATE AS last_play
        FROM int_music_play
        """
    )[0]
    data["sizes"] = q(
        """
        SELECT
            (SELECT COUNT(*) FROM mart_long_standing) AS companion,
            (SELECT COUNT(*) FROM mart_obsession) AS obsession,
            (SELECT COUNT(*) FROM mart_intentionality) AS sought
        """
    )[0]
    data["core"] = q(
        """
        SELECT title, artist, plays, companion_rank, obsession_rank, sought_rank
        FROM mart_song_profile
        WHERE profile = 'core'
        ORDER BY companion_rank + obsession_rank + sought_rank
        """
    )
    data["companion"] = q(
        """
        SELECT title, artist, score, lifetime_months, post_honeymoon_active_months, post_honeymoon_months,
            year(first_play) AS since
        FROM mart_long_standing
        ORDER BY score DESC, active_days DESC
        LIMIT 10
        """
    )
    data["obsession"] = q(
        """
        SELECT title, artist, score, binge_days, binge_months, max_day,
            year(first_binge) AS from_year, year(last_binge) AS to_year
        FROM mart_obsession
        ORDER BY score DESC, binge_days DESC
        LIMIT 10
        """
    )
    data["sought"] = q(
        """
        SELECT title, artist, score, picked_plays, album_sought_plays, total_plays, skipped_plays
        FROM mart_intentionality
        ORDER BY score DESC
        LIMIT 10
        """
    )
    data["eras"] = q(
        """
        WITH yearly AS (
            SELECT year(day) AS year, song_id, COUNT(*) AS binge_days
            FROM int_song_day
            WHERE is_binge
            GROUP BY ALL
        )
        SELECT year, title, artist, binge_days
        FROM yearly
        JOIN mart_song_profile USING (song_id)
        QUALIFY row_number() OVER (PARTITION BY year ORDER BY binge_days DESC, title) <= 3
        ORDER BY year, binge_days DESC, title
        """
    )
    data["map"] = q(
        """
        SELECT title, artist, profile, companion_pct, obsession_pct, is_sought, song_id
        FROM mart_song_profile
        WHERE is_companion OR is_obsession
        """
    )
    data["albums"] = q(
        """
        SELECT album, album_artist, score, sessions, session_months, longest_run,
            year(first_session) AS from_year, year(last_session) AS to_year
        FROM mart_album
        ORDER BY score DESC
        LIMIT 8
        """
    )
    data["works"] = q(
        """
        SELECT work_title, score, adopted_performers, total_plays, performer_plays
        FROM mart_work
        ORDER BY score DESC
        LIMIT 8
        """
    )
    return data


# Rendering ---------------------------------------------------------------------------------


def years(a, b) -> str:
    return str(a) if a == b else f"{a}–{b}"


def ranked_list(rows, accent: str, title_key: str, sub_key: str | None, why) -> str:
    top = max(r["score"] for r in rows) or 1
    items = []
    for i, r in enumerate(rows, 1):
        sub = f'<span class="artist">{esc(r[sub_key])}</span>' if sub_key else ""
        items.append(
            f"""
            <li>
              <span class="rank">{i}</span>
              <div class="entry">
                <div class="name"><strong>{esc(r[title_key])}</strong>{sub}</div>
                <div class="why">{why(r)}</div>
                <div class="bar" style="--w:{100 * r['score'] / top:.1f}%; --c:var({accent})"></div>
              </div>
            </li>"""
        )
    return f'<ol class="ranked">{"".join(items)}</ol>'


def section(id_: str, eyebrow: str, title: str, lede: str, body: str, accent: str) -> str:
    return f"""
    <section id="{id_}" style="--accent:var({accent})">
      <p class="eyebrow">{eyebrow}</p>
      <h2>{title}</h2>
      <p class="lede">{lede}</p>
      {body}
    </section>"""


def render_core(data) -> str:
    sizes = data["sizes"]
    cards = "".join(
        f"""
        <article class="core-card">
          <h3>{esc(r['title'])}</h3>
          <p class="artist">{esc(r['artist'])}</p>
          <dl>
            <div><dt>Companion</dt><dd>#{r['companion_rank']}<small> / {sizes['companion']}</small></dd></div>
            <div><dt>Obsession</dt><dd>#{r['obsession_rank']}<small> / {sizes['obsession']}</small></dd></div>
            <div><dt>Sought</dt><dd>#{r['sought_rank']}<small> / {sizes['sought']}</small></dd></div>
          </dl>
        </article>"""
        for r in data["core"]
    )
    return section(
        "core",
        "The core",
        f"{len(data['core'])} songs that matter in every way",
        "In the top 100 of all three song dimensions at once: with you for years, binged on loop, "
        "and sought out on purpose. The three dimensions barely overlap, so these few are rare.",
        f'<div class="core-grid">{cards}</div>',
        "--core",
    )


def render_eras(data) -> str:
    by_year: dict[int, list] = {}
    for r in data["eras"]:
        by_year.setdefault(r["year"], []).append(r)
    top = max(r["binge_days"] for r in data["eras"])
    rows = []
    for year, songs in by_year.items():
        entries = "".join(
            f"""
            <li>
              <span class="era-song"><strong>{esc(s['title'])}</strong> <span class="artist">{esc(s['artist'])}</span></span>
              <span class="era-bar" style="--w:{100 * s['binge_days'] / top:.0f}%"></span>
              <span class="era-n">{s['binge_days']}</span>
            </li>"""
            for s in songs
        )
        rows.append(f'<div class="era"><h3>{year}</h3><ul>{entries}</ul></div>')
    return section(
        "eras",
        "Eras",
        "The songs of each year",
        "Each year's most binged songs, by number of binge days (a day with 3 or more plays). "
        "Read top to bottom, it's the soundtrack of your chapters.",
        f'<div class="eras">{"".join(rows)}</div>',
        "--obsession",
    )


def render_map(data) -> str:
    size, pad = 560, 44
    span = size - 2 * pad

    def jitter(song_id: str, axis: int) -> float:
        h = hashlib.md5(f"{song_id}{axis}".encode()).digest()[0]
        return (h / 255 - 0.5) * 0.03

    colors = {
        "core": "var(--core)",
        "companion": "var(--companion)",
        "obsession": "var(--obsession)",
        "companion + obsession": "var(--both)",
    }
    dots = []
    for r in data["map"]:
        x = (r["companion_pct"] or 0) + (jitter(r["song_id"], 0) if r["companion_pct"] is None else 0)
        y = (r["obsession_pct"] or 0) + (jitter(r["song_id"], 1) if r["obsession_pct"] is None else 0)
        base = r["profile"].replace(" + sought", "")
        color = colors.get(base, "var(--muted)")
        cx, cy = pad + max(x, 0) * span, size - pad - max(y, 0) * span
        ring = ' stroke="var(--sought)" stroke-width="2"' if r["is_sought"] else ""
        radius = 6 if r["profile"] == "core" else 4
        dots.append(
            f'<circle cx="{cx:.1f}" cy="{cy:.1f}" r="{radius}" fill="{color}"{ring}>'
            f'<title>{esc(r["title"])} — {esc(r["artist"])} ({esc(r["profile"])})</title></circle>'
        )
    axes = f"""
      <line x1="{pad}" y1="{size - pad}" x2="{size - pad}" y2="{size - pad}" class="axis"/>
      <line x1="{pad}" y1="{pad}" x2="{pad}" y2="{size - pad}" class="axis"/>
      <text x="{size / 2}" y="{size - 10}" text-anchor="middle" class="axis-label">Companion → (top right of its ranking)</text>
      <text x="14" y="{size / 2}" text-anchor="middle" class="axis-label" transform="rotate(-90 14 {size / 2})">Obsession →</text>"""
    legend = "".join(
        f'<span><i style="background:{c}"></i>{esc(name)}</span>'
        for name, c in [
            ("companion", "var(--companion)"),
            ("obsession", "var(--obsession)"),
            ("both", "var(--both)"),
            ("core", "var(--core)"),
        ]
    ) + '<span><i class="ring"></i>also sought</span>'
    body = f"""
      <div class="map-wrap">
        <svg viewBox="0 0 {size} {size}" role="img" aria-label="Songs placed by companion and obsession ranking">
          {axes}{''.join(dots)}
        </svg>
        <div class="legend">{legend}</div>
      </div>"""
    return section(
        "map",
        "The map",
        "Regularity and intensity rarely meet",
        "Every song in the top 100 of companion or obsession, placed by its position in each ranking "
        "(songs not in a ranking sit on its axis). Hover a dot for the song. The empty middle is the point: "
        "the songs you live with and the songs you binge are mostly different songs. "
        "For the full 3D view, run <code>just explore</code>.",
        body,
        "--both",
    )


def render_works(data) -> str:
    items = []
    for i, w in enumerate(data["works"], 1):
        chips = "".join(f"<span class='chip'>{esc(p)}</span>" for p in w["performer_plays"][:5])
        items.append(
            f"""
            <li>
              <span class="rank">{i}</span>
              <div class="entry">
                <div class="name"><strong>{esc(w['work_title'])}</strong></div>
                <div class="why">{w['adopted_performers']} performers adopted · {w['total_plays']} plays</div>
                <div class="chips">{chips}</div>
              </div>
            </li>"""
        )
    return section(
        "works",
        "Beyond the artist",
        "Works you love whoever sings them",
        "Compositions you played by several performers, 3 times or more each: love that transcends the original.",
        f'<ol class="ranked">{"".join(items)}</ol>',
        "--work",
    )


def render(data) -> str:
    o, sizes = data["overview"], data["sizes"]
    companion = ranked_list(
        data["companion"],
        "--companion",
        "title",
        "artist",
        lambda r: f"With you since {r['since']} · played {r['post_honeymoon_active_months']} of the "
        f"{r['post_honeymoon_months']} months after the honeymoon",
    )
    obsession = ranked_list(
        data["obsession"],
        "--obsession",
        "title",
        "artist",
        lambda r: f"{r['binge_days']} binge days over {r['binge_months']} months · up to {r['max_day']:g} plays "
        f"in a day · {years(r['from_year'], r['to_year'])}",
    )
    sought = ranked_list(
        data["sought"],
        "--sought",
        "title",
        "artist",
        lambda r: f"Picked {r['picked_plays']} of {r['total_plays']} plays yourself"
        + (f" · {r['album_sought_plays']} inside albums you started" if r["album_sought_plays"] else "")
        + f" · {r['skipped_plays']} skip{'s' if r['skipped_plays'] != 1 else ''}",
    )
    albums = ranked_list(
        data["albums"],
        "--album",
        "album",
        "album_artist",
        lambda r: f"{r['sessions']} listens as a whole over {r['session_months']} months · up to "
        f"{r['longest_run']} tracks in a row · {years(r['from_year'], r['to_year'])}",
    )

    sections = [
        render_core(data),
        section(
            "companion",
            "Companions · regularity",
            "The songs you live with",
            "Not a fad: songs you kept coming back to, month after month, long after the first months of "
            "infatuation. How long they've been with you counts, up to 3 years; after that, they've proven it.",
            companion,
            "--companion",
        ),
        section(
            "obsession",
            "Obsessions · intensity",
            "The songs you played on loop",
            "Songs consumed intensely, whether old or new: days with 3 or more plays, in how many different "
            "months, and the most intense day. A binge inside a whole-album session counts half: that one is "
            "the album's.",
            obsession,
            "--obsession",
        ),
        section(
            "sought",
            "Sought · choice",
            "The songs you seek out",
            "When they play, it's because you picked them, not because autoplay or shuffle served them. "
            "A track inside an album you started counts as half a pick.",
            sought,
            "--sought",
        ),
        render_eras(data),
        render_map(data),
        section(
            "albums",
            "Albums",
            "Albums you live in",
            "Albums listened to as a whole: 3 or more of their tracks in a row, shuffled or not.",
            albums,
            "--album",
        ),
        render_works(data),
    ]

    nav = "".join(
        f'<a href="#{i}">{label}</a>'
        for i, label in [
            ("core", "Core"), ("companion", "Companions"), ("obsession", "Obsessions"), ("sought", "Sought"),
            ("eras", "Eras"), ("map", "Map"), ("albums", "Albums"), ("works", "Works"),
        ]
    )
    return f"""<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Your music</title>
<style>{CSS}</style>
</head>
<body>
<header class="hero">
  <p class="eyebrow">Your music · {o['first_play']:%B %Y} – {o['last_play']:%B %Y}</p>
  <h1>What your songs mean to you</h1>
  <p class="lede">Not just what you played most: <em>how</em> each song matters. The songs you live with,
  the ones you binge on loop, the ones you seek out, and the albums and works that go beyond a single song.</p>
  <dl class="stats">
    <div><dt>Plays</dt><dd>{o['plays']:,}</dd></div>
    <div><dt>Hours</dt><dd>{o['hours']:,.0f}</dd></div>
    <div><dt>Songs</dt><dd>{o['songs']:,}</dd></div>
    <div><dt>Artists</dt><dd>{o['artists']:,}</dd></div>
  </dl>
  <nav>{nav}</nav>
</header>
<main>
{''.join(sections)}
</main>
<footer>
  Generated {dt.date.today():%d %B %Y} from <code>spotify.duckdb</code> · thresholds and weights in
  <code>src/params.sql</code> · explore further with <code>just explore</code>
</footer>
</body>
</html>
"""


CSS = """
:root {
  --bg: #faf8f5; --surface: #ffffff; --text: #1c1b1a; --muted: #6b6762; --line: #e6e1da;
  --companion: #0f8a7e; --obsession: #d1495b; --sought: #6c4fd1; --both: #b0613a;
  --core: #c99a06; --album: #b7791f; --work: #2f6fb3;
  color-scheme: light;
}
@media (prefers-color-scheme: dark) {
  :root {
    --bg: #141312; --surface: #1d1c1a; --text: #f2efe9; --muted: #a29d96; --line: #2f2d2a;
    --companion: #3cc4b4; --obsession: #f07282; --sought: #a08cf5; --both: #e39468;
    --core: #f2c94c; --album: #e3a948; --work: #6fa8e8;
    color-scheme: dark;
  }
}
* { box-sizing: border-box; }
body {
  margin: 0; background: var(--bg); color: var(--text);
  font: 16px/1.55 system-ui, -apple-system, "Segoe UI", "Hiragino Sans", "Noto Sans JP", sans-serif;
  padding: 0 clamp(16px, 4vw, 48px);
}
.hero, main, footer { max-width: 920px; margin: 0 auto; }
.hero { padding: clamp(40px, 8vw, 96px) 0 24px; }
h1 { font-size: clamp(2rem, 5vw, 3.4rem); line-height: 1.08; margin: 0.2em 0 0.4em; letter-spacing: -0.02em; }
h2 { font-size: clamp(1.5rem, 3.2vw, 2.1rem); line-height: 1.15; margin: 0.1em 0 0.4em; letter-spacing: -0.01em; }
h3 { margin: 0; }
.eyebrow { text-transform: uppercase; letter-spacing: 0.12em; font-size: 0.78rem; font-weight: 600; color: var(--accent, var(--muted)); margin: 0; }
.lede { color: var(--muted); max-width: 62ch; font-size: 1.05rem; }
code { font-size: 0.9em; background: var(--line); padding: 0.1em 0.35em; border-radius: 4px; }
.stats { display: grid; grid-template-columns: repeat(auto-fit, minmax(130px, 1fr)); gap: 12px; margin: 32px 0; }
.stats div { background: var(--surface); border: 1px solid var(--line); border-radius: 12px; padding: 14px 16px; }
.stats dt { color: var(--muted); font-size: 0.85rem; }
.stats dd { margin: 0; font-size: 1.7rem; font-weight: 700; font-variant-numeric: tabular-nums; }
nav { display: flex; flex-wrap: wrap; gap: 8px; }
nav a { color: var(--text); text-decoration: none; border: 1px solid var(--line); border-radius: 999px; padding: 4px 12px; font-size: 0.9rem; }
nav a:hover { border-color: var(--text); }
section { padding: 56px 0 8px; border-top: 1px solid var(--line); margin-top: 40px; }
.ranked { list-style: none; padding: 0; margin: 24px 0 0; display: grid; gap: 14px; }
.ranked li { display: grid; grid-template-columns: 2.2em 1fr; gap: 12px; align-items: start; }
.rank { font-size: 1.3rem; font-weight: 700; color: var(--accent); font-variant-numeric: tabular-nums; text-align: right; line-height: 1.3; }
.name strong { font-size: 1.05rem; }
.artist { color: var(--muted); margin-left: 0.5em; }
.why { color: var(--muted); font-size: 0.92rem; }
.bar { height: 4px; border-radius: 2px; background: var(--line); margin-top: 6px; position: relative; overflow: hidden; }
.bar::after { content: ""; position: absolute; inset: 0; width: var(--w); background: var(--c); border-radius: 2px; }
.core-grid { display: grid; grid-template-columns: repeat(auto-fit, minmax(240px, 1fr)); gap: 14px; margin-top: 24px; }
.core-card { background: var(--surface); border: 1px solid var(--line); border-top: 4px solid var(--core); border-radius: 12px; padding: 16px 18px; }
.core-card .artist { margin: 0.2em 0 0.8em; display: block; }
.core-card dl { display: grid; grid-template-columns: repeat(3, 1fr); gap: 8px; margin: 0; }
.core-card dt { font-size: 0.75rem; color: var(--muted); }
.core-card dd { margin: 0; font-weight: 700; font-variant-numeric: tabular-nums; }
.core-card small { color: var(--muted); font-weight: 400; }
.core-card div:nth-child(1) dd { color: var(--companion); }
.core-card div:nth-child(2) dd { color: var(--obsession); }
.core-card div:nth-child(3) dd { color: var(--sought); }
.eras { display: grid; gap: 18px; margin-top: 24px; }
.era { display: grid; grid-template-columns: 4.5em 1fr; gap: 12px; align-items: start; }
.era h3 { font-size: 1.4rem; color: var(--accent); font-variant-numeric: tabular-nums; }
.era ul { list-style: none; margin: 0; padding: 0; display: grid; gap: 6px; }
.era li { display: grid; grid-template-columns: minmax(0, 1.4fr) minmax(60px, 1fr) 2em; gap: 10px; align-items: center; }
.era-song { overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
.era-bar { height: 8px; border-radius: 4px; background: var(--line); position: relative; overflow: hidden; }
.era-bar::after { content: ""; position: absolute; inset: 0; width: var(--w); background: var(--accent); border-radius: 4px; }
.era-n { color: var(--muted); font-variant-numeric: tabular-nums; text-align: right; font-size: 0.9rem; }
.map-wrap { margin-top: 20px; }
.map-wrap svg { width: 100%; max-width: 560px; height: auto; display: block; background: var(--surface); border: 1px solid var(--line); border-radius: 12px; }
.axis { stroke: var(--line); stroke-width: 1.5; }
.axis-label { fill: var(--muted); font-size: 13px; }
circle { opacity: 0.85; }
circle:hover { opacity: 1; stroke: var(--text); stroke-width: 2; }
.legend { display: flex; flex-wrap: wrap; gap: 14px; margin-top: 12px; color: var(--muted); font-size: 0.9rem; }
.legend i { display: inline-block; width: 10px; height: 10px; border-radius: 50%; margin-right: 6px; vertical-align: middle; }
.legend i.ring { border: 2px solid var(--sought); width: 8px; height: 8px; }
.chips { display: flex; flex-wrap: wrap; gap: 6px; margin-top: 6px; }
.chip { font-size: 0.82rem; border: 1px solid var(--line); background: var(--surface); border-radius: 999px; padding: 2px 10px; }
footer { color: var(--muted); font-size: 0.85rem; padding: 48px 0 64px; border-top: 1px solid var(--line); margin-top: 48px; }
@media (max-width: 520px) {
  .era { grid-template-columns: 1fr; gap: 4px; }
  .era li { grid-template-columns: minmax(0, 1fr) 70px 2em; }
  .artist { display: block; margin-left: 0; }
}
"""


def main() -> None:
    OUT.parent.mkdir(exist_ok=True)
    OUT.write_text(render(load()), encoding="utf-8")
    print(f"Wrote {OUT}")


if __name__ == "__main__":
    main()
