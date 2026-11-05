// Lookout —— Claude Code 執行中 session 的監看視窗。外觀照 Mono Sharp design system。
//
// 兩個資料來源：
//   ~/.claude/sessions/<pid>.json          session 自己寫的狀態檔（有心跳）
//   ~/.claude/projects/<slug>/<sid>.jsonl  transcript，用來判斷它是不是在等你回覆
//
// 編譯：  ../install.sh（會編譯並裝到 ~/Library/Application Support/Lookout/app/）
//         只有 design/mono-sharp.tokens.json 改了才需要先跑 python3 gen_tokens.py
// 執行：  平常由 Claude 裡的 mod 開關；手動跑就是 ~/Library/Application\ Support/Lookout/app/lookout &
// 結束：  ⌘Q 或關掉視窗

import AppKit
import ApplicationServices
import Carbon.HIToolbox
import CoreText
import Foundation

/// 讀哪個 Claude 資料夾。平常是 ~/.claude；測試時用 LOOKOUT_CLAUDE_HOME 指到假資料，
/// 才不用在真的 ~/.claude 底下放假檔案 —— 其他 Claude session 也會讀那裡。
let claudeHome = ((ProcessInfo.processInfo.environment["LOOKOUT_CLAUDE_HOME"] ?? "~/.claude")
                  as NSString).expandingTildeInPath
let sessionsDirectory = claudeHome + "/sessions"
let projectsDirectory = claudeHome + "/projects"

// MARK: - 分類

enum Kind: String, Codable {
    case working        // 正在跑
    case atDialog       // 卡在權限對話框，等你按按鈕（任務做到一半）
    case needsReply     // 跑完一輪，而且宣稱「沒有你的答案就做不下去」
    case hasQuestion    // 跑完一輪，問了你一個問題，但沒有宣稱被擋住
    case settled        // 跑完了，沒有東西在等你 —— 可以不用理它
    case noSignal       // 閒置，但 transcript 裡沒有可判斷的訊號
    case unknown        // status 是沒見過的值
}

/// transcript 掃描掃出來的「有沒有東西在等你」。
enum Pending {
    case noSignal       // 整份 transcript 沒出現過 wrap_up（舊 session）
    case needsReply     // 最後一次 wrap_up 是 blocked，之後沒有你的訊息
    case hasQuestion    // 最後一次 wrap_up 有問題但沒 blocked，之後沒有你的訊息
    case settled        // 問題已被回答，或最後一次 wrap_up 根本沒問東西
}

struct SessionRow {
    let pid: Int32          // 未載入的 session 沒有程序，是 0
    let key: String         // 穩定的識別：Desktop 的 session id；CLI 的退回用 pid
    let sessionId: String   // transcript 的檔名
    let isLoaded: Bool      // false = 程序已經結束，這一列是記憶裡的最後狀態
    let title: String
    let cwd: String
    let status: String
    let since: Date
    let kind: Kind
    let ask: String     // 它在等你回答什麼（只有 needsReply / hasQuestion 有）
    let recap: String   // needsReply 卻沒寫 ask 時，那一輪的摘要；其他情況是空字串
    let choices: [Choice]   // 它給你的回覆選項（wrap_up 的 actions）；只有在問你問題時才有
    let link: URL?      // 在 Claude Desktop 打開這個 session；CLI 開的 session 沒有
}

/// session 問你問題時附上的回覆選項：按鈕上的字，和按下去要送出的那句話。
/// 來源是 wrap_up 的 actions；app 自己的動作（commit、開 PR…）從外面做不到，不收。
struct Choice: Codable, Equatable {
    let label: String
    let message: String
}

/// 打開某個 session 的網址。格式取自 app 自己的 session 清單 API（`link` 欄位，
/// 說明是「從 app 外面打開這個 session」）：固定前綴接上 session id。
/// 2026-10-27 對過 40 筆，前綴全部相同；狀態檔的 hostSessionId 就是那個 id。
func sessionLink(_ hostSessionId: String?) -> URL? {
    guard let id = hostSessionId, id.hasPrefix("local_") else { return nil }
    return URL(string: "claude://claude.ai/epitaxy/\(id)")
}

// MARK: - transcript 掃描

/// 一份 transcript 的掃描進度。transcript 是純附加的，所以記住讀到哪個 byte，
/// 下次只讀新增的部分 —— 不然每 2 秒重掃 100MB 是不可能的。
struct ScanState {
    var offset: UInt64 = 0
    var isSeeded = false
    var pending: Pending = .noSignal
    var ask: String = ""
    var recap: String = ""
    var choices: [Choice] = []
}

/// cwd → ~/.claude/projects 底下的目錄名。
/// 斜線和**點**都會變成破折號：`…/app/.claude/worktrees/x` → `…-app--claude-worktrees-x`
/// （兩個破折號，一個來自斜線一個來自點）。只換斜線的話 worktree 的 session 全部會找不到。
func projectSlug(_ cwd: String) -> String {
    cwd.replacingOccurrences(of: "/", with: "-")
       .replacingOccurrences(of: ".", with: "-")
}

func transcriptPath(sessionId: String, cwd: String) -> String? {
    let path = "\(projectsDirectory)/\(projectSlug(cwd))/\(sessionId).jsonl"
    return FileManager.default.fileExists(atPath: path) ? path : nil
}

private let newline = UInt8(0x0A)
private let wrapUpBytes = Array("wrap_up".utf8)
private let userTypeBytes = Array("\"type\":\"user\"".utf8)

/// 位元組搜尋。Data 的 slice 做子序列搜尋很慢（每個 byte 都走泛型 subscript），
/// 所以上游先整塊轉成 [UInt8]，這裡只做便宜的陣列索引。
func contains(_ hay: ArraySlice<UInt8>, _ needle: [UInt8]) -> Bool {
    guard !needle.isEmpty, hay.count >= needle.count else { return false }
    let first = needle[0]
    var i = hay.startIndex
    let last = hay.endIndex - needle.count
    while i <= last {
        if hay[i] == first {
            var j = 1
            while j < needle.count && hay[i + j] == needle[j] { j += 1 }
            if j == needle.count { return true }
        }
        i += 1
    }
    return false
}

func readBytes(path: String, from: UInt64, upTo: UInt64) -> [UInt8] {
    guard upTo > from, let handle = FileHandle(forReadingAtPath: path) else { return [] }
    defer { try? handle.close() }
    try? handle.seek(toOffset: from)
    guard let data = try? handle.read(upToCount: Int(upTo - from)) else { return [] }
    return [UInt8](data)
}

/// 這一則 type=user 的條目，是不是你本人送出的訊息；是的話回傳你寫的文字。
///
/// 依據是紀錄自己的 `origin.kind == "human"`。2026-10-28 掃 36 份紀錄才改成這樣 ——
/// 原本只認「content 是純字串、不是 meta」，兩個方向都錯：
///   - 漏掉：app 在你的訊息前面加一段系統提醒時，content 是「區塊清單」（提醒＋你的字）；
///     附圖片時也是清單。認不出你已經回覆 → 選項一直掛著 → 你再按一次 → 重複送出。
///   - 誤收：side-session 的通知、背景工作完成通知、對話壓縮後的接續摘要，都是 type=user 的純字串。
///     被當成你的回覆 → 還沒回答的問題被判成已回覆、從「需要你」消失。
/// 沒有 origin 欄位的舊紀錄才退回舊規則，並排除系統標籤開頭的訊息。
func yourMessage(_ obj: [String: Any]) -> String? {
    guard obj["type"] as? String == "user", obj["toolUseResult"] == nil,
          (obj["isMeta"] as? Bool ?? false) == false,
          let message = obj["message"] as? [String: Any] else { return nil }
    // 你寫的文字：純字串，或清單裡「不是系統標籤」的文字區塊（系統提醒是另一個區塊）
    func isSystemTag(_ t: String) -> Bool {
        t.hasPrefix("<system-reminder>") || t.hasPrefix("[Request interrupted")
    }
    var text: String
    var hasImage = false
    if let str = message["content"] as? String {
        text = str
    } else if let blocks = message["content"] as? [[String: Any]] {
        if blocks.contains(where: { $0["type"] as? String == "tool_result" }) { return nil }
        hasImage = blocks.contains { $0["type"] as? String == "image" }
        text = blocks.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }
                     .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                     .filter { !isSystemTag($0) }
                     .joined(separator: "\n")
    } else {
        return nil
    }
    text = text.trimmingCharacters(in: .whitespacesAndNewlines)
    if let origin = obj["origin"] as? [String: Any] {
        guard origin["kind"] as? String == "human" else { return nil }
        return text.isEmpty && hasImage ? "（圖片）" : text
    }
    // 舊紀錄：沒有 origin。只認純字串、而且不是系統標籤或壓縮後的接續摘要。
    guard message["content"] is String, !text.isEmpty,
          !text.hasPrefix("<"), !isSystemTag(text),
          !text.hasPrefix("This session is being continued") else { return nil }
    return text
}

