import Foundation
import Observation
import os
import Speech

private let logger = Logger(subsystem: AppPaths.logSubsystem, category: "DictationCaptions")

/// Runtime on-device locale discovery and system asset installation for captions.
/// The coordinator observes assetRevision and rewarms while idle after a download;
/// an ongoing recording keeps its fallback pipelines until it stops.
@MainActor
@Observable
final class DictationCaptionSupport {
    static let shared = DictationCaptionSupport()
    private(set) var locales: [Locale] = []
    private(set) var assetRevision = 0
    private(set) var isLoaded = false
    @ObservationIgnored private let discoverLocales: @Sendable () async -> [Locale]
    @ObservationIgnored private var discovery: Task<[Locale], Never>?
    @ObservationIgnored private var downloads: [String: Task<Void, Never>] = [:]

    init(discoverLocales: @escaping @Sendable () async -> [Locale] = DictationCaptionSupport.systemLocales) {
        self.discoverLocales = discoverLocales
    }

    nonisolated static func systemLocales() async -> [Locale] {
        if #available(macOS 26, *) { return await DictationTranscriber.supportedLocales }
        return []
    }

    func loadIfNeeded() async {
        guard !isLoaded else { return }
        let discover = discoverLocales
        let task = discovery ?? Task { await discover() }
        discovery = task
        let discovered = await task.value
        guard !isLoaded else { return }
        isLoaded = true
        locales = discovered
    }

    func supports(_ language: String) -> Bool {
        locale(for: language) != nil
    }

    func locale(for language: String) -> Locale? {
        let requested = Locale(identifier: language)
        return locales.first { $0.identifier == requested.identifier }
            ?? locales.first { $0.language.languageCode == requested.language.languageCode }
    }

    /// Returns immediately when assets are missing; installation proceeds once
    /// per locale in the background, leaving the active engine's fallback usable.
    func readyLocale(for language: String) async -> Locale? {
        guard #available(macOS 26, *), let locale = locale(for: language) else { return nil }
        let module = DictationTranscriber(locale: locale, preset: .progressiveLongDictation)
        if await Self.isInstalled(locale, module: module) { return locale }
        guard downloads[locale.identifier] == nil else { return nil }
        logger.info("Installing Dictation caption assets for \(locale.identifier, privacy: .public); using fallback until ready")
        downloads[locale.identifier] = Task {
            defer { downloads[locale.identifier] = nil }
            do {
                if let request = try await AssetInventory.assetInstallationRequest(supporting: [module]) {
                    try await request.downloadAndInstall()
                }
                // The same test as above, so a bump always finds the locale ready on rebuild.
                guard await Self.isInstalled(locale, module: module) else {
                    logger.warning("Dictation caption assets for \(locale.identifier, privacy: .public) still not installed after the request")
                    return
                }
                logger.info("Dictation caption assets ready for \(locale.identifier, privacy: .public)")
                assetRevision += 1
            } catch {
                logger.warning("Dictation asset installation failed: \(error.localizedDescription, privacy: .public)")
            }
        }
        return nil
    }

    @available(macOS 26, *)
    private static func isInstalled(_ locale: Locale, module: DictationTranscriber) async -> Bool {
        guard await DictationTranscriber.installedLocales.contains(locale) else { return false }
        return await AssetInventory.status(forModules: [module]) == .installed
    }
}
