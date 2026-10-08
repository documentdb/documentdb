SET search_path TO documentdb_core,documentdb_api,documentdb_api_catalog;

SET documentdb.next_collection_id TO 25850100;
SET documentdb.next_collection_index_id TO 25850100;

-- $dateTrunc behavioral coverage. Each SELECT is a complete, independent case.

-- Proleptic Gregorian calendar behavior.
SELECT 'calendar_1500_day' AS case_id, * FROM bson_dollar_project('{}', '{"result":{"$dateTrunc":{"date":{"$date":{"$numberLong":"-14826628800000"}},"unit":"day","binSize":{"$numberLong":"1"},"timezone":"UTC"}}}');
SELECT 'calendar_1500_month' AS case_id, * FROM bson_dollar_project('{}', '{"result":{"$dateTrunc":{"date":{"$date":{"$numberLong":"-14826628800000"}},"unit":"month","binSize":{"$numberLong":"1"},"timezone":"UTC"}}}');
SELECT 'calendar_1500_quarter' AS case_id, * FROM bson_dollar_project('{}', '{"result":{"$dateTrunc":{"date":{"$date":{"$numberLong":"-14826628800000"}},"unit":"quarter","binSize":{"$numberLong":"1"},"timezone":"UTC"}}}');
SELECT 'calendar_1500_week' AS case_id, * FROM bson_dollar_project('{}', '{"result":{"$dateTrunc":{"date":{"$date":{"$numberLong":"-14826628800000"}},"unit":"week","binSize":{"$numberLong":"1"},"timezone":"UTC","startOfWeek":"sunday"}}}');
SELECT 'calendar_1500_year' AS case_id, * FROM bson_dollar_project('{}', '{"result":{"$dateTrunc":{"date":{"$date":{"$numberLong":"-14826628800000"}},"unit":"year","binSize":{"$numberLong":"1"},"timezone":"UTC"}}}');
SELECT 'calendar_1600_leap_day' AS case_id, * FROM bson_dollar_project('{}', '{"result":{"$dateTrunc":{"date":{"$date":{"$numberLong":"-11670955200000"}},"unit":"day","binSize":{"$numberLong":"1"},"timezone":"UTC"}}}');
SELECT 'calendar_1600_leap_month' AS case_id, * FROM bson_dollar_project('{}', '{"result":{"$dateTrunc":{"date":{"$date":{"$numberLong":"-11670955200000"}},"unit":"month","binSize":{"$numberLong":"1"},"timezone":"UTC"}}}');
SELECT 'calendar_1600_leap_year' AS case_id, * FROM bson_dollar_project('{}', '{"result":{"$dateTrunc":{"date":{"$date":{"$numberLong":"-11670955200000"}},"unit":"year","binSize":{"$numberLong":"1"},"timezone":"UTC"}}}');
-- ISO year 0000 is 1 BCE, and ISO year -000001 is 2 BCE.
SELECT 'calendar_year_zero_month' AS case_id, * FROM bson_dollar_project('{}', '{"result":{"$dateTrunc":{"date":{"$date":{"$numberLong":"-62152831503211"}},"unit":"month","binSize":{"$numberLong":"1"},"timezone":"UTC"}}}');
SELECT 'calendar_year_zero_quarter' AS case_id, * FROM bson_dollar_project('{}', '{"result":{"$dateTrunc":{"date":{"$date":{"$numberLong":"-62152831503211"}},"unit":"quarter","binSize":{"$numberLong":"1"},"timezone":"UTC"}}}');
SELECT 'calendar_year_zero_year' AS case_id, * FROM bson_dollar_project('{}', '{"result":{"$dateTrunc":{"date":{"$date":{"$numberLong":"-62152831503211"}},"unit":"year","binSize":{"$numberLong":"1"},"timezone":"UTC"}}}');
SELECT 'calendar_year_minus_one_month' AS case_id, * FROM bson_dollar_project('{}', '{"result":{"$dateTrunc":{"date":{"$date":{"$numberLong":"-62184453903211"}},"unit":"month","binSize":{"$numberLong":"1"},"timezone":"UTC"}}}');
SELECT 'calendar_year_minus_one_quarter' AS case_id, * FROM bson_dollar_project('{}', '{"result":{"$dateTrunc":{"date":{"$date":{"$numberLong":"-62184453903211"}},"unit":"quarter","binSize":{"$numberLong":"1"},"timezone":"UTC"}}}');
SELECT 'calendar_year_minus_one_year' AS case_id, * FROM bson_dollar_project('{}', '{"result":{"$dateTrunc":{"date":{"$date":{"$numberLong":"-62184453903211"}},"unit":"year","binSize":{"$numberLong":"1"},"timezone":"UTC"}}}');