/// 把一行摺進狀態。
func apply(_ line: ArraySlice<UInt8>, to state: inout ScanState) {
    let hasWrapUp = contains(line, wrapUpBytes)
    if !hasWrapUp && !contains(line, userTypeBytes) { return }
    guard let obj = (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any]
    else { return }

    if obj["type"] as? String == "user" {
        if yourMessage(obj) != nil {
            if state.pending == .needsReply || state.pending == .hasQuestion {
                state.pending = .settled      // 你回了，問題過期
                state.ask = ""
                state.recap = ""
                state.choices = []
            }
        }
        return
    }

    guard obj["type"] as? String == "assistant",
          let message = obj["message"] as? [String: Any],
          let blocks = message["content"] as? [[String: Any]]
    else { return }

    for block in blocks where block["type"] as? String == "tool_use" {
        guard (block["name"] as? String)?.contains("wrap_up") == true else { continue }
        let input = block["input"] as? [String: Any] ?? [:]
        let ask = (input["ask"] as? String) ?? ""
        // 回覆選項：沒有 action 欄位的才是「回一句話」；label 就是整句話時沒有 message。
        let offered: [Choice] = ((input["actions"] as? [[String: Any]]) ?? []).compactMap { a in
            guard a["action"] == nil, let label = a["label"] as? String, !label.isEmpty else { return nil }
            let message = (a["message"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? label
            return Choice(label: label, message: message)
        }
        state.choices = ask.isEmpty ? [] : offered   // 沒有問題就沒有要回答的選項
        if input["blocked"] as? Bool == true {
            state.pending = .needsReply          // 沒有你的答案就做不下去
            state.ask = ask
            // 說自己卡住、卻沒寫出要問什麼：至少留下那一輪的摘要，讓你知道它停在哪裡。
            // 只在沒有 ask 時才留 —— 有 ask 的話，問題本身比摘要有用。
            state.recap = ask.isEmpty ? ((input["recap"] as? String) ?? "") : ""
        } else if !ask.isEmpty {
            state.pending = .hasQuestion         // 問了，但沒說自己卡住
            state.ask = ask
            state.recap = ""
        } else {
            state.pending = .settled             // 什麼都沒問
            state.ask = ""
            state.recap = ""
        }
    }
}

/// 把 bytes 裡每一個完整的行摺進狀態。回傳吃掉的 byte 數（到最後一個換行為止）。
@discardableResult
func fold(_ bytes: [UInt8], into state: inout ScanState) -> Int {
    var cursor = bytes.startIndex
    var consumed = 0
    while let lineEnd = bytes[cursor...].firstIndex(of: newline) {
        apply(bytes[cursor..<lineEnd], to: &state)
        cursor = lineEnd + 1
        consumed = cursor
    }
    return consumed
}

/// 算出這份 transcript 現在是什麼狀態。
///
/// 第一次看到一份 transcript 時**不會**整份讀完 —— 答案只取決於「最後一個 wrap_up」
/// 以及「它之後有沒有你的訊息」，兩者都在檔案尾端。所以從尾端取一段往前加倍，
/// 直到那段裡出現 wrap_up 為止；整份都沒有才是真的 .noSignal。
/// 之後 transcript 只會被附加，所以記住讀到哪個 byte，往後都只讀新增的部分。
func scan(path: String, from state: ScanState) -> ScanState {
    guard let handle = FileHandle(forReadingAtPath: path) else { return state }
    let size = (try? handle.seekToEnd()) ?? 0
    try? handle.close()

    var result = state
    if result.offset > size { result = ScanState() }   // 檔案被截斷或換掉了

    if result.isSeeded {
        guard size > result.offset else { return result }
        let bytes = readBytes(path: path, from: result.offset, upTo: size)
        result.offset += UInt64(fold(bytes, into: &result))
        return result
    }

    var window: UInt64 = 1 << 20          // 先看最後 1MB
    while true {
        let rawStart = size > window ? size - window : 0
        var bytes = readBytes(path: path, from: rawStart, upTo: size)
        if rawStart > 0, let firstBreak = bytes.firstIndex(of: newline) {
            bytes = Array(bytes[(firstBreak + 1)...])   // 丟掉切到一半的那行
        }
        let reachedStart = rawStart == 0
        if contains(bytes[...], wrapUpBytes) || reachedStart {
            var fresh = ScanState()
            fold(bytes, into: &fresh)
            fresh.offset = size
            fresh.isSeeded = true
            return fresh
        }
        window *= 2
    }
}

// MARK: - 讀取 session 狀態

/// 程序還活著嗎。狀態檔不保證會被清掉，只信檔案內容的話，
/// 一個早就不存在的 session 會永遠顯示在清單上。
func isAlive(_ pid: Int32) -> Bool {
    if kill(pid, 0) == 0 { return true }
    return errno == EPERM   // 存在但不屬於我們
}

/// 掃描的快取，只在背景佇列上存取。
var scanCache: [String: ScanState] = [:]

func readSessions() -> [SessionRow] {
    let fm = FileManager.default
    guard let names = try? fm.contentsOfDirectory(atPath: sessionsDirectory) else { return [] }

    var rows: [SessionRow] = []
    for name in names where name.hasSuffix(".json") {
        guard let data = fm.contents(atPath: "\(sessionsDirectory)/\(name)"),
              let json = try? JSONSerialization.jsonObject(with: data),
              let obj = json as? [String: Any],
              let rawPid = obj["pid"] as? Int
        else { continue }

        let pid = Int32(rawPid)
        guard isAlive(pid) else { continue }
        let host = obj["hostSessionId"] as? String

        let status = obj["status"] as? String ?? "(沒有 status 欄位)"
        let stamp = (obj["statusUpdatedAt"] as? Double) ?? (obj["updatedAt"] as? Double) ?? 0
        let cwd = obj["cwd"] as? String ?? ""
        let sessionId = obj["sessionId"] as? String
        let title = (obj["name"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            ?? (cwd.isEmpty ? "session \(pid)" : (cwd as NSString).lastPathComponent)

        // transcript 只在閒著的時候才需要看 —— 正在跑的那些，答案就是「正在跑」。
        var pending = Pending.noSignal
        var ask = ""
        var recap = ""
        var choices: [Choice] = []
        if status != "busy", let sessionId, let path = transcriptPath(sessionId: sessionId, cwd: cwd) {
            let state = scan(path: path, from: scanCache[sessionId] ?? ScanState())
            scanCache[sessionId] = state
            pending = state.pending
            ask = state.ask
            recap = state.recap
            choices = state.choices
        }

        rows.append(SessionRow(
            pid: pid, key: host ?? "pid:\(pid)", sessionId: sessionId ?? "", isLoaded: true,
            title: title, cwd: cwd, status: status,
            since: Date(timeIntervalSince1970: stamp / 1000),
            kind: classify(status: status, pending: pending),
            ask: ask,
            recap: recap,
            choices: choices,
            link: sessionLink(host)))
    }
    return sortForDisplay(rows)
}

/// 顯示順序：需要你 → 執行中 → 閒置。
/// 「需要你」和「執行中」裡，等最久／跑最久的排前面 —— 等了二十小時的那個才是最該先處理的；
/// 「閒置」裡最近的排前面。
func sortForDisplay(_ rows: [SessionRow]) -> [SessionRow] {
    rows.sorted { a, b in
        let ga = group(a.kind), gb = group(b.kind)
        if ga != gb { return ga.rawValue < gb.rawValue }
        return ga == .idle ? a.since > b.since : a.since < b.since
    }
}

// MARK: - 記住未載入的 session

/// Claude Desktop 會結束閒置聊天的程序（例如闔上筆電過夜之後），等你打開才重新啟動；
/// 程序一結束，它的狀態檔也被清掉。於是一個還在等你回答的 session 會從清單上安靜地消失 ——
/// 看起來跟「沒有東西在等你」一模一樣。
///
/// 所以「需要你」區的 session 會被記下來。程序結束之後，它繼續顯示成「未載入」，
/// 直到它回來（你打開它）、它的對話紀錄顯示你已經回覆、紀錄不見了，或你叫它不要再顯示。
struct Remembered: Codable, Equatable {
    var key: String
    var sessionId: String
    var hostSessionId: String?
    var title: String
    var cwd: String
    var status: String
    var kind: Kind
    var ask: String
    var recap: String
    var since: Double   // ms since epoch，跟狀態檔一樣
    /// 後來才加的欄位，所以是 Optional：舊格式的記憶檔沒有它，非 Optional 的話整份會解不開、
    /// 所有記住的 session 會一起靜默消失。
    var choices: [Choice]?
}

/// 記憶存在哪裡。測試時用 LOOKOUT_MEMORY 指到別處，不碰真的那一份。
let memoryFile = ((ProcessInfo.processInfo.environment["LOOKOUT_MEMORY"]
                   ?? "~/Library/Application Support/Lookout/remembered.json") as NSString)
                  .expandingTildeInPath

// MARK: - 開關（給 Claude 裡的 /monitor 用）

/// 資料夾：跟記憶同一個（測試時跟著 LOOKOUT_MEMORY 走，不碰真的那一份）。
let stateDir = (memoryFile as NSString).deletingLastPathComponent

/// 開關狀態檔：`on` 或 `off`。Claude 裡的 mod（/monitor）讀它決定 session 開始時要不要把視窗打開。
/// 規則：打開＝on；你自己關掉視窗或按 ⌘Q＝off；關機、重新開機、登出不算你關的，維持 on —— 所以開機後一用 Claude 它就回來。
let switchFile = (stateDir as NSString).appendingPathComponent("switch")

func writeSwitch(_ on: Bool) {
    try? FileManager.default.createDirectory(atPath: stateDir, withIntermediateDirectories: true)
    try? (on ? "on\n" : "off\n").write(toFile: switchFile, atomically: true, encoding: .utf8)
}

/// 同時只跑一個：好幾個 Claude session 一起開始時，mod 可能各自叫它一次。
/// 用檔案鎖，不用「找有沒有同名的程序」—— 鎖跟著程序走，程序一結束（包括當掉）鎖就放掉，不會留下假的「已經在跑」。
/// 回傳 false 表示已經有一個在跑。
func claimSingleInstance() -> Bool {
    try? FileManager.default.createDirectory(atPath: stateDir, withIntermediateDirectories: true)
    let fd = open((stateDir as NSString).appendingPathComponent("instance.lock"), O_CREAT | O_RDWR, 0o644)
    guard fd >= 0 else { return true }          // 開不了鎖檔就照常跑，不要因為鎖讓視窗出不來
    guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { return false }   // fd 故意不關：程序活著鎖就在
    // 把自己的 pid 寫進鎖檔：Claude 裡的 mod 用它認出「就是這一個」，不用靠程序名稱猜
    // （用名稱 pkill 可能誤殺別的同名程式）。
    let pid = "\(getpid())\n"
    _ = ftruncate(fd, 0)
    _ = pid.withCString { write(fd, $0, strlen($0)) }
    return true
}

/// 只在背景佇列上存取。
var remembered: [String: Remembered] = {
    guard let data = FileManager.default.contents(atPath: memoryFile),
          let list = try? JSONDecoder().decode([Remembered].self, from: data) else { return [:] }
    return Dictionary(list.map { ($0.key, $0) }, uniquingKeysWith: { a, _ in a })
}()

func saveRemembered() {
    let list = remembered.values.sorted { $0.key < $1.key }
    guard let data = try? JSONEncoder().encode(list) else { return }
    let dir = (memoryFile as NSString).deletingLastPathComponent
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    try? data.write(to: URL(fileURLWithPath: memoryFile), options: .atomic)
}

/// 你在畫面上叫它不要再顯示（例如那個聊天已經封存了）。
func forget(_ key: String) {
    if remembered.removeValue(forKey: key) != nil { saveRemembered() }
}

/// 活著的 session，加上記得、但已經沒有程序的 session。
func withRemembered(_ live: [SessionRow]) -> [SessionRow] {
    var changed = false
    let liveKeys = Set(live.map(\.key))

    // 活著的：在「需要你」就記住（或更新），離開了就忘掉。
    // 只記 Desktop 開的 session —— 沒有連結的打不開，記了也只是佔位置。
    for row in live where row.link != nil {
        if group(row.kind) == .attention {
            let entry = Remembered(
                key: row.key, sessionId: row.sessionId,
                hostSessionId: row.key.hasPrefix("local_") ? row.key : nil,
                title: row.title, cwd: row.cwd, status: row.status, kind: row.kind,
                ask: row.ask, recap: row.recap, since: row.since.timeIntervalSince1970 * 1000,
                choices: row.choices)
            if remembered[row.key] != entry {
                remembered[row.key] = entry
                changed = true
            }
        } else if remembered.removeValue(forKey: row.key) != nil {
            changed = true
        }
    }

    // 不在了的：再讀一次它的對話紀錄，確認問題還沒被回答。
    var gone: [SessionRow] = []
    for (key, entry) in Array(remembered) where !liveKeys.contains(key) {
        guard !entry.sessionId.isEmpty,
              let path = transcriptPath(sessionId: entry.sessionId, cwd: entry.cwd) else {
            remembered[key] = nil   // 紀錄不見了（被刪了或搬走了），沒有東西可以打開
            changed = true
            continue
        }
        let state = scan(path: path, from: scanCache[entry.sessionId] ?? ScanState())
        scanCache[entry.sessionId] = state

        var kind = entry.kind, ask = entry.ask, recap = entry.recap, choices = entry.choices ?? []
        if entry.kind == .needsReply || entry.kind == .hasQuestion {
            switch state.pending {
            case .needsReply:  kind = .needsReply; ask = state.ask; recap = state.recap; choices = state.choices
            case .hasQuestion: kind = .hasQuestion; ask = state.ask; recap = ""; choices = state.choices
            case .settled, .noSignal:
                remembered[key] = nil   // 紀錄顯示你已經回覆了
                changed = true
                continue
            }
        }
        // atDialog／unknown 不靠紀錄改判：「卡在對話框」這件事 transcript 看不出來，
        // 留著程序結束前最後看到的樣子。

        gone.append(SessionRow(
            pid: 0, key: key, sessionId: entry.sessionId, isLoaded: false,
            title: entry.title, cwd: entry.cwd, status: entry.status,
            since: Date(timeIntervalSince1970: entry.since / 1000),
            kind: kind, ask: ask, recap: recap, choices: choices, link: sessionLink(entry.hostSessionId)))
    }

    if changed { saveRemembered() }
    return sortForDisplay(live + gone)
}

/// status + transcript 訊號 → 顯示分類。
///
/// 實測 status 只看到 busy / idle / waiting 三個值，完整集合沒有從原始碼確認過，
/// 所以沒見過的值歸 .unknown 並原字串顯示 —— 不要把未知值默默當成「跑完了」。
func classify(status: String, pending: Pending) -> Kind {
    switch status {
    case "busy":    return .working
    case "waiting": return .atDialog
    case "idle":
        switch pending {
        case .needsReply:  return .needsReply
        case .hasQuestion: return .hasQuestion
        case .settled:     return .settled
        case .noSignal:    return .noSignal
        }
    default: return .unknown
    }
}

// MARK: - 顯示用的文字

func symbol(_ kind: Kind) -> String {
    switch kind {
    case .working:     return "●"
    case .atDialog:    return "◐"
    case .needsReply:  return "◆"
    case .hasQuestion: return "◇"
    case .settled:     return "○"
    case .noSignal:    return "○"
    case .unknown:     return "?"
    }
}

func elapsed(since date: Date) -> String {
    let s = max(0, Int(Date().timeIntervalSince(date)))
    if s < 60 { return "\(s) 秒" }
    if s < 3600 { return "\(s / 60) 分" }
    if s < 86400 { return "\(s / 3600) 小時" }
    return "\(s / 86400) 天"
}

func folderName(_ cwd: String) -> String {
    cwd.isEmpty ? "" : (cwd as NSString).lastPathComponent
}

/// 一行純文字的描述。視窗不用它，留給沒有 UI 的量測腳本。
func detail(_ row: SessionRow) -> String {
    let folder = folderName(row.cwd)
    let when = elapsed(since: row.since)
    switch row.kind {
    case .working:     return "跑了 \(when) · \(folder)"
    case .atDialog:    return "卡在對話框 \(when) · \(folder)"
    case .needsReply:  return row.ask.isEmpty ? "等你回覆 \(when) · \(folder)" : row.ask
    case .hasQuestion: return row.ask.isEmpty ? "有問題待答 \(when)" : row.ask
    case .settled:     return "結案 \(when) · \(folder)"
    case .noSignal:    return "閒置 \(when)（無訊號）· \(folder)"
    case .unknown:     return "status=\(row.status) · \(folder)"
    }
}

func span(_ seconds: Int) -> String {
    if seconds < 60 { return "\(seconds) 秒" }
    if seconds < 3600 { return "\(seconds / 60) 分鐘" }
    if seconds < 86400 { return "\(seconds / 3600) 小時" }
    return "\(seconds / 86400) 天"
}

/// 「多久」：執行中寫跑了多久、在等你的寫等了多久、閒置的寫多久之前。
func whenText(_ row: SessionRow) -> String {
    let seconds = max(0, Int(Date().timeIntervalSince(row.since)))
    switch row.kind {
    case .working:  return "已執行 \(span(seconds))"
    case .atDialog, .needsReply, .hasQuestion, .unknown: return "已等 \(span(seconds))"
    default:        return seconds < 60 ? "剛剛" : "\(span(seconds))前"
    }
}

/// 列表列的 meta 行。Mono Sharp 的寫法：「main · 3 分鐘前」，用 · 分隔。
func noteText(_ row: SessionRow) -> String {
    let folder = folderName(row.cwd)
    return folder.isEmpty ? whenText(row) : "\(folder) · \(whenText(row))"
}

// MARK: - 狀態變化時

/// 某個 session 的分類剛剛變了的那一刻，要做什麼。
///
/// 視窗本身已經會變色排序了，所以什麼都不做也是個合理的答案。
/// 現在的做法：變成「需要你」的那一刻響一聲（見下面的 ChimePlayer）。
///
/// 手上的材料：row.kind（變成什麼）、from（變之前的分類）、row.title、row.ask
///
/// 四種轉場的輕重不一樣：
///   → .atDialog     做到一半被對話框擋住，它在空轉。最該吵你。
///   → .needsReply   跑完並且說沒有你的答案就做不下去，row.ask 就是問題本身。
///   → .hasQuestion  跑完並且問了你，但沒說自己卡住。要不要吵你是個判斷。
///   → .settled      跑完而且沒有東西等你。大概不需要吵你。
///   → .working      你剛送出 prompt。一定不需要吵你。
///
/// 2026-10-29 使用者的決定：**只有需要你的時候才出聲**，跑完了、開始跑都不出聲（「怕通知的聲音太多會很吵」）。
/// 所以只看「從外面進到『需要你』」這一刻：
///   - 卡在對話框 → 輕敲兩下（stuck）
///   - 等你回覆、有問題 → 往上一個音（attention）
/// 已經在「需要你」裡面換狀態（例如有問題 → 等你回覆）不再出聲：它本來就在等你。
/// 第一次讀到的 session 沒有「之前」，所以開 app 的那一刻不會一口氣響一串。
func onTransition(_ row: SessionRow, from: Kind) {
    guard group(row.kind) == .attention, group(from) != .attention, row.isLoaded else { return }
    ChimePlayer.shared.request(row.kind == .atDialog ? .stuck : .attention)
}

// MARK: - 提示音

/// 數字越大越要緊：同一次更新裡有好幾個 session 一起進來，只放最要緊的那一個。
enum Chime: Int, CaseIterable {
    case attention = 1, stuck = 2
    /// 低木琴（sounds/synth_soft.py 產生；試聽過四組柔和版之後選的）
    var file: String { self == .stuck ? "woodlow-urgent.wav" : "woodlow-attention.wav" }
}

final class ChimePlayer {
    static let shared = ChimePlayer()
    static let enabledKey = "chimeEnabled"

    /// 預設開著；選單「顯示 → 提示音」可以關掉，下次打開沿用。
    var isEnabled: Bool {
        get { UserDefaults.standard.object(forKey: Self.enabledKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: Self.enabledKey) }
    }

    /// 測試用：設了這個環境變數就用音量 0 播（走完整的播放路徑但聽不到），並把每一次播放印出來。
    private let dryRun = ProcessInfo.processInfo.environment["LOOKOUT_CHIME_DRYRUN"] != nil
    private var pending: Chime?
    private(set) var sounds: [Chime: NSSound] = [:]

    /// 音效檔放在執行檔旁邊的 sounds/ 裡。找不到要大聲說，不要默默變成沒有聲音。
    init() {
        let dir = (Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0]))
            .resolvingSymlinksInPath().deletingLastPathComponent().appendingPathComponent("sounds")
        for chime in Chime.allCases {
            let url = dir.appendingPathComponent(chime.file)
            if let sound = NSSound(contentsOf: url, byReference: true) { sounds[chime] = sound }
            else { FileHandle.standardError.write("提示音：讀不到 \(url.path)\n".data(using: .utf8)!) }
        }
        log("CHIME-LOADED \(sounds.count)/\(Chime.allCases.count)")
    }

    /// 同一輪更新裡的請求先收起來，下一個主執行緒循環只放一次（取最要緊的）。
    func request(_ chime: Chime) {
        guard isEnabled else { log("CHIME-MUTED \(chime)"); return }
        if pending == nil { DispatchQueue.main.async { [weak self] in self?.flush() } }
        if (pending?.rawValue ?? 0) < chime.rawValue { pending = chime }
    }

    private func flush() {
        guard let chime = pending else { return }
        pending = nil
        play(chime)
    }

    func play(_ chime: Chime) {
        guard let sound = sounds[chime] else { log("CHIME-MISSING \(chime)"); return }
        sound.stop()
        sound.volume = dryRun ? 0 : 1
        let started = sound.play()
        log("CHIME \(chime) started=\(started)")
    }

    private func log(_ line: String) {
        guard dryRun else { return }
        print(line); fflush(stdout)
    }
}

// MARK: - 字體大小

/// 內容區的縮放倍率。字級和間距 token 都乘上它，版面比例不會跑掉。
/// 標題列不縮放 —— 不然按一下放大，按鈕會從游標底下跑走。
let scaleKey = "uiScale"
let scaleRange: ClosedRange<CGFloat> = 0.8...1.6
let scaleStep: CGFloat = 0.1

var uiScale: CGFloat = {
    let saved = CGFloat(UserDefaults.standard.double(forKey: scaleKey))
    return saved == 0 ? 1 : min(max(saved, scaleRange.lowerBound), scaleRange.upperBound)
}()

/// 版面尺寸：token 值乘上倍率後取整，免得邊框落在半個像素上糊掉。
func px(_ size: CGFloat) -> CGFloat { (size * uiScale).rounded() }

// MARK: - Mono Sharp：顏色、字體、元件

/// 某個 token 色的透明版本，仍然跟著深色／淺色切換。
/// 不直接用 withAlphaComponent，是因為那不保證動態顏色在切換外觀後還會重新解析。
func tint(_ base: NSColor, _ alpha: CGFloat) -> NSColor {
    NSColor(name: nil) { appearance in
        var resolved = base
        appearance.performAsCurrentDrawingAppearance {
            resolved = NSColor(cgColor: base.cgColor) ?? base
        }
        return resolved.withAlphaComponent(alpha)
    }
}

private let installedFamilies = Set(NSFontManager.shared.availableFontFamilies)

/// 照 token 的字體順序找第一個裝了的。遇到 ui-sans-serif／system-ui 就是系統字 ——
/// 系統字碰到中文會自己退到 PingFang TC，正好是 token 寫的下一個順位。
func msFont(_ style: MSTypeStyle, weight: NSFont.Weight? = nil,
            tabular: Bool = false, scaled: Bool = true) -> NSFont {
    let size = scaled ? style.size * uiScale : style.size
    let w = weight ?? style.weight
    for family in MonoSharp.sansFamilies {
        if family == "ui-sans-serif" || family == "system-ui" { break }
        guard installedFamilies.contains(family) else { continue }
        var descriptor = NSFontDescriptor(fontAttributes: [
            .family: family,
            .traits: [NSFontDescriptor.TraitKey.weight: w.rawValue],
        ])
        if tabular {
            descriptor = descriptor.addingAttributes([.featureSettings: [[
                NSFontDescriptor.FeatureKey.typeIdentifier: kNumberSpacingType,
                NSFontDescriptor.FeatureKey.selectorIdentifier: kMonospacedNumbersSelector,
            ]]])
        }
        if let font = NSFont(descriptor: descriptor, size: size) { return font }
    }
    return tabular ? .monospacedDigitSystemFont(ofSize: size, weight: w)
                   : .systemFont(ofSize: size, weight: w)
}

/// 單行文字。
func label(_ text: String, _ style: MSTypeStyle, color: NSColor = MonoSharp.foreground,
           weight: NSFont.Weight? = nil, tabular: Bool = false, scaled: Bool = true) -> NSTextField {
    let field = NSTextField(labelWithString: text)
    field.font = msFont(style, weight: weight, tabular: tabular, scaled: scaled)
    field.textColor = color
    field.lineBreakMode = .byTruncatingTail
    field.translatesAutoresizingMaskIntoConstraints = false
    return field
}

/// 多行文字的斷行方式。Mono Sharp 規定標題 `text-wrap: balance`、段落 `text-wrap: pretty`，
/// 網頁一行 CSS 就有，AppKit 沒有 —— 所以這裡自己做（2026-10-28 文字稽核抓到 12 種孤字、3 種置中不平衡）。
enum WrapStyle {
    /// 每一行一樣長：找出「不增加行數」的最窄寬度。給置中的文字和標題。
    case balance
    /// 只處理孤字：最後一行太短時才稍微收窄，讓上一行分幾個字下來。給一般段落。
    case pretty
}

/// 用跟畫面同一套排版引擎量每一行（寬度、字數、這一行在原文的哪裡結束）。
/// NSTextField 的 cell 左右各留 2pt、不另加 lineFragmentPadding —— 稽核工具用同一個設定，
/// 和畫面實際行數對過 1170 段文字，只有 1 段不一致。
struct TextLine { let width: CGFloat; let chars: Int; let end: Int }
func measureLines(_ text: NSAttributedString, width: CGFloat) -> [TextLine] {
    let storage = NSTextStorage(attributedString: text)
    let manager = NSLayoutManager()
    let container = NSTextContainer(size: NSSize(width: width, height: .greatestFiniteMagnitude))
    container.lineFragmentPadding = 0
    manager.addTextContainer(container)
    storage.addLayoutManager(manager)
    manager.ensureLayout(for: container)
    var lines: [TextLine] = []
    manager.enumerateLineFragments(forGlyphRange: manager.glyphRange(for: container)) { _, used, _, glyphs, _ in
        let chars = manager.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
        let piece = (text.string as NSString).substring(with: chars)
            .replacingOccurrences(of: wordJoiner, with: "").trimmingCharacters(in: .whitespacesAndNewlines)
        lines.append(TextLine(width: used.width, chars: piece.count, end: NSMaxRange(chars)))
    }
    return lines
}

/// 最後一行算不算孤字：3 個字以內，或不到整段寬度的 1/4。（與稽核工具的判準相同）
func isOrphan(_ last: TextLine, of width: CGFloat) -> Bool {
    last.chars <= 3 || last.width < width * 0.25
}

/// U+2060 WORD JOINER：零寬、看不見，告訴排版引擎「這裡不要斷行」。
let wordJoiner = "\u{2060}"

/// 不拆詞：用系統的中文斷詞找出每個詞，在詞裡的漢字之間插入 word joiner，
/// 排版引擎每一行就只會斷在詞與詞之間（2026-10-28 截圖：「卡在」被拆成「卡｜在」；稽核：143 個斷點裡 43 個拆詞）。
/// 回傳處理後的字串，以及它的詞界（UTF-16 位移，已經算進插入的字元）。
func keepWords(_ text: NSAttributedString) -> (NSAttributedString, Set<Int>) {
    let plain = text.string as NSString
    let cf = text.string as CFString
    let tokenizer = CFStringTokenizerCreate(nil, cf, CFRangeMake(0, CFStringGetLength(cf)),
                                            kCFStringTokenizerUnitWordBoundary, Locale(identifier: "zh-Hant") as CFLocale)
    var tokens: [NSRange] = []
    while CFStringTokenizerAdvanceToNextToken(tokenizer) != [] {
        let r = CFStringTokenizerGetCurrentTokenRange(tokenizer)
        tokens.append(NSRange(location: r.location, length: r.length))
    }
    func isHan(_ unit: unichar) -> Bool { (0x3400...0x9FFF).contains(unit) || (0xF900...0xFAFF).contains(unit) }
    let out = NSMutableAttributedString(attributedString: text)
    var cuts: Set<Int> = []
    var shift = 0
    for token in tokens {
        cuts.insert(token.location + shift)
        // 只處理全是漢字的詞（英文單字本來就不會被拆）。
        let units = (0..<token.length).map { plain.character(at: token.location + $0) }
        if token.length >= 2, units.allSatisfy(isHan) {
            for i in 1..<token.length {
                let at = token.location + i + shift
                let attrs = out.attributes(at: at - 1, effectiveRange: nil)
                out.insert(NSAttributedString(string: wordJoiner, attributes: attrs), at: at)
                shift += 1
            }
        }
        cuts.insert(token.location + token.length + shift)
    }
    return (out, cuts)
}

/// 在寬度 `width` 裡，文字實際該用多窄。回傳的是要讓出來的寬度（0 = 不用動）。
func wrapSlack(_ text: NSAttributedString, width: CGFloat, style: WrapStyle, maxLines: Int, cuts: Set<Int>) -> CGFloat {
    let full = measureLines(text, width: width)
    let count = full.count
    // 一行放得下、或多到會被截斷（截斷的文字談不上平衡），就不動。
    guard count >= 2, maxLines <= 0 || count <= maxLines else { return 0 }
    if style == .pretty, let last = full.last, !isOrphan(last, of: width) { return 0 }

    // 二分搜尋「行數不變」的最窄寬度。行數只會隨寬度變窄而增加，所以可以二分。
    var lo = width / CGFloat(count) * 0.8, hi = width
    while hi - lo > 1 {
        let mid = (lo + hi) / 2
        if measureLines(text, width: mid).count > count { lo = mid } else { hi = mid }
    }
    let narrowest = ceil(hi) + 1   // 多留 1pt，避免剛好卡在換行邊界上
    func breaksBetweenWords(_ lines: [TextLine]) -> Bool { lines.dropLast().allSatisfy { cuts.contains($0.end) } }
    let step = max(2, width / 50)

    if style == .balance {
        // 從最窄往寬找：第一個「行數不變、而且每個斷點都在詞與詞之間」的寬度，就是不拆詞裡最平衡的。
        var w = narrowest
        while w < width {
            let lines = measureLines(text, width: w)
            if lines.count == count, breaksBetweenWords(lines) { return width - w }
            w += step
        }
        return breaksBetweenWords(full) ? 0 : max(0, width - narrowest)   // 怎麼都會拆詞，就只求平衡
    }

    // pretty：從原寬往內收，收到最後一行不再是孤字就停 —— 盡量少收，段落右緣才不會空一大塊。
    // 先找不拆詞的；找不到再放寬成只要不是孤字。
    for needWords in [true, false] {
        var w = width - step
        while w > narrowest {
            let lines = measureLines(text, width: w)
            if lines.count == count, let last = lines.last, !isOrphan(last, of: width),
               !needWords || breaksBetweenWords(lines) { return width - w }
            w -= step
        }
    }
    return max(0, width - narrowest)   // 怎麼收都還是孤字，就退成平衡
}

/// 會自己決定斷行的多行文字框。
/// 做法是改段落樣式的左右縮排，而不是改文字框的寬度：文字框照舊被約束撐滿，
/// 外面的版面一行都不用改；行數不變，所以高度也不變，不會引發版面重算的來回。
final class WrapField: NSTextField {
    var wrapStyle: WrapStyle = .pretty
    private var raw = NSAttributedString()
    private var fittedWidth: CGFloat = -1

    override var attributedStringValue: NSAttributedString {
        get { super.attributedStringValue }
        set {
            raw = newValue
            fittedWidth = -1
            super.attributedStringValue = newValue
            refit()
        }
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        refit()
    }

    /// 對外（輔助使用、複製）給原文，不帶插進去的 word joiner。
    override var stringValue: String {
        get { raw.length > 0 ? raw.string : super.stringValue }
        set { raw = NSAttributedString(); fittedWidth = -1; super.stringValue = newValue }
    }

    /// 寬度一律由外面的約束決定，不回報「內容要多寬」。
    /// 否則：平衡後內容變窄 → 框跟著變窄 → 用更窄的寬度再平衡一次 → 版面永遠收斂不了
    /// （2026-10-28 稽核用的測試版就是這樣在 layout 裡當掉的）。高度照舊由 super 依 preferredMaxLayoutWidth 算。
    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: super.intrinsicContentSize.height)
    }

    private func refit() {
        let width = bounds.width - 4          // cell 左右各留 2pt
        guard width > 20, raw.length > 0, abs(width - fittedWidth) > 0.5 else { return }
        fittedWidth = width
        // 不拆詞會讓某些字串多一行；多出來的那行可能就被行數上限截掉，所以那種情況寧可拆詞。
        var (base, cuts) = keepWords(raw)
        if cellHeight(base) > cellHeight(raw) + 0.5 {
            base = raw
            cuts = []   // 不保證詞界：pretty／balance 會退成只看寬度
        }
        var slack = wrapSlack(base, width: width, style: wrapStyle, maxLines: maximumNumberOfLines, cuts: cuts)
        // 量行數用的排版引擎和文字框自己算高度的方式，在換行邊界上會差 1、2pt
        // （稽核實測：空狀態的說明畫成 2 行、框卻撐成 3 行高）。所以最後由文字框自己的 cell 把關：
        // 收窄後如果變高了，就一點一點放寬，直到高度和不收窄時一樣。
        let original = cellHeight(base)
        while slack > 0, cellHeight(indented(base, slack)) > original + 0.5 { slack = max(0, slack - 2) }
        super.attributedStringValue = indented(base, slack)
    }

    private func indented(_ text: NSAttributedString, _ slack: CGFloat) -> NSAttributedString {
        let fitted = NSMutableAttributedString(attributedString: text)
        fitted.enumerateAttribute(.paragraphStyle, in: NSRange(location: 0, length: fitted.length)) { value, range, _ in
            guard let para = (value as? NSParagraphStyle)?.mutableCopy() as? NSMutableParagraphStyle else { return }
            // 置中的文字兩邊各讓一半，靠左的只讓右邊。
            let lead = para.alignment == .center ? floor(slack / 2) : 0
            para.firstLineHeadIndent = lead
            para.headIndent = lead
            para.tailIndent = -(slack - lead)
            fitted.addAttribute(.paragraphStyle, value: para, range: range)
        }
        return fitted
    }

    /// 這段文字放進這個文字框（同一個 cell 設定、同樣的寬度）會有多高。
    private func cellHeight(_ text: NSAttributedString) -> CGFloat {
        guard let probe = cell?.copy() as? NSCell else { return 0 }
        probe.attributedStringValue = text
        return probe.cellSize(forBounds: NSRect(x: 0, y: 0, width: bounds.width, height: 100_000)).height
    }
}

