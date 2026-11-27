CREATE INDEX ON index_steward.jobs(next_attempt_at) WHERE state='queued';
