// Load the bundled StoreData Extended JSON exports.
print("Initializing StoreData collections...");

const fs = require("fs");
const path = require("path");
const zlib = require("zlib");

const database = db.getSiblingDB("StoreData");
const batchSize = 250;
const duplicateKeyCode = 11000;
const initFile = process.env.DOCUMENTDB_INIT_FILE ||
    path.join(process.cwd(), "01-store-data.js");
const sampleDataDirectory = path.dirname(initFile);

function readExtendedJson(fileName, expectedCount) {
    const filePath = path.join(sampleDataDirectory, fileName);
    const compressed = fs.readFileSync(filePath);
    const documents = EJSON.parse(zlib.gunzipSync(compressed).toString("utf8"));

    if (!Array.isArray(documents) || documents.length !== expectedCount) {
        throw new Error(
            `${fileName} must contain exactly ${expectedCount} documents`
        );
    }

    return documents;
}

function insertMissingDocuments(collectionName, documents) {
    const collection = database.getCollection(collectionName);

    for (let offset = 0; offset < documents.length; offset += batchSize) {
        const batch = documents.slice(offset, offset + batchSize);
        const result = database.runCommand({
            insert: collectionName,
            documents: batch,
            ordered: false
        });

        if (result.ok !== 1) {
            throw new Error(
                `Failed to insert ${collectionName} batch at offset ${offset}: ` +
                EJSON.stringify(result)
            );
        }

        const unexpectedErrors = (result.writeErrors || []).filter(
            error => error.code !== duplicateKeyCode
        );
        if (unexpectedErrors.length > 0) {
            throw new Error(
                `Failed to insert ${collectionName} batch at offset ${offset}: ` +
                EJSON.stringify(unexpectedErrors)
            );
        }
    }

    print(
        `${collectionName}: ${collection.countDocuments({})} documents available`
    );
}

insertMissingDocuments(
    "stores",
    readExtendedJson("StoreData.stores.json.gz", 41505)
);
insertMissingDocuments(
    "ratings",
    readExtendedJson("StoreData.ratings.json.gz", 2)
);

print("StoreData initialization completed");
