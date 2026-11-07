-- Song profile
-- Every song, with its place in each dimension, side by side: what kind of important is it?
--   * companion  (long_standing): regularity, "my morning song"
--   * obsession:                  intensity, "my breakup song"
--   * sought     (intentionality): choice, "I search for it"
--   * work / album: the composition and the album the song belongs to
-- rank: position in the mart (1 = top), pct: 1 = top of the mart, 0 = bottom, NULL = not in it.
-- A song is strong in a dimension when it's in that mart's top N (params.sql), and its
-- profile names the dimensions it's strong in ("core" when strong in all three).

.print mart_song_profile
CREATE OR REPLACE TABLE mart_song_profile AS
WITH

songs AS (
    SELECT
        song_id,
        any_value(title) AS title,
        any_value(song_artist) AS artist,
        any_value(work_id) AS work_id,
        any_value(work_title) AS work_title,
        COUNT(*) FILTER (WHERE count_as_play) AS plays,
        MIN(timestamp) AS first_play,
        MAX(timestamp) AS last_play
    FROM int_music_play
    GROUP BY song_id
),

-- The album a song is most played from
song_album AS (
    SELECT
        song_id,
        arg_max(album_id, row(plays, album_id)) AS album_id
    FROM (
        SELECT song_id, md5(norm_name(artist) || '|' || norm_name(album)) AS album_id, COUNT(*) AS plays
        FROM int_music_play
        GROUP BY song_id, album_id
    )
    GROUP BY song_id
),

ranked AS (
    SELECT
        s.*,
        ls.score AS companion_score,
        row_number() OVER (ORDER BY ls.score DESC NULLS LAST, ls.active_days DESC, s.song_id) AS companion_rank,
        ob.score AS obsession_score,
        row_number() OVER (ORDER BY ob.score DESC NULLS LAST, ob.binge_days DESC, s.song_id) AS obsession_rank,
        it.score AS sought_score,
        row_number() OVER (ORDER BY it.score DESC NULLS LAST, s.song_id) AS sought_rank,
        w.score AS work_score,
        a.album_id,
        a.album,
        a.score AS album_score
    FROM songs s
    LEFT JOIN mart_long_standing ls USING (song_id)
    LEFT JOIN mart_obsession ob USING (song_id)
    LEFT JOIN mart_intentionality it USING (song_id)
    LEFT JOIN mart_work w USING (work_id)
    LEFT JOIN song_album sa USING (song_id)
    LEFT JOIN mart_album a ON a.album_id = sa.album_id
),

with_pct AS (
    SELECT
        * EXCLUDE (companion_rank, obsession_rank, sought_rank),
        CASE WHEN companion_score IS NOT NULL THEN companion_rank END AS companion_rank,
        CASE WHEN obsession_score IS NOT NULL THEN obsession_rank END AS obsession_rank,
        CASE WHEN sought_score IS NOT NULL THEN sought_rank END AS sought_rank,
        1 - (companion_rank - 1) / (SELECT COUNT(*) FROM mart_long_standing) AS companion_pct_raw,
        1 - (obsession_rank - 1) / (SELECT COUNT(*) FROM mart_obsession) AS obsession_pct_raw,
        1 - (sought_rank - 1) / (SELECT COUNT(*) FROM mart_intentionality) AS sought_pct_raw
    FROM ranked
)

SELECT
    * EXCLUDE (companion_pct_raw, obsession_pct_raw, sought_pct_raw),
    CASE WHEN companion_score IS NOT NULL THEN companion_pct_raw END AS companion_pct,
    CASE WHEN obsession_score IS NOT NULL THEN obsession_pct_raw END AS obsession_pct,
    CASE WHEN sought_score IS NOT NULL THEN sought_pct_raw END AS sought_pct,
    coalesce(companion_rank <= getvariable('profile_top_n'), false) AS is_companion,
    coalesce(obsession_rank <= getvariable('profile_top_n'), false) AS is_obsession,
    coalesce(sought_rank <= getvariable('profile_top_n'), false) AS is_sought,
    CASE
        WHEN is_companion AND is_obsession AND is_sought THEN 'core'
        ELSE coalesce(nullif(concat_ws(' + ',
            CASE WHEN is_companion THEN 'companion' END,
            CASE WHEN is_obsession THEN 'obsession' END,
            CASE WHEN is_sought THEN 'sought' END), ''), 'none')
    END AS profile
FROM with_pct;
