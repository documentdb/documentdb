---
title: $shift usage on DocumentDB
description: A window operator that shifts values within a partition and returns the shifted value.
type: operators
category: window-operators
---

# $shift

The `$shift` operator is a window operator used in aggregation pipelines to shift values within a partition and return the shifted value. It is useful for operations where you need to compare values from adjacent documents in a sorted partition.

## Syntax

```javascript
{
  $shift: {
    output: <expression>,
    by: <number>,
    default: <expression>
  }
}
```

## Parameters

| Parameter | Description |
| --- | --- |
| **`output`** | Specifies the field or expression whose value will be shifted. |
| **`by`** | Specifies the number of positions to shift the value. Positive values shift forward, while negative values shift backward. |
| **`default`** | Specifies the default value to return if the shift operation goes out of bounds. |

## Example(s)

### Example 1: Shifting sales data

This example demonstrates how to use `$shift` to calculate the previous sales value for each document in a sorted partition of sales data.

```javascript
db.collection.aggregate([
  {
    $setWindowFields: {
      partitionBy: "$sales.salesByCategory.categoryName",
      sortBy: { "sales.salesByCategory.totalSales": 1 },
      output: {
        previousSales: {
          $shift: {
            output: "$sales.salesByCategory.totalSales",
            by: -1,
            default: null
          }
        }
      }
    }
  }
])
```

### Example 2: Shifting promotional event dates

This example calculates the previous promotional event’s start date by sorting all events by startDate. Since we want to treat all events together, we don’t partition.

```javascript
db.promotionEvents.aggregate([
  {
    $setWindowFields: {
      partitionBy: null,
      sortBy: { "promotionalDates.startDate": 1 },
      output: {
        previousStartDate: {
          $shift: {
            output: "$promotionalDates.startDate",
            by: -1,
            default: null
          }
        }
      }
    }
  }
])
```
