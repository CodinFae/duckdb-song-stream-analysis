"""What makes a song emotional to you? Reverse engineering from your own labels.

You label songs yes/no (in the explorer's Emotional section, saved to seeds/emotional.csv), and this
module looks for the metrics of mart_song_features that separate the yes from the no:

  * one metric at a time: how well each one alone sorts your yes above your no (AUC), with a
    bootstrap interval, so you can see which ones are more than noise
  * a sparse logistic regression (L1): the few metrics that matter together, and how stable
    each one is across resamples of your labels (stability selection)
  * a shallow decision tree on raw values: the "shapes", as readable rules
  * predictions: the songs the model thinks are emotional, to label next

Each answer records how the song was chosen (its `source`): the first batch, a random pick, the
importance order, or the model's own suggestions. Songs the model picked confirm its own guesses, so
every per-metric result is also computed on the unbiased answers alone. Cross-validation holds out
whole artists: your yes songs cluster by artist (soundtracks), and a model that only recognises an
artist it has seen hasn't learned anything about you.

Run `just emotional` for a text report, or use the explorer.
"""

import csv
import datetime as dt
from pathlib import Path

import numpy as np
import polars as pl
from scipy.stats import rankdata
from sklearn.linear_model import LogisticRegression
from sklearn.metrics import roc_auc_score
from sklearn.model_selection import StratifiedGroupKFold
from sklearn.tree import DecisionTreeClassifier, export_text

ROOT = Path(__file__).parent
LABELS = ROOT / "seeds" / "emotional.csv"
TABLE = "mart_song_features"
ID_COLUMNS = ["song_id", "title", "artist"]

# The order of the explorer's Songs table: songs strong in several dimensions first
IMPORTANCE_ORDER = (
    "coalesce(p.companion_pct, 0) + coalesce(p.obsession_pct, 0) + coalesce(p.sought_pct, 0) DESC, "
    "p.plays DESC, p.song_id"
)
FIRST_BATCH = 50  # label the top N important songs first
POOL = 250  # after the first batch, ask among the N most important songs (the model learned from those)
SEED = 0  # every resample is seeded: two runs on the same labels give the same results

# How a song came to be asked. The model's picks are biased towards what it already believes.
SOURCES = {
    "top": "first batch",
    "random": "random pick",
    "importance": "importance order",
    "likely": "model: most likely",
    "uncertain": "model: least sure",
}
MODEL_PICKED = {"likely", "uncertain"}
LABEL_COLUMNS = ["labelled_at", "song_id", "label", "item", "source"]


# Data -------------------------------------------------------------------------------------------


def load_features(q):
    """Every song's features, its importance rank, and the description of each feature.

    `q(sql)` runs a query and returns a polars DataFrame.
    """
    df = q(
        f"""
        SELECT f.*, row_number() OVER (ORDER BY {IMPORTANCE_ORDER}) AS importance_rank,
            year(p.first_play) AS since, year(p.last_play) AS last
        FROM {TABLE} f
        JOIN mart_song_profile p USING (song_id)
        ORDER BY importance_rank
        """
    )
    comments = q(
        f"SELECT column_name, comment FROM duckdb_columns() WHERE table_name = '{TABLE}' AND comment IS NOT NULL"
    )
    describe = dict(zip(comments["column_name"], comments["comment"]))
    return df, describe


def feature_names(describe):
    return [c for c in describe]


def load_labels(path=LABELS):
    """Your latest answer for each song (you can change your mind: the last one wins)."""
    if not path.exists():
        return pl.DataFrame(schema={"song_id": pl.Utf8, "label": pl.Utf8, "source": pl.Utf8})
    return (
        pl.read_csv(path, schema_overrides={"song_id": pl.Utf8, "source": pl.Utf8})
        .with_row_index("order")
        .sort("order")
        .group_by("song_id")
        .last()
        .select("song_id", "label", "source")
    )


def save_label(song_id, label, item, source, path=LABELS):
    new_file = not path.exists()
    with path.open("a", newline="") as f:
        writer = csv.writer(f)
        if new_file:
            writer.writerow(LABEL_COLUMNS)
        writer.writerow([dt.datetime.now().isoformat(timespec="seconds"), song_id, label, item, source])


def undo_last(path=LABELS):
    """Remove your last answer."""
    lines = path.read_text().splitlines(keepends=True) if path.exists() else []
    if len(lines) > 1:
        path.write_text("".join(lines[:-1]))