-- Expression evaluation with default optional arguments: literal and field-path parity.
SELECT 'constant_day_default' AS case_id, * FROM bson_dollar_project('{}', '{"result":{"$dateTrunc":{"date":{"$date":{"$numberLong":"1716049038987"}},"unit":"day"}}}');
SELECT 'expression_day_default' AS case_id, * FROM bson_dollar_project('{"input":{"$date":{"$numberLong":"1716049038987"}}}', '{"result":{"$dateTrunc":{"date":"$input","unit":"day"}}}');
SELECT 'constant_hour_default' AS case_id, * FROM bson_dollar_project('{}', '{"result":{"$dateTrunc":{"date":{"$date":{"$numberLong":"1716049038987"}},"unit":"hour"}}}');
SELECT 'expression_hour_default' AS case_id, * FROM bson_dollar_project('{"input":{"$date":{"$numberLong":"1716049038987"}}}', '{"result":{"$dateTrunc":{"date":"$input","unit":"hour"}}}');
SELECT 'constant_minute_default' AS case_id, * FROM bson_dollar_project('{}', '{"result":{"$dateTrunc":{"date":{"$date":{"$numberLong":"1716049038987"}},"unit":"minute"}}}');
SELECT 'expression_minute_default' AS case_id, * FROM bson_dollar_project('{"input":{"$date":{"$numberLong":"1716049038987"}}}', '{"result":{"$dateTrunc":{"date":"$input","unit":"minute"}}}');
SELECT 'constant_month_default' AS case_id, * FROM bson_dollar_project('{}', '{"result":{"$dateTrunc":{"date":{"$date":{"$numberLong":"1716049038987"}},"unit":"month"}}}');
SELECT 'expression_month_default' AS case_id, * FROM bson_dollar_project('{"input":{"$date":{"$numberLong":"1716049038987"}}}', '{"result":{"$dateTrunc":{"date":"$input","unit":"month"}}}');
SELECT 'constant_quarter_default' AS case_id, * FROM bson_dollar_project('{}', '{"result":{"$dateTrunc":{"date":{"$date":{"$numberLong":"1716049038987"}},"unit":"quarter"}}}');
SELECT 'expression_quarter_default' AS case_id, * FROM bson_dollar_project('{"input":{"$date":{"$numberLong":"1716049038987"}}}', '{"result":{"$dateTrunc":{"date":"$input","unit":"quarter"}}}');
SELECT 'constant_second_default' AS case_id, * FROM bson_dollar_project('{}', '{"result":{"$dateTrunc":{"date":{"$date":{"$numberLong":"1716049038987"}},"unit":"second"}}}');
SELECT 'expression_second_default' AS case_id, * FROM bson_dollar_project('{"input":{"$date":{"$numberLong":"1716049038987"}}}', '{"result":{"$dateTrunc":{"date":"$input","unit":"second"}}}');
SELECT 'constant_week_default' AS case_id, * FROM bson_dollar_project('{}', '{"result":{"$dateTrunc":{"date":{"$date":{"$numberLong":"1716049038987"}},"unit":"week"}}}');
SELECT 'expression_week_default' AS case_id, * FROM bson_dollar_project('{"input":{"$date":{"$numberLong":"1716049038987"}}}', '{"result":{"$dateTrunc":{"date":"$input","unit":"week"}}}');
SELECT 'constant_year_default' AS case_id, * FROM bson_dollar_project('{}', '{"result":{"$dateTrunc":{"date":{"$date":{"$numberLong":"1716049038987"}},"unit":"year"}}}');
SELECT 'expression_year_default' AS case_id, * FROM bson_dollar_project('{"input":{"$date":{"$numberLong":"1716049038987"}}}', '{"result":{"$dateTrunc":{"date":"$input","unit":"year"}}}');

