---
title: $redact
description: The $redact operator filters the content of the documents based on access rights.
type: operators
category: aggregation
---

# $redact

The `$redact` stage in aggregation pipeline is used to filter fields of the documents in a collection dynamically based on access rights or other conditions. It processes each document in the pipeline and removes or retains fields based on the specified logic.

## Syntax

```javascript
{
  $redact: <expression>
}
```

## Parameters

| Parameter | Description |
| --- | --- |
| **`<expression>`** | A valid MongoDB expression that evaluates to one of the following: `$$DESCEND`, `$$PRUNE`, or `$$KEEP`. These variables determine whether to keep, remove, or traverse deeper into the document. |

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

### Example 1: Redacting sensitive information

This query filters the `promotionEvents` field for documents where the `discountPercentage` in a promotion exceeds 15%.

```javascript
db.stores.aggregate([
  {
    $redact: {
      $cond: {
        if: {
          $gt: ["$promotionEvents.discounts.discountPercentage", 15]
        },
        then: "$$PRUNE",
        else: "$$DESCEND"
      }
    }
  }
])
```

The first two results returned by this query are:

```json
[
    {
        "_id": "new-store-001",
        "name": "Adatum Corporation - Downtown Branch",
        "sales": {
            "totalSales": 5000
        },
        "createdDate": "2025-06-11T11:11:32.262Z",
        "status": "new",
        "staff": {
            "totalStaff": {
                "fullTime": 0,
                "partTime": 0
            }
        },
        "version": 1,
        "storeOpeningDate": "2025-06-11T11:11:32.262Z",
        "storeFeatures": 213
    },
    {
        "_id": "gaming-store-mall-001",
        "name": "Trey Research | Gaming Paradise - Mall Location",
        "location": {
            "lat": 35.6762,
            "lon": 139.6503
        },
        "createdDate": "2025-06-11T11:13:27.180Z",
        "status": "active",
        "staff": {
            "totalStaff": {
                "fullTime": 8,
                "partTime": 12
            },
            "manager": "Alex Johnson",
            "departments": [
                "gaming",
                "accessories",
                "repairs"
            ]
        },
        "sales": {
            "totalSales": 0,
            "salesByCategory": []
        },
        "operatingHours": {
            "weekdays": "10:00-22:00",
            "weekends": "09:00-23:00"
        },
        "metadata": {
            "version": 1,
            "source": "store-management-system"
        },
        "storeOpeningDate": "2025-06-11T11:11:32.262Z",
        "storeFeatures": 189
    }
]
```

### Example 2: Restricting access based on tags

This query removes all documents that contain the tag `#MembershipDeals`.

```javascript
db.stores.aggregate([
  {
    $redact: {
      $cond: {
        if: {
          $in: ["#MembershipDeals", "$tag"]
        },
        then: "$$PRUNE",
        else: "$$DESCEND"
      }
    }
  }
])
```
