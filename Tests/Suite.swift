import Foundation
import AppKit
import PDFKit

enum TestHarness {
    static var checks: [[String: Any]] = []
    static func check(_ name: String, _ condition: @autoclosure () throws -> Bool) {
        do { checks.append(["name":name,"passed":try condition()]) }
        catch { checks.append(["name":name,"passed":false,"error":error.localizedDescription]) }
    }
    static func rejects(_ name: String, _ action: () throws -> Void) {
        do { try action(); checks.append(["name":name,"passed":false,"error":"Expected rejection"]) }
        catch { checks.append(["name":name,"passed":true]) }
    }
    static func finish(extra: [String:Any] = [:]) throws {
        let failures=checks.filter { ($0["passed"] as? Bool) != true }
        var report: [String:Any] = ["scope":"Core and transfer CLI checks, not installed UI","checks":checks,"passed":checks.count-failures.count,"failed":failures.count]
        extra.forEach { report[$0.key]=$0.value }
        let data=try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys])
        try FileManager.default.createDirectory(atPath:"Verification",withIntermediateDirectories:true)
        try data.write(to:URL(fileURLWithPath:"Verification/tests.json"))
        print("Checks: \(checks.count-failures.count)/\(checks.count)")
        for failure in failures { print("FAIL: \(failure["name"] ?? "unknown") \(failure["error"] ?? "")") }
        if !failures.isEmpty { exit(1) }
    }
}

enum Fixtures {
    static func vacancy(reviewers: Int = 2, weights: [Int] = [50,30,20]) -> Vacancy {
        var v=Vacancy();v.title="Руководитель поддержки";v.tasks="Помогать клиентам и организовывать работу команды"
        var p=Profile();p.reviewers=(0..<reviewers).map { Reviewer(name:"Интервьюер \($0+1)") }
        p.criteria=weights.enumerated().map { i,w in
            Criterion(name:["Рабочие навыки","Разбор задачи","Общение"][i%3]+" \(i+1)",outcome:"Показанный результат работы",weight:w,stageID:p.stages[0].id,reviewerIDs:p.reviewers.map(\.id),questions:"Расскажите о решённой задаче")
        }
        p.requirements=[Requirement(title:"Рабочий график согласован")];p.locked=true
        v.profiles=[p];v.selectedProfileID=p.id
        v.candidates=[Candidate(name:"Кандидат А",email:"alpha@example.test",phone:"+7 900 123 45 67",summary:"Профессиональная справка",salaryMin:"100000",salaryMax:"120000",basis:.gross),Candidate(name:"Кандидат Б")]
        v.budgetMin="90000";v.budgetMax="130000";v.basis = .gross
        return v
    }
    static func rate(_ vacancy: inout Vacancy, candidate: Int = 0, reviewer: Int, ratings: [Int?], send: Bool = true) throws {
        let p=vacancy.profile
        var c=try CandidateEngine.draft(vacancy,candidateID:vacancy.candidates[candidate].id,stageID:p.stages[0].id,reviewerID:p.reviewers[reviewer].id)
        c.assessments=c.assessments.enumerated().map { i,a in var a=a;a.rating=ratings[i];a.evidence=ratings[i] == nil ? "" : "Разобрал конкретную рабочую задачу \(i+1)";a.skipReason=ratings[i] == nil ? "Вопрос не обсуждался" : "";return a }
        c.comment="Вывод основан на примерах интервью";if c.revision>1 {c.amendmentReason="Уточнён ответ кандидата"}
        try CandidateEngine.saveCard(c,in:&vacancy,submit:send)
    }
    static func workspace(_ v: Vacancy) -> Workspace { Workspace(vacancies:[v],selectedVacancyID:v.id) }
}

