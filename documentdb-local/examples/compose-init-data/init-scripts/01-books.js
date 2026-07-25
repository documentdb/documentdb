// Seed the `library` database with a small books collection.
//
// Written to be idempotent (each insert is guarded by an existence check):
// current images run seed scripts once per fresh data volume, but images
// published before the one-shot markers existed (#612) re-ran them on every
// boot -- a plain insertMany with fixed _ids would crash such a container on
// restart with duplicate-key errors. Idempotent seeds work everywhere, and
// survive being copied into other projects and re-run in unexpected ways.
print("Seeding library.books...");

use('library');

const books = [
    {
        _id: "book1",
        title: "The Left Hand of Darkness",
        author: "Ursula K. Le Guin",
        year: 1969,
        genres: ["science fiction"],
        available: true
    },
    {
        _id: "book2",
        title: "Invisible Cities",
        author: "Italo Calvino",
        year: 1972,
        genres: ["fiction", "fantasy"],
        available: true
    },
    {
        _id: "book3",
        title: "The Dispossessed",
        author: "Ursula K. Le Guin",
        year: 1974,
        genres: ["science fiction"],
        available: false
    }
];

books.forEach(function (doc) {
    if (db.books.countDocuments({ _id: doc._id }) === 0) {
        db.books.insertOne(doc);
    }
});

print("Seeded " + db.books.countDocuments() + " books.");
