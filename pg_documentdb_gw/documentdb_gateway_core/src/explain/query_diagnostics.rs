/*-------------------------------------------------------------------------
 * Copyright (c) Microsoft Corporation.  All rights reserved.
 *
 * documentdb_gateway_core/src/explain/query_diagnostics.rs
 *
 *-------------------------------------------------------------------------
 */

use bson::RawDocumentBuf;
use regex::{CaptureMatches, Regex};

use crate::postgres::QueryCatalog;

static SHARD_KEY_VALUE_EXTRACT: std::sync::LazyLock<Regex> = std::sync::LazyLock::new(|| {
    #[expect(clippy::expect_used, reason = "static regex pattern")]
    Regex::new("shard_key_value (OPERATOR\\(pg_catalog.=\\)|=) '(\\d+)'::bigint")
        .expect("Static input")
});
static BSON_SUM_OF_ONE_OUTPUT_REGEX: std::sync::LazyLock<Regex> = std::sync::LazyLock::new(|| {
    #[expect(clippy::expect_used, reason = "static regex pattern")]
    Regex::new("^bsonsum\\(bson_expression_get\\(.+, 'BSONHEX13000000012473756d00000000000000f03f00'::bson, true\\)\\)?$").expect("Static input")
});
static EXPRESSION_GET_PROJECTION_REGEX: std::sync::LazyLock<Regex> = std::sync::LazyLock::new(
    || {
        #[expect(clippy::expect_used, reason = "static regex pattern")]
        Regex::new(
            r"bson_expression_get\(.*,\s*'BSONHEX(?P<projection>[\w\d]+)'::(?:\w+\.)?bson,\s*true(?:,|\))",
        )
        .expect("Static input")
    },
);

/// Matches a `$lookup` function wrapper around a BSON literal and tags the
/// operator so it maps to `$lookup_in`. Non-lookup wrappers are left untouched
/// and will naturally produce `$unknown`.
static LOOKUP_FUNCTION_BSON_REGEX: std::sync::LazyLock<Regex> = std::sync::LazyLock::new(|| {
    #[expect(clippy::expect_used, reason = "static regex pattern")]
    Regex::new(
        r"(OPERATOR\(\S*@\*=)(\)\s+)\S*bson_dollar_lookup\S*\([^')]*('BSONHEX[^']+'::\S+\.?bson)\)",
    )
    .expect("Static input")
});

#[expect(clippy::expect_used, reason = "static regex pattern")]
pub fn get_projection_type_output(
    output: &str,
    function_name: &str,
    query_catalog: &QueryCatalog,
) -> RawDocumentBuf {
    if let Some(result) = Regex::new(query_catalog.bson_dollar_project_output_regex())
        .expect("static input")
        .captures(output)
    {
        if result.len() == 4 && result.get(2).is_some_and(|x| x.as_str() == function_name) {
            if let Some(m) = result.get(3) {
                if let Ok(bytes) = hex::decode(m.as_str()) {
                    if let Ok(doc) = RawDocumentBuf::from_bytes(bytes) {
                        return doc;
                    }
                }
                tracing::warn!("Failed to parse hex string from explain");
            }
        }
    }
    RawDocumentBuf::new()
}

fn is_single_sharded_query(query: &str) -> bool {
    query.contains("shard_key_value OPERATOR(pg_catalog.=)") || query.contains("shard_key_value =")
}

pub fn is_unsharded_query(relation_name: &str, filter: &str) -> bool {
    if !is_single_sharded_query(filter) {
        return false;
    }
    if let Some(result) = SHARD_KEY_VALUE_EXTRACT.captures(filter) {
        let shard_key_value = result.get(2);
        if let Some(shard_key_value) = shard_key_value {
            return relation_name
                .starts_with(&("documents_".to_owned() + shard_key_value.as_str()));
        }
        return false;
    }

    false
}

pub fn has_shard_filter_query(filter: &str) -> bool {
    filter.contains("shard_key_value OPERATOR(pg_catalog.=)")
        || filter.contains("shard_key_value =")
}

