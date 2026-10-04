package com.workshopbridge;

import java.io.File;
import java.util.ArrayList;
import java.util.Collections;
import java.util.HashSet;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.Set;
import java.util.UUID;
import java.util.concurrent.ConcurrentHashMap;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.function.Consumer;

/**
 * Runs downloads/checks on background threads and exposes pollable status.
 * Lua polls {@link #statusJson(String)} on tick; the game thread never blocks.
 */
public final class JobManager {
    public enum State { RUNNING, DONE, FAILED }

    public static final class Job {
        public final String id;
        public final String kind;
        volatile State state = State.RUNNING;
        volatile int done;
        volatile int total;
        volatile String message = "";
        volatile String error;
        // workshopIds with updates available
        volatile List<String> updates = Collections.emptyList();
        // dependency-check results ("deps" jobs only): one map per required
        // item, {id, title, installed}
        volatile List<Map<String, Object>> deps = Collections.emptyList();

        Job(String id, String kind) {
            this.id = id;
            this.kind = kind;
        }

        String toJson() {
            Map<String, Object> m = new LinkedHashMap<>();
            m.put("state", state.name().toLowerCase(Locale.ROOT));
            m.put("done", done);
            m.put("total", total);
            m.put("message", message);
            if (error != null) {
                m.put("error", error);
            }
            m.put("updates", updates);
            m.put("deps", deps);
            return Json.stringify(m);
        }
    }

    @FunctionalInterface
    private interface JobTask {
        void run(Job job) throws Exception;
    }

    private final Backend backend;
    private final ExecutorService exec = Executors.newCachedThreadPool(r -> {
        Thread t = new Thread(r, "workshopbridge-job");
        t.setDaemon(true);
        return t;
    });
    // Concurrent downloads
    private final ExecutorService downloadExec = Executors.newSingleThreadExecutor(r -> {
        Thread t = new Thread(r, "workshopbridge-download");
        t.setDaemon(true);
        return t;
    });
    private final ConcurrentHashMap<String, Job> jobs = new ConcurrentHashMap<>();
    /** The currently running check job, if any: repeat clicks coalesce onto it. */
    private volatile Job activeCheck;

    // Workshop ids with a download currently in flight
    private final Set<String> inFlight = ConcurrentHashMap.newKeySet();

    JobManager(Backend backend) {
        this.backend = backend;
    }

    public String submitCheck() {
        Job cur = activeCheck;
        if (cur != null && cur.state == State.RUNNING) {
            return cur.id;
        }
        String id = submit("check", this::runCheck);
        activeCheck = jobs.get(id);
        return id;
    }

    public String submitUpdateAll() {
        return submitDownload("update-all", this::runUpdateAll);
    }

    public String submitUpdate(String workshopId) {
        return submitDownload("update", job -> runUpdate(job, workshopId));
    }

    /** Downloads + installs each id in order (duplicates and non-numeric
     * ids are skipped). One job so the progress panel shows "Importing i/N". */
    public String submitImport(List<String> workshopIds) {
        return submitDownload("import", job -> runImport(job, workshopIds));
    }

    /** Resolves a workshop collection's children, then imports them. */
    public String submitImportCollection(String collectionId) {
        return submitDownload("import-collection", job -> runImportCollection(job, collectionId));
    }

    /**
     * Adopts a manually installed mod: downloads the workshop item fresh
     * (so the map gets the real remote timestamp and the mod is current),
     * verifies the item actually contains the mod BEFORE overwriting
     * anything, then installs and records it like a normal update.
     */
    public String submitAdopt(String workshopId, String modId) {
        return submitDownload("adopt", job -> runAdopt(job, workshopId, modId));
    }

    /**
     * Resolves a workshop item's required items ("dependencies") on a
     * background thread. The job's {@code deps} status field carries one
     * {id, title, installed} map per required item when done.
     */
    public String submitDependencies(String workshopId) {
        return submit("deps", job -> runDependencies(job, workshopId));
    }

    /** JSON status object, or null for unknown job ids. */
    public String statusJson(String jobId) {
        Job j = jobs.get(jobId);
        return j == null ? null : j.toJson();
    }

    private String submit(String kind, JobTask task) {
        return submitOn(exec, kind, task, "");
    }

    private String submitDownload(String kind, JobTask task) {
        return submitOn(downloadExec, kind, task, "Queued...");
    }

    private String submitOn(ExecutorService target, String kind, JobTask task,
            String initialMessage) {
        Job job = new Job(UUID.randomUUID().toString().substring(0, 8), kind);
        job.message = initialMessage;
        jobs.put(job.id, job);
        prune();
        target.submit(() -> {
            try {
                task.run(job);
            } catch (Throwable t) {
                fail(job, t);
            }
        });
        return job.id;
    }

