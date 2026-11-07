
-- TODO: Add a "is valid week?" where if a week doesn't have a top 10, we ignore it?

.print int_week_charts
CREATE OR REPLACE TABLE int_week_charts AS
WITH weekly_track_count AS (
    SELECT
        date_trunc('week', timestamp) AS week_start,
        song_id,
        title,
        song_artist AS artist,
        COUNT(*) as total_week_song,
        -- Rank instead of dense_rank heavily punish songs are not sufficiently different in the week.
        -- => TODO: Do a tie-breaker based on listened time?
        RANK() OVER (
            PARTITION BY week_start
            order by total_week_song DESC) AS hit_chart

        FROM int_music_play
        WHERE count_as_play = true
        GROUP BY week_start, song_id, title, song_artist
    ),
max_week_hit AS (
    -- With this, we allow to filter by the actual highest value of the hit track. So a week where all songs are played once will have a max hit of 1
    -- meaning it is very low value to know,
    SELECT week_start, MAX(hit_chart) as max_hit FROM weekly_track_count GROUP BY week_start)

SELECT
    weekly_track_count.week_start,
    song_id,
    title,
    artist,
    total_week_song,
    hit_chart,
    h.max_hit AS max_hit
    FROM weekly_track_count
    INNER JOIN max_week_hit h ON h.week_start == weekly_track_count.week_start;
