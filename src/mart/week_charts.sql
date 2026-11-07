-- Weekly charts
-- Rank songs by number of plays in each calendar week, like a personal top chart.
-- Ties share the same rank (RANK): a week where 24 songs are played twice has 24 songs at #1.
-- To keep #1 meaningful:
--   * is_valid_week: the #1 of the week must have at least 5 plays
--   * number_one_credit: tied #1s share one week of credit (1 / tied songs)

.print int_week_charts
CREATE OR REPLACE TABLE int_week_charts AS
WITH weekly_track_count AS (
    SELECT
        date_trunc('week', timestamp) AS week_start,
        song_id,
        title,
        song_artist AS artist,
        COUNT(*) AS total_week_song,
        RANK() OVER (
            PARTITION BY week_start
            ORDER BY total_week_song DESC
        ) AS hit_chart
    FROM int_music_play
    WHERE count_as_play = true
    GROUP BY week_start, song_id, title, song_artist
),

week_stats AS (
    SELECT
        week_start,
        MAX(total_week_song) AS top_plays,
        COUNT(*) FILTER (WHERE hit_chart = 1) AS tied_number_one
    FROM weekly_track_count
    GROUP BY week_start
)

SELECT
    w.week_start,
    song_id,
    title,
    artist,
    total_week_song,
    hit_chart,
    s.top_plays,
    s.tied_number_one,
    s.top_plays >= 5 AS is_valid_week,
    CASE
        WHEN hit_chart = 1 AND s.top_plays >= 5 THEN 1.0 / s.tied_number_one
        ELSE 0
    END AS number_one_credit
FROM weekly_track_count w
INNER JOIN week_stats s ON s.week_start = w.week_start;
