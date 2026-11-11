import Foundation

func localizedText(_ key: String) -> String {
    Bundle.module.localizedString(forKey: key, value: nil, table: nil)
}

// Keep lookup in the package resource bundle, including when linked into the app.
func L(_ key: String, _ arguments: CVarArg...) -> String {
    String(format: localizedText(key),
           locale: Locale(identifier: Bundle.module.preferredLocalizations.first ?? "en"), arguments: arguments)
}

func LC(_ key: String, _ count: Int64) -> String {
    String(format: localizedText(key),
           locale: Locale(identifier: Bundle.module.preferredLocalizations.first ?? "en"), arguments: [count])
}

public enum MergePreferences {
    public static func preserveExtendedAttributes(in defaults: UserDefaults) -> Bool {
        defaults.object(forKey: "merge.preserveExtendedAttributes") as? Bool ?? true
    }
}

// These identifiers stay stable at the syscall/test boundary and in structured events.
func attributeDisplayName(_ attribute: String) -> String {
    switch attribute {
    case "権限ビット": return L("Permission bits")
    case "変更日": return L("Modification date")
    case "作成日": return L("Creation date")
    default: return attribute // Actual xattr names are never translated.
    }
}
