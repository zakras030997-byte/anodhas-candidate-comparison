import Foundation
import Darwin

final class WorkspaceLock {
    private let url: URL; private var fd: Int32 = -1
    init(url: URL) { self.url = url }
    func acquire() throws {
        if fd >= 0 { return }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let handle = Darwin.open(url.path, O_CREAT | O_RDWR | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        guard handle >= 0 else { throw AppError("Не удалось открыть блокировку рабочего файла.") }
        guard flock(handle, LOCK_EX | LOCK_NB) == 0 else { close(handle); throw AppError("Рабочий файл уже открыт другим экземпляром. Закройте его перед изменением данных.") }
        fd = handle
    }
    func release() { if fd >= 0 { _ = flock(fd, LOCK_UN); close(fd); fd = -1 } }
    deinit { release() }
}

struct WorkspaceDisk {
    let url: URL
    var backupURL: URL { url.deletingPathExtension().appendingPathExtension("backup.json") }
    var preservedURL: URL { url.deletingPathExtension().appendingPathExtension("preserved.json") }
    static func read(_ url: URL, limit: Int = 32*1024*1024) throws -> Data {
        let h=try FileHandle(forReadingFrom:url);defer {try? h.close()}
        let data=try h.read(upToCount:limit+1) ?? Data()
        guard data.count <= limit else {throw AppError("Файл больше 32 МБ. Исходный файл не изменён.")}
        return data
    }
    static func encode(_ workspace: Workspace) throws -> Data {
        try CandidateEngine.validateWorkspace(workspace)
        let e=JSONEncoder();e.dateEncodingStrategy = .iso8601;e.outputFormatting = [.prettyPrinted,.sortedKeys]
        let data=try e.encode(workspace)
        guard data.count<=32*1024*1024 else {throw AppError("Рабочий файл больше 32 МБ.")}
        return data
    }
    static func decode(_ data: Data) throws -> Workspace {
        guard data.count<=32*1024*1024 else {throw AppError("Рабочий файл больше 32 МБ.")}
        guard let header=try JSONSerialization.jsonObject(with:data) as? [String:Any], let n=header["schemaVersion"] as? Int,n==1 else {throw AppError("Неизвестная версия файла. Он сохранён без изменений.")}
        let d=JSONDecoder();d.dateDecodingStrategy = .iso8601
        let result=try d.decode(Workspace.self,from:data);try CandidateEngine.validateWorkspace(result);return result
    }
    func load() throws -> Workspace {
        if !FileManager.default.fileExists(atPath:url.path) {return Workspace()}
        return try Self.decode(Self.read(url))
    }
    func save(_ workspace: Workspace, purgingBackup: Bool = false) throws {
        let raw=try Self.encode(workspace)
        try FileManager.default.createDirectory(at:url.deletingLastPathComponent(),withIntermediateDirectories:true)
        try FileManager.default.setAttributes([.posixPermissions:0o700],ofItemAtPath:url.deletingLastPathComponent().path)
        if FileManager.default.fileExists(atPath:url.path) {
            let old=try Self.read(url);_ = try Self.decode(old)
            if !purgingBackup && old != raw {try old.write(to:backupURL,options:.atomic)}
        }
        // Purge old private content before writing new state. Failure never claims deletion succeeded.
        if purgingBackup {
            try raw.write(to:backupURL,options:.atomic)
            if FileManager.default.fileExists(atPath:preservedURL.path) {try FileManager.default.removeItem(at:preservedURL)}
        }
        try raw.write(to:url,options:.atomic)
        try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:url.path)
        if FileManager.default.fileExists(atPath:backupURL.path) {try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:backupURL.path)}
    }
    var canRecover: Bool { (try? Self.decode(Self.read(backupURL))) != nil }
    func recover() throws -> Workspace {
        let raw=try Self.read(backupURL), result=try Self.decode(raw)
        if FileManager.default.fileExists(atPath:url.path) {
            try Self.read(url).write(to:preservedURL,options:.atomic)
            try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:preservedURL.path)
        }
        try raw.write(to:url,options:.atomic)
        return result
    }
}
