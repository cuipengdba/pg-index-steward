CREATE TABLE index_steward.query_diagnostics (
    userid oid NOT NULL,
    queryid bigint NOT NULL,
    toplevel boolean NOT NULL,
    sampled_at timestamptz NOT NULL,
    elapsed_ms double precision NOT NULL,
    planning_ms double precision NOT NULL,
    calls bigint NOT NULL,
    plans bigint NOT NULL,
    shared_blocks bigint NOT NULL,
    temp_blocks bigint NOT NULL,
    category text NOT NULL,
    PRIMARY KEY (userid, queryid, toplevel)
);

CREATE VIEW index_steward.query_hotspots AS
SELECT * FROM index_steward.query_diagnostics
WHERE sampled_at >= now() - interval '24 hours';