-- Day truncation, including leap years, multi-day and large 64-bit bins, offsets, and DST.
SELECT 'day_1999_december' AS case_id, * FROM bson_dollar_project('{}', '{"result":{"$dateTrunc":{"date":{"$date":{"$numberLong":"946643696789"}},"unit":"day","binSize":{"$numberLong":"1"},"timezone":"UTC"}}}');
SELECT 'day_1999_february' AS case_id, * FROM bson_dollar_project('{}', '{"result":{"$dateTrunc":{"date":{"$date":{"$numberLong":"919082096789"}},"unit":"day","binSize":{"$numberLong":"1"},"timezone":"UTC"}}}');
SELECT 'day_1999_january' AS case_id, * FROM bson_dollar_project('{}', '{"result":{"$dateTrunc":{"date":{"$date":{"$numberLong":"916403696789"}},"unit":"day","binSize":{"$numberLong":"1"},"timezone":"UTC"}}}');
SELECT 'day_2000_dec_31' AS case_id, * FROM bson_dollar_project('{}', '{"result":{"$dateTrunc":{"date":{"$date":{"$numberLong":"978266096789"}},"unit":"day","binSize":{"$numberLong":"1"},"timezone":"UTC"}}}');
SELECT 'day_2000_feb_28' AS case_id, * FROM bson_dollar_project('{}', '{"result":{"$dateTrunc":{"date":{"$date":{"$numberLong":"951741296789"}},"unit":"day","binSize":{"$numberLong":"1"},"timezone":"UTC"}}}');
SELECT 'day_2000_feb_29' AS case_id, * FROM bson_dollar_project('{}', '{"result":{"$dateTrunc":{"date":{"$date":{"$numberLong":"951827696789"}},"unit":"day","binSize":{"$numberLong":"1"},"timezone":"UTC"}}}');
SELECT 'day_2000_mar_01' AS case_id, * FROM bson_dollar_project('{}', '{"result":{"$dateTrunc":{"date":{"$date":{"$numberLong":"951914096789"}},"unit":"day","binSize":{"$numberLong":"1"},"timezone":"UTC"}}}');
SELECT 'day_2001_feb_01' AS case_id, * FROM bson_dollar_project('{}', '{"result":{"$dateTrunc":{"date":{"$date":{"$numberLong":"981030896789"}},"unit":"day","binSize":{"$numberLong":"1"},"timezone":"UTC"}}}');
SELECT 'day_2001_jan_01' AS case_id, * FROM bson_dollar_project('{}', '{"result":{"$dateTrunc":{"date":{"$date":{"$numberLong":"978307260000"}},"unit":"day","binSize":{"$numberLong":"1"},"timezone":"UTC"}}}');
SELECT 'day_2001_jan_02' AS case_id, * FROM bson_dollar_project('{}', '{"result":{"$dateTrunc":{"date":{"$date":{"$numberLong":"978393660000"}},"unit":"day","binSize":{"$numberLong":"1"},"timezone":"UTC"}}}');
SELECT 'day_2001_mar_01' AS case_id, * FROM bson_dollar_project('{}', '{"result":{"$dateTrunc":{"date":{"$date":{"$numberLong":"983450096789"}},"unit":"day","binSize":{"$numberLong":"1"},"timezone":"UTC"}}}');
SELECT 'day_2024_leap' AS case_id, * FROM bson_dollar_project('{}', '{"result":{"$dateTrunc":{"date":{"$date":{"$numberLong":"1709210096789"}},"unit":"day","binSize":{"$numberLong":"1"},"timezone":"UTC"}}}');
SELECT 'day_2026_01' AS case_id, * FROM bson_dollar_project('{"input":{"$date":{"$numberLong":"1768480496789"}},"unit":"day","binSize":{"$numberLong":"1"},"timezone":"UTC","startOfWeek":"sunday"}', '{"result":{"$dateTrunc":{"date":"$input","unit":"$unit","binSize":"$binSize","timezone":"$timezone","startOfWeek":"$startOfWeek"}}}');
SELECT 'day_2026_02' AS case_id, * FROM bson_dollar_project('{}', '{"result":{"$dateTrunc":{"date":{"$date":{"$numberLong":"1771158896789"}},"unit":"day","binSize":{"$numberLong":"1"},"timezone":"UTC"}}}');
SELECT 'day_2026_03' AS case_id, * FROM bson_dollar_project('{}', '{"result":{"$dateTrunc":{"date":{"$date":{"$numberLong":"1773578096789"}},"unit":"day","binSize":{"$numberLong":"1"},"timezone":"UTC"}}}');
SELECT 'day_2026_04' AS case_id, * FROM bson_dollar_project('{}', '{"result":{"$dateTrunc":{"date":{"$date":{"$numberLong":"1776256496789"}},"unit":"day","binSize":{"$numberLong":"1"},"timezone":"UTC"}}}');
SELECT 'day_2026_05' AS case_id, * FROM bson_dollar_project('{}', '{"result":{"$dateTrunc":{"date":{"$date":{"$numberLong":"1778848496789"}},"unit":"day","binSize":{"$numberLong":"1"},"timezone":"UTC"}}}');
SELECT 'day_2026_06' AS case_id, * FROM bson_dollar_project('{}', '{"result":{"$dateTrunc":{"date":{"$date":{"$numberLong":"1781526896789"}},"unit":"day","binSize":{"$numberLong":"1"},"timezone":"UTC"}}}');
SELECT 'day_2026_07' AS case_id, * FROM bson_dollar_project('{}', '{"result":{"$dateTrunc":{"date":{"$date":{"$numberLong":"1784118896789"}},"unit":"day","binSize":{"$numberLong":"1"},"timezone":"UTC"}}}');
SELECT 'day_2026_08' AS case_id, * FROM bson_dollar_project('{}', '{"result":{"$dateTrunc":{"date":{"$date":{"$numberLong":"1786797296789"}},"unit":"day","binSize":{"$numberLong":"1"},"timezone":"UTC"}}}');
SELECT 'day_2026_09' AS case_id, * FROM bson_dollar_project('{}', '{"result":{"$dateTrunc":{"date":{"$date":{"$numberLong":"1789475696789"}},"unit":"day","binSize":{"$numberLong":"1"},"timezone":"UTC"}}}');
SELECT 'day_2026_10' AS case_id, * FROM bson_dollar_project('{}', '{"result":{"$dateTrunc":{"date":{"$date":{"$numberLong":"1792067696789"}},"unit":"day","binSize":{"$numberLong":"1"},"timezone":"UTC"}}}');
SELECT 'day_2026_11' AS case_id, * FROM bson_dollar_project('{}', '{"result":{"$dateTrunc":{"date":{"$date":{"$numberLong":"1794746096789"}},"unit":"day","binSize":{"$numberLong":"1"},"timezone":"UTC"}}}');
SELECT 'day_2026_12' AS case_id, * FROM bson_dollar_project('{}', '{"result":{"$dateTrunc":{"date":{"$date":{"$numberLong":"1797338096789"}},"unit":"day","binSize":{"$numberLong":"1"},"timezone":"UTC"}}}');
SELECT 'day_dst_fall' AS case_id, * FROM bson_dollar_project('{}', '{"result":{"$dateTrunc":{"date":{"$date":{"$numberLong":"1636266600000"}},"unit":"day","binSize":{"$numberLong":"1"},"timezone":"America/New_York"}}}');
SELECT 'day_dst_spring' AS case_id, * FROM bson_dollar_project('{}', '{"result":{"$dateTrunc":{"date":{"$date":{"$numberLong":"1615707000000"}},"unit":"day","binSize":{"$numberLong":"1"},"timezone":"America/New_York"}}}');
SELECT 'day_offset_east' AS case_id, * FROM bson_dollar_project('{}', '{"result":{"$dateTrunc":{"date":{"$date":{"$numberLong":"1704139200000"}},"unit":"day","binSize":{"$numberLong":"1"},"timezone":"+04:45"}}}');
SELECT 'day_offset_west' AS case_id, * FROM bson_dollar_project('{}', '{"result":{"$dateTrunc":{"date":{"$date":{"$numberLong":"1704081600000"}},"unit":"day","binSize":{"$numberLong":"1"},"timezone":"-0530"}}}');
SELECT 'day_ref_before' AS case_id, * FROM bson_dollar_project('{}', '{"result":{"$dateTrunc":{"date":{"$date":{"$numberLong":"946684799999"}},"unit":"day","binSize":{"$numberLong":"2"},"timezone":"UTC"}}}');
SELECT 'day_ref_bin_end' AS case_id, * FROM bson_dollar_project('{}', '{"result":{"$dateTrunc":{"date":{"$date":{"$numberLong":"946857599999"}},"unit":"day","binSize":{"$numberLong":"2"},"timezone":"UTC"}}}');
SELECT 'day_ref_exact' AS case_id, * FROM bson_dollar_project('{}', '{"result":{"$dateTrunc":{"date":{"$date":{"$numberLong":"946684800000"}},"unit":"day","binSize":{"$numberLong":"2"},"timezone":"UTC"}}}');
SELECT 'day_large_bin_after_ref' AS case_id, * FROM bson_dollar_project('{}', '{"result":{"$dateTrunc":{"date":{"$date":{"$numberLong":"1784118896789"}},"unit":"day","binSize":{"$numberLong":"2147483648"},"timezone":"UTC"}}}');
SELECT 'day_large_bin_ref_exact' AS case_id, * FROM bson_dollar_project('{}', '{"result":{"$dateTrunc":{"date":{"$date":{"$numberLong":"946684800000"}},"unit":"day","binSize":{"$numberLong":"2147483648"},"timezone":"UTC"}}}');
SELECT 'day_ref_next' AS case_id, * FROM bson_dollar_project('{}', '{"result":{"$dateTrunc":{"date":{"$date":{"$numberLong":"946857600000"}},"unit":"day","binSize":{"$numberLong":"2"},"timezone":"UTC"}}}');
SELECT 'day_timezone_previous' AS case_id, * FROM bson_dollar_project('{}', '{"result":{"$dateTrunc":{"date":{"$date":{"$numberLong":"1704079800000"}},"unit":"day","binSize":{"$numberLong":"1"},"timezone":"America/New_York"}}}');

