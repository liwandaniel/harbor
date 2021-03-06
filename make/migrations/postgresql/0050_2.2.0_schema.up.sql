/*
Fixes issue https://github.com/goharbor/harbor/issues/13317
  Ensure the role_id of maintainer is 4 and the role_id of limited guest is 5
*/
UPDATE role SET role_id=4 WHERE name='maintainer' AND role_id!=4;
UPDATE role SET role_id=5 WHERE name='limitedGuest' AND role_id!=5;

/*
 Fixes issue https://github.com/goharbor/harbor/issues/12700
 Add the empty CVE allowlist to project library.
 */
INSERT INTO cve_allowlist (project_id, items) SELECT 1, '[]' WHERE NOT EXISTS (SELECT id FROM cve_allowlist WHERE project_id=1);

/*
Clean the dirty data in quota/quota_usage
  Remove quota/quota_usage when the referenced project not exists
*/
DELETE FROM quota WHERE reference='project' AND reference_id::integer NOT IN (SELECT project_id FROM project WHERE deleted=FALSE);
DELETE FROM quota_usage WHERE reference='project' AND reference_id::integer NOT IN (SELECT project_id FROM project WHERE deleted=FALSE);

ALTER TABLE schedule ADD COLUMN IF NOT EXISTS cron_type varchar(64);
ALTER TABLE robot ADD COLUMN IF NOT EXISTS secret varchar(2048);
ALTER TABLE robot ADD COLUMN IF NOT EXISTS salt varchar(64);

ALTER TABLE task ADD COLUMN IF NOT EXISTS vendor_type varchar(16);
UPDATE task SET vendor_type = execution.vendor_type FROM execution WHERE task.execution_id = execution.id;
ALTER TABLE task ALTER COLUMN vendor_type SET NOT NULL;

ALTER TABLE execution ADD COLUMN IF NOT EXISTS update_time timestamp;

DO $$
DECLARE
    art RECORD;
    art_size integer;
BEGIN
    FOR art IN SELECT * FROM artifact WHERE size = 0
    LOOP
      SELECT sum(size) INTO art_size FROM blob WHERE digest IN (SELECT digest_blob FROM artifact_blob WHERE digest_af=art.digest);
      UPDATE artifact SET size=art_size WHERE id = art.id;
    END LOOP;
END $$;

ALTER TABLE robot ADD COLUMN IF NOT EXISTS secret varchar(2048);
ALTER TABLE robot ADD COLUMN IF NOT EXISTS duration int;

CREATE TABLE  IF NOT EXISTS role_permission (
 id SERIAL PRIMARY KEY NOT NULL,
 role_type varchar(255) NOT NULL,
 role_id int NOT NULL,
 permission_policy_id int NOT NULL,
 creation_time timestamp default CURRENT_TIMESTAMP,
 CONSTRAINT unique_role_permission UNIQUE (role_type, role_id, permission_policy_id)
);

CREATE TABLE  IF NOT EXISTS permission_policy (
 id SERIAL PRIMARY KEY NOT NULL,
 /*
  scope:
   system level: /system
   project level: /project/{id}
   all project: /project/ *
  */
 scope varchar(255) NOT NULL,
 resource varchar(255),
 action varchar(255),
 effect varchar(255),
 creation_time timestamp default CURRENT_TIMESTAMP,
 CONSTRAINT unique_rbac_policy UNIQUE (scope, resource, action, effect)
);

/*delete the replication execution records whose policy doesn't exist*/
DELETE FROM replication_execution
    WHERE id IN (SELECT re.id FROM replication_execution re
        LEFT JOIN replication_policy rp ON re.policy_id=rp.id
        WHERE rp.id IS NULL);

/*delete the replication task records whose execution doesn't exist*/
DELETE FROM replication_task
    WHERE id IN (SELECT rt.id FROM replication_task rt
        LEFT JOIN replication_execution re ON rt.execution_id=re.id
        WHERE re.id IS NULL);

/*fill the task count, status and end_time of execution based on the tasks*/
DO $$
DECLARE
    rep_exec RECORD;
    status_count RECORD;
    rep_status varchar(32);
