
-- Long Standing
-- A song that has been there for a long time, always coming to the streaming history
-- should be a meaningful song
--
.print int_long_standing
CREATE OR REPLACE TABLE int_long_standing AS
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
        MIN(timestamp) AS first_play,
        MAX(timestamp) AS last_play,
        COUNT(DISTINCT CAST(timestamp AS DATE)) AS active_days,
        COUNT(DISTINCT date_trunc('month', timestamp)) AS monthly_loyalty,
        COUNT(*) AS total_plays
    FROM stg_music_play
    WHERE count_as_play == true
    GROUP BY track_id, track
)
SELECT
    track,
    -- Longevity: What's the total spanning of the song, i.e. is there a large number of days between first listening
    -- and last. A song that has a high longevity is a song that either has been rediscovered or that is often there
    date_diff('day', first_play, last_play) + 1 AS longevity, -- date_diff returns 0 if a song has been started and stop in a day,

    -- Active Days: How many distinct days was this song listened to. The more there are, the more they are importante
    active_days,

    monthly_loyalty,

    -- Time since last plays: The older the last play of a song, the less significant it is.
    date_diff('day', last_play, last_date) AS time_since_plays

FROM track_stats CROSS JOIN dataset_stats d;

.print mart_long_standing
CREATE OR REPLACE TABLE mart_long_standing AS
SELECT *,
    percent_rank() OVER (ORDER BY longevity) as longevity_score,
    percent_rank() OVER (ORDER BY active_days) as active_days_score,
    percent_rank() OVER (ORDER BY monthly_loyalty) as monthly_loyalty_score,
    exp(-ln(2)*time_since_plays/90) AS  recency_score,
    0.2*longevity_score+0.2*active_days_score+0.4*monthly_loyalty_score+0.2*recency_score as score
FROM int_long_standing
WHERE time_since_plays < 365 -- No need to spend time on a song never listened to in a year
AND active_days >= 7 -- Songs need to have been listened of 7 different days to count as long_standing
;

-- Reporting
SELECT track,
    format('{0} ({1:2f})', longevity, longevity_score) as longevity,
    format('{0} ({1:2f})', active_days, active_days_score) as active_days,
    format('{0} ({1:2f})', monthly_loyalty, monthly_loyalty_score) as active_months,
    format('{0} ({1:2f})', time_since_plays, recency_score) as days_since_plays,
    score
FROM mart_long_standing
ORDER BY score DESC LIMIT 20;