-- Hour truncation, including a fully dynamic case, offsets, and DST.
SELECT 'hour_bin_1' AS case_id, * FROM bson_dollar_project('{"input":{"$date":{"$numberLong":"1707113755381"}},"unit":"hour","binSize":{"$numberLong":"1"},"timezone":"UTC","startOfWeek":"sunday"}', '{"result":{"$dateTrunc":{"date":"$input","unit":"$unit","binSize":"$binSize","timezone":"$timezone","startOfWeek":"$startOfWeek"}}}');
SELECT 'hour_bin_2' AS case_id, * FROM bson_dollar_project('{}', '{"result":{"$dateTrunc":{"date":{"$date":{"$numberLong":"1616239805000"}},"unit":"hour","binSize":{"$numberLong":"2"},"timezone":"UTC"}}}');
SELECT 'hour_bin_24' AS case_id, * FROM bson_dollar_project('{}', '{"result":{"$dateTrunc":{"date":{"$date":{"$numberLong":"1707113755381"}},"unit":"hour","binSize":{"$numberLong":"24"},"timezone":"UTC"}}}');
SELECT 'hour_dst_fall_first' AS case_id, * FROM bson_dollar_project('{}', '{"result":{"$dateTrunc":{"date":{"$date":{"$numberLong":"1636263000000"}},"unit":"hour","binSize":{"$numberLong":"1"},"timezone":"America/New_York"}}}');
SELECT 'hour_dst_fall_second' AS case_id, * FROM bson_dollar_project('{}', '{"result":{"$dateTrunc":{"date":{"$date":{"$numberLong":"1636266600000"}},"unit":"hour","binSize":{"$numberLong":"1"},"timezone":"America/New_York"}}}');
SELECT 'hour_dst_spring' AS case_id, * FROM bson_dollar_project('{}', '{"result":{"$dateTrunc":{"date":{"$date":{"$numberLong":"1615707000000"}},"unit":"hour","binSize":{"$numberLong":"1"},"timezone":"America/New_York"}}}');
SELECT 'hour_offset_colon' AS case_id, * FROM bson_dollar_project('{}', '{"result":{"$dateTrunc":{"date":{"$date":{"$numberLong":"1704112496000"}},"unit":"hour","binSize":{"$numberLong":"1"},"timezone":"+04:45"}}}');
SELECT 'hour_offset_compact' AS case_id, * FROM bson_dollar_project('{}', '{"result":{"$dateTrunc":{"date":{"$date":{"$numberLong":"1704112496000"}},"unit":"hour","binSize":{"$numberLong":"1"},"timezone":"-0530"}}}');
SELECT 'hour_offset_hour' AS case_id, * FROM bson_dollar_project('{}', '{"result":{"$dateTrunc":{"date":{"$date":{"$numberLong":"1704112496000"}},"unit":"hour","binSize":{"$numberLong":"1"},"timezone":"+03"}}}');
SELECT 'hour_ref_before' AS case_id, * FROM bson_dollar_project('{}', '{"result":{"$dateTrunc":{"date":{"$date":{"$numberLong":"946684799999"}},"unit":"hour","binSize":{"$numberLong":"2"},"timezone":"UTC"}}}');
SELECT 'hour_ref_bin_end' AS case_id, * FROM bson_dollar_project('{}', '{"result":{"$dateTrunc":{"date":{"$date":{"$numberLong":"946691999999"}},"unit":"hour","binSize":{"$numberLong":"2"},"timezone":"UTC"}}}');
SELECT 'hour_ref_exact' AS case_id, * FROM bson_dollar_project('{}', '{"result":{"$dateTrunc":{"date":{"$date":{"$numberLong":"946684800000"}},"unit":"hour","binSize":{"$numberLong":"2"},"timezone":"UTC"}}}');
SELECT 'hour_ref_next' AS case_id, * FROM bson_dollar_project('{}', '{"result":{"$dateTrunc":{"date":{"$date":{"$numberLong":"946692000000"}},"unit":"hour","binSize":{"$numberLong":"2"},"timezone":"UTC"}}}');

