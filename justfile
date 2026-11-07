db := "spotify.duckdb"

# List available recipes
default:
    @just --list

# Rebuild every layer (raw -> stg -> mart) from data/*.json
build:
    duckdb {{db}} -c ".read run.sql"

# Open the marimo notebook to explore the marts
explore:
    uv run marimo edit spotify_explorer.py

# Open an interactive DuckDB shell on the database
shell:
    duckdb {{db}}

# Lint SQL files
lint:
    uv run sqruff lint src/

# Auto-fix SQL formatting
fmt:
    uv run sqruff fix src/

# Delete the local database (rebuild with `just build`)
clean:
    rm -f {{db}} {{db}}.wal
