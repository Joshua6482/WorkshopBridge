package com.workshopbridge;

import java.io.IOException;
import java.net.URI;
import java.net.URLEncoder;
import java.net.http.HttpClient;
import java.net.http.HttpRequest;
import java.net.http.HttpResponse;
import java.nio.charset.StandardCharsets;
import java.time.Duration;
import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.concurrent.ConcurrentHashMap;
import java.util.concurrent.ConcurrentMap;
import java.util.function.Consumer;
import java.util.regex.Matcher;
import java.util.regex.Pattern;

/**
 * Workshop search by name, BOIII-style: scrape the public workshop browse
 * pages (Steam's Web API has no keyless search endpoint), regex the item
 * ids out of the HTML, then enrich via the keyless
 * {@link WorkshopApi#getDetails}. No API key needed.
 *
 * Rate-limit posture (Steam IP-bans aggressive scrapers for 15 min to 24 h):
 * sequential page fetches only, ~1s between pages, search results cached
 * 10 minutes, per-item metadata cached 1 hour, details fetched in batches
 * of 50. On HTTP 429 we stop immediately and report it; we never retry
 * into a longer ban.
 */
public final class WorkshopSearch {
    private WorkshopSearch() {}

    /** One search hit, metadata-enriched. */
    public static final class Item {
        public final String id;
        public final String title;
        /** Plain text; Steam BBCode stripped. */
        public final String description;
        public final List<String> tags;
        public final long subscribers;
        public final long fileSize;
        public final long timeUpdated;
        public final String previewUrl;
        public final long votesUp;
        public final long votesDown;

        Item(String id, String title, String description, List<String> tags,
                long subscribers, long fileSize, long timeUpdated,
                String previewUrl, long votesUp, long votesDown) {
            this.id = id;
            this.title = title;
            this.description = description;
            this.tags = tags;
            this.subscribers = subscribers;
            this.fileSize = fileSize;
            this.timeUpdated = timeUpdated;
            this.previewUrl = previewUrl;
            this.votesUp = votesUp;
            this.votesDown = votesDown;
        }

        /** Positive-vote ratio in 0..1, or -1 when there are no votes. */
        public double rating() {
            long total = votesUp + votesDown;
            return total == 0 ? -1.0 : (double) votesUp / total;
        }
    }

    /** Browse pages fetched per search (Lua chains one job per page). */
    static final int MAX_PAGES = 3;
    /** Gentle gap between page fetches; Steam rate-limits scrapers. */
    private static final int PAGE_DELAY_MS = 1000;
    /** Sanity cap on hits per page batch; keeps details calls and the UI list sane. */
    private static final int MAX_ITEMS = 150;

    private static final long PAGE_TTL_MS = 10 * 60 * 1000;
    private static final long DETAILS_TTL_MS = 60 * 60 * 1000;

    private static final int HTTP_OK = 200;
    private static final int HTTP_RATE_LIMITED = 429;

    /** Global fetch pacing: at most one browse fetch per PAGE_DELAY_MS,
     * no matter how the calls interleave. */
    private static final Object FETCH_LOCK = new Object();
    private static long lastFetchAt = 0;

    private static String browseBaseUrl() {
        return System.getProperty("workshopbridge.workshopBrowseUrl",
                "https://steamcommunity.com/workshop/browse/");
    }

    private static final HttpClient CLIENT = HttpClient.newBuilder()
            .connectTimeout(Duration.ofSeconds(15))
            .followRedirects(HttpClient.Redirect.NORMAL)
            .build();

    private static final class CacheEntry<T> {
        final T value;
        final long at;
        CacheEntry(T value, long at) {
            this.value = value;
            this.at = at;
        }
    }

    private static final ConcurrentMap<String, CacheEntry<List<String>>> PAGE_CACHE =
            new ConcurrentHashMap<>();
    private static final ConcurrentMap<String, CacheEntry<Item>> DETAILS_CACHE =
            new ConcurrentHashMap<>();

    /**
     * One page of enriched search results, in Steam's relevance order.
     * Never returns null. Throws IOException with a user-readable message
     * on network failure, rate limiting, or an unexpected page (Steam
     * markup drift); an empty list means no (more) hits.
     */
    public static List<Item> searchPage(String query, int page) throws IOException {
        return searchPage(query, page, WorkshopSearch::fetchPage);
    }

