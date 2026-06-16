---
title: $rename
description: The $rename operator allows renaming fields in documents during update operations.
type: operators
category: field-update
---

# $rename

The `$rename` operator is used to rename fields in documents during update operations. It removes the field with the old name and creates a new field with the specified name, preserving the original value. This operator is useful for restructuring document schemas or correcting field naming conventions.

## Syntax

```javascript
{
  $rename: {
    <field1>: <newName1>,
    <field2>: <newName2>,
    ...
  }
}
```

## Parameters

| Parameter | Description |
| --- | --- |
| **`field`** | The current name of the field to be renamed. |
| **`newName`** | The new name for the field. |

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

### Example 1: Renaming top-level fields

To rename the `name` field to `storeName` and `location` to `storeLocation`, use the $rename operator with both the fields.

```javascript
db.stores.updateOne(
  { "_id": "2cf3f885-9962-4b67-a172-aa9039e9ae2f" },
  {
    $rename: {
      "name": "storeName",
      "location": "storeLocation"
    }
  }
)
```

### Example 2: Renaming nested fields

You can also rename nested fields by using dot notation.

```javascript
db.stores.updateOne(
  { "_id": "2cf3f885-9962-4b67-a172-aa9039e9ae2f" },
  {
    $rename: {
      "location.lat": "location.latitude",
      "location.lon": "location.longitude",
      "staff.totalStaff.fullTime": "staff.totalStaff.fullTimeEmployees"
    }
  }
)
```

### Example 3: Bulk rename operations

You can rename fields across multiple documents using `updateMany()`.

```javascript
db.stores.updateMany(
  {},
  {
    $rename: {
      "sales.totalSales": "sales.revenue",
      "staff.totalStaff": "staff.employeeCount"
    }
  }
)
```

> [!Important]
> 
> If the field specified in `$rename` does not exist, the operation will have no effect on that field.
> 
> If the new field name already exists, the `$rename` operation will overwrite the existing field.
> 
> The `$rename` operator cannot be used to rename array elements or fields within array elements.
> 
> Field names cannot be empty strings or contain null characters.
