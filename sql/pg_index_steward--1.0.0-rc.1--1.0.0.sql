COMMENT ON EXTENSION pg_index_steward IS 'Workload-aware index management with embedded HypoPG and windowed execution';
COMMENT ON COLUMN index_steward.jobs.evidence_at IS 'Latest candidate evidence, independent of postponement or an execution attempt';
COMMENT ON COLUMN index_steward.policy.ddl_timeout_seconds IS 'Maximum seconds for one DDL attempt, also bounded by the maintenance window';
