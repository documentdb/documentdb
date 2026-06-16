---
title: $slice
description: The $slice operator returns a subset of an array from any element onwards in the array.
type: operators
category: array-expression
---

# $slice

The `$slice` operator is used to return a subset of an array. It can be used to limit the number of elements in an array to a specified number or to return elements from a specified position in the array. The operator is useful when dealing with large arrays where only a portion of the data is needed for processing or display.

## Syntax

The syntax for the `$slice` operator is as following.

- Returns elements from either the start or end of the array

```javascript
{
  $slice: [ <array>, <n> ]
}
```

- Returns elements from the specified position in the array

```javascript
{
  $slice: [ <array>, <position>, <n> ]
}
```

## Parameters

| Parameter | Description |
| --- | --- |
| **`array`** | Any valid array expression. |
| **`position`** | Any valid integer expression. |
| **`n`** | Any valid integer expression. |

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

### Example 1: Return the set of elements from the array

This query retrieves the first three elements of the `sales.salesByCategory` array for `_id: 988d2dd1-2faa-4072-b420-b91b95cbfd60` within `stores` collection.

```javascript
db.stores.aggregate([{
    $match: {
        _id: "988d2dd1-2faa-4072-b420-b91b95cbfd60"
    }
}, {
    $project: {
        salesByCategory: {
            $slice: ["$sales.salesByCategory", 3]
        }
    }
}])
```

This query returns the following result.

```json
[
    {
        "_id": "988d2dd1-2faa-4072-b420-b91b95cbfd60",
        "salesByCategory": [
            {
                "categoryName": "Towel Racks",
                "totalSales": 13237
            },
            {
                "categoryName": "Washcloths",
                "totalSales": 44315
            },
            {
                "categoryName": "Face Towels",
                "totalSales": 42095
            }
        ]
    }
]
```

### Example 2: Slice with $push

This query uses `$push` with `$each` to add new elements to the `promotionEvents` array and `$slice` to retain only the first N (positive slice) or last N (negative slice) elements. This ensures the array keeps the most recent entries after the update.

```javascript
db.stores.updateOne({
    _id: "7954bd5c-9ac2-4c10-bb7a-2b79bd0963c5"
}, {
    $push: {
        promotionEvents: {
            $each: [{
                    eventName: "Black Friday Event",
                    promotionalDates: {
                        startDate: {
                            Year: 2024,
                            Month: 8,
                            Day: 1
                        },
                        endDate: {
                            Year: 2024,
                            Month: 8,
                            Day: 7
                        }
                    },
                    discounts: [{
                        categoryName: 'DJ Speakers',
                        discountPercentage: 25
                    }]
                },
                {
                    eventName: "Mega Discount Days",
                    promotionalDates: {
                        startDate: {
                            Year: 2024,
                            Month: 5,
                            Day: 11
                        },
                        endDate: {
                            Year: 2024,
                            Month: 5,
                            Day: 18
                        }
                    },
                    discounts: [{
                        categoryName: "DJ Lights",
                        discountPercentage: 20
                    }]
                }
            ],
            $slice: -3
        }
    }
})
```

The query returns the following result.

```json
[
    {
        "_id": "7954bd5c-9ac2-4c10-bb7a-2b79bd0963c5",
        "name": "Lakeshore Retail | DJ Equipment Stop - Port Cecile",
        "location": {
            "lat": 60.1441,
            "lon": -141.5012
        },
        "staff": {
            "totalStaff": {
                "fullTime": 2,
                "partTime": 0
            }
        },
        "sales": {
            "salesByCategory": [
                {
                    "categoryName": "DJ Headphones",
                    "totalSales": 35921
                },
                {
                    "categoryName": "DJ Cables",
                    "totalSales": 1000
                }
            ],
            "fullSales": 3700
        },
        "promotionEvents": [
            {
                "eventName": "Cyber Monday Event",
                "promotionalDates": {
                    "startDate": {
                        "Year": 2024,
                        "Month": 8,
                        "Day": 1
                    },
                    "endDate": {
                        "Year": 2024,
                        "Month": 8,
                        "Day": 7
                    }
                },
                "discounts": [
                    {
                        "categoryName": "DJ Speakers",
                        "discountPercentage": 25
                    }
                ]
            },
            {
                "eventName": "Black Friday Event",
                "promotionalDates": {
                    "startDate": {
                        "Year": 2024,
                        "Month": 8,
                        "Day": 1
                    },
                    "endDate": {
                        "Year": 2024,
                        "Month": 8,
                        "Day": 7
                    }
                },
                "discounts": [
                    {
                        "categoryName": "DJ Speakers",
                        "discountPercentage": 25
                    }
                ]
            },
            {
                "eventName": "Mega Discount Days",
                "promotionalDates": {
                    "startDate": {
                        "Year": 2024,
                        "Month": 5,
                        "Day": 11
                    },
                    "endDate": {
                        "Year": 2024,
                        "Month": 5,
                        "Day": 18
                    }
                },
                "discounts": [
                    {
                        "categoryName": "DJ Lights",
                        "discountPercentage": 20
                    }
                ]
            }
        ],
        "tag": [
            "#ShopLocal",
            "#NewArrival",
            "#FashionStore",
            "#SeasonalSale",
            "#FreeShipping",
            "#MembershipDeals"
        ]
    }
]
```

### Example 3: Fetch the first matching element from an array

This query retrieves the first document from "sales.salesByCategory" array.

```javascript
db.stores.find({
        name: "Lakeshore Retail"
    }, {
        _id: 1,
        name: 1,
        "sales.salesByCategory": {
            $slice: 1
        }
    } // restricts the fields to be returned
)
```

This query returns the following result.

```json
[
  {
    "_id": "988d2dd1-2faa-4072-b420-b91b95cbfd60",
    "name": "Lakeshore Retail",
    "sales": {
      "salesByCategory": [
        {
          "categoryName": "Towel Racks",
          "totalSales": 13237
        }
      ]
    }
  }
]
```

### Example 4: Fetch the last element from an array

This query retrieves the last document from "sales.salesByCategory" array.

```javascript
db.stores.find({
    name: "Lakeshore Retail"
}, {
    _id: 1,
    name: 1,
    "sales.salesByCategory": {
        $slice: -1
    }
})
```

This query returns the following result.

```json
[
  {
    "_id": "988d2dd1-2faa-4072-b420-b91b95cbfd60",
    "name": "Lakeshore Retail",
    "sales": {
      "salesByCategory": [
        {
          "categoryName": "Pillow Cases",
          "totalSales": 38833
        }
      ]
    }
  }
]
```

### Example 5: Retrieve a range of elements from an array

This query retrieves a subset range from "sales.salesByCategory" array.

```javascript
db.stores.find({
    name: "Lakeshore Retail"
}, {
    _id: 1,
    name: 1,
    "sales.salesByCategory": {
        $slice: [3, 2]
    }
})
```

This query returns the following result.

```json
[
  {
    "_id": "988d2dd1-2faa-4072-b420-b91b95cbfd60",
    "name": "Lakeshore Retail",
    "sales": {
      "salesByCategory": [
        {
          "categoryName": "Toothbrush Holders",
          "totalSales": 47912
        },
        {
          "categoryName": "Hybrid Mattresses",
          "totalSales": 48660
        }
      ]
    }
  }
]
```
