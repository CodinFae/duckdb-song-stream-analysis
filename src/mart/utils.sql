-- utilities
-- Taken from: https://duckdb.org/2025/08/15/ml-data-preprocessing#robust-scaling
CREATE OR REPLACE MACRO scaling_params(table_name, column_list) AS TABLE
    FROM query_table(table_name)
    SELECT
        "avg_\0": avg(columns(column_list)),
        "std_\0": stddev_pop(columns(column_list)),
        "min_\0": min(columns(column_list)),
        "max_\0": max(columns(column_list)),
        "q25_\0": quantile_cont(columns(column_list), 0.25),
        "q50_\0": quantile_cont(columns(column_list), 0.50),
        "q75_\0": quantile_cont(columns(column_list), 0.75);

CREATE OR REPLACE MACRO robust_scaler(val, q25_val, q50_val, q75_val) AS
CASE
    WHEN q75_val = q25_val THEN 0.5
    ELSE 1.0 / (
        1.0 + EXP(
            -(val - q50_val) / (q75_val - q25_val)
        )
    )
END;
