ALTER TABLE index_steward.jobs ADD COLUMN attempts integer NOT NULL DEFAULT 0;
ALTER TABLE index_steward.jobs ADD COLUMN next_attempt_at timestamptz NOT NULL DEFAULT '-infinity';
ALTER TABLE index_steward.jobs ADD COLUMN reason text;
ALTER TABLE index_steward.jobs ADD COLUMN last_started_at timestamptz;

CREATE TABLE index_steward.policy (
    singleton boolean PRIMARY KEY DEFAULT true CHECK (singleton),
    paused boolean NOT NULL DEFAULT false,
    allowed_schemas name[],
    allowed_tables text[],
    daily_limit integer NOT NULL DEFAULT 12 CHECK (daily_limit BETWEEN 1 AND 100),
    retry_limit integer NOT NULL DEFAULT 12 CHECK (retry_limit BETWEEN 1 AND 100),
    min_free_bytes bigint NOT NULL DEFAULT 1073741824 CHECK (min_free_bytes >= 0),
    max_table_bytes bigint NOT NULL DEFAULT 5368709120 CHECK (max_table_bytes > 0)
);
INSERT INTO index_steward.policy DEFAULT VALUES;

CREATE TABLE index_steward.attempts (
    job_id bigint NOT NULL REFERENCES index_steward.jobs ON DELETE CASCADE,
    attempt integer NOT NULL,
    started_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    PRIMARY KEY (job_id, attempt)
);
CREATE INDEX ON index_steward.attempts(started_at);
REVOKE ALL ON index_steward.attempts FROM PUBLIC;

CREATE FUNCTION index_steward.log_event(event text, job_id bigint, action text, reason text, retry_at text)
RETURNS void AS 'MODULE_PATHNAME', 'steward_log_event'
LANGUAGE C;

CREATE OR REPLACE VIEW index_steward.recommendations AS
SELECT id, action, state, target, detail, created_at, updated_at, message,
       attempts, next_attempt_at, reason, last_started_at
FROM index_steward.jobs;

REVOKE ALL ON index_steward.policy FROM PUBLIC;
REVOKE ALL ON FUNCTION index_steward.log_event(text,bigint,text,text,text) FROM PUBLIC;
