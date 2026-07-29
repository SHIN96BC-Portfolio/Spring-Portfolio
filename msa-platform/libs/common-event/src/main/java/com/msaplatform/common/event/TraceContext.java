package com.msaplatform.common.event;

public class TraceContext {
    private static final ThreadLocal<String> CURRENT = new ThreadLocal<>();

    public static void set(String traceId) { CURRENT.set(traceId); }
    public static String currentTraceId() {
        String tid = CURRENT.get();
        return tid != null ? tid : "no-trace";
    }
    public static void clear() { CURRENT.remove(); }
}
