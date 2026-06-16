---
title: $setField
description: The setField command is used to add, update, or remove fields in embedded documents.
type: operators
category: object-expression
---

# $setField

The `$setField` operator is used to add, update, or remove fields in embedded documents. The operator allows for precise manipulation of document fields, which makes it useful for tasks such as updating nested fields, restructuring documents, or even removing fields entirely.

## Syntax

```javascript
{
  $setField: {
    field: <fieldName>,
    input: <expression>,
    value: <expression>
  }
}
```

## Parameters

| Parameter | Description |
| --- | --- |
| **`<field>`** | The document (object) to be transformed into an array of key-value pairs. |
| **`<input>`** | The document or field being processed. |
| **`<value>`** | The new value to assign to the field. If `value` is `null`, the field is removed.|

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

### Example 1: Updating a nested field

This query performs a conditional update on nested discount values inside promotion events for the document matching a specific `_id`.

```javascript
db.stores.updateOne(
  { "_id": "0fcc0bf0-ed18-4ab8-b558-9848e18058f4" },
  [
    {
      $set: {
        "store.promotionEvents": {
          $map: {
            input: "$store.promotionEvents",
            as: "event",
            in: {
              $setField: {
                field: "discounts",
                input: "$$event",
                value: {
                  $map: {
                    input: "$$event.discounts",
                    as: "discount",
                    in: {
                      $cond: {
                        if: { $eq: ["$$discount.categoryName", "Laptops"] },
                        then: {
                          categoryName: "$$discount.categoryName",
                          discountPercentage: 18
                        },
                        else: "$$discount"
                      }
                    }
                  }
                }
              }
            }
          }
        }
      }
    }
  ]
)
```

### Example 2: Removing a field

This query removes the `totalStaff` field from the `staff` object.

```javascript
db.collection.updateOne(
  { "store.storeId": "12345" },
  [{
    $set: {
      "store.staff": {
        $setField: {
          field: "totalStaff",
          input: "$store.staff",
          value: null
        }
      }
    }
  }]
)
```