-- Accepted BSON date input representations.
SELECT 'input_date' AS case_id, * FROM bson_dollar_project('{"input":{"$date":{"$numberLong":"1709208000000"}}}', '{"result":{"$dateTrunc":{"date":"$input","unit":"day"}}}');
SELECT 'input_object_id' AS case_id, * FROM bson_dollar_project('{"input":{"$oid":"65e071c00000000000000000"}}', '{"result":{"$dateTrunc":{"date":"$input","unit":"day"}}}');
SELECT 'input_timestamp' AS case_id, * FROM bson_dollar_project('{"input":{"$timestamp":{"t":1709208000,"i":42}}}', '{"result":{"$dateTrunc":{"date":"$input","unit":"day"}}}');

-- Minute truncation, including a fully dynamic case and fixed offsets.
SELECT 'minute_bin_1' AS case_id, * FROM bson_dollar_project('{"input":{"$date":{"$numberLong":"1707113755381"}},"unit":"minute","binSize":{"$numberLong":"1"},"timezone":"UTC","startOfWeek":"sunday"}', '{"result":{"$dateTrunc":{"date":"$input","unit":"$unit","binSize":"$binSize","timezone":"$timezone","startOfWeek":"$startOfWeek"}}}');
SELECT 'minute_bin_15' AS case_id, * FROM bson_dollar_project('{}', '{"result":{"$dateTrunc":{"date":{"$date":{"$numberLong":"1707113755381"}},"unit":"minute","binSize":{"$numberLong":"15"},"timezone":"UTC"}}}');
SELECT 'minute_bin_90_offset' AS case_id, * FROM bson_dollar_project('{}', '{"result":{"$dateTrunc":{"date":{"$date":{"$numberLong":"1704112496000"}},"unit":"minute","binSize":{"$numberLong":"90"},"timezone":"+04:45"}}}');
SELECT 'minute_ref_before' AS case_id, * FROM bson_dollar_project('{}', '{"result":{"$dateTrunc":{"date":{"$date":{"$numberLong":"946684799999"}},"unit":"minute","binSize":{"$numberLong":"15"},"timezone":"UTC"}}}');
SELECT 'minute_ref_bin_end' AS case_id, * FROM bson_dollar_project('{}', '{"result":{"$dateTrunc":{"date":{"$date":{"$numberLong":"946685699999"}},"unit":"minute","binSize":{"$numberLong":"15"},"timezone":"UTC"}}}');
SELECT 'minute_ref_exact' AS case_id, * FROM bson_dollar_project('{}', '{"result":{"$dateTrunc":{"date":{"$date":{"$numberLong":"946684800000"}},"unit":"minute","binSize":{"$numberLong":"15"},"timezone":"UTC"}}}');
SELECT 'minute_ref_next' AS case_id, * FROM bson_dollar_project('{}', '{"result":{"$dateTrunc":{"date":{"$date":{"$numberLong":"946685700000"}},"unit":"minute","binSize":{"$numberLong":"15"},"timezone":"UTC"}}}');

-- Month truncation, including a fully dynamic case and timezone boundaries.
SELECT 'month_bin_1' AS case_id, * FROM bson_dollar_project('{"input":{"$date":{"$numberLong":"1709210096000"}},"unit":"month","binSize":{"$numberLong":"1"},"timezone":"UTC","startOfWeek":"sunday"}', '{"result":{"$dateTrunc":{"date":"$input","unit":"$unit","binSize":"$binSize","timezone":"$timezone","startOfWeek":"$startOfWeek"}}}');
SELECT 'month_bin_2' AS case_id, * FROM bson_dollar_project('{}', '{"result":{"$dateTrunc":{"date":{"$date":{"$numberLong":"1709210096000"}},"unit":"month","binSize":{"$numberLong":"2"},"timezone":"UTC"}}}');
SELECT 'month_bin_6' AS case_id, * FROM bson_dollar_project('{}', '{"result":{"$dateTrunc":{"date":{"$date":{"$numberLong":"1589811030000"}},"unit":"month","binSize":{"$numberLong":"6"},"timezone":"UTC"}}}');
SELECT 'month_ref_before' AS case_id, * FROM bson_dollar_project('{}', '{"result":{"$dateTrunc":{"date":{"$date":{"$numberLong":"946684799999"}},"unit":"month","binSize":{"$numberLong":"2"},"timezone":"UTC"}}}');
SELECT 'month_ref_bin_end' AS case_id, * FROM bson_dollar_project('{}', '{"result":{"$dateTrunc":{"date":{"$date":{"$numberLong":"951868799999"}},"unit":"month","binSize":{"$numberLong":"2"},"timezone":"UTC"}}}');
SELECT 'month_ref_exact' AS case_id, * FROM bson_dollar_project('{}', '{"result":{"$dateTrunc":{"date":{"$date":{"$numberLong":"946684800000"}},"unit":"month","binSize":{"$numberLong":"2"},"timezone":"UTC"}}}');
SELECT 'month_ref_next' AS case_id, * FROM bson_dollar_project('{}', '{"result":{"$dateTrunc":{"date":{"$date":{"$numberLong":"951868800000"}},"unit":"month","binSize":{"$numberLong":"2"},"timezone":"UTC"}}}');
SELECT 'month_timezone_east' AS case_id, * FROM bson_dollar_project('{}', '{"result":{"$dateTrunc":{"date":{"$date":{"$numberLong":"1709236800000"}},"unit":"month","binSize":{"$numberLong":"1"},"timezone":"Asia/Kolkata"}}}');
SELECT 'month_timezone_west' AS case_id, * FROM bson_dollar_project('{}', '{"result":{"$dateTrunc":{"date":{"$date":{"$numberLong":"1709263800000"}},"unit":"month","binSize":{"$numberLong":"1"},"timezone":"America/New_York"}}}');
SELECT 'month_variable_2001' AS case_id, * FROM bson_dollar_project('{}', '{"result":{"$dateTrunc":{"date":{"$date":{"$numberLong":"986083199999"}},"unit":"month","binSize":{"$numberLong":"1"},"timezone":"UTC"}}}');