    /**
     * Resolves a workshop item's required items. Best-effort: the resolver
     * never throws, so this always completes (possibly with an empty list)
     * and a failed Steam fetch can never surface as a job error here.
     */
    private void runDependencies(Job job, String workshopId) {
        job.message = "Checking dependencies...";
        job.total = 1;
        List<WorkshopDependencies.Dep> found = WorkshopDependencies.getRequired(workshopId);
        Set<String> installed = backend.workshopMap().snapshot().keySet();
        List<Map<String, Object>> deps = new ArrayList<>();
        for (WorkshopDependencies.Dep d : found) {
            Map<String, Object> m = new LinkedHashMap<>();
            m.put("id", d.id);
            m.put("title", d.title);
            m.put("installed", installed.contains(d.id));
            deps.add(m);
        }
        job.deps = deps;
        job.done = 1;
        job.message = deps.isEmpty() ? "No dependencies found"
                : deps.size() + " required item(s) found";
        job.state = State.DONE;
    }

    private void runCheck(Job job) {
        Map<String, WorkshopMap.Entry> items = backend.workshopMap().snapshot();
        List<String> ids = new ArrayList<>(items.keySet());
        job.total = ids.size();
        job.message = "Checking " + ids.size() + " workshop items...";
        final Map<String, Long> remote;
        try {
            remote = WorkshopApi.getTimeUpdated(ids);
        } catch (Exception e) {
            fail(job, e);
            return;
        }
        List<String> withUpdates = new ArrayList<>();
        List<String> missing = new ArrayList<>();
        List<String> skipped = new ArrayList<>();
        // Re-read the map AFTER the network round trip: an update job may
        // have installed items while we were waiting, and comparing against
        // the pre-request snapshot would resurrect stale "update available"
        // badges for just-updated mods.
        Map<String, WorkshopMap.Entry> fresh = backend.workshopMap().snapshot();
        int i = 0;
        for (String wsid : ids) {
            i++;
            job.done = i;
            Long tu = remote.get(wsid);
            WorkshopMap.Entry e = fresh.get(wsid);
            if (e == null) {
                continue; // unmapped while we were away; nothing to compare
            }
            if (tu == null) {
                // the API had no entry: item deleted or made private
                missing.add(wsid);
                job.message = "Checked " + i + "/" + ids.size();
            } else if (inFlight.contains(wsid)) {
                // a download is updating this item right now, so its map
                // timestamp is about to change and any comparison would be
                // stale. Don't report it as up to date - mark the check
                // incomplete instead (see the summary suffix below).
                skipped.add(wsid);
                job.message = "Checked " + i + "/" + ids.size();
            } else if (tu > e.timeUpdated) {
                // one entry per workshop item: an item holding five mods is
                // one update, not five
                withUpdates.add(wsid);
                job.message = "Update available: " + wsid;
            } else {
                job.message = "Checked " + i + "/" + ids.size();
            }
        }
        job.updates = withUpdates;
        job.done = ids.size();
        job.message = checkSummary(withUpdates.size(), missing) + skippedSuffix(skipped);
        job.state = State.DONE;
    }

    private void runUpdateAll(Job job) {
        Map<String, WorkshopMap.Entry> items = backend.workshopMap().snapshot();
        List<String> ids = new ArrayList<>(items.keySet());
        job.message = "Checking for updates...";
        final Map<String, Long> remote;
        try {
            remote = WorkshopApi.getTimeUpdated(ids);
        } catch (Exception e) {
            fail(job, e);
            return;
        }
        Map<String, Long> outdated = new LinkedHashMap<>();
        List<String> missing = new ArrayList<>();
        for (String wsid : ids) {
            Long tu = remote.get(wsid);
            if (tu == null) {
                missing.add(wsid);
            } else if (tu > items.get(wsid).timeUpdated) {
                outdated.put(wsid, tu);
            }
        }
        if (outdated.isEmpty()) {
            job.total = 0;
            job.message = checkSummary(0, missing);
            job.state = State.DONE;
            return;
        }
        job.total = outdated.size();
        int i = 0;
        for (Map.Entry<String, Long> e : outdated.entrySet()) {
            i++;
            job.message = "Downloading " + e.getKey() + " (" + i + "/" + outdated.size() + ")...";
            try {
                downloadAndInstall(e.getKey(), e.getValue());
            } catch (Exception ex) {
                fail(job, new Exception("failed on " + e.getKey() + ": " + ex.getMessage(), ex));
                return;
            }
            job.done = i;
        }
        job.message = "All mods up to date" + missingSuffix(missing);
        job.state = State.DONE;
    }

