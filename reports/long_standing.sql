-- long_standing: top 20
SELECT title, artist,
    strftime(first_play, '%Y-%m') AS since,
    lifetime_months AS life_months,
    format('{0}/{1}', post_honeymoon_active_months, post_honeymoon_months) AS months_after_honeymoon,
    round(survival_rate, 2) AS survival,
    round(proven, 2) AS proven,
    round(score, 3) AS score
FROM mart_long_standing
ORDER BY score DESC, active_days DESC LIMIT 20;
