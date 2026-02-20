/*-------------------------------------------------------------------------
 *
 * tests/isdbgrid_tests_enabled.rs
 *
 * Tests isdbgrid default behavior (enabled by default).
 *
 *-------------------------------------------------------------------------
 */

use bson::doc;

pub mod common;

#[tokio::test]
async fn test_isdbgrid_default_behavior() {
    let config = common::setup_configuration();

    let client = common::initialize_with_config(config).await;
    let db = client.database("test_isdbgrid_default");

    // hello response should contain "msg": "isdbgrid" by default
    let hello_result = db.run_command(doc! { "hello": 1 }).await.unwrap();
    assert_eq!(
        hello_result.get_str("msg").unwrap(),
        "isdbgrid",
        "hello should contain 'msg': 'isdbgrid' by default"
    );
    assert_eq!(hello_result.get_f64("ok").unwrap(), 1.0);

    // isdbgrid command should succeed by default
    let isdbgrid_result = db.run_command(doc! { "isdbgrid": 1 }).await.unwrap();
    assert_eq!(
        isdbgrid_result.get_f64("isdbgrid").unwrap(),
        1.0,
        "isdbgrid command should return 1.0 by default"
    );
    assert_eq!(isdbgrid_result.get_f64("ok").unwrap(), 1.0);
}
