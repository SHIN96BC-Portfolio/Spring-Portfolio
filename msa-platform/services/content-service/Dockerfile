FROM eclipse-temurin:21-jre-alpine

WORKDIR /app
COPY build/libs/content-service.jar app.jar

EXPOSE 8093

HEALTHCHECK --interval=30s --timeout=3s --start-period=30s \
  CMD wget --no-verbose --tries=1 --spider http://localhost:8093/actuator/health || exit 1

ENTRYPOINT ["java", "-jar", "app.jar"]
