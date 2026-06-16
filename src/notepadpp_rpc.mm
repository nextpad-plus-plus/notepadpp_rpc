/*
 * notepadpp_rpc — macOS port
 *
 * Original: Discord Rich Presence plugin for Notepad++ (Windows) by Zukaritasu
 * Shows in Discord the file currently being edited in Notepad++.
 *
 * macOS port:
 *   - Connects to Discord via UNIX domain socket (discord-ipc-N in temp dir)
 *   - Uses GCD (dispatch queues) instead of Win32 threads
 *   - Uses NSJSONSerialization for JSON encoding
 *   - Configuration stored under the host plugin config dir (NPPM_GETPLUGINSCONFIGDIR):
 *     <config>/notepadpp_rpc/notepadpp_rpc.json
 *   - Language detection via file extension
 *   - Status: file name, extension, size, line/column, language
 *   - Idle detection after configurable timeout
 *   - Options dialog (NSPanel)
 */

#include "NppPluginInterfaceMac.h"
#include "Scintilla.h"
#import <Cocoa/Cocoa.h>

#include <string>
#include <vector>
#include <map>
#include <mutex>
#include <atomic>
#include <chrono>
#include <cstring>
#include <cstdio>
#include <sstream>
#include <fstream>
#include <random>

// UNIX domain socket
#include <sys/socket.h>
#include <sys/un.h>
#include <unistd.h>
#include <poll.h>

// ─── Globals ─────────────────────────────────────────────────────────────────

static const char *PLUGIN_NAME = "Discord Rich Presence";
static const int NB_FUNC = 4;
static FuncItem funcItem[NB_FUNC];
NppData nppData;

// ─── Constants ───────────────────────────────────────────────────────────────

static const int64_t DEF_APPLICATION_ID = 938157386068279366LL;
static const int DEF_IDLE_TIME = 300; // seconds
static const int RPC_UPDATE_TIME = 15; // seconds between updates
static const int RPC_RECONNECT_TIME = 2; // seconds between reconnect attempts
static const char *NPP_DEFAULTIMAGE = "favicon";
static const char *NPP_IDLEIMAGE = "idle";
static const char *NPP_NAME = "Notepad++";

// ─── Configuration ──────────────────────────────────────────────────────────

struct PluginConfig {
    int64_t clientId = DEF_APPLICATION_ID;
    bool enable = true;
    bool hideDetails = false;
    bool hideState = false;
    bool langImage = true;
    bool elapsedTime = true;
    bool hideIdleStatus = false;
    int idleTime = DEF_IDLE_TIME;
    std::string detailsFormat = "Editing: %(file)";
    std::string stateFormat = "Size: %(size)";
    std::string largeTextFormat = "Editing a %(LANG) file";
};

static PluginConfig sConfig;
static std::mutex sConfigMutex;

// ─── Language info ───────────────────────────────────────────────────────────

struct LangInfo {
    std::string name;
    std::string image;
};

static LangInfo getLangInfo(const std::string &ext) {
    static std::map<std::string, LangInfo> langMap = {
        {".c",     {"C",            "c"}},
        {".h",     {"C/C++ Header", "c"}},
        {".cpp",   {"C++",          "cpp"}},
        {".cxx",   {"C++",          "cpp"}},
        {".cc",    {"C++",          "cpp"}},
        {".hpp",   {"C++ Header",   "cpp"}},
        {".cs",    {"C#",           "csharp"}},
        {".java",  {"Java",         "java"}},
        {".js",    {"JavaScript",   "javascript"}},
        {".mjs",   {"JavaScript",   "javascript"}},
        {".ts",    {"TypeScript",   "typescript"}},
        {".tsx",   {"TypeScript",   "typescript"}},
        {".py",    {"Python",       "python"}},
        {".rb",    {"Ruby",         "ruby"}},
        {".rs",    {"Rust",         "rust"}},
        {".go",    {"Go",           "go"}},
        {".swift", {"Swift",        "swift"}},
        {".m",     {"Objective-C",  "objectivec"}},
        {".mm",    {"Objective-C++","objectivec"}},
        {".php",   {"PHP",          "php"}},
        {".html",  {"HTML",         "html"}},
        {".htm",   {"HTML",         "html"}},
        {".css",   {"CSS",          "css"}},
        {".scss",  {"SCSS",         "css"}},
        {".json",  {"JSON",         "json"}},
        {".xml",   {"XML",          "xml"}},
        {".yaml",  {"YAML",         "yaml"}},
        {".yml",   {"YAML",         "yaml"}},
        {".md",    {"Markdown",     "markdown"}},
        {".sql",   {"SQL",          "sql"}},
        {".sh",    {"Shell",        "cmd"}},
        {".bash",  {"Bash",         "cmd"}},
        {".zsh",   {"Zsh",          "cmd"}},
        {".lua",   {"Lua",          "lua"}},
        {".pl",    {"Perl",         "perl"}},
        {".r",     {"R",            "r"}},
        {".R",     {"R",            "r"}},
        {".hs",    {"Haskell",      "haskell"}},
        {".erl",   {"Erlang",       "erlang"}},
        {".ex",    {"Elixir",       "erlang"}},
        {".ml",    {"OCaml",        "caml"}},
        {".lisp",  {"Lisp",         "lisp"}},
        {".el",    {"Emacs Lisp",   "lisp"}},
        {".cmake", {"CMake",        "cmake"}},
        {".f90",   {"Fortran",      "fortran"}},
        {".asm",   {"Assembly",     "asm"}},
        {".vb",    {"Visual Basic", "visualbasic"}},
        {".coffee",{"CoffeeScript", "coffeescript"}},
        {".ini",   {"INI",          "properties"}},
        {".toml",  {"TOML",         "properties"}},
        {".txt",   {"Text",         NPP_DEFAULTIMAGE}},
    };

    auto it = langMap.find(ext);
    if (it != langMap.end()) return it->second;
    return { "Unknown", NPP_DEFAULTIMAGE };
}

