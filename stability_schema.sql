-- =====================================================================
-- Stability Tracker - Database Schema
-- Oracle Database / Oracle APEX
--
-- Run order matters: sequences -> tables -> foreign keys -> view
--                    -> functions -> procedures -> triggers
-- =====================================================================


-- =====================================================================
-- 1. SEQUENCES
-- =====================================================================

CREATE SEQUENCE seq_user_id    START WITH 1 INCREMENT BY 1 NOCACHE;
CREATE SEQUENCE seq_product_id START WITH 1 INCREMENT BY 1 NOCACHE;
CREATE SEQUENCE seq_batch_id   START WITH 1 INCREMENT BY 1 NOCACHE;
CREATE SEQUENCE seq_plan_id    START WITH 1 INCREMENT BY 1 NOCACHE;
CREATE SEQUENCE seq_audit_log  START WITH 1 INCREMENT BY 1 NOCACHE;
CREATE SEQUENCE seq_login_log  START WITH 1 INCREMENT BY 1 NOCACHE;


-- =====================================================================
-- 2. TABLES
-- =====================================================================

CREATE TABLE app_users (
    user_id        NUMBER,
    username       VARCHAR2(50),
    full_name      VARCHAR2(100),
    email          VARCHAR2(100),
    role           VARCHAR2(20),
    is_active      VARCHAR2(1) DEFAULT 'Y',
    created_date   DATE        DEFAULT SYSDATE,
    password_hash  VARCHAR2(200),
    session_id     VARCHAR2(100),
    session_time   DATE,
    last_login     DATE,
    CONSTRAINT pk_app_users    PRIMARY KEY (user_id),
    CONSTRAINT uq_app_username UNIQUE (username),
    CONSTRAINT chk_active      CHECK (is_active IN ('Y','N')),
    CONSTRAINT chk_role        CHECK (role IN ('ADMIN','MANAGER','SUPERVISOR','ANALYST'))
);

CREATE TABLE products (
    product_id    NUMBER,
    product_name  VARCHAR2(100),
    dosage        VARCHAR2(50),
    form          VARCHAR2(50),
    CONSTRAINT pk_products PRIMARY KEY (product_id)
);

CREATE TABLE batches (
    batch_id    NUMBER,
    product_id  NUMBER,
    batch_no    VARCHAR2(50),
    mfg_date    DATE,
    CONSTRAINT pk_batches PRIMARY KEY (batch_id)
);

CREATE TABLE chambers (
    chamber_id    VARCHAR2(20),
    chamber_name  VARCHAR2(20),
    condition     VARCHAR2(50),
    chamber_type  VARCHAR2(20),
    CONSTRAINT pk_chambers PRIMARY KEY (chamber_id)
);

CREATE TABLE stability_whole_plan (
    plan_id                 NUMBER,
    product_id              NUMBER,
    batch_no                VARCHAR2(50),
    mfg_date                DATE,
    interval_months         NUMBER,
    chamber_id              VARCHAR2(20),
    shelf_no                VARCHAR2(20),
    quantity                NUMBER,
    incubation_date         DATE,
    plan_pullout_date       DATE,
    actual_pullout_date     DATE,
    pullout_status          VARCHAR2(10) DEFAULT 'PENDING',
    study_status            VARCHAR2(20),
    discontinuation_reason  VARCHAR2(500),
    remark                  VARCHAR2(500),
    created_by              VARCHAR2(50),
    created_date            DATE DEFAULT SYSDATE,
    updated_by              VARCHAR2(50),
    updated_date            DATE,
    is_deleted              VARCHAR2(1) DEFAULT 'N',
    batch_id                NUMBER,
    condition               VARCHAR2(50),
    study_type              VARCHAR2(20),
    CONSTRAINT pk_stability_plan PRIMARY KEY (plan_id),
    CONSTRAINT chk_study_type CHECK (study_type IN ('LONG_TERM','ACCELERATED','ONGOING'))
);

CREATE TABLE stability_audit_log (
    log_id       NUMBER,
    table_name   VARCHAR2(100),
    action_type  VARCHAR2(10),
    record_id    NUMBER,
    old_data     CLOB,
    new_data     CLOB,
    changed_by   VARCHAR2(100),
    change_date  DATE DEFAULT SYSDATE,
    CONSTRAINT pk_stability_audit_log PRIMARY KEY (log_id)
);

CREATE TABLE login_audit_log (
    log_id       NUMBER        NOT NULL,
    username     VARCHAR2(100) NOT NULL,
    email        VARCHAR2(100),
    action       VARCHAR2(20)  NOT NULL,
    login_time   DATE,
    logout_time  DATE,
    ip_address   VARCHAR2(50),
    session_id   VARCHAR2(100),
    CONSTRAINT pk_login_audit_log PRIMARY KEY (log_id)
);


