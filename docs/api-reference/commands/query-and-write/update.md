---
title: update
description: The update commands in DocumentDB modify documents within a collection that match specific filters
type: commands
category: query-and-write
---

# update

The `update` command is used to modify existing documents within a collection. The `update` command can be used to update one or multiple documents based on filtering criteria. Values of fields can be changed, new fields and values can be added and existing fields can be removed.

## Example(s)

Consider this sample document from the stores collection in the StoreData database.

```json
{
    "_id": "0fcc0bf0-ed18-4ab8-b558-9848e18058f4",
    "name": "First Up Consultants | Beverage Shop - Satterfieldmouth",
    "location": {
        "lat": -89.2384,
        "lon": -46.4012
    },
    "staff": {
        "totalStaff": {
            "fullTime": 8,
            "partTime": 20
        }
    },
    "sales": {
        "totalSales": 75670,
        "salesByCategory": [
            {
                "categoryName": "Wine Accessories",
                "totalSales": 34440
            },
            {
                "categoryName": "Bitters",
                "totalSales": 39496
            },
            {
                "categoryName": "Rum",
                "totalSales": 1734
            }
        ]
    },
    "promotionEvents": [
        {
            "eventName": "Unbeatable Bargain Bash",
            "promotionalDates": {
                "startDate": {
                    "Year": 2024,
                    "Month": 6,
                    "Day": 23
                },
                "endDate": {
                    "Year": 2024,
                    "Month": 7,
                    "Day": 2
                }
            },
            "discounts": [
                {
                    "categoryName": "Whiskey",
                    "discountPercentage": 7
                },
                {
                    "categoryName": "Bitters",
                    "discountPercentage": 15
                },
                {
                    "categoryName": "Brandy",
                    "discountPercentage": 8
                },
                {
                    "categoryName": "Sports Drinks",
                    "discountPercentage": 22
                },
                {
                    "categoryName": "Vodka",
                    "discountPercentage": 19
                }
            ]
        },
        {
            "eventName": "Steal of a Deal Days",
            "promotionalDates": {
                "startDate": {
                    "Year": 2024,
                    "Month": 9,
                    "Day": 21
                },
                "endDate": {
                    "Year": 2024,
                    "Month": 9,
                    "Day": 29
                }
            },
            "discounts": [
                {
                    "categoryName": "Organic Wine",
                    "discountPercentage": 19
                },
                {
                    "categoryName": "White Wine",
                    "discountPercentage": 20
                },
                {
                    "categoryName": "Sparkling Wine",
                    "discountPercentage": 19
                },
                {
                    "categoryName": "Whiskey",
                    "discountPercentage": 17
                },
                {
                    "categoryName": "Vodka",
                    "discountPercentage": 23
                }
            ]
        }
    ]
}
```

### Example 1 - Update a single document using the $inc operator

Increment the totalSales by 10 and decrement the number of full time staff for a document with the specified _id.

```javascript
db.stores.updateOne({"_id": "0fcc0bf0-ed18-4ab8-b558-9848e18058f4"}, {"$inc": {"sales.salesByCategory.0.totalSales": 10, "staff.totalStaff.fullTime": -6}})
```

### Example 2 - Update a single document using the $min operator

Update the totalStaff count for the document with the specified _id to 10 if the current value of the field is greater than 10.

```javascript
db.stores.updateOne({"_id": "0fcc0bf0-ed18-4ab8-b558-9848e18058f4"}, {"$min": {"staff.totalStaff.fullTime": 10}})
```

### Example 3 - Update a single document using the $max operator

Update the totalStaff count for the document with the specified _id to 14 if the current value of the field is less than 14.

```javascript
db.stores.updateOne({"_id": "0fcc0bf0-ed18-4ab8-b558-9848e18058f4"}, {"$max": {"staff.totalStaff.fullTime": 14}})
```

### Example 4 - Update a single document using the $mul operator

Multiple the count of part time employees by 2 for the document with the specified _id value.

```javascript
db.stores.updateOne({"_id": "0fcc0bf0-ed18-4ab8-b558-9848e18058f4"}, {"$mul": {"staff.totalStaff.partTime": 2}})
```

### Example 5 - Update a single document using the $rename operator

Rename the totalSales and totalStaff fields to fullSales and staffCounts respectively.

```javascript
db.stores.updateOne({"_id": "0fcc0bf0-ed18-4ab8-b558-9848e18058f4"}, {"$rename": {"sales.totalSales": "sales.fullSales", "staff.totalStaff": "staff.staffCounts"}})
```

### Example 6 - Update a single document using the $set operator

Set the fullSales field to 3700 for the document with the specified _id value.

```javascript
db.stores.updateOne({"_id": "0fcc0bf0-ed18-4ab8-b558-9848e18058f4"}, {"$set": {"sales.fullSales": 3700}})
```

### Example 7 - Update a single document using the $unset operator

Remove the lon field from the location object in the document with the specified _id value.

```javascript
db.stores.updateOne({"_id": "0fcc0bf0-ed18-4ab8-b558-9848e18058f4"}, {"$unset": {"location.lon": ""}})
```

### Example 8 - Update multiple documents

Update all documents where the first promotional event starts in February to start in March.

```javascript
db.stores.updateMany({"promotionEvents.0.promotionalDates.startDate.Month": 2}, {"$inc": {"promotionEvents.0.promotionalDates.startDate.Month": 1}})
```

### Example 9 - Upsert a single document

Set the upsert flag to true to create a new document if the document specified in the query filter does not exist in the collection.

```javascript
db.stores.updateOne({"_id": "NonExistentDocId"}, {"$set": {"name": "Lakeshore Retail", "sales.totalSales": 0}}, {"upsert": true})
```

## Related content

- [insert with DocumentDB](insert)
- [delete with DocumentDB](delete)
