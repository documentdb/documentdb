---
title: $sortByCount
description: The $sortByCount stage in the aggregation pipeline is used to group documents by a specified expression and then sort the count of documents in each group in descending order.
type: operators
category: aggregation
---

# $sortByCount

The $sortByCount stage in the aggregation pipeline is used to group documents by a specified expression and then sort the count of documents in each group in descending order. The `$sortByCount` stage is useful for quickly identifying the most common values within a dataset.

## Syntax

```javascript
{
  $sortByCount: <expression>
}
```

## Parameters

| Parameter | Description |
| --- | --- |
| **`expression`** | This is the field or computed expression on which to group and count the documents. |

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

### Example 1: Group promotion events by name and count occurrences in descending order

To group by the eventName field and count the number of occurrences of each event name, sorting the results in descending order of the count

```javascript
db.stores.aggregate([
  { $unwind: "$promotionEvents" },
  { $sortByCount: "$promotionEvents.eventName" }
])
```

This query returns the following results:

```json
[
  { "_id": "Crazy Deal Days", "count": 4239 },
  { "_id": "Markdown Madness", "count": 2967 },
  { "_id": "Bargain Bonanza", "count": 2925 },
  { "_id": "Crazy Discount Days", "count": 2922 },
  { "_id": "Price Smash Spectacular", "count": 2915 },
  { "_id": "Super Saver Spectacular", "count": 2900 },
  { "_id": "Crazy Markdown Madness", "count": 2899 },
  { "_id": "Price Cut Carnival", "count": 2868 },
  { "_id": "Grand Bargain Bash", "count": 2849 },
  { "_id": "Bargain Blitz Bash", "count": 2843 },
  { "_id": "Grand Savings Gala", "count": 2826 },
  { "_id": "Super Saver Fiesta", "count": 1551 },
  { "_id": "Major Deal Days", "count": 1548 },
  { "_id": "Price Slash Carnival", "count": 1535 },
  { "_id": "Super Discount Days", "count": 1533 },
  { "_id": "Big Deal Bonanza", "count": 1533 },
  { "_id": "Incredible Savings Showcase", "count": 1531 },
  { "_id": "Unbeatable Savings Spectacular", "count": 1518 },
  { "_id": "Fantastic Deal Days", "count": 1511 },
  { "_id": "Flash Bargain Frenzy", "count": 1504 }
]
```

This pipeline will:

1. Use $unwind to deconstruct the promotionEvents array field from the input documents.
2. Use $sortByCount to group by the eventName field and count the number of occurrences of each event name, sorting the results in descending order of the count.
