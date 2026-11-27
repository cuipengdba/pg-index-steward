ALTER TABLE index_steward.policy ADD COLUMN failover_grace_seconds integer NOT NULL DEFAULT 300
    CHECK (failover_grace_seconds BETWEEN 0 AND 86400);
ALTER TABLE index_steward.policy ADD COLUMN primary_epoch text;
ALTER TABLE index_steward.policy ADD COLUMN primary_epoch_at timestamptz;

CREATE TABLE index_steward.retention_policy (
    index_oid oid PRIMARY KEY,
    definition text NOT NULL,
    preserve_until timestamptz NOT NULL DEFAULT 'infinity',
    reason text NOT NULL DEFAULT 'periodic workload'
);
REVOKE ALL ON index_steward.retention_policy FROM PUBLIC;

CREATE FUNCTION index_steward.protect_index(idx regclass, until_at timestamptz DEFAULT 'infinity')
RETURNS void LANGUAGE sql VOLATILE SET search_path=pg_catalog AS $$
    INSERT INTO index_steward.retention_policy (index_oid,definition,preserve_until)
    SELECT i.indexrelid,pg_get_indexdef(i.indexrelid),until_at FROM pg_index i WHERE i.indexrelid=idx
    ON CONFLICT (index_oid) DO UPDATE SET definition=excluded.definition,preserve_until=excluded.preserve_until
$$;
REVOKE ALL ON FUNCTION index_steward.protect_index(regclass,timestamptz) FROM PUBLIC;
