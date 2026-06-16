---
title: findAndModify
description: The findAndModify command is used to atomically modify and return a single document.
type: commands
category: query-and-write
---

# findAndModify

The `findAndModify` command is used to atomically modify and return a single document. This command is useful for operations that require reading and updating a document in a single step, ensuring data consistency. Common use cases include implementing counters, queues, and other atomic operations.

## Syntax

The syntax for the `findAndModify` command is as follows:

```javascript
db.collection.findAndModify({
   query: <document>,
   sort: <document>,
   remove: <boolean>,
   update: <document>,
   new: <boolean>,
   fields: <document>,
   upsert: <boolean>
})
```

### Parameters

- **query**: The selection criteria for the document to modify.
- **sort**: Determines which document to modify if the query selects multiple documents.
- **remove**: If `true`, removes the selected document.
- **update**: The modifications to apply.
- **new**: If `true`, returns the modified document rather than the original.
- **fields**: Limits the fields to return for the matching document.
- **upsert**: If `true`, creates a new document if no document matches the query.

## Examples

### Example 1: Update total sales

Suppose we want to update the total sales for the store with `_id` "e5767a9f-cd95-439c-9ec4-7ddc13d22926" to `550000.00` and return the updated document.

```javascript
db.stores.findAndModify({
   query: { "_id": "e5767a9f-cd95-439c-9ec4-7ddc13d22926" },
   update: { $set: { "sales.totalSales": 550000.00 } },
   new: true
})
```

#### Sample output

```json
{
  "_id": "e5767a9f-cd95-439c-9ec4-7ddc13d22926",
  "name": "Marina's Eyewear Bargains",
  "location": { "lat": -87.4376, "lon": 42.2928 },
  "staff": { "totalStaff": { "fullTime": 20, "partTime": 6 } },
  "sales": {
    "totalSales": 550000,
    "salesByCategory": [
      { "categoryName": "Round Sunglasses", "totalSales": 39621 },
      { "categoryName": "Reading Glasses", "totalSales": 1146 },
      { "categoryName": "Aviators", "totalSales": 9385 }
    ]
  },
  "promotionEvents": [
    {
      "eventName": "Incredible Discount Days",
      "promotionalDates": {
        "startDate": { "Year": 2024, "Month": 2, "Day": 11 },
        "endDate": { "Year": 2024, "Month": 2, "Day": 18 }
      },
      "discounts": [
        { "categoryName": "Square Sunglasses", "discountPercentage": 16 },
        { "categoryName": "Safety Glasses", "discountPercentage": 17 },
        { "categoryName": "Wayfarers", "discountPercentage": 7 },
        { "categoryName": "Eyewear Accessories", "discountPercentage": 12 }
      ]
    }
],
  "tag": [
    "#ShopLocal",
    "#FashionStore",
    "#SeasonalSale",
    "#FreeShipping",
    "#MembershipDeals"
  ]
}
```

### Example 2: Add a new promotional event

Let's add a new promotional event called "Electronics Super Saver" to the store with `_id_` "e5767a9f-cd95-439c-9ec4-7ddc13d22926" and return the updated document.

```javascript
db.stores.findAndModify({
   query: { "_id": "e5767a9f-cd95-439c-9ec4-7ddc13d22926" },
   update: { $push: { "promotionEvents": {
       "eventName": "Electronics Super Saver",
       "promotionalDates": {
         "startDate": "2025-09-31",
         "endDate": "2025-09-31"
       },
       "discounts": [
         {
           "categoryName": "Laptops",
           "discountPercentage": 45
         },
         {
           "categoryName": "Smartphones",
           "discountPercentage": 25
         }
       ]
   }}},
   new: true
})
```

#### Sample output

```json
{
  "_id": "e5767a9f-cd95-439c-9ec4-7ddc13d22926",
  "name": "Marina's Eyewear Bargains",
  "location": { "lat": -87.4376, "lon": 42.2928 },
  "staff": { "totalStaff": { "fullTime": 20, "partTime": 6 } },
  "sales": {
    "totalSales": 550000,
    "salesByCategory": [
      { "categoryName": "Round Sunglasses", "totalSales": 39621 },
      { "categoryName": "Reading Glasses", "totalSales": 1146 },
      { "categoryName": "Aviators", "totalSales": 9385 }
    ]
  },
  "promotionEvents": [
    {
      "eventName": "Electronics Super Saver",
      "promotionalDates": { "startDate": "2025-09-31", "endDate": "2025-09-31" },
      "discounts": [
        { "categoryName": "Laptops", "discountPercentage": 45 },
        { "categoryName": "Smartphones", "discountPercentage": 25 }
      ]
    }
  ],
  "tag": [
    "#ShopLocal",
    "#FashionStore",
    "#SeasonalSale",
    "#FreeShipping",
    "#MembershipDeals"
  ]
}
```

### Example 3: Remove a promotional event

Suppose we want to remove the "Electronics Super Saver" promotional event from the store with `_id` "e5767a9f-cd95-439c-9ec4-7ddc13d22926" and return the original document.

```javascript
db.stores.findAndModify({
   query: { "_id": "e5767a9f-cd95-439c-9ec4-7ddc13d22926" },
   update: { $pull: { "promotionEvents": { "eventName": "Electronics Super Saver" } } },
   new: true
})
```

#### Sample output

```json
{
  "_id": "e5767a9f-cd95-439c-9ec4-7ddc13d22926",
  "name": "Marina's Eyewear Bargains",
  "location": { "lat": -87.4376, "lon": 42.2928 },
  "staff": { "totalStaff": { "fullTime": 20, "partTime": 6 } },
  "sales": {
    "totalSales": 550000,
    "salesByCategory": [
      { "categoryName": "Round Sunglasses", "totalSales": 39621 },
      { "categoryName": "Reading Glasses", "totalSales": 1146 },
      { "categoryName": "Aviators", "totalSales": 9385 }
    ]
  },
  "promotionEvents": [
    {
      "eventName": "Incredible Discount Days",
      "promotionalDates": {
        "startDate": { "Year": 2024, "Month": 2, "Day": 11 },
        "endDate": { "Year": 2024, "Month": 2, "Day": 18 }
      },
      "discounts": [
        { "categoryName": "Square Sunglasses", "discountPercentage": 16 },
        { "categoryName": "Safety Glasses", "discountPercentage": 17 },
        { "categoryName": "Wayfarers", "discountPercentage": 7 },
        { "categoryName": "Eyewear Accessories", "discountPercentage": 12 }
      ]
    }
  ],
  "tag": [
    "#ShopLocal",
    "#FashionStore",
    "#SeasonalSale",
    "#FreeShipping",
    "#MembershipDeals"
  ]
}
```
