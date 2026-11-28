CREATE TABLE index_steward.timescale_build_history (
    job_id bigint PRIMARY KEY REFERENCES index_steward.jobs(id) ON DELETE CASCADE,
    table_oid oid NOT NULL,
    method text NOT NULL,
    bytes bigint NOT NULL CHECK (bytes >= 0),
    chunks bigint NOT NULL CHECK (chunks >= 0),
    elapsed_seconds double precision NOT NULL CHECK (elapsed_seconds > 0),
    finished_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX ON index_steward.timescale_build_history(table_oid,method,finished_at DESC);
REVOKE ALL ON index_steward.timescale_build_history FROM PUBLIC;
