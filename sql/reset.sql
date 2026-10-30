-- sql/reset.sql
-- DEVELOPMENT ONLY. Destroys all data in collectibles_ledger.
-- Run, then 01, 02, 03 in order to rebuild.

DROP VIEW IF EXISTS inventory_summary;

DROP TABLE IF EXISTS cash_movements       CASCADE;
DROP TABLE IF EXISTS inventory_movements  CASCADE;
DROP TABLE IF EXISTS transaction_cash_lines CASCADE;
DROP TABLE IF EXISTS transaction_lines    CASCADE;
DROP TABLE IF EXISTS transactions         CASCADE;
DROP TABLE IF EXISTS products             CASCADE;

DROP FUNCTION IF EXISTS post_reversal(BIGINT);
DROP FUNCTION IF EXISTS post_expense(BIGINT);
DROP FUNCTION IF EXISTS post_adjustment(BIGINT);
DROP FUNCTION IF EXISTS post_trade(BIGINT);
DROP FUNCTION IF EXISTS post_sale(BIGINT);
DROP FUNCTION IF EXISTS post_purchase(BIGINT);
DROP FUNCTION IF EXISTS post_inventory_transaction(BIGINT, TEXT, BOOLEAN, BOOLEAN);
DROP FUNCTION IF EXISTS generate_cash_movements(BIGINT)