/// 多行段落，照 token 的行高排。
/// alignment 要寫進段落樣式裡：只設 field.alignment 會被這裡的段落樣式蓋掉（2026-10-28 空狀態的說明因此靠左）。
/// 斷行：置中的預設 balance，其他預設 pretty（見 WrapStyle）。
func paragraph(_ text: String, _ style: MSTypeStyle, color: NSColor = MonoSharp.foreground,
               maxLines: Int, alignment: NSTextAlignment = .natural, wrap: WrapStyle? = nil) -> NSTextField {
    let font = msFont(style)
    let lineHeight = font.pointSize * (style.lineHeight ?? 1.4)
    let para = NSMutableParagraphStyle()
    para.minimumLineHeight = lineHeight
    para.maximumLineHeight = lineHeight
    para.lineBreakMode = .byWordWrapping
    para.alignment = alignment
    let field = WrapField(wrappingLabelWithString: "")
    field.wrapStyle = wrap ?? (alignment == .center ? .balance : .pretty)
    field.maximumNumberOfLines = maxLines
    field.cell?.truncatesLastVisibleLine = true
    field.attributedStringValue = NSAttributedString(string: text, attributes: [
        .font: font, .foregroundColor: color, .paragraphStyle: para,
    ])
    field.translatesAutoresizingMaskIntoConstraints = false
    field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    return field
}

func setParagraph(_ field: NSTextField, _ text: String, _ style: MSTypeStyle, color: NSColor) {
    field.attributedStringValue = paragraph(text, style, color: color, maxLines: 1).attributedStringValue
}

func symbolImage(_ name: String, size: CGFloat, weight: NSFont.Weight = .regular) -> NSImage? {
    let config = NSImage.SymbolConfiguration(pointSize: size, weight: weight)
    return NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(config)
}

/// 線條圖示（Mono Sharp 指定 lucide；這裡用外形最接近的 SF Symbols 線條版代替）。
/// 顏色跟著文字走，不用填色或彩色圖示。
func icon(_ name: String, color: NSColor, size: CGFloat = 16) -> NSImageView {
    let view = NSImageView()
    // SF Symbols 的點數比 lucide 的像素框看起來大一號，13pt 約等於 16px 的 lucide。
    view.image = symbolImage(name, size: px(size * 0.8))
    view.contentTintColor = color
    // 放進固定大小的方框、在框裡置中。不這樣做的話，view 的大小跟著圖片本身走，
    // 而 SF Symbols 的圖片留白會隨字級變 —— 120% 時警告三角形因此比文字高了 1.25pt。
    view.imageScaling = .scaleProportionallyDown
    view.imageAlignment = .alignCenter
    view.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
        view.widthAnchor.constraint(equalToConstant: px(size)),
        view.heightAnchor.constraint(equalToConstant: px(size)),
    ])
    return view
}

