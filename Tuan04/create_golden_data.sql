/*
Chọn Star Schema kết nối trực tiếp các bảng chiều (Dimension) 
xung quanh một hoặc nhiều bảng sự kiện/tổng hợp (Fact/Aggregated Fact). 
Giúp giảm thiểu số lượng phép JOIN phức tạp

Nếu chọn Snowflake chuẩn hóa (normalize) các bảng Dimension thành nhiều lớp, 
làm tăng số lần JOIN và giảm hiệu năng khi vẽ biểu đồ.

*/

-- Tạo Fact Table cho Doanh thu giao dịch
SELECT 
    o.order_date,
    o.order_id,
    oi.product_id,
    o.order_status,
    oi.quantity,
    oi.unit_price,
    oi.discount_amount,
    ISNULL(r.refund_amount, 0) AS refund_amount,
    -- Tính toán Metrics đã thiết kế:
    (oi.quantity * oi.unit_price) AS gross_revenue,
    ((oi.quantity * oi.unit_price) - oi.discount_amount) AS actual_revenue,
    (((oi.quantity * oi.unit_price) - oi.discount_amount) - ISNULL(r.refund_amount, 0)) AS net_revenue
INTO fact_sales_revenue
FROM order_items_silver oi
JOIN orders_enriched_silver o 
    ON oi.order_id = o.order_id
LEFT JOIN returns_silver r 
    ON o.order_id = r.order_id AND oi.product_id = r.product_id
WHERE o.order_status <> 'cancelled'; -- Điều kiện lọc theo tài liệu

--======================

-- Tạo Aggregated Fact Table cho Tỷ trọng Doanh thu
WITH Revenue_Category_Month AS (
    SELECT 
        FORMAT(o.order_date, 'yyyy-MM') AS Order_Month,
        p.Category,
        SUM((oi.quantity * oi.unit_price) - oi.discount_amount) AS Revenue_Category
    FROM order_items_silver oi
    JOIN orders_enriched_silver o ON oi.order_id = o.order_id
    JOIN products_silver p ON oi.product_id = p.product_id
    WHERE o.order_status <> 'cancelled'
    GROUP BY FORMAT(o.order_date, 'yyyy-MM'), p.Category
),
Total_Revenue_Month AS (
    SELECT 
        FORMAT(o.order_date, 'yyyy-MM') AS Order_Month,
        SUM((oi.quantity * oi.unit_price) - oi.discount_amount) AS Total_Revenue
    FROM order_items_silver oi
    JOIN orders_enriched_silver o ON oi.order_id = o.order_id
    WHERE o.order_status <> 'cancelled'
    GROUP BY FORMAT(o.order_date, 'yyyy-MM')
)
SELECT 
    c.Order_Month,
    c.Category,
    c.Revenue_Category,
    t.Total_Revenue,
    (c.Revenue_Category / NULLIF(t.Total_Revenue, 0)) * 100 AS Contribution_Percentage
INTO agg_revenue_by_category_monthly
FROM Revenue_Category_Month c
JOIN Total_Revenue_Month t ON c.Order_Month = t.Order_Month;

--===================

-- Tạo Golden Table cho Đánh giá Shipper
SELECT 
    shipper_id,
    MAX(shipper_name) AS shipper_name,
    MAX(shipper_experience_years) AS years_experience,
    COUNT(order_id) AS total_orders,
    SUM(shipping_fee) AS total_shipping_fee,
    AVG(CAST(shipper_rating AS FLOAT)) AS average_rating,
    AVG(CAST(delivery_success_rate AS FLOAT)) AS average_success_rate,
    AVG(CAST(delivery_days AS FLOAT)) AS average_delivery_time,
    MAX(working_shift) AS working_shift,
    MAX(shipper_vehicle) AS shipper_vehicle,
    MAX(shipper_company) AS shipper_company,
    MAX(city) AS city,
    MAX(region) AS region,
    MAX(district) AS district
