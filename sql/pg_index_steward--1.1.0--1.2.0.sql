ALTER TABLE index_steward.query_diagnostics ADD COLUMN dimensions jsonb NOT NULL DEFAULT '{}';
CREATE OR REPLACE VIEW index_steward.query_hotspots AS
SELECT * FROM index_steward.query_diagnostics WHERE sampled_at >= now()-interval '24 hours';

CREATE VIEW index_steward.relation_hotspots AS
SELECT r.schema_name,r.table_name,r.shape,d.toplevel,count(*) AS query_fingerprints,
       sum(d.calls) AS calls,sum(d.elapsed_ms) AS execution_ms,
       sum(d.planning_ms) FILTER (WHERE (d.dimensions->>'planning_observed')::boolean) AS planning_ms,
       sum((d.dimensions->>'shared_read_ms')::float8) AS shared_read_ms,
       sum(d.shared_blocks) AS shared_blocks,sum(d.temp_blocks) AS temp_blocks,
       sum((d.dimensions->>'wait_samples')::bigint) AS wait_samples
FROM index_steward.query_hotspots d
CROSS JOIN LATERAL jsonb_to_record(d.dimensions) AS x(relation jsonb)
CROSS JOIN LATERAL jsonb_to_record(x.relation) AS r(schema_name text, table_name text, shape text)
GROUP BY r.schema_name,r.table_name,r.shape,d.toplevel;
REVOKE ALL ON index_steward.relation_hotspots FROM PUBLIC;
