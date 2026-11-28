CREATE FUNCTION index_steward.hypercore_settings(target regclass)
RETURNS jsonb LANGUAGE plpgsql STABLE SET search_path=pg_catalog AS $$
DECLARE
    result jsonb;
BEGIN
    IF to_regclass('timescaledb_information.hypertable_columnstore_settings') IS NULL THEN
        RETURN NULL;
    END IF;
    EXECUTE 'SELECT jsonb_build_object(''segmentby'',s.segmentby,''orderby'',s.orderby,
        ''sparse_indexes'',to_jsonb(s)->''index'')
        FROM timescaledb_information.hypertable_columnstore_settings s WHERE s.hypertable=$1'
        INTO result USING target;
    RETURN result;
END
$$;
REVOKE ALL ON FUNCTION index_steward.hypercore_settings(regclass) FROM PUBLIC;
