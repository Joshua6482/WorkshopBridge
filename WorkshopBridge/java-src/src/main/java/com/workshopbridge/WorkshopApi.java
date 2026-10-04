package com.workshopbridge;

import java.io.IOException;
import java.net.URI;
import java.net.URLEncoder;
import java.net.http.HttpClient;
import java.net.http.HttpRequest;
import java.net.http.HttpResponse;
import java.nio.charset.StandardCharsets;
import java.time.Duration;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

/**
 * Keyless Steam Web API access: ISteamRemoteStorage/GetPublishedFileDetails
 * (update checks) and ISteamRemoteStorage/GetCollectionDetails (collection
 * imports). No API key required for either endpoint.
 */
public final class WorkshopApi {
    /**
     * Steam Web API endpoint, overridable via the
     * {@code workshopbridge.steamApiUrl} system property so tests can point
     * at a local stub server. Read per call, not cached at class-load: the
     * test suite parses fixtures through {@link #parseTimeUpdated} before it
     * sets the property, and a frozen URL would silently send every stubbed
     * check at the real Steam API.
     */
    private static String detailsUrl() {
        return System.getProperty("workshopbridge.steamApiUrl",
                "https://api.steampowered.com/ISteamRemoteStorage/GetPublishedFileDetails/v1/");
    }

    /**
     * Steam Web API collection endpoint, overridable the same way as
     * {@link #detailsUrl()}. This is a different endpoint from the file
     * details one: GetPublishedFileDetails never returns a collection's
     * children (verified against the live API), so collection imports must
     * go here. Keyless, like the details endpoint.
     */
    private static String collectionUrl() {
        String base = System.getProperty("workshopbridge.steamApiUrl", null);
        if (base != null) {
            return base;
        }
        return "https://api.steampowered.com/ISteamRemoteStorage/GetCollectionDetails/v1/";
    }

    private static final HttpClient CLIENT = HttpClient.newBuilder()
            .connectTimeout(Duration.ofSeconds(15))
            .build();

    private WorkshopApi() {}

    /**
     * Returns workshopId -> time_updated (unix seconds) for the given ids.
     * Ids with no usable entry are absent from the map.
     */
    public static Map<String, Long> getTimeUpdated(List<String> workshopIds) throws IOException {
        if (workshopIds.isEmpty()) {
            return new LinkedHashMap<>();
        }
        StringBuilder body = new StringBuilder("itemcount=").append(workshopIds.size());
        for (int i = 0; i < workshopIds.size(); i++) {
            body.append("&publishedfileids%5B").append(i).append("%5D=")
                    .append(URLEncoder.encode(workshopIds.get(i), StandardCharsets.UTF_8));
        }
        final String raw = postForm(detailsUrl(), body.toString());
        try {
            return parseTimeUpdated(raw);
        } catch (IllegalArgumentException e) {
            // a malformed response must fail the check: silently treating it
            // as "no items listed" would misreport every mod as deleted
            throw new IOException("malformed Steam API response: " + e.getMessage(), e);
        }
    }

    /**
     * Returns the workshop ids contained in a collection item, in order.
     * A non-collection id (or a deleted/private one) yields an empty list.
     * Uses GetCollectionDetails: GetPublishedFileDetails never returns a
     * collection's children (verified against the live API).
     */
    public static List<String> getCollectionChildren(String collectionId) throws IOException {
        if (collectionId == null || !collectionId.matches("\\d+")) {
            throw new IllegalArgumentException("invalid workshop id: " + collectionId);
        }
        String raw = postForm(collectionUrl(), "collectioncount=1&publishedfileids%5B0%5D="
                + URLEncoder.encode(collectionId, StandardCharsets.UTF_8));
        try {
            return parseChildren(raw);
        } catch (IllegalArgumentException e) {
            throw new IOException("malformed Steam API response: " + e.getMessage(), e);
        }
    }