def percentiles(df, features):
    """Each feature as its percentile among all songs (0-1), missing values in the middle."""
    out = np.empty((df.height, len(features)))
    for j, name in enumerate(features):
        x = df[name].to_numpy().astype(float)
        ok = ~np.isnan(x)
        col = np.full(x.shape, 0.5)
        col[ok] = (rankdata(x[ok]) - 1) / max(ok.sum() - 1, 1)
        out[:, j] = col
    return out


# Analysis ---------------------------------------------------------------------------------------


def _auc_matrix(X, y):
    """AUC of every column of X (ties count half): P(a yes song has a higher value than a no song)."""
    ranks = rankdata(X, axis=0)
    n1, n0 = y.sum(), len(y) - y.sum()
    return (ranks[y == 1].sum(axis=0) - n1 * (n1 + 1) / 2) / (n1 * n0)


def _resample(y, rng):
    """A stratified bootstrap sample: as many yes and no as in your labels."""
    yes, no = np.flatnonzero(y == 1), np.flatnonzero(y == 0)
    return np.concatenate([rng.choice(yes, len(yes)), rng.choice(no, len(no))])


def univariate(P, y, features, describe, raw, n_boot=300):
    """How well each feature alone separates yes from no, with a 90% bootstrap interval."""
    rng = np.random.default_rng(SEED)
    auc = _auc_matrix(P, y)
    boots = np.array([_auc_matrix(P[idx], y[idx]) for idx in (_resample(y, rng) for _ in range(n_boot))])
    low, high = np.nanpercentile(boots, [5, 95], axis=0)
    return pl.DataFrame(
        {
            "feature": features,
            "auc": auc,
            "low": low,
            "high": high,
            "median_yes": [float(np.nanmedian(raw[y == 1, j])) for j in range(len(features))],
            "median_no": [float(np.nanmedian(raw[y == 0, j])) for j in range(len(features))],
            "meaning": [describe[f] for f in features],
        }
    ).with_columns(
        strength=(pl.col("auc") - 0.5).abs(),
        direction=pl.when(pl.col("auc") > 0.5).then(pl.lit("higher")).otherwise(pl.lit("lower")),
        clear=(pl.col("low") > 0.5) | (pl.col("high") < 0.5),
    ).sort("strength", descending=True)


def correlated(P_all, features, threshold=0.8):
    """For each feature, the others that move with it (|Spearman| above threshold, on all songs)."""
    rho = np.corrcoef(P_all.T)
    return {
        f: [features[k] for k in np.argsort(-np.abs(rho[j])) if k != j and abs(rho[j, k]) >= threshold]
        for j, f in enumerate(features)
    }


def _cv_auc(make_model, X, y, groups, repeats=10):
    """Cross-validated AUC on artists the model did not learn from (5 folds, repeated)."""
    scores = []
    for rep in range(repeats):
        folds = StratifiedGroupKFold(n_splits=5, shuffle=True, random_state=SEED + rep)
        for train, test in folds.split(X, y, groups):
            if len(set(y[test])) < 2 or len(set(y[train])) < 2:
                continue  # an artist-heavy fold with one class only: AUC is undefined
            model = make_model().fit(X[train], y[train])
            scores.append(roc_auc_score(y[test], model.predict_proba(X[test])[:, 1]))
    return float(np.mean(scores)), float(np.std(scores))


def _l1(C):
    return lambda: LogisticRegression(l1_ratio=1.0, C=C, solver="liblinear", class_weight="balanced")


def sparse_model(P, y, features, groups, n_boot=200):
    """L1 logistic regression on percentiles: strength picked by cross-validation, then stability
    selection (in how many resamples of your labels each feature is kept, and with which sign)."""
    X = P - 0.5
    grid = [0.05, 0.1, 0.2, 0.5, 1.0, 2.0]
    cv = {C: _cv_auc(_l1(C), X, y, groups) for C in grid}
    best = max(grid, key=lambda C: (round(cv[C][0], 3), -C))  # ties: the sparser model
    model = _l1(best)().fit(X, y)
    rng = np.random.default_rng(SEED)
    coefs = np.array([_l1(best)().fit(X[idx], y[idx]).coef_[0] for idx in (_resample(y, rng) for _ in range(n_boot))])
    table = (
        pl.DataFrame(
            {
                "feature": features,
                "coef": model.coef_[0],
                "kept": (coefs != 0).mean(axis=0),
                "positive": (coefs > 0).mean(axis=0),
                "negative": (coefs < 0).mean(axis=0),
            }
        )
        .filter(pl.col("kept") > 0)
        .sort("kept", descending=True)
    )
    return {"C": best, "cv_auc": cv[best], "cv_by_C": cv, "model": model, "table": table}


