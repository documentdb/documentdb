---
title: $regex
description: The $regex operator provides regular expression capabilities for pattern matching in queries, allowing flexible string matching and searching.
type: operators
category: evaluation-query
---

# $regex

The `$regex` operator provides regular expression capabilities for pattern matching in queries. It allows you to search for documents where a field matches a specified regular expression pattern. This operator is useful for flexible string searching, pattern validation, and complex text filtering operations.

## Syntax

The syntax for the `$regex` operator is as follows:

```javascript
{
  <field>: { $regex: <pattern>, $options: <options> }
}
```

Or the shorter form:

```javascript
{
  <field>: { $regex: /<pattern>/<options> }
}
```

## Parameters

| Parameter | Description |
| --- | --- |
| **`<field>`** | The field to search in. Must contain string values. |
| **`<pattern>`** | The regular expression pattern to match against. |
| **`<options>`** | Optional. Regular expression options such as case-insensitive matching. Common options include 'i' (case insensitive), 'm' (multiline), 's' (dot all), and 'x' (extended). |

## Examples

Consider this sample document from the stores collection.

```json
{
  "_id": "39acb3aa-f350-41cb-9279-9e34c004415a",
  "name": "First Up Consultants | Bed and Bath Pantry - Port Antone",
  "location": {
    "lat": 87.2239,
    "lon": -129.0506
  },
  "staff": {
    "employeeCount": {
      "fullTime": 8,
      "partTime": 7
    }
  },
  "sales": {
    "salesByCategory": [
      { "categoryName": "Towel Sets", "totalSales": 520 },
      { "categoryName": "Bath Accessories", "totalSales": 41710 },
      { "categoryName": "Drapes", "totalSales": 42893 },
      { "categoryName": "Towel Racks", "totalSales": 30773 },
      { "categoryName": "Hybrid Mattresses", "totalSales": 39491 },
      { "categoryName": "Innerspring Mattresses", "totalSales": 6410 },
      { "categoryName": "Bed Frames", "totalSales": 41917 },
      { "categoryName": "Mattress Protectors", "totalSales": 44124 },
      { "categoryName": "Bath Towels", "totalSales": 5671 },
      { "categoryName": "Turkish Towels", "totalSales": 25674 }
    ],
    "revenue": 279183
  },
  "promotionEvents": [
    {
      "eventName": "Discount Derby",
      "promotionalDates": {
        "startDate": { "Year": 2023, "Month": 12, "Day": 26 },
        "endDate": { "Year": 2024, "Month": 1, "Day": 5 }
      },
      "discounts": [
        { "categoryName": "Microfiber Towels", "discountPercentage": 6 },
        { "categoryName": "Bath Sheets", "discountPercentage": 16 },
        { "categoryName": "Towels", "discountPercentage": 10 },
        { "categoryName": "Hand Towels", "discountPercentage": 11 },
        { "categoryName": "Kitchen Towels", "discountPercentage": 21 },
        { "categoryName": "Placemat", "discountPercentage": 11 },
        { "categoryName": "Bath Accessories", "discountPercentage": 11 },
        { "categoryName": "Bedspreads", "discountPercentage": 21 },
        { "categoryName": "Shower Curtains", "discountPercentage": 24 },
        { "categoryName": "Pillow Top Mattresses", "discountPercentage": 10 }
      ]
    },
    {
      "eventName": "Big Bargain Blitz",
      "promotionalDates": {
        "startDate": { "Year": 2024, "Month": 3, "Day": 25 },
        "endDate": { "Year": 2024, "Month": 4, "Day": 3 }
      },
      "discounts": [
        { "categoryName": "Mattress Toppers", "discountPercentage": 24 },
        { "categoryName": "Pillow Cases", "discountPercentage": 14 },
        { "categoryName": "Soap Dispensers", "discountPercentage": 20 },
        { "categoryName": "Beach Towels", "discountPercentage": 18 },
        { "categoryName": "Bath Mats", "discountPercentage": 22 },
        { "categoryName": "Blankets", "discountPercentage": 12 },
        { "categoryName": "Kitchen Towels", "discountPercentage": 8 },
        { "categoryName": "Memory Foam Mattresses", "discountPercentage": 14 },
        { "categoryName": "Placemat", "discountPercentage": 17 },
        { "categoryName": "Bed Frames", "discountPercentage": 23 }
      ]
    },
    {
      "eventName": "Massive Markdown Mania",
      "promotionalDates": {
        "startDate": { "Year": 2024, "Month": 6, "Day": 23 },
        "endDate": { "Year": 2024, "Month": 6, "Day": 30 }
      },
      "discounts": [
        { "categoryName": "Bed Skirts", "discountPercentage": 17 },
        { "categoryName": "Shower Curtains", "discountPercentage": 23 },
        { "categoryName": "Bath Towels", "discountPercentage": 21 },
        { "categoryName": "Memory Foam Mattresses", "discountPercentage": 11 },
        { "categoryName": "Bathrobes", "discountPercentage": 19 },
        { "categoryName": "Bath Accessories", "discountPercentage": 5 },
        { "categoryName": "Box Springs", "discountPercentage": 21 },
        { "categoryName": "Hand Towels", "discountPercentage": 13 },
        { "categoryName": "Tablecloths", "discountPercentage": 19 },
        { "categoryName": "Duvet Covers", "discountPercentage": 23 }
      ]
    },
    {
      "eventName": "Unbeatable Bargain Bash",
      "promotionalDates": {
        "startDate": { "Year": 2024, "Month": 9, "Day": 21 },
        "endDate": { "Year": 2024, "Month": 9, "Day": 30 }
      },
      "discounts": [
        { "categoryName": "Adjustable Beds", "discountPercentage": 19 },
        { "categoryName": "Mattress Toppers", "discountPercentage": 23 },
        { "categoryName": "Washcloths", "discountPercentage": 7 },
        { "categoryName": "Comforters", "discountPercentage": 24 },
        { "categoryName": "Kitchen Towels", "discountPercentage": 7 },
        { "categoryName": "Pillows", "discountPercentage": 13 },
        { "categoryName": "Bath Sheets", "discountPercentage": 25 },
        { "categoryName": "Napkins", "discountPercentage": 25 },
        { "categoryName": "Bath Towels", "discountPercentage": 15 },
        { "categoryName": "Beach Towels", "discountPercentage": 15 }
      ]
    }
  ],
  "company": "First Up Consultants",
  "city": "Port Antone",
  "storeOpeningDate": { "$date": "2024-09-19T17:31:59.665Z" },
  "lastUpdated": { "$timestamp": { "t": 1729359119, "i": 1 } }
}
```

