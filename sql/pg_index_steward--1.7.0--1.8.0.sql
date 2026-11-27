ALTER TABLE index_steward.jobs DROP CONSTRAINT jobs_action_check;
ALTER TABLE index_steward.jobs ADD CONSTRAINT jobs_action_check CHECK (action IN ('create','drop','analyze'));
ALTER TABLE index_steward.policy ADD COLUMN auto_analyze boolean NOT NULL DEFAULT false;

CREATE VIEW index_steward.table_health AS
SELECT s.relid,s.schemaname,s.relname,s.n_live_tup,s.n_dead_tup,s.n_mod_since_analyze,
       greatest(s.last_analyze,s.last_autoanalyze) AS last_statistics_at,
       s.n_mod_since_analyze>=greatest(1000,s.n_live_tup/5) AS analyze_candidate,
       s.n_dead_tup::numeric/greatest(1,s.n_dead_tup+s.n_live_tup) AS estimated_dead_ratio,
       c.relallvisible::numeric/greatest(1,c.relpages) AS estimated_all_visible_ratio
FROM pg_stat_user_tables s JOIN pg_class c ON c.oid=s.relid
WHERE c.relkind='r' AND c.relpersistence='p' AND NOT c.relispartition
  AND s.schemaname<>'index_steward' AND left(s.schemaname,3)<>'pg_';

CREATE VIEW index_steward.extended_statistics_advice AS
SELECT DISTINCT p.target,p.schema_name,p.table_name,p.keys,
       format('CREATE STATISTICS ON %s FROM %I.%I',
              (SELECT string_agg(quote_ident(key),', ' ORDER BY position)
               FROM jsonb_array_elements_text(p.keys) WITH ORDINALITY v(key,position)),p.schema_name,p.table_name) AS proposed_ddl
FROM index_steward.index_portfolio p
WHERE jsonb_array_length(p.keys) >= 2 AND NOT p.advisory_only
AND NOT EXISTS (SELECT FROM pg_statistic_ext st
    WHERE st.stxrelid=p.target AND NOT EXISTS (
        SELECT FROM jsonb_array_elements_text(p.keys) AS v(key)
        WHERE NOT EXISTS (SELECT FROM pg_attribute a
            WHERE a.attrelid=p.target AND a.attname=v.key AND a.attnum=ANY(st.stxkeys))));

REVOKE ALL ON index_steward.table_health,index_steward.extended_statistics_advice FROM PUBLIC;
