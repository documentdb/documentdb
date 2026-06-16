---
title: $topN
description: The $topN operator returns the first N documents from the result sorted by one or more fields
type: operators
category: accumulators
---

# $topN

The `$topN` operator sorts documents on one or more fields specified by the query and returns the first N documents matching the filtering criteria. It extends the functionality of `$top` by allowing you to retrieve multiple top elements instead of just the single highest-ranked item.

## Syntax

```javascript
{
    $topN: {
        output: [listOfFields],
        sortBy: {
            <fieldName>: < sortOrder >
        },
        n: < numDocumentsToReturn >
    }
}
```

## Parameters

| Parameter | Description |
| --- | --- |
| **`listOfFields`** | The list of fields to be returned for the last document in the result set|
| **`fieldName`** | The field to use for sorting the result set|
| **`sortOrder`** | 1 or -1. 1 implies sorting in ascending order of the value of the field while -1 implies sorting in descending order of the values of the field|
| **`n`** | The number of documents to return from the top of the sorted result set |

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

### Example 1 - Get the two stores with the lowest total sales

To get the two lowest stores by sales within the First Up Consultants company, run a query to filter on the company name, sort the resulting documents in ascending order of sales and return the top two documents from the sorted result set.

```javascript
db.stores.aggregate([{
    $match: {
        company: {
            $in: ["First Up Consultants"]
        }
    }
}, {
    $group: {
        _id: "$company",
        topSales: {
            $topN: {
                output: ["$company", "$sales"],
                sortBy: {
                    "sales.totalSales": 1
                },
                n: 2
            }
        }
    }
}])
```

This query returns the following result:

```json
[
    {
        "_id": "First Up Consultants",
        "topSales": [
            [
                "First Up Consultants",
                {
                    "salesByCategory": [
                        {
                            "categoryName": "Towel Sets",
                            "totalSales": 520
                        },
                        {
                            "categoryName": "Bath Accessories",
                            "totalSales": 41710
                        },
                        {
                            "categoryName": "Drapes",
                            "totalSales": 42893
                        },
                        {
                            "categoryName": "Towel Racks",
                            "totalSales": 30773
                        },
                        {
                            "categoryName": "Hybrid Mattresses",
                            "totalSales": 39491
                        },
                        {
                            "categoryName": "Innerspring Mattresses",
                            "totalSales": 6410
                        },
                        {
                            "categoryName": "Bed Frames",
                            "totalSales": 41917
                        },
                        {
                            "categoryName": "Mattress Protectors",
                            "totalSales": 44124
                        },
                        {
                            "categoryName": "Bath Towels",
                            "totalSales": 5671
                        },
                        {
                            "categoryName": "Turkish Towels",
                            "totalSales": 25674
                        }
                    ],
                    "revenue": 279183
                }
            ],
            [
                "First Up Consultants",
                {
                    "salesByCategory": [
                        {
                            "categoryName": "Lavalier Microphones",
                            "totalSales": 40000
                        },
                        {
                            "categoryName": "Wireless Microphones",
                            "totalSales": 39691
                        }
                    ],
                    "minimumSalesTarget": 30000,
                    "revenue": 50000
                }
            ]
        ]
    }
]
```

### Example 2: Get the two most recent promotion events

To find the two most recent promotion events for each store, group the documents in collection by store, sort them in ascending order of promotion dates and return the top two results from the sorted result set per store.

```javascript
db.stores.aggregate([{
        $unwind: "$promotionEvents"
    },
    {
        $group: {
            _id: "$_id",
            storeName: {
                $first: "$name"
            },
            top2RecentPromotions: {
                $topN: {
                    n: 2,
                    sortBy: {
                        "promotionEvents.promotionalDates.startDate.Year": -1,
                        "promotionEvents.promotionalDates.startDate.Month": -1,
                        "promotionEvents.promotionalDates.startDate.Day": -1
                    },
                    output: {
                        eventName: "$promotionEvents.eventName",
                        startDate: "$promotionEvents.promotionalDates.startDate"
                    }
                }
            }
        }
    }
])
```

The first two results returned by this query are:

```json
[
    {
        "_id": "4a99546f-a1d2-4e61-ae9f-b8c7c1faf73c'",
        "storeName": "Lakeshore Retail | Stationery Nook - West Van",
        "top2RecentPromotions": [
            {
                "eventName": "Crazy Markdown Madness",
                "startDate": {
                    "Year": 2024,
                    "Month": 9,
                    "Day": 21
                }
            },
            {
                "eventName": "Flash Sale Fiesta",
                "startDate": {
                    "Year": 2024,
                    "Month": 6,
                    "Day": 23
                }
            }
        ]
    },
    {
        "_id": "e0c47a06-4fe0-46b7-a309-8971bbb3978f",
        "storeName": "VanArsdel, Ltd. | Baby Products Bargains - Elainamouth",
        "top2RecentPromotions": [
            {
                "eventName": "Crazy Deal Days",
                "startDate": {
                    "Year": 2024,
                    "Month": 9,
                    "Day": 21
                }
            }
        ]
    }
]
```
