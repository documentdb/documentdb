---
title: $text
description: The $text operator performs text search on the content of indexed string fields, enabling full-text search capabilities.
type: operators
category: evaluation-query
---

# $text

The `$text` operator performs text search on the content of indexed string fields. It enables full-text search capabilities by searching for specified words or phrases across text-indexed fields. The `$text` operator requires at least one text index on the collection and provides features like stemming, stop word removal, and relevance scoring.

## Syntax

```javascript
{
  $text: {
    $search: <string>,
    $language: <string>,
    $caseSensitive: <boolean>,
    $diacriticSensitive: <boolean>
  }
}
```

## Parameters

| Parameter | Description |
| --- | --- |
| **`$search`** | Required. The search string containing the terms to search for. Multiple terms are treated as an OR operation unless enclosed in quotes for phrase matching. |
| **`$language`** | Optional. Language for the text search, which determines the stemming rules and stop words, though the system uses the index's default language if you don't specify one |
| **`$caseSensitive`** | Optional. Boolean flag to enable case-sensitive search. Default is false (case-insensitive). |
| **`$diacriticSensitive`** | Optional. Boolean flag to enable diacritic-sensitive search. Default is false (diacritic-insensitive). |

## Prerequisite

Before using the `$text` operator, you must create a text index on the fields you want to search.

## Examples

Let's understand the usage with sample json from `stores` dataset.

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

### Example 1: Simple text search

This query retrieves stores containing the word "Microphone" in indexed text fields.

```javascript
// First create a text index
db.stores.createIndex({ "name": "text", "sales.salesByCategory.categoryName": "text" })

// Then perform the search
db.stores.find(
{ $text: { $search: "Microphone" }},
{ _id: 1, name: 1, "sales.salesByCategory.categoryName": 1 }).limit(2)
```

The first two results returned by this query are:

```json
[
  {
    "_id": "26afb024-53c7-4e94-988c-5eede72277d5",
    "name": "First Up Consultants | Microphone Bazaar - South Lexusland",
    "sales": {
      "salesByCategory": [
        { "categoryName": "Lavalier Microphones" },
        { "categoryName": "Wireless Microphones" }
      ]
    }
  },
  {
    "_id": "7cecdb2d-33c2-434c-ad55-bf529f68044b",
    "name": "Contoso, Ltd. | Microphone Haven - O'Connellside",
    "sales": {
      "salesByCategory": [
        { "categoryName": "Microphone Accessories" },
        { "categoryName": "Wireless Microphones" }
      ]
    }
  }
]
```

### Example 2: Multiple term search

The query retrieves stores related to "Home Decor" (multiple terms treated as `OR` by default).

```javascript
// First create a text index
db.stores.createIndex({ "name": "text", "sales.salesByCategory.categoryName": "text" })

// Then perform the search
db.stores.find(
{ $text: { $search: "Home Decor" }},
{ _id: 1, name: 1, "sales.salesByCategory.categoryName": 1 }).limit(5)
```

The first five results returned by this query are:

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
    "_id": "923d2228-6a28-4856-ac9d-77c39eaf1800",
    "name": "Lakeshore Retail | Home Decor Hub - Franciscoton",
    "sales": {
      "salesByCategory": [ 
        { "categoryName": "Lamps" }, 
        { "categoryName": "Rugs" } 
      ]
    }
  },
  {
    "_id": "1a2c387b-bb43-4b14-a6cd-cc05a5dbfbd5",
    "name": "Contoso, Ltd. | Smart Home Device Vault - Port Katarina",
    "sales": {
      "salesByCategory": [
        { "categoryName": "Smart Locks" },
        { "categoryName": "Smart Home Hubs" }
      ]
    }
  },
  {
    "_id": "15e9ca57-ebc1-4191-81c2-5dc2f4ebd973",
    "name": "Trey Research | Gardening Supply Stop - Port Saul",
    "sales": {
      "salesByCategory": [
        { "categoryName": "Garden Decor" },
        { "categoryName": "Pruning Shears" }
      ]
    }
  },
  {
    "_id": "dda2a7d2-6984-40cc-bbea-4cbfbc06d8a3",
    "name": "Contoso, Ltd. | Home Improvement Closet - Jaskolskiview",
    "sales": {
      "salesByCategory": [ 
        { "categoryName": "Lumber" }, 
        { "categoryName": "Windows" } 
      ]
    }
  }
]
```

### Example 3: Phrase search

This query searches for the exact phrase "Home Theater" using quotes.

```javascript
db.stores.find(
 { $text: { $search: "\"Home Theater\"" }},
 { _id: 1, name: 1, "sales.salesByCategory.categoryName": 1 }).limit(2)
