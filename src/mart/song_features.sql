-- Song features
-- Every metric we can compute per song, most of them used by no dimension. The idea is to throw as
-- much as possible at the wall, then let the explorer's "Emotional" section find which ones describe
-- the songs you label as emotional (reverse engineering, not a definition).
-- Raw values here: the explorer turns them into percentiles before learning. Each column's comment
-- reads "<group>: <meaning>", and the explorer shows it next to the results.
-- "plays" are plays above 30s; choice metrics use real plays (10s+, shorter is a "not now" skip).
-- Songs with too few plays to measure anything are left out (params.sql).

.print mart_song_features
CREATE OR REPLACE TABLE mart_song_features AS
WITH

dataset AS (
    SELECT MAX(timestamp) AS last_ts
    FROM int_music_play
),

events AS (
    SELECT
        p.song_id,
        p.event_id,
        p.track_id,
        p.album,
        p.timestamp,
        timezone(getvariable('local_timezone'), p.timestamp) AS local_ts,
        p.ms_played,
        p.count_as_play,
        p.ms_played >= getvariable('real_play_min_ms') AS is_real,
        p.reason_start,
        p.reason_end,
        p.shuffle,
        p.platform,
        a.event_id IS NOT NULL AS in_album_session,
        -- Neighbours among real plays (lag/lead in the "not real" partition are unused)
        lag(p.song_id) OVER real_plays AS prev_song_id,
        lag(p.timestamp) OVER real_plays AS prev_ts,
        lead(p.timestamp) OVER real_plays AS next_ts
    FROM int_music_play p
    LEFT JOIN int_album_play a USING (event_id)
    WINDOW real_plays AS (
        PARTITION BY p.ms_played >= getvariable('real_play_min_ms')
        ORDER BY p.timestamp, p.event_id
    )
),

song_events AS (
    SELECT
        song_id,
        MIN(timestamp) FILTER (WHERE count_as_play) AS first_play,
        MAX(timestamp) FILTER (WHERE count_as_play) AS last_play,
        SUM(ms_played) FILTER (WHERE count_as_play) / 60000 AS minutes,
        MAX(ms_played) / 1000 AS length_s,
        COUNT(DISTINCT date_trunc('week', local_ts)) FILTER (WHERE count_as_play) AS active_weeks,
        COUNT(DISTINCT year(local_ts)) FILTER (WHERE count_as_play) AS active_years,
        COUNT(DISTINCT track_id) AS versions,
        COUNT(DISTINCT album) AS albums,

        avg((hour(local_ts) < 6)::INT) FILTER (WHERE count_as_play) AS night_share,
        avg((hour(local_ts) BETWEEN 6 AND 11)::INT) FILTER (WHERE count_as_play) AS morning_share,
        avg((hour(local_ts) >= 18)::INT) FILTER (WHERE count_as_play) AS evening_share,
        avg((isodow(local_ts) >= 6)::INT) FILTER (WHERE count_as_play) AS weekend_share,

        avg(shuffle::INT) FILTER (WHERE count_as_play) AS shuffle_share,
        avg((platform ILIKE '%ios%' OR platform ILIKE '%android%')::INT) FILTER (WHERE count_as_play) AS mobile_share,
        avg(in_album_session::INT) FILTER (WHERE count_as_play) AS album_session_share,
        avg((prev_song_id = song_id)::INT) FILTER (WHERE is_real) AS repeat_share,
        avg((prev_ts IS NULL OR timestamp - prev_ts > to_minutes(getvariable('features_session_gap_minutes')))::INT)
            FILTER (WHERE is_real) AS session_opener_share,
        avg((next_ts IS NULL OR next_ts - timestamp > to_minutes(getvariable('features_session_gap_minutes')))::INT)
            FILTER (WHERE is_real) AS session_closer_share,

        avg((reason_start IN ('clickrow', 'playbtn', 'backbtn'))::INT) FILTER (WHERE is_real) AS picked_share,
        avg((reason_start = 'clickrow')::INT) FILTER (WHERE is_real) AS clickrow_share,
        avg((reason_start = 'backbtn')::INT) FILTER (WHERE is_real) AS backbtn_share,
        avg((reason_start = 'fwdbtn')::INT) FILTER (WHERE is_real) AS landed_after_skip_share,
        avg((reason_start = 'trackdone')::INT) FILTER (WHERE is_real) AS followed_share,
        avg((reason_end = 'fwdbtn')::INT) FILTER (WHERE is_real) AS skipped_share,
        avg((reason_end = 'trackdone')::INT) FILTER (WHERE is_real) AS completed_share,
        avg((reason_end = 'endplay')::INT) FILTER (WHERE is_real) AS stopped_share,
        avg((NOT is_real)::INT) AS not_now_share,
        median(ms_played) FILTER (WHERE is_real) / nullif(MAX(ms_played), 0) AS listened_ratio,

        arg_min(reason_start IN ('clickrow', 'playbtn', 'backbtn'), row(timestamp, event_id))
            FILTER (WHERE is_real) AS discovered_by_choice,
        arg_min(shuffle, row(timestamp, event_id)) FILTER (WHERE is_real) AS discovered_on_shuffle
    FROM events
    GROUP BY song_id
),

