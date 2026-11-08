import Foundation
import AppKit

@main enum StoreSuite {
    @MainActor static func main() throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("candidate-store-check-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        defer {try? FileManager.default.removeItem(at:root)}
        var checks:[[String:Any]]=[]
        func check(_ name:String,_ value:Bool) {checks.append(["name":name,"passed":value])}
        var store:CandidateStore?=CandidateStore(folder:root)
        check("Empty first run",store!.data==Workspace() && !store!.blocked)
        var v=Vacancy();v.title="Своя вакансия"
        check("Save own vacancy",store!.saveVacancy(v))
        var invalid=Candidate();invalid.name="Марина";invalid.email="invalid"
        check("Invalid candidate rejected",!store!.saveCandidate(invalid) && store!.current!.candidates.isEmpty)
        invalid.email="marina@example.invalid"
        check("Valid candidate persisted",store!.saveCandidate(invalid) && store!.current!.candidates.count==1)
        var other=invalid;other.id=UUID();other.name="Другая заявка"
        check("Duplicate needs explicit action",!store!.saveCandidate(other))
        check("Explicit separate duplicate accepted",store!.saveCandidate(other,allowDuplicate:true))
        var editor=Candidate();editor.name="Незавершённый ввод";editor.email="not-yet-valid"
        store!.saveEditor(editor,kind:.candidate,vacancyID:v.id)
        let draft=root.appendingPathComponent("editor-draft-v1.json")
        check("Invalid editor fields saved only as draft",FileManager.default.fileExists(atPath:draft.path) && store!.current!.candidates.count==2)
        let permissions=try FileManager.default.attributesOfItem(atPath:draft.path)[.posixPermissions] as? NSNumber
        check("Editor draft owner-only",permissions?.intValue==0o600)
        let readOnly=CandidateStore(folder:root)
        check("Second Store cannot write",readOnly.blocked && !readOnly.saveVacancy(Vacancy()))
        store=nil
        store=CandidateStore(folder:root)
        check("Workspace survives reopening",store!.current?.title=="Своя вакансия" && store!.current?.candidates.count==2)
        let recovered=store!.decodeDraft(Candidate.self)
        check("Editor recovery retains unfinished input",recovered?.email=="not-yet-valid" && store!.current!.candidates.count==2)
        store!.discardDraft()
        check("Discard removes editor draft",!FileManager.default.fileExists(atPath:draft.path))

        v=store!.current!;var p=v.profile
        p.criteria=["Навык1","Навык2","Навык3"].map{Criterion(name:$0,outcome:"Рабочий результат",stageID:p.stages[0].id,reviewerIDs:[p.reviewers[0].id],questions:"Как выполнили задачу?")};p.locked=true
        v.profiles=[p];v.selectedProfileID=p.id
        check("Lock valid profile",store!.saveVacancy(v))
        var tampered=v;tampered.profiles[0].criteria[0].weight=90
        check("Store protects locked profile",!store!.saveVacancy(tampered))
        store!.saveEditor(store!.current!,kind:.vacancy,vacancyID:v.id)
        let vacancyDraft=store!.decodeDraft(Vacancy.self)!
        check("Restored vacancy draft preserves frozen history",store!.saveVacancy(vacancyDraft))
        let candidate=store!.current!.candidates[0]
        var card=try CandidateEngine.draft(store!.current!,candidateID:candidate.id,stageID:p.stages[0].id,reviewerID:p.reviewers[0].id)
        for i in card.assessments.indices {card.assessments[i].rating=4;card.assessments[i].evidence="Реальный пример из беседы"}
        card.comment="Оценка завершена"
        check("Submit through Store",store!.saveScorecard(card,submit:true))
        check("Store result after submit",CandidateEngine.result(store!.current!,candidate).score==4)
        var withDecision=store!.current!.candidates[0]
        withDecision.decisions.append(Decision(profileID:p.id,status:.discuss,author:"Руководитель",reason:"Нужно обсудить условия"))
        check("Manual decision appended",store!.saveCandidate(withDecision,allowDuplicate:true))
        store!.saveEditor(withDecision,kind:.candidate,vacancyID:v.id)
        let decisionDraft=store!.decodeDraft(Candidate.self)!
        check("Restored candidate draft preserves decision history",store!.saveCandidate(decisionDraft,allowDuplicate:true))
        store!.saveEditor(candidate,kind:.candidate,vacancyID:v.id)
        store!.deleteCandidate(candidate.id)
        check("Delete removes candidate and cards",store!.current!.candidates.count==1 && store!.current!.cards.isEmpty)
        check("Delete purges editor recovery",!FileManager.default.fileExists(atPath:draft.path) && store!.editorDraft==nil)
        check("Delete cannot be undone",!store!.canUndo)
        store!.recover()
        check("Recovery cannot resurrect deleted candidate",store!.current!.candidates.count==1 && store!.current!.cards.isEmpty)
        store=nil
        let raw=try WorkspaceDisk.read(root.appendingPathComponent("workspace-v1.json"));check("Final file still valid",(try? WorkspaceDisk.decode(raw)) != nil)
        let failed=checks.filter{($0["passed"] as? Bool) != true}
        let report:[String:Any]=["scope":"Store lifecycle in isolated temporary folder, no installed UI","passed":checks.count-failed.count,"failed":failed.count,"checks":checks]
        try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]).write(to:URL(fileURLWithPath:"Verification/store-tests.json"))
        print("Store checks: \(checks.count-failed.count)/\(checks.count)")
        for f in failed {print("FAIL \(f["name"] ?? "")")}
        if !failed.isEmpty {exit(1)}
    }
}