@main enum CandidateSuite {
    static func main() throws {
        let t=TestHarness.self
        var v=Fixtures.vacancy()
        try CandidateEngine.validateWorkspace(Fixtures.workspace(v))
        var r=CandidateEngine.result(v,v.candidates[0])
        t.check("Empty evaluation is incomplete, not zero score",r.score == nil && r.coverage == 0 && r.missing.count == 6)
        try Fixtures.rate(&v,reviewer:0,ratings:[4,3,4])
        r=CandidateEngine.result(v,v.candidates[0])
        t.check("One of two reviewers has 50% weighted coverage",r.coverage == 50 && r.score == nil)
        try Fixtures.rate(&v,reviewer:1,ratings:[5,3,4])
        r=CandidateEngine.result(v,v.candidates[0])
        t.check("Manual worked example gives 3.95",r.score == Decimal(string:"3.95") && r.coverage == 100)
        t.check("Unassessed mandatory requirement remains separate",r.unknownRequirements == 1 && r.notConfirmedRequirements == 0 && r.confirmedRequirements == 0)
        v.candidates[0].checks=[RequirementCheck(profileID:v.profile.id,requirementID:v.profile.requirements[0].id,state:.notConfirmed,evidence:"График пока не согласован")]
        r=CandidateEngine.result(v,v.candidates[0])
        t.check("Unconfirmed requirement does not erase high score or reject person",r.score == Decimal(string:"3.95") && r.notConfirmedRequirements == 1 && v.candidates[0].status == .new)
        var normalized=v;normalized.profiles[0].criteria[0].weight=5;normalized.profiles[0].criteria[1].weight=3;normalized.profiles[0].criteria[2].weight=2
        t.check("Changing weight units preserves mean",CandidateEngine.result(normalized,normalized.candidates[0]).score == r.score)

        var missing=Fixtures.vacancy();try Fixtures.rate(&missing,reviewer:0,ratings:[4,3,4]);try Fixtures.rate(&missing,reviewer:1,ratings:[nil,3,4])
        r=CandidateEngine.result(missing,missing.candidates[0])
        t.check("One unknown on weight 50 yields 75% coverage",r.coverage == 75 && r.score == nil)
        t.check("Unknown is not included as a zero skill rating",r.criteria[0].ratings == [4] && r.criteria[0].average == 4)
        t.check("Unknown identifies exact reviewer and criterion",r.missing.count == 1 && r.missing[0].contains(missing.profile.reviewers[1].name) && r.missing[0].contains(missing.profile.criteria[0].name))

        var draft=Fixtures.vacancy();try Fixtures.rate(&draft,reviewer:0,ratings:[5,5,5],send:false)
        t.check("Draft does not enter summary",CandidateEngine.result(draft,draft.candidates[0]).coverage == 0)
        let draftID=draft.cards[0].id
        let returned=try CandidateEngine.draft(draft,candidateID:draft.candidates[0].id,stageID:draft.profile.stages[0].id,reviewerID:draft.profile.reviewers[0].id)
        t.check("Reopening draft reuses the same ID",returned.id == draftID && returned.revision == 1)
        try CandidateEngine.saveCard(returned,in:&draft,submit:true)
        t.check("Submitting existing draft replaces it",draft.cards.count == 1 && draft.cards[0].submittedAt != nil)
        t.rejects("Repeated send is rejected, no duplicate"){try CandidateEngine.saveCard(returned,in:&draft,submit:true)}
        t.check("Repeated send leaves one card",draft.cards.count == 1)
        var edit=try CandidateEngine.draft(draft,candidateID:draft.candidates[0].id,stageID:draft.profile.stages[0].id,reviewerID:draft.profile.reviewers[0].id)
        t.check("Amendment has new ID and incremented revision",edit.id != draftID && edit.revision == 2)
        edit.assessments[0].rating=1
        t.rejects("Amendment submission requires reason"){try CandidateEngine.saveCard(edit,in:&draft,submit:true)}
        edit.amendmentReason="Проверили дополнительный пример"
        try CandidateEngine.saveCard(edit,in:&draft,submit:false)
        t.check("Draft amendment preserves active submitted assessment",CandidateEngine.result(draft,draft.candidates[0]).criteria[0].ratings == [5])
        try CandidateEngine.saveCard(edit,in:&draft,submit:true)
        t.check("Submitted amendment replaces rather than adds weight",CandidateEngine.result(draft,draft.candidates[0]).criteria[0].ratings == [1] && CandidateEngine.activeCards(draft,candidateID:draft.candidates[0].id,profileID:draft.profile.id).count == 1)
        t.check("Previous submitted revision retained",draft.cards.filter {$0.submittedAt != nil}.count == 2)
        try CandidateEngine.validateWorkspace(Fixtures.workspace(draft))

        var disagreement=Fixtures.vacancy();try Fixtures.rate(&disagreement,reviewer:0,ratings:[2,3,3]);try Fixtures.rate(&disagreement,reviewer:1,ratings:[4,4,3])
        let dr=CandidateEngine.result(disagreement,disagreement.candidates[0])
        t.check("Two-point disagreement is visible",dr.criteria[0].disagreement)
        t.check("One-point difference not flagged",!dr.criteria[1].disagreement)
        t.check("Individual ratings survive aggregation",dr.criteria[0].ratings.sorted() == [2,4])
        var uneven=Fixtures.vacancy(reviewers:5)
        uneven.profiles[0].criteria[1].reviewerIDs=[uneven.profile.reviewers[0].id]
        uneven.profiles[0].criteria[2].reviewerIDs=[uneven.profile.reviewers[0].id]
        let up=uneven.profile
        for reviewer in up.reviewers {
            var card=try CandidateEngine.draft(uneven,candidateID:uneven.candidates[0].id,stageID:up.stages[0].id,reviewerID:reviewer.id)
            for index in card.assessments.indices {let id=card.assessments[index].criterionID;card.assessments[index].rating=id==up.criteria[1].id ? 3 : 4;card.assessments[index].evidence="Наблюдение по рабочему вопросу"}
            card.comment="Независимое мнение";try CandidateEngine.saveCard(card,in:&uneven,submit:true)
        }
        t.check("Five reviewers on one criterion do not add hidden weight",CandidateEngine.result(uneven,uneven.candidates[0]).score==Decimal(string:"3.7"))
        var unsent=try CandidateEngine.draft(disagreement,candidateID:disagreement.candidates[1].id,stageID:disagreement.profile.stages[0].id,reviewerID:disagreement.profile.reviewers[0].id)
        unsent.comment="Комментарий"
        t.rejects("Unknown criteria need explicit skip reasons on submission"){try CandidateEngine.validateCard(unsent,vacancy:disagreement,submitting:true)}
        for index in unsent.assessments.indices {unsent.assessments[index].rating=3;unsent.assessments[index].evidence=""}
        t.rejects("A score without an evidence note cannot be submitted"){try CandidateEngine.validateCard(unsent,vacancy:disagreement,submitting:true)}
        for index in unsent.assessments.indices {unsent.assessments[index].evidence="Рабочий пример"}
        unsent.comment=""
        t.rejects("Submitted card needs overall comment"){try CandidateEngine.validateCard(unsent,vacancy:disagreement,submitting:true)}
        unsent.comment="Комментарий";unsent.submittedAt=Date()
        t.rejects("Caller cannot supply submitted timestamp to bypass lifecycle"){try CandidateEngine.saveCard(unsent,in:&disagreement,submit:false)}

        let oldProfile=v.profile,oldScore=CandidateEngine.result(v,v.candidates[0]).score,oldCardCount=v.cards.count
        v.candidates[0].decisions=[Decision(profileID:oldProfile.id,status:.next,author:"Руководитель",reason:"Перейти к рабочей задаче")]
        try CandidateEngine.newVersion(&v)
        t.check("New profile is a distinct unlocked version",v.profile.id != oldProfile.id && v.profile.number == 2 && !v.profile.locked)
        t.check("Old profile and cards retained",v.profiles[0] == oldProfile && v.cards.count == oldCardCount)
        t.check("New profile starts with no reused scores",CandidateEngine.result(v,v.candidates[0]).score == nil && CandidateEngine.result(v,v.candidates[0]).coverage == 0)
        t.check("Old version can still be calculated",CandidateEngine.result(v,v.candidates[0],profile:oldProfile).score == oldScore)
        t.check("Manual decision remains tied to old version",v.candidates[0].decisions[0].profileID == oldProfile.id)
        t.rejects("Cannot rate unlocked profile"){_ = try CandidateEngine.draft(v,candidateID:v.candidates[0].id,stageID:v.profile.stages[0].id,reviewerID:v.profile.reviewers[0].id)}

        for bad in [0,6,-1] {
            var badCard=try CandidateEngine.draft(disagreement,candidateID:disagreement.candidates[1].id,stageID:disagreement.profile.stages[0].id,reviewerID:disagreement.profile.reviewers[0].id)
            badCard.assessments[0].rating=bad
            t.rejects("Rating \(bad) is invalid"){try CandidateEngine.validateCard(badCard,vacancy:disagreement,submitting:false)}
        }
        for badWeight in [0,-1,101] {var p=oldProfile;p.criteria[0].weight=badWeight;t.rejects("Weight \(badWeight) invalid"){try CandidateEngine.validateProfile(p)}}
        var p=oldProfile;p.criteria[0].reviewerIDs=[];t.rejects("Criterion needs an assigned reviewer"){try CandidateEngine.validateProfile(p)}
        p=oldProfile;p.criteria[0].reviewerIDs=[UUID()];t.rejects("Unknown assigned reviewer invalid"){try CandidateEngine.validateProfile(p)}
        p=oldProfile;p.criteria[0].stageID=UUID();t.rejects("Unknown stage invalid"){try CandidateEngine.validateProfile(p)}
        p=oldProfile;p.criteria[0].reviewerIDs.append(p.criteria[0].reviewerIDs[0]);t.rejects("Duplicate reviewer cannot add weight"){try CandidateEngine.validateProfile(p)}
        p=oldProfile;p.criteria[0].anchors.removeLast();t.rejects("Exactly five anchors required"){try CandidateEngine.validateProfile(p)}
        p=oldProfile;p.criteria[0].questions="";t.rejects("Activation requires questions"){try CandidateEngine.validateProfile(p,activating:true)}
        p=oldProfile;p.criteria=Array(p.criteria.prefix(2));t.rejects("Activation needs at least three criteria"){try CandidateEngine.validateProfile(p,activating:true)}

        var malformed=disagreement
        malformed.cards[0].candidateID=UUID();t.rejects("Unknown candidate in scorecard rejected"){try CandidateEngine.validateWorkspace(Fixtures.workspace(malformed))}
        malformed=disagreement;malformed.cards[0].assessments[0].criterionID=UUID();t.rejects("Unknown criterion rejected"){try CandidateEngine.validateWorkspace(Fixtures.workspace(malformed))}
        malformed=disagreement;malformed.cards.append(malformed.cards[0]);t.rejects("Duplicate card ID rejected"){try CandidateEngine.validateWorkspace(Fixtures.workspace(malformed))}
        malformed=disagreement;var duplicate=malformed.cards[0];duplicate.id=UUID();malformed.cards.append(duplicate);t.rejects("Duplicate revision key rejected"){try CandidateEngine.validateWorkspace(Fixtures.workspace(malformed))}
        malformed=disagreement;malformed.cards[0].revision=3;t.rejects("Revision sequence gaps rejected"){try CandidateEngine.validateWorkspace(Fixtures.workspace(malformed))}
        malformed=disagreement;malformed.selectedProfileID=UUID();t.rejects("Unknown selected profile rejected"){try CandidateEngine.validateWorkspace(Fixtures.workspace(malformed))}
        var w=Fixtures.workspace(disagreement);w.schemaVersion=2;t.rejects("Unknown workspace schema rejected"){try CandidateEngine.validateWorkspace(w)}
        w=Fixtures.workspace(disagreement);w.selectedVacancyID=UUID();t.rejects("Unknown selected vacancy rejected"){try CandidateEngine.validateWorkspace(w)}

        var person=Candidate(name:"Одинаковое имя")
        let other=Candidate(name:"Одинаковое имя")
        t.check("Same name is not a duplicate identity",CandidateEngine.duplicates(person,in:[other]).isEmpty)
        person.email=" ALPHA@EXAMPLE.TEST "
        t.check("Email normalization finds potential duplicate",CandidateEngine.duplicates(person,in:disagreement.candidates) == [disagreement.candidates[0].id])
        person.email="";person.phone="79001234567"
        t.check("Phone punctuation normalization finds duplicate",CandidateEngine.duplicates(person,in:disagreement.candidates) == [disagreement.candidates[0].id])
        person.phone="123";t.check("Short phone does not identify a person",CandidateEngine.duplicates(person,in:[Candidate(name:"Другой",phone:"123")]).isEmpty)
        person=Candidate(name:"Проверка",email:"broken email");t.rejects("Malformed email rejected"){try CandidateEngine.validateCandidate(person)}
        person=Candidate(name:"Проверка",salaryMin:"120",salaryMax:"100");t.rejects("Reversed salary range rejected"){try CandidateEngine.validateCandidate(person)}
        for badMoney in ["-1","1.234","NaN","1e6","10 000","∞"] {t.rejects("Money rejects \(badMoney)"){_ = try NumberText.money(badMoney)}}
        t.check("Unknown money is nil",try NumberText.money("") == nil)
        t.check("Comma decimal accepted",try NumberText.money("1200,50") == Decimal(string:"1200.50"))
        for badDate in ["2026-02-30","2026-2-01","not a date"] {t.rejects("Date rejects \(badDate)"){try CandidateEngine.validateDate(badDate)}}
        try CandidateEngine.validateDate("2024-02-29");t.check("Leap day accepted",true)
        for url in ["file:///etc/passwd","javascript:alert(1)","https://user:pass@example.test/resume"] {person=Candidate(name:"Проверка",resumeURL:url);t.rejects("Unsafe resume URL scheme or credentials rejected"){try CandidateEngine.validateCandidate(person)}}
        var pay=disagreement.candidates[0]
        t.check("Comparable salary uses monthly known basis",CandidateEngine.salaryComparison(disagreement,pay) == "Минимальные ожидания в бюджете")
        pay.currency="USD";t.check("Different currency not silently compared",CandidateEngine.salaryComparison(disagreement,pay) == "Условия требуют уточнения")
        pay=disagreement.candidates[0];pay.basis = .net;t.check("Gross/net not silently compared",CandidateEngine.salaryComparison(disagreement,pay) == "Условия требуют уточнения")
        pay=disagreement.candidates[0];pay.salaryMin="";t.check("Unknown salary not treated as zero",CandidateEngine.salaryComparison(disagreement,pay) == "Условия требуют уточнения")
        pay=disagreement.candidates[0];pay.salaryMin="140000";t.check("Above budget is condition warning",CandidateEngine.salaryComparison(disagreement,pay) == "Ожидания выше бюджета")

        let knownCases: [([Int],[Int],[Int],String)] = [
            ([1,1,1],[1,1,1],[1,1,1],"1"),([1,1,1],[5,5,5],[5,5,5],"5"),
            ([1,1,1],[1,3,5],[5,3,1],"3"),([80,10,10],[5,1,1],[5,1,1],"4.2"),
            ([10,80,10],[5,1,5],[5,1,5],"1.8"),([50,25,25],[4,3,5],[4,3,5],"4"),
            ([25,25,50],[2,4,3],[4,2,5],"3.5")]
        for (index,entry) in knownCases.enumerated() {
            var f=Fixtures.vacancy(weights:entry.0);try Fixtures.rate(&f,reviewer:0,ratings:entry.1.map(Optional.some));try Fixtures.rate(&f,reviewer:1,ratings:entry.2.map(Optional.some))
            t.check("Independent arithmetic table \(index+1)",CandidateEngine.result(f,f.candidates[0]).score == Decimal(string:entry.3))
        }
        // Metamorphic checks exercise invariants, not a second copy of the scoring implementation.
        for i in 0..<20 {
            var f=Fixtures.vacancy(weights:[i+1,21-i,7]);try Fixtures.rate(&f,reviewer:0,ratings:[i%5+1,(i+2)%5+1,(i+4)%5+1]);try Fixtures.rate(&f,reviewer:1,ratings:[(i+1)%5+1,(i+3)%5+1,i%5+1])
            let before=CandidateEngine.result(f,f.candidates[0])
            var reversed=f;reversed.cards.reverse();reversed.profiles[0].criteria.reverse();reversed.profiles[0].reviewers.reverse()
            t.check("Ordering invariant \(i)",CandidateEngine.result(reversed,reversed.candidates[0]).score == before.score)
            var scaled=f;for j in scaled.profiles[0].criteria.indices {scaled.profiles[0].criteria[j].weight *= 2}
            t.check("Weight scale invariant \(i)",CandidateEngine.result(scaled,scaled.candidates[0]).score == before.score)
            t.check("Complete bounded result \(i)",before.coverage == 100 && before.score! >= 1 && before.score! <= 5)
        }
        let performance=try performanceCheck()
        try transferChecks()
        try t.finish(extra:["performance":performance])
    }

