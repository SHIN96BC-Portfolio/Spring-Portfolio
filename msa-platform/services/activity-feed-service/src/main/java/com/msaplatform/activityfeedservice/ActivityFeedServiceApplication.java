package com.msaplatform.activityfeedservice;

import org.springframework.boot.SpringApplication;
import org.springframework.boot.autoconfigure.SpringBootApplication;

/**
 * CQRS Read Model (MongoDB)
 */
@SpringBootApplication
public class ActivityFeedServiceApplication {

    public static void main(String[] args) {
        SpringApplication.run(ActivityFeedServiceApplication.class, args);
    }
}
