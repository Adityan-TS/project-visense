-- =============================================================================
-- ViSense database setup — run once in Databricks: SQL Editor -> paste -> Run all.
-- (The app also runs these CREATE ... IF NOT EXISTS statements on first launch,
--  so this is only needed if the app's token isn't allowed to create objects.)
-- =============================================================================

CREATE SCHEMA IF NOT EXISTS workspace.visense
  COMMENT 'ViSense caption glasses: users and their timestamped transcripts';

-- One row per app install ("user entity"), created automatically by the app.
CREATE TABLE IF NOT EXISTS workspace.visense.users (
  user_id      STRING    NOT NULL COMMENT 'random ID generated on the phone',
  display_name STRING             COMMENT 'device name, editable later',
  timezone     STRING             COMMENT 'IANA zone of the phone, e.g. Asia/Kolkata',
  created_at   TIMESTAMP          COMMENT 'first seen (UTC)',
  last_seen_at TIMESTAMP          COMMENT 'last upload (UTC)'
) COMMENT 'ViSense users';

-- Every finished caption line.
CREATE TABLE IF NOT EXISTS workspace.visense.transcripts (
  line_id    STRING    NOT NULL COMMENT 'unique per line (UUID from the phone)',
  user_id    STRING    NOT NULL COMMENT 'owner, see users',
  session_id STRING    NOT NULL COMMENT 'one conversation (Start captions .. stop / 5 min silence)',
  ts         TIMESTAMP NOT NULL COMMENT 'when the line was spoken (UTC)',
  text       STRING    NOT NULL COMMENT 'caption text (with "Name: " in front when the speaker is known)',
  speaker    STRING             COMMENT 'who said it (voice match on the phone), NULL if unknown',
  duration_ms BIGINT            COMMENT 'how long the line took to say (talk time)'
) CLUSTER BY (user_id, ts)
  COMMENT 'ViSense transcripts, one row per finished caption line';

-- Tables created before speaker names: add the columns (the app also does this).
-- ALTER TABLE workspace.visense.transcripts ADD COLUMNS (speaker STRING, duration_ms BIGINT);

-- ---------------------------------------------------------------- handy queries
-- Talk time per person this week:
--   SELECT speaker, round(sum(duration_ms) / 60000, 1) AS minutes, count(*) AS lines
--   FROM workspace.visense.transcripts
--   WHERE user_id = '<id>' AND ts >= current_timestamp() - INTERVAL 7 DAYS
--   GROUP BY speaker ORDER BY minutes DESC;
--
-- Users and how much they recorded:
--   SELECT u.user_id, u.display_name, count(t.line_id) AS lines, max(t.ts) AS last_line
--   FROM workspace.visense.users u LEFT JOIN workspace.visense.transcripts t USING (user_id)
--   GROUP BY ALL ORDER BY last_line DESC;
--
-- One user's conversations:
--   SELECT session_id, min(ts) AS started, max(ts) AS ended, count(*) AS lines
--   FROM workspace.visense.transcripts WHERE user_id = '<id>' GROUP BY session_id ORDER BY started DESC;
