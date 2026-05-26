package com.bnpp.osm.poc.common;

import java.io.IOException;
import java.net.URI;
import java.net.http.HttpClient;
import java.net.http.HttpRequest;
import java.net.http.HttpResponse;
import java.time.Duration;

public final class HttpSupport {

    private static final HttpClient CLIENT = HttpClient.newBuilder()
            .connectTimeout(Duration.ofSeconds(10))
            .build();

    private HttpSupport() {
    }

    public static String get(String service, String traceId, String action, String url) throws IOException, InterruptedException {
        TraceLog.info(service, traceId, action, "HTTP GET -> " + url);
        HttpRequest request = HttpRequest.newBuilder()
                .uri(URI.create(url))
                .timeout(Duration.ofSeconds(30))
                .header(TraceLog.TRACE_HEADER, traceId)
                .GET()
                .build();
        HttpResponse<String> response = CLIENT.send(request, HttpResponse.BodyHandlers.ofString());
        TraceLog.info(
                service,
                traceId,
                action,
                "HTTP GET <- status=" + response.statusCode() + " body=" + truncate(response.body()));
        return response.body();
    }

    private static String truncate(String body) {
        if (body == null) {
            return "";
        }
        return body.length() > 500 ? body.substring(0, 500) + "..." : body;
    }
}
