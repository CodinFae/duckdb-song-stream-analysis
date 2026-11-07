-- Song identity
-- A song is one work performed by one artist, whatever the release (single, album, deluxe, remaster...).
-- Spotify's track_id is per recording x release, so several track_ids can map to the same song_id.
--
-- Merged:   releases, remasters, radio/single/album/full edits, "(feat. X)", soundtrack tags,
--           romanization after a Japanese/Chinese/Korean title ("ピースサイン - Peace Sign"),
--           source annotations like '(From "Game")' or ' - Opening Theme to "Anime"' when the
--           artist has only one song with that title (otherwise the source is what tells them apart:
--           "Main Theme (From Zelda)" vs "Main Theme (From Overwatch)")
-- Separate: covers (different artist), live (incl. THE FIRST TAKE), remix, acoustic/piano/... versions, language versions, instrumental
-- Renames: Spotify sometimes renames a title or an artist under the same track_id.
-- Each track_id uses its most recent name; older titles become automatic title aliases, so other
-- tracks still published under the old title merge too. Artist changes are not generalized (see below).
-- Manual fixes, for what the data can't tell (they take priority):
--   seeds/artist_aliases.csv: same artist under two names
--   seeds/title_aliases.csv:  same song under two titles (romanization, translation...)

.print int_song
-- Full-width punctuation and spaces (！？～（） ...) are folded to their ASCII form
CREATE OR REPLACE MACRO norm_text(x) AS
    translate(nfc_normalize(x), '！？～〜＊（）［］：　＂＆', '!?~~*()[]: "&');
CREATE OR REPLACE MACRO norm_name(x) AS lower(trim(norm_text(x)));
-- Version tags, for the work level: " - Acoustic Version", "(English Cover)", " - Russian ver.", " - Live"...
-- ".*" and not "[^-]*" after the dash: tags can contain hyphens (" - M-10 Director's Edit Version")
CREATE OR REPLACE MACRO strip_version_tags(x) AS trim(regexp_replace(
    regexp_replace(x,
        '\s*[\(\[][^\)\]]*\b(version|ver\.|ver\b|cover|live|remix|instrumental|inst\.|inst\b|off vocal|karaoke|acoustic|piano|orchestral|arrange|tv size|full size|slowed|sped up|nightcore|english|russian|spanish|español|japanese|french|remake|demo)[^\)\]]*[\)\]]', '', 'gi'),
    '\s+-\s+.*\b(version|ver\.|ver\b|cover|live|remix|instrumental|inst\.|inst\b|off vocal|karaoke|acoustic|piano|orchestral|arrange|tv size|full size|slowed|sped up|nightcore|english|russian|spanish|español|japanese|french|remake|demo).*$', '', 'i'));
-- Accents are ignored at the work level ("Komm, süsser Tod" = "Komm, susser Tod"), but not on
-- Japanese/Chinese/Korean titles: strip_accents would also remove the dakuten (ビ -> ヒ)
CREATE OR REPLACE MACRO fold_latin_accents(x) AS
    CASE WHEN regexp_matches(x, '[\p{Han}\p{Hiragana}\p{Katakana}\p{Hangul}]') THEN x ELSE strip_accents(x) END;

CREATE OR REPLACE TABLE int_song AS
WITH

names AS (
    SELECT track_id, track, artist, MAX(timestamp) AS last_seen, COUNT(*) AS plays
    FROM stg_music_play
    GROUP BY track_id, track, artist
),

