dependencies {
    implementation(project(":libs:common-event"))
    
    implementation("org.springframework.boot:spring-boot-starter-data-jpa")
    // OutboxPollingPublisher가 KafkaTemplate을 직접 사용하므로 소비 서비스의 전이 의존성에 기대지 않는다.
    implementation("org.springframework.kafka:spring-kafka")
    implementation("com.fasterxml.jackson.core:jackson-databind")
    implementation("com.fasterxml.jackson.datatype:jackson-datatype-jsr310")
    
    compileOnly("org.projectlombok:lombok")
    annotationProcessor("org.projectlombok:lombok")
}
