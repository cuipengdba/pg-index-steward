CREATE INDEX steward_hypercore_active ON index_steward.jobs(target,id)
    WHERE state IN ('queued','running') AND detail @> '{"hypercore":true}'::jsonb;
