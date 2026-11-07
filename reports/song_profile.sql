-- song_profile: how many songs per profile, with examples
SELECT
    profile,
    COUNT(*) AS songs,
    list(title ORDER BY coalesce(companion_pct, 0) + coalesce(obsession_pct, 0) + coalesce(sought_pct, 0) DESC)[1:4] AS examples
FROM mart_song_profile
WHERE profile != 'none'
GROUP BY profile
ORDER BY songs DESC;
