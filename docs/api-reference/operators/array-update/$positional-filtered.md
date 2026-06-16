---
title: $[identifier]
description: The $[identifier] operator is used to update all elements using a specific identifier in an array that match the query condition.
type: operators
category: array-update
---

# $[identifier]

The $[identifier] array update operator is used to update specific elements in an array that match a given condition. This operator is useful when you need to update multiple elements within an array based on certain criteria. It allows for more granular updates within documents, making it a powerful tool for managing complex data structures.

## Syntax

```javascript
{
  <update operator>: {
    <array field>.$[<identifier>]: <value>
  }
},
{
  arrayFilters: [
    { <identifier>.<field>: <condition> }
  ]
}
```

## Parameters

| Parameter | Description |
| --- | --- |
| **`<update operator>`** | The update operator to be applied (for example, `$set`, `$inc`, etc.). |
| **`<array field>`** | The field containing the array to be updated. |
| **`<identifier>`** | A placeholder used in `arrayFilters` to match specific elements in the array. |
| **`<value>`** | The value to be set or updated. |
| **`arrayFilters`** | An array of filter conditions to identify which elements to update. |
| **`<field>`** | The specific field within array elements to be checked. |
| **`<condition>`** | The condition that array elements must meet to be updated. |

## Examples

Consider this sample document from the stores collection.

```json
{
    "_id": "905d1939-e03a-413e-a9c4-221f74055aac",
    "name": "Trey Research | Home Office Depot - Lake Freeda",
    "location": {
        "lat": -48.9752,
        "lon": -141.6816
    },
    "staff": {
        "employeeCount": {
            "fullTime": 12,
            "partTime": 19
        }
    },
    "sales": {
        "salesByCategory": [
            {
                "categoryName": "Desk Lamps",
                "totalSales": 37978
            }
        ],
        "revenue": 37978
    },
    "promotionEvents": [
        {
            "eventName": "Crazy Deal Days",
            "promotionalDates": {
                "startDate": {
                    "Year": 2023,
                    "Month": 9,
                    "Day": 27
                },
                "endDate": {
                    "Year": 2023,
                    "Month": 10,
                    "Day": 4
                }
            },
            "discounts": [
                {
                    "categoryName": "Desks",
                    "discountPercentage": 25
                },
                {
                    "categoryName": "Filing Cabinets",
                    "discountPercentage": 23
                }
            ]
        },
        {
            "eventName": "Incredible Markdown Mania",
            "promotionalDates": {
                "startDate": {
                    "Year": 2023,
                    "Month": 12,
                    "Day": 26
                },
                "endDate": {
                    "Year": 2024,
                    "Month": 1,
                    "Day": 2
                }
            },
            "discounts": [
                {
                    "categoryName": "Monitor Stands",
                    "discountPercentage": 20
                },
                {
                    "categoryName": "Desks",
                    "discountPercentage": 24
                }
            ]
        },
        {
            "eventName": "Major Deal Days",
            "promotionalDates": {
                "startDate": {
                    "Year": 2024,
                    "Month": 3,
                    "Day": 25
                },
                "endDate": {
                    "Year": 2024,
                    "Month": 4,
                    "Day": 2
                }
            },
            "discounts": [
                {
                    "categoryName": "Office Accessories",
                    "discountPercentage": 9
                },
                {
                    "categoryName": "Desks",
                    "discountPercentage": 13
                }
            ]
        },
        {
            "eventName": "Blowout Bonanza",
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
                    "categoryName": "Office Chairs",
                    "discountPercentage": 24
                },
                {
                    "categoryName": "Desk Lamps",
                    "discountPercentage": 19
                }
            ]
        },
        {
            "eventName": "Super Saver Fiesta",
            "promotionalDates": {
                "startDate": {
                    "Year": 2024,
                    "Month": 9,
                    "Day": 21
                },
                "endDate": {
                    "Year": 2024,
                    "Month": 10,
                    "Day": 1
                }
            },
            "discounts": [
                {
                    "categoryName": "Desks",
                    "discountPercentage": 5
                },
                {
                    "categoryName": "Monitor Stands",
                    "discountPercentage": 10
                }
            ]
        }
    ],
    "company": "Trey Research",
    "city": "Lake Freeda",
    "storeOpeningDate": "2024-12-30T22:55:25.779Z",
    "lastUpdated": {
        "t": 1729983325,
        "i": 1
    }
}
```

### Example 1: Update the discount percentage for the chosen category in the specified promotion event.

This query updates the discount percentage for the 'Desk Lamps' category by modifying the specific elements in the promotion event array where the event name is 'Blowout Bonanza'.

```javascript
db.stores.updateOne(
  {
    _id: "905d1939-e03a-413e-a9c4-221f74055aac",
    "promotionEvents.eventName": "Blowout Bonanza"
  },
  {
    $set: {
      "promotionEvents.$[event].discounts.$[discount].discountPercentage": 18
    }
  },
  {
    arrayFilters: [
      { "event.eventName": "Blowout Bonanza" },
      { "discount.categoryName": "Desk Lamps" }
    ]
  }
)
```