def baselines(P, y, features, groups):
    """Cross-validated AUC of simple models, to see whether the features add anything."""
    def cols(names):
        return P[:, [features.index(n) for n in names]] - 0.5

    plain = lambda: LogisticRegression(class_weight="balanced")  # noqa: E731
    return {
        "plays only": _cv_auc(plain, cols(["plays"]), y, groups),
        "the 3 dimensions": _cv_auc(plain, cols(["companion_pct", "obsession_pct", "sought_pct"]), y, groups),
    }


def tree_model(raw, y, features, groups, depth=3, min_leaf=4):
    """A shallow tree on raw values: rules you can read, and the shapes of your emotional songs."""
    X = np.nan_to_num(raw, nan=-1.0)  # missing (survival of very young songs) goes left
    make = lambda: DecisionTreeClassifier(  # noqa: E731
        max_depth=depth, min_samples_leaf=min_leaf, class_weight="balanced", random_state=SEED
    )
    tree = make().fit(X, y)
    return {"tree": tree, "rules": export_text(tree, feature_names=features, show_weights=False),
            "cv_auc": _cv_auc(make, X, y, groups), "shapes": _shapes(tree, X, y, features)}


def _shapes(tree, X, y, features):
    """Each leaf where most songs are yes, as the path of conditions leading to it."""
    t = tree.tree_
    leaves = tree.apply(X)
    shapes = []

    def walk(node, path):
        if t.children_left[node] == -1:
            members = leaves == node
            yes, n = int(y[members].sum()), int(members.sum())
            if n and yes / n > 0.5:
                shapes.append({"rule": " and ".join(path) or "everything", "yes": yes, "songs": n})
            return
        name, thr = features[t.feature[node]], t.threshold[node]
        walk(t.children_left[node], path + [f"{name} ≤ {thr:.3g}"])
        walk(t.children_right[node], path + [f"{name} > {thr:.3g}"])

    walk(0, [])
    return sorted(shapes, key=lambda s: -s["yes"])


def analyse(df, describe, labels):
    """Everything above, for the labelled songs (yes/no; skips are ignored)."""
    features = feature_names(describe)
    lab = df.join(labels.filter(pl.col("label").is_in(["yes", "no"])), on="song_id")
    y = (lab["label"] == "yes").to_numpy().astype(int)
    result = {"n_yes": int(y.sum()), "n_no": int(len(y) - y.sum()), "features": features}
    if min(result["n_yes"], result["n_no"]) < 5:
        result["error"] = "Need at least 5 yes and 5 no to learn anything."
        return result
    P_all = percentiles(df, features)
    index = {s: i for i, s in enumerate(df["song_id"])}
    rows = np.array([index[s] for s in lab["song_id"]])
    P, raw = P_all[rows], lab.select(features).to_numpy().astype(float)
    groups = lab["artist"].to_numpy()
    result["sources"] = (
        lab.group_by("source")
        .agg(yes=(pl.col("label") == "yes").sum(), no=(pl.col("label") == "no").sum())
        .with_columns(
            how=pl.col("source").replace_strict(SOURCES, default=pl.col("source")),
            yes_rate=(pl.col("yes") / (pl.col("yes") + pl.col("no"))).round(2),
            unbiased=~pl.col("source").is_in(MODEL_PICKED),
        )
        .sort("source")
    )
    result["univariate"] = univariate(P, y, features, describe, raw)
    unbiased = ~lab["source"].is_in(MODEL_PICKED).to_numpy()
    ny, nn = int(y[unbiased].sum()), int((1 - y[unbiased]).sum())
    result["n_unbiased"] = (ny, nn)
    if min(ny, nn) >= 5:
        # The same, on the answers the model did not pick: a result that holds in both is solid
        u = univariate(P[unbiased], y[unbiased], features, describe, raw[unbiased]).select(
            "feature", auc_unbiased="auc", clear_unbiased="clear"
        )
        result["univariate"] = (
            result["univariate"]
            .join(u, on="feature", how="left", maintain_order="left")
            .with_columns(
                holds=pl.col("clear") & pl.col("clear_unbiased")
                & ((pl.col("auc") > 0.5) == (pl.col("auc_unbiased") > 0.5))
            )
        )
    result["correlated"] = correlated(P_all, features)
    result["sparse"] = sparse_model(P, y, features, groups)
    result["baselines"] = baselines(P, y, features, groups)
    result["tree"] = tree_model(raw, y, features, groups)
    proba = result["sparse"]["model"].predict_proba(P_all - 0.5)[:, 1]
    result["predictions"] = df.select(*ID_COLUMNS, "importance_rank", "since", "last").with_columns(
        proba=pl.Series(proba)
    ).join(labels, on="song_id", how="left")
    return result


