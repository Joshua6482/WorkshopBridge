import com.workshopbridge.Json;
import java.util.*;

public class Rt {
    public static void main(String[] a) {
        // mimic JobManager.jobStatus() output shapes
        Map<String, Object> running = new LinkedHashMap<>();
        running.put("id", "job-42"); running.put("state", "running");
        running.put("done", 2); running.put("total", 5);
        running.put("current", "Downloading \"Cool Mod\" (id 12345) \\ path");
        running.put("error", "");
        System.out.println(Json.stringify(running));
        Map<String, Object> done = new LinkedHashMap<>();
        done.put("id", "job-43"); done.put("state", "done");
        done.put("done", 3); done.put("total", 3);
        done.put("updates", Arrays.asList("ModA", "ModB"));
        done.put("installed", Arrays.asList("ModA"));
        done.put("failed", new ArrayList<>());
        done.put("error", "");
        System.out.println(Json.stringify(done));
        Map<String, Object> failed = new LinkedHashMap<>();
        failed.put("id", "job-44"); failed.put("state", "failed");
        failed.put("error", "Couldn't reach Steam's servers - check your internet connection.");
        System.out.println(Json.stringify(failed));
        Map<String, Object> withDeps = new LinkedHashMap<>();
        withDeps.put("id", "job-45"); withDeps.put("state", "done");
        withDeps.put("done", 1); withDeps.put("total", 1);
        withDeps.put("updates", new ArrayList<>());
        Map<String, Object> dep1 = new LinkedHashMap<>();
        dep1.put("id", "3171167894"); dep1.put("title", "that DAMN Library");
        dep1.put("installed", false);
        Map<String, Object> dep2 = new LinkedHashMap<>();
        dep2.put("id", "999"); dep2.put("title", "Already \"There\"");
        dep2.put("installed", true);
        withDeps.put("deps", Arrays.asList(dep1, dep2));
        System.out.println(Json.stringify(withDeps));
        // mimic SteamCmdApi.wbGetServerMods() output shape
        Map<String, Object> serverMods = new LinkedHashMap<>();
        serverMods.put("steamMode", false);
        Map<String, Object> sm1 = new LinkedHashMap<>();
        sm1.put("id", "supermod"); sm1.put("workshopId", "111");
        sm1.put("name", "Super \"Mod\""); sm1.put("installed", false);
        Map<String, Object> sm2 = new LinkedHashMap<>();
        sm2.put("id", "manualmod"); sm2.put("workshopId", "");
        sm2.put("name", "Manual Mod"); sm2.put("installed", false);
        serverMods.put("mods", Arrays.asList(sm1, sm2));
        System.out.println(Json.stringify(serverMods));
    }
}