// ─── Helpers ─────────────────────────────────────────────────────────────────

static NppHandle getCurScintilla() {
    int which = -1;
    nppData._sendMessage(nppData._nppHandle, NPPM_GETCURRENTSCINTILLA, 0, (intptr_t)&which);
    return (which == 0) ? nppData._scintillaMainHandle : nppData._scintillaSecondHandle;
}

static intptr_t sci(NppHandle h, uint32_t msg, uintptr_t w = 0, intptr_t l = 0) {
    return nppData._sendMessage(h, msg, w, l);
}

static std::string getConfigDir() {
    @autoreleasepool {
        // Resolve the host plugin config dir (NPPM_GETPLUGINSCONFIGDIR), namespaced
        // under a notepadpp_rpc/ subfolder (survives plugin updates, unlike the
        // plugin's own folder). Fall back to the macOS app-support base — never a
        // hardcoded ~/.nextpad++ dot-folder.
        char buf[1024] = {0};
        nppData._sendMessage(nppData._nppHandle, NPPM_GETPLUGINSCONFIGDIR,
                             (uintptr_t)sizeof(buf), (intptr_t)buf);
        NSString *cfgRoot = (buf[0] != '\0')
            ? [NSString stringWithUTF8String:buf]
            : [NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory,
                  NSUserDomainMask, YES).firstObject
                  stringByAppendingPathComponent:@"Nextpad++/plugins/Config"];
        NSString *dir = [cfgRoot stringByAppendingPathComponent:@"notepadpp_rpc"];
        NSFileManager *fm = [NSFileManager defaultManager];
        [fm createDirectoryAtPath:dir withIntermediateDirectories:YES
                       attributes:nil error:nil];

        // One-time migration from the old per-plugin-folder location.
        NSString *newPath = [dir stringByAppendingPathComponent:@"notepadpp_rpc.json"];
        if (![fm fileExistsAtPath:newPath]) {
            for (NSString *legacy in @[@".nextpad++/plugins/notepadpp_rpc/notepadpp_rpc.json",
                                       @".notepad++/plugins/notepadpp_rpc/notepadpp_rpc.json"]) {
                NSString *old = [NSHomeDirectory() stringByAppendingPathComponent:legacy];
                if ([fm fileExistsAtPath:old]) {
                    [fm copyItemAtPath:old toPath:newPath error:nil];
                    break;
                }
            }
        }
        return std::string([dir UTF8String]);
    }
}

static std::string getConfigFilePath() {
    return getConfigDir() + "/notepadpp_rpc.json";
}

// ─── Config persistence ─────────────────────────────────────────────────────

static void saveConfig() {
    @autoreleasepool {
        std::lock_guard<std::mutex> lock(sConfigMutex);
        NSDictionary *dict = @{
            @"clientId": @(sConfig.clientId),
            @"enable": @(sConfig.enable),
            @"hideDetails": @(sConfig.hideDetails),
            @"hideState": @(sConfig.hideState),
            @"langImage": @(sConfig.langImage),
            @"elapsedTime": @(sConfig.elapsedTime),
            @"hideIdleStatus": @(sConfig.hideIdleStatus),
            @"idleTime": @(sConfig.idleTime),
            @"detailsFormat": @(sConfig.detailsFormat.c_str()),
            @"stateFormat": @(sConfig.stateFormat.c_str()),
            @"largeTextFormat": @(sConfig.largeTextFormat.c_str()),
        };
        NSData *data = [NSJSONSerialization dataWithJSONObject:dict
                                                      options:NSJSONWritingPrettyPrinted
                                                        error:nil];
        if (data)
            [data writeToFile:@(getConfigFilePath().c_str()) atomically:YES];
    }
}

