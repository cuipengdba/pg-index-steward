ALTER TABLE index_steward.policy ADD COLUMN auto_rollback boolean NOT NULL DEFAULT false;
ALTER TABLE index_steward.verdicts ADD COLUMN reviewed_at timestamptz;

CREATE FUNCTION index_steward.approve_rollback(build_id bigint) RETURNS bigint
LANGUAGE sql VOLATILE SET search_path=pg_catalog
AS $$
    INSERT INTO index_steward.jobs(action,target,signature,detail)
    SELECT 'drop',m.index_oid,m.fingerprint,
           jsonb_build_object('rollback',true,'managed',true,'schema',n.nspname,
                              'table',t.relname,'name',i.relname,'ddl',m.ddl)
      FROM index_steward.managed_indexes m
      JOIN index_steward.verdicts v ON v.job_id=m.build_job AND v.state='regression_review'
      JOIN pg_class i ON i.oid=m.index_oid JOIN pg_class t ON t.oid=m.table_oid
      JOIN pg_namespace n ON n.oid=t.relnamespace
     WHERE m.build_job=build_id AND m.retired_at IS NULL
    ON CONFLICT (action,target,signature) WHERE state IN ('queued','running')
    DO UPDATE SET detail=excluded.detail,next_attempt_at='-infinity' WHERE jobs.state='queued'
    RETURNING id
$$;
REVOKE ALL ON FUNCTION index_steward.approve_rollback(bigint) FROM PUBLIC;
