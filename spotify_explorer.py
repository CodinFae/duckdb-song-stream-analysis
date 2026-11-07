import marimo

__generated_with = "0.25.2"
app = marimo.App(width="full", app_title="Spotify explorer")


@app.cell
def _():
    import csv
    import datetime as dt
    import random
    import re

    import duckdb
    import marimo as mo
    import numpy as np
    import plotly.express as px
    import polars as pl

    ROOT = mo.notebook_dir()
    DB_PATH = str(ROOT / "spotify.duckdb")
    JUDGMENTS = ROOT / "seeds" / "judgments.csv"

    def q(sql, params=None):
        # A short-lived read-only connection per query: DuckDB lets no process write while another
        # holds the file open (even read-only), so `just build` can run between two queries
        with duckdb.connect(DB_PATH, read_only=True) as con:
            return con.sql(sql, params=params or []).pl()

    return JUDGMENTS, ROOT, csv, dt, mo, np, pl, px, q, random, re


@app.cell
def _(ROOT, q, re):
    # The five dimensions: where each one lives, its score components, and the current weights
    # (read from src/params.sql, the single source of truth)
    MARTS = {
        "companion": {
            "table": "mart_long_standing",
            "id": "song_id",
            "label": "title || ' — ' || artist",
            "order": "score DESC, active_days DESC",
            "components": {"survival": "survival_rate", "proven": "proven"},
            "prefix": "long_standing_weight_",
            "question": "Which one is more of a companion of your life?",
        },
        "obsession": {
            "table": "mart_obsession",
            "id": "song_id",
            "label": "title || ' — ' || artist",
            "order": "score DESC, binge_days DESC",
            "components": {
                "binge_days": "binge_days_score",
                "recurrence": "recurrence_score",
                "intensity": "intensity_score",
            },
            "prefix": "obsession_weight_",
            "question": "Which one did you consume more intensely, on loop?",
        },
        "sought": {
            "table": "mart_intentionality",
            "id": "song_id",
            "label": "title || ' — ' || artist",
            "order": "score DESC",
            "components": {"selected": "selected_rate", "not_skipped": "1 - clicked_off_rate"},
            "prefix": "intentionality_weight_",
            "question": "Which one do you seek out more, on purpose?",
        },
        "work": {
            "table": "mart_work",
            "id": "work_id",
            "label": "work_title || ' — ' || main_performer",
            "order": "score DESC",
            "components": {
                "beyond_main": "beyond_main_score",
                "adopted": "adopted_score",
                "total": "total_score",
            },
            "prefix": "work_weight_",
            "question": "Which composition do you love more, whoever performs it?",
        },
        "album": {
            "table": "mart_album",
            "id": "album_id",
            "label": "album || ' — ' || album_artist",
            "order": "score DESC",
            "components": {
                "sessions": "sessions_score",
                "recurrence": "recurrence_score",
                "depth": "depth_score",
            },
            "prefix": "album_weight_",
            "question": "Which album do you live in more?",
        },
    }

    _params = dict(re.findall(r"SET VARIABLE (\w+) = ([0-9.]+);", (ROOT / "src" / "params.sql").read_text()))
    for _m in MARTS.values():
        _m["weights"] = {c: float(_params[_m["prefix"] + c]) for c in _m["components"]}
        _m["size"] = q(f"SELECT COUNT(*) AS n FROM {_m['table']}")["n"][0]

    def load_mart(name):
        """A mart's items with their score components and current rank."""
        m = MARTS[name]
        comps = ", ".join(f"{expr} AS {key}" for key, expr in m["components"].items())
        return q(
            f"SELECT {m['id']} AS id, {m['label']} AS item, {comps}, score, "
            f"row_number() OVER (ORDER BY {m['order']}, {m['id']}) AS rank "
            f"FROM {m['table']} ORDER BY rank"
        )

    def params_lines(name, weights):
        prefix = MARTS[name]["prefix"]
        return "\n".join(f"SET VARIABLE {prefix}{k} = {v:.2f};" for k, v in weights.items())

    return MARTS, load_mart, params_lines