-- =====================================================================
-- 3. FOREIGN KEYS
-- =====================================================================

ALTER TABLE batches ADD CONSTRAINT fk_batches_product
    FOREIGN KEY (product_id) REFERENCES products (product_id);

ALTER TABLE stability_whole_plan ADD CONSTRAINT fk_plan_product
    FOREIGN KEY (product_id) REFERENCES products (product_id);

ALTER TABLE stability_whole_plan ADD CONSTRAINT fk_plan_chamber
    FOREIGN KEY (chamber_id) REFERENCES chambers (chamber_id);

ALTER TABLE stability_whole_plan ADD CONSTRAINT fk_plan_batch
    FOREIGN KEY (batch_id) REFERENCES batches (batch_id);


-- =====================================================================
-- 4. VIEW - pull-out schedule matrix (one row per batch, one column per interval)
-- =====================================================================

CREATE OR REPLACE VIEW v_stability_report AS
SELECT s.study_type,
       p.product_name,
       s.batch_no,
       s.mfg_date,
       s.incubation_date,
       MAX(CASE WHEN s.interval_months = 3  THEN s.plan_pullout_date END) AS "3M",
       MAX(CASE WHEN s.interval_months = 6  THEN s.plan_pullout_date END) AS "6M",
       MAX(CASE WHEN s.interval_months = 9  THEN s.plan_pullout_date END) AS "9M",
       MAX(CASE WHEN s.interval_months = 12 THEN s.plan_pullout_date END) AS "12M",
       MAX(CASE WHEN s.interval_months = 18 THEN s.plan_pullout_date END) AS "18M",
       MAX(CASE WHEN s.interval_months = 24 THEN s.plan_pullout_date END) AS "24M",
       MAX(CASE WHEN s.interval_months = 36 THEN s.plan_pullout_date END) AS "36M",
       MAX(CASE WHEN s.interval_months = 48 THEN s.plan_pullout_date END) AS "48M",
       MAX(CASE WHEN s.interval_months = 60 THEN s.plan_pullout_date END) AS "60M"
FROM   stability_whole_plan s
LEFT JOIN products p ON s.product_id = p.product_id
WHERE  s.is_deleted = 'N'
GROUP BY s.study_type, p.product_name, s.batch_no, s.mfg_date, s.incubation_date;


-- =====================================================================
-- 5. FUNCTIONS
-- =====================================================================

-- NOTE: unsalted SHA-256 (see README - Known Limitations)
CREATE OR REPLACE FUNCTION get_hash (p_text IN VARCHAR2)
RETURN VARCHAR2
IS
    v_hash VARCHAR2(255);
BEGIN
    -- STANDARD_HASH is SQL-only, so it is called through DUAL
    SELECT STANDARD_HASH(p_text, 'SHA256') INTO v_hash FROM dual;
    RETURN v_hash;
END;
/

CREATE OR REPLACE FUNCTION get_overdue_count
RETURN NUMBER
IS
    v_count NUMBER;
BEGIN
    SELECT COUNT(*) INTO v_count
    FROM   stability_whole_plan
    WHERE  pullout_status    = 'PENDING'
    AND    plan_pullout_date < TRUNC(SYSDATE)
    AND    is_deleted        = 'N';
    RETURN v_count;
END;
/

-- Custom APEX authentication:
--   password check, login audit, single-session control
CREATE OR REPLACE FUNCTION authenticate2_users (
    p_username IN VARCHAR2,
    p_password IN VARCHAR2
) RETURN BOOLEAN
IS
    v_count         NUMBER;
    v_pwd           VARCHAR2(255);
    v_email         VARCHAR2(100);
    v_session       VARCHAR2(100);
    v_session_time  DATE;
    v_user_id       NUMBER;
