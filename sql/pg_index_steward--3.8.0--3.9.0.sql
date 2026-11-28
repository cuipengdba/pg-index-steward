ALTER TABLE index_steward.policy ADD COLUMN timescale_replica_retirement boolean NOT NULL DEFAULT false;
COMMENT ON COLUMN index_steward.policy.timescale_replica_retirement IS
    'Allow idle hypertable index retirement on a verified topology of direct physical read replicas';
