---
title: $unset
description: The $unset stage in the aggregation pipeline is used to remove specified fields from documents.
type: operators
category: aggregation
---

# $unset

The $unset stage the aggregation pipeline is used to remove specified fields from documents. This can be particularly useful when you need to exclude certain fields from the results of an aggregation query for reasons such as privacy, reducing payload size, or simply cleaning up the output.

## Syntax

```javascript
{
    $unset: "<field1>" | ["<field1>", "<field2>", ...]
}
```

## Parameters

| Parameter | Description |
| --- | --- |
| **`field1, field2, ...`** | The names of the fields to remove from the documents. |

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

### Example 1: Remove a single field

To remove the location field from the documents.

```javascript
db.stores.aggregate([
  {
    $unset: "store.location"
  }
])
```

The first result returned by this query is:

```json
[
  {
    "_id": "7954bd5c-9ac2-4c10-bb7a-2b79bd0963c5",
    "store": {
      "name": "Downtown Store",
      "sales": {
        "totalSales": 15000,
        "salesByCategory": [
          {
            "category": "Electronics",
            "totalSales": 5000
          },
          {
            "category": "Clothing",
            "totalSales": 10000
          }
        ]
      }
    }
  }
]
```

### Example 2: Remove multiple fields

To remove the location and sales.totalSales fields from the documents.

```javascript
db.stores.aggregate([
  {
    $unset: ["store.location", "store.sales.totalSales"]
  }
])
```

The first result returned by this query is:

```json
[
  {
    "_id": "7954bd5c-9ac2-4c10-bb7a-2b79bd0963c5",
    "store": {
      "name": "Downtown Store",
      "sales": {
        "salesByCategory": [
          {
            "category": "Electronics",
            "totalSales": 5000
          },
          {
            "category": "Clothing",
            "totalSales": 10000
          }
        ]
      }
    }
  }
]
```

### Example 3: Remove nested fields

To remove the staff.totalStaff.fullTime and promotionEvents.discounts fields from the documents.

```javascript
db.stores.aggregate([
  {
    $unset: ["store.staff.totalStaff.fullTime", "store.promotionEvents.discounts"]
  }
])
```

The first result returned by this query is:

```json
[
  {
    "_id": "7954bd5c-9ac2-4c10-bb7a-2b79bd0963c5",
    "store": {
      "name": "Downtown Store",
      "staff": {
        "totalStaff": {
          "partTime": 8
        }
      },
      "promotionEvents": ["Summer Sale", "Black Friday", "Holiday Deals"]
    }
  }
]
```
