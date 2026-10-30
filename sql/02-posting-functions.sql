
-- 02-posting-functions.sql

-- Shared helper for PURCHASE, SELL, TRADE, and ADJUSTMENT.
CREATE OR REPLACE FUNCTION post_inventory_transaction(
    p_transaction_id BIGINT,
    p_expected_type TEXT,
    p_allow_in BOOLEAN,
    p_allow_out BOOLEAN
)
RETURNS VOID
LANGUAGE plpgsql
AS $$
DECLARE
    v_type TEXT;
    v_status TEXT;
    v_line RECORD;
    v_quantity NUMERIC(14, 3);
    v_cost_basis NUMERIC(14, 2);
    v_cost_to_remove NUMERIC(14, 2);
BEGIN
    -- Lock the transaction header.
    SELECT transaction_type, status
    INTO v_type, v_status
    FROM transactions
    WHERE transaction_id = p_transaction_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Transaction % does not exist',
            p_transaction_id;
    END IF;

    IF v_type <> p_expected_type THEN
        RAISE EXCEPTION
            'Transaction % is %, expected %',
            p_transaction_id, v_type, p_expected_type;
    END IF;

    IF v_status <> 'DRAFT' THEN
        RAISE EXCEPTION 'Transaction % is not a draft',
            p_transaction_id;
    END IF;

    -- Require at least one line.
    IF NOT EXISTS (
        SELECT 1
        FROM transaction_lines
        WHERE transaction_id = p_transaction_id
    ) THEN
        RAISE EXCEPTION 'Transaction % has no lines',
            p_transaction_id;
    END IF;

    -- Validate allowed directions.
    IF EXISTS (
        SELECT 1
        FROM transaction_lines
        WHERE transaction_id = p_transaction_id
          AND (
              (direction = 'IN' AND NOT p_allow_in)
              OR
              (direction = 'OUT' AND NOT p_allow_out)
          )
    ) THEN
        RAISE EXCEPTION
            'Transaction % contains an invalid line direction',
            p_transaction_id;
    END IF;

    -- Avoid ambiguous same-product IN and OUT accounting
    -- within one transaction.
    IF EXISTS (
        SELECT 1
        FROM transaction_lines a
        JOIN transaction_lines b
          ON b.transaction_id = a.transaction_id
         AND b.product_id = a.product_id
         AND b.direction <> a.direction
        WHERE a.transaction_id = p_transaction_id
    ) THEN
        RAISE EXCEPTION
            'Transaction % cannot have both IN and OUT lines for the same product',
            p_transaction_id;
    END IF;

    -- Prevent duplicate inventory posting.
    IF EXISTS (
        SELECT 1
        FROM inventory_movements
        WHERE transaction_id = p_transaction_id
    ) THEN
        RAISE EXCEPTION
            'Transaction % already has inventory movements',
            p_transaction_id;
    END IF;

    -- Lock every affected product in a consistent order.
    -- All inventory-posting functions should follow this protocol.
    PERFORM p.product_id
    FROM products p
    JOIN transaction_lines tl
      ON tl.product_id = p.product_id
    WHERE tl.transaction_id = p_transaction_id
    ORDER BY p.product_id
    FOR UPDATE OF p;

    -- Process OUT lines first.
    -- Remove inventory at its current weighted-average cost.
    FOR v_line IN
        SELECT transaction_line_id, product_id, quantity
        FROM transaction_lines
        WHERE transaction_id = p_transaction_id
          AND direction = 'OUT'
        ORDER BY product_id
    LOOP
        SELECT
            COALESCE(SUM(quantity_delta), 0),
            COALESCE(SUM(cost_delta), 0)
        INTO v_quantity, v_cost_basis
        FROM inventory_movements
        WHERE product_id = v_line.product_id;

        IF v_quantity < v_line.quantity THEN
            RAISE EXCEPTION
                'Insufficient inventory for product %. Available: %, requested: %',
                v_line.product_id, v_quantity, v_line.quantity;
        END IF;

        -- v_quanrity is always > 0 so there is no zero division problem

        -- If selling/removing all remaining stock, remove the
        -- exact remaining basis to avoid rounding leftovers.
        IF v_line.quantity = v_quantity THEN
            v_cost_to_remove := v_cost_basis;
        ELSE
            v_cost_to_remove :=
                ROUND(v_cost_basis / v_quantity * v_line.quantity, 2);
        END IF;

        INSERT INTO inventory_movements (
            transaction_id,
            transaction_line_id,
            product_id,
            quantity_delta,
            cost_delta
        )
        VALUES (
            p_transaction_id,
            v_line.transaction_line_id,
            v_line.product_id,
            -v_line.quantity,
            -v_cost_to_remove
        );
    END LOOP;

    -- Process IN lines.
    -- Incoming items use the agreed unit value on the transaction line.
    FOR v_line IN
        SELECT transaction_line_id, product_id, quantity, unit_value
        FROM transaction_lines
        WHERE transaction_id = p_transaction_id
          AND direction = 'IN'
        ORDER BY product_id
    LOOP
        INSERT INTO inventory_movements (
            transaction_id,
            transaction_line_id,
            product_id,
            quantity_delta,
            cost_delta
        )
        VALUES (
            p_transaction_id,
            v_line.transaction_line_id,
            v_line.product_id,
            v_line.quantity,
            ROUND(v_line.quantity * v_line.unit_value, 2)
        );
    END LOOP;

    -- Mark the transaction posted only after all movements succeed.
    UPDATE transactions
    SET status = 'POSTED',
        posted_at = now()
    WHERE transaction_id = p_transaction_id;
