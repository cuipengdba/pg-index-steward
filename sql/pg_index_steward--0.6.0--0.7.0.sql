ALTER TABLE index_steward.policy ADD COLUMN replica_services text[] NOT NULL DEFAULT '{}';
ALTER TABLE index_steward.policy ADD COLUMN idle_days integer NOT NULL DEFAULT 60 CHECK (idle_days BETWEEN 60 AND 400);

CREATE TABLE index_steward.replica_usage (
    service text NOT NULL,
    index_oid oid NOT NULL,
    fingerprint text NOT NULL,
    scans bigint NOT NULL,
    reset_marker text NOT NULL,
    observed_at timestamptz NOT NULL,
    idle_since timestamptz NOT NULL,
    PRIMARY KEY (service,index_oid)
);
REVOKE ALL ON index_steward.replica_usage FROM PUBLIC;
