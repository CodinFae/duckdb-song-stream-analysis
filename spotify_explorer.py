import marimo

__generated_with = "0.25.2"
app = marimo.App(width="medium")


@app.cell
def _():
    # Load the duckdb
    import marimo as mo
    import duckdb

    connection = duckdb.connect("spofity.duckdb")
    return connection, mo


@app.cell
def _(connection, mo):
    _df = mo.sql(
        f"""
        SELECT * FROM "spofity"."main"."mart_obsession" ORDER BY score DESC
        """,
        engine=connection
    )
    return


@app.cell
def _(connection, mo):
    _df = mo.sql(
        f"""
        SELECT * FROM 
        """,
        engine=connection
    )
    return


if __name__ == "__main__":
    app.run()