BEGIN
    SELECT COUNT(*) INTO v_count
    FROM   app_users
    WHERE  UPPER(username) = UPPER(p_username)
    AND    is_active = 'Y';

    IF v_count = 0 THEN
        INSERT INTO login_audit_log (log_id, username, email, action, login_time)
        VALUES (seq_login_log.NEXTVAL, UPPER(p_username), NULL, 'NOT_FOUND', SYSDATE);
        COMMIT;
        APEX_UTIL.SET_AUTHENTICATION_RESULT(1);
        RETURN FALSE;
    END IF;

    SELECT password_hash, email, session_id, session_time, user_id
    INTO   v_pwd, v_email, v_session, v_session_time, v_user_id
    FROM   app_users
    WHERE  UPPER(username) = UPPER(p_username);

    IF v_pwd != get_hash(p_password) THEN
        INSERT INTO login_audit_log (log_id, username, email, action, login_time)
        VALUES (seq_login_log.NEXTVAL, UPPER(p_username), v_email, 'FAILED', SYSDATE);
        COMMIT;
        APEX_UTIL.SET_AUTHENTICATION_RESULT(4);
        RETURN FALSE;
    END IF;

    -- Single-session control: block a second login while an active
    -- session is younger than 8 hours
    IF v_session IS NOT NULL
       AND (SYSDATE - NVL(v_session_time, SYSDATE - 1)) * 24 < 8 THEN
        INSERT INTO login_audit_log (log_id, username, email, action, login_time)
        VALUES (seq_login_log.NEXTVAL, UPPER(p_username), v_email, 'BLOCKED', SYSDATE);
        COMMIT;
        APEX_UTIL.SET_AUTHENTICATION_RESULT(4);
        RETURN FALSE;
    END IF;

    UPDATE app_users
    SET    session_id   = TO_CHAR(SYSDATE, 'YYYYMMDDHH24MISS') || '_' || UPPER(p_username),
           session_time = SYSDATE,
           last_login   = SYSDATE
    WHERE  user_id = v_user_id;

    INSERT INTO login_audit_log (log_id, username, email, action, login_time)
    VALUES (seq_login_log.NEXTVAL, UPPER(p_username), v_email, 'LOGIN', SYSDATE);
    COMMIT;

    APEX_UTIL.SET_AUTHENTICATION_RESULT(0);
    RETURN TRUE;

EXCEPTION
    WHEN OTHERS THEN
        APEX_UTIL.SET_AUTHENTICATION_RESULT(7);
        RETURN FALSE;
END;
/


-- =====================================================================
-- 6. PROCEDURES
-- =====================================================================

CREATE OR REPLACE PROCEDURE logout_user (p_username IN VARCHAR2)
AS
BEGIN
    UPDATE app_users
    SET    session_id   = NULL,
           session_time = NULL
    WHERE  UPPER(username) = UPPER(p_username);

    INSERT INTO login_audit_log (log_id, username, email, action, login_time)
    SELECT seq_login_log.NEXTVAL, UPPER(p_username), email, 'LOGOUT', SYSDATE
    FROM   app_users
    WHERE  UPPER(username) = UPPER(p_username);

    COMMIT;
EXCEPTION
    WHEN OTHERS THEN
        NULL; -- never block the logout itself
END;
/

-- Used as the APEX "Post-Logout Procedure"
CREATE OR REPLACE PROCEDURE post_logout_handler
AS
BEGIN
    logout_user(V('APP_USER'));
END;
/

CREATE OR REPLACE PROCEDURE log_user_login
AS
BEGIN
    INSERT INTO login_audit_log
        (log_id, username, email, session_id, action, login_time, ip_address)
    SELECT seq_login_log.NEXTVAL,
           UPPER(V('APP_USER')),
           email,
           V('APP_SESSION'),
           'LOGIN',
           SYSDATE,
           OWA_UTIL.GET_CGI_ENV('REMOTE_ADDR')
    FROM   app_users
    WHERE  UPPER(username) = UPPER(V('APP_USER'));

    COMMIT;
END;
/

CREATE OR REPLACE PROCEDURE record_pullout (
    p_plan_id         IN NUMBER,
    p_actual_pullout  IN DATE,
    p_updated_by      IN VARCHAR2
) AS
BEGIN
    UPDATE stability_whole_plan
    SET    actual_pullout_date = p_actual_pullout,
           pullout_status      = 'DONE',
           updated_by          = p_updated_by
    WHERE  plan_id = p_plan_id;
    COMMIT;
END;
/


-- =====================================================================
-- 7. TRIGGERS
-- =====================================================================

-- ---------- Primary keys from sequences ----------

CREATE OR REPLACE TRIGGER trg_user_id
BEFORE INSERT ON app_users
FOR EACH ROW
BEGIN
    :NEW.user_id := seq_user_id.NEXTVAL;
END;
/

CREATE OR REPLACE TRIGGER trg_product_id
BEFORE INSERT ON products
FOR EACH ROW
BEGIN
    :NEW.product_id := seq_product_id.NEXTVAL;
END;
/

CREATE OR REPLACE TRIGGER trg_batch_id
BEFORE INSERT ON batches
FOR EACH ROW
BEGIN
    IF :NEW.batch_id IS NULL THEN
        :NEW.batch_id := seq_batch_id.NEXTVAL;
    END IF;
