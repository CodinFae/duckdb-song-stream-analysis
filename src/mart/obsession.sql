CREATE OR REPLACE TABLE int_obsession AS
WITH dataset_stats AS (
    SELECT
        MIN(timestamp) AS first_date,
        MAX(timestamp) AS last_date,
        DATE_DIFF(
            'day',
            MIN(timestamp),
            MAX(timestamp)
        ) + 1 AS spanning_days
    FROM stg_music_play
),

track_stats AS (
    SELECT
        track_id,
        track,
        COUNT(*) AS total_plays
    FROM stg_music_play
    WHERE count_as_play = true
    GROUP BY track_id, track
),

chart_stats AS (
    SELECT
        track_id,
        COUNT(*) FILTER (
            WHERE hit_chart = 1
        ) AS weeks_as_number_one
    FROM int_week_charts
    WHERE max_hit >= 10
    GROUP BY track_id
),

weekly_plays AS (
    SELECT
        track_id,
        DATE_TRUNC('week', timestamp) AS week,
        COUNT(*) AS plays
    FROM stg_music_play
    WHERE count_as_play = true
    GROUP BY track_id, DATE_TRUNC('week', timestamp)
),

peak_stats AS (
    SELECT
        track_id,
        MAX(plays) AS peak_weekly_plays
    FROM weekly_plays
    GROUP BY track_id
)

SELECT
    track_stats.track_id,
    track_stats.track,

    -- Average plays per day
    total_plays * 1.0 / spanning_days AS frequency,

    -- Number of weeks ranked #1
    COALESCE(weeks_as_number_one, 0) AS weeks_as_number_one,

    -- Maximum plays in a calendar week
    COALESCE(peak_weekly_plays, 0) AS peak_weekly_plays

FROM track_stats
CROSS JOIN dataset_stats
LEFT JOIN chart_stats
    ON chart_stats.track_id = track_stats.track_id
LEFT JOIN peak_stats
    ON peak_stats.track_id = track_stats.track_id;


    CREATE OR REPLACE TABLE mart_obsession AS
    WITH scores AS (
        SELECT
            *,
            PERCENT_RANK() OVER (
                ORDER BY frequency
            ) AS frequency_score,

            PERCENT_RANK() OVER (
                ORDER BY weeks_as_number_one
            ) AS weeks_score,

            PERCENT_RANK() OVER (
                ORDER BY peak_weekly_plays
            ) AS peak_score

        FROM int_obsession
    )

    SELECT
        *,
        0.3 * frequency_score
        + 0.4 * weeks_score
        + 0.3 * peak_score AS score

    FROM scores;
