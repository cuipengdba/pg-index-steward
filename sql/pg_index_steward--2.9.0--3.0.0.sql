COMMENT ON FUNCTION index_steward.queue_status(bigint,integer) IS
    'Read-only page of maintenance tasks and last observed hypertable coverage';
COMMENT ON COLUMN index_steward.policy.ddl_per_cycle IS
    'Maximum number of sequential DDL steps per cycle, subject to window and daily limits';
COMMENT ON COLUMN index_steward.policy.timescale_retirement IS
    'Allow retirement of verified idle indexes created by Steward on supported rowstore hypertables';
