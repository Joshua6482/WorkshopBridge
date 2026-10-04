package com.workshopbridge;

import com.sun.net.httpserver.HttpServer;

import java.io.File;
import java.io.OutputStream;
import java.net.InetSocketAddress;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.util.List;
import java.util.Map;
import java.util.concurrent.atomic.AtomicBoolean;
import java.util.concurrent.atomic.AtomicReference;
import java.util.function.Consumer;

/**
 * Offline test harness. Run with:
 *   -Dwb.test.zomboid=<tmpdir>
 * (the runner script sets this up; the stub Steam API binds port 0 and the
 * harness points WorkshopApi at it programmatically).
 */
public class WBTest {
    static int failures = 0;

    static void check(boolean c, String name, Object extra) {
        System.out.println((c ? "PASS " : "FAIL ") + name
                + (c || extra == null ? "" : " -- " + extra));
        if (!c) failures++;
    }

    static void check(boolean c, String name) {
        check(c, name, null);
    }

    /** True when running r throws IllegalArgumentException. */
    static boolean throwsIAE(Runnable r) {
        try {
            r.run();
            return false;
        } catch (IllegalArgumentException e) {
            return true;
        }
    }

    /** Polls a job until it leaves RUNNING; returns the final status map. */
    static Map<String, Object> awaitDone(JobManager jobs, String jobId) throws Exception {
        long deadline = System.currentTimeMillis() + 30_000;
        while (System.currentTimeMillis() < deadline) {
            String s = jobs.statusJson(jobId);
            if (s == null) throw new IllegalStateException("job vanished: " + jobId);
            Map<String, Object> st = Json.object(Json.parse(s));
            if (!"running".equals(st.get("state"))) return st;
            Thread.sleep(100);
        }
        throw new IllegalStateException("job timed out: " + jobId);
    }

