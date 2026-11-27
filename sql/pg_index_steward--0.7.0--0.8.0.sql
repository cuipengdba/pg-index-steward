CREATE FUNCTION index_steward.queue_partition_index(parent regclass, keys name[]) RETURNS bigint
LANGUAGE sql VOLATILE SET search_path=pg_catalog
AS $$
    INSERT INTO index_steward.jobs(action,target,signature,detail)
    SELECT 'create',c.oid,md5(c.oid::text || keys::text),
           jsonb_build_object('partition',true,'schema',n.nspname,'table',c.relname,'keys',keys,
                              'index','pgisp_' || md5(c.oid::text || keys::text),'samples','[]'::jsonb)
    FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace
    WHERE c.oid=parent AND c.relkind='p' AND NOT c.relispartition AND NOT c.relrowsecurity
      AND cardinality(keys) BETWEEN 1 AND 3 AND n.nspname !~ '^pg_' AND n.nspname<>'index_steward'
      AND cardinality(keys)=(SELECT count(DISTINCT k) FROM unnest(keys) AS k)
      AND NOT EXISTS(SELECT FROM unnest(keys) AS k WHERE NOT EXISTS(
          SELECT FROM pg_attribute a WHERE a.attrelid=c.oid AND a.attnum>0
            AND NOT a.attisdropped AND a.attname=k))
    ON CONFLICT (action,target,signature) WHERE state IN ('queued','running') DO NOTHING
    RETURNING id
$$;
REVOKE ALL ON FUNCTION index_steward.queue_partition_index(regclass,name[]) FROM PUBLIC;

CREATE VIEW index_steward.timescale_diagnostics AS
SELECT n.nspname AS schema_name,c.relname AS table_name,
       count(h.inhrelid) AS child_relations,
       count(h.inhrelid) FILTER (WHERE EXISTS (
           SELECT FROM pg_index i JOIN pg_class ix ON ix.oid=i.indexrelid
           JOIN pg_am am ON am.oid=ix.relam
           WHERE i.indrelid=h.inhrelid AND am.amname='btree' AND i.indisvalid AND i.indpred IS NULL
       )) AS children_with_valid_btree
FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace
JOIN pg_inherits h ON h.inhparent=c.oid JOIN pg_class ch ON ch.oid=h.inhrelid
JOIN pg_namespace cn ON cn.oid=ch.relnamespace
WHERE cn.nspname LIKE '\_timescaledb\_%' AND NOT ch.relispartition
GROUP BY n.nspname,c.relname;