hours AS (
    SELECT song_id, COUNT(*) / SUM(COUNT(*)) OVER (PARTITION BY song_id) AS p
    FROM events
    WHERE count_as_play
    GROUP BY song_id, hour(local_ts)
),

hour_stats AS (
    -- Spread over the hours of the day: 0 = always the same hour, 1 = any hour
    SELECT song_id, -SUM(p * ln(p)) / ln(24) AS hour_spread
    FROM hours
    GROUP BY song_id
),

periods AS (
    SELECT
        e.song_id,
        avg((e.timestamp < s.first_play + to_days(getvariable('features_early_days')))::INT) AS early_share,
        avg((e.timestamp < s.first_play + INTERVAL 1 YEAR)::INT) AS first_year_share,
        avg((e.timestamp > d.last_ts - INTERVAL 1 YEAR)::INT) AS last_year_share
    FROM events e
    JOIN song_events s USING (song_id)
    CROSS JOIN dataset d
    WHERE e.count_as_play
    GROUP BY e.song_id
),

days AS (
    SELECT
        song_id,
        day,
        raw_plays,
        is_binge,
        date_diff('day', lag(day) OVER (PARTITION BY song_id ORDER BY day), day) AS gap,
        -- Consecutive days share the same key (gaps and islands)
        day - (row_number() OVER (PARTITION BY song_id ORDER BY day))::INT AS streak_key
    FROM int_song_day
),

day_stats AS (
    SELECT
        song_id,
        COUNT(*) AS active_days,
        MAX(raw_plays) AS max_day_plays,
        avg(raw_plays) AS plays_per_active_day,
        COUNT(*) FILTER (WHERE is_binge) AS binge_days,
        COUNT(DISTINCT date_trunc('month', day)) FILTER (WHERE is_binge) AS binge_months,
        coalesce(SUM(raw_plays) FILTER (WHERE is_binge), 0) / SUM(raw_plays) AS binge_share,
        MAX(gap) AS longest_gap_days,
        median(gap) AS median_gap_days,
        COUNT(*) FILTER (WHERE gap >= getvariable('features_comeback_gap_days')) AS comebacks,
        -- Gaps between active days: -1 = like clockwork, 0 = random, 1 = in bursts
        (stddev_pop(gap) - avg(gap)) / nullif(stddev_pop(gap) + avg(gap), 0) AS burstiness
    FROM days
    GROUP BY song_id
),

streaks AS (
    SELECT song_id, MAX(n) AS longest_streak_days
    FROM (SELECT song_id, streak_key, COUNT(*) AS n FROM days GROUP BY song_id, streak_key)
    GROUP BY song_id
),

months AS (
    SELECT
        song_id,
        date_trunc('month', day) AS month,
        SUM(raw_plays) AS plays,
        SUM(raw_plays) / SUM(SUM(raw_plays)) OVER (PARTITION BY song_id) AS p
    FROM int_song_day
    GROUP BY song_id, month
),

month_stats AS (
    SELECT
        song_id,
        COUNT(*) AS active_months,
        MAX(p) AS peak_month_share,
        date_diff('month', MIN(month), arg_max(month, row(plays, month))) AS months_to_peak,
        -- Evenness of plays across its active months: 1 = as much every month
        coalesce(-SUM(p * ln(p)) / nullif(ln(COUNT(*)), 0), 1) AS month_evenness
    FROM months
    GROUP BY song_id
),

