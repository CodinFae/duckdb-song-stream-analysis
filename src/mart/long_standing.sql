
-- Long Standing
-- A companion of life: a song that is not a fad, because you kept coming back to it
-- long after you fell for it. Measured independently of when the song was discovered:
--   * survival: share of months the song was played after its honeymoon (first 3 months),
--     until its last play. A fad is played a lot at first, then rarely.
--   * proven:   how long the song has been with you, with diminishing returns: after 3 years
--     a song has proven it's not a fad, more years don't add more.
-- Songs with less than 12 months of life are too young to tell (see obsession for recent binges).
-- "In my life": recency is not part of the score, a favourite from years ago still counts.

.print int_long_standing
CREATE OR REPLACE TABLE int_long_standing AS
WITH

dataset_stats AS (
    SELECT MAX(timestamp) AS last_date
    FROM int_music_play
),

monthly AS (
    SELECT song_id, date_trunc('month', timestamp) AS month
    FROM int_music_play
    WHERE count_as_play = true
    GROUP BY song_id, month
),

track_stats AS (
    SELECT
        song_id,
        title,
        song_artist AS artist,
        MIN(timestamp) AS first_play,
        MAX(timestamp) AS last_play,
        COUNT(DISTINCT CAST(timestamp AS DATE)) AS active_days,
        COUNT(DISTINCT date_trunc('month', timestamp)) AS active_months,
        COUNT(*) AS total_plays
    FROM int_music_play
    WHERE count_as_play = true
    GROUP BY song_id, title, song_artist
),

post_honeymoon AS (
    SELECT
        t.song_id,
        COUNT(*) FILTER (
            WHERE m.month >= date_trunc('month', t.first_play) + INTERVAL 3 MONTH
        ) AS post_honeymoon_active_months
    FROM track_stats t
    JOIN monthly m USING (song_id)
    GROUP BY t.song_id
)

SELECT
    song_id,
    title,
    artist,
    first_play,
    last_play,
    total_plays,
    active_days,
    active_months,

    -- Life of the song with you, in months (first -> last play)
    date_diff('month', first_play, last_play) + 1 AS lifetime_months,

    -- Survival: months played after the honeymoon / months of life after the honeymoon
    post_honeymoon_active_months,
    greatest(lifetime_months - 3, 0) AS post_honeymoon_months,
    post_honeymoon_active_months / nullif(post_honeymoon_months, 0) AS survival_rate,

    -- Proven: 0 -> 1 over the first 3 years, then capped
    least(lifetime_months / 36.0, 1) AS proven,

    date_diff('day', last_play, last_date) AS time_since_plays

FROM track_stats
JOIN post_honeymoon USING (song_id)
CROSS JOIN dataset_stats;

.print mart_long_standing
CREATE OR REPLACE TABLE mart_long_standing AS
SELECT
    *,
    0.6 * survival_rate + 0.4 * proven AS score
FROM int_long_standing
WHERE active_days >= 7        -- Listened on at least 7 different days
    AND lifetime_months >= 12 -- Too young to tell otherwise
;

-- Reporting
SELECT title, artist,
    strftime(first_play, '%Y-%m') AS since,
    lifetime_months AS life_months,
    format('{0}/{1}', post_honeymoon_active_months, post_honeymoon_months) AS months_after_honeymoon,
    round(survival_rate, 2) AS survival,
    round(proven, 2) AS proven,
    round(score, 3) AS score
FROM mart_long_standing
ORDER BY score DESC, active_days DESC LIMIT 20;
