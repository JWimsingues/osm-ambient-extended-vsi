package com.bnpp.osm.poc.msc;

import com.bnpp.osm.poc.common.HttpSupport;
import com.bnpp.osm.poc.common.TraceLog;
import com.sun.net.httpserver.HttpExchange;
import com.sun.net.httpserver.HttpServer;

import java.io.IOException;
import java.io.OutputStream;
import java.net.InetSocketAddress;
import java.nio.charset.StandardCharsets;
import java.util.Map;
import java.util.stream.Collectors;

public final class MsCApplication {

    private static final String SERVICE = "ms-c";

    public static void main(String[] args) throws Exception {
        int port = Integer.parseInt(env("PORT", "8080"));
        String bindHost = env("BIND_HOST", "0.0.0.0");
        String msAUrl = env("MS_A_URL", "http://ms-a:8080");

        HttpServer server = HttpServer.create(new InetSocketAddress(bindHost, port), 0);
        server.createContext("/health", MsCApplication::health);
        server.createContext("/api/info", exchange -> json(exchange, 200, Map.of(
                "service", SERVICE,
                "allowedCaller", "ms-b only",
                "allowedTarget", "ms-a only",
                "role", "edge service on IBM Cloud VSI")));
        server.createContext("/api/handle-from-b", exchange -> handleFromB(exchange, msAUrl));
        server.createContext("/api/call-a", exchange -> callA(exchange, msAUrl));
        server.setExecutor(null);
        server.start();

        TraceLog.info(
                SERVICE,
                "-",
                "STARTUP",
                "listening on " + bindHost + ":" + port + " downstreamA=" + msAUrl);
    }

    private static void health(HttpExchange exchange) throws IOException {
        text(exchange, 200, "OK");
    }

    private static void handleFromB(HttpExchange exchange, String msAUrl) throws IOException {
        String traceId = traceId(exchange);
        TraceLog.info(SERVICE, traceId, "FROM_B", "ms-c received call from ms-b");
        TraceLog.info(SERVICE, traceId, "CALL_A", "ms-c is calling ms-a (closing the loop)");
        try {
            String body = HttpSupport.get(SERVICE, traceId, "CALL_A", msAUrl + "/api/handle-from-c");
            json(exchange, 200, Map.of(
                    "service", SERVICE,
                    "traceId", traceId,
                    "downstream", body));
        } catch (Exception e) {
            TraceLog.error(SERVICE, traceId, "CALL_A", "failed to reach ms-a", e);
            json(exchange, 502, Map.of("service", SERVICE, "traceId", traceId, "error", e.getMessage()));
        }
    }

    private static void callA(HttpExchange exchange, String msAUrl) throws IOException {
        String traceId = traceId(exchange);
        TraceLog.info(SERVICE, traceId, "CALL_A", "manual call from VSI to ms-a");
        try {
            String body = HttpSupport.get(SERVICE, traceId, "CALL_A", msAUrl + "/api/handle-from-c");
            json(exchange, 200, Map.of("service", SERVICE, "traceId", traceId, "result", body));
        } catch (Exception e) {
            TraceLog.error(SERVICE, traceId, "CALL_A", "failed to reach ms-a", e);
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
