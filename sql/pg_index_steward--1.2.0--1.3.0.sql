CREATE TABLE index_steward.plan_samples (
    id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    table_oid oid NOT NULL,
    label text NOT NULL CHECK (length(label) BETWEEN 1 AND 64),
    statement text NOT NULL CHECK (octet_length(statement) BETWEEN 1 AND 16384),
    parameters text[] NOT NULL DEFAULT '{}' CHECK (cardinality(parameters) <= 16),
    UNIQUE(table_oid,label)
);
CREATE FUNCTION index_steward.valid_plan_sample(statement text) RETURNS boolean
AS 'MODULE_PATHNAME', 'steward_valid_plan_sample' LANGUAGE C STRICT;
CREATE FUNCTION index_steward.hypo_size(index_oid oid) RETURNS bigint
AS 'MODULE_PATHNAME', 'hypopg_relation_size' LANGUAGE C STRICT;
REVOKE ALL ON index_steward.plan_samples FROM PUBLIC;
REVOKE ALL ON FUNCTION index_steward.valid_plan_sample(text),index_steward.hypo_size(oid) FROM PUBLIC;
