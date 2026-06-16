---
title: $linearFill
description: The $linearFill operator interpolates missing values in a sequence of documents using linear interpolation.
type: operators
category: window-operators
---

# $linearFill

The `$linearFill` operator interpolates missing values in a sequence of documents. The $linearFill operator performs linear interpolation for missing data, making it useful for datasets with gaps in values, such as time-series data.

## Syntax

```javascript
{
    $linearFill: {
        input: < expression > ,
        sortBy: {
            < field >: < 1 or - 1 >
        }
    }
}
```

## Parameters

| Parameter | Description |
| --- | --- |
| **`input`** | The field or expression to interpolate missing values for. |
| **`sortBy`** | Specifies the field by which the data is sorted for interpolation, along with the sort order (1 for ascending, -1 for descending). |

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

### Example 1: Interpolating missing sales data

To interpolate missing sales data, run a query to first partition the stores in the dataset by name. Then, use the $linearFill operator to interpolate the missing sales data across the stores within the partition.

```javascript
db.stores.aggregate([{
        "$match": {
            "company": {
                "$in": ["First Up Consultants"]
            }
        }
    },
    {
        "$setWindowFields": {
            "partitionBy": "$name",
            "sortBy": {
                "storeOpeningDate": 1
            },
            "output": {
                "interpolatedSales": {
                    "$linearFill": "$sales.totalSales"
                }
            }
        }
    }
])
```

The first three results returned by this query are:

```json
[
    {
        "_id": "0f4c48fe-c43b-4083-a856-afe6dd902077",
        "name": "First Up Consultants | Appliance Bargains - Feilmouth",
        "interpolatedSales": 26630
    },
    {
        "_id": "c4883253-7ccd-4054-a7e0-8aeb202307b5",
        "name": "First Up Consultants | Appliance Bargains - New Kari",
        "interpolatedSales": 31568
    },
    {
        "_id": "a159ff5c-6ec5-4ca8-9672-e8903a54dd90",
        "name": "First Up Consultants | Appliance Bargains - Schadenstad",
        "interpolatedSales": 59926
    }
]
```
