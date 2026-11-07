-- work: top 20
SELECT work_title,
    adopted_performers,
    total_plays,
    beyond_main_plays,
    performer_plays[1:4] AS performers,
    round(score, 3) AS score
FROM mart_work
ORDER BY score DESC LIMIT 20;
