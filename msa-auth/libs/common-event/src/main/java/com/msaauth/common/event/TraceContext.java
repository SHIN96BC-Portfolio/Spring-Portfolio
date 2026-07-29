package com.msaauth.common.event;

/**
 * 분산 추적 컨텍스트. 
 * 실제 구현은 common-tracing에서 제공.
 * 여기는 심플 fallback.
 */
public class TraceContext {
    private static final ThreadLocal<String> CURRENT = new ThreadLocal<>();

    public static void set(String traceId) {
        CURRENT.set(traceId);
    }

    public static String currentTraceId() {
        String tid = CURRENT.get();
        return tid != null ? tid : "no-trace";
    }

    public static void clear() {
        CURRENT.remove();
    }
}