INTO gold_shipper_performance
FROM shipments_silver
GROUP BY shipper_id;

--=====================

-- Tạo Golden Table cho Đánh giá Nhân viên Kinh doanh
WITH Employee_Sales AS (
    SELECT 
        o.sales_employee_id,
        MAX(o.sales_employee_name) AS sales_employee_name,
        MAX(o.years_experience) AS years_experience,
        COUNT(DISTINCT o.order_id) AS total_orders,
        SUM((oi.quantity * oi.unit_price) - oi.discount_amount) AS net_sales
    FROM orders_enriched_silver o
    JOIN order_items_silver oi ON o.order_id = oi.order_id
    WHERE o.order_status <> 'cancelled'
    GROUP BY o.sales_employee_id
),
Employee_Reviews AS (
    SELECT 
        o.sales_employee_id,
        AVG(CAST(r.rating AS FLOAT)) AS avg_csat,
        COUNT(r.review_id) AS total_reviews,
        SUM(CASE WHEN r.rating >= 4 THEN 1 ELSE 0 END) AS positive_reviews
    FROM orders_enriched_silver o
    JOIN reviews_silver r ON o.order_id = r.order_id
    GROUP BY o.sales_employee_id
),
Employee_Returns AS (
    SELECT 
        o.sales_employee_id,
        SUM(ret.refund_amount) AS total_refund_amount
    FROM orders_enriched_silver o
    JOIN returns_silver ret ON o.order_id = ret.order_id
    GROUP BY o.sales_employee_id
)
SELECT 
    es.sales_employee_id,
    es.sales_employee_name,
    es.years_experience,
    es.total_orders,
    es.net_sales,
    (es.net_sales / NULLIF(es.total_orders, 0)) AS employee_aov,
    ISNULL(er.avg_csat, 0) AS avg_csat,
    (CAST(er.positive_reviews AS FLOAT) / NULLIF(er.total_reviews, 0)) * 100 AS positive_review_rate,
    (ISNULL(ret.total_refund_amount, 0) / NULLIF(es.net_sales, 0)) * 100 AS return_rate,
    -- Giả sử Target Sales trung bình của nhân viên là 10,000,000 để tính Balanced Score (Target này có thể thay thế bằng dữ liệu thật)
    (0.6 * (es.net_sales / 10000000) + 0.4 * (ISNULL(er.avg_csat, 0) / 5)) AS balanced_score,
    CASE 
        WHEN (0.6 * (es.net_sales / 10000000) + 0.4 * (ISNULL(er.avg_csat, 0) / 5)) >= 0.8 THEN N'Xuất sắc'
        WHEN (0.6 * (es.net_sales / 10000000) + 0.4 * (ISNULL(er.avg_csat, 0) / 5)) >= 0.5 THEN N'Khá'
        ELSE N'Cần cải thiện'
    END AS evaluation
INTO gold_employee_performance
FROM Employee_Sales es
LEFT JOIN Employee_Reviews er ON es.sales_employee_id = er.sales_employee_id
LEFT JOIN Employee_Returns ret ON es.sales_employee_id = ret.sales_employee_id;

--======================

-- Tạo Fact Table phục vụ Forecasting
SELECT 
    FORMAT(o.order_date, 'yyyy-MM') AS Month,
    SUM((oi.quantity * oi.unit_price) - oi.discount_amount) AS Actual_Revenue,
    CAST(NULL AS FLOAT) AS Forecasted_Revenue,
    CAST(NULL AS FLOAT) AS Confidence_Interval_Lower,
    CAST(NULL AS FLOAT) AS Confidence_Interval_Upper
INTO fact_revenue_forecast
FROM order_items_silver oi
JOIN orders_enriched_silver o ON oi.order_id = o.order_id
WHERE o.order_status <> 'cancelled'
GROUP BY FORMAT(o.order_date, 'yyyy-MM')
ORDER BY Month ASC;
