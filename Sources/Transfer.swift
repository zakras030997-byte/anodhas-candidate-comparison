import Foundation
import AppKit
import CoreGraphics

enum CSVDecimalSeparator: String, CaseIterable, Identifiable {
    case dot, comma
    var id: String { rawValue }
    var title: String { self == .dot ? "Точка: 12.50" : "Запятая: 12,50" }
}
enum CandidateCSVField: String, CaseIterable, Identifiable {
    case id, name, email, phone, summary, resumeText, resumeURL, source, sourceDate, salaryMin, salaryMax, currency, basis, startDate, notes
    var id: String { rawValue }
    var title: String {
        switch self {
        case .id: return "ID заявки"; case .name: return "Имя"; case .email: return "Email"; case .phone: return "Телефон"
        case .summary: return "Профессиональная справка"; case .resumeText: return "Текст резюме"; case .resumeURL: return "Ссылка на резюме"
        case .source: return "Источник"; case .sourceDate: return "Дата сведений"; case .salaryMin: return "Зарплата от"; case .salaryMax: return "Зарплата до"
        case .currency: return "Валюта"; case .basis: return "База зарплаты"; case .startDate: return "Дата выхода"; case .notes: return "Внутренние заметки"
        }
    }
    static var editable: [CandidateCSVField] { allCases.filter { $0 != .id } }
    static func guess(_ text: String) -> CandidateCSVField? {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().replacingOccurrences(of: "_", with: "").replacingOccurrences(of: " ", with: "")
        if let field = allCases.first(where: { $0.rawValue.lowercased() == value || $0.title.lowercased().replacingOccurrences(of: " ", with: "") == value }) { return field }
        return ["candidateid":.id,"фио":.name,"кандидат":.name,"fullname":.name,"почта":.email,"резюме":.resumeText,"salaryfrom":.salaryMin,"salaryto":.salaryMax,"salarybasis":.basis,"availablefrom":.startDate][value]
    }
}
enum CSVRowAction: String, CaseIterable, Identifiable {
    case unresolved, skip, separate, update
    var id: String { rawValue }
    var title: String { switch self { case .unresolved:return "Выберите действие";case .skip:return "Пропустить";case .separate:return "Создать отдельную заявку";case .update:return "Обновить выбранные поля" } }
}
struct CSVResolution {
    var action: CSVRowAction = .unresolved
    var targetID: UUID?
    var fields: Set<CandidateCSVField> = Set(CandidateCSVField.editable)
}
struct CandidateCSVRow: Identifiable {
    var id: Int { line }
    var line: Int
    var candidate: Candidate?
    var issues: [String]
    var duplicateIDs: [UUID]
    var duplicateLines: [Int]
}
struct CandidateCSVPreview {
    var headers: [String]
    var mapping: [CandidateCSVField: Int]
    var rows: [CandidateCSVRow]
    var issues: [String]
    var existing: [Candidate]
    var hasErrors: Bool { !issues.isEmpty || rows.contains { $0.candidate == nil || !$0.issues.isEmpty } }
}

enum CandidateCSV {
    static let template = "id;name;email;phone;summary;resume_url;source;source_date;salary_min;salary_max;currency;basis;start_date;notes\n;Имя кандидата;;;Профессиональные сведения;;;2026-11-08;100000;120000;RUB;gross;;\n"

    static func parse(_ source: String, separator: Character = ";") throws -> [[String]] {
        guard [";", ",", "\t"].contains(separator), source.utf8.count <= 2 * 1024 * 1024 else { throw AppError("CSV: выберите запятую, точку с запятой или табуляцию; файл не больше 2 МБ.") }
        var text = source.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        if text.first == "\u{feff}" { text.removeFirst() }
        let chars = Array(text)
        var rows: [[String]] = [], row: [String] = [], field = "", quoted = false, closed = false, index = 0
        func finishField() throws {
            guard field.count <= 32000 else { throw AppError("CSV: поле длиннее 32000 символов.") }
            row.append(field); field = ""; closed = false
            guard row.count <= 40 else { throw AppError("CSV: больше 40 колонок.") }
        }
        func finishRow() throws {
            try finishField()
            if row.contains(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) { rows.append(row) }
            row = []
            guard rows.count <= 101 else { throw AppError("CSV: за один импорт доступно до 100 кандидатов.") }
        }
        while index < chars.count {
            let c = chars[index]
            if quoted {
                if c == "\"" {
                    if index + 1 < chars.count && chars[index + 1] == "\"" { field.append("\""); index += 1 }
                    else { quoted = false; closed = true }
                } else { field.append(c) }
            } else if c == separator { try finishField() }
            else if c == "\n" { try finishRow() }
            else if c == "\"" {
                guard field.isEmpty && !closed else { throw AppError("CSV: кавычка внутри неэкранированного поля.") }
                quoted = true
            } else if closed {
                guard c == " " else { throw AppError("CSV: после закрывающей кавычки должен быть разделитель.") }
            } else { field.append(c) }
            index += 1
        }
        guard !quoted else { throw AppError("CSV: не закрыта кавычка.") }
        if !row.isEmpty || !field.isEmpty || closed { try finishRow() }
        guard rows.count >= 2 else { throw AppError("CSV: нужны заголовки и хотя бы одна строка кандидата.") }
        return rows
    }