/// 底色＋框線，跟著淺色／深色重新上色。全直角（Mono Sharp 的 radius 是 0）。
/// layer 的 CGColor 不會自己跟著外觀變，所以顏色在 updateLayer() 裡才解析。
class TintedView: NSView {
    var fill: NSColor = .clear { didSet { needsDisplay = true } }
    var stroke: NSColor = .clear { didSet { needsDisplay = true } }
    var strokeWidth: CGFloat = 0 { didSet { needsDisplay = true } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false
    }
    required init?(coder: NSCoder) { fatalError("不從 nib 載入") }

    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        layer?.backgroundColor = fill.cgColor
        layer?.borderColor = stroke.cgColor
        layer?.borderWidth = strokeWidth
        layer?.cornerRadius = MonoSharp.radius
    }
}

func divider() -> NSView {
    let line = TintedView()
    line.fill = MonoSharp.border
    line.heightAnchor.constraint(equalToConstant: 1).isActive = true
    return line
}

var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

/// icon 或小方塊跟旁邊的文字對齊時，一律用這個：對齊「第一行文字」的視覺中心 ——
/// 基線往上半個大寫字高。不要用外框置中或上緣對齊：文字的外框含行距（內文行高 1.625 倍時，
/// 多出來的行距有一半在字的上方），icon 會明顯偏高；多行文字時外框置中更會落到兩行之間。
func alignToFirstLine(_ view: NSView, of text: NSTextField, font: NSFont) -> NSLayoutConstraint {
    view.centerYAnchor.constraint(equalTo: text.firstBaselineAnchor, constant: -font.capHeight / 2)
}

// MARK: 狀態標籤（StatusBadge）

/// Mono Sharp 的五種狀態語氣。同一種狀態在每個地方都用同一個語氣。
enum Tone {
    case good, check, active, blocked, neutral
    /// 執行中。tokens.json 對 success 的定義是「Done/passed/live status」—— 正在跑就是 live。
    case live

    var color: NSColor {
        switch self {
        case .good, .live: return MonoSharp.success
        case .check:   return MonoSharp.warning
        case .active:  return MonoSharp.foreground
        case .blocked: return MonoSharp.destructive
        case .neutral: return MonoSharp.mutedForeground
        }
    }
}

/// 每個分類用哪個詞、哪個語氣。詞要一到四個字，顏色不能是唯一的訊號。
func status(_ kind: Kind) -> (word: String, tone: Tone) {
    switch kind {
    case .working:     return ("執行中", .live)
    case .atDialog:    return ("等你核准", .blocked)   // 做到一半被擋下 —— Mono Sharp 的 blocked
    case .needsReply:  return ("等你回覆", .check)
    case .hasQuestion: return ("有問題", .check)
    case .unknown:     return ("未知狀態", .check)
    case .settled:     return ("結案", .neutral)
    case .noSignal:    return ("無訊號", .neutral)
    }
}

/// 三件式：文字色、同色 10% 底、同色 40% 框（blocked 用 30% 框）；neutral 只有灰框。
final class StatusBadge: TintedView {
    init(word: String, tone: Tone, pulsing: Bool) {
        super.init(frame: .zero)
        let color = tone.color
        strokeWidth = 1
        switch tone {
        case .neutral:
            stroke = MonoSharp.border
        case .blocked:
            fill = tint(color, MonoSharp.toneFill)
            stroke = tint(color, 0.3)
        default:
            fill = tint(color, MonoSharp.toneFill)
            stroke = tint(color, MonoSharp.toneBorder)
        }

        let text = label(word, MonoSharp.control, color: color, weight: .regular)  // 狀態 badge 字重 400
        var parts: [NSView] = [text]
        if pulsing {
            // 執行中的那一顆前面放一個會脈動的小方塊（ambient 0.8s），眼角餘光就看得到。
            let dot = TintedView()
            dot.fill = color
            dot.widthAnchor.constraint(equalToConstant: px(6)).isActive = true
            dot.heightAnchor.constraint(equalToConstant: px(6)).isActive = true
            if !reduceMotion {
                let breathe = CABasicAnimation(keyPath: "opacity")
                breathe.fromValue = 1.0
                breathe.toValue = 0.25
                breathe.duration = 0.8
                breathe.autoreverses = true
                breathe.repeatCount = .infinity
                breathe.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                dot.layer?.add(breathe, forKey: "ambient")
            }
            parts.insert(dot, at: 0)
        }
        let stack = NSStackView(views: parts)
        stack.spacing = px(6)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .horizontal)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: px(20)),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: px(8)),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -px(8)),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }
    required init?(coder: NSCoder) { fatalError("不從 nib 載入") }
}

// MARK: 提示框（Notice）

/// 它在問你什麼。warning：同色 10% 底＋40% 框＋同色圖示；info：muted 50% 底＋border 框。
/// 文字一律 foreground、body 字級。
final class NoticeView: TintedView {
    private let text: NSTextField
    private var note: NSTextField?

    /// caption：放在內文上面的一行 meta，用來說明這段文字是什麼（例如「這是摘要，不是問題」）。
    /// maxLines：問題本身給 8 行（那是你要回答的東西，不該被切掉）；摘要給 4 行，全文在懸停卡片裡。
    init(text body: String, warning: Bool, caption: String? = nil, maxLines: Int = 8) {
        text = paragraph(body, MonoSharp.body, maxLines: maxLines)
        super.init(frame: .zero)
        strokeWidth = 1
        let mark: NSImageView
        if warning {
            fill = tint(MonoSharp.warning, MonoSharp.toneFill)
            stroke = tint(MonoSharp.warning, MonoSharp.toneBorder)
            mark = icon("exclamationmark.triangle", color: MonoSharp.warning)
        } else {
            fill = tint(MonoSharp.muted, 0.5)
            stroke = MonoSharp.border
            mark = icon("info.circle", color: MonoSharp.mutedForeground)
        }
        addSubview(mark)
        addSubview(text)
        var constraints = [
            mark.leadingAnchor.constraint(equalTo: leadingAnchor, constant: px(12)),
            text.leadingAnchor.constraint(equalTo: mark.trailingAnchor, constant: px(8)),
            text.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -px(12)),
            text.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -px(10)),
        ]
        if let caption {
            // 說明行在上、內文在下；圖示對齊說明行，因為那一行才是在告訴你「這是什麼」。
            // 這一行是在防你誤會（把摘要當成問題），所以窄視窗也不能被切掉 —— 改成可以換行。
            let note = paragraph(caption, MonoSharp.meta, color: MonoSharp.mutedForeground, maxLines: 4)
            self.note = note
            addSubview(note)
            constraints += [
                note.leadingAnchor.constraint(equalTo: text.leadingAnchor),
                note.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -px(12)),
                note.topAnchor.constraint(equalTo: topAnchor, constant: px(10)),
                alignToFirstLine(mark, of: note, font: msFont(MonoSharp.meta)),
                text.topAnchor.constraint(equalTo: note.bottomAnchor, constant: px(4)),
            ]
        } else {
            constraints += [
                // 原本是「對齊文字框上緣再往下 3pt」，實測 icon 比第一行高 8pt。
                alignToFirstLine(mark, of: text, font: msFont(MonoSharp.body)),
                text.topAnchor.constraint(equalTo: topAnchor, constant: px(10)),
            ]
        }
        NSLayoutConstraint.activate(constraints)
    }
    required init?(coder: NSCoder) { fatalError("不從 nib 載入") }

    /// 多行文字在 Auto Layout 下要知道自己多寬才算得出幾行高。
    override func layout() {
        super.layout()
        for field in [text, note].compactMap({ $0 }) {
            let width = field.frame.width
            if width > 0, field.preferredMaxLayoutWidth != width { field.preferredMaxLayoutWidth = width }
        }
    }
}

// MARK: 列表列（ListRow）

/// 「需要你」用完整的列（標題＋meta、狀態標籤、問題框）；
/// 「執行中」和「閒置」用一行的緊湊列 —— 區塊標題已經說了它是什麼狀態，不用每列再標一次。
enum RowStyle { case full, compact }

/// 緊湊列右邊那段：執行中寫跑了多久；閒置寫狀態詞和多久之前（狀態不能只靠顏色表達）。
/// short：列太窄時只留時間（狀態由列前面的色塊表示），把空間還給標題。
func compactNote(_ row: SessionRow, short: Bool = false) -> String {
    let seconds = max(0, Int(Date().timeIntervalSince(row.since)))
    if row.kind == .working { return span(seconds) }
    let ago = seconds < 60 ? "剛剛" : "\(span(seconds))前"
    return short ? ago : "\(status(row.kind).word) · \(ago)"
}

/// 狀態小方塊：每一列、每一格切換鈕、懸停卡片的狀態行前面都有一顆，顏色是那個狀態的語氣。
/// 呼應 logo 中心的方塊。執行中的那顆會脈動（ambient 0.8s）。
/// 顏色不是唯一的訊號 —— 旁邊一定有狀態詞或區塊名稱。
func statusSquare(_ color: NSColor, pulsing: Bool = false, size: CGFloat = 7) -> NSView {
    let dot = TintedView()
    dot.fill = color
    dot.widthAnchor.constraint(equalToConstant: px(size)).isActive = true
    dot.heightAnchor.constraint(equalToConstant: px(size)).isActive = true
    dot.setContentHuggingPriority(.required, for: .horizontal)
    if pulsing && !reduceMotion {
        let breathe = CABasicAnimation(keyPath: "opacity")
        breathe.fromValue = 1.0
        breathe.toValue = 0.25
        breathe.duration = 0.8
        breathe.autoreverses = true
        breathe.repeatCount = .infinity
        breathe.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        dot.layer?.add(breathe, forKey: "ambient")
    }
    return dot
}

/// 「未載入」的說明：1px 虛線框（Mono Sharp 的空狀態框），meta 字級。
final class DashedNote: NSView {
    private let dash = CAShapeLayer()
    private var body: NSTextField!

    init(_ text: String) {
        super.init(frame: .zero)
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false
        dash.fillColor = nil
        dash.lineWidth = 1
        dash.lineDashPattern = [4, 3]
        layer?.addSublayer(dash)
        let mark = icon("pause.circle", color: MonoSharp.mutedForeground)
        // 窄視窗、大字級時會被切掉（稽核：寬320·160%），改成可以換行。
        let body = paragraph(text, MonoSharp.meta, color: MonoSharp.mutedForeground, maxLines: 3)
        self.body = body
        addSubview(mark)
        addSubview(body)
        NSLayoutConstraint.activate([
            mark.leadingAnchor.constraint(equalTo: leadingAnchor, constant: px(10)),
            alignToFirstLine(mark, of: body, font: msFont(MonoSharp.meta)),
            body.leadingAnchor.constraint(equalTo: mark.trailingAnchor, constant: px(6)),
            body.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -px(10)),
            body.topAnchor.constraint(equalTo: topAnchor, constant: px(6)),
            body.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -px(6)),
        ])
    }
    required init?(coder: NSCoder) { fatalError("不從 nib 載入") }

    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() { dash.strokeColor = MonoSharp.border.cgColor }
    override func layout() {
        super.layout()
        dash.frame = bounds
        dash.path = CGPath(rect: bounds.insetBy(dx: 0.5, dy: 0.5), transform: nil)
        let width = body.frame.width
        if width > 0, body.preferredMaxLayoutWidth != width { body.preferredMaxLayoutWidth = width }
    }
}

/// 整列是一個連結。有連結的列點一下會在 Claude Desktop 打開那個 session。
final class RowView: TintedView {
    private(set) var row: SessionRow
    private let note: NSTextField
    /// 「需要你」那種列右邊的狀態標籤；太窄時收起來，把空間還給標題（見 layout()）。
    private var badge: NSView?
    private var badgeGap: NSLayoutConstraint?
    private var titleColumn: NSView?
    private var rightEdge: (() -> CGFloat)?
    /// 精簡列右邊那段時間怎麼放（見 fitCompactNote()）。
    private enum NoteMode { case full, short, below }
    private var noteMode = NoteMode.full
    private var noteIsShort: Bool { noteMode == .short }
    private var inlineNote: [NSLayoutConstraint] = []
    private var belowNote: [NSLayoutConstraint] = []
    private var chevronTrailing: NSLayoutConstraint?
    private var isHovering = false { didSet { refreshFill(); nudgeChevron() } }
    private var isPressed = false { didSet { refreshFill() } }
    private var isClickable: Bool { row.link != nil }
    /// 未載入的列按右鍵可以「不再顯示」；由視窗接手處理（要在背景佇列上改記憶）。
    var onForget: ((String) -> Void)?

    init(row: SessionRow, style: RowStyle) {
        self.row = row
        note = label("", MonoSharp.meta, color: MonoSharp.mutedForeground, tabular: true)
        // 從中間截斷：窄的時候犧牲資料夾名稱，保住尾端的時間。
        note.lineBreakMode = .byTruncatingMiddle
        super.init(frame: .zero)
        switch style {
        case .full:    buildFull()
        case .compact: buildCompact()
        }
        addTrackingArea(NSTrackingArea(
            rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self, userInfo: nil))
        update(row)
    }
    required init?(coder: NSCoder) { fatalError("不從 nib 載入") }

    private var style: RowStyle { group(row.kind) == .attention ? .full : .compact }

    /// 每 2 秒只更新時間，不重建 —— 重建會把脈動動畫和 hover 狀態一起清掉。
    func update(_ new: SessionRow) {
        row = new
        note.stringValue = style == .full ? noteText(new) : compactNote(new, short: noteIsShort)
        // 完整內容不放在系統的 toolTip：那個只在 app 是作用中時才出現。改用 HoverCard。
    }

    /// 標題至少要留這麼寬；不夠就收起右邊的狀態標籤。
    /// 狀態沒有遺失：列前面的色塊、所在的分頁、懸停卡片都還寫著。
    /// 判斷只看「列有多寬」，不看標籤現在顯示與否，所以不會在兩種狀態之間來回跳。
    /// （稽核：寬 320、字級 160% 時，標題被擠到只剩 14pt。）
    override func layout() {
        super.layout()
        if style == .compact { fitCompactNote(); return }
        guard let badge, let badgeGap, let titleColumn, let rightEdge else { return }
        let roomWithoutBadge = rightEdge() - titleColumn.frame.minX
        let badgeCost = badge.fittingSize.width + px(12) - px(10)
        let show = roomWithoutBadge - badgeCost >= px(120)
        if badge.isHidden == show {
            badge.isHidden = !show
            badgeGap.isActive = show
            needsLayout = true
        }
    }

    /// 精簡列的同一件事，分三級：標題能留 120pt 就整句放右邊（「已結案 · 3 天前」）→
    /// 不行就只留時間（「3 天前」，狀態看色塊）→ 還是不行就把時間移到標題下面一行（整句）。
    /// 用字串本身的寬度和列寬判斷，不看目前怎麼擺，所以不會因為切換本身而來回跳。
    /// （稽核：寬 320、字級 160% 時，標題原本被擠到 2pt；第一版保底改成擠掉時間，也不對。）
    private func fitCompactNote() {
        guard let titleColumn, let rightEdge, let font = note.font else { return }
        func width(_ text: String) -> CGFloat { (text as NSString).size(withAttributes: [.font: font]).width + 4 }
        let room = rightEdge() - titleColumn.frame.minX - px(12)
        let mode: NoteMode
        if room - width(compactNote(row)) >= px(120) { mode = .full }
        else if room - width(compactNote(row, short: true)) >= px(120) { mode = .short }
        else { mode = .below }
        guard mode != noteMode else { return }
        noteMode = mode
        NSLayoutConstraint.deactivate(mode == .below ? inlineNote : belowNote)
        NSLayoutConstraint.activate(mode == .below ? belowNote : inlineNote)
        update(row)
        needsLayout = true
    }

