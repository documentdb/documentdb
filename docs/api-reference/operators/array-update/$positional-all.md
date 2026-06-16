---
title: $[]
description: The $[] operator is used to update all elements in an array that match the query condition.
type: operators
category: array-update
---

# $[]

The $[] operator in DocumentDB is used to update all elements in an array that match a specified condition. This operator allows you to perform updates on multiple elements in an array without specifying their positions. It is particularly useful when you need to apply the same update to all items in an array.

## Syntax

```javascript
db.collection.update(
   <query>,
   {
     $set: {
       <arrayField>.$[]: <value>
     }
   }
)
```

## Parameters

| Parameter | Description |
| --- | --- |
| **`<query>`** | The selection criteria for the documents to update. |
| **`<arrayField>`** | The field containing the array to update. |
| **`<value>`** | The value to set for each matching element in the array. |

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

### Example 1: Updating Discount Percentages

This query updates all elements in the discounts array inside each promotion event.

```javascript
db.stores.updateOne(
  { _id: "905d1939-e03a-413e-a9c4-221f74055aac" },
  {
    $inc: {
      "promotionEvents.$[].discounts.$[].discountPercentage": 5
    }
  }
)
```

### Example 2: Updating Sales by Category

This query increase the total sales for all categories by 10% by using the $[] operator.

```javascript
db.stores.update(
  { _id: "905d1939-e03a-413e-a9c4-221f74055aac" },
  {
    $mul: {
      "sales.salesByCategory.$[].totalSales": 1.10
    }
  }
)
```
