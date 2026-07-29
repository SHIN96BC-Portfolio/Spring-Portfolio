package com.msaplatform.edgegateway.adapter.in.web;

import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.RestController;

import java.util.Map;

@RestController
public class HealthController {

    @GetMapping("/hello")
    public Map<String, String> hello() {
        return Map.of("service", "edge-gateway", "message", "Hello from edge-gateway!");
    }
}
