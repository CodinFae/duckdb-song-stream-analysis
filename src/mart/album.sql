-- Albums you live in
-- Some music is listened to as a whole, by album (mostly soundtracks): one level above the song.
-- An album session is a run of plays from the same album (shuffled or not), with less than
-- 20 minutes between plays, covering at least 3 different tracks. Singles never form one.
--   * sessions:        how many times you listened to the album as a whole
--   * session_months:  in how many different months, the album keeps coming back
--   * longest_run:     the most different tracks of the album in a single session

.print int_album_session
CREATE OR REPLACE TABLE int_album_session AS
WITH

plays AS (
    SELECT
        track_id,
        timestamp,
        album,
        artist AS album_artist,
        norm_name(artist) || '|' || norm_name(album) AS album_key
    FROM int_music_play
    WHERE ms_played >= 10000 -- Same as intentionality: shorter is a "not now" skip
),

breaks AS (
    SELECT
        *,
        CASE
            WHEN album_key = lag(album_key) OVER w
                AND timestamp - lag(timestamp) OVER w < INTERVAL 20 MINUTE
            THEN 0 ELSE 1
        END AS is_new_run
    FROM plays
    WINDOW w AS (ORDER BY timestamp)
),

runs AS (
    SELECT *, SUM(is_new_run) OVER (ORDER BY timestamp) AS run_id
    FROM breaks
)

SELECT
    run_id,
    md5(album_key) AS album_id,
    any_value(album) AS album,
    any_value(album_artist) AS album_artist,
    MIN(timestamp) AS started_at,
    COUNT(*) AS plays,
    COUNT(DISTINCT track_id) AS tracks
FROM runs
GROUP BY run_id, album_key
HAVING tracks >= 3;

.print int_album
CREATE OR REPLACE TABLE int_album AS
WITH heard AS (
    SELECT
        md5(norm_name(artist) || '|' || norm_name(album)) AS album_id,
        COUNT(DISTINCT track_id) AS tracks_heard
    FROM int_music_play
    WHERE count_as_play = true
    GROUP BY album_id
)
SELECT
    album_id,
    any_value(album) AS album,
    any_value(album_artist) AS album_artist,
    COUNT(*) AS sessions,
    COUNT(DISTINCT date_trunc('month', started_at)) AS session_months,
    MAX(tracks) AS longest_run,
    SUM(plays) AS plays_in_sessions,
    any_value(h.tracks_heard) AS tracks_heard,
    MIN(started_at) AS first_session,
    MAX(started_at) AS last_session
FROM int_album_session
JOIN heard h USING (album_id)
GROUP BY album_id;

.print mart_album
CREATE OR REPLACE TABLE mart_album AS
WITH scores AS (
    SELECT
        *,
        PERCENT_RANK() OVER (ORDER BY sessions) AS sessions_score,
        PERCENT_RANK() OVER (ORDER BY session_months) AS recurrence_score,
        PERCENT_RANK() OVER (ORDER BY longest_run) AS depth_score
    FROM int_album
    WHERE sessions >= 2 -- Listened to as a whole at least twice
        AND norm_name(album_artist) != 'various artists'
)
SELECT
    *,
    0.4 * sessions_score
    + 0.3 * recurrence_score
    + 0.3 * depth_score AS score
FROM scores;

-- Reporting
SELECT album, album_artist,
    sessions,
    session_months,
    longest_run,
    tracks_heard,
    round(score, 3) AS score
FROM mart_album
ORDER BY score DESC LIMIT 20;