BEGIN
    FOR rep_exec IN SELECT * FROM replication_execution
    LOOP
      /*the replication status is set directly in some cases, so skip if the status is a final one*/
      IF rep_exec.status='Stopped' OR rep_exec.status='Failed' OR rep_exec.status='Succeed' THEN
        CONTINUE;
      END IF;
      /*fulfill the status count*/
      FOR status_count IN SELECT status, COUNT(*) as c FROM replication_task WHERE execution_id=rep_exec.id GROUP BY status
      LOOP
        IF status_count.status = 'Stopped' THEN
          UPDATE replication_execution SET stopped=status_count.c WHERE id=rep_exec.id;
        ELSIF status_count.status = 'Failed' THEN
          UPDATE replication_execution SET failed=status_count.c WHERE id=rep_exec.id;
        ELSIF status_count.status = 'Succeed' THEN
          UPDATE replication_execution SET succeed=status_count.c WHERE id=rep_exec.id;
        ELSE
          UPDATE replication_execution SET in_progress=status_count.c WHERE id=rep_exec.id;
        END IF;
      END LOOP;

      /*reload the execution record*/
      SELECT * INTO rep_exec FROM replication_execution where id=rep_exec.id;

      /*calculate the status*/
      IF rep_exec.in_progress>0 THEN
        rep_status = 'InProgress';
      ELSIF rep_exec.failed>0 THEN
        rep_status = 'Failed';
      ELSIF rep_exec.stopped>0 THEN
        rep_status = 'Stopped';
      ELSE
        rep_status = 'Succeed';
      END IF;
      UPDATE replication_execution SET status=rep_status WHERE id=rep_exec.id;

      /*update the end time if the status is a final one*/
      IF rep_status='Failed' OR rep_status='Stopped' OR rep_status='Succeed' THEN
        UPDATE replication_execution
            SET end_time=(SELECT MAX (end_time) FROM replication_task WHERE execution_id=rep_exec.id)
            WHERE id=rep_exec.id;
      END IF;
    END LOOP;
END $$;

/*move the replication execution records into the new execution table*/
ALTER TABLE replication_execution ADD COLUMN IF NOT EXISTS new_execution_id int;
DO $$
DECLARE
    rep_exec RECORD;
    trigger varchar(64);
    status varchar(32);
    new_exec_id integer;
BEGIN
    FOR rep_exec IN SELECT * FROM replication_execution
    LOOP
      IF rep_exec.trigger = 'scheduled' THEN
        trigger = 'SCHEDULE';
      ELSIF rep_exec.trigger = 'event_based' THEN
        trigger = 'EVENT';
      ELSE
        trigger = 'MANUAL';
      END IF;

      IF rep_exec.status = 'InProgress' THEN
        status = 'Running';
      ELSIF rep_exec.status = 'Stopped' THEN
        status = 'Stopped';
      ELSIF rep_exec.status = 'Failed' THEN
        status = 'Error';
      ELSIF rep_exec.status = 'Succeed' THEN
        status = 'Success';
      END IF;

      INSERT INTO execution (vendor_type, vendor_id, status, status_message, revision, trigger, start_time, end_time)
        VALUES ('REPLICATION', rep_exec.policy_id, status, rep_exec.status_text, 0, trigger, rep_exec.start_time, rep_exec.end_time) RETURNING id INTO new_exec_id;
      UPDATE replication_execution SET new_execution_id=new_exec_id WHERE id=rep_exec.id;
    END LOOP;
END $$;

/*move the replication task records into the new task table*/
DO $$
DECLARE
    rep_task RECORD;
    status varchar(32);
    status_code integer;
BEGIN
    FOR rep_task IN SELECT * FROM replication_task
    LOOP
      IF rep_task.status = 'InProgress' THEN
        status = 'Running';
        status_code = 2;
      ELSIF rep_task.status = 'Stopped' THEN
        status = 'Stopped';
        status_code = 3;
      ELSIF rep_task.status = 'Failed' THEN
        status = 'Error';
        status_code = 3;
      ELSIF rep_task.status = 'Succeed' THEN
        status = 'Success';
        status_code = 3;
      ELSE
        status = 'Pending';
        status_code = 0;
      END IF;
      INSERT INTO task (vendor_type, execution_id, job_id, status, status_code, status_revision,
        run_count, extra_attrs, creation_time, start_time, update_time, end_time)
        VALUES ('REPLICATION', (SELECT new_execution_id FROM replication_execution WHERE id=rep_task.execution_id),
            rep_task.job_id, status, status_code, rep_task.status_revision,
            1, CONCAT('{"resource_type":"', rep_task.resource_type,'","source_resource":"', rep_task.src_resource, '","destination_resource":"', rep_task.dst_resource, '","operation":"', rep_task.operation,'"}')::json,
            rep_task.start_time, rep_task.start_time, rep_task.end_time, rep_task.end_time);
    END LOOP;
