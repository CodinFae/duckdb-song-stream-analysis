-- Song identity
-- A song is one work performed by one artist, whatever the release (single, album, deluxe, remaster...).
-- Spotify's track_id is per recording x release, so several track_ids can map to the same song_id.
--
-- Merged:   releases, remasters, radio/single/album/full edits, "(feat. X)"
-- Separate: covers (different artist), live, remix, acoustic/piano/... versions, language versions, instrumental
-- Artist aliases are fixed by hand in seeds/artist_aliases.csv

.print int_song
CREATE OR REPLACE TABLE int_song AS
WITH

aliases AS (
    SELECT lower(trim(alias)) AS alias, lower(trim(canonical)) AS canonical
    FROM read_csv('seeds/artist_aliases.csv')
),

tracks AS (
    SELECT
        track_id,
        any_value(track) AS track,
        any_value(artist) AS artist,
        COUNT(*) AS plays
    FROM stg_music_play
    GROUP BY track_id
),

normalized AS (
    SELECT
        t.*,
        coalesce(a.canonical, lower(trim(nfc_normalize(t.artist)))) AS artist_key,
        lower(trim(
            regexp_replace(
                regexp_replace(
                    nfc_normalize(t.track),
                    -- "(feat. X)", "[ft. X]", "(with X)"
                    '\s*[\(\[](feat\.?|ft\.?|featuring|with)\s[^\)\]]*[\)\]]', '', 'gi'
                ),
                -- " - 2011 Remaster", " - Radio Edit", " - Single Version", " - Remasterisé en 2006"...
                '\s+-\s+[^-]*(remaster|radio edit|single version|album version|full version|original version)[^-]*$', '', 'i'
            )
        )) AS title_key
    FROM tracks t
    LEFT JOIN aliases a ON a.alias = lower(trim(nfc_normalize(t.artist)))
)

SELECT
    track_id,
    md5(artist_key || '|' || title_key) AS song_id,
    -- Display the most played variant of the song
    arg_max(track, plays) OVER song AS title,
    arg_max(artist, plays) OVER song AS artist,
    track AS source_title,
    artist AS source_artist
FROM normalized
WINDOW song AS (PARTITION BY artist_key, title_key);

-- Every play, with its song
CREATE OR REPLACE VIEW int_music_play AS
SELECT p.*, s.song_id, s.title, s.artist AS song_artist
FROM stg_music_play p
JOIN int_song s USING (track_id);

SELECT
    COUNT(DISTINCT track_id) AS track_ids,
    COUNT(DISTINCT song_id) AS songs
FROM int_song;
