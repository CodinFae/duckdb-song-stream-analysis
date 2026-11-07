.print int_obsession
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
    FROM int_music_play
),

track_stats AS (
    SELECT
        song_id,
        title,
        song_artist AS artist,
        COUNT(*) AS total_plays,
        DATE_DIFF(
            'day',
            MIN(timestamp),
            MAX(timestamp)
        ) + 1 AS song_lifetime
    FROM int_music_play
    WHERE count_as_play = true
    GROUP BY song_id, title, song_artist
),

chart_stats AS (
    SELECT
        song_id,
        COUNT(*) FILTER (
            WHERE hit_chart = 1
        ) AS weeks_as_number_one
    FROM int_week_charts
    WHERE max_hit >= 10
    GROUP BY song_id
),

weekly_plays AS (
    SELECT
        song_id,
        DATE_TRUNC('week', timestamp) AS week,
        COUNT(*) AS plays
    FROM int_music_play
    WHERE count_as_play = true
    GROUP BY song_id, DATE_TRUNC('week', timestamp)
),

peak_stats AS (
    SELECT
        song_id,
        MAX(plays) AS peak_weekly_plays
    FROM weekly_plays
    GROUP BY song_id
)

SELECT
    track_stats.song_id,
    track_stats.title,
    track_stats.artist,

    -- total_plays
    total_plays AS frequency,

    -- Number of weeks ranked #1
    COALESCE(weeks_as_number_one, 0) AS weeks_as_number_one,

    -- Maximum plays in a calendar week
    COALESCE(peak_weekly_plays, 0) AS peak_weekly_plays

FROM track_stats
CROSS JOIN dataset_stats
LEFT JOIN chart_stats
    ON chart_stats.song_id = track_stats.song_id
LEFT JOIN peak_stats
    ON peak_stats.song_id = track_stats.song_id
WHERE total_plays >= 10 -- The song has been played at least 10 times
AND weeks_as_number_one >= 1 -- It has been first at least once
;

.print mart_obsession
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
        0.1 * frequency_score
        + 0.6 * weeks_score
        + 0.3 * peak_score AS score

    FROM scores;


    -- Reporting
    SELECT title, artist,
        format('{0} ({1:2f})', frequency, frequency_score) as frequency,
        format('{0} ({1:2f})', weeks_as_number_one, weeks_score) as weeks_as_one,
        format('{0} ({1:2f})', peak_weekly_plays, peak_score) as peak,

        score
    FROM mart_obsession
    ORDER BY score DESC LIMIT 20;