    // MARK: 版面

    private func chevronIfClickable(alignedTo anchor: NSLayoutYAxisAnchor) -> NSView? {
        guard isClickable else { return nil }
        let chevron = icon("chevron.right", color: MonoSharp.mutedForeground)
        addSubview(chevron)
        let trailing = chevron.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -px(MonoSharp.padSection))
        chevronTrailing = trailing
        NSLayoutConstraint.activate([trailing, chevron.centerYAnchor.constraint(equalTo: anchor)])
        return chevron
    }

    private func buildFull() {
        let title = label(row.title, MonoSharp.bodyMedium)
        for field in [title, note] {
            field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        }
        let main = NSStackView(views: [title, note])
        main.orientation = .vertical
        main.alignment = .leading
        main.spacing = px(2)
        main.translatesAutoresizingMaskIntoConstraints = false

        let (word, tone) = status(row.kind)
        let badge = StatusBadge(word: word, tone: tone, pulsing: false)
        let dot = statusSquare(tone.color)
        addSubview(dot)
        addSubview(main)
        addSubview(badge)

        let pad = px(MonoSharp.padSection)
        var constraints = [
            dot.leadingAnchor.constraint(equalTo: leadingAnchor, constant: pad),
            alignToFirstLine(dot, of: title, font: msFont(MonoSharp.bodyMedium)),
            main.leadingAnchor.constraint(equalTo: dot.trailingAnchor, constant: px(10)),
            main.topAnchor.constraint(equalTo: topAnchor, constant: px(MonoSharp.padRowY)),
            badge.centerYAnchor.constraint(equalTo: main.centerYAnchor),
        ]
        let gap = main.trailingAnchor.constraint(lessThanOrEqualTo: badge.leadingAnchor, constant: -px(12))
        constraints.append(gap)
        self.badge = badge
        badgeGap = gap
        titleColumn = main
        if let chevron = chevronIfClickable(alignedTo: main.centerYAnchor) {
            constraints.append(badge.trailingAnchor.constraint(equalTo: chevron.leadingAnchor, constant: -px(10)))
            // 標籤收起來的時候，標題最多延伸到箭頭前面。
            constraints.append(main.trailingAnchor.constraint(lessThanOrEqualTo: chevron.leadingAnchor, constant: -px(10)))
            rightEdge = { [weak chevron] in (chevron?.frame.minX ?? 0) - px(10) }
        } else {
            constraints.append(badge.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -pad))
            constraints.append(main.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -pad))
            rightEdge = { [weak self] in (self?.bounds.width ?? 0) - pad }
        }

        // 主列底下依序疊：未載入的說明、問題（或摘要）框。
        var extras: [NSView] = []
        if !row.isLoaded {
            // 只放最要緊的一句；「程序已結束、這是最後狀態」的完整說明在滑鼠停留的提示裡。
            extras.append(DashedNote("未載入 · 打開它才會更新"))
        }
        if !row.ask.isEmpty && (row.kind == .needsReply || row.kind == .hasQuestion) {
            extras.append(NoticeView(text: row.ask, warning: row.kind == .needsReply))
        } else if row.kind == .needsReply && !row.recap.isEmpty {
            // 說自己卡住卻沒寫出問題：顯示那一輪的摘要，並且明講它不是問題。
            extras.append(NoticeView(text: row.recap, warning: true,
                                     caption: "這是摘要，不是問題 · 它沒有寫出要問你什麼", maxLines: 4))
        }
        var bottom: NSView = main
        for extra in extras {
            addSubview(extra)
            constraints += [
                extra.topAnchor.constraint(equalTo: bottom.bottomAnchor, constant: px(10)),
                extra.leadingAnchor.constraint(equalTo: main.leadingAnchor),
                extra.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -pad),
            ]
            bottom = extra
        }
        constraints.append(bottom.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -px(MonoSharp.padRowY)))
        NSLayoutConstraint.activate(constraints)
    }

    private func buildCompact() {
        let running = row.kind == .working
        let title = label(row.title, MonoSharp.body,
                          color: running ? MonoSharp.foreground : MonoSharp.mutedForeground)
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        note.setContentHuggingPriority(.required, for: .horizontal)
        note.setContentCompressionResistancePriority(.init(rawValue: 260), for: .horizontal)
        addSubview(title)
        addSubview(note)

        let pad = px(MonoSharp.padSection)
        var constraints = [
            title.topAnchor.constraint(equalTo: topAnchor, constant: px(MonoSharp.padRowY)),
        ]
        // 時間在右邊（同一行）
        inlineNote = [
            title.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -px(MonoSharp.padRowY)),
            title.trailingAnchor.constraint(lessThanOrEqualTo: note.leadingAnchor, constant: -px(12)),
            note.firstBaselineAnchor.constraint(equalTo: title.firstBaselineAnchor),
        ]
        // 時間在標題下面一行（太窄時）
        belowNote = [
            note.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            note.topAnchor.constraint(equalTo: title.bottomAnchor, constant: px(2)),
            note.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -px(MonoSharp.padRowY)),
        ]
        // 每一列都有狀態小方塊，三個 tab 的列才會排在同一條對齊線上。
        let dot = statusSquare(status(row.kind).tone.color, pulsing: running)
        addSubview(dot)
        constraints += [
            dot.leadingAnchor.constraint(equalTo: leadingAnchor, constant: pad),
            alignToFirstLine(dot, of: title, font: msFont(MonoSharp.body)),
            title.leadingAnchor.constraint(equalTo: dot.trailingAnchor, constant: px(10)),
        ]
        let right: NSLayoutXAxisAnchor, inset: CGFloat
        if let chevron = chevronIfClickable(alignedTo: title.centerYAnchor) {
            right = chevron.leadingAnchor; inset = px(10)
            rightEdge = { [weak chevron] in (chevron?.frame.minX ?? 0) - px(10) }
        } else {
            right = trailingAnchor; inset = pad
            rightEdge = { [weak self] in (self?.bounds.width ?? 0) - pad }
        }
        inlineNote.append(note.trailingAnchor.constraint(equalTo: right, constant: -inset))
        belowNote.append(note.trailingAnchor.constraint(lessThanOrEqualTo: right, constant: -inset))
        // 不論時間放哪，標題都不能超過右緣。
        constraints.append(title.trailingAnchor.constraint(lessThanOrEqualTo: right, constant: -inset))
        titleColumn = title
        NSLayoutConstraint.activate(constraints + inlineNote)
    }

    // MARK: 點擊

    /// 整列吃下範圍內所有的點擊，點在文字上也算點到這一列。
    override func hitTest(_ point: NSPoint) -> NSView? {
        super.hitTest(point) == nil ? nil : self
    }
    /// 視窗沒有焦點時，第一下點擊就要算數，不要只拿來喚醒視窗。
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        HoverCard.shared.hide()
        guard isClickable else { return super.mouseDown(with: event) }
        isPressed = true
    }

    override func mouseUp(with event: NSEvent) {
        guard isClickable, isPressed else { return super.mouseUp(with: event) }
        isPressed = false
        // 按下之後把滑鼠移出這一列再放開，等於取消 —— 跟一般按鈕一樣。
        let point = convert(event.locationInWindow, from: nil)
        if bounds.contains(point), let link = row.link {
            NSWorkspace.shared.open(link)
        }
    }

    /// 未載入的列：右鍵「不再顯示」。例如那個聊天你已經封存了，它不會再回來。
    override func menu(for event: NSEvent) -> NSMenu? {
        guard !row.isLoaded else { return nil }
        let menu = NSMenu()
        let item = menu.addItem(withTitle: "不再顯示這個 session", action: #selector(forgetThis), keyEquivalent: "")
        item.target = self
        return menu
    }

    @objc private func forgetThis() { onForget?(row.key) }

    override func mouseEntered(with event: NSEvent) {
        HoverCard.shared.schedule(row, under: self)
        guard isClickable else { return }
        isHovering = true
        NSCursor.pointingHand.set()
    }

    override func mouseExited(with event: NSEvent) {
        // 不馬上收：給你一點時間把滑鼠移進卡片（卡片上可能有選項要按）。
        HoverCard.shared.scheduleHide(after: 0.3)
        isHovering = false
        isPressed = false
        NSCursor.arrow.set()
    }

    /// hover 填 muted 60%；按下時填滿。
    private func refreshFill() {
        fill = isPressed ? MonoSharp.muted : (isHovering ? tint(MonoSharp.muted, 0.6) : .clear)
    }

    /// hover 時箭頭右移 2px（snap 0.15s）。
    private func nudgeChevron() {
        guard let trailing = chevronTrailing else { return }
        let target = -px(MonoSharp.padSection) + (isHovering ? 2 : 0)
        if reduceMotion { trailing.constant = target; return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15
            context.allowsImplicitAnimation = true
            trailing.animator().constant = target
        }
    }
}

// MARK: 自動送出

/// 按下卡片上的選項後，替你把那句話送進那個聊天。
///
/// 從外面沒有正式的「送訊息進某個聊天」介面（2026-10-28 查過 Claude Desktop 原始碼：打開既有 session
/// 的網址不帶預填參數；session 之間的訊息通道會被當成另一個 session 說的話）。所以這裡是模擬你本人
/// 操作：打開聊天、貼上、按 Enter。模擬操作最怕送錯地方，所以 Enter 之前每一關都要過：
///
///   1. Claude 網頁區塊的網址裡出現目標 session 的 id —— 打開的確實是那個聊天
///   2. 那個聊天的輸入框是空的 —— 不會把你打到一半的草稿一起送出去
///   3. 焦點確實在那個輸入框上 —— 不然 Enter 可能按到頁面上 105 個按鈕的其中一個
///   4. 貼上後輸入框裡的字跟要送的那句完全一樣
///
/// 按鍵用 postToPid 只送給 Claude，不送給「目前最前面的 app」：你那一刻切走了，按鍵也不會跑去別處。
/// 任何一關沒過就不按 Enter，結果與原因用系統通知告訴你（那時 Claude 多半蓋在這個視窗上面）。
/// 送完再讀那個 session 的對話紀錄，看到那句話才算「已送達」。
///
/// 需要「輔助使用」權限：讀 Claude 的畫面結構、移動焦點、送按鍵都要。
final class AutoSender {
    static let shared = AutoSender()
    private let queue = DispatchQueue(label: "auto-send")
    private let claudeBundle = "com.anthropic.claudefordesktop"

    enum Outcome {
        case delivered                  // 對話紀錄裡看到了
        case sentUnconfirmed            // 按了 Enter，但一段時間內沒在紀錄裡看到
        case stopped(String, String, nothingSent: Bool)   // 哪一關沒過、現在那句話在哪裡、是否確定沒送出
    }

    private func attr(_ e: AXUIElement, _ a: String) -> CFTypeRef? {
        var v: CFTypeRef?
        return AXUIElementCopyAttributeValue(e, a as CFString, &v) == .success ? v : nil
    }

    /// 找 URL 裡有這個 session id 的網頁區塊。
    private func sessionWebArea(_ app: AXUIElement, key: String) -> AXUIElement? {
        var found: AXUIElement?
        var visited = 0
        func walk(_ e: AXUIElement, _ d: Int) {
            visited += 1
            if found != nil || visited > 3000 || d > 20 { return }
            if (attr(e, kAXRoleAttribute) as? String) == "AXWebArea",
               let u = attr(e, "AXURL"), "\(u)".contains("/epitaxy/\(key)") { found = e; return }
            for c in (attr(e, kAXChildrenAttribute) as? [AXUIElement]) ?? [] { walk(c, d + 1) }
        }
        walk(app, 0)
        return found
    }

    /// 網頁區塊裡唯一的文字輸入區就是對話的輸入框。不是剛好一個就不猜。
    private func composer(in web: AXUIElement) -> AXUIElement? {
        var areas: [AXUIElement] = []
        var visited = 0
        func walk(_ e: AXUIElement, _ d: Int) {
            visited += 1
            if visited > 20000 || d > 60 { return }
            if (attr(e, kAXRoleAttribute) as? String) == "AXTextArea" { areas.append(e) }
            for c in (attr(e, kAXChildrenAttribute) as? [AXUIElement]) ?? [] { walk(c, d + 1) }
        }
        walk(web, 0)
        return areas.count == 1 ? areas[0] : nil
    }

