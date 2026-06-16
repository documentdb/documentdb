---
title: $mul
description: The $mul operator multiplies the value of a field by a specified number.
type: operators
category: field-update
---

# $mul

The `$mul` operator multiplies the value of a field by a specified number. If the field does not exist, `$mul` creates the field and sets it to zero. This operator is useful for applying percentage changes, scaling values, or performing bulk calculations on numeric fields.

## Syntax

```javascript
{
  $mul: {
    <field1>: <number1>,
    <field2>: <number2>,
    ...
  }
}
```

## Parameters

| Parameter | Description |
| --- | --- |
| **`field`** | The name of the field to multiply. |
| **`number`** | The number to multiply the field value by. Must be a numeric value. |

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

### Example 1: Applying percentage increase

Apply a 10% increase to total sales (multiply by 1.1). This will change `totalSales` from 24863 to 27349.3 (24863 × 1.1).

```javascript
db.stores.updateOne(
  { "_id": "438db151-04b8-4422-aa97-acf94bc69cfc" },
  {
    $mul: {
      "sales.totalSales": 1.1
    }
  }
)
```

### Example 2: Applying discount

Apply a 20% discount to sales figures (multiply by 0.8).

```javascript
db.stores.updateOne(
  { "_id": "438db151-04b8-4422-aa97-acf94bc69cfc" },
  {
    $mul: {
      "sales.totalSales": 0.8
    }
  }
)
```

### Example 3: Multiple field operations

Apply different multipliers to multiple fields simultaneously.

```javascript
db.stores.updateOne(
  { "_id": "438db151-04b8-4422-aa97-acf94bc69cfc" },
  {
    $mul: {
      "staff.totalStaff.fullTime": 1.5,
      "staff.totalStaff.partTime": 2,
      "sales.totalSales": 1.25
    }
  }
)
```

This will:

- Increase `fullTime` from 8 to 12 (8 × 1.5)
- Increase `partTime` from 5 to 10 (5 × 2)
- Increase `totalSales` by 25% (multiply by 1.25)

### Example 4: Creating new fields

If a field doesn't exist, `$mul` creates it and sets it to 0.

```javascript
db.stores.updateOne(
  { "_id": "438db151-04b8-4422-aa97-acf94bc69cfc" },
  {
    $mul: {
      "sales.bonusPoints": 100,
      "staff.overtimeHours": 40
    }
  }
)
```

Both `bonusPoints` and `overtimeHours` will be created with value 0.

### Example 5: Working with decimals

Apply precise decimal multipliers for financial calculations.

```javascript
db.stores.updateOne(
  { "_id": "438db151-04b8-4422-aa97-acf94bc69cfc" },
  {
    $mul: {
      "sales.totalSales": 0.915
    }
  }
)
```

### Example 6: Updating array elements

Apply multipliers to specific elements within arrays using positional operators.

```javascript
db.stores.updateOne(
  {
    "_id": "438db151-04b8-4422-aa97-acf94bc69cfc",
    "sales.salesByCategory.categoryName": "Direct-Drive Turntables"
  },
  {
    $mul: {
      "sales.salesByCategory.$.totalSales": 1.15
    }
  }
)
```

### Example 7: Negative values and zero

Handle negative multipliers and zero values.

```javascript
db.stores.updateOne(
  { "_id": "438db151-04b8-4422-aa97-acf94bc69cfc" },
  {
    $mul: {
      "sales.totalSales": -1,
      "staff.totalStaff.fullTime": 0
    }
  }
)
```

This will:

- Make `totalSales` negative (useful for reversals)
- Set `fullTime` to 0

After applying a 1.5 multiplier to staff and 1.25 to sales, the document would be updated as follows:

```json
{
  "_id": "438db151-04b8-4422-aa97-acf94bc69cfc",
  "name": "Fourth Coffee | Turntable Boutique - Tromptown",
  "staff": {
    "totalStaff": {
      "fullTime": 12,
      "partTime": 10
    },
    "overtimeHours": 0
  },
  "sales": {
    "totalSales": 31078.75,
    "bonusPoints": 0,
    "salesByCategory": [
      {
        "categoryName": "Direct-Drive Turntables",
        "totalSales": 28592.45
      }
    ]
  }
}
```
