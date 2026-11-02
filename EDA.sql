USE olist_ecommerce;

-- =============================================================================
-- Data quality checks for Olist
-- Run each query, copy the results, and send them so we can tell if there are problems.
-- =============================================================================


-- -----------------------------------------------------------------------------
-- 1. How many rows are in each table?  (COUNT(*) )
-- -----------------------------------------------------------------------------
-- What this does:
-- COUNT(*) counts how many rows (records) are in the table. Like asking "how many rows are in Excel?"
--
-- Why this matters:
-- If a table is empty (0) — the load probably failed.
-- If the number is much smaller than expected (Olist has about 100k orders)
-- — only part of the file may have been loaded.
--
-- Example input (orders table — 4 sample rows):
--   order_id | customer_id | order_status
--   o1       | c1          | delivered
--   o2       | c2          | shipped
--   o3       | c3          | delivered
--   o4       | c4          | canceled
--
-- Example output:
--   table_name | row_count
--   orders     | 4

SELECT 'orders' AS table_name, COUNT(*) AS row_count FROM orders
UNION ALL
SELECT 'customers', COUNT(*) FROM customers
UNION ALL
SELECT 'order_items', COUNT(*) FROM order_items
UNION ALL
SELECT 'order_payments', COUNT(*) FROM order_payments
UNION ALL
SELECT 'order_reviews', COUNT(*) FROM order_reviews
UNION ALL
SELECT 'products', COUNT(*) FROM products
UNION ALL
SELECT 'sellers', COUNT(*) FROM sellers
UNION ALL
SELECT 'geolocation', COUNT(*) FROM geolocation
UNION ALL
SELECT 'product_category_name_translation', COUNT(*) FROM product_category_name_translation;
/* output
'orders', '99441' -  same as the info in kaggle
'customers', '99441' -  same as the info in kaggle
'order_items', '112650' - same as csv file
'order_payments', '103886' - same as csv file
'order_reviews', '99223' - same as csv file
'products', '32951' - same as kaggle info
'sellers', '3095' - same as kaggle info
'geolocation', '3000489' - same as csv file
'product_category_name_translation', '71' - same as kaggle info
*/
-- when there is a table that has less rows than the info in kaggle, it means that there is a problem with the data
-- i check against the csv file when there is a table with two PM
-- -----------------------------------------------------------------------------
-- 2. Purchase date range  (MIN / MAX on order_purchase_timestamp)
-- -----------------------------------------------------------------------------
-- What this does:
-- MIN finds the earliest purchase timestamp.
-- MAX finds the latest purchase timestamp.
--
-- Why this matters:
-- Olist orders should fall in a known period (about 2016–2018).
-- Dates far outside that range, or NULL as first/last, often mean a load or type issue.

SELECT
    MIN(order_purchase_timestamp) AS first_purchase,
    MAX(order_purchase_timestamp) AS last_purchase
FROM orders;


-- -----------------------------------------------------------------------------
-- 3. order_status distribution  (how many orders in each status)
-- -----------------------------------------------------------------------------
-- What this does:
-- GROUP BY clusters rows that share the same value.
-- COUNT(*) counts how many orders there are in each status.
-- ORDER BY sorts from the most common status to the rarest.
--
-- Why this matters:
-- Most Olist orders should be delivered.
-- If almost everything is canceled / unavailable, or there are odd values
-- (whitespace, NULL, broken text) — there is likely a load issue or incomplete data.
--
-- Example input:
--   order_id | order_status
--   o1       | delivered
--   o2       | delivered
--   o3       | shipped
--   o4       | canceled
--
-- Example output:
--   order_status | orders_count
--   delivered    | 2
--   shipped      | 1
--   canceled     | 1

SELECT
    order_status,
    COUNT(*) AS orders_count
FROM orders
GROUP BY order_status
ORDER BY orders_count DESC;
/* output
delivered	96478
shipped	1107
canceled	625
unavailable	609
invoiced	314
processing	301
created	5
approved	2
*/ -- output is valid
-- -----------------------------------------------------------------------------
-- 4. Customers: customer_id vs customer_unique_id, and returning customers
-- -----------------------------------------------------------------------------
-- Important difference in Olist:
--   customer_id         = id for a single order (almost always one row in customers per order).
--   customer_unique_id  = the person. The same person can appear under several customer_id values if they bought more than once.
--
-- 4a. How many distinct ids of each type
-- COUNT(DISTINCT ...) counts unique values (no duplicates).
-- If distinct customer_id is larger than distinct customer_unique_id — that is expected: some customers returned.
--

SELECT
    COUNT(DISTINCT customer_id) AS distinct_customer_id,
    COUNT(DISTINCT customer_unique_id) AS distinct_customer_unique_id
FROM customers;


-- 4b. How many people bought more than once
-- For each customer_unique_id, count how many customer_id values they have.
-- HAVING COUNT(*) > 1 keeps only those with more than one row = more than one purchase.

SELECT COUNT(*) AS customers_who_bought_more_than_once
FROM (
    SELECT customer_unique_id
    FROM customers
    GROUP BY customer_unique_id
    HAVING COUNT(*) > 1
) AS repeat_customers;
-- output : 2997

-- -----------------------------------------------------------------------------
-- 5. How many NULL values are in the date columns of orders
-- -----------------------------------------------------------------------------
   
