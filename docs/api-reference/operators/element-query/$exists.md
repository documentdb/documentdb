---
title: $exists
description: The $exists operator retrieves documents that contain the specified field in their document structure.
type: operators
category: element-query
---

# $exists

The $exists operator retrieves documents that contain the specified field. The $exists operator returns a value of true for documents that contain the specified field, even if the value of the field is null. The $exists operator returns a value of fall for documents that do not contain the specified field in their document structure.

## Syntax

```javascript
{
  <field>: { $exists: <true or false> }
}
```

## Parameters

| Parameter | Description |
| --- | --- |
| **`field`** | The field to check for existence. |
| **`true or false`** | `true` for documents that contain the field (including null values), `false` for documents that do not contain the field. |

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

### Example 1: Find stores with promotion events

To find any two stores with promotion events, run a query using the $exists operator on the promotionEvents array. Then, project only the ID and promotionEvents fields and limit the results to two documents from the result set.

```javascript
db.stores.find({
    "promotionEvents": {
        $exists: true
    }
}, {
    "_id": 1,
    "promotionEvents": {
        $slice: 1
    }
}).limit(2)
```

This query returns the following results:

```json
  [
    {
        "_id": "a715ab0f-4c6e-4e9d-a812-f2fab11ce0b6",
        "name": "Lakeshore Retail | Holiday Supply Hub - Marvinfort",
        "location": {
            "lat": -74.0427,
            "lon": 160.8154
        },
        "staff": {
            "employeeCount": {
                "fullTime": 9,
                "partTime": 18
            }
        },
        "sales": {
            "salesByCategory": [
                {
                    "categoryName": "Stockings",
                    "totalSales": 25731
                }
            ],
            "revenue": 25731
        },
        "promotionEvents": [
            {
                "eventName": "Mega Savings Extravaganza",
                "promotionalDates": {
                    "startDate": {
                        "Year": 2023,
                        "Month": 6,
                        "Day": 29
                    },
                    "endDate": {
                        "Year": 2023,
                        "Month": 7,
                        "Day": 7
                    }
                },
                "discounts": [
                    {
                        "categoryName": "Stockings",
                        "discountPercentage": 16
                    },
                    {
                        "categoryName": "Tree Ornaments",
                        "discountPercentage": 8
                    }
                ]
            }
        ],
        "company": "Lakeshore Retail",
        "city": "Marvinfort",
        "storeOpeningDate": "2024-10-01T18:24:02.586Z",
        "lastUpdated": "2024-10-02T18:24:02.000Z"
    },
    {
        "_id": "923d2228-6a28-4856-ac9d-77c39eaf1800",
        "name": "Lakeshore Retail | Home Decor Hub - Franciscoton",
        "location": {
            "lat": 61.3945,
            "lon": -3.6196
        },
        "staff": {
            "employeeCount": {
                "fullTime": 7,
                "partTime": 6
            }
        },
        "sales": {
            "salesByCategory": [
                {
                    "categoryName": "Lamps",
                    "totalSales": 19880
                },
                {
                    "categoryName": "Rugs",
                    "totalSales": 20055
                }
            ],
            "revenue": 39935
        },
        "promotionEvents": [
            {
                "eventName": "Unbeatable Markdown Mania",
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
                        "categoryName": "Vases",
                        "discountPercentage": 8
                    },
                    {
                        "categoryName": "Lamps",
                        "discountPercentage": 5
                    }
                ]
            }
        ],
        "company": "Lakeshore Retail",
        "city": "Franciscoton",
        "lastUpdated": "2024-12-02T12:01:46.000Z",
        "storeOpeningDate": "2024-09-03T07:21:46.045Z"
    }
]
```

### Example 2: Confirm the presence of a nested field

To retrieve any two stores with full time employees, run a query using the $exists operator on the nested staff.employeeCount.fullTime field. Then, project only the name and ID fields and limit the results to two documents from the result set.

```javascript
db.stores.find({
    "staff.employeeCount.fullTime": {
        $exists: true
    }
}, {
    "_id": 1,
    "staff.employeeCount": 1
}).limit(2)
```

This query returns the following results:

```json
[
  {
      "_id": "a715ab0f-4c6e-4e9d-a812-f2fab11ce0b6",
      "staff": {
          "employeeCount": {
              "fullTime": 9,
              "partTime": 18
          }
      }
  },
  {
      "_id": "923d2228-6a28-4856-ac9d-77c39eaf1800",
      "staff": {
          "employeeCount": {
              "fullTime": 7,
              "partTime": 6
          }
      }
  }
]
```
