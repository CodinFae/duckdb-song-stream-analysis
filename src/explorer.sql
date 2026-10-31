SELECT
    COUNT(*) AS total,
    COUNT(master_metadata_album_album_name) AS total_songs,
    COUNT(*) FILTER (WHERE ms_played > 5000) AS songs_over_5000ms
FROM raw_spotify_data;
