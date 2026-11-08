-- Parameters
-- Every threshold and weight of the models, in one place. Change a value, then `just build`.
-- Models read them with getvariable('name').

-- Plays -----------------------------------------------------------------------------------
-- A play counts as a listen above this duration (stg_music_play.count_as_play)
SET VARIABLE counted_play_min_ms = 30000;
-- Below this, a play is a "not now" skip (shuffle served a song you don't want right now):
-- neither a listen nor a rejection (intentionality, album sessions)
SET VARIABLE real_play_min_ms = 10000;

-- Album sessions (int_album_play) ---------------------------------------------------------
-- A run of plays from the same album, with at most this gap between two plays...
SET VARIABLE album_session_max_gap_minutes = 20;
-- ...covering at least this many different tracks
SET VARIABLE album_session_min_tracks = 3;

-- long_standing: companions of life -------------------------------------------------------
SET VARIABLE long_standing_min_active_days = 7;      -- listened on at least N different days
SET VARIABLE long_standing_min_lifetime_months = 12; -- too young to tell below
SET VARIABLE long_standing_honeymoon_months = 3;     -- the first months, ignored by survival
SET VARIABLE long_standing_proven_months = 36;       -- after this, a song has proven it's not a fad
SET VARIABLE long_standing_weight_survival = 0.6;
SET VARIABLE long_standing_weight_proven = 0.4;

-- obsession: intense, on-loop listening ---------------------------------------------------
SET VARIABLE obsession_binge_day_plays = 3;   -- plays in a day to make it a binge day
SET VARIABLE obsession_min_binge_days = 2;    -- binged at least N times
SET VARIABLE obsession_album_play_weight = 0.5; -- a play inside an album session counts as this
SET VARIABLE obsession_weight_binge_days = 0.4;
SET VARIABLE obsession_weight_recurrence = 0.3;
SET VARIABLE obsession_weight_intensity = 0.3;

-- intentionality: songs you seek out ------------------------------------------------------
SET VARIABLE intentionality_album_pick_weight = 0.5; -- a track inside an album session you started
SET VARIABLE intentionality_prior_plays = 20;        -- smoothing towards your average rates
SET VARIABLE intentionality_min_plays = 10;
SET VARIABLE intentionality_weight_selected = 0.8;
SET VARIABLE intentionality_weight_not_skipped = 0.2;

-- work: love of the composition, beyond one performer -------------------------------------
SET VARIABLE work_adopted_min_plays = 3;     -- a performer's version you played N+ times
SET VARIABLE work_min_adopted_performers = 2;
SET VARIABLE work_weight_beyond_main = 0.5;
SET VARIABLE work_weight_adopted = 0.3;
SET VARIABLE work_weight_total = 0.2;

-- album: albums you live in ---------------------------------------------------------------
SET VARIABLE album_min_sessions = 2;
SET VARIABLE album_weight_sessions = 0.4;
SET VARIABLE album_weight_recurrence = 0.3;
SET VARIABLE album_weight_depth = 0.3;

-- song_features: every metric we can think of, to find which ones describe an emotional song --
SET VARIABLE features_min_plays = 10;          -- songs with fewer plays are left out
SET VARIABLE features_comeback_gap_days = 180; -- a return after this long a silence is a comeback
SET VARIABLE features_early_days = 30;         -- "early" plays: in the first N days with the song
SET VARIABLE features_session_gap_minutes = 30; -- a listening session ends after this long a pause
SET VARIABLE local_timezone = 'Europe/Zurich'; -- for hours and weekdays (99% of plays are in CH)

-- song_profile: a song is "strong" in a dimension when it's in that mart's top N -------------
SET VARIABLE profile_top_n = 100;
