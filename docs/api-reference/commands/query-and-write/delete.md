---
title: delete
description: The delete command in DocumentDB deletes documents that match a specified criteria
type: commands
category: query-and-write
---

# delete

The `delete` command is used to remove documents from a collection. A single document or multiple documents can be deleted based on a specified query filter.

## Syntax

The basic syntax for the `delete` command is as follows:

```javascript
db.collection.deleteOne(
   <filter>,
   <options>
)

db.collection.deleteMany(
   <filter>,
   <options>
)
```

### Parameters

| Parameter | Description |
| --- | --- |
| **<`filter`>** | A document that specifies the criteria for deletion. Only the documents that match the filter are deleted|
| **`options`** | Optional. A document that specifies options for the delete operation. Common options include writeConcern and collation|

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

### Example 1 - Delete all documents in a collection

```javascript
db.stores.deleteMany({})
```

### Example 2 - Delete a document that matches a specified query filter

```javascript
db.stores.deleteOne({"_id": "68471088-4d45-4164-ae58-a9428d12f310"})
```

### Example 3 - Delete all documents that match a specified query filter

```javascript
db.stores.deleteMany({"promotionEvents.discounts.discountPercentage": 21}, {"limit": 0})
```

### Example 3 - Delete only one of many documents that match a specified query filter

```javascript
db.stores.deleteMany({"promotionEvents.discounts.discountPercentage": 21}, {"limit": 1})
```

## Related content

- [insert with DocumentDB](insert)
- [update with DocumentDB](update)
