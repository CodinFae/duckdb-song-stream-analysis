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
        ) AS selected_plays,

        COUNT(*) FILTER (
            WHERE reason_end = 'fwdbtn'
        ) AS skipped_plays

    FROM int_music_play
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