### Example 1: Find stores by name pattern

This query retrieves all the stores containing "Consultants" in their name (case-insensitive).

```javascript
db.stores.find(
  { name: { $regex: "Consultants", $options: "i" } },
  { _id: 1, name: 1, storeOpeningDate: 1 }
).limit(3)
```

The first three results returned by this query are:

```json
[
  {
    "_id": "39acb3aa-f350-41cb-9279-9e34c004415a",
    "name": "First Up Consultants | Bed and Bath Pantry - Port Antone",
    "storeOpeningDate": "2024-09-19T17:31:59.665Z"
  },
  {
    "_id": "26afb024-53c7-4e94-988c-5eede72277d5",
    "name": "First Up Consultants | Microphone Bazaar - South Lexusland",
    "storeOpeningDate": "2024-09-10T13:43:51.209Z"
  },
  {
    "_id": "62438f5f-0c56-4a21-8c6c-6bfa479494ad",
    "name": "First Up Consultants | Plumbing Supply Shoppe - New Ubaldofort",
    "storeOpeningDate": "2024-09-19T08:27:44.268Z"
  }
]
```

### Example 2: Advanced pattern matching for category names

This query retrieves stores selling products with a category name that starts with a vowel.

```javascript
db.stores.find(
  {
    "sales.salesByCategory.categoryName": { $regex: "^[AEIOUaeiou]" }
  },
  { _id: 1, name: 1, "sales.salesByCategory.categoryName": 1 }
).limit(2)
```

