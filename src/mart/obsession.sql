-- Obsession
-- A song consumed intensely, on loop, whether it is old or new: "my breakup song,
-- when I feel sad I listen to it in loops". Measured on the day, not on the long run
-- (that's long_standing).
-- Strict loops (same song twice in a row) are rare in the data: on loop means many plays
-- in the same day. A binge day is a day with at least 3 plays of the song.
--   * binge_days:   how many times the song was binged
--   * binge_months: in how many different months, a refuge you come back to
--   * max_day:      the most intense day

.print int_obsession
CREATE OR REPLACE TABLE int_obsession AS
WITH

daily AS (
    SELECT
        song_id,
        CAST(timestamp AS DATE) AS day,
        COUNT(*) AS plays
    FROM int_music_play
    WHERE count_as_play = true
    GROUP BY song_id, day
),

songs AS (
    SELECT DISTINCT song_id, title, song_artist AS artist
    FROM int_music_play
)

SELECT
    song_id,
    title,
    artist,
    SUM(plays) AS total_plays,
    COUNT(*) FILTER (WHERE plays >= 3) AS binge_days,
    COUNT(DISTINCT date_trunc('month', day)) FILTER (WHERE plays >= 3) AS binge_months,
    MAX(plays) AS max_day,
    -- Share of the song's plays that happened during binge days
    SUM(plays) FILTER (WHERE plays >= 3) / SUM(plays) AS binge_share,
    MIN(day) FILTER (WHERE plays >= 3) AS first_binge,
    MAX(day) FILTER (WHERE plays >= 3) AS last_binge
FROM daily
JOIN songs USING (song_id)
GROUP BY song_id, title, artist;

.print mart_obsession
CREATE OR REPLACE TABLE mart_obsession AS
WITH scores AS (
    SELECT
        *,
        PERCENT_RANK() OVER (ORDER BY binge_days) AS binge_days_score,
        PERCENT_RANK() OVER (ORDER BY binge_months) AS recurrence_score,
        PERCENT_RANK() OVER (ORDER BY max_day) AS intensity_score
    FROM int_obsession
    WHERE binge_days >= 2 -- Binged at least twice
)
SELECT
    *,
    0.4 * binge_days_score
    + 0.3 * recurrence_score
    + 0.3 * intensity_score AS score
FROM scores;

-- Reporting
SELECT title, artist,
    total_plays,
    binge_days,
    binge_months,
    max_day,
    round(binge_share, 2) AS binge_share,
    round(score, 3) AS score
FROM mart_obsession
ORDER BY score DESC, binge_days DESC LIMIT 20;
