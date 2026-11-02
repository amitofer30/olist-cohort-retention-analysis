-- 7. Cohort month — first purchase month per customer, then cohort size
-- -----------------------------------------------------------------------------
-- What a CTE is:
-- A CTE (WITH name AS (query)) is a temporary named result that exists only for
-- this statement. Here we stack two: clean_orders (one row per valid order), then
-- customer_cohorts (one row per person). MySQL 8.0 allows this chain.
--
-- What MIN() does here:
-- Each person can have several orders. MIN(order_purchase_timestamp) keeps the
-- earliest purchase datetime for that customer_unique_id. That timestamp is the
-- customer's "zero point": month 0 of their life in the shop. Later we can count
-- how many months after that they bought again (retention).
--
-- Why each customer needs a zero point:
-- If we only look at calendar months (Jan, Feb, ...), a January first-timer and
-- a March first-timer are mixed together in "April orders". The cohort month
-- lines everyone up on their own start so we can compare like with like:
-- "share of January customers who still bought in month 3" vs February's cohort.
--
-- MySQL has no DATE_TRUNC(..., 'month'). Turn a datetime into the 1st of that
-- month with DATE_FORMAT, then CAST to DATE:
--   CAST(DATE_FORMAT(dt, '%Y-%m-01') AS DATE)
-- Example: 2018-03-15 14:22:00  →  2018-03-01
-- (Other valid tricks: DATE(dt) - INTERVAL (DAY(dt) - 1) DAY)
--
-- Example input — 5 fictional customers in clean_orders:
--   customer_unique_id | order_id | order_purchase_timestamp
--   Ana                | o1       | 2018-01-05 09:00:00
--   Ana                | o2       | 2018-03-12 11:00:00   <-- later; MIN ignores this
--   Ben                | o3       | 2018-01-20 16:00:00
--   Cam                | o4       | 2018-02-01 10:00:00
--   Dan                | o5       | 2018-02-28 08:00:00
--   Eve                | o6       | 2018-03-15 19:00:00
--
-- After MIN + month start (one row per person):
--   customer_unique_id | cohort_month
--   Ana                | 2018-01-01
--   Ben                | 2018-01-01
--   Cam                | 2018-02-01
--   Dan                | 2018-02-01
--   Eve                | 2018-03-01
--
-- Customers per cohort:
--   cohort_month | customers_in_cohort
--   2018-01-01   | 2
--   2018-02-01   | 2
--   2018-03-01   | 1

-- 7a. First purchase month for each customer
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
),
customer_cohorts AS (
    SELECT
        customer_unique_id,
        CAST(DATE_FORMAT(MIN(order_purchase_timestamp), '%Y-%m-01') AS DATE) AS cohort_month
    FROM clean_orders
    GROUP BY customer_unique_id
)
SELECT
    customer_unique_id,
    cohort_month
FROM customer_cohorts
ORDER BY cohort_month, customer_unique_id;

-- 7b. How many customers are in each cohort
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
),
customer_cohorts AS (
    SELECT
        customer_unique_id,
        CAST(DATE_FORMAT(MIN(order_purchase_timestamp), '%Y-%m-01') AS DATE) AS cohort_month
    FROM clean_orders
    GROUP BY customer_unique_id
)
SELECT
    cohort_month,
    COUNT(*) AS customers_in_cohort
FROM customer_cohorts
GROUP BY cohort_month
ORDER BY cohort_month;

-------------------------------------------------------------------------------------------------
 -- 8. Retention matrix — active customers by month offset
-- -----------------------------------------------------------------------------
-- What this query does:
-- Calculates the percentage of customers from each cohort who returned to make 
-- another purchase in the months following their first purchase[cite: 1].
--
-- Why we use a LEFT JOIN:
-- The JOIN to the clean_orders table is a LEFT JOIN to ensure that a cohort 
-- is not dropped from the final results if 0 customers returned in a specific month. 
-- An INNER JOIN would completely remove months with no repeat purchases.
--
-- What month_offset is:
-- The numerical distance (in months) between the customer's first purchase month 
-- (cohort_month) and any subsequent purchase. It is calculated using TIMESTAMPDIFF 
-- on dates truncated to the first day of the month.
--
-- Why retention in month 0 is always 100%:
-- Month 0 represents the first purchase that assigned the customer to that specific cohort[cite: 1]. 
-- By definition, every customer in the cohort made a purchase in this month, so the 
-- count of active customers in month 0 always equals the original cohort size.
--
-- Note on Olist data (objective reality):
-- As reflected in the EDA, out of ~99k customers, only 2,997 bought more than once[cite: 2]. 
-- Therefore, retention rates in subsequent months (month_offset > 0) are expected 
-- to be near 0%. This indicates the platform functions primarily for one-off 
-- purchases rather than generating recurring shopping behavior.
--
-- Example input — 4 fictional rows in clean_orders:
--   customer_unique_id | order_purchase_timestamp
--   Ana                | 2018-01-15 09:00:00  <-- cohort: 2018-01-01
--   Ana                | 2018-02-10 11:00:00  <-- month_offset: 1
--   Ben                | 2018-01-20 16:00:00  <-- cohort: 2018-01-01
--   Cam                | 2018-02-05 10:00:00  <-- cohort: 2018-02-01
--
-- Example output after calculation:
--   cohort_month | cohort_size | month_offset | active_customers | retention_percentage
--   2018-01-01   | 2           | 0            | 2                | 100.00
--   2018-01-01   | 2           | 1            | 1                | 50.00
--   2018-02-01   | 1           | 0            | 1                | 100.00

WITH clean_orders AS (
    -- 8a. Filter for valid orders only (excluding canceled or unavailable) and get revenue[cite: 1]
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
),
customer_cohorts AS (
    -- 8b. Find the first purchase month (Month 0) for each customer[cite: 1]
    SELECT
        customer_unique_id,
        CAST(DATE_FORMAT(MIN(order_purchase_timestamp), '%Y-%m-01') AS DATE) AS cohort_month
    FROM clean_orders
    GROUP BY customer_unique_id
),
cohort_sizes AS (
    -- 8c. Count the total number of unique customers in each cohort
    SELECT
        cohort_month,
        COUNT(DISTINCT customer_unique_id) AS cohort_size
    FROM customer_cohorts
    GROUP BY cohort_month
)
SELECT
    cc.cohort_month,
    cs.cohort_size,
    TIMESTAMPDIFF(MONTH, cc.cohort_month, CAST(DATE_FORMAT(co.order_purchase_timestamp, '%Y-%m-01') AS DATE)) AS month_offset,
    COUNT(DISTINCT co.customer_unique_id) AS active_customers,
    ROUND((COUNT(DISTINCT co.customer_unique_id) / cs.cohort_size) * 100, 2) AS retention_percentage
FROM customer_cohorts AS cc
LEFT JOIN clean_orders AS co
    ON cc.customer_unique_id = co.customer_unique_id
INNER JOIN cohort_sizes AS cs
    ON cc.cohort_month = cs.cohort_month
GROUP BY
    cc.cohort_month,
    cs.cohort_size,
    month_offset
ORDER BY
    cc.cohort_month,
    month_offset;

