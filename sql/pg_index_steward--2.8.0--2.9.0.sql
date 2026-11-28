ALTER TABLE index_steward.policy ADD COLUMN ddl_per_cycle integer NOT NULL DEFAULT 1
    CHECK (ddl_per_cycle BETWEEN 1 AND 10);

CREATE FUNCTION index_steward.queue_status(after_id bigint DEFAULT 0, page_size integer DEFAULT 50)
RETURNS TABLE (id bigint, action text, state text, schema_name text, table_name text,
    method text, reason text, attempts integer, retry_at timestamptz, age_seconds bigint,
    chunks bigint, indexed_chunks bigint)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path=pg_catalog AS $$
    SELECT j.id,j.action,j.state,j.detail->>'schema',j.detail->>'table',j.detail->>'method',
           j.reason,j.attempts,nullif(j.next_attempt_at,'-infinity'),
           extract(epoch FROM now()-j.created_at)::bigint,
           (j.detail->'coverage'->>'chunks')::bigint,(j.detail->'coverage'->>'indexed')::bigint
    FROM index_steward.jobs j WHERE j.id>after_id ORDER BY j.id
    LIMIT greatest(1,least(page_size,500))
$$;
REVOKE ALL ON FUNCTION index_steward.queue_status(bigint,integer) FROM PUBLIC;

CREATE INDEX steward_queued_due ON index_steward.jobs (next_attempt_at,id) WHERE state='queued';
