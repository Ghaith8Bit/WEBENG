-- Enable useful extensions
CREATE EXTENSION IF NOT EXISTS btree_gist;
CREATE EXTENSION IF NOT EXISTS citext;

-- Enumerated types
CREATE TYPE user_role AS ENUM ('admin', 'provider', 'customer');

CREATE TYPE user_status AS ENUM ('pending', 'active', 'suspended', 'blocked');

CREATE TYPE booking_status AS ENUM ('pending', 'confirmed', 'completed', 'cancelled', 'no_show');

CREATE TYPE audit_action AS ENUM ('INSERT', 'UPDATE', 'DELETE');

-- Utility function to auto-update updated_at
CREATE OR REPLACE FUNCTION set_timestamp()
RETURNS TRIGGER AS $$
BEGIN
    NEW.updated_at := NOW();
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;


-- =========================
-- 1. USERS & PROVIDERS
-- =========================

CREATE TABLE app_user (
    id              BIGSERIAL PRIMARY KEY,
    role            user_role NOT NULL,
    full_name       VARCHAR(150) NOT NULL,
    email           CITEXT UNIQUE NOT NULL,
    phone           VARCHAR(30),
    password_hash   TEXT NOT NULL,
    status          user_status NOT NULL DEFAULT 'pending',
    is_deleted      BOOLEAN NOT NULL DEFAULT FALSE,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TRIGGER app_user_set_timestamp
BEFORE UPDATE ON app_user
FOR EACH ROW
EXECUTE FUNCTION set_timestamp();


-- Extra info for providers
CREATE TABLE provider_profile (
    user_id         BIGINT PRIMARY KEY REFERENCES app_user(id) ON DELETE CASCADE,
    company_name    VARCHAR(150),
    bio             TEXT,
    address_line1   VARCHAR(255),
    address_line2   VARCHAR(255),
    city            VARCHAR(100),
    country         VARCHAR(100),
    latitude        NUMERIC(9,6),
    longitude       NUMERIC(9,6)
);


-- =========================
-- 2. CATEGORIES & SERVICES
-- =========================

CREATE TABLE service_category (
    id              BIGSERIAL PRIMARY KEY,
    parent_id       BIGINT REFERENCES service_category(id) ON DELETE SET NULL,
    name            VARCHAR(100) NOT NULL,
    description     TEXT,
    is_active       BOOLEAN NOT NULL DEFAULT TRUE,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    UNIQUE (parent_id, name)
);

CREATE TRIGGER service_category_set_timestamp
BEFORE UPDATE ON service_category
FOR EACH ROW
EXECUTE FUNCTION set_timestamp();


CREATE TABLE service (
    id              BIGSERIAL PRIMARY KEY,
    provider_id     BIGINT NOT NULL REFERENCES app_user(id) ON DELETE CASCADE,
    category_id     BIGINT NOT NULL REFERENCES service_category(id),
    title           VARCHAR(150) NOT NULL,
    description     TEXT,
    base_price      NUMERIC(12,2) NOT NULL CHECK (base_price >= 0),
    currency        VARCHAR(3) NOT NULL DEFAULT 'USD',
    is_active       BOOLEAN NOT NULL DEFAULT TRUE,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_service_provider ON service(provider_id);
CREATE INDEX idx_service_category ON service(category_id);

CREATE TRIGGER service_set_timestamp
BEFORE UPDATE ON service
FOR EACH ROW
EXECUTE FUNCTION set_timestamp();


-- =========================
-- 3. BOOKINGS / RESERVATIONS
-- =========================

CREATE TABLE booking (
    id                  BIGSERIAL PRIMARY KEY,
    customer_id         BIGINT NOT NULL REFERENCES app_user(id),
    provider_id         BIGINT NOT NULL REFERENCES app_user(id),
    service_id          BIGINT NOT NULL REFERENCES service(id),
    status              booking_status NOT NULL DEFAULT 'pending',

    scheduled_start     TIMESTAMPTZ NOT NULL,
    scheduled_end       TIMESTAMPTZ NOT NULL,

    time_range          TSTZRANGE GENERATED ALWAYS AS
                        (tstzrange(scheduled_start, scheduled_end, '[)')) STORED,

    address_line1       VARCHAR(255) NOT NULL,
    address_line2       VARCHAR(255),
    city                VARCHAR(100),
    country             VARCHAR(100),

    agreed_price        NUMERIC(12,2),
    currency            VARCHAR(3) NOT NULL DEFAULT 'USD',

    notes               TEXT,
    created_at          TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at          TIMESTAMPTZ NOT NULL DEFAULT NOW(),

    CHECK (scheduled_start < scheduled_end),

    CONSTRAINT booking_no_overlapping_for_provider
        EXCLUDE USING gist (
            provider_id WITH =,
            time_range WITH &&
        )
        WHERE (status IN ('pending', 'confirmed'))
);

CREATE INDEX idx_booking_provider ON booking(provider_id);
CREATE INDEX idx_booking_customer ON booking(customer_id);
CREATE INDEX idx_booking_status ON booking(status);

CREATE TRIGGER booking_set_timestamp
BEFORE UPDATE ON booking
FOR EACH ROW
EXECUTE FUNCTION set_timestamp();


-- Validation trigger for bookings
CREATE OR REPLACE FUNCTION booking_validate()
RETURNS TRIGGER AS $$
DECLARE
    provider_role user_role;
    provider_status user_status;
    customer_role user_role;
    customer_status user_status;
    service_is_active BOOLEAN;
BEGIN
    -- Provider checks
    SELECT role, status INTO provider_role, provider_status
    FROM app_user WHERE id = NEW.provider_id;

    IF provider_role IS NULL OR provider_role <> 'provider' THEN
        RAISE EXCEPTION 'provider_id % is not a valid provider', NEW.provider_id;
    END IF;

    IF provider_status <> 'active' THEN
        RAISE EXCEPTION 'provider % is not active', NEW.provider_id;
    END IF;

    -- Customer checks
    SELECT role, status INTO customer_role, customer_status
    FROM app_user WHERE id = NEW.customer_id;

    IF customer_role IS NULL OR customer_role <> 'customer' THEN
        RAISE EXCEPTION 'customer_id % is not a valid customer', NEW.customer_id;
    END IF;

    IF customer_status <> 'active' THEN
        RAISE EXCEPTION 'customer % is not active', NEW.customer_id;
    END IF;

    -- Service active?
    SELECT is_active INTO service_is_active
    FROM service WHERE id = NEW.service_id;

    IF service_is_active IS NULL OR service_is_active = FALSE THEN
        RAISE EXCEPTION 'service % is not active', NEW.service_id;
    END IF;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER booking_validate_insert_update
BEFORE INSERT OR UPDATE ON booking
FOR EACH ROW
EXECUTE FUNCTION booking_validate();


-- =========================
-- 4. REVIEWS & COMMENTS
-- =========================

CREATE TABLE review (
    id              BIGSERIAL PRIMARY KEY,
    booking_id      BIGINT NOT NULL UNIQUE REFERENCES booking(id) ON DELETE CASCADE,
    reviewer_id     BIGINT NOT NULL REFERENCES app_user(id),
    provider_id     BIGINT NOT NULL REFERENCES app_user(id),
    rating          SMALLINT NOT NULL CHECK (rating BETWEEN 1 AND 5),
    title           VARCHAR(200),
    body            TEXT,
    is_deleted      BOOLEAN NOT NULL DEFAULT FALSE,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_review_provider ON review(provider_id);
CREATE INDEX idx_review_reviewer ON review(reviewer_id);

CREATE TRIGGER review_set_timestamp
BEFORE UPDATE ON review
FOR EACH ROW
EXECUTE FUNCTION set_timestamp();


CREATE OR REPLACE FUNCTION review_validate()
RETURNS TRIGGER AS $$
DECLARE
    b_customer_id BIGINT;
    b_provider_id BIGINT;
    b_status      booking_status;
BEGIN
    SELECT customer_id, provider_id, status
    INTO b_customer_id, b_provider_id, b_status
    FROM booking WHERE id = NEW.booking_id;

    IF b_status IS NULL THEN
        RAISE EXCEPTION 'Booking % does not exist', NEW.booking_id;
    END IF;

    IF b_status <> 'completed' THEN
        RAISE EXCEPTION 'Only completed bookings can be reviewed';
    END IF;

    IF NEW.reviewer_id <> b_customer_id THEN
        RAISE EXCEPTION 'Reviewer must be the booking customer';
    END IF;

    IF NEW.provider_id <> b_provider_id THEN
        RAISE EXCEPTION 'Review provider must match booking provider';
    END IF;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER review_validate_insert
BEFORE INSERT ON review
FOR EACH ROW
EXECUTE FUNCTION review_validate();


CREATE TABLE review_comment (
    id              BIGSERIAL PRIMARY KEY,
    review_id       BIGINT NOT NULL REFERENCES review(id) ON DELETE CASCADE,
    author_id       BIGINT NOT NULL REFERENCES app_user(id),
    body            TEXT NOT NULL,
    is_deleted      BOOLEAN NOT NULL DEFAULT FALSE,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_review_comment_review ON review_comment(review_id);

CREATE TRIGGER review_comment_set_timestamp
BEFORE UPDATE ON review_comment
FOR EACH ROW
EXECUTE FUNCTION set_timestamp();


-- =========================
-- 5. AUDIT LOGGING
-- =========================

CREATE TABLE audit_log (
    id              BIGSERIAL PRIMARY KEY,
    table_name      TEXT NOT NULL,
    record_id       BIGINT,
    action          audit_action NOT NULL,
    changed_by      BIGINT REFERENCES app_user(id),
    changed_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    old_data        JSONB,
    new_data        JSONB
);

CREATE OR REPLACE FUNCTION audit_log_trigger()
RETURNS TRIGGER AS $$
DECLARE
    v_user_id BIGINT;
BEGIN
    -- Optionally set from app: SELECT set_config('app.current_user_id', '123', false);
    BEGIN
        v_user_id := current_setting('app.current_user_id', true)::BIGINT;
    EXCEPTION WHEN others THEN
        v_user_id := NULL;
    END;

    IF (TG_OP = 'INSERT') THEN
        INSERT INTO audit_log (table_name, record_id, action, changed_by, old_data, new_data)
        VALUES (TG_TABLE_NAME, NEW.id, 'INSERT', v_user_id, NULL, to_jsonb(NEW));
        RETURN NEW;
    ELSIF (TG_OP = 'UPDATE') THEN
        INSERT INTO audit_log (table_name, record_id, action, changed_by, old_data, new_data)
        VALUES (TG_TABLE_NAME, NEW.id, 'UPDATE', v_user_id, to_jsonb(OLD), to_jsonb(NEW));
        RETURN NEW;
    ELSIF (TG_OP = 'DELETE') THEN
        INSERT INTO audit_log (table_name, record_id, action, changed_by, old_data, new_data)
        VALUES (TG_TABLE_NAME, OLD.id, 'DELETE', v_user_id, to_jsonb(OLD), NULL);
        RETURN OLD;
    END IF;

    RETURN NULL;
END;
$$ LANGUAGE plpgsql;

-- Attach audit triggers
CREATE TRIGGER audit_app_user
AFTER INSERT OR UPDATE OR DELETE ON app_user
FOR EACH ROW EXECUTE FUNCTION audit_log_trigger();

CREATE TRIGGER audit_service_category
AFTER INSERT OR UPDATE OR DELETE ON service_category
FOR EACH ROW EXECUTE FUNCTION audit_log_trigger();

CREATE TRIGGER audit_service
AFTER INSERT OR UPDATE OR DELETE ON service
FOR EACH ROW EXECUTE FUNCTION audit_log_trigger();

CREATE TRIGGER audit_booking
AFTER INSERT OR UPDATE OR DELETE ON booking
FOR EACH ROW EXECUTE FUNCTION audit_log_trigger();

CREATE TRIGGER audit_review
AFTER INSERT OR UPDATE OR DELETE ON review
FOR EACH ROW EXECUTE FUNCTION audit_log_trigger();

CREATE TRIGGER audit_review_comment
AFTER INSERT OR UPDATE OR DELETE ON review_comment
FOR EACH ROW EXECUTE FUNCTION audit_log_trigger();


-- =========================
-- 6. PROVIDER SCHEDULE VIEW
-- =========================

CREATE OR REPLACE VIEW provider_schedule AS
SELECT
    b.id AS booking_id,
    b.provider_id,
    p.full_name AS provider_name,
    b.customer_id,
    c.full_name AS customer_name,
    b.service_id,
    s.title AS service_title,
    b.status,
    b.scheduled_start,
    b.scheduled_end,
    b.city,
    b.country
FROM booking b
JOIN app_user p ON p.id = b.provider_id
JOIN app_user c ON c.id = b.customer_id
JOIN service s ON s.id = b.service_id;
