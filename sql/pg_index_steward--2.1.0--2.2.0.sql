COMMENT ON COLUMN index_steward.policy.retry_limit IS
    'Number of consecutive DDL attempts before emitting a retry alert. Transient blockers remain retryable.';

CREATE OR REPLACE FUNCTION index_steward.alerts()
RETURNS TABLE (database_name name,job_id bigint,action text,kind text,reason text,created_at timestamptz)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path=pg_catalog AS $$
    SELECT current_database(),j.id,j.action,
           CASE WHEN v.state='regression_review' THEN 'regression'
                WHEN j.state='failed' THEN 'failed'
                WHEN j.retry_streak>=p.retry_limit THEN 'retry_threshold' ELSE 'stalled' END,
           j.reason,j.created_at
      FROM index_steward.jobs j CROSS JOIN index_steward.policy p
      LEFT JOIN index_steward.verdicts v ON v.job_id=j.id
     WHERE p.singleton AND (v.state='regression_review' OR j.state='failed' OR
       (j.state='queued' AND j.reason IS NOT NULL AND
          (j.retry_streak>=p.retry_limit OR j.created_at<now()-make_interval(hours=>p.alert_after_hours))))
$$;