The first two results returned by this query are:

```json
[
  {
    "_id": "e6410bb3-843d-4fa6-8c70-7472925f6d0a",
    "name": "Relecloud | Toy Collection - North Jaylan",
    "sales": { 
      "salesByCategory": [ 
        { "categoryName": "Educational Toys" } 
      ] 
    }
  },
  {
    "_id": "4e064f0a-7e30-4701-9a80-eff3caf46ce8",
    "name": "Fourth Coffee | Outdoor Furniture Deals - Lucianohaven",
    "sales": {
      "salesByCategory": [
        { "categoryName": "Outdoor Swings" },
        { "categoryName": "Hammocks" }
      ]
    }
  }
]
```

### Example 3: Find stores with specific naming conventions

This query retrieves stores with names containing a pipe character (|) separator.

```javascript
db.stores.find(
{ name: { $regex: "\\|" }},
{ _id: 1, name: 1, "sales.salesByCategory.categoryName": 1}).limit(2)
```

The first two results returned by this query are:

```json
[
  {
    "_id": "905d1939-e03a-413e-a9c4-221f74055aac",
    "name": "Trey Research | Home Office Depot - Lake Freeda",
    "sales": { 
      "salesByCategory": [ 
        { "categoryName": "Desk Lamps" } 
      ] 
    }
  },
  {
    "_id": "a715ab0f-4c6e-4e9d-a812-f2fab11ce0b6",
    "name": "Lakeshore Retail | Holiday Supply Hub - Marvinfort",
    "sales": { 
      "salesByCategory": [ 
        { "categoryName": "Stockings" } 
      ] 
    }
  }
]
```

### Example 4: Complex pattern for discount categories

This query retrieves stores with categories containing both "Bath" and ending with "s".

```javascript
db.stores.aggregate([
  { $match: { "promotionEvents.discounts.categoryName": { $regex: "Bath.*s$", $options: "i" } } },
  { $project: { "_id": 1, "name": 1, "promotionEvents.discounts.categoryName":1 }},
  { $match: {"promotionEvents.discounts.categoryName": { $ne: [] }} },
  { $limit: 2 }])
```

The first two results returned by this query are:

```json
[
  {
    "_id": "39acb3aa-f350-41cb-9279-9e34c004415a",
    "name": "First Up Consultants | Bed and Bath Pantry - Port Antone",
    "promotionEvents": [
      {
        "discounts": [
          { "categoryName": "Bath Sheets", "discountPercentage": 16 },
          { "categoryName": "Bath Accessories", "discountPercentage": 11 }
        ]
      },
      {
        "discounts": [ 
          { "categoryName": "Bath Mats", "discountPercentage": 22 } 
        ]
      },
      {
        "discounts": [
          { "categoryName": "Bath Towels", "discountPercentage": 21 },
          { "categoryName": "Bathrobes", "discountPercentage": 19 },
          { "categoryName": "Bath Accessories", "discountPercentage": 5 }
        ]
      },
      {
        "discounts": [
          { "categoryName": "Bath Sheets", "discountPercentage": 25 },
          { "categoryName": "Bath Towels", "discountPercentage": 15 }
        ]
      }
    ]
  },
  {
    "_id": "27ef6004-70fa-4217-8395-0eabc4cc9841",
    "name": "Fabrikam, Inc. | Bed and Bath Store - O'Connerborough",
    "promotionEvents": [
      {
        "discounts": [
          { "categoryName": "Bath Accessories", "discountPercentage": 24 }
        ]
      },
      {
        "discounts": [
          { "categoryName": "Bathrobes", "discountPercentage": 18 },
          { "categoryName": "Bath Towels", "discountPercentage": 14 },
          { "categoryName": "Bath Accessories", "discountPercentage": 20 }
        ]
      }
    ]
  }
]
```
