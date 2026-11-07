-- Intentionality
-- A song you seek out: when it plays, it's because you picked it (click, play, back button),
-- not because autoplay or shuffle served it. Songs that follow another one (trackdone) are
-- neutral: the export can't tell your own playlist from an album or radio.
-- Very short plays are ignored (see params.sql): mostly a "not now" skip when shuffle serves a song,
-- neither a listen nor a rejection. A later skip counts against the song.
-- Seeking out an album counts too: a track that plays inside an album session you started
-- (see int_album_play) is sought, at a lower weight than a song you picked directly.

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

        picked_plays + getvariable('intentionality_album_pick_weight') * album_sought_plays AS selected_plays,

        COUNT(*) FILTER (
            WHERE reason_end = 'fwdbtn'
        ) AS skipped_plays

    FROM int_music_play p
    LEFT JOIN int_album_play a USING (event_id)
    WHERE p.ms_played >= getvariable('real_play_min_ms') -- Ignore "not now" skips
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

    (selected_plays + getvariable('intentionality_prior_plays') * global_selected_rate)
        / (total_plays + getvariable('intentionality_prior_plays')) AS selected_rate,

    (skipped_plays + getvariable('intentionality_prior_plays') * global_skipped_rate)
        / (total_plays + getvariable('intentionality_prior_plays')) AS clicked_off_rate

FROM track_stats t
CROSS JOIN global_stats g;

.print mart_intentionality
-- Score on the (smoothed) rates directly rather than percentiles: rates are already 0-1,
-- keep the distance between songs and don't move when other songs are added.
-- trackdone (song followed the previous one) is neutral: neither selected nor skipped.
CREATE OR REPLACE TABLE mart_intentionality AS
SELECT
    *,
    getvariable('intentionality_weight_selected') * selected_rate
    + getvariable('intentionality_weight_not_skipped') * (1 - clicked_off_rate) AS score
FROM int_intentionality
WHERE total_plays >= getvariable('intentionality_min_plays') -- Enough plays for the rates to mean something
;