    private void runUpdate(Job job, String workshopId) {
        if (workshopId == null || !workshopId.matches("\\d+")) {
            fail(job, new IllegalArgumentException("invalid workshop id: " + workshopId));
            return;
        }
        job.total = 1;
        job.message = "Downloading " + workshopId + "...";
        long timeUpdated;
        try {
            timeUpdated = WorkshopApi.getTimeUpdated(List.of(workshopId))
                    .getOrDefault(workshopId, System.currentTimeMillis() / 1000L);
        } catch (Exception e) {
            // best effort: keep the previously recorded timestamp (if any)
            // instead of the wall clock, so a later check retries the
            // comparison instead of wrongly considering us current
            WorkshopMap.Entry prev = backend.workshopMap().snapshot().get(workshopId);
            timeUpdated = prev == null ? 0L : prev.timeUpdated;
        }
        try {
            downloadAndInstall(workshopId, timeUpdated);
        } catch (Exception ex) {
            fail(job, ex);
            return;
        }
        job.done = 1;
        job.message = "Done";
        job.state = State.DONE;
    }

    private void runImportCollection(Job job, String collectionId) {
        if (collectionId == null || !collectionId.matches("\\d+")) {
            fail(job, new IllegalArgumentException("invalid workshop id: " + collectionId));
            return;
        }
        job.message = "Resolving collection " + collectionId + "...";
        final List<String> children;
        try {
            children = WorkshopApi.getCollectionChildren(collectionId);
        } catch (Exception e) {
            fail(job, e);
            return;
        }
        if (children.isEmpty()) {
            job.message = "No mods found in collection " + collectionId
                    + " (not a collection, or it is empty/private)";
            job.state = State.DONE;
            return;
        }
        runImport(job, children);
    }

    private void runAdopt(Job job, String workshopId, String modId) {
        if (workshopId == null || !workshopId.matches("\\d+")) {
            fail(job, new IllegalArgumentException("invalid workshop id: " + workshopId));
            return;
        }
        if (modId == null || modId.isBlank()) {
            fail(job, new IllegalArgumentException("invalid mod id"));
            return;
        }
        job.total = 2;
        job.message = "Downloading " + workshopId + "...";
        // Best-effort timestamp: we are downloading the latest content right
        // now, so on API failure the wall clock is the honest baseline (the
        // next check then only flags genuinely newer uploads). Matches
        // runUpdate's fallback.
        long nowSec = System.currentTimeMillis() / 1000L;
        long timeUpdated;
        try {
            timeUpdated = WorkshopApi.getTimeUpdated(List.of(workshopId))
                    .getOrDefault(workshopId, nowSec);
        } catch (Exception e) {
            timeUpdated = nowSec;
        }
        final File itemDir;
        inFlight.add(workshopId);
        try {
            itemDir = downloadItem(workshopId);
        } catch (Exception ex) {
            inFlight.remove(workshopId);
            fail(job, ex);
            return;
        }
        job.done = 1;
        // verify BEFORE overwriting: the item must actually contain the mod
        // being adopted. Multi-mod items pass here as long as the adopted
        // mod is one of them; the install below then records all of them.
        List<String> contained = ModInstaller.scanModIds(itemDir);
        if (!contained.contains(modId)) {
            inFlight.remove(workshopId);
            fail(job, new IllegalArgumentException("workshop item " + workshopId
                    + " does not contain mod '" + modId + "'; it contains: "
                    + (contained.isEmpty() ? "(no mods found)" : String.join(", ", contained))));
            return;
        }
        job.message = "Installing " + modId + "...";
        try {
            installDownloaded(itemDir, workshopId, timeUpdated);
        } catch (Exception ex) {
            fail(job, ex);
            return;
        } finally {
            inFlight.remove(workshopId);
        }
        job.done = 2;
        job.message = "Adopted " + modId;
        job.state = State.DONE;
    }

    private void runImport(Job job, List<String> workshopIds) {
        // clean the input: digits only, order kept, duplicates dropped
        List<String> ids = new ArrayList<>();
        for (String id : workshopIds) {
            if (id != null && id.matches("\\d+") && !ids.contains(id)) {
                ids.add(id);
            }
        }
        if (ids.isEmpty()) {
            fail(job, new IllegalArgumentException("no valid workshop ids to import"));
            return;
        }
        // one batched timestamp lookup up front, like update-all does
        Map<String, Long> remote;
        boolean apiOk;
        try {
            remote = WorkshopApi.getTimeUpdated(ids);
            apiOk = true;
        } catch (Exception e) {
            remote = new java.util.HashMap<>();
            apiOk = false;
        }
        job.total = ids.size();
        int imported = 0;
        List<String> skipped = new ArrayList<>();
        int i = 0;
        for (String wsid : ids) {
            i++;
            job.done = i - 1;
            Long tu = remote.get(wsid);
            if (tu == null && apiOk) {
                // the API listed no entry: deleted or private; skip it
                skipped.add(wsid);
                continue;
            }
            job.message = "Importing " + wsid + " (" + i + "/" + ids.size() + ")...";
            try {
                // without an API timestamp (offline), the wall clock is the
                // honest baseline: we just downloaded the latest content
                downloadAndInstall(wsid,
                        tu == null ? System.currentTimeMillis() / 1000L : tu);
                imported++;
            } catch (Exception ex) {
                fail(job, new Exception("failed on " + wsid + ": " + ex.getMessage(), ex));
                return;
            }
            job.done = i;
        }
        job.message = imported == 1 ? "Imported 1 mod" : "Imported " + imported + " mods";
        if (!skipped.isEmpty()) {
            job.message += " (" + skipped.size() + " skipped: no longer listed - "
                    + String.join(", ", skipped) + ")";
        }
        job.state = State.DONE;
    }

