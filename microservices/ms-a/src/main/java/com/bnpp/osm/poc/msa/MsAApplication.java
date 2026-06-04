package com.bnpp.osm.poc.msa;

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

public final class MsAApplication {

    private static final String SERVICE = "ms-a";

    public static void main(String[] args) throws Exception {
        int port = Integer.parseInt(env("PORT", "8080"));
        String msBUrl = env("MS_B_URL", "http://ms-b:8080");

        HttpServer server = HttpServer.create(new InetSocketAddress("0.0.0.0", port), 0);
        server.createContext("/health", MsAApplication::health);
        server.createContext("/api/info", exchange -> json(exchange, 200, Map.of(
                "service", SERVICE,
                "allowedCaller", "ms-c only (mesh AuthorizationPolicy)",
                "allowedTarget", "ms-b only",
                "role", "chain entrypoint on cluster")));
        server.createContext("/api/call-b", exchange -> callB(exchange, msBUrl));
        server.createContext("/api/handle-from-c", MsAApplication::handleFromC);
        server.createContext("/api/run-chain", exchange -> runChain(exchange, msBUrl));
        server.setExecutor(Executors.newCachedThreadPool());
        server.start();

        TraceLog.info(SERVICE, "-", "STARTUP", "listening on port " + port + " downstreamB=" + msBUrl);
    }

    private static void health(HttpExchange exchange) throws IOException {
        text(exchange, 200, "OK");
    }

    private static void callB(HttpExchange exchange, String msBUrl) throws IOException {
        String traceId = traceId(exchange);
        TraceLog.info(SERVICE, traceId, "CALL_B", "ms-a is calling ms-b");
        try {
            String body = HttpSupport.get(SERVICE, traceId, "CALL_B", msBUrl + "/api/handle-from-a");
            json(exchange, 200, Map.of("service", SERVICE, "traceId", traceId, "result", body));
        } catch (Exception e) {
            TraceLog.error(SERVICE, traceId, "CALL_B", "failed to reach ms-b", e);
            json(exchange, 502, Map.of("service", SERVICE, "traceId", traceId, "error", e.getMessage()));
        }
    }

    private static void handleFromC(HttpExchange exchange) throws IOException {
        String traceId = traceId(exchange);
        TraceLog.info(SERVICE, traceId, "FROM_C", "ms-a received call from ms-c (end of chain)");
        json(exchange, 200, Map.of(
                "service", SERVICE,
                "traceId", traceId,
                "message", "ms-a handled request from ms-c"));
    }

    private static void runChain(HttpExchange exchange, String msBUrl) throws IOException {
        callB(exchange, msBUrl);
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
