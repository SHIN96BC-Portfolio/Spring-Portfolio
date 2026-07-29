plugins {
    java
    id("org.springframework.boot") version "3.4.0" apply false
    id("io.spring.dependency-management") version "1.1.7" apply false
}

allprojects {
    group = "com.msaauth"
    version = "0.0.1-SNAPSHOT"

    repositories {
        mavenCentral()
    }
}

subprojects {
    apply(plugin = "java")
    apply(plugin = "io.spring.dependency-management")

    java {
        sourceCompatibility = JavaVersion.VERSION_21
        targetCompatibility = JavaVersion.VERSION_21
    }

    the<io.spring.gradle.dependencymanagement.dsl.DependencyManagementExtension>().apply {
        imports {
            mavenBom("org.springframework.boot:spring-boot-dependencies:3.2.0")
        }
    }

    tasks.withType<JavaCompile> {
        options.encoding = "UTF-8"
        options.compilerArgs.addAll(listOf("-parameters"))
    }

    tasks.withType<Test> {
        useJUnitPlatform()
    }
}

// Service subproject에 Spring Boot 적용
configure(subprojects.filter { it.path == ":auth-service" }) {
    apply(plugin = "org.springframework.boot")

    dependencies {
        "implementation"(project(":libs:common-event"))
        "implementation"(project(":libs:common-outbox"))
        "implementation"(project(":libs:common-kafka"))
        "implementation"(project(":libs:common-tracing"))
        "implementation"(project(":libs:common-web"))
    }
}