    private void downloadAndInstall(String workshopId, long timeUpdated) throws Exception {
        inFlight.add(workshopId);
        try {
            installDownloaded(downloadItem(workshopId), workshopId, timeUpdated);
        } finally {
            inFlight.remove(workshopId);
        }
    }

    private File downloadItem(String workshopId) throws Exception {
        return backend.steamCmd().download(
                workshopId, backend.cacheDir(), line -> System.out.println("[WorkshopBridge] " + line));
    }

    private void installDownloaded(File itemDir, String workshopId, long timeUpdated) throws Exception {
        // staging lives under the workshop cache and outside mods/ itself,
        // where the game's file watcher would trip over the transient backup dirs
        WorkshopMap.Entry prev = backend.workshopMap().snapshot().get(workshopId);
        List<String> modIds = ModInstaller.install(
                itemDir, backend.modsDir(),
                new File(backend.cacheDir(), ".install-staging"),
                line -> System.out.println("[WorkshopBridge] " + line));
        removeStaleSubMods(workshopId, prev == null ? List.of() : prev.modIds, modIds);
        backend.workshopMap().record(workshopId, modIds, timeUpdated);
    }

    /**
     * An updated workshop item may no longer contain every mod it used to
     * (the author removed one). A folder left behind would keep loading in
     * the game while no longer being tracked or updatable, so remove it -
     * but only when we are sure it belongs to this item: the folder's
     * mod.info id must match the stale id, and no other workshop item may
     * still claim that id.
     */
    private void removeStaleSubMods(String workshopId, List<String> oldIds, List<String> newIds) {
        Set<String> stale = new HashSet<>(oldIds);
        stale.removeAll(new HashSet<>(newIds));
        if (stale.isEmpty()) {
            return;
        }
        Map<String, WorkshopMap.Entry> items = backend.workshopMap().snapshot();
        File[] dirs = backend.modsDir().listFiles(File::isDirectory);
        if (dirs == null) {
            return;
        }
        Consumer<String> log = line -> System.out.println("[WorkshopBridge] " + line);
        for (String modId : stale) {
            boolean claimedElsewhere = items.entrySet().stream()
                    .anyMatch(e -> !e.getKey().equals(workshopId)
                            && e.getValue().modIds.contains(modId));
            if (claimedElsewhere) {
                log.accept("Keeping " + modId + ": still claimed by another workshop item");
                continue;
            }
            for (File dir : dirs) {
                if (!modId.equals(ModInstaller.readModId(dir))) {
                    continue;
                }
                log.accept("Removing " + dir.getName()
                        + " (no longer in workshop item " + workshopId + ")");
                ModInstaller.deleteRecursiveQuiet(dir.toPath(), log);
            }
        }
    }

    private void fail(Job job, Throwable t) {
        job.state = State.FAILED;
        job.error = t.getMessage() == null ? t.toString() : t.getMessage();
        System.out.println("[WorkshopBridge] job " + job.id + " (" + job.kind + ") failed: " + t);
    }

    // package-private for tests
    static String checkSummary(int updateCount, List<String> missing) {
        String base = updateCount == 0
                ? "Everything is up to date"
                : updateCount == 1
                        ? "1 update available"
                        : updateCount + " updates available";
        return base + missingSuffix(missing);
    }

    // package-private for tests
    static String missingSuffix(List<String> missing) {
        if (missing.isEmpty()) {
            return "";
        }
        return "; " + missing.size()
                + " workshop item(s) no longer listed (deleted or private?): "
                + String.join(", ", missing);
    }

    // package-private for tests
    static String skippedSuffix(List<String> skipped) {
        if (skipped.isEmpty()) {
            return "";
        }
        return "; " + skipped.size()
                + " workshop item(s) skipped (update in flight - re-run the check to confirm)";
    }

    private void prune() {
        if (jobs.size() <= 50) {
            return;
        }
        jobs.entrySet().removeIf(e ->
                e.getValue().state == State.DONE || e.getValue().state == State.FAILED);
    }
}
