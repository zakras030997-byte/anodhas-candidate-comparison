import SwiftUI
import AppKit

@MainActor final class CandidateAppDelegate: NSObject, NSApplicationDelegate {
    static weak var store: CandidateStore?
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let store=Self.store,!store.blocked else{return .terminateNow}
        if store.flush() {return .terminateNow}
        let alert=NSAlert();alert.messageText="Изменения не сохранены";alert.informativeText="Останьтесь в программе, повторите сохранение или экспортируйте данные.";alert.addButton(withTitle:"Остаться");alert.addButton(withTitle:"Выйти без сохранения")
        return alert.runModal() == .alertSecondButtonReturn ? .terminateNow : .terminateCancel
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {true}
}
@main struct CandidateComparisonApp: App {
    @NSApplicationDelegateAdaptor(CandidateAppDelegate.self) private var delegate
    @StateObject private var store=CandidateStore()
    var body: some Scene {
        WindowGroup {CandidateRoot(store:store).frame(minWidth:1050,minHeight:700).onAppear {CandidateAppDelegate.store=store}}
        .defaultSize(width:1220,height:800)
        .commands {CommandGroup(replacing:.newItem) {}}
    }
}
private enum MainTab: String, CaseIterable, Identifiable {case vacancy="Вакансия",candidates="Кандидаты",assessments="Оценки",comparison="Сравнение";var id:String {rawValue}}
private enum EditorSheet: Identifiable {
    case vacancy(Vacancy),candidate(CandidateEditorState),card(Scorecard),csv(String),report
    var id:String {switch self {case .vacancy(let v):return "v"+v.id.uuidString;case .candidate(let c):return "c"+c.candidate.id.uuidString;case .card(let c):return "s"+c.id.uuidString;case .csv:return "csv";case .report:return "report"}}
}
private struct CandidateRoot: View {
    @ObservedObject var store:CandidateStore
    @State private var tab:MainTab = .vacancy
    @State private var sheet:EditorSheet?
    @State private var selected=Set<UUID>()
    @State private var deletingCandidate:Candidate?
    @State private var deletingVacancy:Vacancy?
    @State private var stageID:UUID?
    @State private var reviewerID:UUID?
    @State private var assessingCandidateID:UUID?
    var body:some View {
        NavigationSplitView {
            VStack(alignment:.leading,spacing:12) {
                Label("Сравнение кандидатов",systemImage:"person.2.square.stack").font(.headline).padding(.horizontal)
                List(selection:Binding(get:{store.data.selectedVacancyID},set:{if let id=$0 {store.select(id)}})) {
                    ForEach(store.data.vacancies) {v in VStack(alignment:.leading,spacing:4) {Text(v.title).lineLimit(2);Text("\(v.candidates.count) кандидатов · версия \(v.profile.number)").font(.caption).foregroundStyle(.secondary)}.tag(v.id).contextMenu {Button("Удалить вакансию…",role:.destructive) {deletingVacancy=v}} }
                }.listStyle(.sidebar)
                Button {sheet = .vacancy(Vacancy())} label:{Label("Новая вакансия",systemImage:"plus")}.buttonStyle(.borderedProminent).padding(.horizontal).disabled(store.blocked || store.editorDraft != nil || store.draftReadError)
                Text("Оценки помогают обсуждать факты. Решение о найме принимаете вы.").font(.caption).foregroundStyle(.secondary).padding()
            }.padding(.top,16).navigationSplitViewColumnWidth(min:230,ideal:260,max:320)
        } detail: {
            VStack(spacing:0) {
                if store.blocked {blockedView}
                else {
                    if store.editorDraft != nil || store.draftReadError {
                        HStack {Label(store.draftReadError ? "Есть непрочитанный файл черновика" : "Есть незавершённый ввод",systemImage:"doc.badge.clock");Spacer();if !store.draftReadError {Button("Восстановить ввод") {restoreDraft()}};Button("Отбросить черновик") {store.discardDraft()}}.font(.callout).padding(12).background(Color.orange.opacity(0.1))
                    }
                    if let v=store.current {
                        header(v).disabled(store.editorDraft != nil || store.draftReadError)
                        Picker("Раздел",selection:$tab) {ForEach(MainTab.allCases){Text($0.rawValue).tag($0)}}.pickerStyle(.segmented).padding(.horizontal,24).padding(.bottom,16)
                        Divider()
                        Group {switch tab {case .vacancy:VacancyOverview(vacancy:v,edit:{sheet = .vacancy(v)},newVersion:{store.newVersion()},selectVersion:{store.selectProfile($0)})
                        case .candidates:CandidateList(vacancy:v,selected:$selected,edit:{sheet = .candidate(CandidateEditorState($0))},add:{var c=Candidate();c.currency=v.currency;c.basis=v.basis;sheet = .candidate(CandidateEditorState(c))},delete:{deletingCandidate=$0})
                        case .assessments:assessmentView(v)
                        case .comparison:ComparisonView(vacancy:v,selected:$selected)}}.frame(maxWidth:.infinity,maxHeight:.infinity).disabled(store.editorDraft != nil || store.draftReadError)
                    } else {emptyView.disabled(store.editorDraft != nil || store.draftReadError)}
                }
                Divider();HStack {Image(systemName:store.blocked ? "exclamationmark.triangle" : "internaldrive");Text(store.saved.isEmpty ? "Локальная программа" : store.saved);Spacer();Button("Повторить сохранение") {_=store.flush()}.disabled(store.blocked || store.editorDraft != nil || store.draftReadError);Button("Папка данных") {store.revealData()}}.font(.caption).padding(10).foregroundStyle(.secondary)
            }
            .toolbar {ToolbarItemGroup {Button("Открыть JSON") {store.openJSON()}.disabled(store.blocked || store.editorDraft != nil || store.draftReadError);Button("Пример") {store.example();tab = .comparison}.disabled(store.blocked || store.editorDraft != nil || store.draftReadError);if store.current != nil {Button("Импорт CSV") {store.chooseCSV {sheet = .csv($0)}}.disabled(store.blocked || store.editorDraft != nil || store.draftReadError);Button("Экспорт") {sheet = .report}.disabled(store.blocked || store.editorDraft != nil || store.draftReadError)}}}
        }
        .sheet(item:$sheet) {s in switch s {
            case .vacancy(let v):VacancyEditor(store:store,initial:v).candidateErrors(store)
            case .candidate(let c):if let v=store.current {CandidateEditor(store:store,initial:c.candidate,vacancy:v,recovery:c).candidateErrors(store)}
            case .card(let c):if let v=store.current {ScorecardEditor(store:store,initial:c,vacancy:v).candidateErrors(store)}
            case .csv(let text):CandidateImportView(store:store,source:text).candidateErrors(store)
            case .report:ReportSheet(store:store,selected:Array(selected)).candidateErrors(store)
        }}
        .alert("Не удалось выполнить действие",isPresented:Binding(get:{sheet?.id == nil && !store.error.isEmpty},set:{if !$0 && sheet?.id == nil {store.error=""}})) {Button("Понятно") {store.error=""}} message:{Text(store.error)}
        .confirmationDialog("Удалить кандидата и все его оценки?",isPresented:Binding(get:{deletingCandidate != nil},set:{if !$0 {deletingCandidate=nil}}),titleVisibility:.visible) {Button("Удалить кандидата",role:.destructive) {if let c=deletingCandidate {selected.remove(c.id);store.deleteCandidate(c.id)};deletingCandidate=nil};Button("Отмена",role:.cancel) {deletingCandidate=nil}} message:{Text("\(deletingCandidate?.name ?? "Кандидат"): профиль, оценки, решения и черновик будут удалены из рабочего файла и автоматической резервной копии. Ранее экспортированные файлы останутся у вас.")}
        .confirmationDialog("Удалить вакансию целиком?",isPresented:Binding(get:{deletingVacancy != nil},set:{if !$0 {deletingVacancy=nil}}),titleVisibility:.visible) {Button("Удалить вакансию",role:.destructive) {if let v=deletingVacancy {store.deleteVacancy(v.id)};selected.removeAll();deletingVacancy=nil};Button("Отмена",role:.cancel) {deletingVacancy=nil}} message:{Text("Будут удалены вакансия «\(deletingVacancy?.title ?? "")», все версии, \(deletingVacancy?.candidates.count ?? 0) кандидатов и их оценки из рабочего файла и автоматической копии. Экспорты не удаляются.")}
        .onChange(of:store.data.selectedVacancyID) {_ in selected.removeAll();stageID=nil;reviewerID=nil;assessingCandidateID=nil}
    }
    private var emptyView:some View {VStack(spacing:18) {Image(systemName:"person.2.square.stack").font(.system(size:52)).foregroundStyle(.tint);Text("Сравните кандидатов по общим критериям").font(.title2.bold());Text("Начните с вакансии: определите рабочие задачи, вопросы и понятную шкалу оценки.").foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth:490);Button("Создать вакансию") {sheet = .vacancy(Vacancy())}.buttonStyle(.borderedProminent);Button("Посмотреть пример") {store.example();tab = .comparison}}.frame(maxWidth:.infinity,maxHeight:.infinity).disabled(store.editorDraft != nil || store.draftReadError)}
    private var blockedView:some View {VStack(spacing:14) {Image(systemName:"lock.doc").font(.largeTitle);Text("Рабочий файл не открыт для записи").font(.title2);Text("Повреждённый файл и неизвестная версия сохраняются без изменений. Если файл занят другой копией программы, закройте её и запустите эту программу заново.").frame(maxWidth:550).multilineTextAlignment(.center);if store.canRecover {Button("Восстановить предыдущую копию") {store.recover()}};Button("Открыть папку данных") {store.revealData()}}.padding(30).frame(maxWidth:.infinity,maxHeight:.infinity)}
    private func header(_ v:Vacancy)->some View {HStack(alignment:.top) {VStack(alignment:.leading,spacing:6) {Text(v.title).font(.title2.bold());Text("\(v.candidates.count) кандидатов · версия \(v.profile.number) · \(v.profile.locked ? "профиль зафиксирован" : "черновик профиля")").foregroundStyle(.secondary)};Spacer();Button("Настроить вакансию") {sheet = .vacancy(v)}}.padding(24)}
    private func assessmentView(_ v:Vacancy)->some View {
        ScrollView {VStack(alignment:.leading,spacing:18) {
            Text("Одна карточка на интервьюера и этап").font(.title3.bold())
            Text("Сначала заполните собственные наблюдения. В режиме интервью сводка коллег появится после отправки вашей карточки. Это порядок работы на одном Mac, не разграничение доступа.").foregroundStyle(.secondary)
            if !v.profile.locked {Text("Сначала зафиксируйте профиль вакансии.").foregroundStyle(.orange);Button("Настроить профиль") {sheet = .vacancy(v)}}
            else {
                Picker("Кандидат",selection:Binding(get:{assessingCandidateID ?? v.candidates.first?.id},set:{assessingCandidateID=$0})) {ForEach(v.candidates) {Text($0.name).tag(Optional($0.id))}}
                Picker("Этап",selection:Binding(get:{stageID ?? v.profile.stages.first?.id},set:{stageID=$0})) {ForEach(v.profile.stages) {Text($0.name).tag(Optional($0.id))}}
                Picker("Интервьюер",selection:Binding(get:{reviewerID ?? v.profile.reviewers.first?.id},set:{reviewerID=$0})) {ForEach(v.profile.reviewers) {Text($0.name).tag(Optional($0.id))}}
                Button("Открыть карточку оценки") {openCard(v)}.buttonStyle(.borderedProminent).disabled(v.candidates.isEmpty)
                Divider();Text("Сохранённые карточки").font(.headline)
                ForEach(v.cards.filter {$0.profileID==v.profile.id}.sorted {$0.createdAt>$1.createdAt}) {card in HStack {VStack(alignment:.leading) {Text(v.candidates.first {$0.id==card.candidateID}?.name ?? "Кандидат");Text("\(v.profile.reviewers.first {$0.id==card.reviewerID}?.name ?? "") · \(v.profile.stages.first {$0.id==card.stageID}?.name ?? "") · редакция \(card.revision)").font(.caption).foregroundStyle(.secondary)};Spacer();Text(card.submittedAt == nil ? "Черновик" : "Отправлена").foregroundStyle(card.submittedAt == nil ? .orange : .secondary)}.padding(10).background(Color.primary.opacity(0.035)).cornerRadius(8)}
            }
        }.padding(24).frame(maxWidth:850,alignment:.leading)}
    }
    private func openCard(_ v:Vacancy) {guard let c=assessingCandidateID ?? v.candidates.first?.id,let s=stageID ?? v.profile.stages.first?.id,let r=reviewerID ?? v.profile.reviewers.first?.id else{return};do {sheet = .card(try CandidateEngine.draft(v,candidateID:c,stageID:s,reviewerID:r))}catch {store.error=error.localizedDescription}}
    private func restoreDraft() {
        guard let d=store.editorDraft else{return};if let id=d.vacancyID {store.select(id)}
        switch d.kind {case .vacancy:if let v=store.decodeDraft(Vacancy.self) {sheet = .vacancy(v)}else{store.error="Черновик вакансии не прочитан."}
        case .candidate:if let c=store.decodeDraft(CandidateEditorState.self) {sheet = .candidate(c)}else if let c=store.decodeDraft(Candidate.self) {sheet = .candidate(CandidateEditorState(c))}else{store.error="Черновик кандидата не прочитан."}
        case .scorecard:if let c=store.decodeDraft(Scorecard.self),store.current?.candidates.contains(where:{$0.id==c.candidateID})==true {sheet = .card(c)}else{store.error="Черновик оценки относится к неизвестному кандидату."}}
    }
}

