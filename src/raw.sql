CREATE OR REPLACE TABLE raw_spotify_data AS
SELECT * FROM read_json('data/*.json');
