CREATE SCHEMA IF NOT EXISTS api;

CREATE TABLE IF NOT EXISTS api.entries (
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  name text NOT NULL CHECK (char_length(name) BETWEEN 1 AND 40),
  message text NOT NULL CHECK (char_length(message) BETWEEN 1 AND 280),
  signal text NOT NULL CHECK (signal IN ('rocket','idea','fire','heart','star')),
  reactions int NOT NULL DEFAULT 0,
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE OR REPLACE VIEW api.stats AS
  SELECT (SELECT count(*) FROM api.entries) AS total_entries,
         (SELECT coalesce(sum(reactions),0) FROM api.entries) AS total_reactions,
         (SELECT count(DISTINCT name) FROM api.entries) AS unique_visitors;

CREATE OR REPLACE VIEW api.signal_counts AS
  SELECT s.signal, coalesce(c.count,0)::int AS count
  FROM (VALUES ('rocket'),('idea'),('fire'),('heart'),('star')) AS s(signal)
  LEFT JOIN (SELECT signal, count(*) AS count FROM api.entries GROUP BY signal) c USING (signal);

CREATE OR REPLACE FUNCTION api.react(entry_id bigint) RETURNS void
  LANGUAGE sql SECURITY DEFINER SET search_path = api AS $fn$
    UPDATE api.entries SET reactions = reactions + 1 WHERE id = entry_id;
  $fn$;

DO $do$ BEGIN
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname='web_anon') THEN CREATE ROLE web_anon NOLOGIN; END IF;
END $do$;
GRANT USAGE ON SCHEMA api TO web_anon;
GRANT SELECT ON api.entries, api.stats, api.signal_counts TO web_anon;
GRANT INSERT (name, message, signal) ON api.entries TO web_anon;
GRANT EXECUTE ON FUNCTION api.react(bigint) TO web_anon;

DO $do$ BEGIN
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname='authenticator') THEN CREATE ROLE authenticator NOINHERIT LOGIN PASSWORD 'AUTHPW_PLACEHOLDER'; END IF;
END $do$;
ALTER ROLE authenticator WITH PASSWORD 'AUTHPW_PLACEHOLDER';
GRANT web_anon TO authenticator;

INSERT INTO api.entries (name, message, signal)
SELECT * FROM (VALUES
 ('Ava','Deployed the whole stack in one afternoon — ingress, TLS, HA Postgres. Slick.','rocket'),
 ('Marco','The failover just worked when I drained a node. Zero data loss.','fire'),
 ('Priya','Longhorn + CloudNativePG is a surprisingly clean combo for self-hosting.','idea'),
 ('Sam','1,400 tps on three small nodes? Not bad at all.','star'),
 ('Lena','Love that Portainer stays on the tailnet and never touches the public internet.','heart'),
 ('Theo','cert-manager issued prod certs on the first try. Chef''s kiss.','rocket')
) v(name,message,signal)
WHERE NOT EXISTS (SELECT 1 FROM api.entries);