```

The first two results returned by this query are:

```json
[
  {
    "_id": "0bc4f653-e64e-4342-ae7f-9611dfd37800",
    "name": "Tailwind Traders | Speaker Bazaar - North Mireyamouth",
    "sales": { 
      "salesByCategory": [ 
        { "categoryName": "Home Theater Speakers" } 
      ] 
    }
  },
  {
    "_id": "28bb05ed-d516-4186-9144-b9eeee30917a",
    "name": "Adatum Corporation | Home Entertainment Market - East Bennettville",
    "sales": {
      "salesByCategory": [
        { "categoryName": "Media Players" },
        { "categoryName": "Home Theater Projectors" },
        { "categoryName": "Projector Accessories" },
        { "categoryName": "Sound Bars" },
        { "categoryName": "Blu-ray Players" }
      ]
    }
  }
]
```

### Example 4: Exclude terms with negation

This query searches for stores with "Audio" but exclude the ones with "Wireless".

```javascript
db.stores.find(
 { $text: { $search: "Audio -Wireless" }},
 { _id: 1, name: 1, "sales.salesByCategory.categoryName": 1 }).limit(2)
```

The first two results returned by this query are:

```json
[
  {
    "_id": "32afe6ec-dd3c-46b3-a681-ed041b032c39",
    "name": "Relecloud | Audio Equipment Gallery - Margretshire",
    "sales": {
      "salesByCategory": [
        { "categoryName": "Audio Receivers" },
        { "categoryName": "Portable Bluetooth Speakers" }
      ]
    }
  },
  {
    "_id": "a3d3e59f-54bd-44be-943c-50dca5c4d667",
    "name": "Contoso, Ltd. | Audio Equipment Shop - West Darrion",
    "sales": { 
      "salesByCategory": [ 
        { "categoryName": "Soundbars" } 
      ] 
    }
  }
]
```

### Example 5: Case-sensitive search

> [!NOTE]
> Support for case-sensitive is in pipeline and should be released soon.

The example allows performing a case-sensitive search for "BAZAAR".

```javascript
db.stores.find(
  { $text: { $search: "BAZAAR", $caseSensitive: true } },
  { _id: 1, name: 1, "sales.salesByCategory.categoryName": 1 }
).limit(2)
```

The query will match documents where "BAZAAR" appears in exactly that case.

```json
[
 {
    "_id": "future-electronics-001",
    "name": "Future Electronics Hub",
    "sales": { "totalSales": 25000 }
  },
  {
    "_id": "40d6f4d7-50cd-4929-9a07-0a7a133c2e74",
    "name": "Proseware, Inc. | Home Entertainment Hub - East Linwoodbury",
    "sales": {
      "salesByCategory": [
        { "categoryName": "Sound Bars" },
        { "categoryName": "Game Controllers" },
        { "categoryName": "Remote Controls" },
        { "categoryName": "VR Games" }
      ],
      "totalSales": 160000
    }
  }
]
```

### Example 6: Get text search scores

This query retrieves text search results with relevance scores for ranking.

```javascript
db.stores.find(
  { $text: { $search: "Hub" } },
  { score: { $meta: "textScore" } }
).sort({ score: { $meta: "textScore" } }).limit(5)
```

The first five results returned by this query are:

```json
[
  { "_id": "511c9932-d647-48dd-9bd8-baf47b593f88", "score": 2 },
  { "_id": "a0a2f05c-6085-4c99-9781-689af759662f", "score": 2 },
  { "_id": "fb5aa470-557c-43cb-8ca0-5915d6cae34b", "score": 2 },
  { "_id": "1a2c387b-bb43-4b14-a6cd-cc05a5dbfbd5", "score": 1 },
  { "_id": "40d6f4d7-50cd-4929-9a07-0a7a133c2e74", "score": 1 }
]
```

### Example 7: Search across multiple categories

First, create a comprehensive text index to search across all text fields.

```javascript
// Create comprehensive text index
db.stores.createIndex({ 
  name: "text",
  "sales.salesByCategory.categoryName": "text",
  "promotionEvents.eventName": "text",
  "promotionEvents.discounts.categoryName": "text"
})