static void loadConfig() {
    @autoreleasepool {
        NSData *data = [NSData dataWithContentsOfFile:@(getConfigFilePath().c_str())];
        if (!data) return;
        NSDictionary *dict = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
        if (!dict) return;

        std::lock_guard<std::mutex> lock(sConfigMutex);
        if (dict[@"clientId"]) sConfig.clientId = [dict[@"clientId"] longLongValue];
        if (dict[@"enable"]) sConfig.enable = [dict[@"enable"] boolValue];
        if (dict[@"hideDetails"]) sConfig.hideDetails = [dict[@"hideDetails"] boolValue];
        if (dict[@"hideState"]) sConfig.hideState = [dict[@"hideState"] boolValue];
        if (dict[@"langImage"]) sConfig.langImage = [dict[@"langImage"] boolValue];
        if (dict[@"elapsedTime"]) sConfig.elapsedTime = [dict[@"elapsedTime"] boolValue];
        if (dict[@"hideIdleStatus"]) sConfig.hideIdleStatus = [dict[@"hideIdleStatus"] boolValue];
        if (dict[@"idleTime"]) sConfig.idleTime = [dict[@"idleTime"] intValue];
        if (dict[@"detailsFormat"]) sConfig.detailsFormat = [dict[@"detailsFormat"] UTF8String];
        if (dict[@"stateFormat"]) sConfig.stateFormat = [dict[@"stateFormat"] UTF8String];
        if (dict[@"largeTextFormat"]) sConfig.largeTextFormat = [dict[@"largeTextFormat"] UTF8String];
    }
}

// ─── Discord IPC protocol ───────────────────────────────────────────────────

struct DiscordIPCHeader {
    uint32_t opcode;
    uint32_t length;
};

static int sDiscordSocket = -1;
static std::atomic<bool> sConnected{false};
static std::atomic<bool> sKeepRunning{false};
static std::atomic<int64_t> sLastUpdateTime{0};
static int64_t sStartTime = 0;
// Tracks the two background connection-loop blocks so stopConnectionLoop() can
// WAIT for them to finish before returning. Without this, NPPN_SHUTDOWN sets
// sKeepRunning=false but returns immediately; the app then exit()s and runs the
// C++ static destructors (sConfigMutex/sPresenceMutex/sConfig/...) while a loop is
// still mid-iteration → it locks a destroyed std::mutex → std::system_error thrown
// → std::terminate → SIGABRT on shutdown.
static dispatch_group_t sLoopGroup = nil;

static std::string generateNonce() {
    static std::random_device rd;
    static std::mt19937 gen(rd());
    static std::uniform_int_distribution<> dis(100000, 999999);
    return std::to_string(dis(gen));
}

static bool sendDiscordMessage(int sock, uint32_t opcode, const std::string &json) {
    if (sock < 0) return false;

    DiscordIPCHeader header;
    header.opcode = opcode;
    header.length = (uint32_t)json.size();

    // Write header
    ssize_t written = write(sock, &header, sizeof(header));
    if (written != sizeof(header)) return false;

    // Write payload
    written = write(sock, json.c_str(), json.size());
    if (written != (ssize_t)json.size()) return false;

    // Read response
    DiscordIPCHeader responseHeader;
    struct pollfd pfd = { sock, POLLIN, 0 };
    int pollResult = poll(&pfd, 1, 3000); // 3s timeout
    if (pollResult <= 0) return false;

    ssize_t bytesRead = read(sock, &responseHeader, sizeof(responseHeader));
    if (bytesRead != sizeof(responseHeader)) return false;

    if (responseHeader.length > 0) {
        std::string response(responseHeader.length, '\0');
        bytesRead = read(sock, response.data(), responseHeader.length);
        // We don't parse the response in detail; just check read succeeded
        if (bytesRead != (ssize_t)responseHeader.length) return false;
    }

    return true;
}

