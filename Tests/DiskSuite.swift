import Foundation
import Darwin

enum DiskHarness {
    static var checks:[[String:Any]]=[]
    static func check(_ name:String,_ expression:@autoclosure () throws -> Bool) {
        do {checks.append(["name":name,"passed":try expression()])}
        catch {checks.append(["name":name,"passed":false,"error":error.localizedDescription])}
    }
    static func rejects(_ name:String,_ action:() throws -> Void) {do {try action();checks.append(["name":name,"passed":false])}catch {checks.append(["name":name,"passed":true])}}
}

@main enum CandidateDiskSuite {
    static func makeWorkspace(_ title:String) -> Workspace {
        var v=Vacancy();v.title=title;v.updatedAt=Date(timeIntervalSince1970:1800000000);v.profiles[0].createdAt=v.updatedAt
        v.candidates=[Candidate(name:"Удаляемый кандидат",notes:"CHECK-DELETE-PRIVATE"),Candidate(name:"Сохраняемый кандидат")]
        return Workspace(vacancies:[v],selectedVacancyID:v.id)
    }
    static func main() throws {
        let t=DiskHarness.self,fm=FileManager.default
        let root=fm.temporaryDirectory.appendingPathComponent("candidate-disk-suite-\(UUID().uuidString)",isDirectory:true)
        try fm.createDirectory(at:root,withIntermediateDirectories:true)
        defer {try? fm.removeItem(at:root)}
        let disk=WorkspaceDisk(url:root.appendingPathComponent("workspace.json"))
        t.check("Missing workspace gives an empty workspace",try disk.load() == Workspace())
        let original=makeWorkspace("Первая вакансия")
        try disk.save(original)
        t.check("First write loads the same valid state",try disk.load() == original)
        t.check("First write creates no invented backup",!fm.fileExists(atPath:disk.backupURL.path))
        t.check("Main file permissions are owner-only",(try fm.attributesOfItem(atPath:disk.url.path)[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        t.check("Workspace folder permissions are owner-only",(try fm.attributesOfItem(atPath:root.path)[.posixPermissions] as? NSNumber)?.intValue == 0o700)
        var edited=original;edited.vacancies[0].title="Изменённая вакансия"
        try disk.save(edited)
        t.check("Second valid write creates previous-state backup",try WorkspaceDisk.decode(WorkspaceDisk.read(disk.backupURL)) == original)
        t.check("Second write updates main state",try disk.load() == edited)
        t.check("Backup permissions are owner-only",(try fm.attributesOfItem(atPath:disk.backupURL.path)[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        let unchangedBackup=try Data(contentsOf:disk.backupURL)
        try disk.save(edited)
        t.check("Unchanged save does not replace useful backup",try Data(contentsOf:disk.backupURL) == unchangedBackup)
        t.check("Correct backup is discoverable",disk.canRecover)

        let corrupt=Data("not JSON, preserve this input".utf8)
        try corrupt.write(to:disk.url)
        t.rejects("Corrupt input rejected on load"){_ = try disk.load()}
        t.rejects("Save never overwrites newly corrupt main file"){try disk.save(edited)}
        t.check("Corrupt original bytes preserved after refused save",try Data(contentsOf:disk.url) == corrupt)
        let recovered=try disk.recover()
        t.check("Explicit recovery loads previous valid backup",try recovered == original && disk.load() == original)
        t.check("Recovery preserves corrupt source for diagnosis",try Data(contentsOf:disk.preservedURL) == corrupt)
        t.check("Preserved corrupt source is owner-only",(try fm.attributesOfItem(atPath:disk.preservedURL.path)[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        t.check("Recovered main state remains owner-only",(try fm.attributesOfItem(atPath:disk.url.path)[.posixPermissions] as? NSNumber)?.intValue == 0o600)

        var future=try JSONSerialization.jsonObject(with:WorkspaceDisk.encode(edited)) as! [String:Any]
        future["schemaVersion"]=2
        let futureRaw=try JSONSerialization.data(withJSONObject:future,options:[.sortedKeys])
        try futureRaw.write(to:disk.url)
        t.rejects("Future schema rejected on load"){_ = try disk.load()}
        t.rejects("Future schema not overwritten by save"){try disk.save(original)}
        t.check("Future schema byte-for-byte preserved",try Data(contentsOf:disk.url) == futureRaw)
        _ = try disk.recover()
        t.check("Explicit recovery retains future-schema input",try Data(contentsOf:disk.preservedURL) == futureRaw)

        var invalid=original;invalid.selectedVacancyID=UUID()
        let beforeInvalid=try Data(contentsOf:disk.url)
        t.rejects("Invalid new workspace rejected before write"){try disk.save(invalid)}
        t.check("Invalid new workspace leaves disk unchanged",try Data(contentsOf:disk.url) == beforeInvalid)
        t.rejects("Decode requires a schema header"){_ = try WorkspaceDisk.decode(Data("{\"vacancies\":[]}".utf8))}
        t.rejects("Decode rejects valid JSON with invalid selected ID"){
            let encoder=JSONEncoder();encoder.dateEncodingStrategy = .iso8601
            _ = try WorkspaceDisk.decode(encoder.encode(invalid))
        }
        let oversized=Data(repeating:32,count:32*1024*1024+1)
        t.rejects("Decode enforces 32 MiB bound"){_ = try WorkspaceDisk.decode(oversized)}
        let small=root.appendingPathComponent("bounded-read.bin");try Data(repeating:1,count:17).write(to:small)
        t.rejects("Bounded reader detects overrun"){_ = try WorkspaceDisk.read(small,limit:16)}
        t.check("Bounded reader leaves input untouched",try Data(contentsOf:small).count == 17)

        let obstruction=root.appendingPathComponent("not-a-directory");try Data("block".utf8).write(to:obstruction)
        let failingDisk=WorkspaceDisk(url:obstruction.appendingPathComponent("workspace.json"))
        t.rejects("Write error is surfaced"){try failingDisk.save(original)}
        t.check("Failed save does not mutate in-memory input",original.vacancies[0].title == "Первая вакансия")

        let lockURL=root.appendingPathComponent("workspace.lock")
        let first=WorkspaceLock(url:lockURL),second=WorkspaceLock(url:lockURL)
        try first.acquire();try first.acquire()
        t.rejects("Second writer cannot acquire same workspace"){try second.acquire()}
        first.release();try second.acquire();t.check("Lock transfers after explicit release",true)
        second.release()
        let lockTarget=root.appendingPathComponent("lock-target");try Data().write(to:lockTarget)
        let symlink=root.appendingPathComponent("symlink.lock");try fm.createSymbolicLink(at:symlink,withDestinationURL:lockTarget)
        t.rejects("Lock refuses symlink"){try WorkspaceLock(url:symlink).acquire()}

        // A deletion must update both live state and the automatic rollback copy.
        try disk.save(edited)
        try Data("CHECK-DELETE-PRIVATE preserved".utf8).write(to:disk.preservedURL)
        var deleted=edited;deleted.vacancies[0].candidates.removeFirst()
        try disk.save(deleted,purgingBackup:true)
        t.check("Purge writes post-deletion main state",try disk.load() == deleted)
        t.check("Purge writes post-deletion backup state",try WorkspaceDisk.decode(WorkspaceDisk.read(disk.backupURL)) == deleted)
        t.check("Purge removes preserved private copy",!fm.fileExists(atPath:disk.preservedURL.path))
        t.check("Deleted marker absent from main",!(try String(contentsOf:disk.url,encoding:.utf8)).contains("CHECK-DELETE-PRIVATE"))
        t.check("Deleted marker absent from backup",!(try String(contentsOf:disk.backupURL,encoding:.utf8)).contains("CHECK-DELETE-PRIVATE"))
        t.check("Another candidate survives deletion",try disk.load().vacancies[0].candidates.map(\.name) == ["Сохраняемый кандидат"])
        var cleared=deleted;cleared.vacancies=[];cleared.selectedVacancyID=nil
        try disk.save(cleared,purgingBackup:true)
        t.check("Vacancy deletion clears live and automatic backup",try disk.load().vacancies.isEmpty && WorkspaceDisk.decode(WorkspaceDisk.read(disk.backupURL)).vacancies.isEmpty)

        let noBackup=WorkspaceDisk(url:root.appendingPathComponent("no-backup.json"))
        t.check("Missing backup is not offered as recovery",!noBackup.canRecover)
        t.rejects("Recovery without valid backup is explicit failure"){_ = try noBackup.recover()}
        try fm.removeItem(at:root)
        t.check("Own temporary disk fixtures were removed",!fm.fileExists(atPath:root.path))
        let failures=t.checks.filter {($0["passed"] as? Bool) != true}
        let report:[String:Any] = ["scope":"Disk and lock tests in own temporary directory; not installed UI","passed":t.checks.count-failures.count,"failed":failures.count,"checks":t.checks,"temporary_directory_removed_on_exit":true]
        try fm.createDirectory(atPath:"Verification",withIntermediateDirectories:true)
        try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]).write(to:URL(fileURLWithPath:"Verification/disk-tests.json"))
        print("Disk checks: \(t.checks.count-failures.count)/\(t.checks.count)")
        failures.forEach {print("FAIL: \($0["name"] ?? "") \($0["error"] ?? "")")}
        if !failures.isEmpty {exit(1)}
    }
}
