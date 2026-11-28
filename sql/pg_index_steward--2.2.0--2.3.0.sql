CREATE FUNCTION index_steward.lock_index(oid) RETURNS void
AS 'MODULE_PATHNAME','steward_lock_index' LANGUAGE C STRICT;
REVOKE ALL ON FUNCTION index_steward.lock_index(oid) FROM PUBLIC;
