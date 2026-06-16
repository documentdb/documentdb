---
title: $max
description: The $max operator returns the maximum value from a set of input values.
type: operators
category: accumulators
---

# $max

The `$max` operator returns the maximum value of a set of input values.

When used as a field update operator, the `$max` operator updates the value of a field to a specified value if the specified value is greater than the current value of the field. If the field does not exist, `$max` creates the field and sets it to the specified value.

## Syntax

```javascript
$max: <expression>
```

When used as a field update operator:

```javascript
{
  $max: {
    <field1>: <value1>,
    <field2>: <value2>,
    ...
  }
}
```

## Parameters

| Parameter | Description |
| --- | --- |
| **`<expression>`** | Any valid expression that resolves to a value. The `$max` operator evaluates this expression to determine the maximum value. |

When used as a field update operator:

| Parameter | Description |
| --- | --- |
| **`field`** | The name of the field to update with the maximum value. |
| **`value`** | The value to compare with the current field value. The field will be updated only if this value is larger. |

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

### Example 1: Calculate the highest sales by category

To calculate the highest sales within each category, first run a query to group all documents by sales category. Then run a $max query to retrieve the highest sales within each category across all stores.

```javascript
db.stores.aggregate([{
        $unwind: "$sales.salesByCategory"
    },
    {
        $group: {
            _id: "$sales.salesByCategory.categoryName",
            maxSales: {
                $max: "$sales.salesByCategory.totalSales"
            }
        }
    }
])
```

The first five results returned by this query are:

```json
[
    {
        "_id": "Christmas Trees",
        "maxSales": 49697
    },
    {
        "_id": "Nuts",
        "maxSales": 48020
    },
    {
        "_id": "Camping Tables",
        "maxSales": 48568
    },
    {
        "_id": "Music Theory Books",
        "maxSales": 46133
    },
    {
        "_id": "Fortified Wine",
        "maxSales": 49912
    }
]
```

### Example 2: Using `$max` in `$bucket`

To retrieve the highest sales within buckets of sales boundaries:

```javascript
db.stores.aggregate([{
    $bucket: {
        groupBy: "$sales.totalSales",
        boundaries: [0, 1000, 5000, 10000],
        default: "Other",
        output: {
            maxSales: {
                $max: "$sales.totalSales"
            }
        }
    }
}])
```

This query returns the following results:

```json
[
    {
        "_id": 1000,
        "maxSales": 4996
    },
    {
        "_id": "Other",
        "maxSales": 404106
    },
    {
        "_id": 0,
        "maxSales": 995
    },
    {
        "_id": 5000,
        "maxSales": 9999
    }
]
```

### Example 3: Using `$max` in `$setWindowFields`

To get the highest discount for laptops in 2023, first run a query to unwind just promotion events and filter on the chosen category. Then partition the resulting documents by company and calculate the highest discount percentage within each resulting partition.

```javascript
db.stores.aggregate([{
        $unwind: "$promotionEvents"
    },
    {
        $unwind: "$promotionEvents.discounts"
    },
    // Filter only Laptops category and events in 2023
    {
        $match: {
            "promotionEvents.promotionalDates.startDate.Year": 2023,
            "promotionEvents.discounts.categoryName": "Laptops"
        }
    },
    // Use $setWindowFields to calculate average discount by city
    {
        $setWindowFields: {
            partitionBy: "$company",
            output: {
                maxDiscount: {
                    $max: "$promotionEvents.discounts.discountPercentage",
                    window: {
                        documents: ["unbounded", "unbounded"]
                    }
                }
            }
        }
    },
    // Group by city to return one result per city
    {
        $group: {
            _id: "$company",
            maxDiscount: {
                $first: "$maxDiscount"
            }
        }
    }
])
```

The first three results returned by this query are:

```json
[
    {
        "_id": "Proseware, Inc.",
        "maxDiscount": 24
    },
    {
        "_id": "Fabrikam, Inc.",
        "maxDiscount": 23
    },
    {
        "_id": "Contoso, Ltd.",
        "maxDiscount": 24
    }
]
```

### Example 4: Setting maximum staff capacity (field update operator)

To update the full time staff to 10 only if the current full time staff count is lower, use the $max operator on the field to perform the update. Since the current `fullTime` value is 3, and 10 is greater than 3, the field will be updated to 10.

```javascript
db.stores.updateOne(
  { _id: "f2a8c190-28e4-4e14-9d8b-0256e53dca66" },
  {
    $max: {
      "staff.totalStaff.fullTime": 10
    }
  }
)
```

### Example 5: Multiple field updates (field update operator)

To update multiple fields with maximum values, use the $max operator with multiple fields and their corresponding max values to set.

```javascript
db.stores.updateOne(
  { _id: "f2a8c190-28e4-4e14-9d8b-0256e53dca66" },
  {
    $max: {
      "staff.totalStaff.partTime": 1,
      "sales.totalSales": 50000
    }
  }
)
```

In this case:

- `partTime` (2) will remain 2 since 1 < 2 (no change)
- `totalSales` (31211) will be updated to 50000 since 50000 > 31211

### Example 6: Creating new fields (field update operator)

If a field doesn't exist, `$max` creates it with the specified value.

```javascript
db.stores.updateOne(
  { _id: "f2a8c190-28e4-4e14-9d8b-0256e53dca66" },
  {
    $max: {
      "staff.maxStaffCapacity": 25,
      "sales.peakSalesRecord": 100000
    }
  }
)
```

### Example 7: Updating array elements (field update operator)

Update maximum values within array elements using positional operators.

```javascript
db.stores.updateOne(
  {
    _id: "f2a8c190-28e4-4e14-9d8b-0256e53dca66",
    "sales.salesByCategory.categoryName": "Phone Mounts"
  },
  {
    $max: {
      "sales.salesByCategory.$.totalSales": 12000
    }
  }
)
```

### Example 8: Tracking peak performance (field update operator)

Set peak performance metrics that only update when exceeded.

```javascript
db.stores.updateOne(
  { _id: "f2a8c190-28e4-4e14-9d8b-0256e53dca66" },
  {
    $max: {
      "performance.peakDailySales": 5000,
      "performance.maxCustomersPerDay": 150,
      "performance.highestSalesMonth": 45000
    }
  }
)
```

After these field update operations, the updated document is:

```json
{
  "_id": "f2a8c190-28e4-4e14-9d8b-0256e53dca66",
  "name": "Fabrikam, Inc. | Car Accessory Outlet - West Adele",
  "staff": {
    "totalStaff": {
      "fullTime": 10,
      "partTime": 2
    },
    "maxStaffCapacity": 25
  },
  "sales": {
    "totalSales": 50000,
    "peakSalesRecord": 100000,
    "salesByCategory": [
      {
        "categoryName": "Phone Mounts",
        "totalSales": 12000
      },
      {
        "categoryName": "Dash Cameras",
        "totalSales": 22300
      }
    ]
  },
  "performance": {
    "peakDailySales": 5000,
    "maxCustomersPerDay": 150,
    "highestSalesMonth": 45000
  },
  "lastPromotionDate": ISODate("2024-12-31T00:00:00.000Z"),
  "inventoryDeadline": ISODate("2024-06-30T00:00:00.000Z")
}
```
