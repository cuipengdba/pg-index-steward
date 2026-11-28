CREATE FUNCTION index_steward.timeseries_report(days integer DEFAULT 30) RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER SET search_path=pg_catalog AS $$
    WITH scope AS (
        SELECT greatest(1,least(coalesce(days,30),365)) AS days
    ), jobs AS MATERIALIZED (
        SELECT j.*, CASE WHEN j.detail @> '{"hypercore":true}'::jsonb THEN 'hypercore'
                          WHEN j.detail @> '{"timescale":true}'::jsonb THEN 'timescaledb'
                          ELSE 'partition' END AS kind
        FROM index_steward.jobs j CROSS JOIN scope s
        WHERE (j.created_at>=now()-make_interval(days=>s.days) OR j.state IN ('queued','running'))
          AND j.action='create' AND NOT (j.detail @> '{"advisory":true}'::jsonb)
          AND (j.detail @> '{"timescale":true}'::jsonb OR j.detail @> '{"hypercore":true}'::jsonb
               OR j.detail @> '{"partition":true}'::jsonb)
    ), totals AS (
        SELECT j.kind,count(*) AS total,count(*) FILTER (WHERE state='done') AS completed,
               count(*) FILTER (WHERE state IN ('queued','running')) AS pending,
               count(*) FILTER (WHERE state IN ('failed','cancelled')) AS closed_without_completion,
               round(100.0*count(*) FILTER (WHERE state='done')/count(*),2) AS completion_pct
        FROM jobs j GROUP BY j.kind
    ), blockers AS (
        SELECT j.kind,j.reason,count(*) AS tasks,
               max(extract(epoch FROM now()-coalesce(j.blocked_since,j.created_at)))::bigint AS oldest_seconds,
               min(j.next_attempt_at) FILTER (WHERE isfinite(j.next_attempt_at)) AS next_retry_at,
               count(*) FILTER (WHERE j.next_attempt_at='infinity') AS awaiting_review
        FROM jobs j WHERE j.state='queued' AND j.reason IS NOT NULL GROUP BY j.kind,j.reason
    )
    SELECT jsonb_build_object('days',s.days,
        'pair',(SELECT to_jsonb(p) FROM index_steward.timescale_pair_status() p),
        'jobs',coalesce((SELECT jsonb_agg(to_jsonb(t) ORDER BY t.kind) FROM totals t),'[]'::jsonb),
        'blockers',coalesce((SELECT jsonb_agg(to_jsonb(b) ORDER BY b.kind,b.reason) FROM blockers b),'[]'::jsonb))
    FROM scope s
$$;
REVOKE ALL ON FUNCTION index_steward.timeseries_report(integer) FROM PUBLIC;
