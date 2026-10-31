CREATE OR REPLACE TABLE stg_music_play AS
SELECT
    -- TODO: Add an ID for easier matching
    ts AS timestamp,
    ms_played,
    master_metadata_track_name AS track,
    master_metadata_album_artist_name AS artist,
    master_metadata_album_album_name AS album,
    spotify_track_uri AS source_id,
    reason_start,
    reason_end
FROM raw_spotify_data
WHERE
    track IS NOT NULL AND -- keep only songs
    ms_played > 30000 -- keep only meaningfull songs (TODO: what about small jingles?)
;
