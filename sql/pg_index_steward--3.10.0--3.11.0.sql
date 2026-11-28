ALTER TABLE index_steward.jobs ADD COLUMN blocker_checks integer NOT NULL DEFAULT 0;
ALTER TABLE index_steward.jobs ADD COLUMN blocker_checked_at timestamptz;

CREATE OR REPLACE FUNCTION index_steward.alerts()
RETURNS TABLE (database_name name,job_id bigint,action text,kind text,reason text,created_at timestamptz)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path=pg_catalog AS $$
    SELECT current_database(),j.id,j.action,
           CASE WHEN v.state='regression_review' THEN 'regression'
                WHEN j.state='failed' THEN 'failed'
                WHEN greatest(j.retry_streak,j.blocker_checks)>=p.retry_limit THEN 'retry_threshold'
                ELSE 'stalled' END,
           j.reason,j.created_at
    FROM index_steward.jobs j CROSS JOIN index_steward.policy p
    LEFT JOIN index_steward.verdicts v ON v.job_id=j.id
    WHERE p.singleton AND (v.state='regression_review' OR j.state='failed' OR
      (j.state='queued' AND j.reason IS NOT NULL AND j.reason <> 'blocker_cleared' AND
       (greatest(j.retry_streak,j.blocker_checks)>=p.retry_limit OR
        j.created_at<now()-make_interval(hours=>p.alert_after_hours))))
$$;
