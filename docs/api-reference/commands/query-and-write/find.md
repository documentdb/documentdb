---
title: find
description: The find command in DocumentDB returns documents that match a specified filter criteria
type: commands
category: query-and-write
---

# find

The `find` command in DocumentDB is used to query documents within a collection. This command is fundamental for data retrieval operations and can be customized with filters, projections, and query options to fine-tune the results.

## Syntax

The basic syntax for the `find` command is:

```javascript
db.collection.find(query, projection, options)
```

### Parameters

| Parameter | Description |
| --- | --- |
| **`query`** | A document that specifies the criteria for the documents to be retrieved|
| **`projection`** | (Optional) A document that specifies the fields in the matching documents to be returned in the result set|
| **`options`** | (Optional) A document that specifies options for query behavior and results|

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

### Example 1: Retrieve all documents

The find() command without any query filters returns all documents in the collection.

```javascript
db.stores.find()
```

### Example 2: Retrieve documents with query filters

Retrieve documents using a filter on the name property.

```javascript
db.stores.find({"name": "Fourth Coffee | Stationery Haven - New Franco"})
```

### Example 3: Retrieve documents with query filters on objects

Retrieve documents using query filters on the lat and lon fields within the location object.

```javascript
db.stores.find({"location.lat": 13.5236, "location.lon": -82.5707})
```

When the dot (.) notation isn't used to reference fields within an object, the query filter should exactly match the entire object including the order of the fields.

```javascript
db.stores.find({"location": {"lat": 13.5236, "lon": -82.5707}})
```

### Example 4: Retrieve documents with query filters on arrays

Retrieve documents from the promotionEvents array where the eventName is "Grand Bargain Gala".

```javascript
db.stores.find({"promotionEvents.eventName": "Grand Bargain Gala"})
```

Retrieve documents from the "discounts" array, which is nested within the promotionEvents array where the categoryName is "Area Rugs".

```javascript
db.stores.find({"promotionEvents.discounts.categoryName": "Area Rugs"})
```

## Projections

The second document in the find command specifies the list of fields to project in the response.

### Include a specific field or multiple fields in the response

A non-zero integer value or a boolean value of true includes the field in the response.

```javascript
db.stores.find({"name": "Fourth Coffee | Stationery Haven - New Franco"}, {"location": 1, "sales": 1})
```

```javascript
db.stores.find({"name": "Fourth Coffee | Stationery Haven - New Franco"}, {"location": true, "sales": true})
```

```javascript
db.stores.find({"name": "Fourth Coffee | Stationery Haven - New Franco"}, {"location": 1, "sales": true})
```

```javascript
db.stores.find({"name": "Fourth Coffee | Stationery Haven - New Franco"}, {"location": 1, "sales": -5})
```

All four queries are equivalent and specify the inclusion of the "location" and "sales" fields in the server response.

```json
{
    "_id": "b5c9f932-4efa-49fd-86ba-b35624d80d95",
    "location": {
        "lat": 13.5236,
        "lon": -82.5707
    },
    "sales": {
        "totalSales": 35346,
        "salesByCategory": [
            {
                "categoryName": "Rulers",
                "totalSales": 35346
            }
        ]
    }
}
```

### Exclude a specific field or multiple fields in the response

An integer value of zero or a boolean value of false excludes the specified field from the query response.

```javascript
db.stores.find({"name": "Fourth Coffee | Stationery Haven - New Franco"}, {"promotionEvents": 0, "location": 0, "sales": 0})
```

```javascript
db.stores.find({"name": "Fourth Coffee | Stationery Haven - New Franco"}, {"promotionEvents": false, "location": false, "sales": false})
```

Both queries are equivalent and return the following response:

```json
{
    "_id": "b5c9f932-4efa-49fd-86ba-b35624d80d95",
    "name": "Fourth Coffee | Stationery Haven - New Franco",
    "staff": {
        "totalStaff": {
            "fullTime": 17,
            "partTime": 5
        }
    }
}
```

> [!NOTE]
> By default, the _id field is included in the server response. The projection document cannot contain both inclusion and exclusion clauses. However, the _id field is the only exception to this rule and can be excluded along with a list of fields to include and vice versa.

### Project the first element in an array that matches the query filter criteria

The "arrayFieldName".$ command projects only the first occurrence of an object in an array that matches the specified query filters.

```javascript
db.stores.find({"promotionEvents.eventName": "Grand Bargain Gala"}, {"promotionEvents.$": true})
```

One of the documents returned shows only the first element in the promotionEvents array that has the event name "Grand Bargain Gala" while excluding all other elements in the array.

```json
{
    "_id": "d7fe6fb9-57e8-471a-b8d2-714e3579a415",
    "promotionEvents": [
        {
            "eventName": "Grand Bargain Gala",
            "promotionalDates": {
                "startDate": {
                    "Year": 2024,
                    "Month": 3,
                    "Day": 25
                },
                "endDate": {
                    "Year": 2024,
                    "Month": 4,
                    "Day": 1
                }
            },
            "discounts": [
                {
                    "categoryName": "Area Rugs",
                    "discountPercentage": 7
                },
                {
                    "categoryName": "Vinyl Flooring",
                    "discountPercentage": 12
                }
            ]
        }
    ]
}
```

### Project specific elements in an array that match the query filter criteria

This query projects the eventName property and the nested Year property within the promotionEvents array.

```javascript
db.stores.find({"promotionEvents.eventName": "Grand Bargain Gala"}, {"promotionEvents.eventName": true, "promotionEvents.promotionalDates.startDate.Year": true})
```

One of the documents returned shows the specified array elements projected in the response.

```json
{
    "_id": "d7fe6fb9-57e8-471a-b8d2-714e3579a415",
    "promotionEvents": [
        {
            "eventName": "Grand Bargain Gala",
            "promotionalDates": {
                "startDate": {
                    "Year": 2024
                }
            }
        },
        {
            "eventName": "Grand Bargain Bash",
            "promotionalDates": {
                "startDate": {
                    "Year": 2024
                }
            }
        },
        {
            "eventName": "Epic Bargain Bash",
            "promotionalDates": {
                "startDate": {
                    "Year": 2024
                }
            }
        }
    ]
}
```

## Related content

- [insert with DocumentDB](insert)
- [update with DocumentDB](update)
