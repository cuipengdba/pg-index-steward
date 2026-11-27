\echo Use CREATE EXTENSION pg_index_steward \quit

REVOKE ALL ON SCHEMA index_steward FROM PUBLIC;

CREATE FUNCTION index_steward.candidates(sql text) RETURNS jsonb
AS 'MODULE_PATHNAME', 'steward_candidates'
LANGUAGE C STRICT;

CREATE FUNCTION index_steward.settings()
RETURNS TABLE (auto_create bool, maintenance_window text, auto_drop_existing bool, auto_drop_managed bool)
LANGUAGE sql STABLE SET search_path = pg_catalog
AS $$
    SELECT COALESCE(current_setting('pg_index_steward.auto_create', true)::bool, true),
           COALESCE(current_setting('pg_index_steward.maintenance_window', true), '23:00-06:00'),
           COALESCE(current_setting('pg_index_steward.auto_drop_existing', true)::bool, false),
           COALESCE(current_setting('pg_index_steward.auto_drop_managed', true)::bool, true)
$$;

CREATE TABLE index_steward.workload (
    userid oid NOT NULL,
    queryid bigint NOT NULL,
    toplevel bool NOT NULL,
    snapshot jsonb NOT NULL,
    PRIMARY KEY (userid, queryid, toplevel)
);

CREATE TABLE index_steward.index_usage (
    index_oid oid PRIMARY KEY,
    fingerprint text NOT NULL,
    scans bigint NOT NULL,
    observed_at timestamptz NOT NULL,
    idle_since timestamptz NOT NULL,
    reset_marker text NOT NULL
);

CREATE TABLE index_steward.managed_indexes (
    index_oid oid PRIMARY KEY,
    table_oid oid NOT NULL,
    fingerprint text NOT NULL,
    ddl text NOT NULL,
    build_job bigint NOT NULL,
    created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    retired_at timestamptz
);

CREATE TABLE index_steward.jobs (
    id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    action text NOT NULL CHECK (action IN ('create', 'drop')),
    state text NOT NULL DEFAULT 'queued' CHECK (state IN ('queued', 'running', 'done', 'failed', 'cancelled')),
    target oid NOT NULL,
    signature text NOT NULL,
    detail jsonb NOT NULL,
    created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    updated_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    message text
);

CREATE UNIQUE INDEX steward_active_job ON index_steward.jobs (action, target, signature)
WHERE state IN ('queued','running');

CREATE TABLE index_steward.verdicts (
    job_id bigint PRIMARY KEY REFERENCES index_steward.jobs,
    index_oid oid NOT NULL,
    index_fingerprint text NOT NULL,
    baseline jsonb NOT NULL,
    observations jsonb NOT NULL DEFAULT '[]',
    state text NOT NULL DEFAULT 'observing',
    updated_at timestamptz NOT NULL DEFAULT clock_timestamp()
);

CREATE VIEW index_steward.recommendations AS
SELECT id, action, state, target, detail, created_at, updated_at, message
FROM index_steward.jobs;

REVOKE ALL ON ALL TABLES IN SCHEMA index_steward FROM PUBLIC;
REVOKE ALL ON ALL FUNCTIONS IN SCHEMA index_steward FROM PUBLIC;
