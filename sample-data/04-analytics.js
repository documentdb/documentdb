// Initialize analytics collection with sample data
print("Initializing analytics collection...");

// Switch to the sampledb database
use('sampledb');

// Create analytics collection and insert sample analytics data
db.analytics.insertMany([
    {
        _id: "analytics_2024_06",
        period: "2024-06",
        type: "monthly_summary",
        metrics: {
            totalUsers: 5,
            activeUsers: 4,
            newUsers: 2,
            totalOrders: 4,
            totalRevenue: 1721.08,
            averageOrderValue: 430.27,
            topSellingProducts: [
                { productId: "prod5", productName: "Professional Camera Lens", quantitySold: 1, revenue: 899.99 },
                { productId: "prod1", productName: "Wireless Bluetooth Headphones", quantitySold: 1, revenue: 199.99 },
                { productId: "prod3", productName: "Smart Fitness Watch", quantitySold: 1, revenue: 299.99 }
            ],
            categoryBreakdown: [
                { category: "Electronics", orders: 2, revenue: 499.98 },
                { category: "Photography", orders: 1, revenue: 899.99 },
                { category: "Food & Beverages", orders: 1, revenue: 74.97 },
                { category: "Lifestyle", orders: 3, revenue: 119.96 }
            ]
        },
        generatedAt: new Date("2024-07-01T00:00:00Z")
    },
    {
        _id: "user_activity_2024_06_20",
        date: "2024-06-20",
        type: "daily_user_activity",
        activities: [
            {
                userId: "user1",
                actions: [
                    { action: "login", timestamp: new Date("2024-06-20T08:30:00Z") },
                    { action: "view_product", productId: "prod2", timestamp: new Date("2024-06-20T08:35:00Z") },
                    { action: "view_orders", timestamp: new Date("2024-06-20T08:40:00Z") }
                ]
            },
            {
                userId: "user5",
                actions: [
                    { action: "login", timestamp: new Date("2024-06-20T14:15:00Z") },
                    { action: "view_product", productId: "prod5", timestamp: new Date("2024-06-20T14:20:00Z") },
                    { action: "add_to_cart", productId: "prod5", timestamp: new Date("2024-06-20T14:25:00Z") },
                    { action: "place_order", orderId: "order4", timestamp: new Date("2024-06-20T14:30:00Z") }
                ]
            }
        ]
    }
]);

// Create indexes for analytics queries
db.runCommand({
    createIndexes: "analytics",
    indexes: [
        { key: { "period": 1 }, name: "period_1" },
        { key: { "type": 1 }, name: "type_1" },
        { key: { "date": 1 }, name: "date_1" }
    ]
});

print("Created indexes on analytics collection");
