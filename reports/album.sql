-- album: top 20
SELECT album, album_artist,
    sessions,
    session_months,
    longest_run,
    tracks_heard,
    round(score, 3) AS score
FROM mart_album
ORDER BY score DESC LIMIT 20;