END;
$$;

-- Copies a transaction's draft cash lines into the cash ledger.
-- Call only after the posting function has validated the lines.
CREATE OR REPLACE FUNCTION generate_cash_movements(p_transaction_id BIGINT)
RETURNS VOID
LANGUAGE plpgsql
AS $$
BEGIN
    INSERT INTO cash_movements (
        transaction_id,
        transaction_cash_line_id,
        cash_type,
        amount,
        currency,
        description
    )
    SELECT
        transaction_id,
        transaction_cash_line_id,
        cash_type,
        amount,
        currency,
        description
    FROM transaction_cash_lines
    WHERE transaction_id = p_transaction_id
    ORDER BY transaction_cash_line_id;
END;
$$;

-- Posting purchase function
-- Reads draft cash from transaction_cash_lines, writes the cash ledger,
-- then posts inventory (which also marks the transaction POSTED).
CREATE OR REPLACE FUNCTION post_purchase(p_transaction_id BIGINT)
RETURNS VOID
LANGUAGE plpgsql
AS $$
DECLARE
    v_type   TEXT;
    v_status TEXT;
BEGIN
    -- 1. Lock and validate the header.
    SELECT transaction_type, status
    INTO v_type, v_status
    FROM transactions
    WHERE transaction_id = p_transaction_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Transaction % does not exist',
            p_transaction_id;
    END IF;

    IF v_type <> 'BUY' OR v_status <> 'DRAFT' THEN
        RAISE EXCEPTION 'Transaction % must be a draft BUY',
            p_transaction_id;
    END IF;

    -- 2. A purchase must include at least one payment.
    IF NOT EXISTS (
        SELECT 1
        FROM transaction_cash_lines
        WHERE transaction_id = p_transaction_id
          AND cash_type = 'PURCHASE_PAYMENT'
    ) THEN
        RAISE EXCEPTION
            'Purchase % requires a PURCHASE_PAYMENT cash line',
            p_transaction_id;
    END IF;

    -- 3. Only payment, shipping and fee lines are allowed, and cash
    --    paid is always negative.
    IF EXISTS (
        SELECT 1
        FROM transaction_cash_lines
        WHERE transaction_id = p_transaction_id
          AND (cash_type NOT IN ('PURCHASE_PAYMENT', 'SHIPPING', 'FEE')
               OR amount >= 0)
    ) THEN
        RAISE EXCEPTION
            'Purchase % has an invalid cash line (wrong type or not negative)',
            p_transaction_id;
    END IF;

    -- 4. Generate the cash ledger rows from the draft cash lines.
    PERFORM generate_cash_movements(p_transaction_id);

    -- 5. Post inventory and mark the transaction POSTED.
    --    This is last, so the status changes only after everything
    --    else has succeeded.
    PERFORM post_inventory_transaction(
        p_transaction_id, 'BUY', TRUE, FALSE
    );
END;
$$;

-- Posting sale function
CREATE OR REPLACE FUNCTION post_sale(p_transaction_id BIGINT)
RETURNS VOID
LANGUAGE plpgsql
AS $$
DECLARE
    v_type   TEXT;
    v_status TEXT;