-- Why this matters (and is not always a bug):
--   order_purchase_timestamp         — almost never should be NULL.
--   order_approved_at                — can be NULL if the order was not approved.
--   order_delivered_carrier_date     — NULL if it has not gone to the carrier yet / was canceled.
--   order_delivered_customer_date    — NULL if it has not reached the customer yet / was canceled.
--   order_estimated_delivery_date    — usually filled; NULL here is more suspicious.
--
-- Example input:
--   order_id | purchase            | approved            | carrier | delivered | estimated
--   o1       | 2018-01-01 10:00:00 | 2018-01-01 11:00:00 | NULL    | NULL      | 2018-01-10
--   o2       | 2018-01-02 10:00:00 | NULL                | NULL    | NULL      | 2018-01-12
--
-- Example output:
--   null_purchase | null_approved | null_carrier | null_delivered | null_estimated
--   0             | 1             | 2            | 2              | 0

SELECT
    SUM(order_purchase_timestamp IS NULL)        AS null_purchase,
    SUM(order_approved_at IS NULL)               AS null_approved,
    SUM(order_delivered_carrier_date IS NULL)    AS null_carrier,
    SUM(order_delivered_customer_date IS NULL)   AS null_delivered,
    SUM(order_estimated_delivery_date IS NULL)   AS null_estimated
FROM orders;
 

/* output :
# null_purchase, null_approved, null_carrier, null_delivered, null_estimated
'0', '160', '1783', '2965', '0'
  
 null_purchase = 0 and null_estimated = 0: Every order has a purchase date (the moment it was placed) and an estimated delivery date (set at checkout), so no NULLs here is correct and expected.
null_approved, null_carrier, null_delivered greater than 0: These dates only exist once an order reaches that stage. Canceled orders may never get approved, and orders still in transit have no carrier or delivery date yet, so some NULLs are normal.
therefore our output is pretty expected */ 


-- -----------------------------------------------------------------------------
    -- 6. CTE clean_orders — one row per valid order, with revenue
      -- Example input:
    --   orders
    --     order_id | customer_id | order_status | order_purchase_timestamp
    --     o1       | c1          | delivered    | 2018-01-01 10:00:00
    --     o2       | c2          | canceled     | 2018-01-02 10:00:00
    --     o3       | c3          | shipped      | 2018-01-03 10:00:00
    --
    --   customers
    --     customer_id | customer_unique_id
    --     c1          | person_A
    --     c2          | person_B
    --     c3          | person_A
    --
    --   order_payments
    --     order_id | payment_sequential | payment_value
    --     o1       | 1                  | 50.00
    --     o1       | 2                  | 20.00     <-- two payments on the same order
    --     o2       | 1                  | 80.00
    --     o3       | 1                  | 30.00
    --
    -- Example output of the CTE (o2 dropped because canceled):
    --   customer_unique_id | order_id | order_purchase_timestamp | order_status | order_revenue
    --   person_A           | o1       | 2018-01-01 10:00:00      | delivered    | 70.00
    --   person_A           | o3       | 2018-01-03 10:00:00      | shipped      | 30.00
    --
    -- If we did NOT aggregate payments (join order_payments directly):
    --   person_A | o1 | ... | delivered | 50.00
    --   person_A | o1 | ... | delivered | 20.00   <-- o1 appears twice; 70 becomes two rows
    --   person_A | o3 | ... | shipped   | 30.00
    -- Then COUNT(*) would say 3 orders instead of 2. Any later join without grouping
    -- would double-count o1.
    --

    -- 6a. Row count — should be one row per remaining order
    WITH clean_orders AS (
        SELECT
            c.customer_unique_id,
            o.order_id,
            o.order_purchase_timestamp,
            o.order_status,
            COALESCE(p.order_revenue, 0) AS order_revenue -- replace the NULL with zero
        FROM orders AS o
        INNER JOIN customers AS c
            ON o.customer_id = c.customer_id
        LEFT JOIN (
            SELECT
                order_id,
                SUM(payment_value) AS order_revenue
            FROM order_payments
            GROUP BY order_id
        ) AS p
            ON o.order_id = p.order_id
        WHERE o.order_status NOT IN ('canceled', 'unavailable')
    )
    SELECT COUNT(*) AS clean_order_count
    FROM clean_orders;

    /*output :  98207 orders are left after the cleaning 
    overall orders is 99441 so 1234 orders are removed and that is valid. */
    -- 6b. Preview a few rows
    WITH clean_orders AS (
        SELECT
            c.customer_unique_id,
            o.order_id,
            o.order_purchase_timestamp,
            o.order_status,
            COALESCE(p.order_revenue, 0) AS order_revenue
        FROM orders AS o
        INNER JOIN customers AS c
            ON o.customer_id = c.customer_id
        LEFT JOIN (
            SELECT
                order_id,
                SUM(payment_value) AS order_revenue
            FROM order_payments
            GROUP BY order_id
        ) AS p
            ON o.order_id = p.order_id
        WHERE o.order_status NOT IN ('canceled', 'unavailable')
    )
    SELECT *
    FROM clean_orders
    LIMIT 10;
/* i will use the clean_orders CTE at the top of each later query */

-- -----------------------------------------------------------------------------
