-- obsession: top 20
SELECT title, artist,
    total_plays,
    binge_days,
    binge_months,
    max_day,
    round(binge_share, 2) AS binge_share,
    round(score, 3) AS score
FROM mart_obsession
ORDER BY score DESC, binge_days DESC LIMIT 20;
