.print stg_music_play
CREATE OR REPLACE TABLE stg_music_play AS
SELECT
    md5(concat_ws('|',epoch_ms(ts) ,spotify_track_uri , ms_played)) as event_id,
    ts AS timestamp,
    ms_played,
    master_metadata_track_name AS track,
    master_metadata_album_artist_name AS artist,
    master_metadata_album_album_name AS album,
    spotify_track_uri AS track_id,
    reason_start,
    reason_end,
    shuffle,
    platform,
    ms_played > getvariable('counted_play_min_ms') AS count_as_play
FROM raw_spotify_data
WHERE
    track_id IS NOT NULL -- keep only songs
-- Spotify sometimes logs the same play twice (same ts, track and duration): keep one
QUALIFY row_number() OVER (PARTITION BY event_id) = 1
;

SELECT
    (SELECT COUNT(*) FROM raw_spotify_data WHERE spotify_track_uri IS NOT NULL)
    - COUNT(*) AS duplicate_plays_removed
FROM stg_music_play;