END $$;

DROP TABLE IF EXISTS replication_task;
DROP TABLE IF EXISTS replication_execution;

/*move the replication schedule job records into the new schedule table*/
DO $$
DECLARE
    schd RECORD;
    new_schd_id integer;
    exec_id integer;
    exec_status varchar(32);
    task_status varchar(32);
    task_status_code integer;
BEGIN
    FOR schd IN SELECT * FROM replication_schedule_job
    LOOP
        INSERT INTO schedule (vendor_type, vendor_id, cron, callback_func_name,
            callback_func_param, creation_time, update_time)
            VALUES ('REPLICATION', schd.policy_id,
                (SELECT trigger::json->'trigger_settings'->>'cron' FROM replication_policy WHERE id=schd.policy_id),
                'REPLICATION_CALLBACK', schd.policy_id, schd.creation_time, schd.update_time) RETURNING id INTO new_schd_id;
        IF schd.status = 'stopped' THEN
            exec_status = 'Stopped';
            task_status = 'Stopped';
            task_status_code = 3;
        ELSIF schd.status = 'error' THEN
            exec_status = 'Error';
            task_status = 'Error';
            task_status_code = 3;
        ELSIF schd.status = 'finished' THEN
            exec_status = 'Success';
            task_status = 'Success';
            task_status_code = 3;
        ELSIF schd.status = 'running' THEN
            exec_status = 'Running';
            task_status = 'Running';
            task_status_code = 2;
        ELSEIF schd.status = 'pending' THEN
            exec_status = 'Running';
            task_status = 'Pending';
            task_status_code = 0;
        ELSEIF schd.status = 'scheduled' THEN
            exec_status = 'Running';
            task_status = 'Scheduled';
            task_status_code = 1;
        ELSE
            exec_status = 'Running';
            task_status = 'Pending';
            task_status_code = 0;
        END IF;
        INSERT INTO execution (vendor_type, vendor_id, status, revision, trigger, start_time, end_time)
            VALUES ('SCHEDULER', new_schd_id, exec_status, 0, 'MANUAL', schd.creation_time, schd.update_time) RETURNING id INTO exec_id;
        INSERT INTO task (vendor_type, execution_id, job_id, status, status_code, status_revision, run_count, creation_time, start_time, update_time, end_time)
            VALUES ('SCHEDULER',exec_id, schd.job_id, task_status, task_status_code, 0, 1, schd.creation_time, schd.creation_time, schd.update_time, schd.update_time);
    END LOOP;
END $$;

DROP TABLE IF EXISTS replication_schedule_job;

/* remove the clair scanner */
DO $$
DECLARE
   scanner_info record;
   is_clair_default boolean;
   immutable_clair_uuid VARCHAR(64);
BEGIN
  SELECT INTO scanner_info * FROM scanner_registration WHERE name = 'Clair' AND immutable = TRUE;
  IF scanner_info IS NOT NULL THEN
    is_clair_default = scanner_info.is_default;
    immutable_clair_uuid = scanner_info.uuid;
    DELETE FROM scanner_registration WHERE id = scanner_info.id;
    DELETE FROM scan_report WHERE registration_uuid = immutable_clair_uuid;
  END IF;
  IF is_clair_default THEN
  UPDATE scanner_registration SET is_default = TRUE WHERE name = 'Trivy' AND immutable = TRUE;
  END IF;
END $$;

ALTER TABLE execution ALTER COLUMN vendor_type type varchar(64);
ALTER TABLE schedule ALTER COLUMN vendor_type type varchar(64);
ALTER TABLE schedule ADD COLUMN IF NOT EXISTS extra_attrs JSON;
ALTER TABLE task ALTER COLUMN vendor_type type varchar(64);