def next_songs(df, labels, result=None, mode="random"):
    """The songs to label next, with the `source` to record: the first batch of important songs, then
    among the POOL most important songs (the model learned from those, further down it extrapolates):
    a random pick (unbiased), the importance order, or the model's most likely / least sure songs."""
    unlabelled = df.join(labels, on="song_id", how="anti")
    first = unlabelled.filter(pl.col("importance_rank") <= FIRST_BATCH)
    if first.height:
        return first.with_columns(source=pl.lit("top"))
    pool = unlabelled.filter(pl.col("importance_rank") <= POOL)
    if not pool.height:
        return unlabelled.with_columns(source=pl.lit("importance"))
    if mode in MODEL_PICKED and result is not None and "predictions" in result:
        p = result["predictions"].select("song_id", "proba")
        order = pl.col("proba") if mode == "likely" else -(pl.col("proba") - 0.5).abs()
        return pool.join(p, on="song_id").sort(order, descending=True).drop("proba").with_columns(source=pl.lit(mode))
    if mode == "random":
        # Seeded by how many answers you gave: stable while you look at it, new after each answer
        rng = np.random.default_rng(SEED + labels.height)
        return pool[rng.permutation(pool.height)].with_columns(source=pl.lit("random"))
    return pool.with_columns(source=pl.lit("importance"))


# Text report ------------------------------------------------------------------------------------


def report(result):
    lines = [f"Labels: {result['n_yes']} yes, {result['n_no']} no"]
    if "error" in result:
        return "\n".join(lines + [result["error"]])
    s = result["sparse"]
    lines.append("\nCross-validated AUC on unseen artists (0.5 = coin flip, 1 = perfect):")
    for name, (m, sd) in result["baselines"].items():
        lines.append(f"  {name:20} {m:.2f} ± {sd:.2f}")
    lines.append(f"  {'all features (L1)':20} {s['cv_auc'][0]:.2f} ± {s['cv_auc'][1]:.2f}  (C={s['C']})")
    lines.append(f"  {'tree (depth 3)':20} {result['tree']['cv_auc'][0]:.2f} ± {result['tree']['cv_auc'][1]:.2f}")
    with pl.Config(tbl_rows=25, tbl_cols=-1, tbl_width_chars=250, fmt_str_lengths=60, tbl_hide_dataframe_shape=True,
                   tbl_hide_column_data_types=True):
        lines.append("\nHow the songs were chosen (the model's picks confirm its own guesses):")
        lines.append(str(result["sources"].select("how", "yes", "no", "yes_rate", "unbiased")))
        ny, nn = result["n_unbiased"]
        lines.append(f"\nOne metric at a time (clear = the 90% interval excludes 0.5; holds = clear and same "
                     f"direction on the {ny} yes / {nn} no unbiased answers too):")
        u = result["univariate"].head(20).with_columns(pl.col(pl.Float64).round(2))
        extra = ["auc_unbiased", "holds"] if "holds" in u.columns else []
        lines.append(str(u.select("feature", "auc", "low", "high", "clear", *extra, "median_yes", "median_no", "meaning")))
        lines.append("\nSparse model, stability across 200 resamples:")
        lines.append(str(s["table"].head(15).with_columns(pl.col(pl.Float64).round(2))))
    lines.append("\nTree:\n" + result["tree"]["rules"])
    lines.append("Shapes (leaves where most songs are yes):")
    for sh in result["tree"]["shapes"]:
        lines.append(f"  {sh['yes']}/{sh['songs']} yes: {sh['rule']}")
    return "\n".join(lines)


if __name__ == "__main__":
    import duckdb

    def q(sql):
        with duckdb.connect(str(ROOT / "spotify.duckdb"), read_only=True) as con:
            return con.sql(sql).pl()

    df, describe = load_features(q)
    print(report(analyse(df, describe, load_labels())))