BEGIN
    -- 1. Lock and validate the header.
    SELECT transaction_type, status
    INTO v_type, v_status
    FROM transactions
    WHERE transaction_id = p_transaction_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Transaction % does not exist',
            p_transaction_id;
    END IF;

    IF v_type <> 'SELL' OR v_status <> 'DRAFT' THEN
        RAISE EXCEPTION 'Transaction % must be a draft SELL',
            p_transaction_id;
    END IF;

    -- 2. A sale must include at least one proceeds line, and proceeds
    --    are cash received (positive).
    IF NOT EXISTS (
        SELECT 1
        FROM transaction_cash_lines
        WHERE transaction_id = p_transaction_id
          AND cash_type = 'SALE_PROCEEDS'
    ) THEN
        RAISE EXCEPTION
            'Sale % requires a SALE_PROCEEDS cash line',
            p_transaction_id;
    END IF;

    -- 3. Only proceeds, shipping and fee lines are allowed.
    IF EXISTS (
        SELECT 1
        FROM transaction_cash_lines
        WHERE transaction_id = p_transaction_id
          AND cash_type NOT IN ('SALE_PROCEEDS', 'SHIPPING', 'FEE')
    ) THEN
        RAISE EXCEPTION
            'Sale % can only contain SALE_PROCEEDS, SHIPPING or FEE cash lines',
            p_transaction_id;
    END IF;

    -- 4. Signs: proceeds positive; shipping and fees (costs) negative.
    IF EXISTS (
        SELECT 1
        FROM transaction_cash_lines
        WHERE transaction_id = p_transaction_id
          AND (
              (cash_type = 'SALE_PROCEEDS' AND amount <= 0)
              OR (cash_type IN ('SHIPPING', 'FEE') AND amount >= 0)
          )
    ) THEN
        RAISE EXCEPTION
            'Sale % has a cash line with the wrong sign',
            p_transaction_id;
    END IF;

    -- 5. Generate the cash ledger rows from the draft cash lines.
    PERFORM generate_cash_movements(p_transaction_id);

    -- 6. Post inventory and mark the transaction POSTED (last).
    PERFORM post_inventory_transaction(
        p_transaction_id, 'SELL', FALSE, TRUE
    );
END;
$$;

-- Post trade function
-- Post trade function
CREATE OR REPLACE FUNCTION post_trade(p_transaction_id BIGINT)
RETURNS VOID
LANGUAGE plpgsql
AS $$
DECLARE
    v_type   TEXT;
    v_status TEXT;
BEGIN
    -- 1. Lock and validate the header.
    SELECT transaction_type, status
    INTO v_type, v_status
    FROM transactions
    WHERE transaction_id = p_transaction_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Transaction % does not exist',
            p_transaction_id;
    END IF;

    IF v_type <> 'TRADE' OR v_status <> 'DRAFT' THEN
        RAISE EXCEPTION 'Transaction % must be a draft TRADE',
            p_transaction_id;
    END IF;

    -- 2. Cash is optional for a trade. Allowed types only.
    IF EXISTS (
        SELECT 1
        FROM transaction_cash_lines
        WHERE transaction_id = p_transaction_id
          AND cash_type NOT IN ('TRADE_CASH', 'SHIPPING', 'FEE')
    ) THEN
        RAISE EXCEPTION
            'Trade % can only contain TRADE_CASH, SHIPPING or FEE cash lines',
            p_transaction_id;
    END IF;

    -- 3. TRADE_CASH may be either sign (received or paid).
    --    Shipping and fees are costs, so they must be negative.
    IF EXISTS (
        SELECT 1
        FROM transaction_cash_lines
        WHERE transaction_id = p_transaction_id
          AND cash_type IN ('SHIPPING', 'FEE')
          AND amount >= 0
    ) THEN
        RAISE EXCEPTION
            'Trade % has a SHIPPING or FEE line that is not negative',
            p_transaction_id;
    END IF;

    -- 4. Generate the cash ledger rows (none if there are no cash lines).
    -- INSERT INTO cash_movements (
    --     transaction_id,
    --     transaction_cash_line_id,
    --     cash_type,
    --     amount,
    --     currency,
    --     description
    -- )
    -- SELECT
    --     transaction_id,
    --     transaction_cash_line_id,
    --     cash_type,
    --     amount,
    --     currency,
    --     description
    -- FROM transaction_cash_lines
    -- WHERE transaction_id = p_transaction_id
    -- ORDER BY transaction_cash_line_id;

    -- 5. Generate the cash ledger rows from the draft cash lines.
    PERFORM generate_cash_movements(p_transaction_id);

    -- 6. Post inventory and mark the transaction POSTED (last).
    PERFORM post_inventory_transaction(
        p_transaction_id, 'TRADE', TRUE, TRUE
    );
