import Foundation
import SQLite3

/// 本地轨迹数据库（1:1 对应安卓 Db.java 的 SQLite 表结构）。
/// 表结构与安卓端一致：tracks + track_pts，同一套字段名。
/// 苹果与安卓不共享本地库，但字段设计一致便于未来云同步对齐。
public final class Db {
    public static let shared = Db()
    private var db: OpaquePointer?
    private let queue = DispatchQueue(label: "cn.peakpal.db")

    private init() {
        let path = FileManager.default
            .urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("peakpal.sqlite3").path
        sqlite3_open_v2(path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil)
        exec("PRAGMA journal_mode=WAL;")
        exec("""
        CREATE TABLE IF NOT EXISTS tracks(
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            name TEXT NOT NULL,
            start INTEGER NOT NULL,
            end INTEGER NOT NULL,
            dur INTEGER NOT NULL,
            distance REAL NOT NULL,
            asc REAL NOT NULL,
            maxalt REAL NOT NULL,
            cloud_id INTEGER DEFAULT 0,
            done INTEGER DEFAULT 0
        );
        """)
        exec("""
        CREATE TABLE IF NOT EXISTS track_pts(
            tid INTEGER NOT NULL,
            seq INTEGER NOT NULL,
            lat REAL NOT NULL, lng REAL NOT NULL,
            alt REAL NOT NULL, t INTEGER NOT NULL,
            PRIMARY KEY(tid, seq)
        );
        """)
        exec("CREATE INDEX IF NOT EXISTS idx_pts_tid ON track_pts(tid);")
        // 队伍聊天本地记录（表结构/字段名与安卓 Db.java v7 完全一致）
        exec("""
        CREATE TABLE IF NOT EXISTS team_msg(
            id INTEGER PRIMARY KEY,
            code TEXT, pid TEXT, name TEXT,
            kind TEXT, text TEXT, file TEXT,
            t INTEGER,
            mine INTEGER DEFAULT 0
        );
        """)
        // 标注点表（v7.108 iOS：表结构/字段名与安卓 Db.java poi 表完全一致，便于云同步对齐）
        exec("""
        CREATE TABLE IF NOT EXISTS poi(
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            name TEXT, note TEXT,
            lat REAL NOT NULL, lng REAL NOT NULL,
            alt REAL DEFAULT 0, t INTEGER DEFAULT 0,
            type TEXT DEFAULT 'waypoint',
            tid INTEGER DEFAULT 0
        );
        """)
        exec("CREATE INDEX IF NOT EXISTS idx_poi_tid ON poi(tid);")
    }

    deinit { sqlite3_close(db) }

    @discardableResult
    private func exec(_ sql: String) -> Bool {
        return sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK
    }

    /// 新增轨迹（自动算距离/爬升/最高海拔），返回轨迹 id
    public func insertTrack(_ t: inout Track, pts: [TrackPt]) -> Int64 {
        t.distance = TrackMath.totalDistance(pts)
        t.asc = TrackMath.totalAscent(pts)
        t.maxalt = pts.map(\.alt).max() ?? 0
        if t.dur == 0 { t.dur = max(0, t.end - t.start) }
        let sem = DispatchSemaphore(value: 0)
        var newId: Int64 = 0
        queue.async {
            self.exec("BEGIN;")
            self.exec("INSERT INTO tracks(name,start,end,dur,distance,asc,maxalt,cloud_id,done) VALUES('\(Self.esc(t.name))',\(t.start),\(t.end),\(t.dur),\(t.distance),\(t.asc),\(t.maxalt),\(t.cloudId),\(t.done ? 1 : 0));")
            newId = sqlite3_last_insert_rowid(self.db)
            for (i, p) in pts.enumerated() {
                self.exec("INSERT OR REPLACE INTO track_pts(tid,seq,lat,lng,alt,t) VALUES(\(newId),\(i),\(p.lat),\(p.lng),\(p.alt),\(p.t));")
            }
            self.exec("COMMIT;")
            sem.signal()
        }
        sem.wait()
        return newId
    }

