db := "spotify.duckdb"

# List available recipes
default:
    @just --list

# Rebuild every layer (raw -> stg -> mart) from data/*.json
build:
    duckdb {{db}} -c ".read run.sql"

# Generate the story page (out/story.html) from the marts
story:
    uv run python story.py

# Open the explorer as an app: songs, dimensions, tuning, 3D, judge
explore:
    uv run marimo run spotify_explorer.py

# Edit the explorer notebook
explore-edit:
    uv run marimo edit spotify_explorer.py

# Open an interactive DuckDB shell on the database
shell:
    duckdb {{db}}

# Print a mart's top 20: long_standing, obsession, intentionality, work or album
report name:
    duckdb -readonly {{db}} -c ".read reports/{{name}}.sql"

# Print every report
reports:
    for f in reports/*.sql; do echo "== $f"; duckdb -readonly {{db}} -c ".read $f"; done

# Lint SQL files
lint:
    uv run sqruff lint src/ reports/

# Auto-fix SQL formatting
fmt:
    uv run sqruff fix src/ reports/

# Delete the local database (rebuild with `just build`)
clean:
    rm -f {{db}} {{db}}.wal