static bool connectToDiscord(int64_t clientId) {
    if (sDiscordSocket >= 0) {
        close(sDiscordSocket);
        sDiscordSocket = -1;
    }

    // On macOS, Discord IPC sockets are at:
    // $TMPDIR/discord-ipc-N  or  /tmp/discord-ipc-N
    @autoreleasepool {
        NSArray *tempDirs = @[
            NSTemporaryDirectory(),
            @"/tmp/",
            [NSString stringWithFormat:@"/var/folders/"],
        ];

        for (int i = 0; i < 10; i++) {
            for (NSString *baseDir in tempDirs) {
                NSString *pipePath = [NSString stringWithFormat:@"%@discord-ipc-%d", baseDir, i];
                const char *pathCStr = [pipePath UTF8String];

                struct sockaddr_un addr;
                memset(&addr, 0, sizeof(addr));
                addr.sun_family = AF_UNIX;
                strlcpy(addr.sun_path, pathCStr, sizeof(addr.sun_path));

                int sock = socket(AF_UNIX, SOCK_STREAM, 0);
                if (sock < 0) continue;

                if (connect(sock, (struct sockaddr *)&addr, sizeof(addr)) == 0) {
                    // Send handshake
                    std::string handshake = R"({"v":1,"client_id":")" +
                                           std::to_string(clientId) + R"("})";
                    DiscordIPCHeader header;
                    header.opcode = 0;
                    header.length = (uint32_t)handshake.size();

                    ssize_t w = write(sock, &header, sizeof(header));
                    if (w == sizeof(header)) {
                        w = write(sock, handshake.c_str(), handshake.size());
                        if (w == (ssize_t)handshake.size()) {
                            // Read response
                            struct pollfd pfd = { sock, POLLIN, 0 };
                            int pr = poll(&pfd, 1, 5000);
                            if (pr > 0) {
                                DiscordIPCHeader respHeader;
                                ssize_t r = read(sock, &respHeader, sizeof(respHeader));
                                if (r == sizeof(respHeader) && respHeader.length > 0) {
                                    std::string resp(respHeader.length, '\0');
                                    read(sock, resp.data(), respHeader.length);
                                    sDiscordSocket = sock;
                                    return true;
                                }
                            }
                        }
                    }
                    close(sock);
                }
                else {
                    close(sock);
                }
            }
        }
    }
    return false;
}

static void disconnectDiscord() {
    if (sDiscordSocket >= 0) {
        // Clear activity before disconnecting
        std::string clearJson = R"({"cmd":"SET_ACTIVITY","args":{"pid":)" +
                                std::to_string(getpid()) +
                                R"(,"activity":null},"nonce":")" +
                                generateNonce() + R"("})";
        sendDiscordMessage(sDiscordSocket, 1, clearJson);
        close(sDiscordSocket);
        sDiscordSocket = -1;
    }
    sConnected.store(false);
}

// ─── Editor info ─────────────────────────────────────────────────────────────

struct EditorStatus {
    std::string fileName;
    std::string extension;
    std::string filePath;
    intptr_t line = 0;
    intptr_t column = 0;
    intptr_t fileSize = 0;
    intptr_t lineCount = 0;
    LangInfo langInfo;
};

static EditorStatus getEditorStatus() {
    EditorStatus st;
    NppHandle h = getCurScintilla();

    // File name
    char nameBuf[4096] = {0};
    nppData._sendMessage(nppData._nppHandle, NPPM_GETFILENAME, sizeof(nameBuf) - 1, (intptr_t)nameBuf);
    st.fileName = nameBuf;

    // Extension
    char extBuf[256] = {0};
    nppData._sendMessage(nppData._nppHandle, NPPM_GETEXTPART, sizeof(extBuf) - 1, (intptr_t)extBuf);
    st.extension = extBuf;

    // Full path
    char pathBuf[4096] = {0};
    nppData._sendMessage(nppData._nppHandle, NPPM_GETFULLCURRENTPATH, sizeof(pathBuf) - 1, (intptr_t)pathBuf);
    st.filePath = pathBuf;

    // Editor info
    st.fileSize = sci(h, SCI_GETLENGTH);
    intptr_t pos = sci(h, SCI_GETCURRENTPOS);
    st.line = sci(h, SCI_LINEFROMPOSITION, (uintptr_t)pos) + 1;
    st.column = sci(h, SCI_GETCOLUMN, (uintptr_t)pos) + 1;
    st.lineCount = sci(h, SCI_GETLINECOUNT);

    // Language info
    st.langInfo = getLangInfo(st.extension);

    return st;
}

// ─── Format string helper ───────────────────────────────────────────────────