    /** searchPage with an injectable fetcher, for tests. */
    static List<Item> searchPage(String query, int page, PageFetcher fetcher) throws IOException {
        String q = query == null ? "" : query.trim();
        if (q.isEmpty()) {
            throw new IllegalArgumentException("empty search query");
        }
        if (page < 1 || page > MAX_PAGES) {
            throw new IllegalArgumentException("page out of range: " + page);
        }
        String key = q.toLowerCase(java.util.Locale.ROOT) + "\0" + page;
        CacheEntry<List<String>> cached = PAGE_CACHE.get(key);
        long now = System.currentTimeMillis();
        final List<String> ids;
        if (cached != null && now - cached.at < PAGE_TTL_MS) {
            ids = cached.value;
        } else {
            String html = fetcher.fetch(q, page);
            validatePage(html);
            ids = parseSearchIds(html);
            PAGE_CACHE.put(key, new CacheEntry<>(ids, now));
        }
        if (ids.size() > MAX_ITEMS) {
            return enrich(ids.subList(0, MAX_ITEMS), null);
        }
        return enrich(ids, null);
    }

    /** One browse page's HTML; throws on HTTP/network failure.
     * Self-pacing: real fetches never run closer than PAGE_DELAY_MS apart,
     * however the calls interleave. */
    private static String fetchPage(String query, int page) throws IOException {
        paceFetch();
        String url = browseBaseUrl()
                + "?appid=108600"
                + "&searchtext=" + URLEncoder.encode(query, StandardCharsets.UTF_8)
                + "&browsesort=textsearch&section=readytouseitems&actualsort=textsearch"
                + "&p=" + page;
        HttpRequest req = HttpRequest.newBuilder(URI.create(url))
                .timeout(Duration.ofSeconds(30))
                .header("User-Agent",
                        "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36")
                .header("Referer", "https://steamcommunity.com/app/108600/workshop/")
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
        if (resp.statusCode() == HTTP_RATE_LIMITED) {
            throw new IOException("Steam is rate-limiting this network right now - "
                    + "wait a while before searching again.");
        }
        if (resp.statusCode() != HTTP_OK) {
            throw new IOException("workshop search HTTP " + resp.statusCode());
        }
        return resp.body();
    }

    /** Page fetcher unit-injectable for tests. */
    @FunctionalInterface
    interface PageFetcher {
        String fetch(String query, int page) throws IOException;
    }

    /** Enforces the global minimum gap between real page fetches. */
    private static void paceFetch() throws IOException {
        long wait;
        synchronized (FETCH_LOCK) {
            wait = PAGE_DELAY_MS - (System.currentTimeMillis() - lastFetchAt);
        }
        if (wait > 0) {
            sleepQuietly(wait);
        }
        synchronized (FETCH_LOCK) {
            lastFetchAt = System.currentTimeMillis();
        }
    }

    /**
     * Rejects pages that are not search results: rate-limit pages and
     * anything that is not a workshop page at all (Steam markup drift).
     * A page with zero item ids but otherwise well-formed is a valid
     * empty result, not a failure.
     */
    static void validatePage(String html) throws IOException {
        if (isRateLimited(html)) {
            throw new IOException("Steam is rate-limiting this network right now - "
                    + "wait a while before searching again.");
        }
        if (html == null || !html.toLowerCase(java.util.Locale.ROOT).contains("workshop")) {
            throw new IOException("Steam returned an unexpected page - "
                    + "the workshop layout may have changed.");
        }
    }

    /** True when the HTML is Steam's "too many requests" page. */
    static boolean isRateLimited(String html) {
        return html != null && html.toLowerCase(java.util.Locale.ROOT).contains("too many requests");
    }

    /**
     * Item ids from one browse page, in page order, duplicates dropped.
     * Anchored on the thumbnail-link pattern (href + img), which is what
     * makes a hit a result row rather than a stray link. URL-based, never
     * CSS-class based: Steam obfuscates class names on every web deploy.
     * Package-private for tests.
     */
    static List<String> parseSearchIds(String html) {
        List<String> out = new ArrayList<>();
        if (html == null) {
            return out;
        }
        Matcher m = SEARCH_ID_PATTERN.matcher(html);
        Set<String> seen = new LinkedHashSet<>();
        while (m.find()) {
            if (seen.add(m.group(1))) {
                out.add(m.group(1));
            }
        }
        return out;
    }

