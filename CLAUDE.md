# Spotify OLAP

Personal analysis of a Spotify "Extended streaming history" export with DuckDB: not what was
played most, but *how* each song matters. SQL pipeline + marimo explorer + local HTML story.

## Commands

```sh
just build               # rebuild spotify.duckdb from data/*.json (run.sql: params -> raw -> stg -> int -> marts)
just report <mart>       # top 20 of a mart (reports/<mart>.sql); `just reports` for all
just top25               # out/top25.md: top 25 of each song dimension with context, for analysis
just story               # out/story.html: the story page
just explore             # marimo explorer app (song cards, tuning, 3D, pairwise judge)
just shell               # DuckDB shell
```

DuckDB CLI is v2.0. In Python (duckdb 2.0): use `con.sql(...).pl()`, not `con.execute(...).pl()`.
Timestamps are TIMESTAMPTZ: cast to DATE in SQL before fetching in Python (no pytz installed).

## Layout

- `src/params.sql`: every threshold and weight (`SET VARIABLE`), read with `getvariable()`. Never hard-code a number in a model.
- `src/stg.sql`: one row per song play (podcasts out), dedupes plays Spotify logged twice.
- `src/int_song.sql`: identity. `song_id` = one work by one artist (merges releases, remasters, edits, feat., source tags, romanizations; covers/live/remix/language versions stay separate). `work_id` = the composition across performers and versions. Manual fixes in `seeds/*.csv`.
- `src/int_album_play.sql`: album sessions (3+ different tracks of an album in a row, <20 min gaps), and whether you started them.
- `src/mart/*.sql`: one file per dimension (`int_` metrics, then `mart_` 0-1 score), plus `song_profile.sql`.
- `reports/`: report queries (not run by the build). `story.py`, `spotify_explorer.py`: the two front-ends.

## The dimensions (the user's own definitions)

| Mart | Dimension | Meaning | Measured by |
|---|---|---|---|
| `mart_long_standing` | companion, regularity | "my morning song, I love it because it makes me feel things": not a fad | share of months played after a 3-month honeymoon (survival) + lifetime capped at 3 years; no recency ("in my life") |
| `mart_obsession` | intensity | "my breakup song, when I'm sad I listen to it in loops", old or new | binge days (3+ plays a day), binge months, most plays in a day |
| `mart_intentionality` | choice, "sought" | songs the user seeks out "by song or by playlist" | share of plays started by click/play/back; tracks inside an album session they started count half |
| `mart_work` | love of the work | a composition loved beyond its performers | performers adopted (3+ plays), plays beyond the main version |
| `mart_album` | albums lived in | albums listened to as a whole (mostly soundtracks) | album sessions, recurrence across months, longest run |
| `mart_song_profile` | all | every song's rank per dimension; profile = dimensions it's top 100 in, `core` = all three | |

The three song dimensions barely overlap: that is a finding, not a bug.

## Decisions and why (don't undo without asking)

- `trackdone` (song followed the previous one) is **neutral** for intentionality: the export can't tell the user's own playlist from an album or radio. No playlist API.
- Plays under 10s are "not now" skips (shuffle served a song): ignored, neither a listen nor a rejection.
- Album-session plays count half in obsession (the binge belongs to the album) and half as a pick in intentionality.
- Artist changes under one `track_id` are often album-artist changes (Atlus Sound Team -> Lyn), not renames: artist aliases are manual only. Title renames are safe and automatic.
- Rejected after testing on the data: time-of-day rituals (no signal), places (99% one country), offline/incognito (unused), absorption/completion (confounded by song length without durations), session opener (sub-signal of choice), weekly #1 charts (replaced by binge days).
- Weights barely matter within a reasonable range (83-98% of each top 20 stable); definitions matter. Better weights come from the explorer's pairwise judge (`seeds/judgments.csv`).

## Rules

- **Privacy: the data stays local.** `data/`, `*.duckdb`, `out/`, `seeds/judgments.csv` are gitignored. No cloud services or published pages with listening data (Evidence Studio was rejected for this).
- **Determinism**: break ties explicitly (`arg_max(x, row(plays, ...))`, `ORDER BY timestamp, event_id`). Two builds must be identical.
- **Refactors must not change results**: snapshot the tables to parquet before, compare after (`EXCEPT ALL` both ways).
- **Ranking changes**: show the before/after top 20 (moves, new, out) and let the user validate before committing.
- DuckDB allows no writer while any process holds the file, even read-only: front-ends use short-lived connections.
- `just fmt` is not applied yet (sqruff reports style warnings).

## Analysing the results

`just build && just top25`, then read `out/top25.md`. The `soundtrack` and `script` columns are heuristics
(documented in `reports/top25.sql`). Compare each top 25 with the overall shares at the end of the file.
