CREATE FUNCTION index_steward.maintenance_report(days integer DEFAULT 30) RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER SET search_path=pg_catalog AS $$
    WITH scope AS (
        SELECT greatest(1,least(coalesce(days,30),365)) AS days
    ), jobs AS MATERIALIZED (
        SELECT j.* FROM index_steward.jobs j CROSS JOIN scope s
        WHERE j.created_at>=now()-make_interval(days=>s.days)
          AND NOT (j.detail @> '{"advisory":true}'::jsonb)
    ), outcome AS (
        SELECT count(*) AS total,count(*) FILTER (WHERE state='done') AS done,
               count(*) FILTER (WHERE state='failed') AS failed,
               count(*) FILTER (WHERE state='cancelled') AS cancelled,
               count(*) FILTER (WHERE state IN ('queued','running')) AS pending,
               percentile_cont(.95) WITHIN GROUP (ORDER BY extract(epoch FROM last_started_at-created_at))
                 FILTER (WHERE state='done' AND last_started_at IS NOT NULL) AS p95_seconds_to_last_attempt
        FROM jobs
    ), blockers AS (
        SELECT reason,count(*) AS tasks,max(extract(epoch FROM now()-coalesce(blocked_since,created_at))) AS oldest_seconds
        FROM jobs WHERE state='queued' AND reason IS NOT NULL GROUP BY reason
    ), results AS (
        SELECT v.state,count(*) AS indexes
        FROM index_steward.verdicts v JOIN jobs j ON j.id=v.job_id GROUP BY v.state
    )
    SELECT jsonb_build_object(
        'database',current_database(), 'days',s.days,
        'jobs',to_jsonb(o), 'completion_pct',round(100.0*o.done/nullif(o.total,0),2),
        'blockers',coalesce((SELECT jsonb_agg(to_jsonb(b) ORDER BY b.tasks DESC,b.reason) FROM blockers b),'[]'::jsonb),
        'verdicts',coalesce((SELECT jsonb_object_agg(r.state,r.indexes) FROM results r),'{}'::jsonb)
    ) FROM scope s CROSS JOIN outcome o
$$;
REVOKE ALL ON FUNCTION index_steward.maintenance_report(integer) FROM PUBLIC;