pub fn is_output_count(output: &str, query_catalog: &QueryCatalog) -> bool {
    let output = output.replace(query_catalog.api_catalog_name_regex(), "");
    if output.contains("bson_repath_and_build")
        && output.contains("bsonsum('BSONHEX0b00000010000100000000'::bson)")
    {
        return true;
    }

    if output.contains(query_catalog.output_bson_count_aggregate())
        || output.contains(query_catalog.output_bson_command_count_aggregate())
        || output.contains(query_catalog.output_count_regex())
    {
        return true;
    }

    BSON_SUM_OF_ONE_OUTPUT_REGEX.is_match(&output)
}

#[expect(clippy::expect_used, reason = "static regex pattern")]
fn get_expressions(
    captures: CaptureMatches,
    query_catalog: &QueryCatalog,
) -> Vec<(&'static str, Option<String>, RawDocumentBuf)> {
    let mut expressions = vec![];
    for captures in captures {
        if let Some(capture) = captures.name("expr") {
            if let Some(index_condition) = Regex::new(query_catalog.single_index_condition_regex())
                .expect("static input")
                .captures(capture.as_str())
            {
                let field = index_condition.name("field").map_or("", |m| m.as_str());
                let operator =
                    get_operator(index_condition.name("operator").map_or("", |m| m.as_str()));
                let query_bson = index_condition.name("queryBson").map_or("", |m| m.as_str());
                let query = hex::decode(query_bson).unwrap_or(vec![]);
                let query_bson = RawDocumentBuf::from_bytes(query).unwrap_or_default();

                if field.contains("object_id") {
                    expressions.push((operator, Some("_id".to_owned()), query_bson));
                } else {
                    expressions.push((operator, None, query_bson));
                }
            }
        }
    }
    expressions
}

/// Tags `$lookup` function wrappers so the operator maps to `$lookup_in`.
/// Non-lookup function wrappers are left untouched and produce `$unknown`.
fn preprocess_conditions(input: &str) -> std::borrow::Cow<'_, str> {
    LOOKUP_FUNCTION_BSON_REGEX.replace_all(input, "${1}_lookup${2}${3}")
}

#[expect(clippy::expect_used, reason = "static regex pattern")]
pub fn get_runtime_conditions(
    input: &str,
    query_catalog: &QueryCatalog,
) -> Vec<(&'static str, Option<String>, RawDocumentBuf)> {
    let processed = preprocess_conditions(input);
    get_expressions(
        Regex::new(query_catalog.runtime_condition_split_regex())
            .expect("static input")
            .captures_iter(&processed),
        query_catalog,
    )
}

#[expect(clippy::expect_used, reason = "static regex pattern")]
pub fn get_index_conditions(
    input: &str,
    query_catalog: &QueryCatalog,
) -> Vec<(&'static str, Option<String>, RawDocumentBuf)> {
    let processed = preprocess_conditions(input);
    get_expressions(
        Regex::new(query_catalog.index_condition_split_regex())
            .expect("static input")
            .captures_iter(&processed),
        query_catalog,
    )
}

#[expect(clippy::expect_used, reason = "static regex pattern")]
pub fn get_sort_conditions(input: &str, query_catalog: &QueryCatalog) -> Option<RawDocumentBuf> {
    let sort_regex = Regex::new(query_catalog.sort_condition_split_regex())
        .expect("static input")
        .captures(input);

    if let Some(capture) = sort_regex {
        return decode_document(capture.name("sortSpec")?.as_str());
    }

    EXPRESSION_GET_PROJECTION_REGEX
        .captures(input)
        .and_then(|capture| capture.name("projection"))
        .and_then(|projection| decode_document(projection.as_str()))
}

#[expect(clippy::expect_used, reason = "static regex pattern")]
pub fn get_sort_collation<'a>(input: &'a str, query_catalog: &QueryCatalog) -> Option<&'a str> {
    Regex::new(query_catalog.sort_condition_split_regex())
        .expect("static input")
        .captures(input)
        .and_then(|capture| capture.name("collation"))
        .map(|collation| collation.as_str())
}

pub fn get_group_key(input: &str) -> Option<RawDocumentBuf> {
    EXPRESSION_GET_PROJECTION_REGEX
        .captures(input)
        .and_then(|capture| capture.name("projection"))
        .and_then(|projection| decode_document(projection.as_str()))
}

