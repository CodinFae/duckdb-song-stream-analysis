-- Intentionality
-- A song you seek out: when it plays, it's because you picked it (click, play, back button),
-- not because autoplay or shuffle served it. Songs that follow another one (trackdone) are
-- neutral: the export can't tell your own playlist from an album or radio.
-- Plays shorter than 10s are ignored: mostly a "not now" skip when shuffle serves a song,
-- neither a listen nor a rejection. A skip after 10s counts against the song.
-- Seeking out an album counts too: a track that plays inside an album session you started
-- (see int_album_play) is sought, at half the weight of a song you picked directly.

.print int_intentionality
CREATE OR REPLACE TABLE int_intentionality AS
WITH track_stats AS (
    SELECT
        song_id,
        title,
        song_artist AS artist,
        COUNT(*) AS total_plays,

        COUNT(*) FILTER (
            WHERE reason_start IN ('clickrow', 'playbtn','backbtn')
        ) AS picked_plays,

        -- Not picked directly, but inside an album session you started
        COUNT(*) FILTER (
            WHERE reason_start NOT IN ('clickrow', 'playbtn','backbtn')
                AND a.started_by_you
        ) AS album_sought_plays,

        picked_plays + 0.5 * album_sought_plays AS selected_plays,

        COUNT(*) FILTER (
            WHERE reason_end = 'fwdbtn'
        ) AS skipped_plays

    FROM int_music_play p
    LEFT JOIN int_album_play a USING (event_id)
    WHERE p.ms_played >= 10000 -- Ignore "not now" skips
    GROUP BY song_id, title, song_artist
),

global_stats AS (
    SELECT
        SUM(selected_plays) * 1.0 / SUM(total_plays)
            AS global_selected_rate,

        SUM(skipped_plays) * 1.0 / SUM(total_plays)
            AS global_skipped_rate
    FROM track_stats
)

SELECT
    t.*,

    (selected_plays + 20 * global_selected_rate)
        / (total_plays + 20) AS selected_rate,

    (skipped_plays + 20 * global_skipped_rate)
        / (total_plays + 20) AS clicked_off_rate

FROM track_stats t
CROSS JOIN global_stats g;

.print mart_intentionality
-- Score on the (smoothed) rates directly rather than percentiles: rates are already 0-1,
-- keep the distance between songs and don't move when other songs are added.
-- trackdone (song followed the previous one) is neutral: neither selected nor skipped.
CREATE OR REPLACE TABLE mart_intentionality AS
SELECT
    *,
    0.8 * selected_rate
    + 0.2 * (1 - clicked_off_rate) AS score
FROM int_intentionality
WHERE total_plays >= 10 -- Enough plays for the rates to mean something
;


-- Reporting
SELECT title, artist,
    total_plays,
    round(selected_rate, 3) AS selected_rate,
    round(clicked_off_rate, 3) AS clicked_off_rate,
    score
FROM mart_intentionality
ORDER BY score DESC LIMIT 20;
