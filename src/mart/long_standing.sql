
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
        FROM int_music_play),
track_stats AS (
    SELECT
        song_id,
        title,
        song_artist AS artist,
        MIN(timestamp) AS first_play,
        MAX(timestamp) AS last_play,
        COUNT(DISTINCT CAST(timestamp AS DATE)) AS active_days,
        COUNT(DISTINCT date_trunc('month', timestamp)) AS monthly_loyalty,
        COUNT(*) AS total_plays
    FROM int_music_play
    WHERE count_as_play == true
    GROUP BY song_id, title, song_artist
)
SELECT
    song_id,
    title,
    artist,
    -- Longevity: What's the total spanning of the song, i.e. is there a large number of days between first listening
    -- and last. A song that has a high longevity is a song that either has been rediscovered or that is often there
    date_diff('day', first_play, last_play) + 1 AS longevity, -- date_diff returns 0 if a song has been started and stop in a day,

    -- Active Days: How many distinct days was this song listened to. The more there are, the more they are important
    active_days,

    monthly_loyalty,

    -- Loyalty rate: share of the months of the song's life (first -> last play) in which it was played.
    -- Relative, so a song discovered recently can compete with one known for years.
    date_diff('month', first_play, last_play) + 1 AS lifetime_months,
    monthly_loyalty / lifetime_months AS loyalty_rate,

    -- Time since last plays: The older the last play of a song, the less significant it is.
    date_diff('day', last_play, last_date) AS time_since_plays

FROM track_stats CROSS JOIN dataset_stats d;

.print mart_long_standing
CREATE OR REPLACE TABLE mart_long_standing AS
SELECT *,
    percent_rank() OVER (ORDER BY longevity) as longevity_score,
    percent_rank() OVER (ORDER BY active_days) as active_days_score,
    percent_rank() OVER (ORDER BY loyalty_rate) as loyalty_score,
    0.25*longevity_score+0.25*active_days_score+0.5*loyalty_score as score
FROM int_long_standing
-- "In my life": recency is not part of the score, a favourite from years ago still counts
WHERE active_days >= 7 -- Songs need to have been listened of 7 different days to count as long_standing
;

-- Reporting
SELECT title, artist,
    format('{0} ({1:2f})', longevity, longevity_score) as longevity,
    format('{0} ({1:2f})', active_days, active_days_score) as active_days,
    format('{0}/{1} ({2:2f})', monthly_loyalty, lifetime_months, loyalty_score) as active_months,
    time_since_plays as days_since_plays,
    score
FROM mart_long_standing
ORDER BY score DESC LIMIT 20;
