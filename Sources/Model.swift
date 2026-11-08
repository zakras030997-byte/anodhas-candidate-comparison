import Foundation

struct AppError: LocalizedError { var message: String; init(_ message: String) { self.message = message }; var errorDescription: String? { message } }
enum PayBasis: String, Codable, CaseIterable, Identifiable {
    case unknown, gross, net
    var id: String { rawValue }
    var title: String { switch self { case .unknown: return "Не уточнено"; case .gross: return "До налогов"; case .net: return "После налогов" } }
}
enum CandidateStatus: String, Codable, CaseIterable, Identifiable {
    case new, assessing, discuss, next, offer, rejected, reserve, archived
    var id: String { rawValue }
    var title: String { switch self { case .new:return "Новый";case .assessing:return "В оценке";case .discuss:return "Обсудить";case .next:return "Следующий этап";case .offer:return "Предложение";case .rejected:return "Отказ";case .reserve:return "Резерв";case .archived:return "Архив" } }
}
enum Recommendation: String, Codable, CaseIterable, Identifiable {
    case undecided, proceed, discuss, stop
    var id: String { rawValue }
    var title: String { switch self {case .undecided:return "Пока нет решения";case .proceed:return "Продолжить";case .discuss:return "Обсудить";case .stop:return "Не продолжать"} }
}
enum RequirementState: String, Codable, CaseIterable, Identifiable {
    case unknown, confirmed, notConfirmed
    var id: String { rawValue }
    var title: String { switch self {case .unknown:return "Не проверено";case .confirmed:return "Подтверждено";case .notConfirmed:return "Не подтверждено"} }
}
struct Workspace: Codable, Equatable {
    var schemaVersion = 1
    var vacancies: [Vacancy] = []
    var selectedVacancyID: UUID?
}
struct Stage: Codable, Equatable, Identifiable { var id = UUID(); var name = "Интервью" }
struct Reviewer: Codable, Equatable, Identifiable { var id = UUID(); var name = "Руководитель" }
struct Criterion: Codable, Equatable, Identifiable {
    var id = UUID(); var name = ""; var outcome = ""; var weight = 1
    var stageID: UUID; var reviewerIDs: [UUID]
    var questions = ""
    var anchors = ["Не демонстрирует навык", "Нужна существенная помощь", "Выполняет обычные задачи самостоятельно", "Справляется со сложными задачами", "Решает сложные задачи и помогает другим"]
}
struct Requirement: Codable, Equatable, Identifiable { var id = UUID(); var title = "" }
struct Profile: Codable, Equatable, Identifiable {
    var id = UUID(); var number = 1; var createdAt = Date(); var locked = false
    var criteria: [Criterion] = []; var stages: [Stage] = [Stage()]; var reviewers: [Reviewer] = [Reviewer()]
    var requirements: [Requirement] = []
    static func blank() -> Profile { Profile() }
}
struct RequirementCheck: Codable, Equatable, Identifiable {
    var id = UUID(); var profileID: UUID; var requirementID: UUID
    var state: RequirementState = .unknown; var evidence = ""
}
struct Decision: Codable, Equatable, Identifiable {
    var id = UUID(); var profileID: UUID; var at = Date(); var status: CandidateStatus; var author: String; var reason: String
}
struct Candidate: Codable, Equatable, Identifiable {
    var id = UUID(); var name = ""; var email = ""; var phone = ""; var summary = ""; var resumeText = ""; var resumeURL = ""
    var source = ""; var sourceDate = ""; var salaryMin = ""; var salaryMax = ""; var currency = "RUB"; var basis: PayBasis = .unknown
    var startDate = ""; var notes = ""; var status: CandidateStatus = .new
    var checks: [RequirementCheck] = []; var decisions: [Decision] = []
}
struct Assessment: Codable, Equatable, Identifiable {
    var id: UUID { criterionID }; var criterionID: UUID; var rating: Int?; var evidence = ""; var skipReason = ""
}
struct Scorecard: Codable, Equatable, Identifiable {
    var id = UUID(); var candidateID: UUID; var profileID: UUID; var stageID: UUID; var reviewerID: UUID
    var revision = 1; var createdAt = Date(); var submittedAt: Date?; var amendmentReason = ""
    var assessments: [Assessment] = []; var recommendation: Recommendation = .undecided; var comment = ""
    var key: String { [candidateID, profileID, stageID, reviewerID].map(\.uuidString).joined(separator: ":") }
}
struct Vacancy: Codable, Equatable, Identifiable {
    var id = UUID(); var title = "Новая вакансия"; var tasks = ""; var workFormat = ""; var budgetMin = ""; var budgetMax = ""
    var currency = "RUB"; var basis: PayBasis = .unknown
    var profiles: [Profile] = [Profile.blank()]; var selectedProfileID: UUID?; var candidates: [Candidate] = []; var cards: [Scorecard] = []
    var updatedAt = Date()
    var profile: Profile { profiles.first(where: { $0.id == selectedProfileID }) ?? profiles.last! }
}
struct CriterionResult: Identifiable {
    var id: UUID { criterion.id }; var criterion: Criterion; var ratings: [Int]; var received: Int; var expected: Int
    var average: Decimal? { ratings.isEmpty ? nil : Decimal(ratings.reduce(0,+)) / Decimal(ratings.count) }
    var disagreement: Bool { (ratings.max() ?? 0) - (ratings.min() ?? 0) >= 2 }
}
struct CandidateResult {
    var criteria: [CriterionResult]; var coverage: Decimal; var score: Decimal?; var missing: [String]
    var confirmedRequirements: Int; var notConfirmedRequirements: Int; var unknownRequirements: Int
}
enum NumberText {
    static func money(_ text: String) throws -> Decimal? {
        let s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.isEmpty { return nil }
        let normalized = s.replacingOccurrences(of: ",", with: ".")
        guard normalized.range(of: "^[0-9]{1,10}(\\.[0-9]{1,2})?$", options: .regularExpression) != nil,
              let n = Decimal(string: normalized, locale: Locale(identifier: "en_US_POSIX")), n >= 0 else { throw AppError("Введите неотрицательную сумму с точностью до двух знаков.") }
        return n
    }
    static func display(_ value: Decimal, digits: Int = 2) -> String {
        var input = value; var out = Decimal(); NSDecimalRound(&out, &input, digits, .plain)
        let f = NumberFormatter(); f.locale = Locale(identifier: "ru_RU"); f.numberStyle = .decimal; f.minimumFractionDigits = digits; f.maximumFractionDigits = digits
        return f.string(from: NSDecimalNumber(decimal: out)) ?? NSDecimalNumber(decimal: out).stringValue
    }
}