    static func performanceCheck() throws -> [String:Any] {
        var v=Fixtures.vacancy(reviewers:5,weights:Array(repeating:1,count:20));v.candidates=[];v.cards=[]
        let p=v.profile
        for i in 0..<100 {
            let c=Candidate(name:"Нагрузочный кандидат \(i)");v.candidates.append(c)
            for (j,reviewer) in p.reviewers.enumerated() {
                let a=p.criteria.enumerated().map { k,criterion in Assessment(criterionID:criterion.id,rating:(i+j+k)%5+1,evidence:"Проверенный рабочий пример") }
                v.cards.append(Scorecard(candidateID:c.id,profileID:p.id,stageID:p.stages[0].id,reviewerID:reviewer.id,submittedAt:Date(),assessments:a,comment:"Все критерии оценены"))
            }
        }
        var samples:[Double]=[]
        for _ in 0..<5 {
            let start=DispatchTime.now().uptimeNanoseconds
            let results=v.candidates.map { CandidateEngine.result(v,$0) }
            let ms=Double(DispatchTime.now().uptimeNanoseconds-start)/1_000_000
            samples.append(ms);TestHarness.check("Stress results complete",results.allSatisfy {$0.coverage == 100 && $0.score != nil})
        }
        let median=samples.sorted()[samples.count/2]
        return ["scope":"Engine only, excludes UI rendering and persistence","candidates":100,"criteria":20,"reviewers":5,"samples_ms":samples,"median_ms":median,"target_ms":300,"target_met":median<=300]
    }

