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
    ms_played > 30000 AS count_as_play
FROM raw_spotify_data
WHERE
    track_id IS NOT NULL -- keep only songs
;
