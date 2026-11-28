ALTER TABLE index_steward.policy ADD COLUMN timescale_legacy_compression boolean NOT NULL DEFAULT false;
COMMENT ON COLUMN index_steward.policy.timescale_legacy_compression IS
    'Allow explicit index requests on tested legacy compression hypertables. Indexes apply to the rowstore path.';
