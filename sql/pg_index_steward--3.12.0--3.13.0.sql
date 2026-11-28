CREATE FUNCTION index_steward.timescale_pair_status()
RETURNS TABLE (postgres_major integer, timescaledb_version text, support text, execution_enabled boolean)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path=pg_catalog AS $$
    SELECT pg.major,e.extversion,
        CASE WHEN e.oid IS NULL THEN 'not_installed' WHEN m.pg_major IS NULL THEN 'unvalidated'
             WHEN m.experimental THEN 'experimental' ELSE 'production' END,
        coalesce(NOT m.experimental OR p.timescale_experimental,false)
    FROM (SELECT current_setting('server_version_num')::int/10000 AS major) pg
    CROSS JOIN index_steward.policy p
    LEFT JOIN pg_extension e ON e.extname='timescaledb'
    LEFT JOIN index_steward.timescale_compatibility m ON m.pg_major=pg.major AND m.extension_version=e.extversion
    WHERE p.singleton
$$;
REVOKE ALL ON FUNCTION index_steward.timescale_pair_status() FROM PUBLIC;
