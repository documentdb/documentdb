---
title: $min
description: The $min operator retrieves the minimum value for a specified field
type: operators
category: accumulators
---

# $min

The `$min` operator is used within aggregation stages like `$group`, `$bucket`, `$bucketAuto`, or `$setWindowFields`. The min operator is particularly useful in summarizing data or finding the smallest value in a dataset.

When used as a field update operator, `$min` operator updates the value of a field to a specified value if the specified value is less than the current value of the field. If the field does not exist, `$min` creates the field and sets it to the specified value.

## Syntax

```javascript
$min: <expression>
```

The `<expression>` can be a field path or an aggregation expression that specifies the values to be considered for the minimum calculation.

As a field update operator:

```javascript
{
  $min: {
    <field1>: <value1>,
    <field2>: <value2>,
    ...
  }
}
```

## Parameters

| Parameter | Description |
| --- | --- |
| **`<expression>`** | Specifies the field or computed value to determine the minimum value. |

As a field update operator:

| Parameter | Description |
| --- | --- |
| **`field`** | The name of the field to update with the minimum value. |
| **`value`** | The value to compare with the current field value. The field will be updated only if this value is smaller. |

## Examples

Consider this sample document from the stores collection.

```json
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
      }
    ],
    "fullSales": 3700
  },
  "promotionEvents": [
    {
      "eventName": "Bargain Blitz Days",
      "promotionalDates": {
        "startDate": {
          "Year": 2024,
          "Month": 3,
          "Day": 11
        },
        "endDate": {
          "Year": 2024,
          "Month": 2,
          "Day": 18
        }
      },
      "discounts": [
        {
          "categoryName": "DJ Turntables",
          "discountPercentage": 18
        },
        {
          "categoryName": "DJ Mixers",
          "discountPercentage": 15
        }
      ]
    }
  ],
  "tag": [
    "#ShopLocal",
    "#SeasonalSale",
    "#FreeShipping",
    "#MembershipDeals"
  ],
  "company": "Lakeshore Retail",
  "city": "Port Cecile",
  "lastUpdated": {
    "$date": "2024-12-11T10:21:58.274Z"
  }
}
```

### Example 1: Using `$min` in `$group`

This query calculates the minimum sales value for each category in the `sales.salesByCategory` array by first grouping documents by sales category and then calculating the minimum sales volume within each category.

```javascript
db.stores.aggregate([{
        $unwind: "$sales.salesByCategory"
    },
    {
        $group: {
            _id: "$sales.salesByCategory.categoryName",
            minSales: {
                $min: "$sales.salesByCategory.totalSales"
            }
        }
    }
])
```

This query returns the following results.

```json
[
    {
        "_id": "Christmas Trees",
        "minSales": 391
    },
    {
        "_id": "Nuts",
        "minSales": 257
    },
    {
        "_id": "Camping Tables",
        "minSales": 171
    },
    {
        "_id": "Music Theory Books",
        "minSales": 323
    },
    {
        "_id": "Fortified Wine",
        "minSales": 521
    },
    {
        "_id": "Children's Mystery",
        "minSales": 1470
    },
    {
        "_id": "Short Throw Projectors",
        "minSales": 111
    },
    {
        "_id": "Pliers",
        "minSales": 1981
    },
    {
        "_id": "Bluetooth Headphones",
        "minSales": 465
    },
    {
        "_id": "Video Storage",
        "minSales": 1568
    },
    {
        "_id": "Cleansers",
        "minSales": 170
    },
    {
        "_id": "Camera Straps",
        "minSales": 127
    },
    {
        "_id": "Carry-On Bags",
        "minSales": 149
    },
    {
        "_id": "Disinfectant Wipes",
        "minSales": 647
    },
    {
        "_id": "Insignia Smart TVs",
        "minSales": 451
    },
    {
        "_id": "Toner Refill Kits",
        "minSales": 3525
    },
    {
        "_id": "iPads",
        "minSales": 325
    },
    {
        "_id": "Storage Baskets",
        "minSales": 1151
    },
    {
        "_id": "Memory Foam Mattresses",
        "minSales": 422
    },
    {
        "_id": "Body Spray",
        "minSales": 448
    }
]
```

### Example 2: Using `$min` in `$bucket`

This query creates buckets based on sales values and calculates the minimum sales value for each bucket.

```javascript
db.stores.aggregate([{
    $bucket: {
        groupBy: "$sales.totalSales",
        boundaries: [0, 1000, 5000, 10000],
        default: "Other",
        output: {
            minSales: {
                $min: "$sales.totalSales"
            }
        }
    }
}])
```

This query returns the following results.

