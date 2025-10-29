-- ============================================================================
-- PostgreSQL Demo Database Initialization Script
-- ============================================================================
-- This script creates sample tables and data for the Snowflake tunnel demo
-- Can be run with: pixi run psql -d test_db < demo-data/init_postgres.sql
-- ============================================================================

-- Create users table
CREATE TABLE IF NOT EXISTS users (
    id SERIAL PRIMARY KEY,
    name VARCHAR(100) NOT NULL,
    email VARCHAR(100) UNIQUE NOT NULL,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

-- Create orders table
CREATE TABLE IF NOT EXISTS orders (
    id SERIAL PRIMARY KEY,
    user_id INTEGER REFERENCES users(id),
    product_name VARCHAR(200) NOT NULL,
    quantity INTEGER NOT NULL,
    total_amount DECIMAL(10,2) NOT NULL,
    order_date TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

-- Insert sample users (with ON CONFLICT for rerunning the script)
INSERT INTO users (name, email) VALUES
    ('John Doe', 'john.doe@example.com'),
    ('Jane Smith', 'jane.smith@example.com'),
    ('Bob Johnson', 'bob.johnson@example.com'),
    ('Alice Williams', 'alice.williams@example.com'),
    ('Charlie Brown', 'charlie.brown@example.com'),
    ('Diana Prince', 'diana.prince@example.com'),
    ('Eve Anderson', 'eve.anderson@example.com'),
    ('Frank Miller', 'frank.miller@example.com'),
    ('Grace Lee', 'grace.lee@example.com'),
    ('Henry Taylor', 'henry.taylor@example.com')
ON CONFLICT (email) DO NOTHING;

-- Insert sample orders
INSERT INTO orders (user_id, product_name, quantity, total_amount)
SELECT 1, 'Laptop Computer', 1, 1299.99
WHERE NOT EXISTS (SELECT 1 FROM orders WHERE user_id = 1 AND product_name = 'Laptop Computer')
UNION ALL
SELECT 1, 'Wireless Mouse', 2, 49.98
WHERE NOT EXISTS (SELECT 1 FROM orders WHERE user_id = 1 AND product_name = 'Wireless Mouse')
UNION ALL
SELECT 2, 'Office Chair', 1, 399.00
WHERE NOT EXISTS (SELECT 1 FROM orders WHERE user_id = 2 AND product_name = 'Office Chair')
UNION ALL
SELECT 3, 'Desk Lamp', 1, 79.99
WHERE NOT EXISTS (SELECT 1 FROM orders WHERE user_id = 3 AND product_name = 'Desk Lamp')
UNION ALL
SELECT 3, 'USB-C Cable', 3, 29.97
WHERE NOT EXISTS (SELECT 1 FROM orders WHERE user_id = 3 AND product_name = 'USB-C Cable')
UNION ALL
SELECT 4, 'Monitor 27"', 1, 349.00
WHERE NOT EXISTS (SELECT 1 FROM orders WHERE user_id = 4 AND product_name = 'Monitor 27"')
UNION ALL
SELECT 5, 'Keyboard Mechanical', 1, 159.99
WHERE NOT EXISTS (SELECT 1 FROM orders WHERE user_id = 5 AND product_name = 'Keyboard Mechanical')
UNION ALL
SELECT 6, 'Webcam HD', 1, 89.99
WHERE NOT EXISTS (SELECT 1 FROM orders WHERE user_id = 6 AND product_name = 'Webcam HD')
UNION ALL
SELECT 7, 'Headphones', 1, 199.00
WHERE NOT EXISTS (SELECT 1 FROM orders WHERE user_id = 7 AND product_name = 'Headphones')
UNION ALL
SELECT 8, 'External SSD 1TB', 1, 129.99
WHERE NOT EXISTS (SELECT 1 FROM orders WHERE user_id = 8 AND product_name = 'External SSD 1TB')
UNION ALL
SELECT 9, 'Laptop Stand', 1, 49.99
WHERE NOT EXISTS (SELECT 1 FROM orders WHERE user_id = 9 AND product_name = 'Laptop Stand')
UNION ALL
SELECT 10, 'Cable Management', 1, 24.99
WHERE NOT EXISTS (SELECT 1 FROM orders WHERE user_id = 10 AND product_name = 'Cable Management');

-- Create a view for easy querying
CREATE OR REPLACE VIEW user_orders AS
SELECT 
    u.id as user_id,
    u.name as user_name,
    u.email,
    o.id as order_id,
    o.product_name,
    o.quantity,
    o.total_amount,
    o.order_date
FROM users u
LEFT JOIN orders o ON u.id = o.user_id
ORDER BY u.id, o.order_date DESC;

-- Display sample data
SELECT 'Users created:' as status, COUNT(*) as count FROM users
UNION ALL
SELECT 'Orders created:' as status, COUNT(*) as count FROM orders;

-- Show sample data
SELECT '=== Sample Users ===' as info;
SELECT id, name, email FROM users LIMIT 5;

SELECT '=== Sample Orders ===' as info;
SELECT o.id, u.name, o.product_name, o.total_amount 
FROM orders o 
JOIN users u ON o.user_id = u.id 
LIMIT 5;



