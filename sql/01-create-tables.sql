-- Table products
CREATE TABLE products (
    product_id      BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    product_type    TEXT NOT NULL
                    CHECK (product_type IN ('SINGLE', 'SEALED')),
    name            TEXT NOT NULL,
    set_name        TEXT NOT NULL DEFAULT '',
    variant         TEXT NOT NULL DEFAULT '',
    condition_grade TEXT NOT NULL DEFAULT 'N/A',
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),

    -- Distinguishes, for example, a Near Mint single from a lightly Played copy of the same card.
    CONSTRAINT uq_product_identity
        UNIQUE (product_type, name, set_name, variant, condition_grade)
);

-- Table transactions
CREATE TABLE transactions (
    transaction_id  BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    transaction_type TEXT NOT NULL
        CHECK (transaction_type IN
               ('BUY', 'SELL', 'TRADE', 'EXPENSE',
                'ADJUSTMENT', 'REVERSAL')),
    transaction_date DATE NOT NULL,
    counterparty    TEXT,
    notes           TEXT,
    status          TEXT NOT NULL DEFAULT 'DRAFT'
                    CHECK (status IN ('DRAFT', 'POSTED')),
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    posted_at       TIMESTAMPTZ,

    -- A reversal references the original posted transaction.
    reversal_of_transaction_id BIGINT UNIQUE
        REFERENCES transactions(transaction_id),

    CONSTRAINT ck_reversal_type CHECK (
        (transaction_type = 'REVERSAL'
            AND reversal_of_transaction_id IS NOT NULL)
        OR
        (transaction_type <> 'REVERSAL'
            AND reversal_of_transaction_id IS NULL)
    ),
    CONSTRAINT ck_posted_timestamp CHECK (
        (status = 'POSTED' AND posted_at IS NOT NULL)
        OR
        (status = 'DRAFT' AND posted_at IS NULL)
    )
);

-- Table transaction_lines
CREATE TABLE transaction_lines (
    transaction_line_id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    transaction_id      BIGINT NOT NULL
        REFERENCES transactions(transaction_id),
    product_id          BIGINT NOT NULL
        REFERENCES products(product_id),
    direction           TEXT NOT NULL
        CHECK (direction IN ('IN', 'OUT')),
    quantity            NUMERIC(14, 3) NOT NULL
        CHECK (quantity > 0),
    unit_value          NUMERIC(14, 2) NOT NULL
        CHECK (unit_value >= 0),
    notes               TEXT,

    -- One aggregated line per product and direction per transaction.
    CONSTRAINT uq_transaction_product_direction
        UNIQUE (transaction_id, product_id, direction)
);

-- Table transaction_cash_lines
-- Draft cash details entered before posting.
-- Posting functions validate these and copy them into cash_movements.
CREATE TABLE transaction_cash_lines (
    transaction_cash_line_id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    transaction_id           BIGINT NOT NULL
        REFERENCES transactions(transaction_id),
    cash_type                TEXT NOT NULL
        CHECK (cash_type IN
               ('PURCHASE_PAYMENT', 'SALE_PROCEEDS', 'TRADE_CASH',
                'FEE', 'SHIPPING', 'OTHER')),
    amount                   NUMERIC(14, 2) NOT NULL
        CHECK (amount <> 0),
    currency                 CHAR(3) NOT NULL DEFAULT 'CAD',
    description              TEXT
);

CREATE INDEX idx_transaction_cash_lines_transaction_id
    ON transaction_cash_lines (transaction_id);

-- Table inventory_movements
CREATE TABLE inventory_movements (
    inventory_movement_id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    transaction_id        BIGINT NOT NULL
        REFERENCES transactions(transaction_id),
    transaction_line_id   BIGINT
        REFERENCES transaction_lines(transaction_line_id),
    product_id            BIGINT NOT NULL
        REFERENCES products(product_id),
    quantity_delta         NUMERIC(14, 3) NOT NULL
        CHECK (quantity_delta <> 0),
    cost_delta             NUMERIC(14, 2) NOT NULL,
    reversal_of_movement_id BIGINT UNIQUE
        REFERENCES inventory_movements(inventory_movement_id),
    created_at             TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX idx_inventory_movements_product
    ON inventory_movements (product_id);

CREATE TABLE cash_movements (
    cash_movement_id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    transaction_id  BIGINT NOT NULL
        REFERENCES transactions(transaction_id),
    transaction_cash_line_id BIGINT UNIQUE
        REFERENCES transaction_cash_lines(transaction_cash_line_id),
    cash_type        TEXT NOT NULL
        CHECK (cash_type IN
               ('PURCHASE_PAYMENT', 'SALE_PROCEEDS', 'TRADE_CASH',
                'FEE', 'SHIPPING', 'OTHER')),
    amount           NUMERIC(14, 2) NOT NULL
        CHECK (amount <> 0),
    currency         CHAR(3) NOT NULL DEFAULT 'CAD',
    description      TEXT,
    reversal_of_cash_movement_id BIGINT UNIQUE
        REFERENCES cash_movements(cash_movement_id),
    created_at       TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX idx_cash_movements_transaction_id
    ON cash_movements (transaction_id);