    static func preview(_ text: String, separator: Character = ";", decimal: CSVDecimalSeparator = .dot, mapping selectedMapping: [CandidateCSVField: Int]? = nil, existing: [Candidate] = []) throws -> CandidateCSVPreview {
        let table = try parse(text, separator: separator)
        let headers = table[0].map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        var mapping = selectedMapping ?? [:], issues: [String] = []
        if selectedMapping == nil {
            for (index, name) in headers.enumerated() {
                guard let field = CandidateCSVField.guess(name) else { continue }
                if mapping[field] != nil { issues.append("Несколько колонок подходят для «\(field.title)». Выберите одну вручную.") }
                else { mapping[field] = index }
            }
        }
        if mapping[.name] == nil { issues.append("Сопоставьте колонку с именем кандидата.") }
        if Set(mapping.values).count != mapping.count || mapping.values.contains(where: { !headers.indices.contains($0) }) { issues.append("Проверьте сопоставление: одна колонка может соответствовать одному полю.") }
        var rows: [CandidateCSVRow] = []
        for (offset, values) in table.dropFirst().enumerated() {
            var c = Candidate(), errors: [String] = []
            func get(_ field: CandidateCSVField) -> String { mapping[field].flatMap { values.indices.contains($0) ? values[$0] : nil }?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "" }
            if values.count != headers.count { errors.append("Число ячеек отличается от числа заголовков.") }
            if !get(.id).isEmpty { if let id = UUID(uuidString: get(.id)) { c.id = id } else { errors.append("ID заявки должен быть UUID либо пустым.") } }
            c.name = get(.name); c.email = get(.email); c.phone = get(.phone); c.summary = get(.summary); c.resumeText = get(.resumeText); c.resumeURL = get(.resumeURL)
            c.source = get(.source); c.sourceDate = get(.sourceDate); c.startDate = get(.startDate); c.notes = get(.notes)
            c.currency = get(.currency).isEmpty ? "RUB" : get(.currency).uppercased()
            for field in [CandidateCSVField.salaryMin, .salaryMax] {
                let raw = get(field), wrong = decimal == .dot ? "," : "."
                if raw.contains(wrong) { errors.append("\(field.title): выбран другой десятичный разделитель.") }
                let normalized = raw.replacingOccurrences(of: ",", with: ".")
                if field == .salaryMin { c.salaryMin = normalized } else { c.salaryMax = normalized }
            }
            if (!c.salaryMin.isEmpty || !c.salaryMax.isEmpty) && get(.currency).isEmpty { errors.append("Для зарплаты укажите валюту явно, например RUB.") }
            let basis = get(.basis)
            if let matched = PayBasis.allCases.first(where: { $0.rawValue == basis.lowercased() || $0.title.lowercased() == basis.lowercased() }) { c.basis = matched }
            else if !basis.isEmpty { errors.append("База зарплаты: unknown, gross, net или русское название.") }
            do { try CandidateEngine.validateCandidate(c) } catch { errors.append(error.localizedDescription) }
            let matches = duplicateIDs(c, existing: existing)
            let duplicateLines = rows.filter { previous in previous.candidate.map { isDuplicate(c, $0) } ?? false }.map(\.line)
            rows.append(CandidateCSVRow(line: offset + 2, candidate: c, issues: errors, duplicateIDs: matches, duplicateLines: duplicateLines))
        }
        return CandidateCSVPreview(headers: headers, mapping: mapping, rows: rows, issues: issues, existing: existing)
    }