/* Remove these columns in scan_report because execution-task pattern will handle them */
ALTER TABLE scan_report DROP COLUMN IF EXISTS job_id;
ALTER TABLE scan_report DROP COLUMN IF EXISTS track_id;
ALTER TABLE scan_report DROP COLUMN IF EXISTS requester;
ALTER TABLE scan_report DROP COLUMN IF EXISTS status;
ALTER TABLE scan_report DROP COLUMN IF EXISTS status_code;
ALTER TABLE scan_report DROP COLUMN IF EXISTS status_rev;
ALTER TABLE scan_report DROP COLUMN IF EXISTS start_time;
ALTER TABLE scan_report DROP COLUMN IF EXISTS end_time;

/*add unique for vendor_type+vendor_id to avoid dup records when updating policies*/
ALTER TABLE schedule ADD CONSTRAINT unique_schedule UNIQUE (vendor_type, vendor_id);

/*move the gc schedule job records into the new schedule table*/
DO $$
DECLARE
    schd RECORD;
    new_schd_id integer;
    exec_id integer;
    exec_status varchar(32);
    task_status varchar(32);
    task_status_code integer;
BEGIN
    FOR schd IN SELECT * FROM admin_job where job_name='IMAGE_GC' and job_kind='Periodic' and deleted=FALSE
    LOOP
        INSERT INTO schedule (vendor_type, vendor_id, cron, callback_func_name,
            callback_func_param, cron_type, extra_attrs, creation_time, update_time)
            VALUES ('GARBAGE_COLLECTION', -1,
                (SELECT schd.cron_str::json->>'cron'),
                'GARBAGE_COLLECTION',
                (SELECT json_build_object('trigger', null, 'deleteuntagged', schd.job_parameters::json->'delete_untagged', 'dryrun', false, 'job_parameters', schd.job_parameters)),
                (SELECT schd.cron_str::json->>'type'),
                (SELECT json_build_object('delete_untagged', schd.job_parameters::json->'delete_untagged')),
                schd.creation_time, schd.update_time) RETURNING id INTO new_schd_id;
        IF schd.status = 'stopped' THEN
            exec_status = 'Stopped';
            task_status = 'Stopped';
            task_status_code = 3;
        ELSIF schd.status = 'error' THEN
            exec_status = 'Error';
            task_status = 'Error';
            task_status_code = 3;
        ELSIF schd.status = 'finished' THEN
            exec_status = 'Success';
            task_status = 'Success';
            task_status_code = 3;
        ELSIF schd.status = 'running' THEN
            exec_status = 'Running';
            task_status = 'Running';
            task_status_code = 2;
        ELSEIF schd.status = 'pending' THEN
            exec_status = 'Running';
            task_status = 'Pending';
            task_status_code = 0;
        ELSEIF schd.status = 'scheduled' THEN
            exec_status = 'Running';
            task_status = 'Scheduled';
            task_status_code = 1;
        ELSE
            exec_status = 'Running';
            task_status = 'Pending';
            task_status_code = 0;
        END IF;
        INSERT INTO execution (vendor_type, vendor_id, status, revision, trigger, start_time, end_time)
            VALUES ('SCHEDULER', new_schd_id, exec_status, 0, 'MANUAL', schd.creation_time, schd.update_time) RETURNING id INTO exec_id;
        INSERT INTO task (vendor_type, execution_id, job_id, status, status_code, status_revision, run_count, creation_time, start_time, update_time, end_time)
            VALUES ('SCHEDULER',exec_id, schd.job_uuid, task_status, task_status_code, 0, 1, schd.creation_time, schd.creation_time, schd.update_time, schd.update_time);
    END LOOP;
END $$;

/*move the gc history into the new task&execution table*/
DO $$
DECLARE
    aj RECORD;
    exec_id integer;
    exec_status varchar(32);
    task_status varchar(32);
    task_status_code integer;