fn decode_document(hex_string: &str) -> Option<RawDocumentBuf> {
    hex::decode(hex_string)
        .ok()
        .and_then(|bytes| RawDocumentBuf::from_bytes(bytes).ok())
}

fn get_operator(input: &str) -> &'static str {
    match input {
        "@=" | "=" | "#=" => "$eq",
        "@>" | ">" | "#>" => "$gt",
        "@>=" | ">=" | "#>=" => "$gte",
        "@<" | "<" | "#<" => "$lt",
        "@<=" | "<=" | "#<=" => "$lte",
        "@*=" => "$in",
        "@*=_lookup" => "$lookup_in",
        "@!=" => "$ne",
        "@!*=" => "$nin",
        "@~" => "$regExp",
        "@?" => "$exists",
        "@@#" => "$size",
        "@#" => "$type",
        "@&=" => "$all",
        "@!&" => "$bitsAllClear",
        "@!|" => "$bitsAnyClear",
        "@#?" => "$elemMatch",
        "@&" => "$bitsAllSet",
        "@|" => "$bitsAnySet",
        "@%" => "$mod",
        "@<>" => "$range",
        "@#%" => "$text",
        "@|-|" => "$geoWithin",
        "@|#|" => "$geoIntersects",
        "@|><|" => "$_minMaxDistance", // This is only for explain to show either $minDistance or $maxDistance was used
        _ => "$unknown",
    }
}

#[cfg(test)]
mod tests {
    use crate::{explain::query_diagnostics::get_sort_conditions, postgres::create_query_catalog};

    #[test]
    fn sort_condition_supports_collation_argument() {
        let query_catalog = create_query_catalog();
        let condition = "(documentdb_api_internal.bson_orderby_index_reverse(\
            agg_stage.document, \
            'BSONHEX0c0000001063000100000000'::documentdb_core.bson, \
            'en-u-ks-level2'::text)) DESC NULLS LAST";

        let Some(sort_specification) = get_sort_conditions(condition, &query_catalog) else {
            panic!("the static sort condition should parse");
        };

        assert_eq!(sort_specification.get_i32("c"), Ok(1));
        assert_eq!(
            super::get_sort_collation(condition, &query_catalog),
            Some("en-u-ks-level2")
        );
    }

    #[test]
    fn sort_condition_supports_nested_first_argument() {
        let query_catalog = create_query_catalog();
        let condition = "(documentdb_api_internal.bson_orderby(\
            documentdb_api_catalog.bson_repath_and_build(c1, c2, c3), \
            'BSONHEX0c000000106300ffffffff00'::documentdb_core.bson))";

        let Some(sort_specification) = get_sort_conditions(condition, &query_catalog) else {
            panic!("the static sort condition should parse");
        };

        assert_eq!(sort_specification.get_i32("c"), Ok(-1));
    }

    #[test]
    fn expression_projection_is_used_for_group_sort_and_group_key() {
        let query_catalog = create_query_catalog();
        let expression = "(documentdb_api_internal.bson_expression_get(\
            collection.document, \
            'BSONHEX0e00000002000300000024620000'::documentdb_core.bson, \
            true, \
            'BSONHEX0500000000'::documentdb_core.bson))";

        let Some(sort_specification) = get_sort_conditions(expression, &query_catalog) else {
            panic!("the static group sort condition should parse");
        };
        let Some(group_key) = super::get_group_key(expression) else {
            panic!("the static group key should parse");
        };

        assert_eq!(sort_specification.get_str(""), Ok("$b"));
        assert_eq!(group_key.get_str(""), Ok("$b"));
    }

    #[test]
    fn collation_metadata_is_separate_from_sort_field_with_same_name() {
        let query_catalog = create_query_catalog();
        let condition = "(documentdb_api_internal.bson_orderby(\
            collection.document, \
            'BSONHEX1400000010636f6c6c6174696f6e000100000000'::documentdb_core.bson, \
            'en-u-ks-level2'::text))";

        let Some(sort_specification) = get_sort_conditions(condition, &query_catalog) else {
            panic!("the static sort condition should parse");
        };

        assert_eq!(sort_specification.get_i32("collation"), Ok(1));
        assert_eq!(
            super::get_sort_collation(condition, &query_catalog),
            Some("en-u-ks-level2")
        );
    }
}
