CREATE OR REPLACE TABLE int_intentionality AS
WITH track_stats AS (
    SELECT
        track_id,
        track,
        COUNT(*) AS total_plays,

        COUNT(*) FILTER (
            WHERE reason_start IN ('clickrow', 'playbtn')
        ) AS selected_plays,

        COUNT(*) FILTER (
            WHERE reason_end = 'fwdbtn'
        ) AS skipped_plays

    FROM stg_music_play
    GROUP BY track_id, track
),

global_stats AS (
    SELECT
        SUM(selected_plays) * 1.0 / SUM(total_plays)
            AS global_selected_rate,

        SUM(skipped_plays) * 1.0 / SUM(total_plays)
            AS global_skipped_rate
    FROM track_stats
)

SELECT
    t.*,

    (selected_plays + 20 * global_selected_rate)
        / (total_plays + 20) AS selected_rate,

    (skipped_plays + 20 * global_skipped_rate)
        / (total_plays + 20) AS clicked_off_rate

FROM track_stats t
CROSS JOIN global_stats g;

CREATE OR REPLACE TABLE mart_intentionality AS
WITH scores AS (
    SELECT
        *,
        PERCENT_RANK() OVER (
            ORDER BY selected_rate
        ) AS selected_score,

        PERCENT_RANK() OVER (
            ORDER BY  clicked_off_rate DESC
        ) AS not_skipped_score
    FROM int_intentionality
)
SELECT
    *,
    0.8 * selected_score
    + 0.2 * not_skipped_score AS score
FROM scores;
