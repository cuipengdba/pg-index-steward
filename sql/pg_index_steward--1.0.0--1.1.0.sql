ALTER TABLE index_steward.jobs ADD COLUMN required_seconds integer NOT NULL DEFAULT 30
    CHECK (required_seconds BETWEEN 30 AND 14405);
ALTER TABLE index_steward.jobs ADD COLUMN pending_cleanup jsonb;
CREATE OR REPLACE VIEW index_steward.recommendations AS
SELECT id,action,state,target,detail,created_at,updated_at,message,
       attempts,next_attempt_at,reason,last_started_at,evidence_at,retry_streak,required_seconds
FROM index_steward.jobs;