    public static void main(String[] args) throws Exception {
        String zomboidProp = System.getProperty("wb.test.zomboid");
        if (zomboidProp == null || zomboidProp.isEmpty()) {
            // Never run against the real ~/Zomboid: without the property the
            // backend would resolve to the user's actual game folder.
            System.err.println("wb.test.zomboid not set - run via tests/java/run.sh");
            System.exit(2);
        }

        // ---- 1. Json basics ----
        Object o = Json.parse("{\"a\":1,\"b\":[true,null],\"c\":\"x\\\"y\"}");
        Map<String, Object> m = Json.object(o);
        check(m != null && ((Number) m.get("a")).intValue() == 1, "json parse object");
        check(Json.stringify(m).contains("\"a\":1"), "json stringify");

        // ---- 1b. Json edge cases ----
        Map<String, Object> esc = Json.object(
                Json.parse("{\"q\":\"a\\\"b\\\\c\\/d\\b\\f\\n\\r\\t\"}"));
        check("a\"b\\c/d\b\f\n\r\t".equals(esc.get("q")), "json escapes", esc.get("q"));
        Map<String, Object> uni = Json.object(Json.parse("{\"u\":\"\\u0041\\u00e9\"}"));
        check("A\u00e9".equals(uni.get("u")), "json unicode escapes", uni.get("u"));
        Map<String, Object> sur = Json.object(Json.parse("{\"s\":\"\\ud83d\\ude00\"}"));
        check("\uD83D\uDE00".equals(sur.get("s")), "json surrogate pair", sur.get("s"));
        Object nested = Json.parse("{\"a\":{\"b\":[1,2,{\"c\":null}]}}");
        check("{\"a\":{\"b\":[1,2,{\"c\":null}]}}".equals(Json.stringify(nested)),
                "json nesting round-trip");
        check(((Number) Json.parse("01")).intValue() == 1, "json leading-zero number (lenient)");
        boolean threw = false;
        try {
            Json.parse("{\"a\":}");
        } catch (IllegalArgumentException e) {
            threw = true;
        }
        check(threw, "json malformed object throws");
        boolean threw2 = false;
        try {
            Json.parse("{\"a\":1} trailing");
        } catch (IllegalArgumentException e) {
            threw2 = true;
        }
        check(threw2, "json trailing data throws");

        // ---- 2. Net messages ----
        // ---- 2b. parse a REAL captured Steam API response ----
        String fixtureDir = System.getProperty("wb.test.fixtures");
        String realJson = Files.readString(
                new File(fixtureDir, "publishedfiledetails.json").toPath(), StandardCharsets.UTF_8);
        Map<String, Long> parsed = WorkshopApi.parseTimeUpdated(realJson);
        check(parsed.get("2685600088") != null && parsed.get("2685600088") > 1_700_000_000L,
                "real response: time_updated parsed", parsed.get("2685600088"));
        check(!parsed.containsKey("1"), "real response: bogus id absent (result=9)");
        check(throwsIAE(() -> WorkshopApi.parseTimeUpdated("not json")),
                "garbage -> throws (never silently empty)");
        check(throwsIAE(() -> WorkshopApi.parseTimeUpdated("{\"response\":{}}")),
                "response without publishedfiledetails -> throws");
        check(Net.friendlyMessage(new java.io.IOException(
                new java.net.UnknownHostException("x")))
                .startsWith("Couldn't reach Steam's servers"), "net dns");
        check(Net.friendlyMessage(new java.io.IOException("weird")).equals("weird"),
                "net passthrough");

        // ---- 2c. dependency ("required items") parsing ----
        String depHtml = Files.readString(
                new File(fixtureDir, "workshoppage-requireditems.html").toPath(),
                StandardCharsets.UTF_8);
        java.util.List<WorkshopDependencies.Dep> deps =
                WorkshopDependencies.parseRequiredItems(depHtml);
        check(deps.size() == 1 && "3171167894".equals(deps.get(0).id),
                "deps: real page yields the required item", deps.size());
        check("that DAMN Library".equals(deps.get(0).title),
                "deps: title parsed", deps.get(0).title);
        check(WorkshopDependencies.parseRequiredItems("<html>no marker here</html>").isEmpty(),
                "deps: no RequiredItems marker -> empty");
        check(WorkshopDependencies.parseRequiredItems(null).isEmpty(),
                "deps: null html -> empty");
        check(WorkshopDependencies.parseRequiredItems("").isEmpty(),
                "deps: empty html -> empty");
        // unrelated filedetails links elsewhere on the page must not leak in
        String twoLinks = "<div id=\"RequiredItems\">"
                + "<a href=\"https://steamcommunity.com/workshop/filedetails/?id=111\">"
                + "<div class=\"requiredItem\">One &amp; Only</div></a>"
                + "<a href=\"https://steamcommunity.com/workshop/filedetails/?id=111\">"
                + "<div class=\"requiredItem\">One duplicate</div></a>"
                + "<a href=\"https://steamcommunity.com/workshop/filedetails/?id=222\">"
                + "<div class=\"requiredItem\">Two</div></a>"
                + "</div><!-- created by --><a href=\"?id=999\">unrelated</a>";
        java.util.List<WorkshopDependencies.Dep> two =
                WorkshopDependencies.parseRequiredItems(twoLinks);
        check(two.size() == 2 && "111".equals(two.get(0).id) && "222".equals(two.get(1).id),
                "deps: order kept, duplicates dropped", two.size());
        check("One & Only".equals(two.get(0).title), "deps: entities unescaped",
                two.get(0).title);
        // transitive collection: cycle-safe, depth-capped
        java.util.Map<String, java.util.List<WorkshopDependencies.Dep>> graph =
                new java.util.LinkedHashMap<>();
        graph.put("1", java.util.List.of(new WorkshopDependencies.Dep("2", "B"),
                new WorkshopDependencies.Dep("3", "C")));
        graph.put("2", java.util.List.of(new WorkshopDependencies.Dep("3", "C"),
                new WorkshopDependencies.Dep("1", "A"))); // cycle back to root
        graph.put("3", java.util.List.of());
        java.util.List<WorkshopDependencies.Dep> trans = new java.util.ArrayList<>();
        java.util.Set<String> seen = new java.util.LinkedHashSet<>();
        seen.add("1");
        WorkshopDependencies.collectInto("1", 0, seen, trans,
                id -> graph.getOrDefault(id, java.util.List.of()));
        check(trans.size() == 2 && "2".equals(trans.get(0).id)
                        && "3".equals(trans.get(1).id),
                "deps: transitive, no repeats, cycle-safe", trans.size());
        java.util.Map<String, java.util.List<WorkshopDependencies.Dep>> chain =
                new java.util.LinkedHashMap<>();
        chain.put("1", java.util.List.of(new WorkshopDependencies.Dep("2", "b")));
        chain.put("2", java.util.List.of(new WorkshopDependencies.Dep("3", "c")));
        chain.put("3", java.util.List.of(new WorkshopDependencies.Dep("4", "d")));
        chain.put("4", java.util.List.of(new WorkshopDependencies.Dep("5", "e")));
        java.util.List<WorkshopDependencies.Dep> capped = new java.util.ArrayList<>();
        java.util.Set<String> seen2 = new java.util.LinkedHashSet<>();
        seen2.add("1");
        WorkshopDependencies.collectInto("1", 0, seen2, capped,
                id -> chain.getOrDefault(id, java.util.List.of()));
        check(capped.size() == 3 && "4".equals(capped.get(2).id),
                "deps: transitive depth capped", capped.size());
        // getRequired never throws, even for garbage input
        check(WorkshopDependencies.getRequired("abc").isEmpty(),
                "deps: non-numeric id -> empty, no throw");
        check(WorkshopDependencies.getRequired(null).isEmpty(),
                "deps: null id -> empty, no throw");

        // ---- 3. Backend + atomic map save ----
        Backend backend = Backend.get();
        File zomboidDir = backend.zomboidDir();
        check(zomboidDir.getAbsolutePath()
                .equals(new File(System.getProperty("wb.test.zomboid")).getAbsolutePath()),
                "zomboid dir honors test property", zomboidDir);
        backend.workshopMap().record("111", List.of("ModA"), 1000L);
        backend.workshopMap().record("222", List.of("ModB"), 1000L);
        File mapFile = new File(zomboidDir, "workshopbridge_map.json");
        check(mapFile.isFile(), "map file written");
        check(!new File(zomboidDir, "workshopbridge_map.json.tmp").exists(),
                "no temp file left behind (atomic save)");
        WorkshopMap reloaded = new WorkshopMap(mapFile);
        reloaded.load();
        check("111".equals(reloaded.getWorkshopId("ModA"))
                && "222".equals(reloaded.getWorkshopId("ModB")), "map reload round-trip");
        check(reloaded.snapshot().get("111").timeUpdated == 1000L, "map timeUpdated");

        // ---- 3b. corrupt map file loads empty instead of throwing ----
        File corruptFile = new File(zomboidDir, "corrupt_map.json");
        Files.writeString(corruptFile.toPath(), "this is not json{{{", StandardCharsets.UTF_8);
        WorkshopMap corrupt = new WorkshopMap(corruptFile);
        corrupt.load(); // must not throw
        check(corrupt.snapshot().isEmpty(), "corrupt map loads empty");

        // ---- 3b2. mod.info id parsing: B42 "42.0" layout + self-healing ----
        File typoMod = new File(backend.modsDir(), "True Weigth/42.0");
        typoMod.mkdirs();
        writeFile(new File(typoMod, "mod.info"), "id=TrueWeight\n");
        check("TrueWeight".equals(ModInstaller.readModId(new File(backend.modsDir(), "True Weigth"))),
                "readModId parses 42.0/mod.info");
        // recorded under the (typo'd) folder name, as older versions did
        backend.workshopMap().record("3768669395", List.of("True Weigth"), 1000L);
        check(backend.workshopMap().getWorkshopId("TrueWeight") == null,
                "typo'd entry misses direct lookup");
        check("3768669395".equals(backend.getWorkshopId("TrueWeight")),
                "self-healing lookup finds workshop id via mod.info");
        check("3768669395".equals(backend.workshopMap().getWorkshopId("TrueWeight")),
                "entry repaired to true mod id");

        // ---- 3b3. versioned mod.info dirs: game's own picker (42 / 42.1 / 42.1.0) ----
        File verMod = new File(backend.modsDir(), "VerMod");
        new File(verMod, "42").mkdirs();
        new File(verMod, "42.1").mkdirs();
        new File(verMod, "42.1.0").mkdirs();
        writeFile(new File(verMod, "42/mod.info"), "id=Id42\n");
        writeFile(new File(verMod, "42.1/mod.info"), "id=Id421\n");
        writeFile(new File(verMod, "42.1.0/mod.info"), "id=Id4210\n");
        // default test game version is 42.1.0 -> highest dir at/below it wins
        check("Id4210".equals(ModInstaller.readModId(verMod)),
                "readModId picks 42.1.0/mod.info on game 42.1.0");
        // version dir beats common/ (game's read order: version first)
        writeFile(new File(verMod, "common/mod.info"), "id=IdCommon\n");
        check("Id4210".equals(ModInstaller.readModId(verMod)),
                "readModId prefers version dir over common/");
        System.setProperty("wb.test.gameVersion", "42.0.9");
        try {
            check("Id42".equals(ModInstaller.readModId(verMod)),
                    "readModId picks 42/mod.info on game 42.0.9");
        } finally {
            System.clearProperty("wb.test.gameVersion");
        }
        // legacy flat mod.info at the root is ignored (B41 layout, unsupported)
        File flatMod = new File(backend.modsDir(), "FlatMod");
        flatMod.mkdirs();
        writeFile(new File(flatMod, "mod.info"), "id=FlatId\n");
        check("FlatMod".equals(ModInstaller.readModId(flatMod)),
                "readModId ignores legacy flat mod.info");
        // no mod.info anywhere -> folder name fallback still works
        File bareMod = new File(backend.modsDir(), "BareMod");
        bareMod.mkdirs();
        check("BareMod".equals(ModInstaller.readModId(bareMod)),
                "readModId falls back to folder name");

        // ---- 3c. point steamcmd at the fake (used by every job test below) ----
        File props = new File(zomboidDir, "workshopbridge.properties");
        String fakeExe = new File(System.getProperty("wb.test.fakebin"),
                "steamcmd.sh").getAbsolutePath();
        Files.writeString(props.toPath(), "steamcmd.path=" + fakeExe + "\n");
        // BOM variant: Windows Notepad saves UTF-8 with a BOM; the override
        // must still be honored, not silently dropped
        byte[] bom = {(byte) 0xEF, (byte) 0xBB, (byte) 0xBF};
        byte[] plain = ("steamcmd.path=" + fakeExe + "\n").getBytes(StandardCharsets.UTF_8);
        byte[] withBom = new byte[bom.length + plain.length];
        System.arraycopy(bom, 0, withBom, 0, bom.length);
        System.arraycopy(plain, 0, withBom, bom.length, plain.length);
        Files.write(props.toPath(), withBom);

        // ---- 3c2. workshopbridge.properties auto-created with docs ----
        File propsDir = scratchDir(zomboidDir, "wb-props");
        File autoProps = new File(propsDir, "workshopbridge.properties");
        check(!autoProps.isFile(), "no properties file before SteamCmd init");
        new SteamCmd(propsDir);
        check(autoProps.isFile(), "properties file auto-created");
        String template = Files.readString(autoProps.toPath());
        check(template.contains("#") && template.contains("steamcmd.path"),
                "template carries commented docs");
        // an existing file is never overwritten...
        Files.writeString(autoProps.toPath(), "steamcmd.path=/custom/steamcmd\n");
        new SteamCmd(propsDir);
        check(Files.readString(autoProps.toPath()).contains("/custom/steamcmd"),
                "existing properties file preserved");
        // ...and the commented template parses to "no override"
        File bareDir = scratchDir(zomboidDir, "wb-props-bare");
        new SteamCmd(bareDir); // creates the template
        check(new SteamCmd(bareDir).findExecutable() == null,
                "template with empty steamcmd.path -> no override");
        check(fakeExe.equals(backend.steamCmd().findExecutable()),
                "BOM in properties file does not drop steamcmd.path",
                backend.steamCmd().findExecutable());
        Files.writeString(props.toPath(), "steamcmd.path=" + fakeExe + "\n");

        // ---- 4. check job with a stub Steam API: 111 updated, 222 gone ----
        HttpServer api = HttpServer.create(new InetSocketAddress("127.0.0.1", 0), 0);
        int apiPort = api.getAddress().getPort();
        AtomicReference<String> apiJson = new AtomicReference<>(
                "{\"response\":{\"publishedfiledetails\":["
                + "{\"publishedfileid\":\"111\",\"time_updated\":2000,"
                + "\"result\":1}]}}");
        AtomicBoolean apiSlow = new AtomicBoolean(false);
        api.createContext("/", ex -> {
            if (apiSlow.get()) {
                try { Thread.sleep(3000); } catch (InterruptedException ignored) { }
            }
            byte[] b = apiJson.get().getBytes(StandardCharsets.UTF_8);
            ex.getResponseHeaders().add("Content-Type", "application/json");
            ex.sendResponseHeaders(200, b.length);
            try (OutputStream os = ex.getResponseBody()) { os.write(b); }
        });
        // captured real workshop page for dependency checks
        byte[] depPage = Files.readAllBytes(
                new File(fixtureDir, "workshoppage-requireditems.html").toPath());
        api.createContext("/page", ex -> {
            ex.getResponseHeaders().add("Content-Type", "text/html; charset=utf-8");
            ex.sendResponseHeaders(200, depPage.length);
            try (OutputStream os = ex.getResponseBody()) { os.write(depPage); }
        });
        api.start();
        // WorkshopApi reads the steamApiUrl property on every call (deliberately
        // not cached at class-load: the fixture test above already exercised
        // WorkshopApi.parseTimeUpdated, which would otherwise freeze the URL
        // to the real Steam API and send every "stubbed" check at real
        // workshop items). Binding port 0 above means run.sh needs no
        // free-port hack (and no python3).
        System.setProperty("workshopbridge.steamApiUrl",
                "http://127.0.0.1:" + apiPort + "/");
        JobManager jobs = new JobManager(backend);
        // ---- 4a. dependency job against a dead endpoint: best-effort, the
        // job still completes (with an empty list), never fails. Runs
        // everywhere, including sandboxes without socket access.
        String savedPageUrl = System.getProperty("workshopbridge.workshopPageUrl");
        System.setProperty("workshopbridge.workshopPageUrl", "http://127.0.0.1:1/none/");
        String depJob = jobs.submitDependencies("3799732653");
        Map<String, Object> depSt = awaitDone(jobs, depJob);
        check("done".equals(depSt.get("state")), "deps job completes on dead endpoint",
                depSt.get("state"));
        List<Object> depList = Json.array(depSt.get("deps"));
        check(depList != null && depList.isEmpty(),
                "deps job yields empty list on failure, never an error", depList);
        if (savedPageUrl != null) {
            System.setProperty("workshopbridge.workshopPageUrl", savedPageUrl);
        } else {
            System.clearProperty("workshopbridge.workshopPageUrl");
        }
        // Gate the live-HTTP checks on a plain probe of the stub server, not on
        // our code's error strings: in sandboxed environments loopback HTTP may
        // be intercepted or dead, and the failure mode varies. On a normal
        // machine the probe succeeds and every assertion below runs for real.
        boolean liveHttp = stubApiUsable(System.getProperty("workshopbridge.steamApiUrl"));
        if (!liveHttp) {
            System.out.println("SKIPPED live check-job HTTP test (no usable loopback HTTP here)");
            System.out.println("SKIPPED check reports the outdated workshop item (no usable loopback HTTP here)");
            System.out.println("SKIPPED check flags deleted item (no usable loopback HTTP here)");
            System.out.println("SKIPPED live update-all HTTP test (no usable loopback HTTP here)");
        } else {
            // ---- 4b. dependency job against the stub workshop page ----
            System.setProperty("workshopbridge.workshopPageUrl",
                    "http://127.0.0.1:" + apiPort + "/page");
            String depJob2 = jobs.submitDependencies("3799732653");
            Map<String, Object> depSt2 = awaitDone(jobs, depJob2);
            check("done".equals(depSt2.get("state")), "deps job completes",
                    depSt2.get("state"));
            List<Object> deps2 = Json.array(depSt2.get("deps"));
            check(deps2 != null && deps2.size() == 1, "deps job carries one dep", deps2);
            Map<String, Object> dep0 = Json.object(deps2.get(0));
            check("3171167894".equals(dep0.get("id")), "deps job dep id", dep0.get("id"));
            check("that DAMN Library".equals(dep0.get("title")), "deps job dep title",
                    dep0.get("title"));
            check(Boolean.FALSE.equals(dep0.get("installed")),
                    "deps job dep not installed", dep0.get("installed"));
            System.clearProperty("workshopbridge.workshopPageUrl");

            String checkId = jobs.submitCheck();
            Map<String, Object> st = awaitDone(jobs, checkId);
            check("done".equals(st.get("state")), "check completes", st.get("state"));
            List<Object> updates = Json.array(st.get("updates"));
            check(updates != null && updates.size() == 1 && "111".equals(updates.get(0)),
                    "check reports the outdated workshop item (not its mod)", updates);
            String msg = String.valueOf(st.get("message"));
            check(msg.contains("222") && msg.contains("no longer listed"),
                    "check flags deleted item", msg);

            // ---- 4c. update-all job against the same stub API ----
            // map: 111 -> ModA (outdated), 222 -> ModB (missing from API)
            String upAllId = jobs.submitUpdateAll();
            Map<String, Object> uast = awaitDone(jobs, upAllId);
            check("done".equals(uast.get("state")), "update-all completes", uast.get("error"));
            check("111".equals(backend.workshopMap().getWorkshopId("FakeMod-111")),
                    "update-all re-records workshop->mod");
            String umsg = String.valueOf(uast.get("message"));
            check(umsg.contains("All mods up to date") && umsg.contains("222"),
                    "update-all message notes missing item", umsg);

            // ---- 4c2. repeat checks coalesce onto the running job ----
            apiSlow.set(true);
            String coalesce1 = jobs.submitCheck();
            String coalesce2 = jobs.submitCheck();
            check(coalesce1.equals(coalesce2),
                    "second check while one runs rejoins the same job");
            awaitDone(jobs, coalesce1);
            apiSlow.set(false);
            String coalesce3 = jobs.submitCheck();
            check(!coalesce3.equals(coalesce1),
                    "new check after completion starts a fresh job");
            awaitDone(jobs, coalesce3);

            // ---- 4c3. malformed API response fails the check outright ----
            // it must never look like "everything deleted / up to date"
            apiJson.set("this is not json");
            String badApiId = jobs.submitCheck();
            Map<String, Object> badSt = awaitDone(jobs, badApiId);
            check("failed".equals(badSt.get("state")),
                    "malformed API response -> failed check", badSt.get("state"));
            check(String.valueOf(badSt.get("error")).contains("malformed"),
                    "failure error says the response was malformed",
                    badSt.get("error"));
            apiJson.set("{\"response\":{\"publishedfiledetails\":["
                    + "{\"publishedfileid\":\"111\",\"time_updated\":2000,"
                    + "\"result\":1}]}}");

            // ---- 4c4. check re-reads the map after the API round trip ----
            // 33333 is outdated per the API (@2000 vs recorded 1000); an
            // update installing it while the check is in flight (slow API)
            // must not resurrect a stale "update available" badge.
            backend.workshopMap().record("33333", List.of("FakeMod-33333"), 1000L);
            apiJson.set("{\"response\":{\"publishedfiledetails\":["
                    + "{\"publishedfileid\":\"33333\",\"time_updated\":2000,"
                    + "\"result\":1}]}}");
            apiSlow.set(true);
            String raceCheckId = jobs.submitCheck();
            Thread.sleep(500); // let the check reach the API wait
            backend.workshopMap().record("33333", List.of("FakeMod-33333"), 2000L);
            apiSlow.set(false);
            Map<String, Object> raceSt = awaitDone(jobs, raceCheckId);
            List<Object> raceUpdates = Json.array(raceSt.get("updates"));
            check(raceUpdates != null && raceUpdates.isEmpty(),
                    "check re-reads map: no stale badge for just-updated item",
                    raceUpdates);

            // ---- 4c5. check excludes items with a download in flight ----
            // 99998 is slow in the fake steamcmd (sleeps 2s mid-download);
            // the check must not flag it while those bytes are on the way.
            backend.workshopMap().record("99998", List.of("FakeMod-99998"), 1000L);
            apiJson.set("{\"response\":{\"publishedfiledetails\":["
                    + "{\"publishedfileid\":\"99998\",\"time_updated\":2000,"
                    + "\"result\":1}]}}");
            String slowUpId = jobs.submitUpdate("99998");
            Thread.sleep(500); // let the download get in flight
            String flightCheckId = jobs.submitCheck();
            Map<String, Object> flightSt = awaitDone(jobs, flightCheckId);
            List<Object> flightUpdates = Json.array(flightSt.get("updates"));
            check(flightUpdates != null && flightUpdates.isEmpty(),
                    "check excludes in-flight download", flightUpdates);
            check(String.valueOf(flightSt.get("message")).contains("skipped (update in flight"),
                    "check reports the skipped item instead of a clean bill",
                    flightSt.get("message"));
            awaitDone(jobs, slowUpId);
            apiJson.set("{\"response\":{\"publishedfiledetails\":["
                    + "{\"publishedfileid\":\"111\",\"time_updated\":2000,"
                    + "\"result\":1}]}}");
        }
        api.stop(0);

        // ---- 4d. downloads are serialized: second waits queued ----
        // (no stub API needed: runUpdate falls back gracefully when the
        // API is unreachable; the fake steamcmd does the real work)
        // 99998 is slow in the fake steamcmd (sleeps 2s); 99999 is fast.
        String slowId = jobs.submitUpdate("99998");
        String fastId = jobs.submitUpdate("99999");
        boolean sawQueued = false;
        boolean overlap = false;
        long qdeadline = System.currentTimeMillis() + 30_000;
        while (System.currentTimeMillis() < qdeadline) {
            Map<String, Object> sa =
                    Json.object(Json.parse(jobs.statusJson(slowId)));
            Map<String, Object> sb =
                    Json.object(Json.parse(jobs.statusJson(fastId)));
            String ma = String.valueOf(sa.get("message"));
            String mb = String.valueOf(sb.get("message"));
            if (mb.startsWith("Queued")) sawQueued = true;
            if (ma.startsWith("Downloading") && mb.startsWith("Downloading")) {
                overlap = true;
            }
            if ("done".equals(sa.get("state")) && "done".equals(sb.get("state"))) break;
            Thread.sleep(50);
        }
        check(sawQueued, "second download reports Queued while first runs");
        check(!overlap, "downloads never overlap");
        Map<String, Object> sdone = awaitDone(jobs, slowId);
        Map<String, Object> fdone = awaitDone(jobs, fastId);
        check("done".equals(sdone.get("state")) && "done".equals(fdone.get("state")),
                "both queued downloads complete");

        // ---- 4e. a failed steamcmd must not install stale cached content ----
        // 99996 downloads fine once; then the fake is told to fail (exit 1).
        // The item dir is wiped before every download, so there is no stale
        // tree to fall back on: the job must fail with the exit code named,
        // not reinstall anything as if fresh.
        String staleId1 = jobs.submitUpdate("99996");
        Map<String, Object> stale1 = awaitDone(jobs, staleId1);
        check("done".equals(stale1.get("state")), "stale-test setup download completes",
                stale1.get("error"));
        File failMarker = new File(backend.cacheDir(), ".fail-99996");
        check(failMarker.createNewFile(), "fail marker created", failMarker);
        String staleId2 = jobs.submitUpdate("99996");
        Map<String, Object> stale2 = awaitDone(jobs, staleId2);
        check("failed".equals(stale2.get("state")),
                "failed steamcmd with stale cache -> failed job", stale2.get("state"));
        check(String.valueOf(stale2.get("error")).contains("exit=1"),
                "failure error cites the exit code", stale2.get("error"));
        check(failMarker.delete(), "fail marker cleaned up");

        // ---- 4b. check-summary message building (no network needed) ----
        check(JobManager.checkSummary(2, List.of("222")).equals("2 updates available; "
                        + "1 workshop item(s) no longer listed (deleted or private?): 222"),
                "summary with updates + missing",
                JobManager.checkSummary(2, List.of("222")));
        check(JobManager.checkSummary(1, List.of()).equals("1 update available"),
                "summary singular",
                JobManager.checkSummary(1, List.of()));
        check(JobManager.checkSummary(0, List.of()).equals("Everything is up to date"),
                "summary clean");
        check(JobManager.skippedSuffix(List.of("1", "2")).equals(
                        "; 2 workshop item(s) skipped (update in flight - re-run the check to confirm)"),
                "skipped suffix names the count",
                JobManager.skippedSuffix(List.of("1", "2")));
        check(JobManager.skippedSuffix(List.of()).isEmpty(),
                "skipped suffix empty when nothing skipped");
        String s2 = JobManager.checkSummary(0, List.of("222", "333"));
        check(s2.contains("Everything is up to date") && s2.contains("222, 333"),
                "summary clean + missing lists ids", s2);

        // ---- 5. fake steamcmd download -> install -> map ----
        String found = backend.steamCmd().findExecutable();
        check(fakeExe.equals(found), "override steamcmd found", found);
        String upId = jobs.submitUpdate("99999");
        Map<String, Object> ust = awaitDone(jobs, upId);
        check("done".equals(ust.get("state")), "update completes: " + ust.get("state"),
                ust.get("error"));
        File installedInfo = new File(backend.modsDir(), "FakeMod-99999/common/mod.info");
        check(installedInfo.isFile(), "mod installed to mods dir");
        WorkshopMap.Entry e99999 = backend.workshopMap().snapshot().get("99999");
        check(e99999 != null && e99999.modIds.contains("FakeMod-99999"),
                "map records workshop->mod");

        // ---- 5b. steamcmd failure surfaces as a failed job, not a hang ----
        String failId = jobs.submitUpdate("0"); // fake steamcmd exits 1 for id 0
        Map<String, Object> fst = awaitDone(jobs, failId);
        check("failed".equals(fst.get("state")), "steamcmd failure -> failed job",
                fst.get("state"));
        check(String.valueOf(fst.get("error")).contains("exit=1"),
                "failure error cites the exit code", fst.get("error"));

        // ---- 6. invalid workshop id fails cleanly ----
        String badId = jobs.submitUpdate("abc");
        Map<String, Object> bst = awaitDone(jobs, badId);
        check("failed".equals(bst.get("state")), "invalid id fails", bst.get("state"));

        // ---- 5c. more tools: export ----
        String exportPath = backend.exportModList(List.of("2685600088", "12345"));
        File exportFile = new File(exportPath);
        check(exportFile.isFile(), "export writes file", exportPath);
        check("workshopbridge-exports".equals(exportFile.getParentFile().getName()),
                "export lands in workshopbridge-exports", exportPath);
        check(exportPath.endsWith(".txt"), "export file is a .txt", exportPath);
        String exportText = Files.readString(exportFile.toPath());
        check(exportText.contains(
                        "https://steamcommunity.com/sharedfiles/filedetails/?id=2685600088\n")
                        && exportText.contains(
                        "https://steamcommunity.com/sharedfiles/filedetails/?id=12345\n"),
                "export writes one URL per line", exportText);
        // two exports in the same second must not overwrite each other
        String exp1 = backend.exportModList(List.of("111"));
        String exp2 = backend.exportModList(List.of("222"));
        check(!exp1.equals(exp2), "back-to-back exports get distinct paths",
                exp1 + " vs " + exp2);
        check(Files.readString(new File(exp1).toPath()).contains("?id=111"),
                "first export keeps its content");
        check(Files.readString(new File(exp2).toPath()).contains("?id=222"),
                "second export keeps its content");

        // ---- 5d. more tools: import job (fake steamcmd does the work) ----
        String impId = jobs.submitImport(List.of("99994", "99995"));
        Map<String, Object> ist = awaitDone(jobs, impId);
        check("done".equals(ist.get("state")), "import completes", ist.get("error"));
        check(new File(backend.modsDir(), "FakeMod-99994/common/mod.info").isFile()
                        && new File(backend.modsDir(), "FakeMod-99995/common/mod.info").isFile(),
                "import installs every id");
        check(backend.workshopMap().snapshot().containsKey("99994")
                        && backend.workshopMap().snapshot().containsKey("99995"),
                "import records workshop->mod in the map");
        check(String.valueOf(ist.get("message")).contains("Imported 2"),
                "import message counts", ist.get("message"));
        // a failing id fails the job with the id named (fake exits 1 for 0)
        String impFail = jobs.submitImport(List.of("99993", "0"));
        Map<String, Object> ifst = awaitDone(jobs, impFail);
        check("failed".equals(ifst.get("state")), "import failure -> failed job",
                ifst.get("state"));
        check(String.valueOf(ifst.get("error")).contains("failed on 0"),
                "import failure names the id", ifst.get("error"));
        // junk ids never reach the downloader
        String impJunk = jobs.submitImport(List.of("abc", "12x", ""));
        Map<String, Object> jst = awaitDone(jobs, impJunk);
        check("failed".equals(jst.get("state")), "import of only-junk fails cleanly",
                jst.get("state"));

        // ---- 5d2. adopt: force-download, verify, install, record ----
        String adoptId = jobs.submitAdopt("99990", "FakeMod-99990");
        Map<String, Object> ast = awaitDone(jobs, adoptId);
        check("done".equals(ast.get("state")), "adopt completes", ast.get("error"));
        check(new File(backend.modsDir(), "FakeMod-99990/common/mod.info").isFile(),
                "adopt installs the mod");
        check(backend.workshopMap().snapshot().containsKey("99990"),
                "adopt records workshop->mod in the map");
        check(String.valueOf(ast.get("message")).contains("Adopted"),
                "adopt message", ast.get("message"));
        // id mismatch: nothing is overwritten, nothing recorded
        String misId = jobs.submitAdopt("99989", "NotInThere");
        Map<String, Object> mst = awaitDone(jobs, misId);
        check("failed".equals(mst.get("state")), "adopt mismatch -> failed job",
                mst.get("state"));
        check(String.valueOf(mst.get("error")).contains("does not contain mod 'NotInThere'"),
                "adopt mismatch names the expected mod", mst.get("error"));
        check(String.valueOf(mst.get("error")).contains("FakeMod-99989"),
                "adopt mismatch lists what the item holds", mst.get("error"));
        check(!new File(backend.modsDir(), "FakeMod-99989").exists(),
                "adopt mismatch installs nothing");
        check(!backend.workshopMap().snapshot().containsKey("99989"),
                "adopt mismatch records nothing");
        // invalid workshop id fails cleanly
        String adoptBad = jobs.submitAdopt("abc", "Whatever");
        Map<String, Object> abst = awaitDone(jobs, adoptBad);
        check("failed".equals(abst.get("state")), "adopt with bad id fails",
                abst.get("state"));

        // ---- 5d3. stale sub-mods: an update drops what the item no longer holds ----
        // 99987 is a two-mod item in the fake steamcmd; the .single-99987
        // marker makes it serve only the first (author removed the second).
        String twoId = jobs.submitUpdate("99987");
        Map<String, Object> twoSt = awaitDone(jobs, twoId);
        check("done".equals(twoSt.get("state")), "two-mod item installs", twoSt.get("error"));
        File modA = new File(backend.modsDir(), "FakeMod-99987-A");
        File modB = new File(backend.modsDir(), "FakeMod-99987-B");
        check(modA.isDirectory() && modB.isDirectory(), "both sub-mods installed");
        check(backend.workshopMap().snapshot().get("99987").modIds
                        .containsAll(List.of("FakeMod-99987-A", "FakeMod-99987-B")),
                "map records both sub-mods");
        // protection: another item claims B, so the update must keep its folder
        backend.workshopMap().record("99986", List.of("FakeMod-99987-B"), 123L);
        File singleMarker = new File(backend.cacheDir(), ".single-99987");
        check(singleMarker.createNewFile(), "single-mod marker created");
        String twoId2 = jobs.submitUpdate("99987");
        Map<String, Object> twoSt2 = awaitDone(jobs, twoId2);
        check("done".equals(twoSt2.get("state")), "update with removed sub-mod completes",
                twoSt2.get("error"));
        check(modB.isDirectory(), "claimed-elsewhere folder is kept");
        check(backend.workshopMap().snapshot().get("99987").modIds
                        .equals(List.of("FakeMod-99987-A")),
                "map drops the removed sub-mod");
        // no other claim: the stale folder is removed
        backend.workshopMap().record("99986", List.of(), 123L);
        backend.workshopMap().record("99987",
                List.of("FakeMod-99987-A", "FakeMod-99987-B"), 123L);
        String twoId3 = jobs.submitUpdate("99987");
        Map<String, Object> twoSt3 = awaitDone(jobs, twoId3);
        check("done".equals(twoSt3.get("state")), "stale-cleanup update completes",
                twoSt3.get("error"));
        check(!modB.exists(), "unclaimed stale folder is removed");
        check(modA.isDirectory(), "surviving sub-mod untouched");
        check(backend.workshopMap().snapshot().get("99987").modIds
                        .equals(List.of("FakeMod-99987-A")),
                "map records only the surviving sub-mod");
        check(singleMarker.delete(), "single-mod marker cleaned up");

        // ---- 5e. collection children parsing (offline, real captured fixture) ----
        // fixture: live GetCollectionDetails response for collection 3624667829
        String collJson = Files.readString(
                new File(System.getProperty("wb.test.fixtures"), "collectiondetails.json").toPath(),
                StandardCharsets.UTF_8);
        check(WorkshopApi.parseChildren(collJson).equals(
                        List.of("3579640010", "3624669324", "3628452306", "3721829036")),
                "parseChildren reads the real collectiondetails shape",
                WorkshopApi.parseChildren(collJson));
        String collInline = "{\"response\":{\"result\":1,\"collectiondetails\":[{"
                + "\"publishedfileid\":\"555\",\"result\":1,"
                + "\"children\":[{\"publishedfileid\":\"111\",\"sortorder\":1},"
                + "{\"publishedfileid\":222,\"sortorder\":2},"
                + "{\"kind\":\"collection\"}]}]}}";
        check(WorkshopApi.parseChildren(collInline).equals(List.of("111", "222")),
                "parseChildren reads string+numeric child ids",
                WorkshopApi.parseChildren(collInline));
        String fileJson = "{\"response\":{\"collectiondetails\":[{\"publishedfileid\":\"666\"}]}}";
        check(WorkshopApi.parseChildren(fileJson).isEmpty(),
                "parseChildren empty for non-collection (not an error)");
        check(throwsIAE(() -> WorkshopApi.parseChildren("nope")),
                "parseChildren rejects malformed JSON");
        check(throwsIAE(() -> WorkshopApi.parseChildren("{\"response\":{}}")),
                "parseChildren rejects missing details array");

        // ---- 5f. id list parsing ----
        check(SteamCmdApi.parseIdList("1, 2\n3\t2").equals(List.of("1", "2", "3")),
                "parseIdList splits on comma/whitespace and dedupes");
        check(SteamCmdApi.parseIdList("abc, ,12x").isEmpty(),
                "parseIdList rejects junk");
        check(SteamCmdApi.parseIdList(null).isEmpty(), "parseIdList null -> empty");

        // ---- 7. unknown job ----
        check(jobs.statusJson("no-such-job") == null, "unknown job -> null");

        // ---- 9. interrupted-install recovery ----
        File modsDir = backend.modsDir();
        File stageDir = new File(zomboidDir, "workshop_cache/.install-staging");
        Consumer<String> quiet = s -> {};
        // case A: crash between the two renames -> complete forward
        // (legacy layout: staging next to the destination)
        File victimOld = new File(modsDir, "VictimMod.old-aaa");
        File victimNew = new File(modsDir, "VictimMod.new-aaa");
        writeFile(new File(victimOld, "common/mod.info"), "id=VictimMod\n");
        writeFile(new File(victimNew, "common/mod.info"), "id=VictimMod\n");
        writeFile(new File(victimNew, "newfile.txt"), "new");
        ModInstaller.recoverInterruptedInstalls(modsDir.toPath(), stageDir.toPath(), quiet);
        check(new File(modsDir, "VictimMod/newfile.txt").isFile(),
                "mid-swap crash completes forward");
        check(!victimOld.exists() && !victimNew.exists(), "mid-swap leftovers cleaned");
        // case A2: same, but with the current layout (staging in the stage dir,
        // outside the mods folder the game's file watcher walks)
        File victimOld2 = new File(stageDir, "Victim2Mod.old-bbb");
        File victimNew2 = new File(stageDir, "Victim2Mod.new-bbb");
        writeFile(new File(victimOld2, "common/mod.info"), "id=Victim2Mod\n");
        writeFile(new File(victimNew2, "common/mod.info"), "id=Victim2Mod\n");
        writeFile(new File(victimNew2, "newfile.txt"), "new");
        ModInstaller.recoverInterruptedInstalls(modsDir.toPath(), stageDir.toPath(), quiet);
        check(new File(modsDir, "Victim2Mod/newfile.txt").isFile(),
                "mid-swap crash completes forward (stage dir)");
        check(!victimOld2.exists() && !victimNew2.exists(), "stage-dir leftovers cleaned");
        // case B: backup left after a completed swap -> dropped, live tree kept
        File staleLive = new File(modsDir, "StaleMod");
        writeFile(new File(staleLive, "keep.txt"), "keep");
        File staleOld = new File(modsDir, "StaleMod.old-bbb");
        writeFile(new File(staleOld, "old.txt"), "old");
        ModInstaller.recoverInterruptedInstalls(modsDir.toPath(), stageDir.toPath(), quiet);
        check(new File(staleLive, "keep.txt").isFile() && !staleOld.exists(),
                "post-swap backup cleaned");
        // case C: partial staging from a copy-phase crash -> dropped
        File partialLive = new File(modsDir, "PartialMod");
        writeFile(new File(partialLive, "keep.txt"), "keep");
        File partialNew = new File(modsDir, "PartialMod.new-ccc");
        writeFile(new File(partialNew, "partial.txt"), "partial");
        ModInstaller.recoverInterruptedInstalls(modsDir.toPath(), stageDir.toPath(), quiet);
        check(new File(partialLive, "keep.txt").isFile() && !partialNew.exists(),
                "partial staging dropped");

        // ---- 10. reinstall clean-replaces through the atomic swap ----
        // scratch dirs live under the test work dir, never the system temp
        // (on Windows that would be inside the user profile)
        File scratch = scratchDir(zomboidDir, "wb-scratch");
        File itemV1 = new File(scratch, "itemV1/mods/ReMod");
        writeFile(new File(itemV1, "common/mod.info"), "id=ReMod\n");
        writeFile(new File(itemV1, "old.txt"), "v1");
        ModInstaller.install(new File(scratch, "itemV1"), modsDir, stageDir, quiet);
        check(new File(modsDir, "ReMod/old.txt").isFile(), "v1 installed");
        File itemV2 = new File(scratch, "itemV2/mods/ReMod");
        writeFile(new File(itemV2, "common/mod.info"), "id=ReMod\n");
        writeFile(new File(itemV2, "new.txt"), "v2");
        List<String> ids = ModInstaller.install(new File(scratch, "itemV2"), modsDir, stageDir, quiet);
        File reMod = new File(modsDir, "ReMod");
        check(new File(reMod, "new.txt").isFile() && !new File(reMod, "old.txt").exists(),
                "reinstall clean-replaces (stale files gone)");
        check(ids.equals(List.of("ReMod")), "install returns mod ids", ids);
        boolean leftovers = false;
        File[] modEntries = modsDir.listFiles();
        if (modEntries != null) {
            for (File f : modEntries) {
                if (f.getName().contains(".new-") || f.getName().contains(".old-")) {
                    leftovers = true;
                }
            }
        }
        check(!leftovers, "no staging dirs left in mods after install");
        boolean stageLeftovers = false;
        File[] stageEntries = stageDir.listFiles();
        if (stageEntries != null) {
            stageLeftovers = stageEntries.length > 0;
        }
        check(!stageLeftovers, "no staging dirs left in stage dir after install");

        // ---- 11. installArchive handles a real tar.gz ----
        File tgzDir = scratchDir(zomboidDir, "wb-tgz");
        File contentDir = new File(tgzDir, "content");
        contentDir.mkdirs();
        File sh = new File(contentDir, "steamcmd.sh");
        Files.writeString(sh.toPath(), "#!/bin/sh\necho hi\n");
        Process tar = new ProcessBuilder("tar", "-czf",
                new File(tgzDir, "sc.tar.gz").getAbsolutePath(),
                "-C", contentDir.getAbsolutePath(), "steamcmd.sh").start();
        check(tar.waitFor() == 0, "tar fixture created");
        SteamCmd sc = new SteamCmd(zomboidDir);
        File exeDir = new File(tgzDir, "out");
        String exe = sc.installArchive(new File(tgzDir, "sc.tar.gz"), false, exeDir,
                s -> {});
        check(new File(exe).isFile() && new File(exe).canExecute(), "installArchive extracts tar.gz", exe);

        // ---- 11b. tar.gz with a GNU long filename (>100 chars -> @LongLink) ----
        File longDir = scratchDir(zomboidDir, "wb-longname");
        File longContent = new File(longDir, "content");
        longContent.mkdirs();
        Files.writeString(new File(longContent, "steamcmd.sh").toPath(), "#!/bin/sh\necho hi\n");
        String longFileName = "a".repeat(120) + ".txt";
        Files.writeString(new File(longContent, longFileName).toPath(), "long-name-ok");
        Process tarLong = new ProcessBuilder("tar", "--format=gnu", "-czf",
                new File(longDir, "long.tar.gz").getAbsolutePath(),
                "-C", longContent.getAbsolutePath(), "steamcmd.sh", longFileName).start();
        check(tarLong.waitFor() == 0, "long-name tar fixture created");
        File longOut = new File(longDir, "out");
        sc.installArchive(new File(longDir, "long.tar.gz"), false, longOut, s -> {});
        File extractedLong = new File(longOut, longFileName);
        check(extractedLong.isFile()
                && Files.readString(extractedLong.toPath()).equals("long-name-ok"),
                "installArchive handles GNU long names");

        // ---- 12. 32-bit hint fires on the classic failure signatures ----
        // (pass the nixos flag explicitly: the 1-arg overload sniffs the real
        // OS, so on NixOS these take the steam-run branch instead)
        check(SteamCmd.missing32BitHint(
                "did not identify as steamcmd (exit=127, output: .../linux32/steamcmd: No such file or directory)",
                false).contains("32-bit"), "32-bit hint on exit=127");
        check(SteamCmd.missing32BitHint(
                "error while loading shared libraries: libstdc++.so.6: cannot open shared object file",
                false).contains("32-bit"), "32-bit hint on shared libraries");
        check(SteamCmd.missing32BitHint(
                "did not identify as steamcmd (exit=127)", true).contains("steam-run"),
                "NixOS exit=127 hint names steam-run");
        // Windows branch (direct: isWindows() sniffs the real OS)
        check(SteamCmd.windowsFailureHint("createprocess error=193, %1 is not a valid"
                        + " win32 application").contains("Defender"),
                "Windows corrupt-download hint");
        check(SteamCmd.windowsFailureHint("cannot launch: createprocess error=5,"
                        + " access is denied").contains("Unblock"),
                "Windows blocked-exe hint");
        check(SteamCmd.windowsFailureHint("did not identify as steamcmd (exit=1)").isEmpty(),
                "Windows hint empty for unrelated failures");
        check(SteamCmd.missing32BitHint(
                "did not identify as steamcmd (exit=1, output: nope)").isEmpty(),
                "no 32-bit hint for other failures");

        // ---- 13. NixOS detection and hint ----
        check(SteamCmd.isNixOSRelease("NAME=NixOS\nID=nixos\nVERSION=\"25.05\"\n"),
                "detects NixOS");
        check(!SteamCmd.isNixOSRelease("NAME=Ubuntu\nID=ubuntu\n"),
                "non-NixOS not detected");
        check(SteamCmd.missing32BitHint("did not identify as steamcmd (exit=127)", true)
                .contains("steam-run"), "NixOS hint names steam-run");

        // ---- 14. noexec fallback helpers ----
        check(SteamCmd.isExecDenied(
                "Bootstrapped steamcmd failed validation in /mnt/x: cannot launch:"
                        + " Cannot run program \"/mnt/x/steamcmd.sh\": posix_spawn failed,"
                        + " error: 13 (Permission denied)"),
                "EACCES detected as exec-denied");
        check(SteamCmd.isExecDenied("Cannot run program \"foo\": error=13, Permission denied"),
                "error=13 detected as exec-denied");
        check(!SteamCmd.isExecDenied("did not identify as steamcmd (exit=127)"),
                "exit=127 is not exec-denied");
        check(!SteamCmd.isExecDenied(null), "null is not exec-denied");
        check(SteamCmd.missing32BitHint(
                "cannot launch: Cannot run program \"/home/u/.cache/wb/steamcmd.sh\":"
                        + " error=2, No such file or directory",
                true).contains("steam-run"),
                "NixOS error=2 hint names steam-run");
        check(SteamCmd.missing32BitHint(
                "cannot launch: Cannot run program \"/home/u/.cache/wb/steamcmd.sh\":"
                        + " error=2, No such file or directory",
                false).isEmpty(),
                "no error=2 hint off NixOS");
        check(SteamCmd.isExecDenied(
                "Cannot run program \"C:\\wb\\steamcmd.exe\": CreateProcess error=5, Access is denied"),
                "Windows error=5 detected as exec-denied");
        check(SteamCmd.isExecDenied(
                "Cannot run program \"C:\\wb\\steamcmd.exe\": CreateProcess error=193,"
                        + " %1 is not a valid Win32 application"),
                "Windows error=193 detected as exec-denied");
        File fbXdg = SteamCmd.fallbackSteamCmdDir(false, null, "/tmp/xdgcache", "/home/u");
        check(fbXdg.getAbsolutePath().equals("/tmp/xdgcache/workshopbridge/steamcmd"),
                "fallback honors XDG_CACHE_HOME", fbXdg);
        File fbHome = SteamCmd.fallbackSteamCmdDir(false, null, "", "/home/u");
        check(fbHome.getAbsolutePath().equals("/home/u/.cache/workshopbridge/steamcmd"),
                "fallback defaults to ~/.cache", fbHome);
        File fbWin = SteamCmd.fallbackSteamCmdDir(true, "C:\\Users\\u\\AppData\\Local",
                null, "C:\\Users\\u");
        check(fbWin.getPath().equals("C:\\Users\\u\\AppData\\Local" + File.separator
                        + "workshopbridge" + File.separator + "steamcmd"),
                "fallback prefers %LOCALAPPDATA% on Windows", fbWin);
        File fbWinNoEnv = SteamCmd.fallbackSteamCmdDir(true, "", null, "C:\\Users\\u");
        check(fbWinNoEnv.getPath().equals("C:\\Users\\u" + File.separator + ".cache"
                        + File.separator + "workshopbridge" + File.separator + "steamcmd"),
                "Windows fallback without LOCALAPPDATA", fbWinNoEnv);

        // ---- 15. posix_spawn hint, ANSI stripping, validation leniency ----
        check(SteamCmd.posixSpawnHint(
                "cannot launch: Cannot run program \"/x/steamcmd.sh\": posix_spawn failed,"
                        + " error: 13 (Permission denied)")
                .contains("FORK"), "posix_spawn EACCES hint suggests FORK");
        check(SteamCmd.posixSpawnHint("did not identify as steamcmd (exit=1)").isEmpty(),
                "no FORK hint for other failures");
        check(SteamCmd.posixSpawnHint(null).isEmpty(), "no FORK hint for null");
        check(SteamCmd.stripAnsi("Loading Steam API...\u001B[0mOK")
                .equals("Loading Steam API...OK"), "stripAnsi removes SGR reset");
        check(SteamCmd.stripAnsi("\u001B[0mWaiting... \u001B[0mOK")
                .equals("Waiting... OK"), "stripAnsi removes multiple codes");
        check(SteamCmd.stripAnsi("plain line").equals("plain line"),
                "stripAnsi leaves plain text alone");
        check(SteamCmd.stripAnsi(null) == null, "stripAnsi null -> null");
        check(SteamCmd.validationOk(null), "null reason is usable");
        check(SteamCmd.validationOk("timed out after 30s without identifying as steamcmd"),
                "validation timeout is usable (first-run self-update)");
        check(!SteamCmd.validationOk("not executable"), "other reasons are not usable");

        // ---- 16. wbInvalidateModCaches resets the game mod caches ----
        zombie.ZomboidFileSystem.resetModFoldersCalled = false;
        zombie.gameStates.ChooseGameInfo.resetCalled = false;
        SteamCmdApi.wbInvalidateModCaches();
        check(zombie.ZomboidFileSystem.resetModFoldersCalled,
                "wbInvalidateModCaches resets the mod folder scan");
        check(zombie.gameStates.ChooseGameInfo.resetCalled,
                "wbInvalidateModCaches resets the mod info cache");

        // ---- 17. Main.main exposes the wb* Lua globals on cold boot ----
        // (ZB's automatic @LuaMethod discovery runs in its afterExposeAll
        // phase, before our jar loads; without the manual step the globals
        // never appear until a Lua reload.)
        me.zed_0xff.zombie_buddy.Exposer.addCalled = false;
        me.zed_0xff.zombie_buddy.Exposer.addedClass = null;
        FakeLuaExposer.exposedCount = 0;
        zombie.Lua.LuaManager.exposer = new FakeLuaExposer();
        Main.main(new String[0]);
        check(me.zed_0xff.zombie_buddy.Exposer.addCalled,
                "Main.main registers SteamCmdApi for global Lua exposure");
        check(me.zed_0xff.zombie_buddy.Exposer.addedClass == SteamCmdApi.class,
                "registered class is SteamCmdApi");
        check(FakeLuaExposer.exposedCount == 1,
                "Main.main exposes wb* globals immediately", FakeLuaExposer.exposedCount);
        // no Lua engine yet: still registers for later, exposes nothing,
        // and must not throw
        zombie.Lua.LuaManager.exposer = null;
        me.zed_0xff.zombie_buddy.Exposer.addCalled = false;
        FakeLuaExposer.exposedCount = 0;
        Main.main(new String[0]);
        check(me.zed_0xff.zombie_buddy.Exposer.addCalled,
                "registration still happens when the exposer is not ready");
        check(FakeLuaExposer.exposedCount == 0,
                "nothing exposed immediately without a Lua engine");

        // ---- 18. wbOpenWorkshopPage builds OS-appropriate browser commands ----
        String realOs = System.getProperty("os.name");
        try {
            System.setProperty("os.name", "Windows 11");
            String[][] win = SteamCmdApi.browserCommands("https://steamcommunity.com/sharedfiles/filedetails/?id=1");
            check(win.length == 1 && win[0][0].equals("cmd") && win[0][3].equals("\"\"")
                            && win[0][4].endsWith("?id=1"),
                    "windows uses cmd /c start with an empty title",
                    java.util.Arrays.deepToString(win));
            System.setProperty("os.name", "Mac OS X");
            String[][] mac = SteamCmdApi.browserCommands("https://example.com/x");
            check(mac.length == 1 && mac[0][0].equals("open")
                            && mac[0][1].equals("https://example.com/x"),
                    "macos uses open", java.util.Arrays.deepToString(mac));
            System.setProperty("os.name", "Linux");
            String[][] lin = SteamCmdApi.browserCommands("https://example.com/x");
            check(lin.length >= 1 && lin[0][0].equals("xdg-open")
                            && lin[0][1].equals("https://example.com/x"),
                    "linux tries xdg-open first", java.util.Arrays.deepToString(lin));
        } finally {
            if (realOs != null) System.setProperty("os.name", realOs);
        }
        // invalid ids never reach a command line (valid ids would launch a
        // real browser, so they are not exercised here)
        check(!SteamCmdApi.wbOpenWorkshopPage("1 & evil"), "non-numeric id rejected");
        check(!SteamCmdApi.wbOpenWorkshopPage(null), "null id rejected");
        // openWithDesktop must degrade gracefully and never throw, whether
        // the desktop module is present or not (the sandbox has no display)
        SteamCmdApi.openWithDesktop("https://example.com/x");
        check(true, "openWithDesktop never throws");

        System.out.println(failures == 0 ? "ALL TESTS PASSED" : failures + " FAILURES");
        System.exit(failures == 0 ? 0 : 1);
    }

