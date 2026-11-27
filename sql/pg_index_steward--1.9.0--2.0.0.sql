COMMENT ON EXTENSION pg_index_steward IS 'Workload-aware PostgreSQL index management with embedded HypoPG and resumable maintenance';
COMMENT ON FUNCTION index_steward.status() IS 'Read-only fleet status API';
COMMENT ON FUNCTION index_steward.alerts() IS 'Read-only fleet alerts API';
COMMENT ON FUNCTION index_steward.retry_job(bigint) IS 'Requeue a failed maintenance job for normal policy checks';
