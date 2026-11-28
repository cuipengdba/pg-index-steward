CREATE TABLE index_steward.timescale_usage (
    build_job bigint PRIMARY KEY REFERENCES index_steward.jobs(id) ON DELETE CASCADE,
    snapshot jsonb NOT NULL,
    observed_at timestamptz NOT NULL,
    idle_since timestamptz NOT NULL
);
REVOKE ALL ON index_steward.timescale_usage FROM PUBLIC;

ALTER TABLE index_steward.policy ADD COLUMN timescale_retirement boolean NOT NULL DEFAULT true;
