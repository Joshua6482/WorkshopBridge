package com.workshopbridge;

import java.io.IOException;
import java.net.URI;
import java.net.http.HttpClient;
import java.net.http.HttpRequest;
import java.net.http.HttpResponse;
import java.nio.charset.StandardCharsets;
import java.time.Duration;
import java.util.ArrayList;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Set;
import java.util.regex.Matcher;
import java.util.regex.Pattern;

/**
 * Workshop "required items" (mod dependency) resolution.
 *
 * Steam's Web API exposes no dependency field (verified against the live
 * GetPublishedFileDetails, including with includechildren=true: children
 * are a collections-only concept), so this scrapes the public workshop
 * page, which renders a "Required items" panel:
 *
 * <pre>
 * &lt;div class="requiredItemsContainer" id="RequiredItems"&gt;
 *   &lt;a href=".../workshop/filedetails/?id=123"&gt;
 *     &lt;div class="requiredItem"&gt;Some Library&lt;/div&gt;
 *   &lt;/a&gt;
 *   ...
 * &lt;/div&gt;
 * </pre>
 *
 * Best-effort by design: any fetch or parse failure yields an empty (or
 * partial) list, never an exception, so a Steam hiccup can never block an
 * install. If Steam changes the markup, the marker is simply not found and
 * no dependencies are reported.
 */
public final class WorkshopDependencies {
    private WorkshopDependencies() {}

    /** One required workshop item: id plus the title shown on the page. */
    public static final class Dep {
        public final String id;
        public final String title;
        Dep(String id, String title) {
            this.id = id;
            this.title = title;
        }
    }

    /** Transitive depth cap: deps of deps of deps, then stop. */
    private static final int MAX_DEPTH = 3;

    private static String pageBaseUrl() {
        return System.getProperty("workshopbridge.workshopPageUrl",
                "https://steamcommunity.com/sharedfiles/filedetails/");
    }

    private static final HttpClient CLIENT = HttpClient.newBuilder()
            .connectTimeout(Duration.ofSeconds(15))
            .followRedirects(HttpClient.Redirect.NORMAL)
            .build();

    /**
     * All transitive required-item ids for a workshop item, in discovery
     * order, cycles impossible. Never throws: on any failure returns what
     * was collected so far (possibly empty).
     */
    public static List<Dep> getRequired(String workshopId) {
        List<Dep> out = new ArrayList<>();
        if (workshopId == null || !workshopId.matches("\\d+")) {
            return out;
        }
        Set<String> seen = new LinkedHashSet<>();
        seen.add(workshopId);
        try {
            collectInto(workshopId, 0, seen, out, WorkshopDependencies::fetchAndParse);
        } catch (Throwable t) {
            // best-effort: a Steam hiccup must never break an install flow
            System.out.println("[WorkshopBridge] dependency check failed for "
                    + workshopId + ": " + t);
        }
        return out;
    }

    /** One page fetch plus parse; throws on HTTP/network failure. */
    private static List<Dep> fetchAndParse(String workshopId) throws IOException {
        return parseRequiredItems(fetchPage(workshopId));
    }

    private static String fetchPage(String workshopId) throws IOException {
        String url = pageBaseUrl() + "?id=" + workshopId;
        HttpRequest req = HttpRequest.newBuilder(URI.create(url))
                .timeout(Duration.ofSeconds(30))
                .header("User-Agent", "WorkshopBridge/1.0")
                .GET()
                .build();
        HttpResponse<String> resp;
        try {
            resp = CLIENT.send(req, HttpResponse.BodyHandlers.ofString(StandardCharsets.UTF_8));
        } catch (InterruptedException e) {
            Thread.currentThread().interrupt();
            throw new IOException("interrupted", e);
        } catch (IOException e) {
            throw new IOException(Net.friendlyMessage(e), e);
        }
        if (resp.statusCode() != 200) {
            throw new IOException("workshop page HTTP " + resp.statusCode());
        }
        return resp.body();
    }

    /** One page's direct dependencies; the unit injectable for tests. */
    interface DepFetcher {
        List<Dep> fetch(String workshopId) throws IOException;
    }

    /**
     * Depth-first transitive collection with cycle protection.
     * Package-private for tests.
     */
    static void collectInto(String id, int depth, Set<String> seen, List<Dep> out,
            DepFetcher fetcher) throws IOException {
        if (depth >= MAX_DEPTH) {
            return;
        }
        for (Dep d : fetcher.fetch(id)) {
            if (seen.add(d.id)) {
                out.add(d);
                collectInto(d.id, depth + 1, seen, out, fetcher);
            }
        }
    }

    /**
     * Parses one workshop page's RequiredItems container into (id, title)
     * pairs, in page order, duplicates dropped. Package-private for tests.
     */
    static List<Dep> parseRequiredItems(String html) {
        List<Dep> out = new ArrayList<>();
        if (html == null) {
            return out;
        }
        int start = html.indexOf("id=\"RequiredItems\"");
        if (start < 0) {
            return out;
        }
        // Bound the scan at the next panel so unrelated page links
        // (related items, creator's other mods) can never leak in.
        int end = html.indexOf("<!-- created by -->", start);
        if (end < 0 || end - start > 100_000) {
            end = Math.min(html.length(), start + 100_000);
        }
        Matcher m = DEP_PATTERN.matcher(html.substring(start, end));
        Set<String> seenIds = new LinkedHashSet<>();
        while (m.find()) {
            if (seenIds.add(m.group(1))) {
                out.add(new Dep(m.group(1), unescape(m.group(2).trim())));
            }
        }
        return out;
    }

    private static final Pattern DEP_PATTERN = Pattern.compile(
            "<a\\s[^>]*?href=\"[^\"]*?filedetails/\\?id=(\\d+)\"[^>]*>"
                    + "\\s*<div\\s+class=\"requiredItem\">\\s*(.*?)\\s*</div>",
            Pattern.CASE_INSENSITIVE | Pattern.DOTALL);

    /** Minimal HTML entity unescape for item titles. Package-private for tests. */
    static String unescape(String s) {
        return s.replace("&amp;", "&").replace("&lt;", "<").replace("&gt;", ">")
                .replace("&quot;", "\"").replace("&#39;", "'").replace("&#x27;", "'");
    }
}