-- Each track_id uses its most recent name (deterministic, and Spotify's current naming)
tracks AS (
    SELECT
        track_id,
        arg_max(track, row(last_seen, track)) AS track,
        arg_max(artist, row(last_seen, artist)) AS artist,
        SUM(plays) AS plays
    FROM names
    GROUP BY track_id
),

-- Manual only: an artist change under a track_id is often an album-artist change
-- (Atlus Sound Team -> Lyn), not a rename, so it can't be generalized automatically
artist_aliases AS (
    SELECT norm_name(alias) AS alias, norm_name(canonical) AS canonical, canonical AS display_name
    FROM read_csv('seeds/artist_aliases.csv')
),

title_aliases AS (
    SELECT
        coalesce(a.canonical, norm_name(m.artist)) AS artist,
        norm_name(m.alias) AS alias,
        m.canonical
    FROM (
        SELECT artist, alias, canonical, 1 AS priority FROM read_csv('seeds/title_aliases.csv')
        UNION ALL
        -- Automatic: older titles of a renamed track_id (same recording, so same song)
        SELECT t.artist, n.track, t.track, 2
        FROM names n
        JOIN tracks t USING (track_id)
        WHERE norm_name(n.track) != norm_name(t.track)
    ) m
    LEFT JOIN artist_aliases a ON a.alias = norm_name(m.artist)
    -- One canonical title per alias: manual first, then deterministic
    QUALIFY row_number() OVER (
        PARTITION BY coalesce(a.canonical, norm_name(m.artist)), norm_name(m.alias)
        ORDER BY m.priority, m.canonical
    ) = 1
),

with_artist AS (
    SELECT
        t.*,
        coalesce(a.canonical, norm_name(t.artist)) AS artist_key,
        -- Artists in the seed (alias or canonical) are displayed under their canonical name
        coalesce(c.display_name, t.artist) AS display_artist
    FROM tracks t
    LEFT JOIN artist_aliases a ON a.alias = norm_name(t.artist)
    LEFT JOIN (SELECT DISTINCT canonical, display_name FROM artist_aliases) c
        ON c.canonical = coalesce(a.canonical, norm_name(t.artist))
),

with_title AS (
    SELECT
        w.*,
        norm_text(coalesce(ta.canonical, w.track)) AS clean_title
    FROM with_artist w
    LEFT JOIN title_aliases ta
        ON ta.artist = w.artist_key
        AND ta.alias = norm_name(w.track)
),

stripped AS (
    -- Title cleaning, one step per column (each step reads the previous one)
    SELECT
        *,
        lower(trim(clean_title)) AS t0,
        -- "THE FIRST TAKE" is a separate one-take live performance, not a source annotation
        t0 LIKE '%first take%' AS is_live_take,

        -- 1. Featured artists: "(feat. X)", "[ft. X]", "(with X)", " feat.X"
        regexp_replace(
            regexp_replace(t0, '\s*[\(\[](feat\.?|ft\.?|featuring|with)\s[^\)\]]*[\)\]]', '', 'g'),
            '\s+(feat\.|ft\.|featuring\s).*$', ''
        ) AS t1,

        -- 2. Source annotation: '(From "Game")', ' - From "Movie" Soundtrack', ' - Opening Theme to "Anime"'
        --    The source is kept (letters/digits only) to tell apart generic titles, see title_key
        CASE WHEN NOT is_live_take THEN nullif(regexp_replace(coalesce(
            nullif(regexp_extract(t0, '[\(\[]from\s([^\)\]]*)[\)\]]', 1), ''),
            nullif(regexp_extract(t0,
                '\s+-\s+(?:from\s|(?:opening|ending)\s(?:theme\s)?(?:to|from|of)\s|theme\s(?:from|of)\s)(.*)$', 1), '')
        ), '[^[:alnum:]]', '', 'g'), '') END AS source_key,
        CASE WHEN is_live_take THEN t1 ELSE regexp_replace(
            regexp_replace(t1, '\s*[\(\[]from\s[^\)\]]*[\)\]]', '', 'g'),
            '\s+-\s+(from\s|(opening|ending)\s(theme\s)?(to|from|of)\s|theme\s(from|of)\s).*$', ''
        ) END AS t2,

        -- 3. Same-recording version tags: "[Full Version]", " - 2011 Remaster", " - Radio Edit", " - Remasterisé en 2006"...
        regexp_replace(
            regexp_replace(t2,
                '\s*[\(\[][^\)\]]*(remaster|radio edit|single version|album version|full version|original version)[^\)\]]*[\)\]]', '', 'g'),
            '\s+-\s+[^-]*(remaster|radio edit|single version|album version|full version|original version)[^-]*$', ''
        ) AS t3,

        -- 4. Soundtrack tags: " - Hazbin Hotel Original Soundtrack", " - Original Game Soundtrack"
        regexp_replace(t3, '\s+-\s+[^-]*soundtrack[^-]*$', '') AS t4,

        -- 5. Japanese/Chinese/Korean title followed by its romanization or translation:
        --    "ピースサイン - Peace Sign", "堕天 - Daten". Not when the Latin part is a variant ("- TV Size", "- Live"...)
        CASE
            WHEN regexp_matches(t4, '^([^a-z]*[\p{Han}\p{Hiragana}\p{Katakana}\p{Hangul}][^a-z]*?)\s+-\s+([\x20-\x7e]+)$')
                AND NOT regexp_matches(
                    regexp_extract(t4, '^([^a-z]*[\p{Han}\p{Hiragana}\p{Katakana}\p{Hangul}][^a-z]*?)\s+-\s+([\x20-\x7e]+)$', 2),
                    '(live|remix|instrumental|version|ver\b|cover|acoustic|piano|mix|edit|inst\b|karaoke|off vocal|orchestra|reprise|slowed|sped|tv size|short|first take)')
            THEN regexp_extract(t4, '^([^a-z]*[\p{Han}\p{Hiragana}\p{Katakana}\p{Hangul}][^a-z]*?)\s+-\s+([\x20-\x7e]+)$', 1)
            ELSE t4
        END AS t5,

        trim(regexp_replace(t5, '\s*-\s*$', '')) AS base_title
    FROM with_title
),

sources_per_title AS (
    SELECT artist_key, base_title, COUNT(DISTINCT source_key) AS n_sources
    FROM stripped
    GROUP BY artist_key, base_title
),

normalized AS (
    SELECT
        s.*,
        CASE
            WHEN p.n_sources <= 1 THEN s.base_title
            -- Several sources for the same title: the source is part of the identity
            ELSE s.base_title || '|' || coalesce(s.source_key, '')
        END AS title_key
    FROM stripped s
    JOIN sources_per_title p USING (artist_key, base_title)
),

-- Work: the composition, whoever performs it. One level above the song: all the versions
-- of a song (live, cover, language, acoustic...) and all its performers share a work_id.
-- Source annotations only tell works apart for generic titles ("Main Theme", "Kakariko Village"),
-- i.e. titles an artist has from several sources.
-- seeds/work_aliases.csv: translated titles (Rabbit Hole = ラビットホール), and homonyms, by giving
-- one artist's song its own work name (Skillet's "Monster" is not Adventure Time's).
generic_titles AS (
    SELECT DISTINCT base_title FROM sources_per_title WHERE n_sources > 1
),

work_aliases AS (
    SELECT
        nullif(norm_name(artist), '') AS artist,
        fold_latin_accents(norm_name(title)) AS title,
        fold_latin_accents(norm_name(work)) AS work
    FROM read_csv('seeds/work_aliases.csv', all_varchar = true)
),

works AS (
    SELECT
        n.*,
        fold_latin_accents(strip_version_tags(n.base_title)) AS work_base,
        -- Display: the source title without its version tag
        strip_version_tags(n.track) AS work_display
    FROM normalized n
),

work_keys AS (
    SELECT
        w.*,
        coalesce(wa.work, w.work_base) AS work_title,
        CASE
            WHEN g.base_title IS NULL THEN coalesce(wa.work, w.work_base)
            -- Generic title: the source is the identity, or the song itself when there is none
            WHEN w.source_key IS NOT NULL THEN w.work_base || '|' || w.source_key
            ELSE w.work_base || '|' || w.artist_key
        END AS work_key
    FROM works w
    LEFT JOIN generic_titles g ON g.base_title = w.base_title
    LEFT JOIN work_aliases wa
        ON wa.title = w.work_base
        AND (wa.artist IS NULL OR wa.artist = w.artist_key)
    QUALIFY row_number() OVER (PARTITION BY w.track_id ORDER BY wa.artist NULLS LAST) = 1
)

SELECT
    track_id,
    md5(artist_key || '|' || title_key) AS song_id,
    -- Display the most played variant of the song (ties: the shortest, cleanest title)
    arg_max(track, row(plays, -length(track), track)) OVER song AS title,
    arg_max(display_artist, row(plays, display_artist)) OVER song AS artist,
    md5(work_key) AS work_id,
    arg_max(work_display, row(plays, -length(work_display), work_display)) OVER work AS work_title,
    track AS source_title,
    artist AS source_artist
FROM work_keys
WINDOW
    song AS (PARTITION BY artist_key, title_key),
    work AS (PARTITION BY work_key);

-- Every play, with its song and work
CREATE OR REPLACE VIEW int_music_play AS
SELECT p.*, s.song_id, s.title, s.artist AS song_artist, s.work_id, s.work_title
FROM stg_music_play p
JOIN int_song s USING (track_id);

SELECT
    COUNT(DISTINCT track_id) AS track_ids,
    COUNT(DISTINCT song_id) AS songs,
    COUNT(DISTINCT work_id) AS works
FROM int_song;
