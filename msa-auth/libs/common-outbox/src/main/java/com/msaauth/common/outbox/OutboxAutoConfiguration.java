package com.msaauth.common.outbox;

import org.springframework.boot.autoconfigure.AutoConfiguration;
import org.springframework.boot.autoconfigure.condition.ConditionalOnProperty;
import org.springframework.boot.context.properties.EnableConfigurationProperties;
import org.springframework.context.annotation.ComponentScan;
import org.springframework.data.jpa.repository.config.EnableJpaRepositories;
import org.springframework.scheduling.annotation.EnableScheduling;

@AutoConfiguration
@ConditionalOnProperty(prefix = "msa.outbox", name = "enabled", havingValue = "true", matchIfMissing = true)
@EnableScheduling
@ComponentScan(basePackages = "com.msaauth.common.outbox")
@EnableJpaRepositories(basePackages = "com.msaauth.common.outbox")
public class OutboxAutoConfiguration {
}