END;
$$;

-- Posting adjustment function
-- Inventory-only changes (found, lost, pulled from a pack, count fix).
CREATE OR REPLACE FUNCTION post_adjustment(p_transaction_id BIGINT)
RETURNS VOID
LANGUAGE plpgsql
AS $$
DECLARE
    v_type   TEXT;
    v_status TEXT;
    v_notes  TEXT;
BEGIN
    -- 1. Lock and validate the header.
    SELECT transaction_type, status, notes
    INTO v_type, v_status, v_notes
    FROM transactions
    WHERE transaction_id = p_transaction_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Transaction % does not exist',
            p_transaction_id;
    END IF;

    IF v_type <> 'ADJUSTMENT' OR v_status <> 'DRAFT' THEN
        RAISE EXCEPTION 'Transaction % must be a draft ADJUSTMENT',
            p_transaction_id;
    END IF;

    -- 2. A reason is required, so every adjustment can be explained later.
    IF v_notes IS NULL OR btrim(v_notes) = '' THEN
        RAISE EXCEPTION 'Adjustment % requires a reason in notes',
            p_transaction_id;
    END IF;

    -- 3. Adjustments are inventory only: no cash lines.
    IF EXISTS (
        SELECT 1
        FROM transaction_cash_lines
        WHERE transaction_id = p_transaction_id
    ) THEN
        RAISE EXCEPTION 'Adjustment % must not contain cash lines',
            p_transaction_id;
    END IF;

    -- 4. Post inventory and mark the transaction POSTED.
    PERFORM post_inventory_transaction(
        p_transaction_id, 'ADJUSTMENT', TRUE, TRUE
    );
END;
$$;

-- Posting expense function
CREATE OR REPLACE FUNCTION post_expense(p_transaction_id BIGINT)
RETURNS VOID
LANGUAGE plpgsql
AS $$
DECLARE
    v_type   TEXT;
    v_status TEXT;
BEGIN
    -- 1. Lock and validate the header.
    SELECT transaction_type, status
    INTO v_type, v_status
    FROM transactions
    WHERE transaction_id = p_transaction_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Transaction % does not exist',
            p_transaction_id;
    END IF;

    IF v_type <> 'EXPENSE' OR v_status <> 'DRAFT' THEN
        RAISE EXCEPTION 'Transaction % must be a draft EXPENSE',
            p_transaction_id;
    END IF;

    -- 2. An expense is cash only: no product lines.
    IF EXISTS (
        SELECT 1
        FROM transaction_lines
        WHERE transaction_id = p_transaction_id
    ) THEN
        RAISE EXCEPTION 'Expense % must not contain product lines',
            p_transaction_id;
    END IF;

    -- 3. At least one cash line.
    IF NOT EXISTS (
        SELECT 1
        FROM transaction_cash_lines
        WHERE transaction_id = p_transaction_id
    ) THEN
        RAISE EXCEPTION 'Expense % must have at least one cash line',
            p_transaction_id;
    END IF;

    -- 4. Allowed types, and all amounts negative (money paid).
    IF EXISTS (
        SELECT 1
        FROM transaction_cash_lines
        WHERE transaction_id = p_transaction_id
          AND (cash_type NOT IN ('FEE', 'SHIPPING', 'OTHER')
               OR amount >= 0)
    ) THEN
        RAISE EXCEPTION 'Expense % has an invalid cash line',
            p_transaction_id;
    END IF;

    -- 5. Generate the cash ledger rows.
    PERFORM generate_cash_movements(p_transaction_id);

    -- 6. Mark posted (last, after everything else succeeded).
    UPDATE transactions
    SET status = 'POSTED',
        posted_at = now()
    WHERE transaction_id = p_transaction_id;
END;
$$;