END;
/

-- ---------- Stability plan business rules ----------

CREATE OR REPLACE TRIGGER trg_plan_before
BEFORE INSERT ON stability_whole_plan
FOR EACH ROW
BEGIN
    :NEW.plan_id        := seq_plan_id.NEXTVAL;
    :NEW.created_date   := SYSDATE;
    :NEW.pullout_status := NVL(:NEW.pullout_status, 'PENDING');
    :NEW.is_deleted     := NVL(:NEW.is_deleted, 'N');
    :NEW.created_by     := NVL(SYS_CONTEXT('APEX$SESSION','APP_USER'),
                               SYS_CONTEXT('USERENV','SESSION_USER'));
END;
/

-- Planned pull-out date = incubation date + interval
CREATE OR REPLACE TRIGGER trg_plan_calc
BEFORE INSERT OR UPDATE ON stability_whole_plan
FOR EACH ROW
BEGIN
    IF :NEW.incubation_date IS NOT NULL AND :NEW.interval_months IS NOT NULL THEN
        :NEW.plan_pullout_date := ADD_MONTHS(:NEW.incubation_date, :NEW.interval_months);
    END IF;
END;
/

CREATE OR REPLACE TRIGGER trg_plan_updated
BEFORE UPDATE ON stability_whole_plan
FOR EACH ROW
BEGIN
    :NEW.updated_date := SYSDATE;
    :NEW.updated_by   := NVL(SYS_CONTEXT('APEX$SESSION','APP_USER'),
                             SYS_CONTEXT('USERENV','SESSION_USER'));
END;
/

-- Stamp / clear the actual pull-out date when the status changes
CREATE OR REPLACE TRIGGER trg_actual_pullout
BEFORE UPDATE ON stability_whole_plan
FOR EACH ROW
BEGIN
    IF :NEW.pullout_status = 'DONE'
       AND :OLD.pullout_status <> 'DONE'
       AND :NEW.actual_pullout_date IS NULL THEN
        :NEW.actual_pullout_date := SYSDATE;
    ELSIF :NEW.pullout_status = 'PENDING' THEN
        :NEW.actual_pullout_date := NULL;
    END IF;
END;
/

-- ---------- Audit trail ----------

CREATE OR REPLACE TRIGGER trg_app_users_audit
AFTER INSERT OR UPDATE OR DELETE ON app_users
FOR EACH ROW
DECLARE
    v_action VARCHAR2(10);
    v_old    VARCHAR2(500);
    v_new    VARCHAR2(500);
    v_id     NUMBER;
BEGIN
    IF INSERTING THEN
        v_action := 'INSERT';
        v_new    := 'USERNAME=' || :NEW.username || ', ROLE=' || :NEW.role || ', ACTIVE=' || :NEW.is_active;
        v_id     := :NEW.user_id;
    ELSIF UPDATING THEN
        v_action := 'UPDATE';
        v_old    := 'USERNAME=' || :OLD.username || ', ROLE=' || :OLD.role || ', ACTIVE=' || :OLD.is_active;
        v_new    := 'USERNAME=' || :NEW.username || ', ROLE=' || :NEW.role || ', ACTIVE=' || :NEW.is_active;
        v_id     := :NEW.user_id;
    ELSIF DELETING THEN
        v_action := 'DELETE';
        v_old    := 'USERNAME=' || :OLD.username || ', ROLE=' || :OLD.role || ', ACTIVE=' || :OLD.is_active;
        v_id     := :OLD.user_id;
    END IF;

    INSERT INTO stability_audit_log
        (log_id, table_name, action_type, record_id, old_data, new_data, changed_by, change_date)
    VALUES
        (seq_audit_log.NEXTVAL, 'APP_USERS', v_action, v_id, v_old, v_new,
         NVL(SYS_CONTEXT('APEX$SESSION','APP_USER'), SYS_CONTEXT('USERENV','SESSION_USER')),
         SYSDATE);
END;
/

CREATE OR REPLACE TRIGGER trg_products_audit
AFTER INSERT OR UPDATE OR DELETE ON products
FOR EACH ROW
DECLARE
    v_action VARCHAR2(10);
    v_old    VARCHAR2(500);
    v_new    VARCHAR2(500);
    v_id     NUMBER;
