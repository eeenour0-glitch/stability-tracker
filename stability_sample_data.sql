-- =====================================================================
-- Stability Tracker - Sample Data (100% synthetic)
--
-- All dates are RELATIVE to SYSDATE, so the demo always shows
-- DONE, OVERDUE and UPCOMING pull-outs no matter when it is run.
--
-- Runs as one PL/SQL block (works in APEX SQL Commands).
-- Demo users password: Demo@123
-- =====================================================================
DECLARE
    TYPE t_months IS TABLE OF NUMBER;

    v_prod_a  NUMBER;
    v_prod_b  NUMBER;
    v_prod_c  NUMBER;
    v_batch_a NUMBER;
    v_batch_b NUMBER;
    v_batch_c NUMBER;

    -- Creates every pull-out row of one study (same idea as the APEX process)
    PROCEDURE create_plan (
        p_product_id  NUMBER,
        p_batch_id    NUMBER,
        p_batch_no    VARCHAR2,
        p_mfg_date    DATE,
        p_study_type  VARCHAR2,
        p_chamber_id  VARCHAR2,
        p_shelf_no    VARCHAR2,
        p_condition   VARCHAR2,
        p_incubation  DATE,
        p_months      t_months
    ) IS
    BEGIN
        FOR i IN 1 .. p_months.COUNT LOOP
            INSERT INTO stability_whole_plan (
                product_id, batch_id, batch_no, mfg_date, interval_months,
                chamber_id, shelf_no, quantity, incubation_date,
                condition, study_type, study_status
            ) VALUES (
                p_product_id, p_batch_id, p_batch_no, p_mfg_date, p_months(i),
                p_chamber_id, p_shelf_no, 20, p_incubation,
                p_condition, p_study_type, 'ACTIVE'
            );
            -- plan_id, plan_pullout_date, created_by: filled by triggers
        END LOOP;
    END;

BEGIN
    -- -----------------------------------------------------------------
    -- Chambers (standard storage conditions)
    -- ID format must be XX-NN: page 4 derives it from the shelf number
    -- -----------------------------------------------------------------
    DELETE FROM chambers;

    INSERT INTO chambers VALUES ('CH-01', 'Chamber 01', '25°C / 60% RH', 'LONG_TERM');
    INSERT INTO chambers VALUES ('CH-02', 'Chamber 02', '40°C / 75% RH', 'ACCELERATED');
    INSERT INTO chambers VALUES ('CH-03', 'Chamber 03', '30°C / 75% RH', 'ONGOING');

    -- -----------------------------------------------------------------
    -- Products
    -- -----------------------------------------------------------------
    INSERT INTO products (product_name, dosage, form)
    VALUES ('Product A', '500 mg', 'Tablet')
    RETURNING product_id INTO v_prod_a;

    INSERT INTO products (product_name, dosage, form)
    VALUES ('Product B', '250 mg', 'Capsule')
    RETURNING product_id INTO v_prod_b;

    INSERT INTO products (product_name, dosage, form)
    VALUES ('Product C', '5 mg/ml', 'Oral Solution')
    RETURNING product_id INTO v_prod_c;

    -- -----------------------------------------------------------------
    -- Batches
    -- -----------------------------------------------------------------
    INSERT INTO batches (product_id, batch_no, mfg_date)
    VALUES (v_prod_a, 'TEST-A-001', TRUNC(ADD_MONTHS(SYSDATE, -13), 'MM'))
    RETURNING batch_id INTO v_batch_a;

    INSERT INTO batches (product_id, batch_no, mfg_date)
    VALUES (v_prod_b, 'TEST-B-001', TRUNC(ADD_MONTHS(SYSDATE, -7), 'MM'))
    RETURNING batch_id INTO v_batch_b;

    INSERT INTO batches (product_id, batch_no, mfg_date)
    VALUES (v_prod_c, 'TEST-C-001', TRUNC(ADD_MONTHS(SYSDATE, -4), 'MM'))
    RETURNING batch_id INTO v_batch_c;

    -- -----------------------------------------------------------------
    -- Study 1: LONG_TERM, incubated ~13 months ago
    --   3M, 6M, 9M -> DONE
    --   12M        -> OVERDUE (still PENDING, date passed)
    --   18M+       -> future
    -- -----------------------------------------------------------------
    create_plan(v_prod_a, v_batch_a, 'TEST-A-001',
                TRUNC(ADD_MONTHS(SYSDATE, -13), 'MM'),
                'LONG_TERM', 'CH-01', 'CH-01-S1', '25°C / 60% RH',
                ADD_MONTHS(TRUNC(SYSDATE), -13) + 5,
                t_months(3, 6, 9, 12, 18, 24, 36, 48, 60));

    UPDATE stability_whole_plan
    SET    pullout_status      = 'DONE',
           actual_pullout_date = plan_pullout_date + 1
    WHERE  batch_no = 'TEST-A-001'
    AND    interval_months IN (3, 6, 9);

    -- -----------------------------------------------------------------
    -- Study 2: ACCELERATED
    --   3M -> DONE
    --   6M -> due in 2 days (shows in the "upcoming" alert)
    -- -----------------------------------------------------------------
    create_plan(v_prod_b, v_batch_b, 'TEST-B-001',
                TRUNC(ADD_MONTHS(SYSDATE, -7), 'MM'),
                'ACCELERATED', 'CH-02', 'CH-02-S1', '40°C / 75% RH',
                ADD_MONTHS(TRUNC(SYSDATE) + 2, -6),
                t_months(3, 6));

    UPDATE stability_whole_plan
    SET    pullout_status      = 'DONE',
           actual_pullout_date = plan_pullout_date
    WHERE  batch_no = 'TEST-B-001'
    AND    interval_months = 3;

    -- -----------------------------------------------------------------
    -- Study 3: ONGOING, recently started -> first pull-out tomorrow
    -- -----------------------------------------------------------------
    create_plan(v_prod_c, v_batch_c, 'TEST-C-001',
                TRUNC(ADD_MONTHS(SYSDATE, -4), 'MM'),
                'ONGOING', 'CH-03', 'CH-03-S2', '30°C / 75% RH',
                ADD_MONTHS(TRUNC(SYSDATE) + 1, -3),
                t_months(3, 6, 12, 18, 24, 36, 48, 60));

    -- -----------------------------------------------------------------
    -- Demo users (one per role)
    -- -----------------------------------------------------------------
    INSERT INTO app_users (username, full_name, email, role, is_active, password_hash)
    VALUES ('manager', 'Demo Manager', 'manager@demo.com', 'MANAGER', 'Y', get_hash('Demo@123'));

    INSERT INTO app_users (username, full_name, email, role, is_active, password_hash)
    VALUES ('admin', 'Demo Admin', 'admin@demo.com', 'ADMIN', 'Y', get_hash('Demo@123'));

    INSERT INTO app_users (username, full_name, email, role, is_active, password_hash)
    VALUES ('supervisor', 'Demo Supervisor', 'supervisor@demo.com', 'SUPERVISOR', 'Y', get_hash('Demo@123'));

    INSERT INTO app_users (username, full_name, email, role, is_active, password_hash)
    VALUES ('analyst', 'Demo Analyst', 'analyst@demo.com', 'ANALYST', 'Y', get_hash('Demo@123'));

    COMMIT;
END;
/
