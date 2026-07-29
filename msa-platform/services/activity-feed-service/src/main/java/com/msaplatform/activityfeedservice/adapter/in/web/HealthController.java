package com.msaplatform.activityfeedservice.adapter.in.web;

import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.RestController;

import java.util.Map;

@RestController
public class HealthController {

    @GetMapping("/hello")
    public Map<String, String> hello() {
        return Map.of("service", "activity-feed-service", "message", "Hello from activity-feed-service!");
    }
}
