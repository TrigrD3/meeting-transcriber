import Foundation

extension AppSettings {
    /// Whether export of generated protocols to a Notion database is enabled.
    var notionExportEnabled: Bool {
        get { defaults.object(forKey: "notionExportEnabled") as? Bool ?? false }
        set { defaults.set(newValue, forKey: "notionExportEnabled") }
    }

    /// Notion API / Integration token, securely stored in the Keychain.
    var notionAPIKey: String {
        get { KeychainHelper.read(key: notionAPIKeyAccount) ?? "" }
        set {
            if newValue.isEmpty {
                KeychainHelper.delete(key: notionAPIKeyAccount)
            } else {
                KeychainHelper.save(key: notionAPIKeyAccount, value: newValue)
            }
        }
    }

    /// Notion Database ID or URL where meeting notes should be created.
    var notionDatabaseID: String {
        get { defaults.string(forKey: "notionDatabaseID") ?? "" }
        set { defaults.set(newValue, forKey: "notionDatabaseID") }
    }

    /// When true, skips saving the local .md file in the output folder if Notion export succeeds.
    /// In case of export failure or offline recording, the local .md file is always saved as backup.
    var notionSkipLocalMarkdownOnSuccess: Bool {
        get { defaults.object(forKey: "notionSkipLocalMarkdownOnSuccess") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "notionSkipLocalMarkdownOnSuccess") }
    }
}
