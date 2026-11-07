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
| `int_` / `mart_` | `src/mart/*.sql` | Per-track metrics, then percentile-based scores (0–1) |

## Marts

- **week_charts**: weekly top chart of your plays (`int_week_charts`).
- **long_standing**: songs that stayed with you over time: lifetime span, active
  days, active months and recency (90-day half-life).
- **obsession**: songs you binged: total plays, weeks at #1, peak weekly plays.
- **intentionality**: songs you choose on purpose (clicked, played, went back to)
  versus skipped, smoothed with a 20-play prior.

## Roadmap

- SQLMesh for models, dependencies and data audits
- sqruff via LSP / pre-commit
- marimo dashboards to tune score weights
