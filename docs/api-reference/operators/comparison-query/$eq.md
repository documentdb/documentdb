---
title: $eq
description: The $eq query operator compares the value of a field to a specified value
type: operators
category: comparison-query
---

# $eq

The `$eq` operator is used to match documents where the value of a field is equal to a specified value. The $eq operator filters documents based on exact matches on query predicates to retrieve documents with specific values, objects and arrays.

## Syntax

```javascript
{
    field: {
        $eq: <value>
    }
}
```

## Parameters

| Parameter | Description |
| --- | --- |
| **`field`** | The field to be compared|
| **`value`** | The value to compare against|

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

### Example 1: Use $eq filter on a root level field

To find a store with the name "Boulder Innovations | Home Security Place - Ankundingburgh", run a query with the $eq predicate to match on the name field and project only the ID and name fields in the result.

```javascript
db.stores.find({
    name: {
        $eq: "Boulder Innovations | Home Security Place - Ankundingburgh"
    }
}, {
    name: 1
})
```

This query returns the following result:

```json
[
    {
        "_id": "bda56164-954d-4f47-a230-ecf64b317b43",
        "name": "Boulder Innovations | Home Security Place - Ankundingburgh"
    }
]
```

### Example 2: Use $eq filter on a nested field

To find a store with a total sales of exactly $37,015, run a query using the $eq operator using the dot notation on the nested field sales.totalSales field.

```javascript
db.stores.find({
    "sales.totalSales": {
        $eq: 37015
    }
}, {
    name: 1,
    "sales.totalSales": 1
})
```

This returns the following result:

```json
[
    {
        "_id": "bda56164-954d-4f47-a230-ecf64b317b43",
        "name": "Boulder Innovations | Home Security Place - Ankundingburgh",
        "sales": { "totalSales": 37015 }
    }
]
```

### Example 3: Use $eq for individual items in an array

The following query retrieves documents using equality predicates on individual items within the nested promotionEvents.discounts array.

This query searches for an equality match on any one of the objects within the nested discounts array

```javascript
db.stores.find({
    "promotionEvents.discounts": {
        $eq: {
            categoryName: "Alarm Systems",
            discountPercentage: 5
        }
    }
}, {
    name: 1
}, {
    limit: 2
})
```

This query returns the following results:

```json
[
  {
    "_id": "ece5bf6c-3255-477e-bf2c-d577c82d6995",
    "name": "Proseware, Inc. | Home Security Boutique - Schambergertown"
  },
  {
    "_id": "7baa8fd8-113a-4b10-a7b9-2c116e976491",
    "name": "Tailwind Traders | Home Security Pantry - Port Casper"
  }
]
```

### Example 4: Use $eq to match the entire array

This query searches for documents based on exact match on ALL the values within the promotionEvents.discounts array.

```javascript
db.stores.find({
    "promotionEvents.discounts": {
        $eq: [{
            categoryName: "Alarm Systems",
            discountPercentage: 5
        }, {
            categoryName: "Door Locks",
            discountPercentage: 12
        }]
    }
}, {
    name: 1
})
```

This query returns the following result:

```json
[
    {
        "_id": "aa9ad64c-29da-42f8-a1f0-30e03bf04a2d",
        "name": "Boulder Innovations | Home Security Market - East Sheridanborough"
    }
]
```

> [!NOTE]
> For an equality match on an entire array, the order of the specified values in the equality predicates must also be an exact match.