private struct VacancyOverview:View {
    let vacancy:Vacancy;let edit:()->Void;let newVersion:()->Void;let selectVersion:(UUID)->Void
    var body:some View {ScrollView {VStack(alignment:.leading,spacing:20) {
        HStack {Text("Профиль оценки").font(.title3.bold());Spacer();Picker("Версия",selection:Binding(get:{vacancy.profile.id},set:selectVersion)) {ForEach(vacancy.profiles) {Text("Версия \($0.number)\($0.locked ? "" : " · черновик")").tag($0.id)}}.frame(width:230);if vacancy.profile.locked {Button("Новая версия") {newVersion()}}}
        Text(vacancy.tasks.isEmpty ? "Добавьте задачи и ожидаемые результаты работы." : vacancy.tasks).foregroundStyle(.secondary)
        HStack(spacing:20) {Metric(title:"Критериев",value:"\(vacancy.profile.criteria.count)");Metric(title:"Этапов",value:"\(vacancy.profile.stages.count)");Metric(title:"Интервьюеров",value:"\(vacancy.profile.reviewers.count)")}
        let total=vacancy.profile.criteria.reduce(0){$0+$1.weight}
        ForEach(vacancy.profile.criteria) {c in VStack(alignment:.leading,spacing:7) {HStack {Text(c.name.isEmpty ? "Критерий без названия" : c.name).font(.headline);Spacer();Text("\(total>0 ? NumberText.display(100*Decimal(c.weight)/Decimal(total),digits:2) : "0")% важности").font(.caption).foregroundStyle(.secondary)};Text(c.outcome).foregroundStyle(.secondary);Text(c.questions).font(.callout)}.padding(16).frame(maxWidth:.infinity,alignment:.leading).background(Color.primary.opacity(0.035)).cornerRadius(10)}
        if !vacancy.profile.requirements.isEmpty {Text("Обязательные требования").font(.headline);ForEach(vacancy.profile.requirements){Text("• \($0.title)")}}
        if !vacancy.profile.locked {Button("Настроить и зафиксировать профиль",action:edit).buttonStyle(.borderedProminent)}
        Text("Изменение зафиксированных критериев создаёт новую версию. Старые оценки сохраняются отдельно, новые карточки начинаются без баллов.").font(.caption).foregroundStyle(.secondary)
    }.padding(24)}}
}
private struct Metric:View {let title:String;let value:String;var body:some View {VStack(alignment:.leading,spacing:6){Text(value).font(.title2.bold()).monospacedDigit();Text(title).font(.caption).foregroundStyle(.secondary)}.padding(16).frame(maxWidth:.infinity,alignment:.leading).background(Color.accentColor.opacity(0.08)).cornerRadius(10)}}