artists AS (
    SELECT
        artist,
        SUM(plays) AS artist_plays,
        COUNT(*) FILTER (WHERE plays >= getvariable('work_adopted_min_plays')) AS artist_songs
    FROM mart_song_profile
    GROUP BY artist
),

main_album AS (
    SELECT song_id, arg_max(album, row(n, album)) AS album
    FROM (SELECT song_id, album, COUNT(*) AS n FROM int_music_play GROUP BY song_id, album)
    GROUP BY song_id
)

SELECT
    p.song_id,
    p.title,
    p.artist,

    -- volume
    p.plays::DOUBLE AS plays,
    se.minutes::DOUBLE AS minutes,
    ds.active_days::DOUBLE AS active_days,
    se.active_weeks::DOUBLE AS active_weeks,
    ms.active_months::DOUBLE AS active_months,
    se.active_years::DOUBLE AS active_years,

    -- time: the song's life with you
    ls.lifetime_months::DOUBLE AS lifetime_months,
    ls.survival_rate::DOUBLE AS survival_rate,
    (p.plays / ls.lifetime_months)::DOUBLE AS plays_per_lifetime_month,
    pe.early_share::DOUBLE AS early_share,
    pe.first_year_share::DOUBLE AS first_year_share,
    ms.peak_month_share::DOUBLE AS peak_month_share,
    ms.months_to_peak::DOUBLE AS months_to_peak,
    round(ms.month_evenness, 9)::DOUBLE AS month_evenness, -- rounded: float sums vary with thread order
    ds.longest_gap_days::DOUBLE AS longest_gap_days,
    ds.median_gap_days::DOUBLE AS median_gap_days,
    ds.comebacks::DOUBLE AS comebacks,
    round(ds.burstiness, 9)::DOUBLE AS burstiness,

    -- loop: intensity on the day
    ds.binge_days::DOUBLE AS binge_days,
    ds.binge_months::DOUBLE AS binge_months,
    ds.binge_share::DOUBLE AS binge_share,
    ds.max_day_plays::DOUBLE AS max_day_plays,
    ds.plays_per_active_day::DOUBLE AS plays_per_active_day,
    st.longest_streak_days::DOUBLE AS longest_streak_days,
    se.repeat_share::DOUBLE AS repeat_share,

    -- choice
    se.picked_share::DOUBLE AS picked_share,
    se.clickrow_share::DOUBLE AS clickrow_share,
    se.backbtn_share::DOUBLE AS backbtn_share,
    se.followed_share::DOUBLE AS followed_share,
    se.landed_after_skip_share::DOUBLE AS landed_after_skip_share,
    se.skipped_share::DOUBLE AS skipped_share,
    se.completed_share::DOUBLE AS completed_share,
    se.stopped_share::DOUBLE AS stopped_share,
    se.not_now_share::DOUBLE AS not_now_share,
    se.listened_ratio::DOUBLE AS listened_ratio,
    se.shuffle_share::DOUBLE AS shuffle_share,
    se.discovered_by_choice::DOUBLE AS discovered_by_choice,
    se.discovered_on_shuffle::DOUBLE AS discovered_on_shuffle,

    -- when and how
    se.night_share::DOUBLE AS night_share,
    se.morning_share::DOUBLE AS morning_share,
    se.evening_share::DOUBLE AS evening_share,
    se.weekend_share::DOUBLE AS weekend_share,
    round(hs.hour_spread, 9)::DOUBLE AS hour_spread,
    se.mobile_share::DOUBLE AS mobile_share,
    se.session_opener_share::DOUBLE AS session_opener_share,
    se.session_closer_share::DOUBLE AS session_closer_share,
    se.album_session_share::DOUBLE AS album_session_share,

    -- context: the song among its artist, its work, its album
    se.length_s::DOUBLE AS length_s,
    se.versions::DOUBLE AS versions,
    se.albums::DOUBLE AS albums,
    (p.plays / ar.artist_plays)::DOUBLE AS artist_share,
    ar.artist_songs::DOUBLE AS artist_songs,
    w.adopted_performers::DOUBLE AS work_performers,
    (p.plays / w.total_plays)::DOUBLE AS work_share,
    regexp_matches(ma.album, '(?i)(soundtrack|\bost\b|original score|music from|game music|サウンドトラック|from the series|motion picture)')::DOUBLE AS soundtrack,
    regexp_matches(p.title || p.artist, '[\p{Han}\p{Hiragana}\p{Katakana}\p{Hangul}]')::DOUBLE AS cjk_script,

    -- dimensions: the existing scores (0 = not in the dimension)
    coalesce(p.companion_pct, 0)::DOUBLE AS companion_pct,
    coalesce(p.obsession_pct, 0)::DOUBLE AS obsession_pct,
    coalesce(p.sought_pct, 0)::DOUBLE AS sought_pct,
    coalesce(p.work_score, 0)::DOUBLE AS work_score,
    coalesce(p.album_score, 0)::DOUBLE AS album_score,

    -- recency: depends on when the export was made, not on the song
    date_diff('day', p.first_play, d.last_ts)::DOUBLE AS days_since_first_play,
    date_diff('day', p.last_play, d.last_ts)::DOUBLE AS days_since_last_play,
    pe.last_year_share::DOUBLE AS last_year_share

