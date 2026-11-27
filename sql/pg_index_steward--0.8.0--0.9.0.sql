ALTER TABLE index_steward.policy ADD COLUMN ddl_timeout_seconds integer NOT NULL DEFAULT 1800
    CHECK (ddl_timeout_seconds BETWEEN 30 AND 14400);

CREATE FUNCTION index_steward.status()
RETURNS TABLE (database_name name, version text, paused boolean, action text,
               state text, reason text, jobs bigint, oldest_job_seconds double precision)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path=pg_catalog
AS $$
    SELECT current_database(), e.extversion, p.paused, j.action, j.state,
           j.reason, count(j.id), max(extract(epoch FROM now()-j.created_at))::float8
    FROM index_steward.policy p
    CROSS JOIN pg_extension e
    LEFT JOIN index_steward.jobs j ON true
    WHERE p.singleton AND e.extname='pg_index_steward'
    GROUP BY e.extversion,p.paused,j.action,j.state,j.reason
$$;
REVOKE ALL ON FUNCTION index_steward.status() FROM PUBLIC;