@app.cell
def _(mo):
    mo.md("""
    # Spotify explorer

    Your listening, along five dimensions that barely overlap:
    **companion** (regularity, *"my morning song"*), **obsession** (intensity, *"my breakup song"*),
    **sought** (choice, *"I search for it"*), plus the **work** (a composition beyond its performers)
    and the **album** (albums you listen to as a whole).

    Sections: [Songs](#songs) · [Dimensions](#dimensions) · [Tune](#tune) · [3D](#3d) · [Judge](#judge).
    Everything reads `spotify.duckdb`; rebuild it anytime with `just build`.
    """)
    return


@app.cell
def _(mo):
    mo.md("""
    ## Songs
    Search a song, an artist or a work, then pick one to see **why** it ranks where it does.
    """)
    return


@app.cell
def _(mo):
    search = mo.ui.text(placeholder="Search a song, an artist or a work…", full_width=True)
    search
    return (search,)


@app.cell
def _(mo, q, search):
    _term = search.value.strip()
    _like = f"%{_term}%"
    _songs = q(
        """
        SELECT title, artist, profile, plays,
            companion_rank, obsession_rank, sought_rank,
            work_title AS work, album, song_id
        FROM mart_song_profile
        WHERE ? = '' OR title ILIKE ? OR artist ILIKE ? OR work_title ILIKE ?
        ORDER BY coalesce(companion_pct, 0) + coalesce(obsession_pct, 0) + coalesce(sought_pct, 0) DESC,
            plays DESC
        LIMIT 200
        """,
        [_term, _like, _like, _like],
    )
    song_table = mo.ui.table(_songs, selection="single", page_size=10, hidden_columns=["song_id"])
    song_table
    return (song_table,)


@app.cell
def _(MARTS, mo, q, song_table):
    def _rank(rank, name):
        return f"**#{rank}** of {MARTS[name]['size']}" if rank is not None else "not in it"

    def song_card(song_id):
        p = q("SELECT * FROM mart_song_profile WHERE song_id = ?", [song_id]).row(0, named=True)
        ls = q("SELECT * FROM int_long_standing WHERE song_id = ?", [song_id]).to_dicts()
        ob = q("SELECT * FROM int_obsession WHERE song_id = ?", [song_id]).to_dicts()
        it = q("SELECT * FROM int_intentionality WHERE song_id = ?", [song_id]).to_dicts()
        wk = q(
            """SELECT w.*, r.rank FROM int_work w
            LEFT JOIN (SELECT work_id, row_number() OVER (ORDER BY score DESC, work_id) AS rank FROM mart_work) r
                USING (work_id)
            WHERE work_id = ?""",
            [p["work_id"]],
        ).to_dicts()
        al = q(
            """SELECT a.*, r.rank FROM int_album a
            LEFT JOIN (SELECT album_id, row_number() OVER (ORDER BY score DESC, album_id) AS rank FROM mart_album) r
                USING (album_id)
            WHERE album_id = ?""",
            [p["album_id"]],
        ).to_dicts()

        rows = []
        if ls:
            l = ls[0]
            survival = f"{l['survival_rate']:.0%}" if l["survival_rate"] is not None else "–"
            rows.append(
                f"| Companion | {_rank(p['companion_rank'], 'companion')} | {l['lifetime_months']} months of life, "
                f"played {l['post_honeymoon_active_months']} of {l['post_honeymoon_months']} months after the "
                f"honeymoon ({survival}), on {l['active_days']} days |"
            )
        if ob:
            o = ob[0]
            rows.append(
                f"| Obsession | {_rank(p['obsession_rank'], 'obsession')} | {o['binge_days']} binge days over "
                f"{o['binge_months']} months, up to {o['max_day']:g} plays in a day |"
            )
        if it:
            i = it[0]
            rows.append(
                f"| Sought | {_rank(p['sought_rank'], 'sought')} | {i['picked_plays']} of {i['total_plays']} plays "
                f"picked yourself, {i['album_sought_plays']} inside your album sessions, {i['skipped_plays']} skips |"
            )
        if wk:
            w = wk[0]
            rank = f"**#{w['rank']}** of {MARTS['work']['size']}" if w["rank"] else "not in it"
            rows.append(
                f"| Work: *{w['work_title']}* | {rank} | {w['adopted_performers']} performers adopted: "
                f"{', '.join(w['performer_plays'][:5])} |"
            )
        if al:
            a = al[0]
            rank = f"**#{a['rank']}** of {MARTS['album']['size']}" if a["rank"] else "not in it"
            rows.append(
                f"| Album: *{a['album']}* | {rank} | {a['sessions']} album sessions over {a['session_months']} "
                f"months, up to {a['longest_run']} tracks in a row |"
            )
        elif p["album"] is None:
            rows.append("| Album | – | never listened to as a whole |")

        return mo.md(
            f"""
    ### {p['title']} — {p['artist']}
    **Profile: {p['profile']}** · {p['plays']} plays · {p['first_play']:%Y-%m} → {p['last_play']:%Y-%m}

    | Dimension | Rank | Why |
    |---|---|---|
    """
            + "\n".join(rows)
        )

    _selected = song_table.value
    song_card(_selected["song_id"][0]) if len(_selected) else mo.md("*Pick a song in the table to see its card.*")
    return