FROM mart_song_profile p
JOIN song_events se USING (song_id)
JOIN day_stats ds USING (song_id)
JOIN streaks st USING (song_id)
JOIN month_stats ms USING (song_id)
JOIN hour_stats hs USING (song_id)
JOIN periods pe USING (song_id)
JOIN int_long_standing ls USING (song_id)
JOIN artists ar ON ar.artist = p.artist
JOIN main_album ma USING (song_id)
LEFT JOIN int_work w ON w.work_id = p.work_id
CROSS JOIN dataset d
WHERE p.plays >= getvariable('features_min_plays');

COMMENT ON COLUMN mart_song_features.plays IS 'volume: plays (30s+)';
COMMENT ON COLUMN mart_song_features.minutes IS 'volume: minutes listened';
COMMENT ON COLUMN mart_song_features.active_days IS 'volume: days it was played';
COMMENT ON COLUMN mart_song_features.active_weeks IS 'volume: weeks it was played';
COMMENT ON COLUMN mart_song_features.active_months IS 'volume: months it was played';
COMMENT ON COLUMN mart_song_features.active_years IS 'volume: calendar years it was played';
COMMENT ON COLUMN mart_song_features.lifetime_months IS 'time: months from first to last play';
COMMENT ON COLUMN mart_song_features.survival_rate IS 'time: share of months played after the 3-month honeymoon (companion)';
COMMENT ON COLUMN mart_song_features.plays_per_lifetime_month IS 'time: plays per month of life';
COMMENT ON COLUMN mart_song_features.early_share IS 'time: share of plays in the first 30 days (a fad is front-loaded)';
COMMENT ON COLUMN mart_song_features.first_year_share IS 'time: share of plays in the first year';
COMMENT ON COLUMN mart_song_features.peak_month_share IS 'time: share of plays in its biggest month';
COMMENT ON COLUMN mart_song_features.months_to_peak IS 'time: months from first play to its biggest month (slow burn)';
COMMENT ON COLUMN mart_song_features.month_evenness IS 'time: plays spread evenly across its active months (1) or in one (0)';
COMMENT ON COLUMN mart_song_features.longest_gap_days IS 'time: longest silence between two days it was played';
COMMENT ON COLUMN mart_song_features.median_gap_days IS 'time: typical days between two days it was played';
COMMENT ON COLUMN mart_song_features.comebacks IS 'time: returns after 6+ months of silence';
COMMENT ON COLUMN mart_song_features.burstiness IS 'time: days played in bursts (1) or like clockwork (-1)';
COMMENT ON COLUMN mart_song_features.binge_days IS 'loop: days with 3+ plays';
COMMENT ON COLUMN mart_song_features.binge_months IS 'loop: months with a binge day';
COMMENT ON COLUMN mart_song_features.binge_share IS 'loop: share of plays on binge days';
COMMENT ON COLUMN mart_song_features.max_day_plays IS 'loop: most plays in a day';
COMMENT ON COLUMN mart_song_features.plays_per_active_day IS 'loop: plays per day it was played';
COMMENT ON COLUMN mart_song_features.longest_streak_days IS 'loop: most days in a row it was played';
COMMENT ON COLUMN mart_song_features.repeat_share IS 'loop: share of plays right after itself (strict loop)';
COMMENT ON COLUMN mart_song_features.picked_share IS 'choice: share of plays you started (click, play, back)';
COMMENT ON COLUMN mart_song_features.clickrow_share IS 'choice: share of plays started by clicking it in a list';
COMMENT ON COLUMN mart_song_features.backbtn_share IS 'choice: share of plays started with the back button (replay)';
COMMENT ON COLUMN mart_song_features.followed_share IS 'choice: share of plays that followed the previous song';
COMMENT ON COLUMN mart_song_features.landed_after_skip_share IS 'choice: share of plays reached by skipping the previous song';
COMMENT ON COLUMN mart_song_features.skipped_share IS 'choice: share of plays you skipped (after 10s)';
COMMENT ON COLUMN mart_song_features.completed_share IS 'choice: share of plays that went to the end';
COMMENT ON COLUMN mart_song_features.stopped_share IS 'choice: share of plays you stopped (pause, other song)';
COMMENT ON COLUMN mart_song_features.not_now_share IS 'choice: share of plays skipped within 10s (not now)';
COMMENT ON COLUMN mart_song_features.listened_ratio IS 'choice: typical play length / longest play';
COMMENT ON COLUMN mart_song_features.shuffle_share IS 'choice: share of plays on shuffle';
COMMENT ON COLUMN mart_song_features.discovered_by_choice IS 'choice: its first play was started by you';
COMMENT ON COLUMN mart_song_features.discovered_on_shuffle IS 'choice: its first play was on shuffle';
COMMENT ON COLUMN mart_song_features.night_share IS 'when: share of plays 0-6h';
COMMENT ON COLUMN mart_song_features.morning_share IS 'when: share of plays 6-12h';
COMMENT ON COLUMN mart_song_features.evening_share IS 'when: share of plays 18-24h';
COMMENT ON COLUMN mart_song_features.weekend_share IS 'when: share of plays on weekends';
COMMENT ON COLUMN mart_song_features.hour_spread IS 'when: played at any hour (1) or always the same hour (0)';
COMMENT ON COLUMN mart_song_features.mobile_share IS 'how: share of plays on the phone';
COMMENT ON COLUMN mart_song_features.session_opener_share IS 'how: share of plays opening a listening session';
COMMENT ON COLUMN mart_song_features.session_closer_share IS 'how: share of plays closing a listening session';
COMMENT ON COLUMN mart_song_features.album_session_share IS 'how: share of plays inside an album session';
COMMENT ON COLUMN mart_song_features.length_s IS 'context: song length (longest play, seconds)';
COMMENT ON COLUMN mart_song_features.versions IS 'context: Spotify tracks merged into this song';
COMMENT ON COLUMN mart_song_features.albums IS 'context: albums it was played from';
COMMENT ON COLUMN mart_song_features.artist_share IS 'context: share of its artist''s plays';
COMMENT ON COLUMN mart_song_features.artist_songs IS 'context: songs of its artist you played 3+ times';
COMMENT ON COLUMN mart_song_features.work_performers IS 'context: performers of its work you adopted';
COMMENT ON COLUMN mart_song_features.work_share IS 'context: share of its work''s plays (1 = the only version)';
COMMENT ON COLUMN mart_song_features.soundtrack IS 'context: its main album looks like a soundtrack (heuristic)';
COMMENT ON COLUMN mart_song_features.cjk_script IS 'context: Japanese/Chinese/Korean title or artist';
COMMENT ON COLUMN mart_song_features.companion_pct IS 'dimension: companion position (1 = top, 0 = not in it)';
COMMENT ON COLUMN mart_song_features.obsession_pct IS 'dimension: obsession position (1 = top, 0 = not in it)';
COMMENT ON COLUMN mart_song_features.sought_pct IS 'dimension: sought position (1 = top, 0 = not in it)';
COMMENT ON COLUMN mart_song_features.work_score IS 'dimension: work score of its composition';
COMMENT ON COLUMN mart_song_features.album_score IS 'dimension: album score of its main album';
COMMENT ON COLUMN mart_song_features.days_since_first_play IS 'recency: days since its first play';
COMMENT ON COLUMN mart_song_features.days_since_last_play IS 'recency: days since its last play';
COMMENT ON COLUMN mart_song_features.last_year_share IS 'recency: share of plays in the last 12 months';