    static func transferChecks() throws {
        let t=TestHarness.self
        var v=Fixtures.vacancy();try Fixtures.rate(&v,reviewer:0,ratings:[4,3,4]);try Fixtures.rate(&v,reviewer:1,ratings:[5,3,4])
        v.candidates[0].notes="CHECK-PRIVATE-NOTES";v.candidates[0].summary="CHECK-PRIVATE-SUMMARY";v.candidates[0].resumeText="CHECK-PRIVATE-RESUME"
        v.candidates[0].email="private-check@example.test";v.cards[0].comment="CHECK-PRIVATE-INTERVIEW"
        let raw=try CandidateTransfer.encodeVacancy(v),decoded=try CandidateTransfer.decodeVacancy(raw)
        t.check("Vacancy JSON preserves IDs, profiles and assessment history",decoded.id==v.id && decoded.profiles.map(\.id)==v.profiles.map(\.id) && decoded.cards.map(\.id)==v.cards.map(\.id) && decoded.candidates==v.candidates)
        t.check("JSON round-trip preserves score",CandidateEngine.result(decoded,decoded.candidates[0]).score == Decimal(string:"3.95"))
        t.check("JSON round-trip has stable encoded bytes",try CandidateTransfer.encodeVacancy(decoded)==raw)
        t.check("Full JSON intentionally includes private information",String(decoding:raw,as:UTF8.self).contains("CHECK-PRIVATE-NOTES"))
        var object=try JSONSerialization.jsonObject(with:raw) as! [String:Any];object["schemaVersion"]=99
        t.rejects("Transfer rejects future envelope version"){_ = try CandidateTransfer.decodeVacancy(JSONSerialization.data(withJSONObject:object))}
        t.rejects("Transfer rejects missing envelope"){_ = try CandidateTransfer.decodeVacancy(Data("{}".utf8))}
        var broken=v;broken.cards[0].reviewerID=UUID()
        t.rejects("Transfer rejects unknown references before export"){_ = try CandidateTransfer.encodeVacancy(broken)}
        object=try JSONSerialization.jsonObject(with:raw) as! [String:Any]
        var jsonVacancy=object["vacancy"] as! [String:Any];var cards=jsonVacancy["cards"] as! [[String:Any]];cards[0]["reviewerID"]=UUID().uuidString;jsonVacancy["cards"]=cards;object["vacancy"]=jsonVacancy
        t.rejects("Transfer rejects unknown references on import"){_ = try CandidateTransfer.decodeVacancy(JSONSerialization.data(withJSONObject:object))}

        let quoted="\u{feff}name;summary;salary_min;salary_max;currency;basis\r\n\"Иван; Петров\";\"Строка 1\r\nСтрока \"\"2\"\"\";100,50;200,00;RUB;gross\r\n"
        let preview=try CandidateCSV.preview(quoted,decimal:.comma,existing:v.candidates)
        t.check("CSV BOM, quotes, separators and newlines parsed",!preview.hasErrors && preview.rows.count==1 && preview.rows[0].candidate?.name=="Иван; Петров" && preview.rows[0].candidate?.summary=="Строка 1\nСтрока \"2\"")
        t.check("CSV explicit comma decimal normalized",preview.rows[0].candidate?.salaryMin=="100.50" && preview.rows[0].candidate?.salaryMax=="200.00")
        let applied=try CandidateCSV.apply(preview,to:v)
        t.check("CSV new candidate is added after preview",applied.candidates.count==3 && applied.candidates.last?.name=="Иван; Петров")
        t.check("CSV new import preserves existing assessments",applied.cards==v.cards)
        let wrongDecimal=try CandidateCSV.preview(quoted,decimal:.dot,existing:v.candidates)
        t.check("Wrong CSV decimal basis produces row issue",wrongDecimal.hasErrors)
        let mapped=try CandidateCSV.preview("custom;cost;money\nИмя;123.45;RUB\n",mapping:[.name:0,.salaryMin:1,.currency:2])
        t.check("Manual CSV column mapping works",!mapped.hasErrors && mapped.rows[0].candidate?.salaryMin=="123.45")
        let conflict=try CandidateCSV.preview("a;b\nИмя;Текст\n",mapping:[.name:0,.summary:0])
        t.check("Mapping one column twice rejected",conflict.hasErrors)
        let ambiguous=try CandidateCSV.preview("name;ФИО\nИмя;Имя\n")
        t.check("Ambiguous automatic header mapping rejected",ambiguous.hasErrors)
        let noName=try CandidateCSV.preview("email\nalpha@example.test\n")
        t.check("Missing candidate-name mapping identified",noName.hasErrors)
        for malformed in ["name;summary\n\"broken;entry\n","name\nA\"B\n","name\n\"A\"Z\n"] {t.rejects("Malformed CSV quotation rejected"){_ = try CandidateCSV.parse(malformed)}}
        t.rejects("CSV accepts only supported separators"){_ = try CandidateCSV.parse("name|email\nИмя|mail\n",separator:"|")}
        t.rejects("CSV row limit enforced"){_ = try CandidateCSV.parse("name\n"+Array(repeating:"Имя",count:101).joined(separator:"\n"))}
        t.rejects("CSV file bound enforced"){_ = try CandidateCSV.parse("name\n"+String(repeating:"a",count:2*1024*1024))}
        let invalidRows=try CandidateCSV.preview("name;email;source_date;salary_min;salary_max\nИмя;bad;2026-02-30;200;100\n")
        t.check("CSV malformed fields stay in preview",invalidRows.hasErrors && invalidRows.rows[0].issues.count>=1)
        t.rejects("CSV row issues block entire import"){_ = try CandidateCSV.apply(invalidRows,to:Fixtures.vacancy())}

        let duplicateText="name;email;summary\nНовое имя;PRIVATE-CHECK@EXAMPLE.TEST;Обновлённая справка\n"
        let dup=try CandidateCSV.preview(duplicateText,existing:v.candidates)
        t.check("CSV duplicate contact is visible",dup.rows[0].duplicateIDs == [v.candidates[0].id])
        t.rejects("CSV duplicate needs explicit resolution"){_ = try CandidateCSV.apply(dup,to:v)}
        let skipped=try CandidateCSV.apply(dup,to:v,resolutions:[2:CSVResolution(action:.skip)])
        t.check("CSV skip leaves candidate and cards unchanged",skipped.candidates==v.candidates && skipped.cards==v.cards)
        let separate=try CandidateCSV.apply(dup,to:v,resolutions:[2:CSVResolution(action:.separate)])
        t.check("CSV separate assigns fresh identity",separate.candidates.count==3 && separate.candidates.last?.id != v.candidates[0].id)
        let updated=try CandidateCSV.apply(dup,to:v,resolutions:[2:CSVResolution(action:.update,targetID:v.candidates[0].id,fields:[.summary])])
        t.check("CSV update touches only selected mapped fields",updated.candidates[0].summary=="Обновлённая справка" && updated.candidates[0].name==v.candidates[0].name && updated.candidates[0].email==v.candidates[0].email && updated.candidates[0].notes==v.candidates[0].notes)
        t.check("CSV update preserves submitted cards and private lifecycle",updated.cards==v.cards && updated.candidates[0].checks==v.candidates[0].checks && updated.candidates[0].decisions==v.candidates[0].decisions)
        t.rejects("CSV update cannot target unrelated person"){_ = try CandidateCSV.apply(dup,to:v,resolutions:[2:CSVResolution(action:.update,targetID:v.candidates[1].id,fields:[.name])])}
        var stale=v;stale.candidates[0].name="Изменилось после предпросмотра"
        t.rejects("Stale CSV snapshot cannot overwrite new edits"){_ = try CandidateCSV.apply(dup,to:stale,resolutions:[2:CSVResolution(action:.skip)])}
        let sameName=try CandidateCSV.preview("name\nКандидат А\n",existing:v.candidates)
        t.check("CSV does not deduplicate by name",sameName.rows[0].duplicateIDs.isEmpty)
        let internalDup=try CandidateCSV.preview("name;email\nПервый;x@example.test\nВторой;x@example.test\n")
        t.check("CSV duplicate inside input identified",internalDup.rows[1].duplicateLines == [2])
        var empty=v;empty.candidates=[];empty.cards=[]
        t.rejects("Within-file duplicate needs explicit resolution"){_ = try CandidateCSV.apply(internalDup,to:empty)}
        let kept=try CandidateCSV.apply(internalDup,to:empty,resolutions:[3:CSVResolution(action:.separate)])
        t.check("Within-file separate keeps distinct IDs",kept.candidates.count==2 && kept.candidates[0].id != kept.candidates[1].id)
        let knownID=try CandidateCSV.preview("id;name\n\(v.candidates[0].id.uuidString);Другое имя\n",existing:v.candidates)
        t.check("Known ID is a duplicate even without contacts",knownID.rows[0].duplicateIDs == [v.candidates[0].id])

        let ids=[v.candidates[0].id]
        let report=try CandidateTransfer.reportCSV(v,candidateIDs:ids)
        let csv=String(decoding:report,as:UTF8.self)
        t.check("Default CSV excludes contacts and long private materials",!["private-check@example.test","CHECK-PRIVATE-NOTES","CHECK-PRIVATE-SUMMARY","CHECK-PRIVATE-RESUME","CHECK-PRIVATE-INTERVIEW"].contains(where:csv.contains))
        t.check("CSV includes score, profile and uncertainty labels",csv.contains("3,95") && csv.contains("Полнота оценок") && csv.contains("Не проверено"))
        t.check("CSV includes only selected candidate",!csv.contains("Кандидат Б"))
        let completeCSV=String(decoding:try CandidateTransfer.reportCSV(v,candidateIDs:ids,includeContacts:true,includeNotes:true),as:UTF8.self)
        t.check("Explicit report options include requested private content",completeCSV.contains("private-check@example.test") && completeCSV.contains("CHECK-PRIVATE-NOTES") && completeCSV.contains("CHECK-PRIVATE-INTERVIEW"))
        for input in ["=2+2","+SUM(A1)","-2+3","@SUM(A1)","  =cmd()","\tcmd"] {t.check("Formula CSV cell neutralized",CandidateTransfer.csvCell(input).hasPrefix("\"'"))}
        t.check("CSV quotes escaped",CandidateTransfer.csvCell("Иван \"текст\"")=="\"Иван \"\"текст\"\"\"")
        t.rejects("Report rejects empty selection"){_ = try CandidateTransfer.reportCSV(v,candidateIDs:[])}
        t.rejects("Report rejects duplicate IDs"){_ = try CandidateTransfer.reportPDF(v,candidateIDs:[ids[0],ids[0]])}
        t.rejects("Report rejects vanished candidate ID"){_ = try CandidateTransfer.reportCSV(v,candidateIDs:[UUID()])}
        let pdf=try CandidateTransfer.reportPDF(v,candidateIDs:ids)
        let doc=PDFDocument(data:pdf),pdfText=doc?.string ?? ""
        t.check("Native PDF is readable with Cyrillic",(doc?.pageCount ?? 0)>0 && pdfText.contains("Сравнение кандидатов") && pdfText.contains("Кандидат А"))
        t.check("PDF score matches native calculation",pdfText.contains("3,95"))
        t.check("Default PDF excludes private markers",!["private-check@example.test","CHECK-PRIVATE-NOTES","CHECK-PRIVATE-RESUME","CHECK-PRIVATE-INTERVIEW"].contains(where:pdfText.contains))
        try pdf.write(to:URL(fileURLWithPath:"Verification/fixture-default-report.pdf"))
        try report.write(to:URL(fileURLWithPath:"Verification/fixture-default-report.csv"))
        var long=v;long.candidates[0].notes=String(repeating:"Развёрнутое описание профессиональной ситуации и наблюдений интервьюера. ",count:180)+" CHECK-PDF-TAIL"
        let longPDF=try CandidateTransfer.reportPDF(long,candidateIDs:ids,includeNotes:true),longDoc=PDFDocument(data:longPDF)
        t.check("Long PDF paginates without losing tail",(longDoc?.pageCount ?? 0)>1 && (longDoc?.string ?? "").contains("CHECK-PDF-TAIL"))
        t.check("Every PDF page repeats document heading",(0..<(longDoc?.pageCount ?? 0)).allSatisfy {longDoc?.page(at:$0)?.string?.contains("Сравнение кандидатов") == true})
        try longPDF.write(to:URL(fileURLWithPath:"Verification/fixture-long-report.pdf"))
        var incomplete=Fixtures.vacancy();try Fixtures.rate(&incomplete,reviewer:0,ratings:[4,3,4])
        let partial=String(decoding:try CandidateTransfer.reportCSV(incomplete,candidateIDs:[incomplete.candidates[0].id]),as:UTF8.self)
        t.check("Incomplete report states missing final score",partial.contains("Оценка не завершена") && partial.contains("50,00%"))
    }
}
