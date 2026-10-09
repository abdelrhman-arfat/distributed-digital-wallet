CREATE TYPE user_status AS ENUM (
    'ACTIVE',
    'PENDING_ACTIVATION',
    'BLOCKED',
    'SUSPENDED',
    'CLOSED',
    'DELETED'
);

CREATE TYPE activation_request_status AS ENUM (
    'PENDING',
    'APPROVED',
    'REJECTED'
);

CREATE TYPE idempotency_status AS ENUM (
    'IN_PROGRESS',
    'COMPLETED'
);

CREATE TYPE transaction_status AS ENUM (
    'SUCCESS',
    'PENDING',
    'FAILED',
    'CANCELLED'
);

CREATE TABLE users (
    id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    first_name VARCHAR(50) NOT NULL,
    last_name VARCHAR(50) NOT NULL,
    email VARCHAR(255) NOT NULL,
    phone VARCHAR(20) NOT NULL,
    country_code VARCHAR(10) NOT NULL,
    national_id VARCHAR(50) NULL,
    nationality VARCHAR(50) NULL,
    pin_hash VARCHAR(255),
    phone_verified_at TIMESTAMPTZ,
    status user_status NOT NULL DEFAULT 'PENDING_ACTIVATION',
    email_verified_at TIMESTAMPTZ,
    created_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    deleted_at TIMESTAMPTZ
);

CREATE UNIQUE INDEX uq_users_active_phone ON users (phone, country_code)
WHERE
    deleted_at IS NULL;

CREATE UNIQUE INDEX uq_users_active_email ON users (email)
WHERE
    deleted_at IS NULL;

CREATE UNIQUE INDEX uq_users_active_national_id ON users (national_id)
WHERE
    deleted_at IS NULL
    AND national_id IS NOT NULL;

CREATE TABLE users_activation_requests (
    id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    user_id BIGINT NOT NULL REFERENCES users (id) ON DELETE RESTRICT,
    status activation_request_status NOT NULL DEFAULT 'PENDING',
    handled_at TIMESTAMPTZ,
    handled_by BIGINT REFERENCES users (id) ON DELETE SET NULL,
    resolution TEXT, -- comment from the admin who handled this request
    created_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT chk_activation_handled CHECK (
        (
            status = 'PENDING'
            AND handled_at IS NULL
            AND resolution IS NULL
        )
        OR (
            status <> 'PENDING'
            AND handled_at IS NOT NULL
        )
    )
);

CREATE INDEX idx_users_activation_requests_user_created ON users_activation_requests (user_id, created_at DESC);

-- prevent two PENDING / APPROVED requests for the same user
CREATE UNIQUE INDEX uq_users_activation_requests_user_id ON users_activation_requests (user_id)
WHERE
    status = 'PENDING'
    OR status = 'APPROVED';

CREATE TABLE otp_codes (
    id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    phone VARCHAR(20) NOT NULL,
    code_hash VARCHAR(255) NOT NULL,
    is_used BOOLEAN NOT NULL DEFAULT FALSE,
    type VARCHAR(30) NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    expires_at TIMESTAMPTZ NOT NULL,
    attempt_count INTEGER NOT NULL DEFAULT 0,
    max_attempt_reached_at TIMESTAMPTZ,
    can_resend_at TIMESTAMPTZ NOT NULL,
    CONSTRAINT chk_otp_attempt_count CHECK (attempt_count >= 0),
    CONSTRAINT chk_otp_expiration CHECK (expires_at > created_at)
);

CREATE INDEX idx_otp_codes_phone_type_created
ON otp_codes (phone, type, created_at DESC)
WHERE is_used = FALSE;

CREATE TABLE fraud_actions (
    id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    user_id BIGINT NOT NULL REFERENCES users (id) ON DELETE RESTRICT,
    type VARCHAR(30) NOT NULL, -- login_limit_exceeded, transaction_limit_exceeded, password_reset_failed, suspicious_transaction
    score INT NOT NULL, -- if score >= 100 the user account is SUSPENDED directly
    is_calculated BOOLEAN NOT NULL DEFAULT FALSE, -- if FALSE, score is auto-calculated from details
    details JSONB NOT NULL DEFAULT '{}'::jsonb,
    action VARCHAR(30) NOT NULL, -- BLOCK, ALLOW, FLAG
    created_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    deleted_at TIMESTAMPTZ,
    handled_at TIMESTAMPTZ,
    handled_by BIGINT REFERENCES users (id) ON DELETE SET NULL,
    resolution TEXT, -- comment from the admin who handled this action
    CONSTRAINT chk_fraud_score CHECK (
        score >= 0
        AND score <= 100
    )
);