static std::string formatString(const std::string &fmt, const EditorStatus &st) {
    std::string result = fmt;
    auto replace = [&](const std::string &token, const std::string &value) {
        size_t pos;
        while ((pos = result.find(token)) != std::string::npos) {
            result.replace(pos, token.size(), value);
        }
    };

    replace("%(file)", st.fileName);
    replace("%(extension)", st.extension);
    replace("%(line)", std::to_string(st.line));
    replace("%(column)", std::to_string(st.column));
    replace("%(line_count)", std::to_string(st.lineCount));
    replace("%(position)", std::to_string(st.line));

    // File size formatting
    std::string sizeStr;
    if (st.fileSize < 1024)
        sizeStr = std::to_string(st.fileSize) + " B";
    else if (st.fileSize < 1024 * 1024) {
        char buf[32];
        snprintf(buf, sizeof(buf), "%.1f KB", st.fileSize / 1024.0);
        sizeStr = buf;
    } else {
        char buf[32];
        snprintf(buf, sizeof(buf), "%.1f MB", st.fileSize / (1024.0 * 1024.0));
        sizeStr = buf;
    }
    replace("%(size)", sizeStr);

    // Language variants
    std::string langLower = st.langInfo.name;
    std::transform(langLower.begin(), langLower.end(), langLower.begin(), ::tolower);
    std::string langUpper = st.langInfo.name;
    std::transform(langUpper.begin(), langUpper.end(), langUpper.begin(), ::toupper);
    std::string langTitle = st.langInfo.name;

    replace("%(lang)", langLower);
    replace("%(Lang)", langTitle);
    replace("%(LANG)", langUpper);

    return result;
}

// ─── Build presence JSON ─────────────────────────────────────────────────────

static std::string buildPresenceJson(const EditorStatus &st, bool idle) {
    @autoreleasepool {
        NSMutableDictionary *activity = [NSMutableDictionary dictionary];

        std::lock_guard<std::mutex> lock(sConfigMutex);

        if (idle) {
            activity[@"details"] = @"Idling";
        } else {
            if (!st.fileName.empty()) {
                if (!sConfig.hideDetails) {
                    std::string details = formatString(sConfig.detailsFormat, st);
                    if (details.size() >= 2)
                        activity[@"details"] = @(details.c_str());
                }
                if (!sConfig.hideState) {
                    std::string state = formatString(sConfig.stateFormat, st);
                    if (state.size() >= 2)
                        activity[@"state"] = @(state.c_str());
                }
            }
        }

        // Assets
        NSMutableDictionary *assets = [NSMutableDictionary dictionary];
        if (idle) {
            assets[@"large_image"] = @(NPP_IDLEIMAGE);
            assets[@"large_text"] = @(NPP_NAME);
        } else if (!sConfig.langImage || st.fileName.empty()) {
            assets[@"large_image"] = @(NPP_DEFAULTIMAGE);
            assets[@"large_text"] = @(NPP_NAME);
        } else {
            assets[@"large_image"] = @(st.langInfo.image.c_str());
            std::string largeText = formatString(sConfig.largeTextFormat, st);
            if (largeText.size() >= 2)
                assets[@"large_text"] = @(largeText.c_str());
            if (![assets[@"large_image"] isEqualToString:@(NPP_DEFAULTIMAGE)]) {
                assets[@"small_image"] = @(NPP_DEFAULTIMAGE);
                assets[@"small_text"] = @(NPP_NAME);
            }
        }
        if (assets.count > 0)
            activity[@"assets"] = assets;

        // Timestamps
        if (sConfig.elapsedTime && sStartTime > 0) {
            activity[@"timestamps"] = @{ @"start": @(sStartTime) };
        }

        // Build full command
        NSDictionary *cmd = @{
            @"cmd": @"SET_ACTIVITY",
            @"nonce": @(generateNonce().c_str()),
            @"args": @{
                @"pid": @(getpid()),
                @"activity": activity
            }
        };

        NSData *jsonData = [NSJSONSerialization dataWithJSONObject:cmd options:0 error:nil];
        if (!jsonData) return "";
        return std::string((const char *)[jsonData bytes], [jsonData length]);
    }
}

// ─── Background connection & update thread ───────────────────────────────────

static dispatch_source_t sUpdateTimer = nil;
static dispatch_source_t sIdleTimer = nil;
static std::string sLastPresenceJson;
static std::mutex sPresenceMutex;

static void updatePresence() {
    if (!sConnected.load()) return;

    EditorStatus st = getEditorStatus();
    std::string json = buildPresenceJson(st, false);
    if (json.empty()) return;

    {
        std::lock_guard<std::mutex> lock(sPresenceMutex);
        if (json == sLastPresenceJson) return; // No change
        sLastPresenceJson = json;
    }

    sLastUpdateTime.store(std::chrono::duration_cast<std::chrono::seconds>(
        std::chrono::system_clock::now().time_since_epoch()).count());

    if (!sendDiscordMessage(sDiscordSocket, 1, json)) {
        sConnected.store(false);
    }
}

