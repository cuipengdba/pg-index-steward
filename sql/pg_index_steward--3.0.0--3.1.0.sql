ALTER TABLE index_steward.jobs ADD COLUMN blocked_since timestamptz;
CREATE INDEX steward_recheck_blockers ON index_steward.jobs (next_attempt_at,id)
    WHERE state='queued' AND reason IN ('55P03','long_transaction','replication_lag','disk_headroom','53100');