@app.cell
def _(MARTS, mo):
    mo.md("""
    ## Dimensions
    The full ranking of one dimension, and how its scores are spread.
    """)
    dimension_pick = mo.ui.dropdown(list(MARTS), value="companion", label="Dimension")
    dimension_pick
    return (dimension_pick,)


@app.cell
def _(dimension_pick, load_mart, mo, px):
    _df = load_mart(dimension_pick.value)
    _hist = px.histogram(_df, x="score", nbins=40, height=260)
    _hist.update_layout(margin=dict(l=10, r=10, t=10, b=10), bargap=0.05)
    mo.hstack(
        [mo.ui.table(_df.drop("id"), page_size=15, selection=None), _hist],
        widths=[2, 1],
        align="start",
    )
    return


@app.cell
def _(MARTS, mo):
    mo.md("""
    ## Tune
    Move the weights of a dimension and see how its top 20 changes. Weights are normalized to sum
    to 1; copy the lines into `src/params.sql` to keep them.
    """)
    tune_pick = mo.ui.dropdown(list(MARTS), value="obsession", label="Dimension")
    tune_pick
    return (tune_pick,)


@app.cell
def _(MARTS, mo, tune_pick):
    tune_weights = mo.ui.dictionary(
        {
            k: mo.ui.slider(0, 1, 0.05, value=v, show_value=True, label=k.replace("_", " "))
            for k, v in MARTS[tune_pick.value]["weights"].items()
        }
    )
    tune_weights.hstack()
    return (tune_weights,)


@app.cell
def _(load_mart, mo, params_lines, pl, tune_pick, tune_weights):
    _total = sum(tune_weights.value.values()) or 1
    _w = {k: v / _total for k, v in tune_weights.value.items()}
    _df = load_mart(tune_pick.value)
    _df = (
        _df.with_columns(new_score=sum(pl.col(k) * w for k, w in _w.items()))
        .with_columns(new_rank=pl.col("new_score").rank("ordinal", descending=True).cast(pl.Int64))
        .sort("new_rank")
    )
    _top = _df.filter(pl.col("new_rank") <= 20).with_columns(
        move=pl.when(pl.col("rank") > 20)
        .then(pl.format("new (was #{})", pl.col("rank")))
        .when(pl.col("rank") > pl.col("new_rank"))
        .then(pl.format("▲ {}", pl.col("rank") - pl.col("new_rank")))
        .when(pl.col("rank") < pl.col("new_rank"))
        .then(pl.format("▼ {}", pl.col("new_rank") - pl.col("rank")))
        .otherwise(pl.lit("="))
    )
    _kept = _df.filter((pl.col("new_rank") <= 20) & (pl.col("rank") <= 20)).height
    _out = _df.filter((pl.col("rank") <= 20) & (pl.col("new_rank") > 20)).select("item", "rank", "new_rank")
    mo.vstack(
        [
            mo.hstack(
                [
                    mo.stat(f"{_kept}/20", label="Current top 20 kept"),
                    mo.md(f"```sql\n{params_lines(tune_pick.value, _w)}\n```"),
                ],
                justify="start",
                gap=2,
            ),
            mo.ui.table(
                _top.select("new_rank", "item", "move", pl.col("new_score").round(3), *_w.keys()),
                selection=None,
                page_size=20,
            ),
            mo.md("**Leaving the top 20:** " + (", ".join(f"{r['item']} (→ #{r['new_rank']})" for r in _out.to_dicts()) or "none")),
        ]
    )
    return


