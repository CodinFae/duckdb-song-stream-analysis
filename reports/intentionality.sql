-- intentionality: top 20
SELECT title, artist,
    total_plays,
    round(selected_rate, 3) AS selected_rate,
    round(clicked_off_rate, 3) AS clicked_off_rate,
    score
FROM mart_intentionality
ORDER BY score DESC LIMIT 20;
