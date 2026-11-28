CREATE FUNCTION index_steward.queue_hypercore_layout(hypertable regclass, segment_column name, order_column name)
RETURNS bigint LANGUAGE sql VOLATILE SET search_path=pg_catalog AS $$
    INSERT INTO index_steward.jobs(action,target,signature,detail)
    SELECT 'create',c.oid,md5('hypercore_layout'),jsonb_build_object('hypercore',true,'step','layout',
           'schema',n.nspname,'table',c.relname,'source','manual','segmentby',segment_column,
           'orderby',order_column,'before',index_steward.hypercore_settings(hypertable))
    FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace
    WHERE c.oid=hypertable AND c.relkind='r' AND c.relpersistence='p' AND NOT c.relrowsecurity
      AND segment_column<>order_column AND index_steward.hypercore_settings(hypertable)->>'orderby' IS NOT NULL
      AND (SELECT count(*) FROM pg_attribute a WHERE a.attrelid=c.oid AND a.attnum>0
           AND NOT a.attisdropped AND a.attname IN (segment_column,order_column))=2
    ON CONFLICT(action,target,signature) WHERE state IN ('queued','running') DO NOTHING RETURNING id
$$;
REVOKE ALL ON FUNCTION index_steward.queue_hypercore_layout(regclass,name,name) FROM PUBLIC;
