CREATE FUNCTION index_steward.timescale_storage(hypertable regclass)
RETURNS TABLE (chunk_schema name, chunk_name name, storage text, layout jsonb)
LANGUAGE plpgsql STABLE SET search_path=pg_catalog AS $$
DECLARE
    storage_view regclass := to_regclass('timescaledb_information.chunk_columnstore_settings');
BEGIN
    IF to_regclass('timescaledb_information.chunks') IS NULL THEN
        RETURN;
    END IF;
    RETURN QUERY EXECUTE format($q$
        SELECT c.chunk_schema::name,c.chunk_name::name,
            CASE WHEN NOT c.is_compressed THEN 'rowstore'
                 WHEN %L THEN 'columnstore' ELSE 'legacy_compressed' END,
            %s
        FROM timescaledb_information.chunks c %s
        WHERE to_regclass(format('%%I.%%I',c.hypertable_schema,c.hypertable_name))=$1
        ORDER BY c.chunk_schema,c.chunk_name$q$,
        storage_view IS NOT NULL,
        CASE WHEN storage_view IS NULL THEN 'NULL::jsonb'
             ELSE 'jsonb_build_object(''segmentby'',to_jsonb(s)->''segmentby'',''orderby'',to_jsonb(s)->''orderby'')' END,
        CASE WHEN storage_view IS NULL THEN '' ELSE
             format('LEFT JOIN %s s ON s.chunk=to_regclass(format(''%%I.%%I'',c.chunk_schema,c.chunk_name))',storage_view) END)
        USING hypertable;
END
$$;
REVOKE ALL ON FUNCTION index_steward.timescale_storage(regclass) FROM PUBLIC;
