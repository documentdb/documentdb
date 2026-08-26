-- Global local retryable writes table, replacing per-collection retry tables.
CREATE TABLE __API_DATA_SCHEMA__.retryable_writes (
    collection_id bigint NOT NULL,
    shard_key_value bigint NOT NULL,
    transaction_id text NOT NULL,
    object_id __CORE_SCHEMA__.bson,
    rows_affected bool NOT NULL,
    write_time timestamptz DEFAULT now(),
    result_document __CORE_SCHEMA__.bson NULL,
    PRIMARY KEY (collection_id, shard_key_value, transaction_id)
);

CREATE INDEX ON __API_DATA_SCHEMA__.retryable_writes (collection_id, object_id);

ALTER TABLE __API_DATA_SCHEMA__.retryable_writes OWNER TO __API_ADMIN_ROLE__;