-- Posting reversal function
-- Creates a REVERSAL transaction that exactly undoes a posted transaction.
-- Rule: reversals must go newest-first. A transaction cannot be reversed
-- if any later, still-active inventory movement exists for the same product.
-- Reversing a transaction requires reversing all the later transactions for the same product first
CREATE OR REPLACE FUNCTION post_reversal(
    p_original_transaction_id BIGINT
)
RETURNS BIGINT
LANGUAGE plpgsql
AS $$
DECLARE
    v_original         transactions%ROWTYPE;
    v_reversal_id      BIGINT;
    v_blocking_product BIGINT;
BEGIN
    -- 1. Lock and validate the original transaction.
    SELECT *
    INTO v_original
    FROM transactions
    WHERE transaction_id = p_original_transaction_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Transaction % does not exist',
            p_original_transaction_id;
    END IF;

    IF v_original.status <> 'POSTED' THEN
        RAISE EXCEPTION 'Transaction % is not posted',
            p_original_transaction_id;
    END IF;

    IF v_original.transaction_type = 'REVERSAL' THEN
        RAISE EXCEPTION 'A reversal transaction cannot itself be reversed';
    END IF;

    IF EXISTS (
        SELECT 1
        FROM transactions
        WHERE reversal_of_transaction_id = p_original_transaction_id
    ) THEN
        RAISE EXCEPTION 'Transaction % has already been reversed',
            p_original_transaction_id;
    END IF;

    -- 2. Lock the affected products in a consistent order.
    PERFORM p.product_id
    FROM products p
    JOIN (
        SELECT DISTINCT product_id
        FROM inventory_movements
        WHERE transaction_id = p_original_transaction_id
    ) m ON m.product_id = p.product_id
    ORDER BY p.product_id
    FOR UPDATE OF p;

    -- 3. Newest-first rule.
    --    A later movement blocks the reversal unless it has been cancelled:
    --    reversal movements and the movements they reversed are ignored.
    SELECT orig.product_id
    INTO v_blocking_product
    FROM (
        SELECT product_id,
               MAX(inventory_movement_id) AS last_movement_id
        FROM inventory_movements
        WHERE transaction_id = p_original_transaction_id
        GROUP BY product_id
    ) orig
    JOIN inventory_movements later
      ON later.product_id = orig.product_id
     AND later.inventory_movement_id > orig.last_movement_id
    WHERE later.reversal_of_movement_id IS NULL
      AND NOT EXISTS (
          SELECT 1
          FROM inventory_movements r
          WHERE r.reversal_of_movement_id = later.inventory_movement_id
      )
    LIMIT 1;

    IF FOUND THEN
        RAISE EXCEPTION
            'Cannot reverse transaction %: product % has later inventory activity. Reverse newer transactions first.',
            p_original_transaction_id, v_blocking_product;
    END IF;

    -- 4. Create the reversal header.
    INSERT INTO transactions (
        transaction_type,
        transaction_date,
        counterparty,
        notes,
        reversal_of_transaction_id
    )
    VALUES (
        'REVERSAL',
        CURRENT_DATE,
        v_original.counterparty,
        'Reversal of transaction ' || p_original_transaction_id,
        p_original_transaction_id
    )
    RETURNING transaction_id INTO v_reversal_id;

    -- 5. Reverse inventory quantity and cost basis exactly.
    INSERT INTO inventory_movements (
        transaction_id,
        transaction_line_id,
        product_id,
        quantity_delta,
        cost_delta,
        reversal_of_movement_id
    )
    SELECT
        v_reversal_id,
        NULL,
        product_id,
        -quantity_delta,
        -cost_delta,
        inventory_movement_id
    FROM inventory_movements
    WHERE transaction_id = p_original_transaction_id
    ORDER BY inventory_movement_id;

    -- 6. Reverse cash exactly. Cash is a simple signed total, so order
    --    does not matter and no newest-first rule is needed here.
    INSERT INTO cash_movements (
        transaction_id,
        cash_type,
        amount,
        currency,
        description,
        reversal_of_cash_movement_id
    )
    SELECT
        v_reversal_id,
        cash_type,
        -amount,
        currency,
        'Reversal of cash movement ' || cash_movement_id,
        cash_movement_id
    FROM cash_movements
    WHERE transaction_id = p_original_transaction_id
    ORDER BY cash_movement_id;

    -- 7. Mark the reversal posted (last).
    UPDATE transactions
    SET status = 'POSTED',
        posted_at = now()
    WHERE transaction_id = v_reversal_id;

    RETURN v_reversal_id;
END;
$$;