@app.cell
def _(mo):
    mo.md("""
    ## 3D
    Each song placed by its position in the three song dimensions (1 = top of the dimension,
    0 = not in it). Drag to rotate, hover for the title.
    """)
    strong_only = mo.ui.switch(value=True, label="Only songs in the top of at least one dimension")
    strong_only
    return (strong_only,)


@app.cell
def _(mo, px, q, strong_only):
    _df = q(
        f"""
        SELECT title, artist, profile, plays,
            coalesce(companion_pct, 0) AS companion,
            coalesce(obsession_pct, 0) AS obsession,
            coalesce(sought_pct, 0) AS sought
        FROM mart_song_profile
        WHERE {"profile != 'none'" if strong_only.value else "coalesce(companion_pct, obsession_pct, sought_pct) IS NOT NULL"}
        """
    )
    _fig = px.scatter_3d(
        _df,
        x="companion",
        y="obsession",
        z="sought",
        color="profile",
        hover_name="title",
        hover_data={"artist": True, "plays": True, "profile": False},
        height=650,
        opacity=0.8,
    )
    _fig.update_traces(marker=dict(size=4))
    _fig.update_layout(margin=dict(l=0, r=0, t=0, b=0), legend=dict(itemsizing="constant"))
    mo.ui.plotly(_fig)
    return


@app.cell
def _(MARTS, mo):
    mo.md("""
    ## Judge
    Pick the one that matters more **to you**, by gut feeling. Each answer goes to
    `seeds/judgments.csv`; after about 10 per dimension, the weights that best reproduce your choices
    are learned below. Pairs are chosen where the components disagree, so each answer is informative.
    """)
    judge_pick = mo.ui.dropdown(list(MARTS), value="obsession", label="Dimension")
    judge_pick
    return (judge_pick,)


@app.cell
def _(MARTS, judge_pick, load_mart, mo, random):
    _pool = load_mart(judge_pick.value).head(150).to_dicts()
    _keys = list(MARTS[judge_pick.value]["components"])

    def draw_pair():
        """Two items where neither is better on every component."""
        for _ in range(500):
            a, b = random.sample(_pool, 2)
            diffs = [a[k] - b[k] for k in _keys]
            if any(d > 0 for d in diffs) and any(d < 0 for d in diffs):
                return a, b
        return tuple(random.sample(_pool, 2))

    get_pair, set_pair = mo.state(draw_pair())
    return draw_pair, get_pair, set_pair


@app.cell
def _(JUDGMENTS, csv, draw_pair, dt, get_pair, judge_pick, mo, set_pair):
    def _answer(winner):
        def _on_click(_):
            a, b = get_pair()
            if winner is not None:
                new_file = not JUDGMENTS.exists()
                with JUDGMENTS.open("a", newline="") as f:
                    writer = csv.writer(f)
                    if new_file:
                        writer.writerow(["judged_at", "dimension", "a_id", "b_id", "winner", "a_item", "b_item"])
                    writer.writerow(
                        [dt.datetime.now().isoformat(timespec="seconds"), judge_pick.value,
                         a["id"], b["id"], winner, a["item"], b["item"]]
                    )
            set_pair(draw_pair())

        return _on_click

    pick_a = mo.ui.button(label="◀ This one", kind="success", on_click=_answer("a"))
    pick_b = mo.ui.button(label="This one ▶", kind="success", on_click=_answer("b"))
    skip = mo.ui.button(label="Can't tell, next pair", on_click=_answer(None))
    return pick_a, pick_b, skip