private struct CandidateList:View {
    let vacancy:Vacancy;@Binding var selected:Set<UUID>;let edit:(Candidate)->Void;let add:()->Void;let delete:(Candidate)->Void
    @State private var search="";@State private var sortScore=false
    private var candidates:[Candidate] {let list=vacancy.candidates.filter {search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) || $0.summary.localizedCaseInsensitiveContains(search)};return list.sorted {a,b in if sortScore {let x=CandidateEngine.result(vacancy,a).score,y=CandidateEngine.result(vacancy,b).score;if let x,let y,x != y {return x>y};if (x != nil) != (y != nil) {return x != nil}};return a.name.localizedStandardCompare(b.name) == .orderedAscending}}
    var body:some View {VStack(alignment:.leading,spacing:12) {
        HStack {TextField("Поиск по имени и профессиональной справке",text:$search).textFieldStyle(.roundedBorder);Toggle("По баллу",isOn:$sortScore).toggleStyle(.checkbox);Menu("Редактировать") {ForEach(candidates) {c in Button(c.name) {edit(c)}}}.disabled(candidates.isEmpty);Button("Добавить кандидата",action:add).buttonStyle(.borderedProminent).disabled(vacancy.candidates.count>=100)}
        Text("Выберите 2–6 кандидатов для сравнения. Неполные оценки не получают итоговый балл.").font(.caption).foregroundStyle(.secondary)
        Table(candidates,selection:$selected) {
            TableColumn("Кандидат") {c in VStack(alignment:.leading){Button(c.name){edit(c)}.buttonStyle(.plain).fontWeight(.medium);Text(c.status.title).font(.caption).foregroundStyle(.secondary)}}.width(min:160,ideal:220)
            TableColumn("Полнота") {c in Text(NumberText.display(CandidateEngine.result(vacancy,c).coverage,digits:2)+"%").monospacedDigit()}.width(70)
            TableColumn("Итог / 5") {c in Text(CandidateEngine.result(vacancy,c).score.map {NumberText.display($0)} ?? "Не завершена").monospacedDigit()}.width(min:90,ideal:110)
            TableColumn("Требования") {c in let r=CandidateEngine.result(vacancy,c);Text("\(r.confirmedRequirements) да · \(r.notConfirmedRequirements) нет · \(r.unknownRequirements) ?").font(.caption)}.width(min:105,ideal:130)
            TableColumn("Условия") {c in Text(CandidateEngine.salaryComparison(vacancy,c)).font(.caption)}.width(min:130,ideal:200)
            TableColumn("") {c in Button {delete(c)} label:{Image(systemName:"trash")}.buttonStyle(.borderless).accessibilityLabel("Удалить кандидата \(c.name)")}.width(35)
        }
        if candidates.isEmpty {Text("Кандидатов пока нет. Добавьте первого или импортируйте CSV.").foregroundStyle(.secondary)}
    }.padding(20)}
}