    private func value(_ e: AXUIElement) -> String {
        ((attr(e, kAXValueAttribute) as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func key(_ code: Int, _ flags: CGEventFlags = [], to pid: pid_t) {
        let source = CGEventSource(stateID: .hidSystemState)
        for down in [true, false] {
            let e = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(code), keyDown: down)
            e?.flags = flags
            e?.postToPid(pid)
        }
    }

    /// 存下剪貼簿的全部內容（每一種格式），送完再放回去。
    private func snapshotPasteboard() -> [[NSPasteboard.PasteboardType: Data]] {
        (NSPasteboard.general.pasteboardItems ?? []).map { item in
            var out: [NSPasteboard.PasteboardType: Data] = [:]
            for t in item.types { if let d = item.data(forType: t) { out[t] = d } }
            return out
        }
    }
    private func restorePasteboard(_ items: [[NSPasteboard.PasteboardType: Data]]) {
        let board = NSPasteboard.general
        board.clearContents()
        board.writeObjects(items.map { dict in
            let item = NSPasteboardItem()
            for (t, d) in dict { item.setData(d, forType: t) }
            return item
        })
    }

    /// 在主執行緒上做；已經在主執行緒就直接做 —— 在主執行緒上呼叫 main.sync 會自己等自己、整個卡死。
    private func onMain(_ work: () -> Void) {
        if Thread.isMainThread { work() } else { DispatchQueue.main.sync(execute: work) }
    }

    private func wait(_ seconds: Double, every step: Double = 0.1, until ok: () -> Bool) -> Bool {
        var t = 0.0
        while t < seconds {
            if ok() { return true }
            Thread.sleep(forTimeInterval: step); t += step
        }
        return ok()
    }

    func send(_ text: String, to row: SessionRow, finish: @escaping (Outcome) -> Void) {
        let done = { (o: Outcome) in DispatchQueue.main.async { finish(o) } }
        guard let link = row.link, row.key.hasPrefix("local_") else {
            return done(.stopped("這個 session 沒有連結", "沒有送出", nothingSent: true))
        }
        let trusted = AXIsProcessTrustedWithOptions(
            [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
        let saved = snapshotPasteboard()
        func copyOnly(_ why: String) -> Outcome {
            onMain {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
            }
            return .stopped(why, "已複製，請在 Claude 按 ⌘V 再按 Enter", nothingSent: true)
        }
        guard trusted else {
            NSWorkspace.shared.open(link)
            return done(copyOnly("還沒有「輔助使用」權限（系統設定 → 隱私權與安全性 → 輔助使用）"))
        }
        let offset = transcriptSize(row)
        NSWorkspace.shared.open(link)

        queue.async { [self] in
            guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: claudeBundle).first else {
                return done(copyOnly("找不到 Claude"))
            }
            let pid = app.processIdentifier
            let ax = AXUIElementCreateApplication(pid)

            // 1. 打開的確實是那個聊天
            var web: AXUIElement?
            guard wait(8, every: 0.2, until: { web = sessionWebArea(ax, key: row.key); return web != nil }),
                  let web else { return done(copyOnly("等了 8 秒，Claude 顯示的不是這個聊天")) }
            // 2. 輸入框是空的
            var box: AXUIElement?
            guard wait(3, every: 0.2, until: { box = composer(in: web); return box != nil }),
                  let box else { return done(copyOnly("在那個聊天裡找不到唯一的輸入框")) }
            guard value(box).isEmpty else {
                return done(copyOnly("那個聊天的輸入框裡已經有字（可能是你的草稿），為了不一起送出，沒有自動送"))
            }
            // 3. 焦點在輸入框上
            AXUIElementSetAttributeValue(box, kAXFocusedAttribute as CFString, kCFBooleanTrue)
            guard wait(1.5, until: {
                guard let f = attr(ax, kAXFocusedUIElementAttribute) else { return false }
                return CFEqual(f, box)
            }) else { return done(copyOnly("沒辦法把焦點移到輸入框")) }
            // 4. 貼上，確認字一模一樣
            onMain {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
            }
            key(kVK_ANSI_V, .maskCommand, to: pid)
            let target = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard wait(2, until: { value(box) == target }) else {
                onMain { restorePasteboard(saved) }
                return done(.stopped("貼上後輸入框的字跟要送的那句不一樣", "沒有按送出；請到 Claude 檢查輸入框",
                                     nothingSent: false))
            }
            // 送出前最後再確認一次：還是那個聊天、焦點還在輸入框
            guard sessionWebArea(ax, key: row.key) != nil,
                  let f = attr(ax, kAXFocusedUIElementAttribute), CFEqual(f, box) else {
                onMain { restorePasteboard(saved) }
                return done(.stopped("貼上之後畫面變了", "沒有按送出；那句話在輸入框裡，請確認後自己按 Enter",
                                     nothingSent: false))
            }
            key(kVK_Return, to: pid)
            Thread.sleep(forTimeInterval: 0.4)
            onMain { restorePasteboard(saved) }

            // 送達確認：那個 session 的對話紀錄裡出現這句話
            let seen = wait(15, every: 0.5, until: { transcriptHasUserMessage(row, text: target, after: offset) })
            done(seen ? .delivered : .sentUnconfirmed)
        }
    }
}

/// 送出前記下對話紀錄的大小，送達確認只看之後新增的部分。
func transcriptSize(_ row: SessionRow) -> UInt64 {
    guard !row.sessionId.isEmpty, let path = transcriptPath(sessionId: row.sessionId, cwd: row.cwd),
          let size = (try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? UInt64 else { return 0 }
    return size
}

/// 對話紀錄在 offset 之後有沒有一則你送出的訊息、內容就是這句話。
func transcriptHasUserMessage(_ row: SessionRow, text: String, after offset: UInt64) -> Bool {
    guard !row.sessionId.isEmpty, let path = transcriptPath(sessionId: row.sessionId, cwd: row.cwd) else { return false }
    let size = transcriptSize(row)
    guard size > offset else { return false }
    for line in readBytes(path: path, from: offset, upTo: size).split(separator: newline) {
        guard let obj = (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any],
              let said = yourMessage(obj) else { continue }
        // 系統提醒是另一個區塊，yourMessage 已經拿掉了；比對的是你寫的那部分。
        if said == text { return true }
    }
    return false
}

// MARK: 懸停卡片

/// 卡片上的回覆按鈕。Mono Sharp 的按鈕：直角、control 字級（12px／500）、高 28px、左右 10px；
/// 主要按鈕（實心 primary，一頁只有一個）給 session 建議的那個選項，其他是外框按鈕。
/// hover：主要按鈕降到 80%，外框按鈕填 muted；按下：往下 1px。
final class ChoiceButton: TintedView {
    let choice: Choice
    private let isPrimary: Bool
    private let text: NSTextField
    private var textTop: NSLayoutConstraint!
    var onHover: ((Choice?) -> Void)?
    var onPick: ((Choice) -> Void)?
    private var isHovering = false { didSet { refresh() } }
    /// 停用時半透明（Mono Sharp 的 disabled 透明度）、按了沒反應。
    var isEnabled = true { didSet { alphaValue = isEnabled ? 1 : MonoSharp.disabled; isHovering = false } }

    init(_ choice: Choice, primary: Bool) {
        self.choice = choice
        isPrimary = primary
        text = label(choice.label, MonoSharp.control,
                     color: primary ? MonoSharp.primaryForeground : MonoSharp.foreground)
        super.init(frame: .zero)
        strokeWidth = primary ? 0 : 1
        stroke = MonoSharp.input
        addSubview(text)
        textTop = text.centerYAnchor.constraint(equalTo: centerYAnchor)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: px(MonoSharp.controlSm)),
            text.leadingAnchor.constraint(equalTo: leadingAnchor, constant: px(MonoSharp.padControlX)),
            text.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -px(MonoSharp.padControlX)),
            textTop,
        ])
        addTrackingArea(NSTrackingArea(
            rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self, userInfo: nil))
        refresh()
    }
    required init?(coder: NSCoder) { fatalError("不從 nib 載入") }

    private func refresh() {
        if isPrimary {
            fill = isHovering ? tint(MonoSharp.primary, MonoSharp.primaryHover) : MonoSharp.primary
        } else {
            fill = isHovering ? MonoSharp.muted : .clear
        }
    }

    override func hitTest(_ point: NSPoint) -> NSView? { super.hitTest(point) == nil ? nil : self }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseEntered(with event: NSEvent) { guard isEnabled else { return }; isHovering = true; onHover?(choice) }
    override func mouseExited(with event: NSEvent) { isHovering = false; onHover?(nil); textTop.constant = 0 }
    override func mouseDown(with event: NSEvent) { if isEnabled { textTop.constant = 1 } }   // 按下：往下 1px
    override func mouseUp(with event: NSEvent) {
        textTop.constant = 0
        guard isEnabled else { return }
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onPick?(choice) }
    }
}

/// 卡片本身。滑鼠在卡片裡時不收起來；離開卡片才收。
final class CardView: TintedView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        addTrackingArea(NSTrackingArea(
            rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self, userInfo: nil))
    }
    required init?(coder: NSCoder) { fatalError("不從 nib 載入") }
    override func mouseEntered(with event: NSEvent) { HoverCard.shared.cancelHide() }
    override func mouseExited(with event: NSEvent) { HoverCard.shared.scheduleHide(after: 0.2) }
}

/// 滑鼠停在某一列上一下子，就在那一列下方浮出完整的內容：完整標題、路徑、狀態、問題或摘要。
/// session 有給回覆選項的話，卡片上也有按鈕。
///
/// 不用系統的 toolTip：它只在 app 是作用中時才會出現，而這個視窗大部分時候放在旁邊、
/// 沒有焦點（它啟動時也刻意不搶焦點）—— 所以那個提示其實一直都在，只是你幾乎看不到。
/// 這張卡片是附在主視窗上的子視窗，不管有沒有焦點都會出現。
///
/// 收起的時機：滑鼠離開那一列後等 0.3 秒；這段時間移進卡片就不收，離開卡片才收。
/// 不然卡片上的按鈕永遠按不到 —— 滑鼠一離開列，卡片就不見了。
final class HoverCard {
    static let shared = HoverCard()
    private var panel: NSPanel?
    private var showing: String?             // 目前顯示的是哪一列（row.key）
    private var pendingShow: DispatchWorkItem?
    private var pendingHide: DispatchWorkItem?
    private var preview: NSTextField?        // 按鈕底下那一行：滑過按鈕時顯示完整回覆

    func schedule(_ row: SessionRow, under anchor: NSView) {
        // 從卡片移回同一列：卡片留著就好，不要收起來再重新浮出來（會閃一下）。
        if showing == row.key, panel != nil { cancelHide(); return }
        hide()
        let work = DispatchWorkItem { [weak self, weak anchor] in
            guard let self, let anchor, anchor.window != nil else { return }
            self.show(row, under: anchor)
        }
        pendingShow = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45, execute: work)
    }

    func scheduleHide(after delay: TimeInterval) {
        guard !isSending else { return }
        guard panel != nil else { hide(); return }   // 卡片還沒浮出來：直接取消
        pendingHide?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.hide() }
        pendingHide = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    func cancelHide() {
        pendingHide?.cancel()
        pendingHide = nil
    }

    var isVisible: Bool { panel?.isVisible ?? false }

    func hide() {
        guard !isSending else { return }
        pendingShow?.cancel()
        pendingShow = nil
        cancelHide()
        if let panel {
            panel.parent?.removeChildWindow(panel)
            panel.orderOut(nil)
        }
        panel = nil
        showing = nil
        preview = nil
    }

    private func show(_ row: SessionRow, under anchor: NSView) {
        guard let window = anchor.window else { return }
        // 左右各內縮一點：跟列表卡片同寬的話，它看起來會像列表的一部分，而不是浮在上面的一層。
        let indent = px(12)
        let width = max(280, anchor.bounds.width - 2 * indent)
        let content = makeContent(for: row, width: width)
        content.appearance = window.effectiveAppearance
        content.layoutSubtreeIfNeeded()
        let size = NSSize(width: width, height: content.fittingSize.height)

        let rowOnScreen = window.convertToScreen(anchor.convert(anchor.bounds, to: nil))
        let screen = window.screen?.visibleFrame ?? rowOnScreen
        var origin = NSPoint(x: rowOnScreen.minX + indent, y: rowOnScreen.minY - size.height - 4)
        if origin.y < screen.minY { origin.y = rowOnScreen.maxY + 4 }   // 下面放不下就放上面
        origin.y = min(origin.y, screen.maxY - size.height)

        let card = NSPanel(contentRect: NSRect(origin: origin, size: size),
                           styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        card.isOpaque = false
        card.backgroundColor = .clear
        card.hasShadow = true            // shadow-popover：只有浮層才有陰影
        card.appearance = window.effectiveAppearance
        card.contentView = content
        window.addChildWindow(card, ordered: .above)
        panel = card
        showing = row.key
    }

    func refitIfVisible() { refit() }

    /// 內容高度變了（例如按下選項後說明變長）：保持上緣不動、往下長。
    private func refit() {
        guard let panel, let content = panel.contentView else { return }
        content.layoutSubtreeIfNeeded()
        let height = content.fittingSize.height
        var frame = panel.frame
        frame.origin.y += frame.height - height
        frame.size.height = height
        panel.setFrame(frame, display: true)
    }

    /// 送出途中卡片不收：滑鼠一定會離開（Claude 會跳到最前面），結果還要顯示在這裡。
    private var isSending = false

    /// 已經按過選項的問題：session＋問題文字 → 送出的那句。同一個問題不會再送第二次 ——
    /// 就算對話紀錄還沒寫進你的回覆，或「認出你的回覆」的判斷又出錯。
    /// 2026-10-28 實際發生過：回覆沒被認出來，選項一直掛著，同一句被送了兩次。
    private var answered: [String: String] = [:]
    private var buttons: [ChoiceButton] = []
    private func questionKey(_ row: SessionRow) -> String { row.key + "\u{1F}" + row.ask }

    /// 按下某個選項：交給 AutoSender 送進那個聊天，結果只顯示在卡片上（不發系統通知）。
    private func pick(_ choice: Choice, in row: SessionRow) {
        guard !isSending, answered[questionKey(row)] == nil else { return }
        isSending = true
        // 按下的那一刻就上鎖：送出要好幾秒，這段時間再按也不會送第二次。
        answered[questionKey(row)] = choice.label
        buttons.forEach { $0.isEnabled = false }
        cancelHide()
        let say = { [weak self] (text: String, color: NSColor) in
            guard let self, let preview = self.preview else { return }
            setParagraph(preview, text, MonoSharp.meta, color: color)
            self.refit()
        }
        say("送出「\(choice.label)」中… 先確認 Claude 打開的是這個聊天", MonoSharp.foreground)
        AutoSender.shared.send(choice.message, to: row) { [weak self] outcome in
            let title: String, body: String, color: NSColor
            switch outcome {
            case .delivered:
                title = "已送出「\(choice.label)」"
                body = "\(row.title) · 對話紀錄裡已經看到這句話"
                color = MonoSharp.success
            case .sentUnconfirmed:
                title = "已按下送出，但還沒確認送達"
                body = "\(row.title) · 15 秒內沒在對話紀錄裡看到這句話，請到 Claude 看一下"
                color = MonoSharp.warning
            case .stopped(let why, let now, let nothingSent):
                title = "沒有自動送出"
                body = "\(why) · \(now)"
                color = MonoSharp.warning
                // 確定什麼都沒送出（那句話只在剪貼簿裡）才解鎖，讓你可以再按一次。
                // 字已經貼進輸入框的情況不解鎖：你可能自己按了 Enter。
                if nothingSent, let self {
                    self.answered[self.questionKey(row)] = nil
                    self.buttons.forEach { $0.isEnabled = true }
                }
            }
            say("\(title) · \(body)", color)
            // 不另發系統通知：結果已經寫在卡片上；osascript 的通知會以「工序指令編寫程式」的名義跳出來，
            // 每選一次就跳一次（2026-10-28 依使用者要求拿掉）。
            self?.isSending = false
            self?.scheduleHide(after: 6)
        }
    }

    /// popover 底＋ring-card 框、直角。
    private func makeContent(for row: SessionRow, width: CGFloat) -> NSView {
        let box = CardView()
        box.fill = MonoSharp.popover
        box.stroke = tint(MonoSharp.foreground, 0.1)
        box.strokeWidth = 1

        let pad = px(12)
        let inner = width - 2 * pad
        func wrap(_ field: NSTextField) -> NSTextField {
            field.preferredMaxLayoutWidth = inner
            return field
        }

        var parts: [NSView] = []
        parts.append(wrap(paragraph(row.title, MonoSharp.bodyMedium, maxLines: 4, wrap: .balance)))
        var state = "\(status(row.kind).word) · \(whenText(row))"
        if !row.isLoaded { state += " · 未載入：程序已結束，這是結束前最後的狀態" }
        let stateText = paragraph(state, MonoSharp.meta, color: MonoSharp.mutedForeground, maxLines: 3)
        stateText.preferredMaxLayoutWidth = inner - px(7) - px(8)
        let stateDot = statusSquare(status(row.kind).tone.color)
        let stateLine = NSView()
        for v in [stateDot, stateText] { v.translatesAutoresizingMaskIntoConstraints = false; stateLine.addSubview(v) }
        NSLayoutConstraint.activate([
            stateDot.leadingAnchor.constraint(equalTo: stateLine.leadingAnchor),
            stateText.leadingAnchor.constraint(equalTo: stateDot.trailingAnchor, constant: px(8)),
            stateText.trailingAnchor.constraint(equalTo: stateLine.trailingAnchor),
            stateText.topAnchor.constraint(equalTo: stateLine.topAnchor),
            stateText.bottomAnchor.constraint(equalTo: stateLine.bottomAnchor),
            alignToFirstLine(stateDot, of: stateText, font: msFont(MonoSharp.meta)),
        ])
        parts.append(stateLine)
        if !row.cwd.isEmpty {
            parts.append(wrap(paragraph(row.cwd, MonoSharp.meta, color: MonoSharp.mutedForeground, maxLines: 3)))
        }

        var body: String?
        var caption = ""
        if !row.ask.isEmpty {
            body = row.ask
            caption = "它問你"
        } else if !row.recap.isEmpty {
            body = row.recap
            caption = "這是摘要，不是問題 · 它沒有寫出要問你什麼"
        }
        if let body {
            parts.append(divider())
            parts.append(wrap(paragraph(caption, MonoSharp.meta, color: MonoSharp.mutedForeground, maxLines: 2)))
            parts.append(wrap(paragraph(body, MonoSharp.body, maxLines: 30)))
        }

        // 回覆選項：要能打開那個聊天才放（沒有連結的話，複製了也不知道要貼去哪裡）。
        buttons = []
        if let label = answered[questionKey(row)], !row.choices.isEmpty {
            parts.append(wrap(paragraph("你已經用「\(label)」回覆過這個問題 · 要再回覆請到 Claude",
                                        MonoSharp.meta, color: MonoSharp.mutedForeground, maxLines: 3)))
        } else if !row.choices.isEmpty, row.link != nil {
            let buttons = row.choices.enumerated().map { ChoiceButton($1, primary: $0 == 0) }
            self.buttons = buttons
            let preview = wrap(paragraph("滑過按鈕可以看到完整的回覆內容 · 按下會直接送進那個聊天", MonoSharp.meta,
                                         color: MonoSharp.mutedForeground, maxLines: 8))
            self.preview = preview
            for button in buttons {
                button.onHover = { [weak preview] choice in
                    guard let preview else { return }
                    setParagraph(preview, choice.map { "會送出：\($0.message)" } ?? "滑過按鈕可以看到完整的回覆內容 · 按下會直接送進那個聊天",
                                 MonoSharp.meta, color: choice == nil ? MonoSharp.mutedForeground : MonoSharp.foreground)
                    HoverCard.shared.refitIfVisible()
                }
                button.onPick = { [weak self] choice in self?.pick(choice, in: row) }
            }
            // 放得下就排成一列，放不下就一個一排、撐滿寬度。
            let rowStack = NSStackView(views: buttons)
            rowStack.spacing = px(8)
            let fitsInOneLine = rowStack.fittingSize.width <= inner
            if !fitsInOneLine {
                rowStack.orientation = .vertical
                rowStack.alignment = .leading
                for b in buttons { b.widthAnchor.constraint(equalToConstant: inner).isActive = true }
            }
            parts.append(rowStack)
            parts.append(preview)
        }

        // 底部只放「你從習慣裡學不到」的事。「點那一列在 Claude 打開」使用者已經知道，
        // 2026-10-28 依使用者要求拿掉，不再佔空間。
        var notes: [String] = []
        if row.link == nil { notes.append("不是從 Claude Desktop 開的，沒有連結") }
        if !row.isLoaded { notes.append("右鍵可以不再顯示") }
        if !notes.isEmpty {
            parts.append(divider())
            parts.append(wrap(paragraph(notes.joined(separator: " · "), MonoSharp.meta,
                                        color: MonoSharp.mutedForeground, maxLines: 2)))
        }

        var previous: NSView?
        for part in parts {
            part.translatesAutoresizingMaskIntoConstraints = false
            box.addSubview(part)
            let gap: CGFloat = previous == nil ? pad : px(8)
            var constraints = [
                part.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: pad),
                part.topAnchor.constraint(equalTo: previous?.bottomAnchor ?? box.topAnchor, constant: gap),
            ]
            // 按鈕那一列不撐滿（按鈕維持自己的寬度），其他都撐滿。
            if part is NSStackView {
                constraints.append(part.trailingAnchor.constraint(lessThanOrEqualTo: box.trailingAnchor, constant: -pad))
            } else {
                constraints.append(part.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -pad))
            }
            NSLayoutConstraint.activate(constraints)
            previous = part
        }
        previous?.bottomAnchor.constraint(equalTo: box.bottomAnchor, constant: -pad).isActive = true
        box.widthAnchor.constraint(equalToConstant: width).isActive = true
        return box
    }
}