    private static String postForm(String url, String formBody) throws IOException {
        HttpRequest req = HttpRequest.newBuilder(URI.create(url))
                .timeout(Duration.ofSeconds(30))
                .header("Content-Type", "application/x-www-form-urlencoded")
                .header("User-Agent", "WorkshopBridge/1.0")
                .POST(HttpRequest.BodyPublishers.ofString(formBody))
                .build();
        HttpResponse<String> resp;
        try {
            resp = CLIENT.send(req, HttpResponse.BodyHandlers.ofString());
        } catch (InterruptedException e) {
            Thread.currentThread().interrupt();
            throw new IOException("interrupted", e);
        } catch (IOException e) {
            throw new IOException(Net.friendlyMessage(e), e);
        }
        if (resp.statusCode() != 200) {
            throw new IOException("Steam API HTTP " + resp.statusCode());
        }
        return resp.body();
    }

    /**
     * Extracts workshopId -> time_updated from a GetPublishedFileDetails
     * response body. Package-private so tests can run it against captured
     * real responses (see tests/java/fixtures/).
     *
     * @throws IllegalArgumentException when the response is not JSON or is
     *         missing the expected structure ({@code response} object with a
     *         {@code publishedfiledetails} array). Individual malformed
     *         entries are skipped; a structurally invalid whole response is
     *         never silently treated as "no items".
     */
    static Map<String, Long> parseTimeUpdated(String json) {
        Map<String, Long> out = new LinkedHashMap<>();
        final Object root = Json.parse(json); // throws on malformed JSON
        Map<String, Object> rootObj = Json.object(root);
        Map<String, Object> response = rootObj == null ? null : Json.object(rootObj.get("response"));
        if (response == null) {
            throw new IllegalArgumentException("missing 'response' object");
        }
        List<Object> details = Json.array(response.get("publishedfiledetails"));
        if (details == null) {
            throw new IllegalArgumentException("missing 'publishedfiledetails' array");
        }
        for (Object d : details) {
            Map<String, Object> m = Json.object(d);
            if (m == null) {
                continue;
            }
            Object idObj = m.get("publishedfileid");
            final String id;
            if (idObj instanceof Number) {
                id = String.valueOf(((Number) idObj).longValue());
            } else {
                id = idObj == null ? null : String.valueOf(idObj);
            }
            Object tu = m.get("time_updated");
            long timeUpdated = tu instanceof Number ? ((Number) tu).longValue() : 0L;
            if (id != null && !id.isEmpty() && timeUpdated > 0) {
                out.put(id, timeUpdated);
            }
        }
        return out;
    }

    /**
     * Extracts the {@code children[].publishedfileid} list of the first
     * publishedfiledetails entry (collections only). Package-private so
     * tests can run it against captured real responses.
     *
     * @throws IllegalArgumentException when the response is not JSON or is
     *         missing the expected structure.
     */
    static List<String> parseChildren(String json) {
        List<String> out = new java.util.ArrayList<>();
        final Object root = Json.parse(json); // throws on malformed JSON
        Map<String, Object> rootObj = Json.object(root);
        Map<String, Object> response = rootObj == null ? null : Json.object(rootObj.get("response"));
        if (response == null) {
            throw new IllegalArgumentException("missing 'response' object");
        }
        List<Object> details = Json.array(response.get("collectiondetails"));
        if (details == null || details.isEmpty()) {
            throw new IllegalArgumentException("missing 'collectiondetails' array");
        }
        Map<String, Object> first = Json.object(details.get(0));
        if (first == null) {
            return out;
        }
        List<Object> children = Json.array(first.get("children"));
        if (children == null) {
            return out; // not a collection (or no children): not an error
        }
        for (Object c : children) {
            Map<String, Object> m = Json.object(c);
            if (m == null) {
                continue;
            }
            Object idObj = m.get("publishedfileid");
            final String id;
            if (idObj instanceof Number) {
                id = String.valueOf(((Number) idObj).longValue());
            } else {
                id = idObj == null ? null : String.valueOf(idObj);
            }
            if (id != null && !id.isEmpty()) {
                out.add(id);
            }
        }
        return out;
    }
}