private struct VacancyEditor:View {
    @ObservedObject var store:CandidateStore;@Environment(\.dismiss) private var dismiss
    @State private var draft:Vacancy;@State private var selectedCriterion:UUID?
    init(store:CandidateStore,initial:Vacancy){self.store=store;_draft=State(initialValue:initial)}
    private var pi:Int {draft.profiles.firstIndex {$0.id==draft.selectedProfileID} ?? draft.profiles.count-1}
    private var profile:Profile {draft.profiles[pi]}
    var body:some View {VStack(spacing:0) {
        EditorHeader(title:"Вакансия и профиль оценки",subtitle:"Версия \(profile.number) · \(profile.locked ? "зафиксирована" : "редактируется")")
        ScrollView {VStack(alignment:.leading,spacing:18) {
            GroupBox("Рабочие задачи и условия") {VStack(spacing:10) {LabeledField("Название вакансии",text:$draft.title);LabeledField("Задачи и ожидаемые результаты",text:$draft.tasks,lines:3);LabeledField("Формат работы",text:$draft.workFormat);HStack {LabeledField("Бюджет от / месяц",text:$draft.budgetMin);LabeledField("Бюджет до / месяц",text:$draft.budgetMax);LabeledField("Валюта",text:$draft.currency);Picker("База",selection:$draft.basis){ForEach(PayBasis.allCases){Text($0.title).tag($0)}}}}.padding(8)}
            if profile.locked {HStack {Label("Критерии защищены от случайного изменения",systemImage:"lock");Spacer();Button("Создать новую версию") {do {try CandidateEngine.newVersion(&draft)}catch {store.error=error.localizedDescription}}};Text("Старые карточки останутся в старой версии. В новой версии баллы нужно внести заново.").font(.caption).foregroundStyle(.secondary)}
            GroupBox("Этапы и интервьюеры") {VStack(alignment:.leading,spacing:12) {
                HStack(alignment:.top) {VStack {ForEach(profile.stages.indices,id:\.self) {i in HStack {TextField("Название этапа",text:$draft.profiles[pi].stages[i].name);Button {removeStage(i)}label:{Image(systemName:"minus.circle")}.disabled(profile.stages.count==1 || profile.criteria.contains {$0.stageID==profile.stages[i].id})}};Button("Добавить этап") {draft.profiles[pi].stages.append(Stage(name:"Новый этап"))}.disabled(profile.stages.count>=3)};Divider();VStack {ForEach(profile.reviewers.indices,id:\.self) {i in HStack {TextField("Имя интервьюера",text:$draft.profiles[pi].reviewers[i].name);Button {removeReviewer(i)}label:{Image(systemName:"minus.circle")}.disabled(profile.reviewers.count==1 || profile.criteria.contains {$0.reviewerIDs.contains(profile.reviewers[i].id)})}};Button("Добавить интервьюера") {draft.profiles[pi].reviewers.append(Reviewer(name:"Новый интервьюер"))}.disabled(profile.reviewers.count>=5)}}
                Text("Этап или интервьюера сначала нужно убрать из назначений критериев. Имена здесь являются локальными метками, не аккаунтами.").font(.caption).foregroundStyle(.secondary)
            }.padding(8)}.disabled(profile.locked)
            HStack {Text("Критерии: \(profile.criteria.count) из 20").font(.headline);Spacer();Button("Добавить критерий") {let c=Criterion(stageID:profile.stages[0].id,reviewerIDs:[profile.reviewers[0].id]);draft.profiles[pi].criteria.append(c);selectedCriterion=c.id}.disabled(profile.locked || profile.criteria.count>=20)}
            ForEach(profile.criteria.indices,id:\.self) {i in CriterionEditor(criterion:$draft.profiles[pi].criteria[i],profile:profile,remove:{draft.profiles[pi].criteria.remove(at:i)}).disabled(profile.locked)}
            GroupBox("Обязательные рабочие требования") {VStack(alignment:.leading) {ForEach(profile.requirements.indices,id:\.self) {i in HStack {TextField("Например, подтверждённый допуск к работе",text:$draft.profiles[pi].requirements[i].title);Button {draft.profiles[pi].requirements.remove(at:i)}label:{Image(systemName:"minus.circle")}}};Button("Добавить требование") {draft.profiles[pi].requirements.append(Requirement())}.disabled(profile.requirements.count>=20);Text("Проверка требований показывается отдельно от балла. Программа не принимает решение о найме.").font(.caption).foregroundStyle(.secondary)}.padding(8)}.disabled(profile.locked)
        }.textFieldStyle(.roundedBorder).padding(22)}
        Divider();HStack {Button("Отмена") {store.discardDraft();dismiss()}.keyboardShortcut(.cancelAction);Spacer();if !profile.locked {Button("Сохранить черновик") {save(lock:false)}};Button(profile.locked ? "Сохранить" : "Зафиксировать профиль") {save(lock:!profile.locked)}.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)}.padding(18)
    }.frame(width:900,height:760).onAppear {persist()}.onChange(of:draft) {_ in persist()}}
    private func persist(){store.saveEditor(draft,kind:.vacancy,vacancyID:store.data.vacancies.contains(where:{$0.id==draft.id}) ? draft.id : nil)}
    private func save(lock:Bool) {do {guard !draft.title.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty else{throw AppError("Назовите вакансию.")};try CandidateEngine.validateProfile(profile,activating:lock || profile.locked);var candidate=draft;if lock {candidate.profiles[pi].locked=true};if store.saveVacancy(candidate){dismiss()}}catch {store.error=error.localizedDescription}}
    private func removeStage(_ i:Int) {draft.profiles[pi].stages.remove(at:i)}
    private func removeReviewer(_ i:Int) {draft.profiles[pi].reviewers.remove(at:i)}
}
private struct CriterionEditor:View {
    @Binding var criterion:Criterion;let profile:Profile;let remove:()->Void
    var body:some View {GroupBox {VStack(alignment:.leading,spacing:10) {
        HStack {TextField("Название критерия",text:$criterion.name).font(.headline);Stepper("Важность: \(criterion.weight)",value:$criterion.weight,in:1...100).frame(width:190);Button(role:.destructive,action:remove) {Image(systemName:"trash")}.accessibilityLabel("Удалить критерий")}
        LabeledField("Какой рабочий результат проверяем",text:$criterion.outcome,lines:2)
        LabeledField("Основной вопрос для всех кандидатов",text:$criterion.questions,lines:2)
        HStack {Picker("Этап",selection:$criterion.stageID){ForEach(profile.stages){Text($0.name).tag($0.id)}};Spacer();ForEach(profile.reviewers){r in Toggle(r.name,isOn:Binding(get:{criterion.reviewerIDs.contains(r.id)},set:{on in if on {if !criterion.reviewerIDs.contains(r.id) {criterion.reviewerIDs.append(r.id)}}else if criterion.reviewerIDs.count>1 {criterion.reviewerIDs.removeAll {$0==r.id}}})).toggleStyle(.checkbox)}}
        DisclosureGroup("Описание уровней 1–5") {VStack {ForEach(0..<5,id:\.self) {i in HStack {Text("\(i+1)").fontWeight(.semibold).frame(width:22);TextField("Наблюдаемое поведение",text:$criterion.anchors[i])}}.padding(.top,8)}}
    }.padding(8)}}
}
private struct LabeledField:View {let title:String;@Binding var text:String;var lines=1;init(_ title:String,text:Binding<String>,lines:Int=1){self.title=title;_text=text;self.lines=lines};var body:some View {VStack(alignment:.leading,spacing:4) {Text(title).font(.caption).foregroundStyle(.secondary);if lines>1 {TextField(title,text:$text,axis:.vertical).lineLimit(lines...max(lines,6))}else{TextField(title,text:$text)}}}}
private struct EditorHeader:View {let title:String;let subtitle:String;var body:some View {HStack {VStack(alignment:.leading,spacing:5){Text(title).font(.title2.bold());Text(subtitle).font(.caption).foregroundStyle(.secondary)};Spacer()}.padding(22);Divider()}}

