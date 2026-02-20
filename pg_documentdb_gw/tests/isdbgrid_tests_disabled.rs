/*-------------------------------------------------------------------------
 *
 * tests/isdbgrid_tests_disabled.rs
 *
 * Tests isdbgrid when disabled.
 *
 *-------------------------------------------------------------------------
 */

use bson::doc;
use documentdb_gateway::error::ErrorCode;

pub mod common;

#[tokio::test]
async fn test_isdbgrid_disabled() {
    let config = common::setup_configuration_with_dynamic_config(r#"{"IsMongoSharded": false}"#);

    let client = common::initialize_with_config(config).await;
    let db = client.database("test_isdbgrid_disabled");

    let hello_result = db.run_command(doc! { "hello": 1 }).await.unwrap();
    assert!(
        !hello_result.contains_key("msg"),
        "hello should NOT contain 'msg' field when isdbgrid is disabled"
    );
    assert_eq!(hello_result.get_f64("ok").unwrap(), 1.0);

    // When disabled, isdbgrid command should fail with error (like mongod)
    let result = db.run_command(doc! { "isdbgrid": 1 }).await;
    match result {
        Err(e) => {
            if let mongodb::error::ErrorKind::Command(ref command_error) = *e.kind {
                let expected_code = ErrorCode::CommandNotSupported as i32;
                assert_eq!(
                    command_error.code, expected_code,
                    "Expected error code {expected_code} (CommandNotSupported), got: {}",
                    command_error.code
                );
                assert!(
                    command_error.message.contains("no such cmd: isdbgrid"),
                    "Expected error message to contain 'no such cmd: isdbgrid', got: {}",
                    command_error.message
                );
            } else {
                panic!("Expected Command error kind, got: {e:?}");
            }
        }
        Ok(_) => panic!("Expected error but isdbgrid command succeeded"),
    }
}
