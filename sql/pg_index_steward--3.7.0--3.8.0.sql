ALTER TABLE index_steward.verdicts ADD COLUMN indexed_at timestamptz;
UPDATE index_steward.verdicts v SET indexed_at=j.updated_at
  FROM index_steward.jobs j WHERE j.id=v.job_id AND j.state='done';
CREATE INDEX steward_pending_verdicts ON index_steward.verdicts(updated_at,job_id) WHERE state='observing';

CREATE OR REPLACE FUNCTION index_steward.approve_rollback(build_id bigint) RETURNS bigint
LANGUAGE sql VOLATILE SET search_path=pg_catalog AS $$
    WITH candidate AS (
      SELECT m.index_oid,m.fingerprint,n.nspname AS schema_name,t.relname AS table_name,
             i.relname AS index_name,m.ddl,false AS timescale
      FROM index_steward.managed_indexes m JOIN pg_class i ON i.oid=m.index_oid
      JOIN pg_class t ON t.oid=m.table_oid JOIN pg_namespace n ON n.oid=t.relnamespace
      WHERE m.build_job=build_id AND m.retired_at IS NULL
      UNION ALL
      SELECT v.index_oid,v.index_fingerprint,n.nspname,t.relname,i.relname,pg_get_indexdef(v.index_oid),true
      FROM index_steward.jobs j JOIN index_steward.verdicts v ON v.job_id=j.id
      JOIN pg_index x ON x.indexrelid=v.index_oid AND x.indrelid=j.target
      JOIN pg_class i ON i.oid=x.indexrelid JOIN pg_class t ON t.oid=j.target
      JOIN pg_namespace n ON n.oid=t.relnamespace
      WHERE j.id=build_id AND j.state='done' AND j.detail @> '{"timescale":true}'::jsonb
        AND j.detail->>'retired_at' IS NULL AND j.detail->'owned_index'->>'fingerprint'=v.index_fingerprint
    )
    INSERT INTO index_steward.jobs(action,target,signature,detail)
    SELECT 'drop',c.index_oid,c.fingerprint,
           jsonb_build_object('rollback',true,'managed',true,'schema',c.schema_name,
                              'table',c.table_name,'name',c.index_name,'ddl',c.ddl,
                              'timescale',c.timescale,'build_job',build_id)
      FROM candidate c WHERE EXISTS(SELECT FROM index_steward.verdicts WHERE job_id=build_id AND state='regression_review')
    ON CONFLICT (action,target,signature) WHERE state IN ('queued','running')
    DO UPDATE SET detail=excluded.detail,next_attempt_at='-infinity' WHERE jobs.state='queued'
    RETURNING id
$$;