    /// 轨迹列表（按开始时间倒序）
    public func listTracks() -> [Track] {
        var out: [Track] = []
        let sem = DispatchSemaphore(value: 0)
        queue.async {
            var stmt: OpaquePointer?
            sqlite3_prepare_v2(self.db, "SELECT id,name,start,end,dur,distance,asc,maxalt,cloud_id,done FROM tracks ORDER BY start DESC;", -1, &stmt, nil)
            while sqlite3_step(stmt) == SQLITE_ROW {
                var t = Track()
                t.id = sqlite3_column_int64(stmt, 0)
                t.name = sqlite3_column_text(stmt, 1).map { String(cString: $0) } ?? ""
                t.start = sqlite3_column_int64(stmt, 2)
                t.end = sqlite3_column_int64(stmt, 3)
                t.dur = sqlite3_column_int64(stmt, 4)
                t.distance = sqlite3_column_double(stmt, 5)
                t.asc = sqlite3_column_double(stmt, 6)
                t.maxalt = sqlite3_column_double(stmt, 7)
                t.cloudId = sqlite3_column_int64(stmt, 8)
                t.done = sqlite3_column_int64(stmt, 9) == 1
                out.append(t)
            }
            sqlite3_finalize(stmt)
            sem.signal()
        }
        sem.wait()
        return out
    }

    /// 读轨迹点
    public func loadPts(tid: Int64) -> [TrackPt] {
        var out: [TrackPt] = []
        let sem = DispatchSemaphore(value: 0)
        queue.async {
            var stmt: OpaquePointer?
            sqlite3_prepare_v2(self.db, "SELECT lat,lng,alt,t FROM track_pts WHERE tid=\(tid) ORDER BY seq;", -1, &stmt, nil)
            var seq = 0
            while sqlite3_step(stmt) == SQLITE_ROW {
                var p = TrackPt(
                    lat: sqlite3_column_double(stmt, 0),
                    lng: sqlite3_column_double(stmt, 1),
                    alt: sqlite3_column_double(stmt, 2),
                    t: sqlite3_column_int64(stmt, 3))
                p.seq = seq; seq += 1
                if p.isValid { out.append(p) }
            }
            sqlite3_finalize(stmt)
            sem.signal()
        }
        sem.wait()
        return out
    }

    /// 删除轨迹
    public func deleteTrack(tid: Int64) {
        let sem = DispatchSemaphore(value: 0)
        queue.async {
            self.exec("DELETE FROM tracks WHERE id=\(tid);")
            self.exec("DELETE FROM track_pts WHERE tid=\(tid);")
            sem.signal()
        }
        sem.wait()
    }

    /// 回写云端 id
    public func setCloudId(tid: Int64, cloudId: Int64) {
        let sem = DispatchSemaphore(value: 0)
        queue.async {
            self.exec("UPDATE tracks SET cloud_id=\(cloudId) WHERE id=\(tid);")
            sem.signal()
        }
        sem.wait()
    }

    // MARK: - 队伍聊天（对应安卓 Db.addTeamMsg / teamMsgs）

    public struct TeamMsg: Identifiable {
        public var id: Int64 = 0
        public var pid = ""
        public var name = ""
        public var kind = "text"
        public var text = ""
        public var file: String?
        public var t: Int64 = 0
        public var mine = false
        public func voice() -> Bool { kind == "voice" }
        public func image() -> Bool { kind == "image" }
        public func video() -> Bool { kind == "video" }
        public func media() -> Bool { voice() || image() || video() }
    }

    /// 插入/替换一条聊天记录（服务器消息 id 为主键，重复拉取幂等）
    public func addTeamMsg(id: Int64, code: String, pid: String, name: String,
                           kind: String, text: String, file: String?, t: Int64, mine: Bool) {
        let sem = DispatchSemaphore(value: 0)
        queue.async {
            let f = file.map { "'\(Self.esc($0))'" } ?? "NULL"
            self.exec("INSERT OR REPLACE INTO team_msg(id,code,pid,name,kind,text,file,t,mine) VALUES(\(id),'\(Self.esc(code))','\(Self.esc(pid))','\(Self.esc(name))','\(Self.esc(kind))','\(Self.esc(text))',\(f),\(t),\(mine ? 1 : 0));")
            sem.signal()
        }
        sem.wait()
    }

