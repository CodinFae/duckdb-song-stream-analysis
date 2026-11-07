# Spotify OLAP

Analyse your own Spotify streaming history with DuckDB to find the songs that
actually matter to you.

## Setup

1. Request your **Extended streaming history** from Spotify
   (Account → Privacy settings → Download your data).
2. Put the `Streaming_History_Audio_*.json` files in `data/`
   (it is gitignored: your data never leaves your machine).
3. Install the tools:
   - [uv](https://docs.astral.sh/uv/) → `uv sync`
   - [DuckDB CLI](https://duckdb.org/docs/installation/) → `brew install duckdb`
   - [just](https://just.systems) → `brew install just`

## Usage

```sh
just build    # rebuild spotify.duckdb from data/*.json (and print the reports)
just explore  # open the marimo notebook
just shell    # DuckDB shell on the database
just lint     # lint SQL with sqruff (`just fmt` to auto-fix)
```

## Layers

| Layer | File | Content |
|-------|------|---------|
| `raw_` | `src/raw.sql` | JSON export loaded as-is |
| `stg_` | `src/stg.sql` | One row per song play, renamed columns, podcasts removed. A play "counts" above 30s |
| `int_song` | `src/int_song.sql` | Song identity: one `song_id` per (artist, title), merging releases, remasters, edits, `feat.`, source/soundtrack tags and romanizations. Covers, live and alternative versions stay separate. Manual fixes in `seeds/artist_aliases.csv` and `seeds/title_aliases.csv` |
| `int_` / `mart_` | `src/mart/*.sql` | Per-song metrics (`int_`), then a 0–1 score (`mart_`) |

## Marts

- **long_standing**: companions of life, songs you keep coming back to: share of months
  played after the first 3 months (survival) and lifetime capped at 3 years. Songs under
  12 months are too young to tell.
- **obsession**: songs consumed intensely, on loop: days with 3+ plays (binge days), in how
  many different months, and the most plays in a day.
- **intentionality**: songs you pick on purpose (click, play, back button) rather than
  autoplay, and rarely skip. Smoothed with a 20-play prior, at least 10 plays.
- **work**: compositions you love beyond one performer: performers whose version you played
  3+ times, and plays beyond the main version. Translations and homonyms in `seeds/work_aliases.csv`.
- **album**: albums you listen to as a whole: sessions of 3+ different tracks in a row, in how
  many months, and the longest run.

## Roadmap

- SQLMesh for models, dependencies and data audits
- sqruff via LSP / pre-commit
- marimo dashboards to tune score weights