private struct CandidateEditor:View {
    @ObservedObject var store:CandidateStore;@Environment(\.dismiss) private var dismiss
    @State private var draft:Candidate;let vacancy:Vacancy
    @State private var decisionStatus:CandidateStatus = .discuss;@State private var decisionAuthor="";@State private var decisionReason=""
    init(store:CandidateStore,initial:Candidate,vacancy:Vacancy,recovery:CandidateEditorState?=nil){self.store=store;self.vacancy=vacancy;_draft=State(initialValue:initial);_decisionStatus=State(initialValue:recovery?.decisionStatus ?? initial.status);_decisionAuthor=State(initialValue:recovery?.decisionAuthor ?? "");_decisionReason=State(initialValue:recovery?.decisionReason ?? "")}
    var body:some View {VStack(spacing:0) {
        EditorHeader(title:draft.name.isEmpty ? "Новый кандидат" : draft.name,subtitle:vacancy.title)
        ScrollView {VStack(alignment:.leading,spacing:18) {
            GroupBox("Профессиональные сведения") {VStack(spacing:10) {LabeledField("Имя",text:$draft.name);LabeledField("Опыт, навыки и результаты",text:$draft.summary,lines:3);LabeledField("Текст резюме",text:$draft.resumeText,lines:3);HStack {LabeledField("Ссылка на резюме",text:$draft.resumeURL);Button("Открыть") {if let u=URL(string:draft.resumeURL),["http","https"].contains(u.scheme?.lowercased() ?? "") {NSWorkspace.shared.open(u)}}.disabled(draft.resumeURL.isEmpty)};HStack {LabeledField("Источник сведений",text:$draft.source);LabeledField("Дата сведений: ГГГГ-ММ-ДД",text:$draft.sourceDate)}}.padding(8)}
            GroupBox("Контакты и условия") {VStack(spacing:10) {HStack {LabeledField("Email, необязательно",text:$draft.email);LabeledField("Телефон, необязательно",text:$draft.phone)};HStack {LabeledField("Зарплата от / месяц",text:$draft.salaryMin);LabeledField("Зарплата до / месяц",text:$draft.salaryMax);LabeledField("Валюта",text:$draft.currency)};HStack {Picker("База зарплаты",selection:$draft.basis){ForEach(PayBasis.allCases){Text($0.title).tag($0)}};LabeledField("Дата выхода: ГГГГ-ММ-ДД",text:$draft.startDate)};Text(CandidateEngine.salaryComparison(vacancy,draft)).font(.caption).foregroundStyle(.secondary)}.padding(8)}
            if !vacancy.profile.requirements.isEmpty {GroupBox("Обязательные требования · версия \(vacancy.profile.number)") {VStack(alignment:.leading,spacing:14) {ForEach(vacancy.profile.requirements) {req in RequirementEditor(requirement:req,check:checkBinding(req))}}.padding(8)}}
            GroupBox("Решение руководителя") {VStack(alignment:.leading,spacing:10) {Text("Текущий статус: \(draft.status.title)").font(.headline);Picker("Следующий статус",selection:$decisionStatus){ForEach(CandidateStatus.allCases){Text($0.title).tag($0)}};LabeledField("Автор решения",text:$decisionAuthor);LabeledField("Причина решения",text:$decisionReason,lines:2);Button("Записать решение") {recordDecision()};ForEach(draft.decisions.reversed()) {d in Text("\(d.at.formatted(date:.abbreviated,time:.shortened)) · \(d.status.title) · \(d.author): \(d.reason)").font(.caption).foregroundStyle(.secondary)}}.padding(8)}
            LabeledField("Внутренние заметки",text:$draft.notes,lines:3)
            let duplicates=CandidateEngine.duplicates(draft,in:vacancy.candidates)
            if !duplicates.isEmpty {Label("Найдена похожая заявка по email или телефону. Проверьте перед сохранением.",systemImage:"person.crop.circle.badge.questionmark").foregroundStyle(.orange)}
        }.textFieldStyle(.roundedBorder).padding(22)}
        Divider();HStack {Button("Отмена") {store.discardDraft();dismiss()}.keyboardShortcut(.cancelAction);Spacer();if !CandidateEngine.duplicates(draft,in:vacancy.candidates).isEmpty {Button("Сохранить отдельную заявку") {save(allowDuplicate:true)}};Button("Сохранить кандидата") {save(allowDuplicate:false)}.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)}.padding(18)
    }.frame(width:850,height:760).onAppear {persist()}.onChange(of:draft) {_ in persist()}.onChange(of:decisionStatus) {_ in persist()}.onChange(of:decisionAuthor) {_ in persist()}.onChange(of:decisionReason) {_ in persist()}}
    private func persist(){var state=CandidateEditorState(draft);state.decisionStatus=decisionStatus;state.decisionAuthor=decisionAuthor;state.decisionReason=decisionReason;store.saveEditor(state,kind:.candidate,vacancyID:vacancy.id)}
    private func save(allowDuplicate:Bool){if store.saveCandidate(draft,allowDuplicate:allowDuplicate){dismiss()}}
    private func checkBinding(_ req:Requirement)->Binding<RequirementCheck> {Binding(get:{draft.checks.first {$0.profileID==vacancy.profile.id && $0.requirementID==req.id} ?? RequirementCheck(profileID:vacancy.profile.id,requirementID:req.id)},set:{c in if let i=draft.checks.firstIndex(where:{$0.profileID==c.profileID && $0.requirementID==c.requirementID}){draft.checks[i]=c}else{draft.checks.append(c)}})}
    private func recordDecision(){guard !decisionAuthor.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty,!decisionReason.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty else{store.error="Укажите автора и причину решения.";return};draft.decisions.append(Decision(profileID:vacancy.profile.id,status:decisionStatus,author:decisionAuthor,reason:decisionReason));draft.status=decisionStatus;decisionReason=""}
}
private struct RequirementEditor:View {let requirement:Requirement;@Binding var check:RequirementCheck;var body:some View {VStack(alignment:.leading,spacing:8) {Text(requirement.title).fontWeight(.medium);Picker("Проверка",selection:$check.state){ForEach(RequirementState.allCases){Text($0.title).tag($0)}}.pickerStyle(.segmented);LabeledField("Основание проверки",text:$check.evidence)}}}

