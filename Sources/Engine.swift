import Foundation

enum CandidateEngine {
    static func activeCards(_ vacancy: Vacancy, candidateID: UUID, profileID: UUID) -> [Scorecard] {
        let cards = vacancy.cards.filter { $0.candidateID == candidateID && $0.profileID == profileID && $0.submittedAt != nil }
        return Dictionary(grouping: cards, by: \.key).values.compactMap { $0.max(by: { $0.revision < $1.revision }) }
    }
    static func result(_ vacancy: Vacancy, _ candidate: Candidate, profile: Profile? = nil) -> CandidateResult {
        let p = profile ?? vacancy.profile, cards = activeCards(vacancy, candidateID: candidate.id, profileID: p.id)
        var missing: [String] = []
        let criteria = p.criteria.map { c -> CriterionResult in
            var ratings: [Int] = []
            for reviewerID in c.reviewerIDs {
                let a = cards.first { $0.reviewerID == reviewerID && $0.stageID == c.stageID }?.assessments.first { $0.criterionID == c.id }
                if let a, let rating = a.rating, (1...5).contains(rating), !a.evidence.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { ratings.append(rating) }
                else { let name = p.reviewers.first { $0.id == reviewerID }?.name ?? "Интервьюер"; missing.append("\(c.name): \(name)") }
            }
            return CriterionResult(criterion: c, ratings: ratings, received: ratings.count, expected: c.reviewerIDs.count)
        }
        let totalWeight = p.criteria.reduce(0) { $0 + $1.weight }
        let valid = !criteria.isEmpty && criteria.allSatisfy { (1...5).contains($0.expected) && (1...100).contains($0.criterion.weight) }
        // LCM(1...5)=60 keeps all reviewer averages exact until the final division.
        func ratio(_ numerator: Int, _ denominator: Int) -> Decimal {
            guard denominator > 0 else { return 0 }
            var a = abs(numerator), b = denominator
            while b != 0 { let remainder = a % b; a = b; b = remainder }
            let divisor = max(1, a)
            return Decimal(numerator / divisor) / Decimal(denominator / divisor)
        }
        let covered = valid ? criteria.reduce(0) { $0 + $1.criterion.weight * $1.received * (60 / $1.expected) } : 0
        let coverage = valid && totalWeight > 0 ? ratio(100 * covered, totalWeight * 60) : 0
        let complete = valid && criteria.allSatisfy { $0.received == $0.expected }
        let score = complete ? ratio(criteria.reduce(0) { $0 + $1.criterion.weight * $1.ratings.reduce(0,+) * (60 / $1.expected) }, totalWeight * 60) : nil
        var yes = 0, no = 0, unknown = 0
        for req in p.requirements {
            switch candidate.checks.first(where: { $0.profileID == p.id && $0.requirementID == req.id })?.state ?? .unknown {
            case .confirmed: yes += 1; case .notConfirmed: no += 1; case .unknown: unknown += 1
            }
        }
        return CandidateResult(criteria: criteria, coverage: coverage, score: score, missing: missing, confirmedRequirements: yes, notConfirmedRequirements: no, unknownRequirements: unknown)
    }
    static func validateProfile(_ p: Profile, activating: Bool = false) throws {
        guard p.criteria.count <= 20, (1...3).contains(p.stages.count), (1...5).contains(p.reviewers.count), p.requirements.count <= 20 else { throw AppError("Пределы: 20 критериев, 20 требований, 3 этапа и 5 интервьюеров.") }
        for ids in [p.criteria.map(\.id),p.stages.map(\.id),p.reviewers.map(\.id),p.requirements.map(\.id)] { guard Set(ids).count == ids.count else { throw AppError("Повторяющийся идентификатор профиля.") } }
        guard p.number > 0 else { throw AppError("Некорректный номер версии.") }
        for c in p.criteria {
            guard (1...100).contains(c.weight), c.anchors.count == 5, p.stages.contains(where: { $0.id == c.stageID }), !c.reviewerIDs.isEmpty,
                  Set(c.reviewerIDs).count == c.reviewerIDs.count, c.reviewerIDs.allSatisfy({ id in p.reviewers.contains { $0.id == id } }) else { throw AppError("Проверьте важность, этап, интервьюеров и пять уровней критерия.") }
            if activating && (c.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || c.outcome.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || c.questions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || c.anchors.contains(where: { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })) { throw AppError("Для каждого критерия нужны название, рабочий результат, вопрос и пять описаний уровней.") }
            guard c.name.count <= 200 else { throw AppError("Название критерия: до 200 символов.") }
        }
        guard p.stages.allSatisfy({ $0.name.count <= 100 }), p.reviewers.allSatisfy({ $0.name.count <= 100 }), p.requirements.allSatisfy({ $0.title.count <= 500 }) else { throw AppError("Сократите название этапа/интервьюера до 100 символов, требование до 500.") }
        if activating {
            guard p.criteria.count >= 3, p.stages.allSatisfy({ !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }), p.reviewers.allSatisfy({ !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }), p.requirements.allSatisfy({ !$0.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else { throw AppError("Добавьте минимум три критерия и назовите этапы, интервьюеров и требования.") }
        }
    }
    static func draft(_ vacancy: Vacancy, candidateID: UUID, stageID: UUID, reviewerID: UUID) throws -> Scorecard {
        let p = vacancy.profile
        try validateProfile(p, activating: true)
        guard p.locked, vacancy.candidates.contains(where: {$0.id == candidateID}), p.stages.contains(where: {$0.id == stageID}), p.reviewers.contains(where: {$0.id == reviewerID}) else { throw AppError("Выберите кандидата и действующий план оценки.") }
        let cs = p.criteria.filter { $0.stageID == stageID && $0.reviewerIDs.contains(reviewerID) }
        guard !cs.isEmpty else { throw AppError("Этому интервьюеру не назначены критерии на выбранном этапе.") }
        let matches = vacancy.cards.filter { $0.candidateID == candidateID && $0.profileID == p.id && $0.stageID == stageID && $0.reviewerID == reviewerID }
        if let pending = matches.first(where: { $0.submittedAt == nil }) { return pending }
        let latest = matches.max { $0.revision < $1.revision }
        return Scorecard(candidateID: candidateID, profileID: p.id, stageID: stageID, reviewerID: reviewerID, revision: (latest?.revision ?? 0) + 1, assessments: latest?.assessments ?? cs.map { Assessment(criterionID: $0.id) }, recommendation: latest?.recommendation ?? .undecided, comment: latest?.comment ?? "")
    }
    static func validateCard(_ card: Scorecard, vacancy: Vacancy, submitting: Bool) throws {
        guard let p = vacancy.profiles.first(where: { $0.id == card.profileID }), p.locked,
              vacancy.candidates.contains(where: {$0.id == card.candidateID}), p.reviewers.contains(where: {$0.id == card.reviewerID}), p.stages.contains(where: {$0.id == card.stageID}), card.revision > 0 else { throw AppError("Карточка ссылается на неизвестного кандидата, интервьюера или профиль.") }
        let expected = p.criteria.filter { $0.stageID == card.stageID && $0.reviewerIDs.contains(card.reviewerID) }.map(\.id)
        guard !expected.isEmpty, Set(expected) == Set(card.assessments.map(\.criterionID)), card.assessments.count == expected.count else { throw AppError("Набор критериев карточки не совпадает с планом.") }
        for a in card.assessments {
            if let r = a.rating { guard (1...5).contains(r) else { throw AppError("Балл должен быть от 1 до 5; неизвестное оставьте без балла.") } }
            if submitting {
                if a.rating != nil && a.evidence.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { throw AppError("Укажите основание каждого балла.") }
                if a.rating == nil && a.skipReason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { throw AppError("Поясните, почему критерий не проверен.") }
            }
        }
        if submitting && card.comment.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { throw AppError("Добавьте общий комментарий к интервью.") }
        if submitting && card.revision > 1 && card.amendmentReason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { throw AppError("Укажите причину исправления отправленной оценки.") }
    }
    static func saveCard(_ card: Scorecard, in vacancy: inout Vacancy, submit: Bool) throws {
        guard card.submittedAt == nil else { throw AppError("Для записи нужна черновая карточка. Отправленная оценка сохраняется в истории.") }
        if let old = vacancy.cards.first(where: {$0.id == card.id}), old.submittedAt != nil { throw AppError("Отправленную карточку можно изменить только новой редакцией.") }
        guard !vacancy.cards.contains(where: {$0.id != card.id && $0.key == card.key && ($0.revision == card.revision || ($0.submittedAt == nil))}) else { throw AppError("Такая карточка или её черновик уже существует.") }
        let previous = vacancy.cards.filter { $0.key == card.key && $0.submittedAt != nil }.map(\.revision).max() ?? 0
        guard card.revision == previous + 1 else { throw AppError("Редакция карточки устарела. Откройте действующую карточку заново.") }
        try validateCard(card, vacancy: vacancy, submitting: submit)
        var next = card; if submit { next.submittedAt = Date() }
        if let index = vacancy.cards.firstIndex(where: {$0.id == next.id}) { vacancy.cards[index] = next } else { vacancy.cards.append(next) }
    }
    static func newVersion(_ vacancy: inout Vacancy) throws {
        guard vacancy.profiles.count < 30 else { throw AppError("Доступно до 30 версий одной вакансии. Для нового цикла создайте копию вакансии.") }
        var p = vacancy.profile; p.id = UUID(); p.number = (vacancy.profiles.map(\.number).max() ?? 0) + 1; p.createdAt = Date(); p.locked = false
        vacancy.profiles.append(p); vacancy.selectedProfileID = p.id
    }
    static func validateCandidate(_ c: Candidate) throws {
        guard !c.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, c.name.count <= 200 else { throw AppError("Укажите имя кандидата, до 200 символов.") }
        if !c.email.isEmpty && c.email.range(of: "^[^\\s@]+@[^\\s@]+\\.[^\\s@]+$", options: .regularExpression) == nil { throw AppError("Проверьте email кандидата.") }
        try validateRange(c.salaryMin,c.salaryMax)
        guard c.currency.range(of: "^[A-Z]{3}$",options:.regularExpression) != nil else { throw AppError("Валюта: три заглавные латинские буквы, например RUB.") }
        for date in [c.sourceDate,c.startDate] { try validateDate(date) }
        if !c.resumeURL.isEmpty { guard let u = URL(string:c.resumeURL), ["http","https"].contains(u.scheme?.lowercased() ?? ""), u.host != nil, u.user == nil, u.password == nil else { throw AppError("Ссылка на резюме должна начинаться с http:// или https:// без логина и пароля.") } }
    }
    static func validateDate(_ s: String) throws {
        guard !s.isEmpty else { return }
        let f=DateFormatter(); f.locale=Locale(identifier:"en_US_POSIX"); f.timeZone=TimeZone(secondsFromGMT:0); f.dateFormat="yyyy-MM-dd";f.isLenient=false
        guard s.count == 10, let d=f.date(from:s), f.string(from:d)==s else { throw AppError("Дата: ГГГГ-ММ-ДД; оставьте пустой, если неизвестна.") }
    }
    static func validateRange(_ low: String,_ high: String) throws { let l=try NumberText.money(low),h=try NumberText.money(high);if let l,let h,l>h { throw AppError("Минимальная сумма превышает максимальную.") } }
    static func salaryComparison(_ v: Vacancy,_ c: Candidate) -> String {
        guard v.currency == c.currency, v.basis != .unknown, v.basis == c.basis, let candidateMin = try? NumberText.money(c.salaryMin), let budgetMax = try? NumberText.money(v.budgetMax) else { return "Условия требуют уточнения" }
        return candidateMin > budgetMax ? "Ожидания выше бюджета" : "Минимальные ожидания в бюджете"
    }
    static func duplicates(_ c: Candidate, in candidates: [Candidate]) -> [UUID] {
        let email=c.email.trimmingCharacters(in:.whitespacesAndNewlines).lowercased(),phone=c.phone.filter(\.isNumber)
        return candidates.filter { $0.id != c.id && ((!email.isEmpty && $0.email.trimmingCharacters(in:.whitespacesAndNewlines).lowercased()==email) || (phone.count >= 7 && $0.phone.filter(\.isNumber)==phone)) }.map(\.id)
    }
    static func validateWorkspace(_ w: Workspace) throws {
        guard w.schemaVersion == 1, w.vacancies.count <= 100, Set(w.vacancies.map(\.id)).count == w.vacancies.count else { throw AppError("Некорректная версия или список вакансий.") }
        if let selected=w.selectedVacancyID { guard w.vacancies.contains(where: {$0.id == selected}) else { throw AppError("Выбранная вакансия не найдена.") } }
        for v in w.vacancies {
            guard !v.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, v.title.count <= 200 else { throw AppError("Название вакансии: от 1 до 200 символов.") }
            guard !v.profiles.isEmpty,v.profiles.count<=30,v.candidates.count<=100,v.cards.count<=100000,Set(v.profiles.map(\.id)).count==v.profiles.count,Set(v.profiles.map(\.number)).count==v.profiles.count,Set(v.candidates.map(\.id)).count==v.candidates.count,Set(v.cards.map(\.id)).count==v.cards.count else { throw AppError("Повторяющиеся ID или превышение размера вакансии.") }
            if let selected=v.selectedProfileID {guard v.profiles.contains(where: {$0.id == selected}) else {throw AppError("Версия профиля не найдена.")} }
            try validateRange(v.budgetMin,v.budgetMax)
            guard v.currency.range(of:"^[A-Z]{3}$",options:.regularExpression) != nil else {throw AppError("Проверьте валюту вакансии.")}
            for p in v.profiles { try validateProfile(p,activating:p.locked) }
            for c in v.candidates {
                try validateCandidate(c)
                guard Set(c.checks.map { "\($0.profileID):\($0.requirementID)" }).count==c.checks.count else {throw AppError("Повторяющаяся проверка требования.")}
                for x in c.checks { guard v.profiles.contains(where: {$0.id == x.profileID && $0.requirements.contains(where: {$0.id == x.requirementID})}) else {throw AppError("Неизвестное требование.")}; if x.state != .unknown && x.evidence.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty {throw AppError("У требования нет основания.")} }
                for d in c.decisions {guard v.profiles.contains(where: {$0.id == d.profileID}),!d.author.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty,!d.reason.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty else {throw AppError("У решения нет версии, автора или причины.")} }
            }
            var keys=Set<String>(),drafts=Set<String>()
            for card in v.cards {
                try validateCard(card,vacancy:v,submitting:card.submittedAt != nil)
                guard keys.insert(card.key+":\(card.revision)").inserted else {throw AppError("Повтор редакции карточки.")}
                if card.submittedAt==nil {guard drafts.insert(card.key).inserted else {throw AppError("Повтор черновика карточки.")} }
            }
            for group in Dictionary(grouping: v.cards, by: \.key).values {
                let sent = group.filter { $0.submittedAt != nil }.map(\.revision).sorted()
                guard sent == Array(0..<sent.count).map({ $0 + 1 }) else { throw AppError("Нарушена последовательность редакций.") }
                if let draft = group.first(where: { $0.submittedAt == nil }), draft.revision != (sent.last ?? 0) + 1 { throw AppError("Черновик редакции устарел.") }
            }
        }
        let raw = try JSONEncoder().encode(w)
        guard raw.count<=32*1024*1024 else {throw AppError("Рабочий файл больше 32 МБ.")}
        // Bound all user strings without logging their contents.
        func bound(_ object:Any) throws {if let s=object as? String,s.count>32000 {throw AppError("Поле длиннее 32000 символов.")};if let a=object as? [Any]{for x in a {try bound(x)}};if let d=object as? [String:Any]{for x in d.values {try bound(x)}}}
        try bound(JSONSerialization.jsonObject(with:raw))
    }
}