    private static final Pattern SEARCH_ID_PATTERN = Pattern.compile(
            "<a\\s[^>]*?href=\"https://steamcommunity\\.com/sharedfiles/filedetails/\\?id=(\\d+)\""
                    + "[^>]*>\\s*<img",
            Pattern.CASE_INSENSITIVE | Pattern.DOTALL);

    /** Enriches ids with cached-or-fetched metadata, in id order. */
    static List<Item> enrich(List<String> ids, Consumer<String> progress) throws IOException {
        List<Item> out = new ArrayList<>();
        List<String> missing = new ArrayList<>();
        long now = System.currentTimeMillis();
        for (String id : ids) {
            CacheEntry<Item> e = DETAILS_CACHE.get(id);
            if (e != null && now - e.at < DETAILS_TTL_MS) {
                out.add(e.value);
            } else {
                missing.add(id);
            }
        }
        if (!missing.isEmpty()) {
            if (progress != null) {
                progress.accept("Loading mod details...");
            }
            Map<String, Map<String, Object>> details = WorkshopApi.getDetails(missing);
            for (String id : missing) {
                Map<String, Object> d = details.get(id);
                if (d == null) {
                    continue; // deleted/private since the scrape; skip
                }
                Item item = buildItem(id, d);
                DETAILS_CACHE.put(id, new CacheEntry<>(item, System.currentTimeMillis()));
                out.add(item);
            }
            // restore id order: cached items were added first above
            Map<String, Item> byId = new LinkedHashMap<>();
            for (Item it : out) {
                byId.put(it.id, it);
            }
            out.clear();
            for (String id : ids) {
                Item it = byId.get(id);
                if (it != null) {
                    out.add(it);
                }
            }
        }
        return out;
    }

    /** Builds an Item from a WorkshopApi detail map. Package-private for tests. */
    static Item buildItem(String id, Map<String, Object> d) {
        @SuppressWarnings("unchecked")
        List<String> tags = d.get("tags") instanceof List
                ? (List<String>) d.get("tags") : new ArrayList<>();
        return new Item(
                id,
                str(d.get("title")),
                stripBbcode(str(d.get("description"))),
                tags,
                num(d.get("subscriptions")),
                num(d.get("fileSize")),
                num(d.get("timeUpdated")),
                str(d.get("previewUrl")),
                num(d.get("votesUp")),
                num(d.get("votesDown")));
    }

    private static String str(Object o) {
        return o == null ? "" : String.valueOf(o);
    }

    private static long num(Object o) {
        return o instanceof Number ? ((Number) o).longValue() : 0L;
    }

    /**
     * Strips Steam BBCode ([b], [h1], [url=...], [list], [*], ...) to plain
     * text and unescapes HTML entities. Package-private for tests.
     */
    static String stripBbcode(String s) {
        if (s == null) {
            return "";
        }
        String out = BBCODE_TAG.matcher(s).replaceAll("");
        out = out.replace("&amp;", "&").replace("&lt;", "<").replace("&gt;", ">")
                .replace("&quot;", "\"").replace("&#39;", "'");
        // collapse blank lines from removed block tags
        out = BLANK_LINES.matcher(out).replaceAll("\n\n").trim();
        return out;
    }

    private static final Pattern BBCODE_TAG = Pattern.compile("\\[/?[a-z0-9*]+(?:=[^\\]]*)?\\]",
            Pattern.CASE_INSENSITIVE);
    private static final Pattern BLANK_LINES = Pattern.compile("\n{3,}");

    private static void sleepQuietly(long ms) throws IOException {
        try {
            Thread.sleep(ms);
        } catch (InterruptedException e) {
            Thread.currentThread().interrupt();
            throw new IOException("interrupted", e);
        }
    }

    /** Clears both caches. Used by tests. */
    static void clearCaches() {
        PAGE_CACHE.clear();
        DETAILS_CACHE.clear();
    }
}