private struct ScorecardEditor:View {
    @ObservedObject var store:CandidateStore;@Environment(\.dismiss) private var dismiss;@State private var draft:Scorecard;let vacancy:Vacancy
    init(store:CandidateStore,initial:Scorecard,vacancy:Vacancy){self.store=store;self.vacancy=vacancy;_draft=State(initialValue:initial)}
    private var profile:Profile {vacancy.profiles.first {$0.id==draft.profileID} ?? vacancy.profile}
    private var hasOwnSubmitted:Bool {vacancy.cards.contains {$0.key==draft.key && $0.submittedAt != nil}}
    var body:some View {VStack(spacing:0) {
        EditorHeader(title:"Карточка оценки · редакция \(draft.revision)",subtitle:"\(vacancy.candidates.first {$0.id==draft.candidateID}?.name ?? "") · \(profile.reviewers.first {$0.id==draft.reviewerID}?.name ?? "") · версия \(profile.number)")
        ScrollView {VStack(alignment:.leading,spacing:18) {
            Text("Оценивайте только проверенные рабочие навыки. Для каждого балла укажите конкретное основание; если тему не проверили, оставьте её без балла и запишите причину.").foregroundStyle(.secondary)
            ForEach(draft.assessments.indices,id:\.self) {i in if let c=profile.criteria.first(where: {$0.id==draft.assessments[i].criterionID}) {AssessmentEditor(assessment:$draft.assessments[i],criterion:c)}}
            Picker("Рекомендация интервьюера",selection:$draft.recommendation){ForEach(Recommendation.allCases){Text($0.title).tag($0)}}
            LabeledField("Общий комментарий к интервью",text:$draft.comment,lines:3)
            if draft.revision>1 {LabeledField("Причина исправления предыдущей карточки",text:$draft.amendmentReason,lines:2)}
            if hasOwnSubmitted {DisclosureGroup("Отправленные оценки коллег") {ForEach(CandidateEngine.activeCards(vacancy,candidateID:draft.candidateID,profileID:draft.profileID)) {card in VStack(alignment:.leading) {Text(profile.reviewers.first {$0.id==card.reviewerID}?.name ?? "Интервьюер").font(.headline);ForEach(card.assessments){a in Text("\(profile.criteria.first {$0.id==a.criterionID}?.name ?? "Критерий"): \(a.rating.map(String.init) ?? "не проверено") · \(a.rating == nil ? a.skipReason : a.evidence)").font(.callout)}}.padding(10)}}}else {Label("Сводка коллег скрыта до отправки вашей карточки",systemImage:"eye.slash").font(.caption).foregroundStyle(.secondary)}
        }.textFieldStyle(.roundedBorder).padding(22)}
        Divider();HStack {Button("Отмена") {store.discardDraft();dismiss()}.keyboardShortcut(.cancelAction);Spacer();Button("Сохранить черновик") {save(false)};Button("Отправить оценку") {save(true)}.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)}.padding(18)
    }.frame(width:850,height:760).onAppear {persist()}.onChange(of:draft) {_ in persist()}}
    private func persist(){store.saveEditor(draft,kind:.scorecard,vacancyID:vacancy.id)}
    private func save(_ submit:Bool){if store.saveScorecard(draft,submit:submit){dismiss()}}
}
private struct AssessmentEditor:View { @Binding var assessment:Assessment;let criterion:Criterion;var body:some View {GroupBox(criterion.name) {VStack(alignment:.leading,spacing:12) {Text(criterion.outcome).foregroundStyle(.secondary);Text(criterion.questions).fontWeight(.medium);Picker("Балл",selection:Binding(get:{assessment.rating ?? 0},set:{assessment.rating=$0==0 ? nil : $0})) {Text("Не проверено").tag(0);ForEach(1...5,id:\.self){Text("\($0)").tag($0)}}.pickerStyle(.segmented);if let rating=assessment.rating {Text(criterion.anchors[rating-1]).font(.callout).foregroundStyle(.secondary);LabeledField("На чём основана оценка",text:$assessment.evidence,lines:3)}else{LabeledField("Почему не проверено / что уточнить",text:$assessment.skipReason,lines:2)}}.padding(8)}}}

