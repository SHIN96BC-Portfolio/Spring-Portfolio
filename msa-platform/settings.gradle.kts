rootProject.name = "msa-platform"

// Common libraries
include(
    ":libs:common-event",
    ":libs:common-outbox",
    ":libs:common-kafka",
    ":libs:common-saga",
    ":libs:common-tracing",
    ":libs:common-web",
    ":libs:common-auth-client"
)

// Services (13개)
include(
    ":services:edge-gateway",
    ":services:user-bff",
    ":services:admin-bff",
    ":services:user-service",
    ":services:content-service",
    ":services:commerce-service",
    ":services:point-service",
    ":services:fashion-service",
    ":services:social-service",
    ":services:recommendation-service",
    ":services:activity-feed-service",
    ":services:notification-service",
    ":services:media-service"
)