```json
[
    {
        "_id": 1000,
        "minSales": 1000
    },
    {
        "_id": "Other",
        "minSales": null
    },
    {
        "_id": 0,
        "minSales": 108
    },
    {
        "_id": 5000,
        "minSales": 5001
    }
]
```

### Example 3: Using `$min` in `$setWindowFields`

This query retrieves the minimum discount for "Laptops" by company, in the year 2023:

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
                minDiscount: {
                    $min: "$promotionEvents.discounts.discountPercentage",
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
            minDiscount: {
                $first: "$minDiscount"
            }
        }
    }
])
```

This query returns the following results.

```json
[
    {
        "_id": "VanArsdel, Ltd.",
        "minDiscount": 6
    },
    {
        "_id": "Proseware, Inc.",
        "minDiscount": 8
    },
    {
        "_id": "Fabrikam, Inc.",
        "minDiscount": 5
    },
    {
        "_id": "Contoso, Ltd.",
        "minDiscount": 5
    },
    {
        "_id": "Fourth Coffee",
        "minDiscount": 6
    },
    {
        "_id": "Trey Research",
        "minDiscount": 7
    },
    {
        "_id": "Adatum Corporation",
        "minDiscount": 5
    },
    {
        "_id": "Relecloud",
        "minDiscount": 5
    },
    {
        "_id": "Lakeshore Retail",
        "minDiscount": 7
    },
    {
        "_id": "Northwind Traders",
        "minDiscount": 8
    },
    {
        "_id": "First Up Consultants",
        "minDiscount": 9
    },
    {
        "_id": "Wide World Importers",
        "minDiscount": 10
    },
    {
        "_id": "Tailwind Traders",
        "minDiscount": 5
    }
]
```

### Example 4: Setting minimum staff requirements (field update operator)

To set a minimum staff requirement, update the full time stagg count only if the current value of the field is higher. Since the current `fullTime` value is 14, and 10 is less than 14, the field will be updated to 10.

```javascript
db.stores.updateOne(
  { _id: "26afb024-53c7-4e94-988c-5eede72277d5" },
  {
    $min: {
      "staff.totalStaff.fullTime": 10
    }
  }
)
```

### Example 5: Multiple field updates (field update operator)

To update multiple fields with minimum values simultaneously, use the $min operator with multiple fields and corresponding min values.

```javascript
db.stores.updateOne(
  { _id: "26afb024-53c7-4e94-988c-5eede72277d5" },
  {
    $min: {
      "staff.totalStaff.partTime": 12,
      "sales.totalSales": 50000
    }
  }
)
```

In this case:

- `partTime` (8) will be updated to 8 since 12 > 8 (no change)
- `totalSales` (83865) will be updated to 50000 since 50000 < 83865

### Example 6: Creating new fields (field update operator)

If a field doesn't exist, `$min` creates it with the specified value.

```javascript
db.stores.updateOne(
  { _id: "26afb024-53c7-4e94-988c-5eede72277d5" },
  {
    $min: {
      "staff.minStaffRequired": 15,
      "sales.minimumSalesTarget": 30000
    }
  }
)
```

### Example 7: Working with Dates (field update operator)

Set minimum dates for tracking earliest events.

```javascript
db.stores.updateOne(
  { _id: "26afb024-53c7-4e94-988c-5eede72277d5" },
  {
    $min: {
      "lastInventoryCheck": new Date("2024-01-15"),
      "firstSaleDate": new Date("2023-06-01")
    }
  }
)
```

### Example 8: Updating array elements (field update operator)

Update minimum values within array elements using positional operators.

```javascript
db.stores.updateOne(
  {
    _id: "26afb024-53c7-4e94-988c-5eede72277d5",
    "sales.salesByCategory.categoryName": "Lavalier Microphones"
  },
  {
    $min: {
      "sales.salesByCategory.$.totalSales": 40000
    }
  }
)
```

After these field update operations, the updated document is:

```json
{
  "_id": "26afb024-53c7-4e94-988c-5eede72277d5",
  "name": "First Up Consultants | Microphone Bazaar - South Lexusland",
  "staff": {
    "totalStaff": {
      "fullTime": 10,
      "partTime": 8
    },
    "minStaffRequired": 15
  },
  "sales": {
    "totalSales": 50000,
    "minimumSalesTarget": 30000,
    "salesByCategory": [
      {
        "categoryName": "Lavalier Microphones",
        "totalSales": 40000
      },
      {
        "categoryName": "Wireless Microphones",
        "totalSales": 39691
      }
    ]
  },
  "lastInventoryCheck": ISODate("2024-01-15T00:00:00.000Z"),
  "firstSaleDate": ISODate("2023-06-01T00:00:00.000Z")
}
```
