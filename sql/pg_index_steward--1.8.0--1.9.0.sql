ALTER TABLE index_steward.policy ADD COLUMN rollout_percent integer NOT NULL DEFAULT 100
    CHECK (rollout_percent BETWEEN 0 AND 100);
ALTER TABLE index_steward.policy ADD COLUMN alert_after_hours integer NOT NULL DEFAULT 24
    CHECK (alert_after_hours BETWEEN 1 AND 720);

CREATE TABLE index_steward.alert_history (
    job_id bigint NOT NULL REFERENCES index_steward.jobs(id) ON DELETE CASCADE,
    kind text NOT NULL,
    emitted_at timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY(job_id,kind)
);
REVOKE ALL ON index_steward.alert_history FROM PUBLIC;

CREATE FUNCTION index_steward.alerts()
RETURNS TABLE (database_name name,job_id bigint,action text,kind text,reason text,created_at timestamptz)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path=pg_catalog AS $$
    SELECT current_database(),j.id,j.action,
           CASE WHEN v.state='regression_review' THEN 'regression'
                WHEN j.state='failed' THEN 'failed' ELSE 'stalled' END,
           j.reason,j.created_at
      FROM index_steward.jobs j CROSS JOIN index_steward.policy p
      LEFT JOIN index_steward.verdicts v ON v.job_id=j.id
     WHERE p.singleton AND (v.state='regression_review' OR j.state='failed' OR
       (j.state='queued' AND j.reason IS NOT NULL AND j.created_at<now()-make_interval(hours=>p.alert_after_hours)))
$$;
REVOKE ALL ON FUNCTION index_steward.alerts() FROM PUBLIC;

CREATE FUNCTION index_steward.set_paused(pause boolean) RETURNS void
LANGUAGE plpgsql VOLATILE SET search_path=pg_catalog AS $$
BEGIN
    UPDATE index_steward.policy SET paused=pause WHERE singleton AND paused IS DISTINCT FROM pause;
    IF FOUND THEN
        PERFORM index_steward.log_event('policy_changed',NULL,NULL,CASE WHEN pause THEN 'paused' ELSE 'resumed' END,NULL);
    END IF;
END
$$;
REVOKE ALL ON FUNCTION index_steward.set_paused(boolean) FROM PUBLIC;
