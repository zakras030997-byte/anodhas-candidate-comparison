import Foundation
import SwiftUI
import AppKit
import UniformTypeIdentifiers

enum EditorKind: String, Codable { case vacancy, candidate, scorecard }
struct EditorDraft: Codable, Equatable {
    var schemaVersion = 1
    var kind: EditorKind
    var vacancyID: UUID?
    var payload: Data
    var savedAt = Date()
}
struct CandidateEditorState: Codable, Equatable {
    var candidate: Candidate
    var decisionStatus: CandidateStatus
    var decisionAuthor = ""
    var decisionReason = ""
    init(_ candidate:Candidate) {self.candidate=candidate;decisionStatus=candidate.status}
}
enum ReportKind: String, CaseIterable, Identifiable {
    case pdf = "PDF", csv = "CSV", json = "JSON"
    var id: String { rawValue }
    var ext: String { rawValue.lowercased() }
    var type: UTType { switch self { case .pdf:return .pdf;case .csv:return .commaSeparatedText;case .json:return .json } }
}

@MainActor final class CandidateStore: ObservableObject {
    @Published private(set) var data = Workspace()
    @Published private(set) var blocked = false
    @Published private(set) var saved = ""
    @Published var error = ""
    @Published private(set) var editorDraft: EditorDraft?
    @Published private(set) var draftReadError = false
    private let disk: WorkspaceDisk
    private let lock: WorkspaceLock
    private let draftURL: URL
    private var lockHeld = false
    private var retainedOpenPanel: NSOpenPanel?
    private var retainedSavePanel: NSSavePanel?

    init(folder: URL? = nil) {
        let directory = folder ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("ANODHAS Candidate Comparison", isDirectory: true)
        disk = WorkspaceDisk(url: directory.appendingPathComponent("workspace-v1.json"))
        draftURL = directory.appendingPathComponent("editor-draft-v1.json")
        lock = WorkspaceLock(url: directory.appendingPathComponent("workspace-v1.json.lock"))
        do { try lock.acquire(); lockHeld = true; data = try disk.load(); saved = "Сохранено на Mac"; loadDraft() }
        catch { blocked = true; self.error = "Рабочее пространство не открыто для записи. Исходный файл сохранён. \(error.localizedDescription)" }
    }
    deinit { lock.release() }
    var current: Vacancy? { data.vacancies.first { $0.id == data.selectedVacancyID } }
    var dataPath: String { disk.url.path }
    var canRecover: Bool { lockHeld && disk.canRecover }
    var canUndo: Bool { false }
    var canRedo: Bool { false }

