ALTER TABLE index_steward.policy ADD COLUMN timescale_build_mib_per_second integer NOT NULL DEFAULT 16
    CHECK (timescale_build_mib_per_second BETWEEN 1 AND 1024);
COMMENT ON COLUMN index_steward.policy.timescale_build_mib_per_second IS
    'Initial hypertable DDL sizing assumption in MiB per second. Calibrate with observed build times.';
