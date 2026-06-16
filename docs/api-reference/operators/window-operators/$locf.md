---
title: $locf
description: The $locf operator propagates the last observed non-null value forward within a partition in a windowed query.
type: operators
category: window-operators
---

# $locf

The `$locf` operator propagates the last observed non-null value forward within a partition in a windowed query. The $locf operator is particularly useful in filling missing data points in time-series data or other datasets with gaps.

## Syntax

```javascript
{
  $locf: {
    input: <expression>,
    sortBy: <document>
  }
}
```

## Parameters

| Parameter | Description |
| --- | --- |
| **`input`** | The expression that resolves to the field whose value you want to propagate. |
| **`sortBy`** | A document that specifies the sort order for the partition. |

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

### Example 1: Using `$locf` to fill missing time series data

To propagate the most recent non-null value for the lastUpdated field across stores within the "First Up Consultants" company, first run a query to partition the stores within the company. Then, use the $lecf operator to propagate the last non-null value for the field for all stores within the partition.

```javascript
db.stores.aggregate([{
    "$match": {
        "company": {
            "$in": ["First Up Consultants"]
        }
    }
}, {
    "$setWindowFields": {
        "partitionBy": "$name",
        "sortBy": {
            "sales.revenue": 1
        },
        "output": {
            "lastUpdatedDate": {
                "$locf": {
                    "lastUpdated": 1
                }
            }
        }
    }
}, {
    "$project": {
        "company": 1,
        "name": 1,
        "lastObservedDiscount": 1
    }
}])
```

The first three results returned by this query are:

```json
[
    {
        "_id": "0f4c48fe-c43b-4083-a856-afe6dd902077",
        "name": "First Up Consultants | Appliance Bargains - Feilmouth",
        "company": "First Up Consultants"
    },
    {
        "_id": "c4883253-7ccd-4054-a7e0-8aeb202307b5",
        "name": "First Up Consultants | Appliance Bargains - New Kari",
        "company": "First Up Consultants"
    },
    {
        "_id": "a159ff5c-6ec5-4ca8-9672-e8903a54dd90",
        "name": "First Up Consultants | Appliance Bargains - Schadenstad",
        "company": "First Up Consultants"
    }
]
```