private struct ComparisonView:View {
    let vacancy:Vacancy;@Binding var selected:Set<UUID>;@State private var mode="Критерии"
    private var candidates:[Candidate] {vacancy.candidates.filter {selected.contains($0.id)}.sorted {$0.name.localizedStandardCompare($1.name) == .orderedAscending}}
    var body:some View {VStack(alignment:.leading,spacing:12) {
        HStack {Text("Сравнение по версии \(vacancy.profile.number)").font(.headline);Spacer();Picker("Вид",selection:$mode){ForEach(["Критерии","Основания","Условия"],id:\.self){Text($0).tag($0)}}.pickerStyle(.segmented).frame(width:370)}
        HStack {Menu("Выбрать кандидатов (\(selected.count))") {ForEach(vacancy.candidates){c in Button {if selected.contains(c.id) {selected.remove(c.id)}else if selected.count<6 {selected.insert(c.id)}}label:{Label(c.name,systemImage:selected.contains(c.id) ? "checkmark.square" : "square")}}};Button("Первые шесть по имени") {selected=Set(vacancy.candidates.sorted {$0.name.localizedStandardCompare($1.name) == .orderedAscending}.prefix(6).map(\.id))};Button("Снять выбор") {selected.removeAll()}}
        if candidates.count<2 || candidates.count>6 {VStack(spacing:10) {Image(systemName:"rectangle.split.3x1").font(.largeTitle);Text("Выберите от двух до шести кандидатов").font(.headline);Text("Выбор также доступен в таблице раздела «Кандидаты».").foregroundStyle(.secondary)}.frame(maxWidth:.infinity,maxHeight:.infinity)}
        else {ScrollView([.horizontal,.vertical]) {HStack(alignment:.top,spacing:14) {ForEach(candidates) {c in comparisonCard(c)}}.padding(.bottom,16)}}
    }.padding(20)}
    private func comparisonCard(_ c:Candidate)->some View {let r=CandidateEngine.result(vacancy,c);return VStack(alignment:.leading,spacing:14) {
        Text(c.name).font(.title3.bold());Text(c.status.title).foregroundStyle(.secondary)
        HStack {Metric(title:"Итог / 5",value:r.score.map {NumberText.display($0)} ?? "—");Metric(title:"Полнота",value:NumberText.display(r.coverage,digits:2)+"%")}
        if r.score==nil {Text("Оценка не завершена").foregroundStyle(.orange).font(.caption)}
        if r.notConfirmedRequirements>0 || r.unknownRequirements>0 {Label("Требования: \(r.notConfirmedRequirements) не подтверждено, \(r.unknownRequirements) не проверено",systemImage:"exclamationmark.triangle").font(.caption).foregroundStyle(.orange)}
        if mode=="Условия" {Text("Ожидания / месяц: \(c.salaryMin.isEmpty ? "?" : c.salaryMin) – \(c.salaryMax.isEmpty ? "?" : c.salaryMax) \(c.currency)");Text(c.basis.title);Text(CandidateEngine.salaryComparison(vacancy,c));Text("Выход: \(c.startDate.isEmpty ? "не уточнён" : c.startDate)");Text(c.summary)}
        else {ForEach(r.criteria) {item in VStack(alignment:.leading,spacing:7) {HStack {Text(item.criterion.name).font(.headline);Spacer();Text(item.average.map {NumberText.display($0)} ?? "—").monospacedDigit()};Text("Получено \(item.received) из \(item.expected)").font(.caption).foregroundStyle(.secondary);if item.disagreement {Label("Мнения расходятся",systemImage:"bubble.left.and.bubble.right").font(.caption).foregroundStyle(.orange)};if mode=="Основания" {ForEach(CandidateEngine.activeCards(vacancy,candidateID:c.id,profileID:vacancy.profile.id).filter {$0.assessments.contains(where:{$0.criterionID==item.id})}) {card in if let a=card.assessments.first(where:{$0.criterionID==item.id}) {Text("\(vacancy.profile.reviewers.first {$0.id==card.reviewerID}?.name ?? "Интервьюер"): \(a.rating.map(String.init) ?? "?") · \(a.rating == nil ? a.skipReason : a.evidence)").font(.callout)}}}else{Text(item.ratings.map(String.init).joined(separator:" · ")).font(.callout)}}.padding(12).background(Color.primary.opacity(0.035)).cornerRadius(8)}}
        DisclosureGroup("Что уточнить (\(r.missing.count))") {if r.missing.isEmpty && r.notConfirmedRequirements==0 && r.unknownRequirements==0 {Text("Все предусмотренные оценки получены").font(.caption)};ForEach(r.missing,id:\.self){Text($0).font(.caption)};ForEach(vacancy.profile.requirements) {req in if (c.checks.first {$0.profileID==vacancy.profile.id && $0.requirementID==req.id}?.state ?? .unknown) != .confirmed {Text("Требование: \(req.title)").font(.caption)}};ForEach(r.criteria.filter(\.disagreement)){Text("Обсудить расхождение: \($0.criterion.name)").font(.caption)}}
        if let d=c.decisions.last {Divider();Text("Решение: \(d.status.title)").font(.headline);Text(d.reason);Text("\(d.author) · версия \(vacancy.profiles.first {$0.id==d.profileID}?.number ?? 0)").font(.caption).foregroundStyle(.secondary)}
    }.padding(16).frame(width:300,alignment:.topLeading).background(Color(nsColor:.controlBackgroundColor)).cornerRadius(12).overlay(RoundedRectangle(cornerRadius:12).stroke(Color.primary.opacity(0.08)))}
}

