CREATE VIEW index_steward.index_portfolio AS
SELECT target, id, detail->>'schema' AS schema_name, detail->>'table' AS table_name,
       detail->'keys' AS keys, detail->'include' AS include_columns,
       detail->>'predicate' AS predicate, detail->>'ddl_preview' AS proposed_ddl,
       detail->'plan_evidence' AS plan_evidence, detail->'write_profile' AS write_profile,
       COALESCE((detail->>'score')::float8,0) AS priority,
       COALESCE(jsonb_array_length(detail->'samples'),0) AS observed_queries,
       COALESCE((detail->>'advisory')::boolean,false) AS advisory_only
FROM index_steward.jobs WHERE action='create' AND state='queued';
REVOKE ALL ON index_steward.index_portfolio FROM PUBLIC;