    static void writeFile(File f, String content) throws Exception {
        f.getParentFile().mkdirs();
        Files.writeString(f.toPath(), content, StandardCharsets.UTF_8);
    }

    /** Test scratch dir inside the (gitignored, per-run) test work dir. */
    static File scratchDir(File zomboidDir, String prefix) throws Exception {
        File base = new File(zomboidDir, ".scratch");
        base.mkdirs();
        return Files.createTempDirectory(base.toPath(), prefix).toFile();
    }

    /** Stand-in for Kahlua's LuaJavaClassExposer in the exposure test. */
    public static class FakeLuaExposer {
        static int exposedCount = 0;
        public void exposeGlobalFunctions(Object instance) {
            exposedCount++;
        }
    }

    /**
     * True when a plain HTTP round-trip to the stub API works. Used to decide
     * whether the live-HTTP checks can run in this environment; deliberately
     * independent of the code under test.
     */
    static boolean stubApiUsable(String url) {
        try {
            java.net.HttpURLConnection c =
                    (java.net.HttpURLConnection) new java.net.URL(url).openConnection();
            c.setConnectTimeout(3000);
            c.setReadTimeout(3000);
            c.setRequestMethod("POST");
            c.setDoOutput(true);
            byte[] body = "itemcount=0".getBytes(StandardCharsets.UTF_8);
            c.getOutputStream().write(body);
            if (c.getResponseCode() != 200) {
                return false;
            }
            String resp = new String(c.getInputStream().readAllBytes(), StandardCharsets.UTF_8);
            return resp.contains("publishedfiledetails");
        } catch (Exception e) {
            return false;
        }
    }
}
