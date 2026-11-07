-- Love of the work
-- A composition you love so much it transcends artists: you listen to it by several
-- performers, not only the original. Built on work_id (see int_song): all the versions and
-- performers of a song share a work.
--   * adopted_performers: performers whose version you played several times
--     (one play of a cover is curiosity, not love)
--   * beyond_main_plays:  plays of the work outside its most played performer
--   * total_plays:        plays of the work, all performers together

.print int_work
CREATE OR REPLACE TABLE int_work AS
WITH

performers AS (
    SELECT
        work_id,
        song_artist AS performer,
        COUNT(*) AS plays
    FROM int_music_play
    WHERE count_as_play = true
    GROUP BY work_id, song_artist
),

titles AS (
    SELECT work_id, any_value(work_title) AS work_title
    FROM int_music_play
    GROUP BY work_id
)

SELECT
    work_id,
    work_title,
    COUNT(*) AS performers,
    COUNT(*) FILTER (WHERE plays >= getvariable('work_adopted_min_plays')) AS adopted_performers,
    SUM(plays) AS total_plays,
    arg_max(performer, row(plays, performer)) AS main_performer,
    MAX(plays) AS main_plays,
    SUM(plays) - MAX(plays) AS beyond_main_plays,
    list(performer || ' (' || plays || ')' ORDER BY plays DESC, performer) AS performer_plays
FROM performers
JOIN titles USING (work_id)
GROUP BY work_id, work_title;

.print mart_work
CREATE OR REPLACE TABLE mart_work AS
WITH scores AS (
    SELECT
        *,
        PERCENT_RANK() OVER (ORDER BY beyond_main_plays) AS beyond_main_score,
        PERCENT_RANK() OVER (ORDER BY adopted_performers) AS adopted_score,
        PERCENT_RANK() OVER (ORDER BY total_plays) AS total_score
    FROM int_work
    WHERE adopted_performers >= getvariable('work_min_adopted_performers')
)
SELECT
    *,
    getvariable('work_weight_beyond_main') * beyond_main_score
    + getvariable('work_weight_adopted') * adopted_score
    + getvariable('work_weight_total') * total_score AS score
FROM scores;