// Search across all indexed fields
db.stores.find(
{ $text: { $search: "\"Home Theater\"" }},
{ name: 1, "sales.salesByCategory.categoryName": 1, "promotionEvents.eventName": 1, "promotionEvents.discounts.categoryName": 1}).limit(2)
```

The first two results returned by this query.

```json
[
  {
    "_id": "40d6f4d7-50cd-4929-9a07-0a7a133c2e74",
    "name": "Proseware, Inc. | Home Entertainment Hub - East Linwoodbury",
    "sales": {
      "salesByCategory": [
        { "categoryName": "Sound Bars" },
        { "categoryName": "Game Controllers" },
        { "categoryName": "Remote Controls" },
        { "categoryName": "VR Games" }
      ]
    },
    "promotionEvents": [
      {
        "eventName": "Massive Markdown Mania",
        "discounts": [
          { "categoryName": "DVD Players" },
          { "categoryName": "Projector Lamps" },
          { "categoryName": "Media Players" },
          { "categoryName": "Blu-ray Players" },
          { "categoryName": "Home Theater Systems" },
          { "categoryName": "Televisions" }
        ]
      },
      {
        "eventName": "Fantastic Deal Days",
        "discounts": [
          { "categoryName": "TV Mounts" },
          { "categoryName": "Game Accessories" },
          { "categoryName": "Portable Projectors" },
          { "categoryName": "Projector Screens" },
          { "categoryName": "Blu-ray Players" },
          { "categoryName": "DVD Players" }
        ]
      },
      {
        "eventName": "Discount Delight Days",
        "discounts": [
          { "categoryName": "Game Controllers" },
          { "categoryName": "Home Theater Projectors" },
          { "categoryName": "Sound Bars" },
          { "categoryName": "Media Players" },
          { "categoryName": "Televisions" },
          { "categoryName": "Projector Lamps" }
        ]
      },
      {
        "eventName": "Super Sale Spectacular",
        "discounts": [
          { "categoryName": "Laser Projectors" },
          { "categoryName": "Projector Screens" },
          { "categoryName": "PC Games" },
          { "categoryName": "PlayStation Games" },
          { "categoryName": "TV Mounts" },
          { "categoryName": "Mobile Games" }
        ]
      },
      {
        "eventName": "Grand Deal Days",
        "discounts": [
          { "categoryName": "Remote Controls" },
          { "categoryName": "Televisions" },
          { "categoryName": "Business Projectors" },
          { "categoryName": "Laser Projectors" },
          { "categoryName": "Projectors" },
          { "categoryName": "Projector Screens" }
        ]
      },
      {
        "eventName": "Major Bargain Bash",
        "discounts": [
          { "categoryName": "Sound Bars" },
          { "categoryName": "VR Games" },
          { "categoryName": "Xbox Games" },
          { "categoryName": "Projector Accessories" },
          { "categoryName": "Mobile Games" },
          { "categoryName": "Projector Cases" }
        ]
      }
    ]
  },
  {
    "_id": "0bc4f653-e64e-4342-ae7f-9611dfd37800",
    "name": "Tailwind Traders | Speaker Bazaar - North Mireyamouth",
    "sales": { 
      "salesByCategory": [ 
        { "categoryName": "Home Theater Speakers" } 
      ] 
    },
    "promotionEvents": [
      {
        "eventName": "Epic Bargain Bash",
        "discounts": [
          { "categoryName": "Bluetooth Speakers" },
          { "categoryName": "Outdoor Speakers" }
        ]
      },
      {
        "eventName": "Fantastic Deal Days",
        "discounts": [
          { "categoryName": "Portable Speakers" },
          { "categoryName": "Home Theater Speakers" }
        ]
      }
    ]
  }
]
```
