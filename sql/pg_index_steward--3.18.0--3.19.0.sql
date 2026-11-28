ALTER TABLE index_steward.policy ADD COLUMN hypercore_validate_batches boolean NOT NULL DEFAULT false;

CREATE FUNCTION index_steward.approve_hypercore_rollback(change_id bigint) RETURNS bigint
LANGUAGE plpgsql VOLATILE SET search_path=pg_catalog AS $$
DECLARE
    source_job index_steward.jobs%ROWTYPE;
    rollback_job bigint;
BEGIN
    SELECT j.* INTO source_job FROM index_steward.jobs j
    JOIN index_steward.verdicts v ON v.job_id=j.id
    WHERE j.id=change_id AND j.detail->>'step'='layout_rebuild' AND v.state='regression_review'
      AND jsonb_array_length(j.detail->'completed_chunks')>0
      AND j.detail->'after'=index_steward.hypercore_settings(j.target::regclass)
      AND (j.state='done' OR (j.state='queued' AND j.next_attempt_at='infinity'));
    IF NOT FOUND THEN RETURN NULL; END IF;
    INSERT INTO index_steward.jobs(action,target,signature,detail)
    VALUES ('create',source_job.target,md5('hypercore_rollback:'||change_id),
        jsonb_build_object('hypercore',true,'step','layout_rollback','rollback',true,
          'source','manual','schema',source_job.detail->>'schema','table',source_job.detail->>'table',
          'before',source_job.detail->'after','restore',source_job.detail->'before',
          'source_job',change_id,'rollback_chunks',source_job.detail->'completed_chunks'))
    ON CONFLICT(action,target,signature) WHERE state IN ('queued','running') DO NOTHING
    RETURNING id INTO rollback_job;
    IF rollback_job IS NOT NULL THEN
        UPDATE index_steward.jobs SET state='cancelled',reason='hypercore_rollback_approved',
            updated_at=clock_timestamp() WHERE id=change_id AND state='queued';
        PERFORM index_steward.log_event('queued',rollback_job,'create','hypercore_rollback_approved',NULL);
    END IF;
    RETURN rollback_job;
END
$$;
REVOKE ALL ON FUNCTION index_steward.approve_hypercore_rollback(bigint) FROM PUBLIC;
