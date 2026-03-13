import Foundation

enum L10n {
    static var appName: String {
        tr("app.name", default: "Hyperkey")
    }

    static func tr(_ key: String, default value: String, _ arguments: CVarArg...) -> String {
        let format = Bundle.main.localizedString(forKey: key, value: value, table: "Localizable")
        guard !arguments.isEmpty else { return format }
        return String(format: format, locale: Locale.current, arguments: arguments)
    }
}
