package com.msaplatform.common.tracing;

import com.msaplatform.common.event.TraceContext;
import jakarta.servlet.FilterChain;
import jakarta.servlet.ServletException;
import jakarta.servlet.http.HttpServletRequest;
import jakarta.servlet.http.HttpServletResponse;
import org.slf4j.MDC;
import org.springframework.core.Ordered;
import org.springframework.stereotype.Component;
import org.springframework.web.filter.OncePerRequestFilter;

import java.io.IOException;
import java.util.UUID;

@Component
public class TraceHttpFilter extends OncePerRequestFilter implements Ordered {

    public static final String TRACE_ID_HEADER = "X-Trace-Id";
    public static final String MDC_TRACE_ID = "traceId";

    @Override
    public int getOrder() { return Ordered.HIGHEST_PRECEDENCE; }

    @Override
    protected void doFilterInternal(HttpServletRequest req, HttpServletResponse res, FilterChain chain)
            throws ServletException, IOException {
        String tid = req.getHeader(TRACE_ID_HEADER);
        if (tid == null || tid.isBlank()) tid = UUID.randomUUID().toString();
        try {
            TraceContext.set(tid);
            MDC.put(MDC_TRACE_ID, tid);
            res.setHeader(TRACE_ID_HEADER, tid);
            chain.doFilter(req, res);
        } finally {
            TraceContext.clear();
            MDC.remove(MDC_TRACE_ID);
        }
    }
}
