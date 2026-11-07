-- Album sessions, play by play
-- An album session is a run of plays from the same album (shuffled or not), with less than
-- 20 minutes between plays, covering at least 3 different tracks. Singles never form one.
-- Used by mart_album, and by the song marts: a session started by you (click, play, back
-- button on its first track) means the album was sought out; a binge inside an album session
-- is partly a binge of the album.

.print int_album_play
CREATE OR REPLACE TABLE int_album_play AS
WITH

plays AS (
    SELECT
        event_id,
        track_id,
        timestamp,
        reason_start,
        album,
        artist AS album_artist,
        norm_name(artist) || '|' || norm_name(album) AS album_key
    FROM int_music_play
    WHERE ms_played >= 10000 -- Shorter is a "not now" skip
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
),

run_stats AS (
    SELECT
        run_id,
        COUNT(DISTINCT track_id) AS tracks,
        arg_min(reason_start, timestamp) AS first_reason_start
    FROM runs
    GROUP BY run_id
)

SELECT
    r.event_id,
    r.run_id,
    md5(r.album_key) AS album_id,
    r.album,
    r.album_artist,
    r.track_id,
    r.timestamp,
    row_number() OVER (PARTITION BY r.run_id ORDER BY r.timestamp) AS position,
    s.first_reason_start IN ('clickrow', 'playbtn', 'backbtn') AS started_by_you
FROM runs r
JOIN run_stats s USING (run_id)
WHERE s.tracks >= 3;
