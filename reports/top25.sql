-- Top 25 songs of each song dimension, with context for pattern / personality analysis.
-- Export with `just top25` (writes out/top25.md, gitignored: it's your listening history).
--
-- Columns, for every song:
--   rank / dimension rank, the song's ranks in the two other dimensions (empty = not in it)
--   since / last:     year of first and last play
--   plays:            plays above 30s
--   picked:           share of its (10s+) plays you started yourself (click, play, back button)
--   binge_days:       days with 3+ plays
--   soundtrack:       its main album's name looks like a soundtrack (OST, game, film, series).
--                     Heuristic: misses soundtracks not named so ("Evangelion Finally") and anime/game
--                     songs released as singles (most openings)
--   script:           cjk when the title or artist has Japanese/Chinese/Korean characters.
--                     Heuristic: Japanese songs with romanized titles and artists count as latin
--   covers:           performers of its work you adopted (3+ plays), the song's own included
--   profile:          dimensions it's in the top 100 of (core = all three)

CREATE OR REPLACE TEMP VIEW song_context AS
WITH main_album AS (
    SELECT song_id, arg_max(album, row(n, album)) AS album
    FROM (SELECT song_id, album, COUNT(*) AS n FROM int_music_play GROUP BY ALL)
    GROUP BY song_id
)
SELECT
    p.song_id,
    p.title,
    p.artist,
    p.profile,
    p.companion_rank,
    p.obsession_rank,
    p.sought_rank,
    year(p.first_play) AS since,
    year(p.last_play) AS last,
    p.plays,
    round(it.picked_plays / it.total_plays, 2) AS picked,
    ob.binge_days,
    a.album AS main_album,
    regexp_matches(a.album, '(?i)(soundtrack|\bost\b|original score|music from|game music|サウンドトラック|from the series|motion picture)') AS soundtrack,
    CASE WHEN regexp_matches(p.title || p.artist, '[\p{Han}\p{Hiragana}\p{Katakana}\p{Hangul}]') THEN 'cjk' ELSE 'latin' END AS script,
    w.adopted_performers AS covers
FROM mart_song_profile p
LEFT JOIN int_intentionality it USING (song_id)
LEFT JOIN int_obsession ob USING (song_id)
LEFT JOIN main_album a USING (song_id)
LEFT JOIN int_work w USING (work_id);

.print ## Companions (long_standing): songs you live with, regularity
SELECT companion_rank AS rank, title, artist, obsession_rank AS obs, sought_rank AS sought,
    since, last, plays, picked, binge_days, soundtrack, script, covers, main_album
FROM song_context WHERE companion_rank <= 25 ORDER BY companion_rank;

.print
.print ## Obsessions: songs you binge on loop, intensity
SELECT obsession_rank AS rank, title, artist, companion_rank AS comp, sought_rank AS sought,
    since, last, plays, picked, binge_days, soundtrack, script, covers, main_album
FROM song_context WHERE obsession_rank <= 25 ORDER BY obsession_rank;

.print
.print ## Sought (intentionality): songs you seek out, choice
SELECT sought_rank AS rank, title, artist, companion_rank AS comp, obsession_rank AS obs,
    since, last, plays, picked, binge_days, soundtrack, script, covers, main_album
FROM song_context WHERE sought_rank <= 25 ORDER BY sought_rank;

.print
.print ## Shares across each top 25
SELECT
    dimension,
    round(avg(soundtrack::INT), 2) AS soundtrack_share,
    round(avg((script = 'cjk')::INT), 2) AS cjk_share,
    round(avg((covers >= 2)::INT), 2) AS covered_work_share,
    round(avg(picked), 2) AS avg_picked,
    median(since) AS median_since,
    COUNT(DISTINCT artist) AS artists
FROM (
    SELECT 'companion' AS dimension, * FROM song_context WHERE companion_rank <= 25
    UNION ALL SELECT 'obsession', * FROM song_context WHERE obsession_rank <= 25
    UNION ALL SELECT 'sought', * FROM song_context WHERE sought_rank <= 25
)
GROUP BY dimension
ORDER BY dimension;

.print
.print ## Top 10 albums you live in and works loved across performers
SELECT album, album_artist, sessions, session_months, longest_run FROM mart_album ORDER BY score DESC LIMIT 10;
SELECT work_title, adopted_performers, total_plays, performer_plays[1:4] AS performers FROM mart_work ORDER BY score DESC LIMIT 10;

.print
.print ## Your listening overall, for comparison
SELECT
    round(avg(regexp_matches(album, '(?i)(soundtrack|\bost\b|original score|music from|game music|サウンドトラック|from the series|motion picture)')::INT), 2) AS soundtrack_share_of_plays,
    round(avg(regexp_matches(title || song_artist, '[\p{Han}\p{Hiragana}\p{Katakana}\p{Hangul}]')::INT), 2) AS cjk_share_of_plays,
    COUNT(*) AS plays
FROM int_music_play WHERE count_as_play;