// MARK: 區塊（Section）

/// 三種狀態，各自一個切換鈕。「需要你」排第一 —— 這個視窗存在的理由就是那一區。
enum Group: Int, CaseIterable {
    case attention, running, idle

    var title: String {
        switch self {
        case .attention: return "需要你"
        case .running:   return "執行中"
        case .idle:      return "閒置"
        }
    }

    /// 這一區的代表色：需要你＝琥珀（需要人處理）、執行中＝綠（live）、閒置＝灰。
    var tone: NSColor {
        switch self {
        case .attention: return MonoSharp.warning
        case .running:   return MonoSharp.success
        case .idle:      return MonoSharp.mutedForeground
        }
    }

    /// 這一區是空的時候說什麼：一行標題、一行說明（告訴人什麼時候會有東西）。
    /// 介面上的中文句子不加句點（使用者的偏好）—— 原本用「。」分開的兩句，改成標題與說明兩行。
    var emptyTitle: String {
        switch self {
        case .attention: return "目前沒有 session 在等你"
        case .running:   return "目前沒有 session 在跑"
        case .idle:      return "沒有閒置的 session"
        }
    }
    var emptyHint: String {
        switch self {
        case .attention: return "有 session 問你問題或卡在對話框時，會出現在這裡"
        case .running:   return "在 Claude 送出一個 prompt，它就會出現在這裡"
        case .idle:      return "跑完、沒有東西在等你的 session 會出現在這裡"
        }
    }

    /// 這一區的 icon：需要你＝鈴鐺、執行中＝閃電、閒置＝月亮。切換鈕與空狀態共用。
    var symbol: String {
        switch self {
        case .attention: return "bell"
        case .running:   return "bolt"
        case .idle:      return "moon.zzz"
        }
    }
}

func group(_ kind: Kind) -> Group {
    switch kind {
    case .atDialog, .needsReply, .hasQuestion, .unknown: return .attention
    case .working:                                       return .running
    case .settled, .noSignal:                            return .idle
    }
}

/// card 底＋1px foreground 10% 框、直角，裡面是貼齊左右邊、用 border 分隔的列。
final class SectionView: TintedView {
    init(rows: [RowView]) {
        super.init(frame: .zero)
        fill = MonoSharp.card
        stroke = tint(MonoSharp.foreground, 0.1)
        strokeWidth = 1

        var previous: NSView?
        for (i, row) in rows.enumerated() {
            var stacked: [NSView] = [row]
            if i > 0 { stacked.insert(divider(), at: 0) }
            for view in stacked {
                addSubview(view)
                view.leadingAnchor.constraint(equalTo: leadingAnchor).isActive = true
                view.trailingAnchor.constraint(equalTo: trailingAnchor).isActive = true
                view.topAnchor.constraint(equalTo: previous?.bottomAnchor ?? topAnchor).isActive = true
                previous = view
            }
        }
        previous?.bottomAnchor.constraint(equalTo: bottomAnchor).isActive = true
    }
    required init?(coder: NSCoder) { fatalError("不從 nib 載入") }
}

/// 這一區沒有東西時：icon、標題、說明由上往下排，整組在剩下的空間裡上下左右置中。
/// Mono Sharp 的空狀態原本是「1px 虛線框、上下 40px」—— 這裡照使用者的偏好拿掉框，
/// 改成佔滿列表剩下的高度（高度由視窗那邊用約束撐滿，見 Monitor.rebuild）。
final class EmptyStateView: NSView {
    private let hint: NSTextField

    init(_ group: Group) {
        hint = paragraph(group.emptyHint, MonoSharp.body, color: MonoSharp.mutedForeground, maxLines: 3, alignment: .center)
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        let mark = NSImageView()
        mark.image = symbolImage(group.symbol, size: px(28), weight: .regular)
        mark.contentTintColor = MonoSharp.mutedForeground
        mark.translatesAutoresizingMaskIntoConstraints = false
        let title = label(group.emptyTitle, MonoSharp.bodyMedium)
        title.alignment = .center

        let stack = NSStackView(views: [mark, title, hint])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = px(8)
        stack.setCustomSpacing(px(12), after: mark)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        let side = px(MonoSharp.padSection)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: side),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -side),
            stack.topAnchor.constraint(greaterThanOrEqualTo: topAnchor, constant: px(24)),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -px(24)),
            // 說明的框撐滿可用寬度、文字在框裡置中；框的寬度不能跟著內容走（見 WrapField.intrinsicContentSize）。
            hint.widthAnchor.constraint(equalTo: widthAnchor, constant: -2 * side),
        ])
    }
    required init?(coder: NSCoder) { fatalError("不從 nib 載入") }

    /// 多行說明要知道自己多寬才算得出幾行高。
    override func layout() {
        super.layout()
        let width = bounds.width - 2 * px(MonoSharp.padSection)
        if width > 0, hint.preferredMaxLayoutWidth != width { hint.preferredMaxLayoutWidth = width }
    }
}

// MARK: 切換鈕（FilterToggle）

/// Mono Sharp 的 FilterToggle：`muted` 軌道、2px 內距；項目 28px 高、12px／500；
/// 選中塊是 `background`＋ring-card＋shadow-pill，切換時用 snap（0.15s）滑過去。
/// 數量用 muted-foreground、等寬數字 —— 「需要你」有東西時改用 warning，那是這個視窗最重要的訊號。
/// 規格說「只是篩選同一份列表 → 用 FilterToggle，不用 Tabs」，這裡正是同一份 session 清單依狀態篩選。
final class FilterToggle: TintedView {
    var onChange: ((Group) -> Void)?
    private(set) var selected: Group = .attention
    private let pill = TintedView()
    private var cells: [(view: NSView, title: NSTextField, count: NSTextField)] = []
    private let inset: CGFloat = 2
    /// 格子太窄時三格一起收成「icon＋數量」，名稱藏起來（見 layout()）。
    private var iconOnly = false
    private var fullWidthConstraints: [NSLayoutConstraint] = []
    private var iconOnlyConstraints: [NSLayoutConstraint] = []

    override init(frame: NSRect) {
        super.init(frame: frame)
        fill = MonoSharp.muted
        pill.translatesAutoresizingMaskIntoConstraints = true
        pill.fill = MonoSharp.background
        pill.stroke = tint(MonoSharp.foreground, 0.1)
        pill.strokeWidth = 1
        pill.layer?.shadowColor = NSColor.black.cgColor   // shadow-pill：0 1px 2px rgba(0,0,0,.05)
        pill.layer?.shadowOpacity = 0.05
        pill.layer?.shadowOffset = CGSize(width: 0, height: -1)
        pill.layer?.shadowRadius = 1
        addSubview(pill)

        for g in Group.allCases {
            let mark = Self.icon(for: g)
            let title = label(g.title, MonoSharp.control)
            let count = label("0", MonoSharp.control, color: MonoSharp.mutedForeground, tabular: true)
            let font = title.font ?? msFont(MonoSharp.control)

            // icon、名稱、數量排成一組，整組在格子裡水平置中。
            let group = NSView()
            group.translatesAutoresizingMaskIntoConstraints = false
            for v in [mark, title, count] as [NSView] { group.addSubview(v) }
            let cell = NSView()
            cell.addSubview(group)
            // 名稱顯示時：icon、名稱、數量；收起時：icon、數量（名稱的寬度歸零）。
            fullWidthConstraints.append(count.leadingAnchor.constraint(equalTo: title.trailingAnchor, constant: px(6)))
            iconOnlyConstraints += [
                count.leadingAnchor.constraint(equalTo: mark.trailingAnchor, constant: px(6)),
                title.widthAnchor.constraint(equalToConstant: 0),
            ]
            NSLayoutConstraint.activate([
                mark.leadingAnchor.constraint(equalTo: group.leadingAnchor),
                title.leadingAnchor.constraint(equalTo: mark.trailingAnchor, constant: px(6)),
                count.trailingAnchor.constraint(equalTo: group.trailingAnchor),
                group.topAnchor.constraint(equalTo: title.topAnchor),
                group.bottomAnchor.constraint(equalTo: title.bottomAnchor),
                count.firstBaselineAnchor.constraint(equalTo: title.firstBaselineAnchor),
                // 垂直對齊不用「外框置中」：文字的外框含行距，icon 會看起來偏一點。
                // 改成對齊文字的視覺中心 —— 基線往上半個大寫字高。
                alignToFirstLine(mark, of: title, font: font),
                group.centerXAnchor.constraint(equalTo: cell.centerXAnchor),
                group.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            ])
            addSubview(cell)
            cells.append((cell, title, count))
        }
        NSLayoutConstraint.activate(fullWidthConstraints)
        heightAnchor.constraint(equalToConstant: px(28) + 2 * inset).isActive = true
        refreshColors()
    }
    required init?(coder: NSCoder) { fatalError("不從 nib 載入") }

    /// 每一區的 icon：需要你＝鈴鐺、執行中＝閃電、閒置＝月亮。線條版（Mono Sharp 不用填色圖示），
    /// 顏色是那一區的狀態色，跟名稱一起出現，顏色不是唯一的訊號。
    /// 三個 icon 的外形寬窄不一，所以都放進同樣大小的方框裡置中 —— 不然名稱的起點會跟著 icon 左右飄。
    private static func icon(for g: Group) -> NSView {
        let name = g.symbol
        let box = px(14)
        let view = NSImageView()
        let config = NSImage.SymbolConfiguration(pointSize: box * 0.8, weight: .medium)
        view.image = NSImage(systemSymbolName: name, accessibilityDescription: g.title)?
            .withSymbolConfiguration(config)
        view.imageScaling = .scaleProportionallyDown
        view.imageAlignment = .alignCenter
        view.contentTintColor = g.tone
        view.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            view.widthAnchor.constraint(equalToConstant: box),
            view.heightAnchor.constraint(equalToConstant: box),
        ])
        return view
    }

    private func segment(_ i: Int) -> NSRect {
        let w = (bounds.width - 2 * inset) / CGFloat(cells.count)
        return NSRect(x: inset + CGFloat(i) * w, y: inset, width: w, height: bounds.height - 2 * inset)
    }

    override func layout() {
        super.layout()
        for (i, cell) in cells.enumerated() { cell.view.frame = segment(i) }
        pill.frame = segment(selected.rawValue)
        fitTitles()
    }

    /// 稽核截圖（寬 320、字級 160%）：整組 icon＋名稱＋數量比格子寬，溢出去壓到隔壁格。
    /// 任何一格放不下，三格一起只留 icon＋數量 —— 一起收，切換鈕才不會一半有字一半沒有。
    /// 數量一律用兩位數估，數字從 9 變 10 時不會跟著來回切換。
    private func fitTitles() {
        guard bounds.width > 0, let font = cells.first?.title.font else { return }
        func width(_ text: String) -> CGFloat { (text as NSString).size(withAttributes: [.font: font]).width + 4 }
        let cellWidth = segment(0).width
        let fits = cells.allSatisfy { cell in
            px(14) + px(6) + width(cell.title.stringValue) + px(6) + width("99") + 2 * px(4) <= cellWidth
        }
        guard fits == iconOnly else { return }
        iconOnly = !fits
        NSLayoutConstraint.deactivate(iconOnly ? fullWidthConstraints : iconOnlyConstraints)
        NSLayoutConstraint.activate(iconOnly ? iconOnlyConstraints : fullWidthConstraints)
        for cell in cells { cell.title.isHidden = iconOnly }
        needsLayout = true
    }

    func setCounts(_ counts: [Group: Int]) {
        for g in Group.allCases { cells[g.rawValue].count.stringValue = "\(counts[g] ?? 0)" }
        refreshColors(counts)
    }

    func select(_ g: Group, animated: Bool) {
        guard g != selected else { return }
        selected = g
        refreshColors()
        if animated && !reduceMotion {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.15   // snap
                pill.animator().frame = segment(g.rawValue)
            }
        } else {
            needsLayout = true
        }
    }

    private var lastCounts: [Group: Int] = [:]
    private func refreshColors(_ counts: [Group: Int]? = nil) {
        if let counts { lastCounts = counts }
        for g in Group.allCases {
            let cell = cells[g.rawValue]
            cell.title.textColor = g == selected ? MonoSharp.foreground : MonoSharp.mutedForeground
            // 有東西時數字用那一區的顏色（閒置除外 —— 它最不重要，維持灰色）。
            let lit = g != .idle && (lastCounts[g] ?? 0) > 0
            cell.count.textColor = lit ? g.tone : MonoSharp.mutedForeground
        }
    }

    // 整條吃下點擊，依位置決定是哪一格；再按一次已選中的不會取消。
    override func hitTest(_ point: NSPoint) -> NSView? {
        super.hitTest(point) == nil ? nil : self
    }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseUp(with event: NSEvent) {
        let x = convert(event.locationInWindow, from: nil).x
        guard let i = cells.indices.first(where: { segment($0).minX <= x && x < segment($0).maxX }),
              let g = Group(rawValue: i) else { return }
        select(g, animated: true)
        onChange?(g)
    }
}

