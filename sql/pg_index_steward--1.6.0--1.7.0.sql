ALTER TABLE index_steward.policy ADD COLUMN auto_resume_partitions boolean NOT NULL DEFAULT true;

CREATE VIEW index_steward.partition_index_progress AS
SELECT j.id,j.state,j.reason,j.target AS parent_oid,j.detail->>'index' AS index_name,
       parent.indexrelid AS parent_index_oid,parent.indisvalid,
       (SELECT count(*) FROM pg_inherits h WHERE h.inhparent=j.target) AS partitions,
       (SELECT count(*) FROM pg_inherits h WHERE h.inhparent=parent.indexrelid) AS attached_indexes
FROM index_steward.jobs j
LEFT JOIN pg_class t ON t.oid=j.target
LEFT JOIN pg_class c ON c.relnamespace=t.relnamespace AND c.relname=j.detail->>'index'
LEFT JOIN pg_index parent ON parent.indexrelid=c.oid AND parent.indrelid=j.target
WHERE j.action='create' AND j.detail @> '{"partition":true}'::jsonb;

CREATE VIEW index_steward.timescale_chunk_index_details AS
SELECT n.nspname AS hypertable_schema,t.relname AS hypertable_name,
       cn.nspname AS chunk_schema,c.relname AS chunk_name,c.oid AS chunk_oid,
       pg_get_expr(c.relpartbound,c.oid) AS partition_bound,
       ARRAY(SELECT pg_get_constraintdef(p.oid) FROM pg_constraint p
               WHERE p.conrelid=c.oid AND p.contype='c' ORDER BY p.oid) AS chunk_checks,
       ARRAY(SELECT pg_get_indexdef(i.indexrelid) FROM pg_index i
               WHERE i.indrelid=c.oid AND i.indisvalid ORDER BY i.indexrelid) AS valid_indexes
FROM pg_inherits h JOIN pg_class t ON t.oid=h.inhparent JOIN pg_namespace n ON n.oid=t.relnamespace
JOIN pg_class c ON c.oid=h.inhrelid JOIN pg_namespace cn ON cn.oid=c.relnamespace
WHERE left(cn.nspname,13)='_timescaledb_' AND NOT c.relispartition;
REVOKE ALL ON index_steward.partition_index_progress,index_steward.timescale_chunk_index_details FROM PUBLIC;
