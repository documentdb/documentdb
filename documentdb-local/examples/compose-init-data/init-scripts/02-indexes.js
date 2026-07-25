// Create indexes for the seeded data. Runs after 01-books.js (alphabetical
// order).
print("Creating indexes on library.books...");

use('library');

db.books.createIndex({ author: 1 });
db.books.createIndex({ year: -1 });

print("Indexes created.");