@app.cell
def _(MARTS, get_pair, judge_pick, mo, pick_a, pick_b, skip):
    _a, _b = get_pair()
    mo.vstack(
        [
            mo.md(f"### {MARTS[judge_pick.value]['question']}"),
            mo.hstack(
                [
                    mo.callout(mo.vstack([mo.md(f"**{_a['item']}**"), pick_a]), kind="neutral"),
                    mo.callout(mo.vstack([mo.md(f"**{_b['item']}**"), pick_b]), kind="neutral"),
                ],
                widths="equal",
                gap=2,
            ),
            skip,
        ]
    )
    return


@app.cell
def _(JUDGMENTS, MARTS, get_pair, judge_pick, load_mart, mo, np, params_lines, pl):
    get_pair()  # re-run after every answer

    def fit_weights(X, y, l2=0.1, iterations=50):
        """Logistic regression without intercept on component differences (Newton's method)."""
        beta = np.zeros(X.shape[1])
        for _ in range(iterations):
            p = 1 / (1 + np.exp(-X @ beta))
            gradient = X.T @ (y - p) - l2 * beta
            hessian = -(X.T * (p * (1 - p))) @ X - l2 * np.eye(X.shape[1])
            beta = beta - np.linalg.solve(hessian, gradient)
        return beta

    def agreement(X, y, w):
        """Share of your answers the weights reproduce (ties count half)."""
        s = np.sign(X @ w)
        return float(np.mean(np.where(s == 0, 0.5, s == (2 * y - 1))))

    _m = MARTS[judge_pick.value]
    _keys = list(_m["components"])
    _min_answers = 10
    _answers = (
        pl.read_csv(JUDGMENTS, schema_overrides={"a_id": pl.Utf8, "b_id": pl.Utf8}).filter(
            pl.col("dimension") == judge_pick.value
        )
        if JUDGMENTS.exists()
        else pl.DataFrame()
    )

    if _answers.height < _min_answers:
        _view = mo.callout(
            mo.md(f"**{_answers.height}** answers for *{judge_pick.value}*: "
                  f"{_min_answers - _answers.height} more before learning its weights."),
            kind="info",
        )
    else:
        _comp = load_mart(judge_pick.value).select("id", *_keys)
        _j = (
            _answers.join(_comp, left_on="a_id", right_on="id")
            .join(_comp, left_on="b_id", right_on="id", suffix="_b")
        )
        _X = np.column_stack([_j[k].to_numpy() - _j[f"{k}_b"].to_numpy() for k in _keys])
        _y = (_j["winner"] == "a").to_numpy().astype(float)
        _beta = fit_weights(_X, _y)
        _learned = np.clip(_beta, 0, None)
        _learned = _learned / _learned.sum() if _learned.sum() > 0 else np.full(len(_keys), 1 / len(_keys))
        _current = np.array([_m["weights"][k] for k in _keys])
        _view = mo.vstack(
            [
                mo.hstack(
                    [
                        mo.stat(_j.height, label="Answers used"),
                        mo.stat(f"{agreement(_X, _y, _current):.0%}", label="Agreement, current weights"),
                        mo.stat(f"{agreement(_X, _y, _learned):.0%}", label="Agreement, learned weights"),
                    ],
                    justify="start",
                    gap=2,
                ),
                mo.ui.table(
                    pl.DataFrame(
                        {
                            "component": _keys,
                            "current": _current.round(2),
                            "learned": _learned.round(2),
                            "raw coefficient": _beta.round(2),
                        }
                    ),
                    selection=None,
                ),
                mo.md(
                    "A negative raw coefficient means that component works *against* your choices.\n\n"
                    f"```sql\n{params_lines(judge_pick.value, dict(zip(_keys, _learned)))}\n```"
                ),
            ]
        )
    _view
    return


if __name__ == "__main__":
    app.run()
