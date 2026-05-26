package com.bnpp.osm.poc.common;

import java.time.Instant;
import java.util.UUID;

public final class TraceLog {

    public static final String TRACE_HEADER = "X-Trace-Id";
    public static final String LOG_TYPE = "osm-poc-app";

    private static final boolean JSON =
            "json".equalsIgnoreCase(System.getenv().getOrDefault("LOG_FORMAT", "text"));

    private TraceLog() {
    }

    public static String newTraceId() {
        return UUID.randomUUID().toString();
    }

    public static void info(String service, String traceId, String action, String message) {
        emit("INFO", service, traceId, action, message, null);
    }

    public static void error(String service, String traceId, String action, String message, Throwable t) {
        String detail = t == null ? message : message + ": " + t.getMessage();
        emit("ERROR", service, traceId, action, detail, null);
    }

    private static void emit(
            String level,
            String service,
            String traceId,
            String action,
            String message,
            Void ignored) {
        if (JSON) {
            System.out.println(toJson(level, service, traceId, action, message));
            return;
        }
        var out = "ERROR".equals(level) ? System.err : System.out;
        out.printf(
                "%s [service=%s] [traceId=%s] [action=%s] %s%n",
                Instant.now(),
                service,
                traceId,
                action,
                message);
    }

    private static String toJson(
            String level,
            String service,
            String traceId,
            String action,
            String message) {
        return "{"
                + "\"timestamp\":\"" + Instant.now() + "\","
                + "\"level\":\"" + escape(level) + "\","
                + "\"logtype\":\"" + LOG_TYPE + "\","
                + "\"service\":\"" + escape(service) + "\","
                + "\"traceId\":\"" + escape(traceId) + "\","
                + "\"action\":\"" + escape(action) + "\","
                + "\"message\":\"" + escape(message) + "\""
                + "}";
    }

    private static String escape(String value) {
        if (value == null) {
            return "";
        }
        return value
                .replace("\\", "\\\\")
                .replace("\"", "\\\"")
                .replace("\n", "\\n")
                .replace("\r", "\\r");
    }
}
