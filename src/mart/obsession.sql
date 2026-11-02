-- Obsession
-- A song that has been played a lot, including both frequently but also during a short period of time

CREATE OR REPLACE TABLE int_obsession AS
WITH

dataset_stats AS (
    SELECT
        MIN(timestamp) AS first_date,
        MAX(timestamp) as last_date,
        date_diff('day', first_date, last_date) + 1 AS spanning_days
        FROM stg_music_play),
track_stats AS (
    SELECT
        track,
        timestamp,
        COUNT(*) AS total_plays
    FROM stg_music_play
    WHERE count_as_play == true
    GROUP BY track_id, track
)
SELECT
    track,
    -- Frequency represents a simple metric of how many time per day a song has been playex
    total_plays/spanning_days AS frequency,


FROM track_stats
CROSS JOIN dataset_stats;

CREATE OR REPLACE TABLE mart_obsession AS
SELECT *,
    percent_rank() OVER (ORDER BY frequency) as frequency_score,
    frequency_score as score
FROM int_obsession
