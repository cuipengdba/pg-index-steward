ALTER TABLE index_steward.policy ADD COLUMN hypercore_changes boolean NOT NULL DEFAULT false;

CREATE FUNCTION index_steward.queue_hypercore_sparse(hypertable regclass, bloom_column name, minmax_column name)
RETURNS bigint LANGUAGE plpgsql SET search_path=pg_catalog AS $$
DECLARE
    result bigint;
    target_schema name;
    target_table name;
BEGIN
    SELECT n.nspname,c.relname INTO STRICT target_schema,target_table
      FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace
      WHERE c.oid=hypertable AND c.relkind='r' AND c.relpersistence='p' AND NOT c.relrowsecurity;
    IF bloom_column IS NULL OR minmax_column IS NULL OR bloom_column=minmax_column OR
       (SELECT count(*) FROM pg_attribute WHERE attrelid=hypertable AND attnum>0 AND NOT attisdropped
           AND attname IN (bloom_column,minmax_column))<>2 THEN
        RAISE EXCEPTION 'Specify distinct existing Bloom and minmax columns';
    END IF;
    IF index_steward.hypercore_settings(hypertable)->>'orderby' IS NULL THEN
        RAISE EXCEPTION 'Target requires an existing Hypercore columnstore layout';
    END IF;
    INSERT INTO index_steward.jobs(action,target,signature,detail)
    VALUES ('create',hypertable,md5('hypercore_sparse'),jsonb_build_object('hypercore',true,'schema',target_schema,
        'table',target_table,'bloom',bloom_column,'minmax',minmax_column,
        'before',index_steward.hypercore_settings(hypertable),'source','manual'))
    ON CONFLICT (action,target,signature) WHERE state IN ('queued','running') DO NOTHING
    RETURNING id INTO result;
    IF result IS NOT NULL THEN
        PERFORM index_steward.log_event('queued',result,'create','hypercore_sparse',NULL);
    END IF;
    RETURN result;
END
$$;
REVOKE ALL ON FUNCTION index_steward.queue_hypercore_sparse(regclass,name,name) FROM PUBLIC;