BEGIN
    IF INSERTING THEN
        v_action := 'INSERT';
        v_new    := 'NAME=' || NVL(:NEW.product_name,'NULL') || ', DOSAGE=' || NVL(:NEW.dosage,'NULL') || ', FORM=' || NVL(:NEW.form,'NULL');
        v_id     := :NEW.product_id;
    ELSIF UPDATING THEN
        v_action := 'UPDATE';
        v_old    := 'NAME=' || NVL(:OLD.product_name,'NULL') || ', DOSAGE=' || NVL(:OLD.dosage,'NULL') || ', FORM=' || NVL(:OLD.form,'NULL');
        v_new    := 'NAME=' || NVL(:NEW.product_name,'NULL') || ', DOSAGE=' || NVL(:NEW.dosage,'NULL') || ', FORM=' || NVL(:NEW.form,'NULL');
        v_id     := :NEW.product_id;
    ELSIF DELETING THEN
        v_action := 'DELETE';
        v_old    := 'NAME=' || NVL(:OLD.product_name,'NULL') || ', DOSAGE=' || NVL(:OLD.dosage,'NULL') || ', FORM=' || NVL(:OLD.form,'NULL');
        v_id     := :OLD.product_id;
    END IF;

    INSERT INTO stability_audit_log
        (log_id, table_name, action_type, record_id, old_data, new_data, changed_by, change_date)
    VALUES
        (seq_audit_log.NEXTVAL, 'PRODUCTS', v_action, v_id, v_old, v_new,
         NVL(SYS_CONTEXT('APEX$SESSION','APP_USER'), SYS_CONTEXT('USERENV','SESSION_USER')),
         SYSDATE);
END;
/

CREATE OR REPLACE TRIGGER trg_batches_audit
AFTER INSERT OR UPDATE OR DELETE ON batches
FOR EACH ROW
DECLARE
    v_action VARCHAR2(10);
    v_old    VARCHAR2(500);
    v_new    VARCHAR2(500);
    v_id     NUMBER;
BEGIN
    IF INSERTING THEN
        v_action := 'INSERT';
        v_new    := 'BATCH_NO=' || NVL(:NEW.batch_no,'NULL') || ', MFG_DATE=' || TO_CHAR(:NEW.mfg_date,'DD-MON-YYYY');
        v_id     := :NEW.batch_id;
    ELSIF UPDATING THEN
        v_action := 'UPDATE';
        v_old    := 'BATCH_NO=' || NVL(:OLD.batch_no,'NULL');
        v_new    := 'BATCH_NO=' || NVL(:NEW.batch_no,'NULL');
        v_id     := :NEW.batch_id;
    ELSIF DELETING THEN
        v_action := 'DELETE';
        v_old    := 'BATCH_NO=' || NVL(:OLD.batch_no,'NULL');
        v_id     := :OLD.batch_id;
    END IF;

    INSERT INTO stability_audit_log
        (log_id, table_name, action_type, record_id, old_data, new_data, changed_by, change_date)
    VALUES
        (seq_audit_log.NEXTVAL, 'BATCHES', v_action, v_id, v_old, v_new,
         NVL(SYS_CONTEXT('APEX$SESSION','APP_USER'), SYS_CONTEXT('USERENV','SESSION_USER')),
         SYSDATE);
END;
/

CREATE OR REPLACE TRIGGER trg_stability_audit
AFTER INSERT OR UPDATE OR DELETE ON stability_whole_plan
FOR EACH ROW
DECLARE
    v_action VARCHAR2(10);
    v_old    VARCHAR2(500);
    v_new    VARCHAR2(500);
    v_id     NUMBER;
BEGIN
    IF INSERTING THEN
        v_action := 'INSERT';
        v_new    := 'STATUS=' || NVL(:NEW.pullout_status,'NULL') || ', PRODUCT_ID=' || NVL(TO_CHAR(:NEW.product_id),'NULL');
        v_id     := :NEW.plan_id;
    ELSIF UPDATING THEN
        v_action := 'UPDATE';
        v_old    := 'STATUS=' || NVL(:OLD.pullout_status,'NULL');
        v_new    := 'STATUS=' || NVL(:NEW.pullout_status,'NULL');
        v_id     := :NEW.plan_id;
    ELSIF DELETING THEN
        v_action := 'DELETE';
        v_old    := 'STATUS=' || NVL(:OLD.pullout_status,'NULL');
        v_id     := :OLD.plan_id;
    END IF;

    INSERT INTO stability_audit_log
        (log_id, table_name, action_type, record_id, old_data, new_data, changed_by, change_date)
    VALUES
        (seq_audit_log.NEXTVAL, 'STABILITY_WHOLE_PLAN', v_action, v_id, v_old, v_new,
         NVL(SYS_CONTEXT('APEX$SESSION','APP_USER'), SYS_CONTEXT('USERENV','SESSION_USER')),
         SYSDATE);
END;
/