    @discardableResult private func commit(_ next: Workspace, undo: Bool = true, purge: Bool = false) -> Bool {
        guard !blocked, lockHeld else { return false }
        do {
            try CandidateEngine.validateWorkspace(next)
            try validateHistory(next,purge:purge)
            if purge { try removeDraftFile() }; try disk.save(next, purgingBackup: purge)
            if purge { editorDraft=nil;draftReadError=false }
            data = next; saved = "Сохранено на Mac"; return true
        } catch { self.error = "Изменения не записаны. Открытый ввод сохранён в черновике, исходный файл не заменён. \(error.localizedDescription)"; saved = "Не удалось сохранить"; return false }
    }
    private func canonicalEqual<T:Encodable>(_ lhs:T,_ rhs:T) throws -> Bool {let e=JSONEncoder();e.dateEncodingStrategy = .iso8601;e.outputFormatting = [.sortedKeys];return try e.encode(lhs)==e.encode(rhs)}
    private func validateHistory(_ next:Workspace,purge:Bool) throws {
        for old in data.vacancies {
            guard let replacement=next.vacancies.first(where:{$0.id==old.id}) else {if !purge {throw AppError("Удаление вакансии требует очистки резервной копии.")};continue}
            for profile in old.profiles where profile.locked {guard let same=replacement.profiles.first(where:{$0.id==profile.id}),try canonicalEqual(same,profile) else {throw AppError("Зафиксированную версию нельзя изменить или удалить. Создайте новую версию.")}}
            for card in old.cards where card.submittedAt != nil {
                if !replacement.candidates.contains(where:{$0.id==card.candidateID}) && purge {continue}
                guard let same=replacement.cards.first(where:{$0.id==card.id}),try canonicalEqual(same,card) else {throw AppError("Отправленную оценку нельзя перезаписать. Создайте новую редакцию.")}
            }
            for candidate in old.candidates {
                guard let changed=replacement.candidates.first(where:{$0.id==candidate.id}) else {if !purge {throw AppError("Удаление кандидата требует очистки резервной копии.")};continue}
                guard changed.decisions.count>=candidate.decisions.count,try canonicalEqual(Array(changed.decisions.prefix(candidate.decisions.count)),candidate.decisions) else {throw AppError("Историю решений нельзя переписать. Запишите новое решение.")}
            }
        }
    }
    @discardableResult func flush() -> Bool {
        guard !blocked, lockHeld else { return false }
        do { try disk.save(data); saved = "Сохранено на Mac"; return true }
        catch { self.error = "Не удалось сохранить: \(error.localizedDescription)"; return false }
    }
    func recover() {
        guard lockHeld else { error = "Другая копия программы использует файл. Закройте её и откройте эту программу заново."; return }
        do { data = try disk.recover(); blocked = false; saved = "Восстановлена резервная копия"; loadDraft() }
        catch { self.error = "Восстановление не выполнено: \(error.localizedDescription)" }
    }
    func select(_ id: UUID) { var w=data; w.selectedVacancyID=id; _=commit(w,undo:false) }
    func selectProfile(_ id: UUID) { mutate { v in guard v.profiles.contains(where: {$0.id == id}) else { return }; v.selectedProfileID=id } }
    @discardableResult func mutate(_ edit: (inout Vacancy) throws -> Void, purge: Bool = false) -> Bool {
        guard let id=data.selectedVacancyID,let i=data.vacancies.firstIndex(where: {$0.id==id}) else { return false }
        var w=data
        do { try edit(&w.vacancies[i]); w.vacancies[i].updatedAt=Date(); return commit(w,purge:purge) }
        catch { self.error=error.localizedDescription; return false }
    }
    @discardableResult func saveVacancy(_ value: Vacancy) -> Bool {
        var w=data;var v=value;v.updatedAt=Date()
        if let i=w.vacancies.firstIndex(where: {$0.id==v.id}) { w.vacancies[i]=v }
        else { guard w.vacancies.count<100 else {error="Доступно до 100 вакансий.";return false};w.vacancies.append(v) }
        w.selectedVacancyID=v.id
        let ok=commit(w);if ok {discardDraft()};return ok
    }
    @discardableResult func saveCandidate(_ c: Candidate, allowDuplicate: Bool = false) -> Bool {
        guard let v=current else { return false }
        do { try CandidateEngine.validateCandidate(c) } catch {self.error=error.localizedDescription;return false}
        let duplicates=CandidateEngine.duplicates(c,in:v.candidates)
        if !allowDuplicate && !duplicates.isEmpty { error="Есть кандидат с таким email или телефоном. Проверьте дубль или сохраните отдельную заявку явной кнопкой.";return false }
        let ok=mutate { v in if let i=v.candidates.firstIndex(where: {$0.id==c.id}) {v.candidates[i]=c} else {guard v.candidates.count<100 else {throw AppError("Доступно до 100 кандидатов на вакансию.")};v.candidates.append(c)} }
        if ok {discardDraft()};return ok
    }
    @discardableResult func saveScorecard(_ card: Scorecard, submit: Bool) -> Bool {
        let ok=mutate { try CandidateEngine.saveCard(card,in:&$0,submit:submit) }
        if ok {discardDraft()};return ok
    }
    func newVersion() { _=mutate { try CandidateEngine.newVersion(&$0) } }
    func deleteCandidate(_ id: UUID) { _=mutate({ v in v.candidates.removeAll {$0.id==id};v.cards.removeAll {$0.candidateID==id} },purge:true) }
    func deleteVacancy(_ id: UUID) { var w=data;w.vacancies.removeAll {$0.id==id};if w.selectedVacancyID==id {w.selectedVacancyID=w.vacancies.first?.id};_=commit(w,purge:true) }
    func undo() {}
    func redo() {}
    func revealData() { NSWorkspace.shared.activateFileViewerSelecting([disk.url]) }