CREATE INDEX idx_fraud_actions_user_created ON fraud_actions (
    user_id,
    created_at DESC,
    is_calculated DESC
);

CREATE TABLE wallets (
    id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    user_id BIGINT NOT NULL REFERENCES users (id) ON DELETE RESTRICT,
    balance NUMERIC(19, 4) NOT NULL DEFAULT 0,
    locked_balance NUMERIC(19, 4) NOT NULL DEFAULT 0,
    currency VARCHAR(3) NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT chk_wallet_currency CHECK (
        currency = UPPER(currency)
        AND LENGTH(currency) = 3
    ),
    CONSTRAINT chk_wallet_balances CHECK (
        balance >= 0
        AND locked_balance >= 0
        AND locked_balance <= balance
    ),
    CONSTRAINT uq_wallet_user_currency UNIQUE (user_id, currency)
);

CREATE TABLE transactions (
    id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    initiated_by_user_id BIGINT REFERENCES users (id) ON DELETE RESTRICT,
    source_system VARCHAR(50) NOT NULL,
    amount NUMERIC(19, 4) NOT NULL CHECK (amount > 0),
    currency VARCHAR(3) NOT NULL,
    type VARCHAR(30) NOT NULL,
    status transaction_status NOT NULL DEFAULT 'PENDING',
    created_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    failure_reason VARCHAR(255) NULL,
    CONSTRAINT chk_transaction_currency CHECK (
        currency = UPPER(currency)
        AND LENGTH(currency) = 3
    )
);

CREATE INDEX idx_transactions_user_created ON transactions (
    initiated_by_user_id,
    created_at DESC,
    id DESC
);

CREATE TABLE wallet_ledger (
    id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    wallet_id BIGINT NOT NULL REFERENCES wallets (id) ON DELETE RESTRICT,
    transaction_id BIGINT NOT NULL REFERENCES transactions (id) ON DELETE RESTRICT,
    amount NUMERIC(19, 4) NOT NULL CHECK (amount <> 0),
    balance_after_transaction NUMERIC(19, 4) NOT NULL CHECK (
        balance_after_transaction >= 0
    ),
    created_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT uq_wallet_transaction UNIQUE (wallet_id, transaction_id)
);

CREATE INDEX idx_ledger_wallet_created ON wallet_ledger (
    wallet_id,
    created_at DESC,
    id DESC
);

CREATE INDEX idx_ledger_transaction ON wallet_ledger (transaction_id);

CREATE TABLE idempotency_keys (
    id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    user_id BIGINT REFERENCES users (id) ON DELETE RESTRICT, -- NULL on payment page (not authed yet)
    idempotency_key UUID NOT NULL,
    type VARCHAR(30) NOT NULL, -- WALLET_TRANSFER, PAYMENT_PAGE
    request_hash VARCHAR(64) NOT NULL,
    status idempotency_status NOT NULL DEFAULT 'IN_PROGRESS',
    reference_id VARCHAR(255),
    reference_type VARCHAR(255),
    created_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE UNIQUE INDEX uq_idempotency_scope
ON idempotency_keys (idempotency_key, user_id, type) NULLS NOT DISTINCT;

CREATE INDEX idx_idempotency_keys_created ON idempotency_keys (created_at DESC);

CREATE TABLE outbox_events (
    id UUID PRIMARY KEY,
    aggregate_type VARCHAR(50) NOT NULL,
    aggregate_id BIGINT NOT NULL,
    event_type VARCHAR(100) NOT NULL,
    payload JSONB NOT NULL,
    status VARCHAR(20) NOT NULL DEFAULT 'PENDING',
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    published_at TIMESTAMPTZ,
    attempts INT NOT NULL DEFAULT 0,
    next_retry_at TIMESTAMPTZ,
);

