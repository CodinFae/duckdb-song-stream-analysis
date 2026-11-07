import marimo

__generated_with = "0.25.2"
app = marimo.App(width="medium")


@app.cell
def _():
    # Load the duckdb
    import marimo as mo
    import duckdb

    # Read-only, so `just build` can run while the notebook is open
    connection = duckdb.connect("spotify.duckdb", read_only=True)
    return connection, mo


@app.cell
def _(connection, mo):
    _df = mo.sql(
        f"""
        SELECT * FROM mart_obsession ORDER BY score DESC
        """,
        engine=connection
    )
    return


if __name__ == "__main__":
    app.run()
