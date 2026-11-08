import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct CandidateImportView:View {
    @ObservedObject var store:CandidateStore
    let source:String
    @Environment(\.dismiss) private var dismiss
    @State private var separator=";"
    @State private var decimal:CSVDecimalSeparator = .dot
    @State private var preview:CandidateCSVPreview?
    @State private var headers:[String]=[]
    @State private var mapping:[CandidateCSVField:Int]=[:]
    @State private var resolutions:[Int:CSVResolution]=[:]
    @State private var message=""
    @State private var showMapping=false
    var body:some View {VStack(spacing:0) {
        HStack {VStack(alignment:.leading,spacing:5){Text("Импорт кандидатов из CSV").font(.title2.bold());Text("Сначала проверьте столбцы, строки и совпадения. Оценки и решения не импортируются.").font(.caption).foregroundStyle(.secondary)};Spacer()}.padding(22)
        Divider()
        HStack {Picker("Разделитель",selection:$separator){Text("Точка с запятой").tag(";");Text("Запятая").tag(",")};Picker("Дробные суммы",selection:$decimal){ForEach(CSVDecimalSeparator.allCases){Text($0.title).tag($0)}};Button("Сохранить шаблон") {store.saveFile(Data(CandidateCSV.template.utf8),name:"Кандидаты-шаблон.csv",type:.commaSeparatedText)}}.padding(18)
        ScrollView {VStack(alignment:.leading,spacing:16) {
            if !message.isEmpty {Label(message,systemImage:"exclamationmark.triangle").foregroundStyle(.orange)}
            if !headers.isEmpty {
                DisclosureGroup("Сопоставить столбцы",isExpanded:$showMapping) {VStack {ForEach(CandidateCSVField.allCases){field in HStack {Text(field.title).frame(width:210,alignment:.leading);Picker(field.title,selection:Binding(get:{mapping[field] ?? -1},set:{value in if value<0{mapping.removeValue(forKey:field)}else{mapping[field]=value};refresh(useMapping:true)})){Text("Не импортировать").tag(-1);ForEach(headers.indices,id:\.self){i in Text("\(i+1). \(headers[i])").tag(i)}}.labelsHidden()}}}.padding(.top,10)}
            }
            if let p=preview {
                if !p.issues.isEmpty {ForEach(p.issues,id:\.self){Text($0).foregroundStyle(.orange)}}
                HStack {Text("Строк: \(p.rows.count)").font(.headline);Spacer();Button("Все дубли пропустить") {resolveAll(.skip)};Button("Все дубли оставить отдельно") {resolveAll(.separate)}}
                ForEach(p.rows) {row in VStack(alignment:.leading,spacing:10) {
                    HStack {Text("Строка \(row.line)").font(.caption).foregroundStyle(.secondary);Text(row.candidate?.name ?? "Не удалось прочитать кандидата").font(.headline);Spacer();if !row.issues.isEmpty {Text("Нужны исправления").foregroundStyle(.orange).font(.caption)}}
                    if let c=row.candidate {Text([c.email,c.phone,c.salaryMin.isEmpty ? "" : "\(c.salaryMin) \(c.currency) / месяц"].filter{!$0.isEmpty}.joined(separator:" · ")).font(.caption).foregroundStyle(.secondary)}
                    ForEach(row.issues,id:\.self){Text($0).font(.caption).foregroundStyle(.orange)}
                    if !row.duplicateIDs.isEmpty || !row.duplicateLines.isEmpty {
                        Text("Найдено совпадение по ID, email или телефону\(row.duplicateLines.isEmpty ? "" : "; в этом CSV: строки " + row.duplicateLines.map(String.init).joined(separator:", "))").font(.caption).foregroundStyle(.orange)
                        Picker("Действие с совпадением",selection:resolutionBinding(row.line,\.action)) {ForEach(CSVRowAction.allCases){action in if action != .update || !row.duplicateIDs.isEmpty {Text(action.title).tag(action)}}}
                        if resolutions[row.line]?.action == .update {
                            Picker("Обновить кандидата",selection:Binding(get:{resolutions[row.line]?.targetID ?? row.duplicateIDs.first},set:{id in var r=resolutions[row.line] ?? CSVResolution();r.targetID=id;resolutions[row.line]=r})) {ForEach(row.duplicateIDs,id:\.self){id in Text(store.current?.candidates.first {$0.id==id}?.name ?? id.uuidString).tag(Optional(id))}}
                            DisclosureGroup("Какие поля обновить") {LazyVGrid(columns:[GridItem(.flexible()),GridItem(.flexible())],alignment:.leading){ForEach(CandidateCSVField.editable){field in if p.mapping[field] != nil {Toggle(field.title,isOn:Binding(get:{(resolutions[row.line] ?? CSVResolution()).fields.contains(field)},set:{on in var r=resolutions[row.line] ?? CSVResolution();if on{r.fields.insert(field)}else{r.fields.remove(field)};resolutions[row.line]=r})).toggleStyle(.checkbox)}}}}
                        }
                    }
                }.padding(14).background(Color.primary.opacity(0.035)).cornerRadius(9)}
            } else {Text("Не удалось построить предпросмотр. Проверьте формат CSV или используйте шаблон.").foregroundStyle(.secondary)}
        }.padding(22)}
        Divider();HStack {Button("Отмена") {dismiss()}.keyboardShortcut(.cancelAction);Spacer();Text("Изменения применятся только после этой кнопки").font(.caption).foregroundStyle(.secondary);Button("Импортировать") {if let p=preview,store.applyCSV(p,resolutions:completedResolutions(p)) {dismiss()}}.buttonStyle(.borderedProminent).disabled(preview == nil || preview?.hasErrors == true)}.padding(18)
    }.frame(width:900,height:740).onAppear {refresh(useMapping:false)}.onChange(of:separator){_ in resolutions=[:];refresh(useMapping:false)}.onChange(of:decimal){_ in resolutions=[:];refresh(useMapping:!mapping.isEmpty)}}
    private func refresh(useMapping:Bool) {guard let v=store.current else{return};do {let p=try CandidateCSV.preview(source,separator:separator.first ?? ";",decimal:decimal,mapping:useMapping ? mapping:nil,existing:v.candidates);preview=p;headers=p.headers;mapping=p.mapping;message=""}catch {preview=nil;message=error.localizedDescription}}
    private func resolutionBinding<T>(_ line:Int,_ key:WritableKeyPath<CSVResolution,T>)->Binding<T> {Binding(get:{(resolutions[line] ?? CSVResolution())[keyPath:key]},set:{value in var r=resolutions[line] ?? CSVResolution();r[keyPath:key]=value;if r.action == .update,r.targetID==nil {r.targetID=preview?.rows.first {$0.line==line}?.duplicateIDs.first};resolutions[line]=r})}
    private func completedResolutions(_ p:CandidateCSVPreview)->[Int:CSVResolution] {var result=resolutions;for row in p.rows {if result[row.line]?.action == .update,result[row.line]?.targetID==nil {result[row.line]?.targetID=row.duplicateIDs.first}};return result}
    private func resolveAll(_ action:CSVRowAction) {guard let p=preview else{return};for row in p.rows where !row.duplicateIDs.isEmpty || !row.duplicateLines.isEmpty {resolutions[row.line]=CSVResolution(action:action)}}
}
