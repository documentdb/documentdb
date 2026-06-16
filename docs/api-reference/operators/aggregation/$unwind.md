---
title: $unwind
description: The $unwind stage in the aggregation framework is used to deconstruct an array field from the input documents to output a document for each element.
type: operators
category: aggregation
---

# $unwind

The $unwind stage in the aggregation framework is used to deconstruct an array field from the input documents to output a document for each element. Each output document is a copy of the original but with the value of the array field replaced by a single element. This is particularly useful for normalizing data stored in arrays and for performing operations on each element of an array separately.

## Syntax

```javascript
{
  $unwind: {
    path: <field path>,
    includeArrayIndex: <string>, // Optional
    preserveNullAndEmptyArrays: <boolean> // Optional
  }
}
```

## Parameters

| Parameter | Description |
| --- | --- |
| **`path`** | The field path to an array field. This is a required parameter. |
| **`includeArrayIndex`** | Optional. The name of a new field to hold the array index of the unwound element. |
| **`preserveNullAndEmptyArrays`** | Optional. If true, if the path is null, missing, or an empty array, `$unwind` outputs the document unchanged. |

## Examples

Consider this sample document from the stores collection.

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

### Example 1: Unwind sales by category

To deconstruct the salesByCategory array in the store document:

```javascript
db.stores.aggregate([
  {
    $unwind: "$sales.salesByCategory"
  }
])
```

The first two results returned by this query are:

```json
[
  {
    "_id": "7954bd5c-9ac2-4c10-bb7a-2b79bd0963c5",
    "store": {
      "name": "Downtown Store",
      "sales": {
        "totalSales": 15000,
        "salesByCategory": {
          "category": "Electronics",
          "totalSales": 5000
        }
      }
    }
  },
  {
    "_id": "7954bd5c-9ac2-4c10-bb7a-2b79bd0963c5",
    "store": {
      "name": "Downtown Store",
      "sales": {
        "totalSales": 15000,
        "salesByCategory": {
          "category": "Clothing",
          "totalSales": 10000
        }
      }
    }
  }
]
```

### Example 2: Unwind promotion events with array index

To deconstruct the promotionEvents array and include the array index in the output:

```javascript
db.stores.aggregate([
  {
    $unwind: {
      path: "$promotionEvents",
      includeArrayIndex: "eventIndex"
    }
  }
])
```

The first two results returned by this query are:

```json
[
  {
    "_id": "7954bd5c-9ac2-4c10-bb7a-2b79bd0963c5",
    "store": {
      "name": "Downtown Store",
      "promotionEvents": {
        "eventName": "Summer Sale",
        "eventDate": ISODate("2024-08-01T00:00:00Z")
      },
      "eventIndex": 0
    }
  },
  {
    "_id": "7954bd5c-9ac2-4c10-bb7a-2b79bd0963c5",
    "store": {
      "name": "Downtown Store",
      "promotionEvents": {
        "eventName": "Black Friday",
        "eventDate": ISODate("2024-11-25T00:00:00Z")
      },
      "eventIndex": 1
    }
  }
]
```

### Example 3: Unwind discounts within pomotion events

To deconstruct the discounts array within each promotion event and preserve documents with no discounts:

```javascript
db.stores.aggregate([
  {
    $unwind: {
      path: "$promotionEvents.discounts",
      preserveNullAndEmptyArrays: true
    }
  }
])
```

The first two results returned by this query are:

```json
[
  {
    "_id": "7954bd5c-9ac2-4c10-bb7a-2b79bd0963c5",
    "store": {
      "name": "Downtown Store",
      "promotionEvents": {
        "eventName": "Summer Sale",
        "discounts": {
          "discountType": "Percentage",
          "discountAmount": 20
        }
      }
    }
  },
  {
    "_id": "7954bd5c-9ac2-4c10-bb7a-2b79bd0963c5",
    "store": {
      "name": "Downtown Store",
      "promotionEvents": {
        "eventName": "Black Friday"
      }
    }
  }
]
```