-- Quarter truncation, including a fully dynamic case and timezone boundaries.
SELECT 'quarter_2026_q1' AS case_id, * FROM bson_dollar_project('{"input":{"$date":{"$numberLong":"1771158896000"}},"unit":"quarter","binSize":{"$numberLong":"1"},"timezone":"UTC","startOfWeek":"sunday"}', '{"result":{"$dateTrunc":{"date":"$input","unit":"$unit","binSize":"$binSize","timezone":"$timezone","startOfWeek":"$startOfWeek"}}}');
SELECT 'quarter_2026_q2' AS case_id, * FROM bson_dollar_project('{}', '{"result":{"$dateTrunc":{"date":{"$date":{"$numberLong":"1778848496000"}},"unit":"quarter","binSize":{"$numberLong":"1"},"timezone":"UTC"}}}');
SELECT 'quarter_2026_q3' AS case_id, * FROM bson_dollar_project('{}', '{"result":{"$dateTrunc":{"date":{"$date":{"$numberLong":"1786797296000"}},"unit":"quarter","binSize":{"$numberLong":"1"},"timezone":"UTC"}}}');
SELECT 'quarter_2026_q4' AS case_id, * FROM bson_dollar_project('{}', '{"result":{"$dateTrunc":{"date":{"$date":{"$numberLong":"1794746096000"}},"unit":"quarter","binSize":{"$numberLong":"1"},"timezone":"UTC"}}}');
SELECT 'quarter_bin_2' AS case_id, * FROM bson_dollar_project('{}', '{"result":{"$dateTrunc":{"date":{"$date":{"$numberLong":"1794746096000"}},"unit":"quarter","binSize":{"$numberLong":"2"},"timezone":"UTC"}}}');
SELECT 'quarter_ref_before' AS case_id, * FROM bson_dollar_project('{}', '{"result":{"$dateTrunc":{"date":{"$date":{"$numberLong":"946684799999"}},"unit":"quarter","binSize":{"$numberLong":"2"},"timezone":"UTC"}}}');
SELECT 'quarter_ref_bin_end' AS case_id, * FROM bson_dollar_project('{}', '{"result":{"$dateTrunc":{"date":{"$date":{"$numberLong":"962409599999"}},"unit":"quarter","binSize":{"$numberLong":"2"},"timezone":"UTC"}}}');
SELECT 'quarter_ref_exact' AS case_id, * FROM bson_dollar_project('{}', '{"result":{"$dateTrunc":{"date":{"$date":{"$numberLong":"946684800000"}},"unit":"quarter","binSize":{"$numberLong":"2"},"timezone":"UTC"}}}');
SELECT 'quarter_ref_next' AS case_id, * FROM bson_dollar_project('{}', '{"result":{"$dateTrunc":{"date":{"$date":{"$numberLong":"962409600000"}},"unit":"quarter","binSize":{"$numberLong":"2"},"timezone":"UTC"}}}');
SELECT 'quarter_timezone_west' AS case_id, * FROM bson_dollar_project('{}', '{"result":{"$dateTrunc":{"date":{"$date":{"$numberLong":"1711942200000"}},"unit":"quarter","binSize":{"$numberLong":"1"},"timezone":"America/New_York"}}}');

-- Second truncation, including a fully dynamic case and reference boundaries.
SELECT 'second_bin_1' AS case_id, * FROM bson_dollar_project('{"input":{"$date":{"$numberLong":"1707113755381"}},"unit":"second","binSize":{"$numberLong":"1"},"timezone":"UTC","startOfWeek":"sunday"}', '{"result":{"$dateTrunc":{"date":"$input","unit":"$unit","binSize":"$binSize","timezone":"$timezone","startOfWeek":"$startOfWeek"}}}');
SELECT 'second_bin_10' AS case_id, * FROM bson_dollar_project('{}', '{"result":{"$dateTrunc":{"date":{"$date":{"$numberLong":"1707113755381"}},"unit":"second","binSize":{"$numberLong":"10"},"timezone":"UTC"}}}');
SELECT 'second_bin_90' AS case_id, * FROM bson_dollar_project('{}', '{"result":{"$dateTrunc":{"date":{"$date":{"$numberLong":"1707113755381"}},"unit":"second","binSize":{"$numberLong":"90"},"timezone":"UTC"}}}');
SELECT 'second_ref_before' AS case_id, * FROM bson_dollar_project('{}', '{"result":{"$dateTrunc":{"date":{"$date":{"$numberLong":"946684799999"}},"unit":"second","binSize":{"$numberLong":"10"},"timezone":"UTC"}}}');
SELECT 'second_ref_bin_end' AS case_id, * FROM bson_dollar_project('{}', '{"result":{"$dateTrunc":{"date":{"$date":{"$numberLong":"946684809999"}},"unit":"second","binSize":{"$numberLong":"10"},"timezone":"UTC"}}}');
SELECT 'second_ref_exact' AS case_id, * FROM bson_dollar_project('{}', '{"result":{"$dateTrunc":{"date":{"$date":{"$numberLong":"946684800000"}},"unit":"second","binSize":{"$numberLong":"10"},"timezone":"UTC"}}}');
SELECT 'second_ref_next' AS case_id, * FROM bson_dollar_project('{}', '{"result":{"$dateTrunc":{"date":{"$date":{"$numberLong":"946684810000"}},"unit":"second","binSize":{"$numberLong":"10"},"timezone":"UTC"}}}');