    static func apply(_ preview: CandidateCSVPreview, to vacancy: Vacancy, resolutions: [Int: CSVResolution] = [:]) throws -> Vacancy {
        guard !preview.hasErrors else { throw AppError("Исправьте ошибки CSV и сопоставление колонок до импорта.") }
        guard preview.existing == vacancy.candidates else { throw AppError("Кандидаты изменились после предпросмотра. Обновите предпросмотр перед импортом.") }
        var next = vacancy
        for row in preview.rows {
            guard var candidate = row.candidate else { throw AppError("CSV: строка без кандидата.") }
            let matches = duplicateIDs(candidate, existing: next.candidates)
            let resolution = resolutions[row.line] ?? CSVResolution()
            if resolution.action == .skip { continue }
            if !matches.isEmpty || !row.duplicateIDs.isEmpty || !row.duplicateLines.isEmpty {
                guard resolution.action != .unresolved else { throw AppError("Строка \(row.line): выберите действие с повторной заявкой.") }
            }
            if resolution.action == .update {
                guard let id = resolution.targetID, matches.contains(id), let index = next.candidates.firstIndex(where: { $0.id == id }) else { throw AppError("Строка \(row.line): выберите существующую совпавшую заявку для обновления.") }
                let fields = resolution.fields.intersection(Set(CandidateCSVField.editable)).intersection(Set(preview.mapping.keys))
                guard !fields.isEmpty else { throw AppError("Выберите хотя бы одно сопоставленное поле для обновления.") }
                var updated = next.candidates[index]
                for field in fields { copy(field, from: candidate, to: &updated) }
                try CandidateEngine.validateCandidate(updated); next.candidates[index] = updated
            } else {
                if resolution.action == .separate || next.candidates.contains(where: { $0.id == candidate.id }) { candidate.id = UUID() }
                guard next.candidates.count < 100 else { throw AppError("В одной вакансии доступно до 100 кандидатов.") }
                next.candidates.append(candidate)
            }
        }
        next.updatedAt = Date()
        var workspace = Workspace(); workspace.vacancies = [next]; workspace.selectedVacancyID = next.id
        try CandidateEngine.validateWorkspace(workspace)
        return next
    }
    private static func duplicateIDs(_ c: Candidate, existing: [Candidate]) -> [UUID] {
        existing.filter { isDuplicate(c, $0) }.map(\.id)
    }
    private static func isDuplicate(_ a: Candidate, _ b: Candidate) -> Bool {
        if a.id == b.id { return true }
        let email = a.email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), phone = a.phone.filter(\.isNumber)
        return (!email.isEmpty && email == b.email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()) || (phone.count >= 7 && phone == b.phone.filter(\.isNumber))
    }
    private static func copy(_ field: CandidateCSVField, from source: Candidate, to target: inout Candidate) {
        switch field {
        case .id: break;case .name:target.name = source.name;case .email:target.email = source.email;case .phone:target.phone = source.phone
        case .summary:target.summary = source.summary;case .resumeText:target.resumeText = source.resumeText;case .resumeURL:target.resumeURL = source.resumeURL
        case .source:target.source = source.source;case .sourceDate:target.sourceDate = source.sourceDate;case .salaryMin:target.salaryMin = source.salaryMin
        case .salaryMax:target.salaryMax = source.salaryMax;case .currency:target.currency = source.currency;case .basis:target.basis = source.basis
        case .startDate:target.startDate = source.startDate;case .notes:target.notes = source.notes
        }
    }
}

