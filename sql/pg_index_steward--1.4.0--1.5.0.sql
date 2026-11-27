CREATE TABLE index_steward.latency_samples (
    queryid bigint NOT NULL, sampled_at timestamptz NOT NULL,
    p95_ms double precision NOT NULL CHECK (p95_ms >= 0 AND p95_ms < 'Infinity'::float8),
    calls bigint NOT NULL CHECK (calls > 0), PRIMARY KEY(queryid,sampled_at)
);
ALTER TABLE index_steward.verdicts ADD COLUMN comparison jsonb NOT NULL DEFAULT '{}';
REVOKE ALL ON index_steward.latency_samples FROM PUBLIC;