-- Week truncation, including defaults, anchors, large 64-bit bins, abbreviations, and timezones.
SELECT 'week_default_sunday' AS case_id, * FROM bson_dollar_project('{}', '{"result":{"$dateTrunc":{"date":{"$date":{"$numberLong":"1707309296000"}},"unit":"week"}}}');
SELECT 'week_ref_before' AS case_id, * FROM bson_dollar_project('{}', '{"result":{"$dateTrunc":{"date":{"$date":{"$numberLong":"946857599999"}},"unit":"week","binSize":{"$numberLong":"2"},"timezone":"UTC","startOfWeek":"monday"}}}');
SELECT 'week_ref_bin_end' AS case_id, * FROM bson_dollar_project('{}', '{"result":{"$dateTrunc":{"date":{"$date":{"$numberLong":"948067199999"}},"unit":"week","binSize":{"$numberLong":"2"},"timezone":"UTC","startOfWeek":"monday"}}}');
SELECT 'week_ref_exact' AS case_id, * FROM bson_dollar_project('{}', '{"result":{"$dateTrunc":{"date":{"$date":{"$numberLong":"946857600000"}},"unit":"week","binSize":{"$numberLong":"2"},"timezone":"UTC","startOfWeek":"monday"}}}');
SELECT 'week_large_bin_after_ref' AS case_id, * FROM bson_dollar_project('{}', '{"result":{"$dateTrunc":{"date":{"$date":{"$numberLong":"1784118896789"}},"unit":"week","binSize":{"$numberLong":"2147483648"},"timezone":"UTC","startOfWeek":"saturday"}}}');
SELECT 'week_large_bin_ref_exact' AS case_id, * FROM bson_dollar_project('{}', '{"result":{"$dateTrunc":{"date":{"$date":{"$numberLong":"946684800000"}},"unit":"week","binSize":{"$numberLong":"2147483648"},"timezone":"UTC","startOfWeek":"saturday"}}}');
SELECT 'week_ref_next' AS case_id, * FROM bson_dollar_project('{}', '{"result":{"$dateTrunc":{"date":{"$date":{"$numberLong":"948067200000"}},"unit":"week","binSize":{"$numberLong":"2"},"timezone":"UTC","startOfWeek":"monday"}}}');
SELECT 'week_start_fri_abbr' AS case_id, * FROM bson_dollar_project('{}', '{"result":{"$dateTrunc":{"date":{"$date":{"$numberLong":"1707309296000"}},"unit":"week","binSize":{"$numberLong":"1"},"timezone":"UTC","startOfWeek":"fri"}}}');
SELECT 'week_start_friday' AS case_id, * FROM bson_dollar_project('{}', '{"result":{"$dateTrunc":{"date":{"$date":{"$numberLong":"1707309296000"}},"unit":"week","binSize":{"$numberLong":"1"},"timezone":"UTC","startOfWeek":"friday"}}}');
SELECT 'week_start_mon_abbr' AS case_id, * FROM bson_dollar_project('{}', '{"result":{"$dateTrunc":{"date":{"$date":{"$numberLong":"1707309296000"}},"unit":"week","binSize":{"$numberLong":"1"},"timezone":"UTC","startOfWeek":"mon"}}}');
SELECT 'week_start_monday' AS case_id, * FROM bson_dollar_project('{}', '{"result":{"$dateTrunc":{"date":{"$date":{"$numberLong":"1707309296000"}},"unit":"week","binSize":{"$numberLong":"1"},"timezone":"UTC","startOfWeek":"monday"}}}');
SELECT 'week_start_saturday' AS case_id, * FROM bson_dollar_project('{}', '{"result":{"$dateTrunc":{"date":{"$date":{"$numberLong":"1707309296000"}},"unit":"week","binSize":{"$numberLong":"1"},"timezone":"UTC","startOfWeek":"saturday"}}}');
SELECT 'week_start_sunday' AS case_id, * FROM bson_dollar_project('{"input":{"$date":{"$numberLong":"1707309296000"}},"unit":"week","binSize":{"$numberLong":"1"},"timezone":"UTC","startOfWeek":"sunday"}', '{"result":{"$dateTrunc":{"date":"$input","unit":"$unit","binSize":"$binSize","timezone":"$timezone","startOfWeek":"$startOfWeek"}}}');
SELECT 'week_start_thursday' AS case_id, * FROM bson_dollar_project('{}', '{"result":{"$dateTrunc":{"date":{"$date":{"$numberLong":"1707309296000"}},"unit":"week","binSize":{"$numberLong":"1"},"timezone":"UTC","startOfWeek":"thursday"}}}');
SELECT 'week_start_tuesday' AS case_id, * FROM bson_dollar_project('{}', '{"result":{"$dateTrunc":{"date":{"$date":{"$numberLong":"1707309296000"}},"unit":"week","binSize":{"$numberLong":"1"},"timezone":"UTC","startOfWeek":"tuesday"}}}');
SELECT 'week_start_wed_abbr' AS case_id, * FROM bson_dollar_project('{}', '{"result":{"$dateTrunc":{"date":{"$date":{"$numberLong":"1707309296000"}},"unit":"week","binSize":{"$numberLong":"1"},"timezone":"UTC","startOfWeek":"WED"}}}');
SELECT 'week_start_wednesday' AS case_id, * FROM bson_dollar_project('{}', '{"result":{"$dateTrunc":{"date":{"$date":{"$numberLong":"1707309296000"}},"unit":"week","binSize":{"$numberLong":"1"},"timezone":"UTC","startOfWeek":"wednesday"}}}');
SELECT 'week_timezone_example_0' AS case_id, * FROM bson_dollar_project('{}', '{"result":{"$dateTrunc":{"date":{"$date":{"$numberLong":"1589811030000"}},"unit":"week","binSize":{"$numberLong":"2"},"timezone":"America/Los_Angeles","startOfWeek":"monday"}}}');
SELECT 'week_timezone_example_1' AS case_id, * FROM bson_dollar_project('{}', '{"result":{"$dateTrunc":{"date":{"$date":{"$numberLong":"1616239805000"}},"unit":"week","binSize":{"$numberLong":"2"},"timezone":"America/Los_Angeles","startOfWeek":"monday"}}}');
SELECT 'week_timezone_example_2' AS case_id, * FROM bson_dollar_project('{}', '{"result":{"$dateTrunc":{"date":{"$date":{"$numberLong":"1610346675000"}},"unit":"week","binSize":{"$numberLong":"2"},"timezone":"America/Los_Angeles","startOfWeek":"monday"}}}');
SELECT 'week_timezone_example_3' AS case_id, * FROM bson_dollar_project('{}', '{"result":{"$dateTrunc":{"date":{"$date":{"$numberLong":"1581167603000"}},"unit":"week","binSize":{"$numberLong":"2"},"timezone":"America/Los_Angeles","startOfWeek":"monday"}}}');
SELECT 'week_timezone_example_4' AS case_id, * FROM bson_dollar_project('{}', '{"result":{"$dateTrunc":{"date":{"$date":{"$numberLong":"1558195741000"}},"unit":"week","binSize":{"$numberLong":"2"},"timezone":"America/Los_Angeles","startOfWeek":"monday"}}}');
SELECT 'week_timezone_example_5' AS case_id, * FROM bson_dollar_project('{}', '{"result":{"$dateTrunc":{"date":{"$date":{"$numberLong":"1546927923000"}},"unit":"week","binSize":{"$numberLong":"2"},"timezone":"America/Los_Angeles","startOfWeek":"monday"}}}');