// MARK: 捲軸

/// Mono Sharp 沒有規定捲軸，這裡照它的語彙做：直角、不加裝飾、顏色用 foreground 的淡化。
/// 平常只是一條 4pt 的細線；滑鼠移上去時變 6pt、顏色加深，並畫出淡色軌道，讓你知道可以拖。
/// 搭配 overlay 樣式：浮在內容上、不佔寬度（列表右邊本來就有 16pt 的留白）。
final class MonoScroller: NSScroller {
    private var isHovering = false { didSet { needsDisplay = true } }

    override class var isCompatibleWithOverlayScrollers: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        addTrackingArea(NSTrackingArea(
            rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self, userInfo: nil))
    }
    required init?(coder: NSCoder) { fatalError("不從 nib 載入") }

    override func mouseEntered(with event: NSEvent) { isHovering = true }
    override func mouseExited(with event: NSEvent) { isHovering = false }

    private var width: CGFloat { isHovering ? 6 : 4 }

    override func drawKnobSlot(in slotRect: NSRect, highlight flag: Bool) {
        guard isHovering else { return }   // 平常不畫軌道
        tint(MonoSharp.muted, 0.9).setFill()
        NSRect(x: slotRect.maxX - width - 3, y: slotRect.minY + 2,
               width: width, height: max(0, slotRect.height - 4)).fill()
    }

    override func drawKnob() {
        let r = rect(for: .knob)
        tint(MonoSharp.foreground, isHovering ? 0.45 : 0.25).setFill()
        NSRect(x: r.maxX - width - 3, y: r.minY + 2, width: width, height: max(0, r.height - 4)).fill()
    }
}

// MARK: - 視窗

/// NSView 預設不是 flipped，NSStackView 當 documentView 時內容會由下往上排，
/// 捲動位置停在尾端 —— 排序最前面、也就是最該看的那幾列反而看不到。翻過來。
final class FlippedStack: NSStackView {
    override var isFlipped: Bool { true }
}


final class Monitor: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var window: NSWindow!
    private var list: FlippedStack!
    private var toggle: FilterToggle!

    private var lastRows: [SessionRow] = []
    private var lastKind: [String: Kind] = [:]
    private var signature: String?
    private var rowViews: [String: RowView] = [:]
    private let scanQueue = DispatchQueue(label: "transcript-scan", qos: .utility)
    private var isScanning = false

    /// 目前看哪一區。第一次拿到資料時決定：有在等你的就開「需要你」，沒有就開「執行中」。
    private var tab: Group = .attention
    private var hasChosenTab = false
    /// 上一輪在「需要你」裡的 session。自動切換只看「這一輪跟上一輪差在哪」，不看現在有幾個。
    private var lastAttentionKeys: Set<String> = []

    func applicationDidFinishLaunching(_: Notification) {
        writeSwitch(true)
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(willPowerOff(_:)), name: NSWorkspace.willPowerOffNotification, object: nil)
        // 一般 app：有 Dock 圖示、⌘Tab 找得到。視窗不置頂，所以被蓋住時要有辦法叫回來。
        NSApp.setActivationPolicy(.regular)
        NSApp.applicationIconImage = appIcon()   // Logo.swift
        buildMenu()

        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 560),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false)
        window.title = "Lookout"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.titlebarSeparatorStyle = .none   // 標題列底線自己畫，用 border token 的顏色
        window.backgroundColor = MonoSharp.background
        window.minSize = NSSize(width: 320, height: 240)
        window.delegate = self
        // 沿用之前存下的位置（含在哪個螢幕）。
        let frameName = "ClaudeSessionMonitor.v2"
        if !window.setFrameUsingName(frameName) { window.center() }
        window.setFrameAutosaveName(frameName)

        // 標題列不放 toolbar、不放 logo 和名稱：只剩紅綠燈的細條，空間留給內容。

        buildContent()
        // 不搶焦點：顯示在最上面，但等你點了才變成作用中的 app。
        window.orderFrontRegardless()

        // ⌘= 也當放大（不用按 Shift）。其他快捷鍵由選單處理。
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.modifierFlags.contains(.command),
                  event.charactersIgnoringModifiers == "=" else { return event }
            self.makeLarger()
            return nil
        }

        refresh()
        let timer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in self?.refresh() }
        RunLoop.main.add(timer, forMode: .common)
    }

    func windowWillClose(_: Notification) { NSApp.terminate(nil) }

    /// 關機／重新開機／登出會先發這個通知，之後才結束 app。
    private var isPoweringOff = false
    @objc private func willPowerOff(_: Notification) { isPoweringOff = true }

    /// 你自己關掉（關視窗、⌘Q）＝把開關關掉；關機時結束的不算。
    func applicationWillTerminate(_: Notification) {
        if !isPoweringOff { writeSwitch(false) }
    }
    func windowWillMiniaturize(_: Notification) { HoverCard.shared.hide() }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        window.makeKeyAndOrderFront(nil)
        return true
    }

    // MARK: 選單

    private func buildMenu() {
        let main = NSMenu()

        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "隱藏 Lookout", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "結束 Lookout", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        let appItem = NSMenuItem()
        appItem.submenu = appMenu
        main.addItem(appItem)

        let viewMenu = NSMenu(title: "顯示")
        // ⌘1 ⌘2 ⌘3 直接切到那一區，比用滑鼠點更快。
        for g in Group.allCases {
            let item = viewMenu.addItem(withTitle: g.title, action: #selector(selectTab(_:)),
                                        keyEquivalent: "\(g.rawValue + 1)")
            item.tag = g.rawValue
            item.target = self
        }
        viewMenu.addItem(.separator())
        // 字體大小只放在這裡：一天用不到一次，不值得佔標題列。
        for (title, key, action) in [("放大字體", "+", #selector(makeLarger)),
                                     ("縮小字體", "-", #selector(makeSmaller)),
                                     ("實際大小", "0", #selector(resetScale))] {
            let item = viewMenu.addItem(withTitle: title, action: action, keyEquivalent: key)
            item.target = self
        }
        viewMenu.addItem(.separator())
        // 提示音只在「需要你」時響；這裡可以整個關掉。打勾＝開著。
        let chime = viewMenu.addItem(withTitle: "提示音", action: #selector(toggleChime(_:)), keyEquivalent: "")
        chime.target = self
        chime.state = ChimePlayer.shared.isEnabled ? .on : .off
        let viewItem = NSMenuItem()
        viewItem.submenu = viewMenu
        main.addItem(viewItem)

        let windowMenu = NSMenu(title: "視窗")
        windowMenu.addItem(withTitle: "縮到最小", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "關閉", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        let windowItem = NSMenuItem()
        windowItem.submenu = windowMenu
        main.addItem(windowItem)

        NSApp.mainMenu = main
        NSApp.windowsMenu = windowMenu
    }

    /// 打開時放一次「需要你」的聲音，順便確認音量。關掉時安靜地關。
    @objc private func toggleChime(_ sender: NSMenuItem) {
        let player = ChimePlayer.shared
        player.isEnabled.toggle()
        sender.state = player.isEnabled ? .on : .off
        if player.isEnabled { player.play(.attention) }
    }

    @objc private func selectTab(_ sender: NSMenuItem) {
        guard let g = Group(rawValue: sender.tag) else { return }
        toggle.select(g, animated: true)
        switchTo(g)
    }

    private func switchTo(_ g: Group) {
        hasChosenTab = true
        tab = g
        signature = nil
        render(lastRows)
    }

    // MARK: 字體大小

    @objc private func makeSmaller() { setScale(uiScale - scaleStep) }
    @objc private func makeLarger() { setScale(uiScale + scaleStep) }
    @objc private func resetScale() { setScale(1) }

    private func setScale(_ value: CGFloat) {
        // 取到小數一位，免得連按幾次之後累積出 1.2000000002 這種值。
        let next = min(max((value * 10).rounded() / 10, scaleRange.lowerBound), scaleRange.upperBound)
        guard next != uiScale else { return }
        uiScale = next
        UserDefaults.standard.set(Double(next), forKey: scaleKey)
        buildContent()
        signature = nil
        render(lastRows)
    }

    // MARK: 內容

    private func buildContent() {
        HoverCard.shared.hide()
        let root = TintedView()
        root.fill = MonoSharp.background
        window.contentView = root

        let rule = divider()   // 標題列的底線
        let gutter = px(MonoSharp.gutter)

        // 切換鈕固定在上面，不跟著列表捲動 —— 不管捲到哪裡都能直接切。
        toggle = FilterToggle()
        toggle.select(tab, animated: false)
        toggle.onChange = { [weak self] g in self?.switchTo(g) }

        list = FlippedStack()
        list.orientation = .vertical
        list.alignment = .leading
        list.spacing = px(16)
        list.edgeInsets = NSEdgeInsets(top: px(12), left: gutter, bottom: gutter, right: gutter)
        list.translatesAutoresizingMaskIntoConstraints = false

        let scroll = NSScrollView()
        scroll.documentView = list
        scroll.verticalScroller = MonoScroller()
        scroll.scrollerStyle = .overlay
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.contentView.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.automaticallyAdjustsContentInsets = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        // 捲動時收起懸停卡片，不然它會停在原地、跟它描述的那一列錯開。
        scroll.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification,
                                               object: scroll.contentView, queue: .main) { _ in
            HoverCard.shared.hide()
        }

        for view in [rule, toggle!, scroll] as [NSView] { root.addSubview(view) }
        let contentTop = (window.contentLayoutGuide as? NSLayoutGuide)?.topAnchor ?? root.topAnchor
        NSLayoutConstraint.activate([
            rule.topAnchor.constraint(equalTo: contentTop),
            rule.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            rule.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            // 切換鈕跟下面的卡片用同一條左右對齊線（gutter）。
            toggle.topAnchor.constraint(equalTo: rule.bottomAnchor, constant: gutter),
            toggle.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: gutter),
            toggle.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -gutter),
            scroll.topAnchor.constraint(equalTo: toggle.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            list.widthAnchor.constraint(equalTo: scroll.widthAnchor),
        ])
    }

    // MARK: 更新

    /// 第一輪要從 transcript 尾端往前找，掃描在背景佇列上做，視窗才不會卡住。
    /// 記憶（未載入的 session）也只在這個佇列上讀寫。
    private func refresh() {
        guard !isScanning else { return }
        isScanning = true
        scanQueue.async { [weak self] in
            let rows = withRemembered(readSessions())
            DispatchQueue.main.async {
                self?.isScanning = false
                self?.render(rows)
            }
        }
    }

    private func forgetSession(_ key: String) {
        HoverCard.shared.hide()
        scanQueue.async { [weak self] in
            forget(key)
            DispatchQueue.main.async { self?.refresh() }
        }
    }

    private func render(_ rows: [SessionRow]) {
        lastRows = rows
        for row in rows {
            if let was = lastKind[row.key], was != row.kind {
                onTransition(row, from: was)
            }
        }
        lastKind = Dictionary(rows.map { ($0.key, $0.kind) }, uniquingKeysWith: { a, _ in a })

        var counts: [Group: Int] = [:]
        for row in rows { counts[group(row.kind), default: 0] += 1 }
        toggle.setCounts(counts)

        let attentionKeys = Set(rows.filter { group($0.kind) == .attention }.map(\.key))
        if !hasChosenTab {
            hasChosenTab = true
            tab = attentionKeys.isEmpty ? .running : .attention
            toggle.select(tab, animated: false)
        } else {
            autoSwitch(from: lastAttentionKeys, to: attentionKeys)
        }
        lastAttentionKeys = attentionKeys

        // 結構沒變就只更新時間，不重建：重建會清掉脈動動畫和 hover。
        let shown = rows.filter { group($0.kind) == tab }
        let shape = shown.map { "\($0.key)|\($0.kind)|\($0.isLoaded)|\($0.title)|\($0.ask)|\($0.recap)|\($0.cwd)" }
                         .joined(separator: "\n") + "|tab=\(tab.rawValue)"
        if shape == signature {
            for row in shown { rowViews[row.key]?.update(row) }
            return
        }
        signature = shape
        rebuild(shown)
    }

    /// 自動切換。兩條規則都只在「事情發生的那一刻」觸發一次，不是只要條件成立就一直拉：
    /// 不然你主動切去看「執行中」時，只要「需要你」還有東西，2 秒後就會被拉回來，等於出不去。
    ///
    /// - 有新的 session 進入「需要你」（上一輪沒有它）：你在別的 tab，就切過去。
    /// - 「需要你」從有東西變成空：你正在「需要你」，就切到「執行中」。
    ///   你自己點進一個本來就空的「需要你」不算 —— 那一刻它沒有「變成」空。
    private func autoSwitch(from before: Set<String>, to now: Set<String>) {
        let arrived = !now.subtracting(before).isEmpty
        if tab != .attention && arrived {
            tab = .attention
            toggle.select(.attention, animated: true)
        } else if tab == .attention && now.isEmpty && !before.isEmpty {
            tab = .running
            toggle.select(.running, animated: true)
        }
    }

    private func rebuild(_ shown: [SessionRow]) {
        HoverCard.shared.hide()
        for view in list.arrangedSubviews { view.removeFromSuperview() }
        rowViews = [:]

        if shown.isEmpty {
            let empty = EmptyStateView(tab)
            append(empty)
            // 撐滿捲動區剩下的高度（扣掉列表上下的留白），內容才會在視窗裡置中，而不是貼在上面。
            if let clip = list.enclosingScrollView?.contentView {
                let insets = list.edgeInsets.top + list.edgeInsets.bottom
                empty.heightAnchor.constraint(greaterThanOrEqualTo: clip.heightAnchor, constant: -insets).isActive = true
            }
            return
        }
        var views: [RowView] = []
        for row in shown {
            let view = RowView(row: row, style: tab == .attention ? .full : .compact)
            view.onForget = { [weak self] key in self?.forgetSession(key) }
            rowViews[row.key] = view
            views.append(view)
        }
        append(SectionView(rows: views))
    }

    /// 靠 stack 的 alignment 撐不滿寬度，所以每一塊直接釘寬（扣掉左右 gutter）。
    private func append(_ view: NSView) {
        list.addArrangedSubview(view)
        view.widthAnchor.constraint(equalTo: list.widthAnchor, constant: -2 * px(MonoSharp.gutter)).isActive = true
    }
}

// ENTRY-BEGIN（量測腳本會把這一段拿掉，換成自己的進入點）
@main
enum SessionMonitorApp {
    static func main() {
        // 自己開一個新的 session／process group，跟啟動它的那一方完全脫鉤。
        // Claude 桌面版用 `disclaimer --pgroup` 跑每個 session 的 engine：session 結束時整個 process group 會被收掉，
        // 只靠 nohup 擋不住（nohup 只忽略 SIGHUP）。已經是 group leader 時 setsid 會失敗，那種情況本來就不受影響。
        _ = setsid()
        guard claimSingleInstance() else {
            FileHandle.standardError.write("已經有一個在跑了，這個不開\n".data(using: .utf8)!)
            exit(0)
        }
        let monitor = Monitor()
        NSApplication.shared.delegate = monitor
        NSApplication.shared.run()
    }
}
// ENTRY-END
