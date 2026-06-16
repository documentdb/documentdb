---
title: $inc
description: The $inc operator increments the value of a field by a specified amount.
type: operators
category: field-update
---

# $inc

The `$inc` operator increments the value of a field by a specified amount. If the field doesn't exist, `$inc` creates the field and sets it to the specified value. The operator accepts positive and negative values for incrementing and decrementing respectively.

## Syntax

The syntax for the `$inc` operator is as follows:

```javascript
{
  $inc: {
    <field1>: <amount1>,
    <field2>: <amount2>,
    ...
  }
}
```

## Parameters

| Parameter | Description |
| --- | --- |
| **`field`** | The name of the field to increment. |
| **`amount`** | The increment value. Must be a number (positive for increment, negative for decrement). |

## Examples

Consider this sample document from the stores collection.

```json
{
  "_id": "40d6f4d7-50cd-4929-9a07-0a7a133c2e74",
  "name": "Proseware, Inc. | Home Entertainment Hub - East Linwoodbury",
  "staff": {
    "totalStaff": {
      "fullTime": 19,
      "partTime": 20
    }
  },
  "sales": {
    "totalSales": 151864,
    "salesByCategory": [
      {
        "categoryName": "Sound Bars",
        "totalSales": 2120
      },
      {
        "categoryName": "Home Theater Projectors",
        "totalSales": 45004
      }
    ]
  }
}
```

### Example 1: Incrementing staff count

To increase the full-time staff count by 3, use the $inc operator on the fullTime staff field with a value of 3.

```javascript
db.stores.updateOne(
  { "_id": "40d6f4d7-50cd-4929-9a07-0a7a133c2e74" },
  {
    $inc: {
      "staff.totalStaff.fullTime": 3
    }
  }
)
```

### Example 2: Decreasing and increasing values

To decrease the part-time staff by 2 and increase total sales by 5000, use the $inc operator on both fields with values of -2 and 5000 respectively.

```javascript
db.stores.updateOne(
  { "_id": "40d6f4d7-50cd-4929-9a07-0a7a133c2e74" },
  {
    $inc: {
      "staff.totalStaff.partTime": -2,
      "sales.totalSales": 5000
    }
  }
)
```

### Example 3: Creating New Fields

If a field doesn't exist, `$inc` creates it with the specified value.

```javascript
db.stores.updateOne(
  { "_id": "40d6f4d7-50cd-4929-9a07-0a7a133c2e74" },
  {
    $inc: {
      "staff.contractorCount": 5,
      "sales.monthlyTarget": 200000
    }
  }
)
```

### Example 4: Incrementing array element values

Update specific sales figures within the salesByCategory array using positional operators.

```javascript
db.stores.updateOne(
  { 
    "_id": "40d6f4d7-50cd-4929-9a07-0a7a133c2e74",
    "sales.salesByCategory.categoryName": "Sound Bars"
  },
  {
    $inc: {
      "sales.salesByCategory.$.totalSales": 500
    }
  }
)
```

After these operations, the document is updated as follows:

```json
{
  "_id": "40d6f4d7-50cd-4929-9a07-0a7a133c2e74",
  "name": "Proseware, Inc. | Home Entertainment Hub - East Linwoodbury",
  "staff": {
    "totalStaff": {
      "fullTime": 22,
      "partTime": 18
    },
    "contractorCount": 5
  },
  "sales": {
    "totalSales": 156864,
    "monthlyTarget": 200000,
    "salesByCategory": [
      {
        "categoryName": "Sound Bars",
        "totalSales": 2620
      },
      {
        "categoryName": "Home Theater Projectors",
        "totalSales": 45004
      }
    ]
  }
}
```
