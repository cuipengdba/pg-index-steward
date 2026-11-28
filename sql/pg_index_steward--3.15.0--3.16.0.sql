CREATE FUNCTION index_steward.queue_hypercore_rebuild(hypertable regclass) RETURNS bigint
LANGUAGE sql VOLATILE SET search_path=pg_catalog AS $$
    INSERT INTO index_steward.jobs(action,target,signature,detail)
    SELECT 'create',j.target,md5('hypercore_rebuild'),jsonb_build_object('hypercore',true,
           'step','rebuild','source','manual','schema',j.detail->>'schema','table',j.detail->>'table',
           'after',j.detail->'after','configuration_job',j.id,'completed_chunks','[]'::jsonb)
    FROM index_steward.jobs j WHERE j.target=hypertable AND j.state='done' AND j.reason='hypercore_sparse_applied'
      AND j.detail->'after'=index_steward.hypercore_settings(hypertable)
    ORDER BY j.id DESC LIMIT 1
    ON CONFLICT(action,target,signature) WHERE state IN ('queued','running') DO NOTHING
    RETURNING id
$$;
REVOKE ALL ON FUNCTION index_steward.queue_hypercore_rebuild(regclass) FROM PUBLIC;