BEGIN
    FOR aj IN SELECT * FROM admin_job where job_name='IMAGE_GC' and job_kind='Generic'and deleted=FALSE
    LOOP
        IF aj.status = 'stopped' THEN
            exec_status = 'Stopped';
            task_status = 'Stopped';
            task_status_code = 3;
        ELSIF aj.status = 'error' THEN
            exec_status = 'Error';
            task_status = 'Error';
            task_status_code = 3;
        ELSIF aj.status = 'finished' THEN
            exec_status = 'Success';
            task_status = 'Success';
            task_status_code = 3;
        ELSIF aj.status = 'running' THEN
            exec_status = 'Running';
            task_status = 'Running';
            task_status_code = 2;
        ELSEIF aj.status = 'pending' THEN
            exec_status = 'Running';
            task_status = 'Pending';
            task_status_code = 0;
        ELSEIF aj.status = 'scheduled' THEN
            exec_status = 'Running';
            task_status = 'Scheduled';
            task_status_code = 1;
        ELSE
            exec_status = 'Running';
            task_status = 'Pending';
            task_status_code = 0;
        END IF;
        INSERT INTO execution (vendor_type, vendor_id, status, revision, extra_attrs, trigger, start_time, end_time)
            VALUES ('GARBAGE_COLLECTION', -1, exec_status, 0, cast(aj.job_parameters as json),
            'MANUAL', aj.creation_time, aj.update_time) RETURNING id INTO exec_id;
        INSERT INTO task (vendor_type, execution_id, job_id, status, status_code, status_revision, run_count, extra_attrs, creation_time, start_time, update_time, end_time)
            VALUES ('GARBAGE_COLLECTION',exec_id, aj.job_uuid, task_status, task_status_code, 0, 1, cast(aj.job_parameters as json), aj.creation_time, aj.creation_time, aj.update_time, aj.update_time);
    END LOOP;
END $$;

/*move the scan all schedule records into the new schedule table*/
DO $$
DECLARE
    schd RECORD;
    new_schd_id integer;
    exec_id integer;
    exec_status varchar(32);
    task_status varchar(32);
    task_status_code integer;
BEGIN
    FOR schd IN SELECT * FROM admin_job where job_name='IMAGE_SCAN_ALL' and job_kind='Periodic' and deleted=FALSE
    LOOP
        INSERT INTO schedule (vendor_type, vendor_id, cron, callback_func_name,
            cron_type, creation_time, update_time)
            VALUES ('IMAGE_SCAN_ALL', 0,
                 (SELECT schd.cron_str::json->>'cron'),
                'scanAll',
                (SELECT schd.cron_str::json->>'type'),
                schd.creation_time, schd.update_time) RETURNING id INTO new_schd_id;
        IF schd.status = 'stopped' THEN
            exec_status = 'Stopped';
            task_status = 'Stopped';
            task_status_code = 3;
        ELSIF schd.status = 'error' THEN
            exec_status = 'Error';
            task_status = 'Error';
            task_status_code = 3;
        ELSIF schd.status = 'finished' THEN
            exec_status = 'Success';
            task_status = 'Success';
            task_status_code = 3;
        ELSIF schd.status = 'running' THEN
            exec_status = 'Running';
            task_status = 'Running';
            task_status_code = 2;
        ELSEIF schd.status = 'pending' THEN
            exec_status = 'Running';
            task_status = 'Pending';
            task_status_code = 0;
        ELSEIF schd.status = 'scheduled' THEN
            exec_status = 'Running';
            task_status = 'Scheduled';
            task_status_code = 1;
        ELSE
            exec_status = 'Running';
            task_status = 'Pending';
            task_status_code = 0;
        END IF;
        INSERT INTO execution (vendor_type, vendor_id, status, revision, trigger, start_time, end_time)
            VALUES ('SCHEDULER', new_schd_id, exec_status, 0, 'MANUAL', schd.creation_time, schd.update_time) RETURNING id INTO exec_id;
        INSERT INTO task (vendor_type, execution_id, job_id, status, status_code, status_revision, run_count, creation_time, start_time, update_time, end_time)
            VALUES ('SCHEDULER',exec_id, schd.job_uuid, task_status, task_status_code, 0, 1, schd.creation_time, schd.creation_time, schd.update_time, schd.update_time);
    END LOOP;
END $$;

/* admin_job no more needed, drop it */
DROP TABLE IF EXISTS admin_job;

/*migrate robot_token_duration from minutes to days if exist*/
DO $$
DECLARE
   properties_info record;
   duration_in_minutes text;
   duration_in_days integer;
BEGIN
  SELECT INTO properties_info * FROM properties WHERE k = 'robot_token_duration';
  IF properties_info IS NOT NULL THEN
    duration_in_minutes = properties_info.v;
    duration_in_days = cast(duration_in_minutes as integer) / 60 / 24;
    update properties set v = cast(duration_in_days as text)  WHERE k = 'robot_token_duration';
  END IF;
END $$;
