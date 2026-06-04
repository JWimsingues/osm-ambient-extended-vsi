package com.bnpp.osm.poc.msb;

import com.bnpp.osm.poc.common.HttpSupport;
import com.bnpp.osm.poc.common.TraceLog;
import com.sun.net.httpserver.HttpExchange;
import com.sun.net.httpserver.HttpServer;

import java.io.IOException;
import java.io.OutputStream;
import java.net.InetSocketAddress;
import java.nio.charset.StandardCharsets;
import java.util.Map;
import java.util.concurrent.Executors;
import java.util.stream.Collectors;

public final class MsBApplication {

    private static final String SERVICE = "ms-b";

    public static void main(String[] args) throws Exception {
        int port = Integer.parseInt(env("PORT", "8080"));
        String msCUrl = env("MS_C_URL", "http://ms-c:8080");

        HttpServer server = HttpServer.create(new InetSocketAddress("0.0.0.0", port), 0);
        server.createContext("/health", MsBApplication::health);
        server.createContext("/api/info", exchange -> json(exchange, 200, Map.of(
                "service", SERVICE,
                "allowedCaller", "ms-a only",
                "allowedTarget", "ms-c only",
                "role", "middle service on cluster")));
        server.createContext("/api/handle-from-a", exchange -> handleFromA(exchange, msCUrl));
        server.setExecutor(Executors.newCachedThreadPool());
        server.start();

        TraceLog.info(SERVICE, "-", "STARTUP", "listening on port " + port + " downstreamC=" + msCUrl);
    }

    private static void health(HttpExchange exchange) throws IOException {
        text(exchange, 200, "OK");
    }

    private static void handleFromA(HttpExchange exchange, String msCUrl) throws IOException {
        String traceId = traceId(exchange);
        TraceLog.info(SERVICE, traceId, "FROM_A", "ms-b received call from ms-a");
        TraceLog.info(SERVICE, traceId, "CALL_C", "ms-b is calling ms-c");
        try {
            String body = HttpSupport.get(SERVICE, traceId, "CALL_C", msCUrl + "/api/handle-from-b");
            json(exchange, 200, Map.of(
                    "service", SERVICE,
                    "traceId", traceId,
                    "downstream", body));
        } catch (Exception e) {
            TraceLog.error(SERVICE, traceId, "CALL_C", "failed to reach ms-c", e);
            json(exchange, 502, Map.of("service", SERVICE, "traceId", traceId, "error", e.getMessage()));
        }
    }

    private static String traceId(HttpExchange exchange) {
        String header = exchange.getRequestHeaders().getFirst(TraceLog.TRACE_HEADER);
        return header == null || header.isBlank() ? TraceLog.newTraceId() : header;
    }

    private static void json(HttpExchange exchange, int status, Map<String, String> map) throws IOException {
        String body = map.entrySet().stream()
                .map(e -> "\"" + e.getKey() + "\":\"" + escape(e.getValue()) + "\"")
                .collect(Collectors.joining(",", "{", "}"));
        byte[] bytes = body.getBytes(StandardCharsets.UTF_8);
        exchange.getResponseHeaders().set("Content-Type", "application/json");
        exchange.sendResponseHeaders(status, bytes.length);
        try (OutputStream os = exchange.getResponseBody()) {
            os.write(bytes);
        }
    }

    private static void text(HttpExchange exchange, int status, String body) throws IOException {
        byte[] bytes = body.getBytes(StandardCharsets.UTF_8);
        exchange.sendResponseHeaders(status, bytes.length);
        try (OutputStream os = exchange.getResponseBody()) {
            os.write(bytes);
        }
    }

    private static String escape(String value) {
        return value.replace("\\", "\\\\").replace("\"", "\\\"");
    }

    private static String env(String key, String defaultValue) {
        String value = System.getenv(key);
        return value == null || value.isBlank() ? defaultValue : value;
    }
}