static void startConnectionLoop() {
    if (!sConfig.enable) return;

    sKeepRunning.store(true);
    if (!sLoopGroup) sLoopGroup = dispatch_group_create();

    dispatch_group_async(sLoopGroup, dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        while (sKeepRunning.load()) {
            if (!sConnected.load()) {
                int64_t clientId;
                {
                    std::lock_guard<std::mutex> lock(sConfigMutex);
                    clientId = sConfig.clientId;
                }
                if (connectToDiscord(clientId)) {
                    sConnected.store(true);
                    sStartTime = std::chrono::duration_cast<std::chrono::seconds>(
                        std::chrono::system_clock::now().time_since_epoch()).count();
                    sLastUpdateTime.store(sStartTime);

                    // Send initial presence
                    dispatch_async(dispatch_get_main_queue(), ^{
                        updatePresence();
                    });
                } else {
                    // Wait before retrying
                    for (int i = 0; i < RPC_RECONNECT_TIME * 10 && sKeepRunning.load(); i++) {
                        usleep(100000); // 100ms
                    }
                }
            } else {
                // Connected — send periodic updates
                for (int i = 0; i < RPC_UPDATE_TIME * 10 && sKeepRunning.load(); i++) {
                    usleep(100000); // 100ms
                }
                if (sConnected.load() && sKeepRunning.load()) {
                    // Re-send current presence (keepalive)
                    std::lock_guard<std::mutex> lock(sPresenceMutex);
                    if (!sLastPresenceJson.empty()) {
                        if (!sendDiscordMessage(sDiscordSocket, 1, sLastPresenceJson)) {
                            sConnected.store(false);
                        }
                    }
                }
            }
        }
    });

    // Idle detection thread
    dispatch_group_async(sLoopGroup, dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_LOW, 0), ^{
        bool wasIdle = false;
        while (sKeepRunning.load()) {
            // ~1s, but interruptible every 100ms so shutdown is prompt.
            for (int i = 0; i < 10 && sKeepRunning.load(); i++) usleep(100000);
            if (!sKeepRunning.load()) break;

            int idleTime;
            bool hideIdle;
            {
                std::lock_guard<std::mutex> lock(sConfigMutex);
                hideIdle = sConfig.hideIdleStatus;
                idleTime = sConfig.idleTime;
            }

            if (hideIdle) continue;
            if (!sConnected.load()) continue;

            int64_t now = std::chrono::duration_cast<std::chrono::seconds>(
                std::chrono::system_clock::now().time_since_epoch()).count();
            int64_t elapsed = now - sLastUpdateTime.load();

            if (elapsed >= idleTime) {
                if (!wasIdle) {
                    wasIdle = true;
                    // Dispatch to main queue — getEditorStatus() accesses
                    // UI state (EditorView, Scintilla) that is only safe
                    // to touch from the main thread.
                    dispatch_async(dispatch_get_main_queue(), ^{
                        EditorStatus st = getEditorStatus();
                        std::string json = buildPresenceJson(st, true);
                        if (!json.empty()) {
                            std::lock_guard<std::mutex> lock(sPresenceMutex);
                            sLastPresenceJson = json;
                            sendDiscordMessage(sDiscordSocket, 1, json);
                        }
                    });
                }
            } else if (wasIdle) {
                wasIdle = false;
                // Restore normal presence
                dispatch_async(dispatch_get_main_queue(), ^{
                    updatePresence();
                });
            }
        }
    });
}

static void stopConnectionLoop() {
    sKeepRunning.store(false);
    disconnectDiscord();   // also closes the socket, unblocking any in-flight send
    // Block until both background loops have actually exited, so they are not
    // touching our static mutexes/config when the process tears them down at exit
    // (this runs on the main thread during NPPN_SHUTDOWN). The loops only async-
    // dispatch to the main queue (never sync), so blocking here can't deadlock; the
    // bounded timeout guards against a loop stuck in a blocking socket call.
    if (sLoopGroup) {
        dispatch_group_wait(sLoopGroup,
            dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3 * NSEC_PER_SEC)));
    }
}

// ─── Menu commands ───────────────────────────────────────────────────────────

