rootProject.name = "msa-auth"

// Common libraries
include(
    ":libs:common-event",
    ":libs:common-outbox",
    ":libs:common-kafka",
    ":libs:common-tracing",
    ":libs:common-web"
)

// Application
include(":auth-service")
