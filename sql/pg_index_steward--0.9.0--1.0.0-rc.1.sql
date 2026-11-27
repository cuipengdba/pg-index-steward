ALTER TABLE index_steward.jobs ADD COLUMN evidence_at timestamptz;
UPDATE index_steward.jobs SET evidence_at=updated_at;
ALTER TABLE index_steward.jobs ALTER COLUMN evidence_at SET DEFAULT clock_timestamp();
ALTER TABLE index_steward.jobs ALTER COLUMN evidence_at SET NOT NULL;
ALTER TABLE index_steward.jobs ADD COLUMN retry_streak integer NOT NULL DEFAULT 0;

CREATE FUNCTION index_steward.retry_job(job bigint) RETURNS boolean
LANGUAGE plpgsql VOLATILE SET search_path=pg_catalog
AS $$
DECLARE
    operation text;
BEGIN
    UPDATE index_steward.jobs j
       SET state='queued', reason='manual_retry', next_attempt_at='-infinity',
           retry_streak=0, updated_at=now()
     WHERE j.id=job AND j.state='failed' AND NOT EXISTS (
         SELECT FROM index_steward.jobs other WHERE other.id<>j.id
           AND other.action=j.action AND other.target=j.target AND other.signature=j.signature
           AND other.state IN ('queued','running'))
    RETURNING j.action INTO operation;
    IF NOT FOUND THEN
        RETURN false;
    END IF;
    PERFORM index_steward.log_event('queued',job,operation,'manual_retry',NULL);
    RETURN true;
END
$$;
REVOKE ALL ON FUNCTION index_steward.retry_job(bigint) FROM PUBLIC;

CREATE OR REPLACE VIEW index_steward.recommendations AS
SELECT id,action,state,target,detail,created_at,updated_at,message,
       attempts,next_attempt_at,reason,last_started_at,evidence_at,retry_streak
FROM index_steward.jobs;