enum CandidateTransfer {
    private struct Envelope: Codable { var schemaVersion = 1; var vacancy: Vacancy }
    static func encodeVacancy(_ vacancy: Vacancy) throws -> Data {
        try validate(vacancy)
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601; encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let raw = try encoder.encode(Envelope(vacancy: vacancy))
        guard raw.count <= 32 * 1024 * 1024 else { throw AppError("JSON больше 32 МБ.") }
        return raw
    }
    static func decodeVacancy(_ raw: Data) throws -> Vacancy {
        guard raw.count <= 32 * 1024 * 1024 else { throw AppError("JSON больше 32 МБ.") }
        guard let object = try JSONSerialization.jsonObject(with: raw) as? [String: Any], let version = object["schemaVersion"] as? Int, version == 1,
              object["vacancy"] is [String: Any] else { throw AppError("Неизвестная версия или формат файла вакансии. Текущие данные не изменены.") }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let envelope = try decoder.decode(Envelope.self, from: raw)
        try validate(envelope.vacancy)
        return envelope.vacancy
    }
    private static func validate(_ v: Vacancy) throws { var w = Workspace(); w.vacancies = [v]; w.selectedVacancyID = v.id; try CandidateEngine.validateWorkspace(w) }
    private static func selected(_ vacancy: Vacancy, _ ids: [UUID]) throws -> [Candidate] {
        try validate(vacancy)
        guard !ids.isEmpty, ids.count <= 100, Set(ids).count == ids.count else { throw AppError("Выберите от 1 до 100 разных кандидатов для отчёта.") }
        return try ids.map { id in guard let c = vacancy.candidates.first(where: {$0.id == id}) else { throw AppError("Выбранный кандидат больше не найден. Обновите выбор.") }; return c }
    }
    static func reportCSV(_ vacancy: Vacancy, candidateIDs: [UUID], includeContacts: Bool = false, includeNotes: Bool = false) throws -> Data {
        let candidates = try selected(vacancy, candidateIDs), p = vacancy.profile
        let date = ISO8601DateFormatter().string(from: Date())
        var rows = [["Вакансия", "Версия профиля", "Дата отчёта", "ID заявки", "Кандидат", "Раздел", "Поле", "Значение"]]
        for c in candidates {
            for record in records(vacancy, candidate: c, includeContacts: includeContacts, includeNotes: includeNotes) {
                rows.append([vacancy.title, String(p.number), date, c.id.uuidString, c.name, record.section, record.label, record.value])
            }
        }
        return Data(("\u{feff}" + rows.map { $0.map(csvCell).joined(separator: ";") }.joined(separator: "\r\n") + "\r\n").utf8)
    }
    static func reportPDF(_ vacancy: Vacancy, candidateIDs: [UUID], includeContacts: Bool = false, includeNotes: Bool = false) throws -> Data {
        let candidates = try selected(vacancy, candidateIDs)
        return try CandidatePDF(vacancy: vacancy, candidates: candidates, includeContacts: includeContacts, includeNotes: includeNotes).render()
    }
    static func csvCell(_ source: String) -> String {
        let trimmed = source.trimmingCharacters(in: .whitespacesAndNewlines)
        let formula = trimmed.first.map { "=+-@".contains($0) } ?? false
        let text = (formula || source.first == "\t" || source.first == "\r" ? "'" : "") + source
        return "\"" + text.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
    fileprivate struct Record { var section: String; var label: String; var value: String }
    fileprivate static func records(_ vacancy: Vacancy, candidate c: Candidate, includeContacts: Bool, includeNotes: Bool) -> [Record] {
        let p = vacancy.profile, result = CandidateEngine.result(vacancy, c), active = CandidateEngine.activeCards(vacancy, candidateID: c.id, profileID: p.id)
        var rows: [Record] = []
        func add(_ section: String, _ label: String, _ value: String) { rows.append(Record(section: section, label: label, value: value.isEmpty ? "Не указано" : value)) }
        add("Сводка", "Кандидат", c.name); add("Сводка", "Статус процесса", c.status.title)
        add("Сводка", "Полнота оценок", NumberText.display(result.coverage) + "%")
        add("Сводка", "Общий балл", result.score.map { NumberText.display($0) + " из 5" } ?? "Оценка не завершена")
        add("Сводка", "Обязательные требования", "Подтверждено: \(result.confirmedRequirements); не подтверждено: \(result.notConfirmedRequirements); не проверено: \(result.unknownRequirements)")
        add("Условия", "Ожидания в месяц", "\(c.salaryMin.isEmpty ? "?" : c.salaryMin) — \(c.salaryMax.isEmpty ? "?" : c.salaryMax) \(c.currency); \(c.basis.title)")
        add("Условия", "Сопоставление с бюджетом", CandidateEngine.salaryComparison(vacancy, c)); add("Условия", "Выход на работу", c.startDate)
        if includeContacts { add("Контакты", "Email", c.email); add("Контакты", "Телефон", c.phone) }
        for criterion in p.criteria {
            let r = result.criteria.first { $0.id == criterion.id }
            add("Критерий", criterion.name, "Важность \(criterion.weight); получено \(r?.received ?? 0) из \(r?.expected ?? 0); среднее \(r?.average.map { NumberText.display($0) } ?? "не проверено")\(r?.disagreement == true ? "; мнения расходятся" : "")")
            for card in active.filter({$0.stageID == criterion.stageID && criterion.reviewerIDs.contains($0.reviewerID)}).sorted(by: { a,b in (p.reviewers.first {$0.id == a.reviewerID}?.name ?? "") < (p.reviewers.first {$0.id == b.reviewerID}?.name ?? "") }) {
                guard let a = card.assessments.first(where: {$0.criterionID == criterion.id}) else { continue }
                let name = p.reviewers.first {$0.id == card.reviewerID}?.name ?? "Интервьюер"
                add("Оценка", "\(criterion.name) · \(name)", "\(a.rating.map(String.init) ?? "Не проверено"); \(a.rating == nil ? a.skipReason : a.evidence)")
            }
        }
        for requirement in p.requirements {
            let check = c.checks.first {$0.profileID == p.id && $0.requirementID == requirement.id}
            add("Требование", requirement.title, "\((check?.state ?? .unknown).title); \(check?.evidence ?? "")")
        }
        let latest = c.decisions.filter {$0.profileID == p.id}.max {$0.at < $1.at}
        if let d = latest { add("Решение", d.status.title, "\(d.author); \(ISO8601DateFormatter().string(from:d.at)); \(d.reason)") }
        else { add("Решение", "Решение по этой версии", "Пока не записано") }
        if !result.missing.isEmpty { add("Уточнить", "Недостающие оценки", result.missing.joined(separator: "\n")) }
        if includeNotes {
            add("Материалы", "Профессиональная справка", c.summary); add("Материалы", "Резюме", c.resumeText); add("Материалы", "Ссылка на резюме", c.resumeURL)
            add("Материалы", "Источник", c.source + (c.sourceDate.isEmpty ? "" : "; " + c.sourceDate)); add("Материалы", "Внутренние заметки", c.notes)
            for card in active { let name = p.reviewers.first {$0.id == card.reviewerID}?.name ?? "Интервьюер"; add("Интервью", name, "\(card.recommendation.title); \(card.comment)") }
        }
        return rows
    }
}

private final class CandidatePDF {
    let vacancy: Vacancy, candidates: [Candidate], includeContacts: Bool, includeNotes: Bool
    let width: CGFloat = 595.28, height: CGFloat = 841.89, margin: CGFloat = 42
    let ink = NSColor(srgbRed: 0.24, green: 0.19, blue: 0.16, alpha: 1)
    let muted = NSColor(srgbRed: 0.46, green: 0.38, blue: 0.32, alpha: 1)
    var context: CGContext!, page = 0, y: CGFloat = 0, currentCandidate = "", pageOpen = false
    var available: CGFloat { width - 2 * margin }
    var valueWidth: CGFloat { available - 156 }
    init(vacancy: Vacancy, candidates: [Candidate], includeContacts: Bool, includeNotes: Bool) { self.vacancy = vacancy; self.candidates = candidates; self.includeContacts = includeContacts; self.includeNotes = includeNotes }
    func render() throws -> Data {
        let data = NSMutableData()
        guard let consumer = CGDataConsumer(data:data), let ctx = CGContext(consumer:consumer, mediaBox:nil, [kCGPDFContextTitle as String: "Сравнение кандидатов", kCGPDFContextCreator as String: "ANODHAS AI"] as CFDictionary) else { throw AppError("Не удалось создать PDF.") }
        context = ctx
        do {
            for c in candidates {
                currentCandidate = c.name
                if pageOpen { endPage() }
                try beginPage()
                for r in CandidateTransfer.records(vacancy, candidate:c, includeContacts:includeContacts, includeNotes:includeNotes) { try row(r.section + " · " + r.label, r.value) }
                try paragraph("Баллы являются сводкой введённых оценок. Решение принимает человек. Основания могут содержать персональные сведения.", size:8, color:muted)
            }
            if pageOpen { endPage() }; context.closePDF()
            return data as Data
        } catch { if pageOpen { endPage() }; context.closePDF(); throw error }
    }
    func beginPage() throws {
        guard page < 300 else { throw AppError("Отчёт превышает 300 страниц. Выберите меньше кандидатов или исключите длинные заметки; данные не обрезаны.") }
        var rect = CGRect(x:0,y:0,width:width,height:height)
        let box = NSData(bytes:&rect,length:MemoryLayout<CGRect>.size)
        context.beginPDFPage([kCGPDFContextMediaBox as String:box] as CFDictionary); context.saveGState()
        context.translateBy(x:0,y:height); context.scaleBy(x:1,y:-1)
        NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = NSGraphicsContext(cgContext:context,flipped:true)
        page += 1; pageOpen = true; y = margin
        NSColor(srgbRed:1,green:0.988,blue:0.969,alpha:1).setFill();context.fill(CGRect(x:0,y:0,width:width,height:height))
        draw("Сравнение кандидатов",x:margin,y:y,width:available,size:18,bold:true);y += 28
        for line in wrapped(vacancy.title + " · версия \(vacancy.profile.number)",width:available,font:font(10,true)) { draw(line,x:margin,y:y,width:available,size:10,bold:true);y += 14 }
        for line in wrapped(currentCandidate,width:available,font:font(10,true)) { draw(line,x:margin,y:y,width:available,size:10,bold:true);y += 14 }
        let f = DateFormatter();f.locale = Locale(identifier:"ru_RU");f.dateFormat = "dd.MM.yyyy HH:mm"
        draw(f.string(from:Date()) + " · внутренний отчёт",x:margin,y:y,width:available,size:8,color:muted);y += 20
        NSColor(srgbRed:0.96,green:0.91,blue:0.86,alpha:1).setFill();context.fill(CGRect(x:margin,y:y,width:available,height:22))
        draw("Критерий / поле",x:margin+5,y:y+5,width:146,size:9,bold:true)
        draw("Значение и основания",x:margin+161,y:y+5,width:valueWidth-5,size:9,bold:true);y += 27
    }
    func endPage() {
        draw("Сравнение кандидатов · \(page)",x:margin,y:height-margin+8,width:available,size:8,color:muted)
        NSGraphicsContext.restoreGraphicsState();context.restoreGState();context.endPDFPage();pageOpen = false
    }
    func ensure(_ amount:CGFloat) throws { if y+amount>height-margin-20 { endPage();try beginPage() } }
    func row(_ label:String,_ value:String) throws {
        let left = wrapped(label,width:146,font:font(9,true)),right = wrapped(value,width:valueWidth-10,font:font(9))
        let count = max(left.count,right.count)
        for index in 0..<count {
            try ensure(14)
            if index<left.count { draw(left[index],x:margin+4,y:y,width:146,size:9,bold:true) }
            if index<right.count { draw(right[index],x:margin+160,y:y,width:valueWidth-10,size:9) }
            y += 14
        }
        context.setStrokeColor(NSColor(srgbRed:0.87,green:0.81,blue:0.75,alpha:1).cgColor);context.setLineWidth(0.4)
        context.move(to:CGPoint(x:margin,y:y+2));context.addLine(to:CGPoint(x:width-margin,y:y+2));context.strokePath();y += 8
    }
    func paragraph(_ text:String,size:CGFloat=10,color:NSColor?=nil) throws {
        for line in wrapped(text,width:available,font:font(size)) { try ensure(size*1.5);draw(line,x:margin,y:y,width:available,size:size,color:color);y += size*1.5 }; y += 4
    }
    func draw(_ text:String,x:CGFloat,y:CGFloat,width:CGFloat,size:CGFloat,bold:Bool=false,color:NSColor?=nil) {
        let style = NSMutableParagraphStyle();style.lineBreakMode = .byClipping
        (text as NSString).draw(in:CGRect(x:x,y:y,width:width,height:size*1.5),withAttributes:[.font:font(size,bold),.foregroundColor:color ?? ink,.paragraphStyle:style])
    }
    func font(_ size:CGFloat,_ bold:Bool=false)->NSFont { NSFont(name:bold ? "Arial-BoldMT":"ArialMT",size:size) ?? (bold ? NSFont.boldSystemFont(ofSize:size):NSFont.systemFont(ofSize:size)) }
    func wrapped(_ text:String,width:CGFloat,font:NSFont)->[String] {
        var lines:[String] = []
        func fits(_ s:String)->Bool { (s as NSString).size(withAttributes:[.font:font]).width <= width-1 }
        for p in text.components(separatedBy:.newlines) {
            if p.isEmpty { lines.append("");continue }
            var line = ""
            for token in p.split(whereSeparator:{$0.isWhitespace}) {
                let word = String(token),next = line.isEmpty ? word : line+" "+word
                if fits(next) { line = next;continue }
                if !line.isEmpty { lines.append(line);line = "" }
                if fits(word) { line = word;continue }
                for char in word { let part=line+String(char);if !fits(part) && !line.isEmpty { lines.append(line);line=String(char) } else { line=part } }
            }
            if !line.isEmpty { lines.append(line) }
        }
        return lines.isEmpty ? [""] : lines
    }
}
