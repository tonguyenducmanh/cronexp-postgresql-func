DROP FUNCTION IF EXISTS cron.is_cron_expression_satisfied(cron_expression VARCHAR, target_datetime TIMESTAMP);
CREATE OR REPLACE FUNCTION cron.is_cron_expression_satisfied(
    cron_expression VARCHAR,
    target_datetime TIMESTAMP
)
RETURNS BOOLEAN
AS $$
-- function này hỗ trợ check ngày có phù hợp với biểu thức cron expression không
-- cron_expression: tuân thủ biểu thức sau:
-- * * * * * * *
-- | | | | | | |
-- | | | | | | +-- Year (range: 1900-3000)
-- | | | | | +---- Day of the week (range: 1-7, 1 = Sunday)
-- | | | | +------ Month (range: 1-12)
-- | | | +-------- Day of the month (range: 1-31)
-- | | +---------- Hour (range: 0-23)
-- | +------------ Minute (range: 0-59)
-- +-------------- Second (range: 0-59)
-- các logic hỗ trợ gồm:
---- * : toàn bộ giá trị phù hợp
---- giá trị cụ thể : vd 12
---- range giá trị: vd 1-5
---- list giá trị: vd 1,2,3
---- step value: vd */10 với * là phút thì lấy các phút chia hết cho 10
---- end of month: vd L với day_of_month thì lấy ngày cuối cùng của tháng
---- => lưu ý từ này chỉ dùng cho day of month
---- thứ tự ưu tiên ngày - năm giảm dần, các thứ tự ưu tiên giảm dần có thể bỏ
-- select 'vd thời gian cụ thể' as type, cron.is_cron_expression_satisfied('* * * * 6 1 *','2024-06-23'::TIMESTAMP) as result
-- union all
-- select 'vd range, list' as type,  cron.is_cron_expression_satisfied('* * * 20-25 5,6,7 * *','2024-06-23'::TIMESTAMP) as result
-- union all
-- select 'vd step value' as type, cron.is_cron_expression_satisfied('* * * */2 5,6,7 * *','2024-06-20'::TIMESTAMP) as result
-- union all
-- select 'vd end of month' as type, cron.is_cron_expression_satisfied('* * * L 5,6,7 * *','2024-06-30'::TIMESTAMP) as result
-- union all
-- select 'vd bỏ qua các giá trị không cần thiết' as type, cron.is_cron_expression_satisfied('* * * L','2024-06-30'::TIMESTAMP) as result;
DECLARE
    cron_parts VARCHAR[] = STRING_TO_ARRAY(cron_expression, ' ');
    seconds VARCHAR;
    minutes VARCHAR;
    hours VARCHAR;
    day_of_month VARCHAR;
    month VARCHAR;
    day_of_week VARCHAR;
    year VARCHAR;
    target_second INT = EXTRACT(SECOND FROM target_datetime);
    target_minute INT = EXTRACT(MINUTE FROM target_datetime);
    target_hour INT = EXTRACT(HOUR FROM target_datetime);
    target_day_of_month INT = EXTRACT(DAY FROM target_datetime);
    target_month_array INT = EXTRACT(MONTH FROM target_datetime);
    target_day_of_week INT = EXTRACT(DOW FROM target_datetime) + 1;
    target_year INT = EXTRACT(YEAR FROM target_datetime);
BEGIN
    -- Bóc tách thành phần cụ thể từ cron expression
    seconds := coalesce(cron_parts[1], '*');
    minutes := coalesce(cron_parts[2], '*');
    hours := coalesce(cron_parts[3], '*');
    day_of_month := coalesce(cron_parts[4], '*');
    month := coalesce(cron_parts[5], '*');
    day_of_week := coalesce(cron_parts[6], '*');
    year := coalesce(cron_parts[7], '*');

    -- Kiểm tra target_datetime có thỏa mãn cron expression
    RETURN (
        cron.is_satisfied(seconds, target_second, target_datetime) AND
        cron.is_satisfied(minutes, target_minute, target_datetime) AND
        cron.is_satisfied(hours, target_hour, target_datetime) AND
        cron.is_satisfied(day_of_month, target_day_of_month, target_datetime) AND
        cron.is_satisfied(month, target_month_array, target_datetime) AND
        cron.is_satisfied(day_of_week, target_day_of_week, target_datetime) AND
        cron.is_satisfied(year, target_year, target_datetime)
    );
END;
$$ LANGUAGE plpgsql;

DROP FUNCTION IF EXISTS cron.is_satisfied(cron_value VARCHAR, target_value INT, target_datetime TIMESTAMP);
CREATE OR REPLACE FUNCTION cron.is_satisfied(cron_value VARCHAR, target_value INT, target_datetime TIMESTAMP)
RETURNS BOOLEAN
AS $$
-- function này hỗ trợ check giá trị đích có phù hợp với biểu thức cron value không
-- biểu thức cron value là biểu thức con của biểu thức cron expression
DECLARE
    -- chia biểu thức cron thành các thành phần theo dấu , để xử lý từng phần 1
    cron_parts VARCHAR[] = REGEXP_SPLIT_TO_ARRAY(cron_value, ',');
    i INT;
BEGIN
    FOR i IN 1..ARRAY_LENGTH(cron_parts, 1) LOOP
        IF cron_parts[i] LIKE '%-%' THEN
            -- xử lý giá trị có nằm trong 1 khoảng hay không
            DECLARE
                range_parts INT[] = ARRAY[CAST(SPLIT_PART(cron_parts[i], '-', 1) AS INT), CAST(SPLIT_PART(cron_parts[i], '-', 2) AS INT)];
            BEGIN
                IF target_value BETWEEN range_parts[1] AND range_parts[2] THEN
                    RETURN TRUE;
                END IF;
            END;
        ELSIF cron_parts[i] LIKE '*/%' THEN
            -- Xử lý giá trị có chia hết cho 1 số hay không
            DECLARE
                step_value INT = CAST(SPLIT_PART(cron_parts[i], '*/', 2) AS INT);
            BEGIN
                IF target_value % step_value = 0 THEN
                    RETURN TRUE;
                END IF;
            END;
        ELSIF cron_parts[i] = 'L' THEN
            -- Xử lý giá trị có phải là ngày cuối của tháng không
            DECLARE
                last_day_of_month INT = EXTRACT(DAY FROM DATE_TRUNC('MONTH', target_datetime + INTERVAL '1 MONTH') - INTERVAL '1 DAY');
            BEGIN
                IF target_value = last_day_of_month THEN
                    RETURN TRUE;
                END IF;
            END;
        ELSIF cron_parts[i] = '*' THEN
            -- Xử lý giá trị có phải là mọi giá trị không
            RETURN TRUE;
        ELSIF target_value = CAST(cron_parts[i] AS INT) THEN
            -- Xử lý giá trị có bằng giá trị cụ thể không
            RETURN TRUE;
        END IF;
    END LOOP;

    RETURN FALSE;
END;
$$ LANGUAGE plpgsql;