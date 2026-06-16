---
title: $mod
description: The $mod operator performs a modulo operation on the value of a field and selects documents with a specified result.
type: operators
category: evaluation-query
---

# $mod

The `$mod` operator performs a modulo operation on the value of a field and selects documents with a specified result. This operator is useful for finding documents where a numeric field value, when divided by a divisor, leaves a specific remainder. It commonly serves for pagination, sampling data, or finding patterns in numeric sequences.

## Syntax

```javascript
{
  <field>: { $mod: [ <divisor>, <remainder> ] }
}
```

## Parameters

| Parameter | Description |
| --- | --- |
| **`<field>`** | The field to perform the modulo operation on. The field must contain numeric values. |
| **`<divisor>`** | The number to divide the field value by. Must be a positive number. |
| **`<remainder>`** | The expected remainder after the modulo operation. Must be a non-negative number less than the divisor. |

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

### Example 1: Find stores with sales divisible by 1000

This query retrieves stores where the total sales are divisible by 1000 (useful for identifying round sales figures).

```javascript
db.stores.find({
  "sales.totalSales": { $mod: [1000, 0] }
}).limit(2)
```

The first two results returned by this query are:

```json
[
  {
    "_id": "new-store-001",
    "name": "TechWorld Electronics - Downtown Branch",
    "sales": {
      "totalSales": 5000
    },
    "createdDate": "2025-06-11T11:11:32.262Z",
    "status": "new",
    "staff": {
      "totalStaff": {
        "fullTime": 0,
        "partTime": 0
      }
    },
    "version": 1
  },
  {
    "_id": "gaming-store-mall-001",
    "name": "Gaming Paradise - Mall Location",
    "location": {
      "lat": 35.6762,
      "lon": 139.6503
    },
    "createdDate": "2025-06-11T11:13:27.180Z",
    "status": "active",
    "staff": {
      "totalStaff": {
        "fullTime": 8,
        "partTime": 12
      },
      "manager": "Alex Johnson",
      "departments": [
        "gaming",
        "accessories",
        "repairs"
      ]
    },
    "sales": {
      "totalSales": 0,
      "salesByCategory": []
    },
    "operatingHours": {
      "weekdays": "10:00-22:00",
      "weekends": "09:00-23:00"
    },
    "metadata": {
      "version": 1,
      "source": "store-management-system"
    }
  }
]
```

### Example 2: Pagination-style querying

This query retrieves stores where the part-time employee count leaves a remainder of 0 when divided by 4 (useful for creating data subsets).

```javascript
db.stores.find({
  "staff.totalStaff.partTime": { $mod: [4, 0] }
})
```

The first two results returned by this query are:

```json
[
  {
    "_id": "new-store-001",
    "name": "TechWorld Electronics - Downtown Branch",
    "sales": {
      "totalSales": 5000
    },
    "createdDate": "2025-06-11T11:11:32.262Z",
    "status": "new",
    "staff": {
      "totalStaff": {
        "fullTime": 0,
        "partTime": 0
      }
    },
    "version": 1
  },
  {
    "_id": "gaming-store-mall-001",
    "name": "Gaming Paradise - Mall Location",
    "location": {
      "lat": 35.6762,
      "lon": 139.6503
    },
    "createdDate": "2025-06-11T11:13:27.180Z",
    "status": "active",
    "staff": {
      "totalStaff": {
        "fullTime": 8,
        "partTime": 12
      },
      "manager": "Alex Johnson",
      "departments": [
        "gaming",
        "accessories",
        "repairs"
      ]
    },
    "sales": {
      "totalSales": 0,
      "salesByCategory": []
    },
    "operatingHours": {
      "weekdays": "10:00-22:00",
      "weekends": "09:00-23:00"
    },
    "metadata": {
      "version": 1,
      "source": "store-management-system"
    }
  }
]
```
