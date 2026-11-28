ALTER TABLE index_steward.jobs ADD COLUMN reserved_at timestamptz;
ALTER TABLE index_steward.jobs ADD COLUMN budget_timeouts integer NOT NULL DEFAULT 0;
