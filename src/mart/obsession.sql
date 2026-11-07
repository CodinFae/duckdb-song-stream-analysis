-- Obsession
-- A song consumed intensely, on loop, whether it is old or new: "my breakup song,
-- when I feel sad I listen to it in loops". Measured on the day, not on the long run
-- (that's long_standing).
-- Strict loops (same song twice in a row) are rare in the data: on loop means many plays
-- in the same day. A binge day is a day with several plays of the song (see params.sql).
-- A play inside an album session counts as part of a play: binging a soundtrack still matters,
-- but it's partly a binge of the album, not of each of its tracks (see mart_album).
--   * binge_days:   how many times the song was binged
--   * binge_months: in how many different months, a refuge you come back to
--   * max_day:      the most intense day

.print int_obsession
CREATE OR REPLACE TABLE int_obsession AS
WITH

daily AS (
    SELECT
        song_id,
        CAST(p.timestamp AS DATE) AS day,
        COUNT(*) AS raw_plays,
        SUM(CASE WHEN a.event_id IS NULL THEN 1.0 ELSE getvariable('obsession_album_play_weight') END)::DOUBLE AS plays
    FROM int_music_play p
    LEFT JOIN int_album_play a USING (event_id)
    WHERE p.count_as_play = true
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
    SUM(raw_plays) AS total_plays,
    COUNT(*) FILTER (WHERE plays >= getvariable('obsession_binge_day_plays')) AS binge_days,
    COUNT(DISTINCT date_trunc('month', day)) FILTER (WHERE plays >= getvariable('obsession_binge_day_plays')) AS binge_months,
    MAX(plays) AS max_day,
    -- Share of the song's plays that happened during binge days
    SUM(raw_plays) FILTER (WHERE plays >= getvariable('obsession_binge_day_plays')) / SUM(raw_plays) AS binge_share,
    MIN(day) FILTER (WHERE plays >= getvariable('obsession_binge_day_plays')) AS first_binge,
    MAX(day) FILTER (WHERE plays >= getvariable('obsession_binge_day_plays')) AS last_binge
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
    WHERE binge_days >= getvariable('obsession_min_binge_days')
)
SELECT
    *,
    getvariable('obsession_weight_binge_days') * binge_days_score
    + getvariable('obsession_weight_recurrence') * recurrence_score
    + getvariable('obsession_weight_intensity') * intensity_score AS score
FROM scores;
