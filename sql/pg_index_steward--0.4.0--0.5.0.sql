ALTER TABLE index_steward.policy ADD COLUMN use_hypopg boolean NOT NULL DEFAULT true;

CREATE FUNCTION index_steward.hypo_create(IN definition text, OUT indexrelid oid, OUT indexname text)
RETURNS SETOF record AS 'MODULE_PATHNAME', 'steward_hypo_create' LANGUAGE C STRICT VOLATILE;
CREATE FUNCTION index_steward.hypo_reset()
RETURNS void AS 'MODULE_PATHNAME', 'steward_hypo_reset' LANGUAGE C VOLATILE;

REVOKE ALL ON FUNCTION index_steward.hypo_create(text), index_steward.hypo_reset() FROM PUBLIC;
