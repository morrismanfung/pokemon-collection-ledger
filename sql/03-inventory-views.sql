
-- 03_inventory_views.sql

CREATE VIEW inventory_summary AS
SELECT
    p.product_id,
    p.product_type,
    p.name,
    p.set_name,
    p.variant,
    p.condition_grade,
    COALESCE(SUM(m.quantity_delta), 0) AS quantity_owned,
    COALESCE(SUM(m.cost_delta), 0)::NUMERIC(14, 2)
        AS remaining_cost_basis,
    CASE
        WHEN COALESCE(SUM(m.quantity_delta), 0) = 0
            THEN NULL
        ELSE ROUND(
            COALESCE(SUM(m.cost_delta), 0)
            / SUM(m.quantity_delta),
            4
        )
    END AS average_unit_cost
FROM products p
LEFT JOIN inventory_movements m
    ON m.product_id = p.product_id
GROUP BY
    p.product_id,
    p.product_type,
    p.name,
    p.set_name,
    p.variant,
    p.condition_grade;