    func saveEditor<T: Encodable>(_ value:T, kind:EditorKind,vacancyID:UUID?) {
        guard lockHeld,!blocked,!draftReadError else{return}
        do {
            let encoder=JSONEncoder();encoder.dateEncodingStrategy = .iso8601
            let payload=try encoder.encode(value);guard payload.count<=16*1024*1024 else {throw AppError("Черновик больше 16 МБ.")}
            let draft=EditorDraft(kind:kind,vacancyID:vacancyID,payload:payload)
            try FileManager.default.createDirectory(at:draftURL.deletingLastPathComponent(),withIntermediateDirectories:true)
            try encoder.encode(draft).write(to:draftURL,options:.atomic);try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:draftURL.path);editorDraft=draft
        } catch {self.error="Не удалось сохранить незавершённый ввод: \(error.localizedDescription)"}
    }
    func decodeDraft<T:Decodable>(_ type:T.Type) -> T? {
        guard let d=editorDraft else{return nil};let decoder=JSONDecoder();decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(type,from:d.payload)
    }
    private func loadDraft() {
        guard FileManager.default.fileExists(atPath:draftURL.path) else{return}
        do {
            let raw=try WorkspaceDisk.read(draftURL,limit:24*1024*1024)
            let decoder=JSONDecoder();decoder.dateDecodingStrategy = .iso8601
            let d=try decoder.decode(EditorDraft.self,from:raw);guard d.schemaVersion==1 else{throw AppError("Неизвестная версия черновика.")}
            if let id=d.vacancyID {guard data.vacancies.contains(where: {$0.id==id}) else {throw AppError("Вакансия черновика больше не существует.")}}
            editorDraft=d
        } catch {draftReadError=true;self.error="Незавершённый ввод не прочитан. Файл сохранён; можно явно отбросить его. \(error.localizedDescription)"}
    }
    func discardDraft() {
        guard lockHeld else{return}
        do {try removeDraftFile();editorDraft=nil;draftReadError=false}
        catch {self.error="Не удалось удалить черновик: \(error.localizedDescription)"}
    }

    private func removeDraftFile() throws { if FileManager.default.fileExists(atPath:draftURL.path) {try FileManager.default.removeItem(at:draftURL)} }
    func chooseCSV(_ completion:@escaping (String)->Void) {
        let panel=NSOpenPanel();panel.allowedContentTypes=[.commaSeparatedText,.plainText];panel.allowsMultipleSelection=false;panel.message="Выберите CSV со сведениями о кандидатах";retainedOpenPanel=panel
        panel.begin { [weak self] response in defer {self?.retainedOpenPanel=nil};guard response == .OK,let url=panel.url else{return};do {let raw=try WorkspaceDisk.read(url,limit:2*1024*1024);guard let text=String(data:raw,encoding:.utf8) else{throw AppError("Нужен CSV UTF-8 размером до 2 МБ.")};completion(text)}catch {self?.error=error.localizedDescription} }
    }
    func openJSON() {
        let panel=NSOpenPanel();panel.allowedContentTypes=[.json];panel.allowsMultipleSelection=false;panel.message="Открыть отдельную копию вакансии. Текущие данные не будут заменены.";retainedOpenPanel=panel
        panel.begin { [weak self] response in defer {self?.retainedOpenPanel=nil};guard response == .OK,let url=panel.url,let self else{return};do {let raw=try WorkspaceDisk.read(url);let v=try CandidateTransfer.decodeVacancy(raw);let alert=NSAlert();alert.messageText="Открыть «\(v.title)» отдельной копией?";alert.informativeText="Кандидатов: \(v.candidates.count). Версий: \(v.profiles.count). Карточек: \(v.cards.count). Файл содержит персональные сведения, оценки и историю. Текущие вакансии сохранятся.";alert.addButton(withTitle:"Открыть отдельно");alert.addButton(withTitle:"Отмена");guard alert.runModal() == .alertFirstButtonReturn else{return};var copy=v;copy.id=UUID();copy.title += " · импорт";_=self.saveVacancy(copy)}catch {self.error=error.localizedDescription} }
    }
    @discardableResult func applyCSV(_ preview:CandidateCSVPreview,resolutions:[Int:CSVResolution]) -> Bool {
        guard let v=current else{return false}
        do {return saveVacancy(try CandidateCSV.apply(preview,to:v,resolutions:resolutions))}catch {self.error=error.localizedDescription;return false}
    }
    func export(_ kind:ReportKind,candidateIDs:[UUID],contacts:Bool,notes:Bool) {
        guard let v=current else{return}
        do {
            let ids=candidateIDs.isEmpty ? v.candidates.map(\.id) : candidateIDs
            let bytes:Data
            switch kind {case .json:bytes=try CandidateTransfer.encodeVacancy(v);case .csv:bytes=try CandidateTransfer.reportCSV(v,candidateIDs:ids,includeContacts:contacts,includeNotes:notes);case .pdf:bytes=try CandidateTransfer.reportPDF(v,candidateIDs:ids,includeContacts:contacts,includeNotes:notes)}
            saveFile(bytes,name:"Сравнение кандидатов.\(kind.ext)",type:kind.type)
        }catch {self.error=error.localizedDescription}
    }
    func saveFile(_ bytes:Data,name:String,type:UTType) {
        let panel=NSSavePanel();panel.allowedContentTypes=[type];panel.nameFieldStringValue=name;retainedSavePanel=panel
        panel.begin { [weak self] response in defer{self?.retainedSavePanel=nil};guard response == .OK,let url=panel.url else{return};do {try bytes.write(to:url,options:.atomic);self?.saved="Файл сохранён: \(url.lastPathComponent)"}catch {self?.error=error.localizedDescription} }
    }
    func example() {
        var v=Vacancy();v.title="Менеджер по работе с клиентами · пример";v.tasks="Вести заявки и готовить коммерческие предложения";v.budgetMax="120000";v.basis = .gross
        var p=v.profile
        let names=["Работа с запросом","Подготовка предложения","Организация задач"]
        p.criteria=names.enumerated().map { index,name in Criterion(name:name,outcome:"Самостоятельно выполняет задачу: \(name.lowercased())",weight:[50,30,20][index],stageID:p.stages[0].id,reviewerIDs:[p.reviewers[0].id],questions:"Приведите конкретный пример из вашей работы.") };p.locked=true;v.profiles=[p];v.selectedProfileID=p.id
        for (name,ratings) in [("Кандидат А",[4,3,4]),("Кандидат Б",[3,4,4])] {
            var c=Candidate();c.name=name;c.summary="Пример профессиональных сведений для знакомства с программой";c.basis = .gross;c.salaryMin="100000";v.candidates.append(c)
            var card=Scorecard(candidateID:c.id,profileID:p.id,stageID:p.stages[0].id,reviewerID:p.reviewers[0].id,assessments:zip(p.criteria,ratings).map {Assessment(criterionID:$0.0.id,rating:$0.1,evidence:"Обсуждён пример выполненной рабочей задачи")},recommendation:.discuss,comment:"Уточнить рабочие условия на следующем этапе")
            card.submittedAt=Date();v.cards.append(card)
        }
        _=saveVacancy(v)
    }
}
