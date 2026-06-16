---
title: $documentNumber
description: The $documentNumber operator assigns and returns a position for each document within a partition based on a specified sort order
type: operators
category: window-operators
---

# $documentNumber

The `$documentNumber` operator sorts documents on one or more fields within a partition and assigns a document number for each document in the result set.

## Syntax

```javascript
{
    $documentNumber: {}
}
```

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

### Example 1 - Retrieve a document number by total sales

To retrieve a document number (positional ranking) for each store under the First Up Consultants company, first run a query to filter on the company name, then sort the results in ascending order of total sales, and assign a document number to each of the documents in the sorted result set.

```javascript
db.stores.aggregate([{
    "$match": {
        "company": {
            "$in": ["First Up Consultants"]
        }
    }
}, {
    "$setWindowFields": {
        "partitionBy": "$company",
        "sortBy": {
            "sales.totalSales": -1
        },
        "output": {
            "documentNumber": {
                "$documentNumber": {}
            }
        }
    }
}, {
    "$project": {
        "company": 1,
        "documentNumber": 1
    }
}])
```

The first 5 results returned by this query are:

```json
[
    {
        "_id": "39acb3aa-f350-41cb-9279-9e34c004415a",
        "company": "First Up Consultants",
        "documentNumber": 1
    },
    {
        "_id": "26afb024-53c7-4e94-988c-5eede72277d5",
        "company": "First Up Consultants",
        "documentNumber": 2
    },
    {
        "_id": "62438f5f-0c56-4a21-8c6c-6bfa479494ad",
        "company": "First Up Consultants",
        "documentNumber": 3
    },
    {
        "_id": "bfb213fa-8db8-419f-8e5b-e7096120bad2",
        "company": "First Up Consultants",
        "documentNumber": 4
    },
    {
        "_id": "14ab145b-0819-4d22-9e02-9ae0725fcda9",
        "company": "First Up Consultants",
        "documentNumber": 5
    }
]
```
