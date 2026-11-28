ALTER TABLE index_steward.policy ADD COLUMN timescale_create boolean NOT NULL DEFAULT true;

CREATE TABLE index_steward.timescale_compatibility (
    pg_major integer NOT NULL,
    extension_version text NOT NULL,
    PRIMARY KEY (pg_major,extension_version)
);
INSERT INTO index_steward.timescale_compatibility VALUES (14,'2.8.0');
REVOKE ALL ON index_steward.timescale_compatibility FROM PUBLIC;

CREATE FUNCTION index_steward.queue_timescale_index(hypertable regclass, keys name[])
RETURNS bigint LANGUAGE plpgsql VOLATILE SET search_path=pg_catalog AS $$
DECLARE
    obj record;
    queued_id bigint;
    fingerprint text;
BEGIN
    SELECT c.oid,c.relname,n.nspname INTO STRICT obj
    FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace
    WHERE c.oid=hypertable AND c.relkind='r' AND NOT c.relispartition
      AND c.relpersistence='p' AND NOT c.relrowsecurity;
    IF NOT EXISTS (SELECT FROM pg_extension WHERE extname='timescaledb') THEN
        RAISE EXCEPTION 'TimescaleDB is required';
    END IF;
    IF NOT EXISTS (SELECT FROM timescaledb_information.hypertables h
                   WHERE h.hypertable_schema=obj.nspname AND h.hypertable_name=obj.relname) THEN
        RAISE EXCEPTION 'Target is not a TimescaleDB hypertable';
    END IF;
    IF coalesce(cardinality(keys),0) NOT BETWEEN 1 AND 3
       OR cardinality(keys)<>(SELECT count(DISTINCT k) FROM unnest(keys) AS k)
       OR EXISTS (SELECT FROM unnest(keys) AS k WHERE NOT EXISTS (
           SELECT FROM pg_attribute a WHERE a.attrelid=obj.oid AND a.attname=k
                AND a.attnum>0 AND NOT a.attisdropped)) THEN
        RAISE EXCEPTION 'Specify one to three distinct existing index columns';
    END IF;
    fingerprint := md5(obj.oid::text || keys::text || ':btree');
    INSERT INTO index_steward.jobs(action,target,signature,detail)
      VALUES ('create',obj.oid,fingerprint,jsonb_build_object('timescale',true,'schema',obj.nspname,
         'table',obj.relname,'keys',keys,'method','btree','index','pgist_' || fingerprint,'samples','[]'::jsonb))
    ON CONFLICT (action,target,signature) WHERE state IN ('queued','running')
      DO UPDATE SET evidence_at=clock_timestamp() RETURNING id INTO queued_id;
    PERFORM index_steward.log_event('queued',queued_id,'create','timescale_hypertable',NULL);
    RETURN queued_id;
END
$$;
REVOKE ALL ON FUNCTION index_steward.queue_timescale_index(regclass,name[]) FROM PUBLIC;
