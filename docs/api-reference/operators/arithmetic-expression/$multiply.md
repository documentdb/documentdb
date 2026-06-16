---
title: $multiply
description: The $multiply operator multiplies the input numerical values
type: operators
category: arithmetic-expression
---

# $multiply

The `$multiply` operator calculates the product of the specified input numerical values.

## Syntax

```javascript
{
  $multiply: [ <listOfValues> ]
}
```

## Parameters

| Parameter | Description |
| --- | --- |
|**`<listOfValues>`**| A comma separated list of numerical values.

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

### Example 1: Multiply a field by a constant

To double the total sales for all stores under the "First Up Consultants" company, first run a query to filter on the name of the company. Then, use the $multiply operator on the totalSales field to return the desired results.

```javascript
db.stores.aggregate([{
    $match: {
        company: {
            $in: ["First Up Consultants"]
        }
    }
}, {
    $project: {
        company: 1,
        "sales.revenue": 1,
        salesVolumeDoubled: {
            $multiply: ["$sales.revenue", 2]
        }
    }
}])
```

The first three results returned by this query are:

```json
[
    {
        "_id": "39acb3aa-f350-41cb-9279-9e34c004415a",
        "sales": {
            "revenue": 279183
        },
        "company": "First Up Consultants",
        "salesVolumeDoubled": 558366
    },
    {
        "_id": "26afb024-53c7-4e94-988c-5eede72277d5",
        "sales": {
            "revenue": 50000
        },
        "company": "First Up Consultants",
        "salesVolumeDoubled": 100000
    },
    {
        "_id": "62438f5f-0c56-4a21-8c6c-6bfa479494ad",
        "sales": {
            "revenue": 68508
        },
        "company": "First Up Consultants",
        "salesVolumeDoubled": 137016
    }
]
```

## Limitations

- The `$multiply` operator works only with numerical expressions. Using it with non-numerical values result in an error.
- Be cautious of overflow or precision issues when working with large numbers or floating-point arithmetic.
