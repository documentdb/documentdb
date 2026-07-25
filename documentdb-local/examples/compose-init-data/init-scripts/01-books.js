// Seed the `library` database with a small books collection.
//
// Runs once per fresh data volume (see compose.yaml). Keep seed scripts
// idempotent anyway -- they are the kind of file that gets copied into other
// projects and re-run in unexpected ways.
print("Seeding library.books...");

use('library');

db.books.insertMany([
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
]);

print("Seeded " + db.books.countDocuments() + " books.");