private struct ReportSheet:View {
    @ObservedObject var store:CandidateStore;@Environment(\.dismiss) private var dismiss;let selected:[UUID]
    @State private var kind:ReportKind = .pdf;@State private var contacts=false;@State private var notes=false
    var body:some View {VStack(alignment:.leading,spacing:18) {Text("Экспорт вакансии").font(.title2.bold());Picker("Формат",selection:$kind){ForEach(ReportKind.allCases){Text($0.rawValue).tag($0)}}.pickerStyle(.segmented);if kind == .json {Text("Полная резервная копия вакансии содержит все версии, персональные сведения, оценки, основания и историю. Сохраняйте её в надёжном месте.").foregroundStyle(.secondary)}else{Text(selected.isEmpty ? "В отчёт войдут все кандидаты текущей вакансии." : "Выбрано кандидатов: \(selected.count)");Toggle("Включить контакты",isOn:$contacts);Toggle("Включить длинные заметки и полные комментарии",isOn:$notes);Text("Основания оценок включаются в отчёт и могут содержать персональные сведения. Итоги относятся к выбранной версии профиля.").font(.caption).foregroundStyle(.secondary)};HStack {Button("Отмена") {dismiss()};Spacer();Button("Выбрать файл и сохранить") {store.export(kind,candidateIDs:selected,contacts:contacts,notes:notes);dismiss()}.buttonStyle(.borderedProminent)}}.padding(26).frame(width:560)}
}

private struct CandidateErrorModifier: ViewModifier {
    @ObservedObject var store: CandidateStore
    func body(content: Content) -> some View {
        content.alert("Не удалось выполнить действие", isPresented: Binding(get: { !store.error.isEmpty }, set: { if !$0 { store.error = "" } })) {
            Button("Понятно") { store.error = "" }
        } message: { Text(store.error) }
    }
}
private extension View {
    func candidateErrors(_ store: CandidateStore) -> some View { modifier(CandidateErrorModifier(store: store)) }
}