static void commandOptions() {
    @autoreleasepool {
        NSRect frame = NSMakeRect(200, 200, 450, 400);
        NSPanel *panel = [[NSPanel alloc] initWithContentRect:frame
                                                   styleMask:NSWindowStyleMaskTitled |
                                                             NSWindowStyleMaskClosable
                                                     backing:NSBackingStoreBuffered
                                                       defer:NO];
        [panel setTitle:@"Discord Rich Presence Options"];
        NSView *content = [panel contentView];
        CGFloat y = 350;

        // Enable checkbox
        NSButton *enableCheck = [NSButton checkboxWithTitle:@"Enable Rich Presence"
                                                    target:nil action:nil];
        enableCheck.frame = NSMakeRect(20, y, 300, 20);
        enableCheck.state = sConfig.enable ? NSControlStateValueOn : NSControlStateValueOff;
        [content addSubview:enableCheck];
        y -= 30;

        // Language image checkbox
        NSButton *langImgCheck = [NSButton checkboxWithTitle:@"Show language image"
                                                     target:nil action:nil];
        langImgCheck.frame = NSMakeRect(20, y, 300, 20);
        langImgCheck.state = sConfig.langImage ? NSControlStateValueOn : NSControlStateValueOff;
        [content addSubview:langImgCheck];
        y -= 30;

        // Elapsed time checkbox
        NSButton *elapsedCheck = [NSButton checkboxWithTitle:@"Show elapsed time"
                                                     target:nil action:nil];
        elapsedCheck.frame = NSMakeRect(20, y, 300, 20);
        elapsedCheck.state = sConfig.elapsedTime ? NSControlStateValueOn : NSControlStateValueOff;
        [content addSubview:elapsedCheck];
        y -= 30;

        // Hide details checkbox
        NSButton *hideDetailsCheck = [NSButton checkboxWithTitle:@"Hide details line"
                                                         target:nil action:nil];
        hideDetailsCheck.frame = NSMakeRect(20, y, 300, 20);
        hideDetailsCheck.state = sConfig.hideDetails ? NSControlStateValueOn : NSControlStateValueOff;
        [content addSubview:hideDetailsCheck];
        y -= 30;

        // Hide state checkbox
        NSButton *hideStateCheck = [NSButton checkboxWithTitle:@"Hide state line"
                                                       target:nil action:nil];
        hideStateCheck.frame = NSMakeRect(20, y, 300, 20);
        hideStateCheck.state = sConfig.hideState ? NSControlStateValueOn : NSControlStateValueOff;
        [content addSubview:hideStateCheck];
        y -= 30;

        // Hide idle checkbox
        NSButton *hideIdleCheck = [NSButton checkboxWithTitle:@"Hide idle status"
                                                      target:nil action:nil];
        hideIdleCheck.frame = NSMakeRect(20, y, 300, 20);
        hideIdleCheck.state = sConfig.hideIdleStatus ? NSControlStateValueOn : NSControlStateValueOff;
        [content addSubview:hideIdleCheck];
        y -= 40;

        // Details format
        NSTextField *detailsLabel = [NSTextField labelWithString:@"Details format:"];
        detailsLabel.frame = NSMakeRect(20, y, 120, 20);
        [content addSubview:detailsLabel];

        NSTextField *detailsField = [[NSTextField alloc] initWithFrame:NSMakeRect(140, y, 280, 24)];
        detailsField.stringValue = @(sConfig.detailsFormat.c_str());
        [content addSubview:detailsField];
        y -= 30;

        // State format
        NSTextField *stateLabel = [NSTextField labelWithString:@"State format:"];
        stateLabel.frame = NSMakeRect(20, y, 120, 20);
        [content addSubview:stateLabel];

        NSTextField *stateField = [[NSTextField alloc] initWithFrame:NSMakeRect(140, y, 280, 24)];
        stateField.stringValue = @(sConfig.stateFormat.c_str());
        [content addSubview:stateField];
        y -= 30;

        // Idle time
        NSTextField *idleLabel = [NSTextField labelWithString:@"Idle timeout (sec):"];
        idleLabel.frame = NSMakeRect(20, y, 120, 20);
        [content addSubview:idleLabel];

        NSTextField *idleField = [[NSTextField alloc] initWithFrame:NSMakeRect(140, y, 80, 24)];
        idleField.stringValue = [NSString stringWithFormat:@"%d", sConfig.idleTime];
        [content addSubview:idleField];
        y -= 40;

        // Save button — stops the modal loop so values are read and saved
        NSButton *saveBtn = [NSButton buttonWithTitle:@"Save" target:NSApp action:@selector(stopModal)];
        saveBtn.frame = NSMakeRect(340, y, 80, 30);
        saveBtn.keyEquivalent = @"\r"; // Enter key triggers Save
        [content addSubview:saveBtn];

        // Ensure the modal loop exits when the panel is closed by ANY means
        // (X button, Save button, programmatic close). Without this, clicking
        // the X close button would close the window but leave runModalForWindow
        // spinning with no visible window — freezing the entire app.
        id closeObserver = [[NSNotificationCenter defaultCenter]
            addObserverForName:NSWindowWillCloseNotification
                       object:panel
                        queue:nil
                   usingBlock:^(NSNotification *note) {
                       [NSApp stopModal];
                   }];

        [NSApp runModalForWindow:panel];

        [[NSNotificationCenter defaultCenter] removeObserver:closeObserver];

        // Always save when window closes
        {
            std::lock_guard<std::mutex> lock(sConfigMutex);
            sConfig.enable = enableCheck.state == NSControlStateValueOn;
            sConfig.langImage = langImgCheck.state == NSControlStateValueOn;
            sConfig.elapsedTime = elapsedCheck.state == NSControlStateValueOn;
            sConfig.hideDetails = hideDetailsCheck.state == NSControlStateValueOn;
            sConfig.hideState = hideStateCheck.state == NSControlStateValueOn;
            sConfig.hideIdleStatus = hideIdleCheck.state == NSControlStateValueOn;
            sConfig.detailsFormat = [detailsField.stringValue UTF8String];
            sConfig.stateFormat = [stateField.stringValue UTF8String];
            sConfig.idleTime = [idleField.stringValue intValue];
            if (sConfig.idleTime < 10) sConfig.idleTime = DEF_IDLE_TIME;
        }
        saveConfig();

        [panel close];

        // Restart connection if needed
        if (sConfig.enable && !sConnected.load()) {
            startConnectionLoop();
        } else if (!sConfig.enable) {
            stopConnectionLoop();
        }
    }
}

