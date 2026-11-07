-- Albums you live in
-- Some music is listened to as a whole, by album (mostly soundtracks): one level above the song.
-- Album sessions come from int_album_play (several different tracks of an album in a row).
--   * sessions:        how many times you listened to the album as a whole
--   * session_months:  in how many different months, the album keeps coming back
--   * longest_run:     the most different tracks of the album in a single session

.print int_album_session
CREATE OR REPLACE TABLE int_album_session AS
SELECT
    run_id,
    album_id,
    min(album) AS album, -- same album, spellings may differ in case
    min(album_artist) AS album_artist,
    MIN(timestamp) AS started_at,
    bool_or(started_by_you) AS started_by_you,
    COUNT(*) AS plays,
    COUNT(DISTINCT track_id) AS tracks
FROM int_album_play
GROUP BY run_id, album_id;

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
    min(album) AS album, -- same album, spellings may differ in case
    min(album_artist) AS album_artist,
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
    WHERE sessions >= getvariable('album_min_sessions')
        AND norm_name(album_artist) != 'various artists'
)
SELECT
    *,
    getvariable('album_weight_sessions') * sessions_score
    + getvariable('album_weight_recurrence') * recurrence_score
    + getvariable('album_weight_depth') * depth_score AS score
FROM scores;