    /// 本地聊天历史（最新 500 条，升序返回，与安卓一致）
    public func teamMsgs(code: String) -> [TeamMsg] {
        var out: [TeamMsg] = []
        let sem = DispatchSemaphore(value: 0)
        queue.async {
            var stmt: OpaquePointer?
            sqlite3_prepare_v2(self.db, "SELECT id,pid,name,kind,text,file,t,mine FROM (SELECT * FROM team_msg WHERE code=? ORDER BY id DESC LIMIT 500) ORDER BY id ASC;", -1, &stmt, nil)
            if stmt != nil {
                sqlite3_bind_text(stmt, 1, (code as NSString).utf8String, -1, nil)
                while sqlite3_step(stmt) == SQLITE_ROW {
                    var m = TeamMsg()
                    m.id = sqlite3_column_int64(stmt, 0)
                    m.pid = sqlite3_column_text(stmt, 1).map { String(cString: $0) } ?? ""
                    m.name = sqlite3_column_text(stmt, 2).map { String(cString: $0) } ?? ""
                    m.kind = sqlite3_column_text(stmt, 3).map { String(cString: $0) } ?? "text"
                    m.text = sqlite3_column_text(stmt, 4).map { String(cString: $0) } ?? ""
                    m.file = sqlite3_column_text(stmt, 5).map { String(cString: $0) }
                    m.t = sqlite3_column_int64(stmt, 6)
                    m.mine = sqlite3_column_int64(stmt, 7) == 1
                    out.append(m)
                }
                sqlite3_finalize(stmt)
            }
            sem.signal()
        }
        sem.wait()
        return out
    }

    static func esc(_ s: String) -> String {
        return s.replacingOccurrences(of: "'", with: "''")
    }

    // MARK: - 标注点（对应安卓 Db.poisForTrack / trackPois / addPoi / delPoi）

    private func readPoi(_ sql: String, bind tid: Int64? = nil) -> [Poi] {
        var out: [Poi] = []
        let sem = DispatchSemaphore(value: 0)
        queue.async {
            var stmt: OpaquePointer?
            sqlite3_prepare_v2(self.db, sql, -1, &stmt, nil)
            if stmt != nil {
                if let tid { sqlite3_bind_int64(stmt, 1, tid) }
                while sqlite3_step(stmt) == SQLITE_ROW {
                    var p = Poi()
                    p.id = sqlite3_column_int64(stmt, 0)
                    p.name = sqlite3_column_text(stmt, 1).map { String(cString: $0) } ?? ""
                    p.note = sqlite3_column_text(stmt, 2).map { String(cString: $0) } ?? ""
                    p.lat = sqlite3_column_double(stmt, 3)
                    p.lng = sqlite3_column_double(stmt, 4)
                    p.alt = sqlite3_column_double(stmt, 5)
                    p.t = sqlite3_column_int64(stmt, 6)
                    p.type = sqlite3_column_text(stmt, 7).map { String(cString: $0) } ?? "waypoint"
                    p.tid = sqlite3_column_int64(stmt, 8)
                    if p.isValid { out.append(p) }
                }
                sqlite3_finalize(stmt)
            }
            sem.signal()
        }
        sem.wait()
        return out
    }

    /// 本轨迹标注点 + 全局兴趣点（tid=0 OR tid，正序；与安卓 poisForTrack 同语义）
    public func poisForTrack(_ tid: Int64) -> [Poi] {
        return readPoi("SELECT id,name,note,lat,lng,alt,t,type,tid FROM poi WHERE tid=0 OR tid=? ORDER BY t ASC;", bind: tid)
    }

    /// 仅本轨迹导入绑定的标注点（不含全局，与安卓 trackPois 同语义）
    public func trackPois(_ tid: Int64) -> [Poi] {
        return readPoi("SELECT id,name,note,lat,lng,alt,t,type,tid FROM poi WHERE tid=? ORDER BY t ASC;", bind: tid)
    }

    /// 新增标注点（GPX/KMZ 导入、拍摄/语音落点用），返回新 id
    public func insertPoi(_ poi: Poi, tid: Int64) -> Int64 {
        var p = poi
        p.tid = tid
        var newId: Int64 = 0
        let sem = DispatchSemaphore(value: 0)
        queue.async {
            self.exec("BEGIN;")
            self.exec("INSERT INTO poi(name,note,lat,lng,alt,t,type,tid) VALUES('\(Self.esc(p.name))','\(Self.esc(p.note))',\(p.lat),\(p.lng),\(p.alt),\(p.t),'\(Self.esc(p.type))',\(p.tid));")
            newId = sqlite3_last_insert_rowid(self.db)
            self.exec("COMMIT;")
            sem.signal()
        }
        sem.wait()
        return newId
    }

    /// 删除标注点
    public func deletePoi(id: Int64) {
        queue.async { self.exec("DELETE FROM poi WHERE id=\(id);") }
    }
}
