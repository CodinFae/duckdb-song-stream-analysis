-- Album sessions, play by play
-- An album session is a run of plays from the same album (shuffled or not), with a short gap
-- between plays, covering several different tracks (see params.sql). Singles never form one.
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
    WHERE ms_played >= getvariable('real_play_min_ms') -- Shorter is a "not now" skip
),

breaks AS (
    SELECT
        *,
        CASE
            WHEN album_key = lag(album_key) OVER w
                AND timestamp - lag(timestamp) OVER w < to_minutes(getvariable('album_session_max_gap_minutes'))
            THEN 0 ELSE 1
        END AS is_new_run
    FROM plays
    -- event_id breaks ties between plays logged at the same time
    WINDOW w AS (ORDER BY timestamp, event_id)
),

runs AS (
    SELECT *, SUM(is_new_run) OVER (ORDER BY timestamp, event_id) AS run_id
    FROM breaks
),

run_stats AS (
    SELECT
        run_id,
        COUNT(DISTINCT track_id) AS tracks,
        arg_min(reason_start, row(timestamp, event_id)) AS first_reason_start
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
    row_number() OVER (PARTITION BY r.run_id ORDER BY r.timestamp, r.event_id) AS position,
    s.first_reason_start IN ('clickrow', 'playbtn', 'backbtn') AS started_by_you
FROM runs r
JOIN run_stats s USING (run_id)
WHERE s.tracks >= getvariable('album_session_min_tracks');