-- Year truncation, including a fully dynamic case and timezone boundaries.
SELECT 'year_bin_1' AS case_id, * FROM bson_dollar_project('{"input":{"$date":{"$numberLong":"1784118896000"}},"unit":"year","binSize":{"$numberLong":"1"},"timezone":"UTC","startOfWeek":"sunday"}', '{"result":{"$dateTrunc":{"date":"$input","unit":"$unit","binSize":"$binSize","timezone":"$timezone","startOfWeek":"$startOfWeek"}}}');
SELECT 'year_bin_10' AS case_id, * FROM bson_dollar_project('{}', '{"result":{"$dateTrunc":{"date":{"$date":{"$numberLong":"1784118896000"}},"unit":"year","binSize":{"$numberLong":"10"},"timezone":"UTC"}}}');
SELECT 'year_bin_2' AS case_id, * FROM bson_dollar_project('{}', '{"result":{"$dateTrunc":{"date":{"$date":{"$numberLong":"1784118896000"}},"unit":"year","binSize":{"$numberLong":"2"},"timezone":"UTC"}}}');
SELECT 'year_ref_before' AS case_id, * FROM bson_dollar_project('{}', '{"result":{"$dateTrunc":{"date":{"$date":{"$numberLong":"946684799999"}},"unit":"year","binSize":{"$numberLong":"2"},"timezone":"UTC"}}}');
SELECT 'year_ref_bin_end' AS case_id, * FROM bson_dollar_project('{}', '{"result":{"$dateTrunc":{"date":{"$date":{"$numberLong":"1009843199999"}},"unit":"year","binSize":{"$numberLong":"2"},"timezone":"UTC"}}}');
SELECT 'year_ref_exact' AS case_id, * FROM bson_dollar_project('{}', '{"result":{"$dateTrunc":{"date":{"$date":{"$numberLong":"946684800000"}},"unit":"year","binSize":{"$numberLong":"2"},"timezone":"UTC"}}}');
SELECT 'year_ref_next' AS case_id, * FROM bson_dollar_project('{}', '{"result":{"$dateTrunc":{"date":{"$date":{"$numberLong":"1009843200000"}},"unit":"year","binSize":{"$numberLong":"2"},"timezone":"UTC"}}}');
SELECT 'year_timezone_west' AS case_id, * FROM bson_dollar_project('{}', '{"result":{"$dateTrunc":{"date":{"$date":{"$numberLong":"1704079800000"}},"unit":"year","binSize":{"$numberLong":"1"},"timezone":"America/New_York"}}}');

-- End of $dateTrunc behavioral coverage.