static void commandEditConfig() {
    saveConfig(); // Ensure file exists
    // Keep the path in a static so its .c_str() pointer is still valid when
    // the host's NPPM_DOOPEN handler (which uses dispatch_async) reads it
    // on the next runloop iteration.
    static std::string sConfigPath;
    sConfigPath = getConfigFilePath();
    nppData._sendMessage(nppData._nppHandle, NPPM_DOOPEN, 0, (intptr_t)sConfigPath.c_str());
}

static void commandAbout() {
    @autoreleasepool {
        NSAlert *alert = [[NSAlert alloc] init];
        [alert setMessageText:@"Discord Rich Presence"];
        [alert setInformativeText:
            @"Discord Rich Presence plugin for Notepad++ (macOS port)\n\n"
            "Shows in Discord the file being edited in Notepad++.\n\n"
            "Features:\n"
            "- File name, language, and size display\n"
            "- Language-specific icons\n"
            "- Idle detection\n"
            "- Customizable format strings\n"
            "  %(file) %(extension) %(line) %(column)\n"
            "  %(size) %(lang) %(Lang) %(LANG)\n\n"
            "Original Windows plugin by Zukaritasu (GPLv3)\n"
            "macOS port uses UNIX domain sockets for Discord IPC."];
        [alert addButtonWithTitle:@"OK"];
        [alert runModal];
    }
}

// ─── Plugin exports ──────────────────────────────────────────────────────────

extern "C" NPP_EXPORT void setInfo(NppData data) {
    nppData = data;
    loadConfig();

    int idx = 0;
    auto addItem = [&](const char *name, PFUNCPLUGINCMD func) {
        strncpy(funcItem[idx]._itemName, name, NPP_MENU_ITEM_SIZE);
        funcItem[idx]._pFunc = func;
        funcItem[idx]._init2Check = false;
        funcItem[idx]._pShKey = nullptr;
        idx++;
    };

    addItem("Options",                      commandOptions);      // 0
    // Separator: host treats _pFunc == nullptr as NSMenuItem separatorItem
    funcItem[idx]._itemName[0] = '\0';
    funcItem[idx]._pFunc = nullptr;
    funcItem[idx]._init2Check = false;
    funcItem[idx]._pShKey = nullptr;
    idx++;

    addItem("Edit configuration file",      commandEditConfig);   // 2
    addItem("About",                        commandAbout);        // 3

    // Start the Discord connection
    if (sConfig.enable) {
        startConnectionLoop();
    }
}

extern "C" NPP_EXPORT const char *getName() {
    return PLUGIN_NAME;
}

extern "C" NPP_EXPORT FuncItem *getFuncsArray(int *nbF) {
    *nbF = NB_FUNC;
    return funcItem;
}

extern "C" NPP_EXPORT void beNotified(SCNotification *n) {
    switch (n->nmhdr.code) {
        case NPPN_BUFFERACTIVATED:
        case NPPN_LANGCHANGED:
        case SCN_UPDATEUI:
            if (sConnected.load()) {
                updatePresence();
            }
            break;
        case NPPN_SHUTDOWN:
            stopConnectionLoop();
            saveConfig();
            break;
        default:
            break;
    }
}

extern "C" NPP_EXPORT intptr_t messageProc(uint32_t, uintptr_t, intptr_t) {
    return 1;
}
