//
//  StreamLanguageFilter.swift
//  NuvioTV
//
//  WatchParty: hide streams by audio language. The German Providers plugins put the
//  language into every stream name ("Huhu · Deutsch · voe.sx", "Aniworld · Japanisch,
//  dt. UT · …"); add-ons usually say "German"/"GER"/"DE" or show a flag. The stream
//  list and smart playback both read the filtered groups, so with "German only" the
//  auto-selected link is always a German one.
//

import Foundation

enum StreamLanguageFilter: String, CaseIterable {
    case all
    case germanAndSubtitled = "german_subtitled"
    case germanOnly = "german_only"

    static var current: StreamLanguageFilter {
        UserDefaults.standard.string(forKey: SettingsKey.streamLanguageFilter).flatMap(StreamLanguageFilter.init(rawValue:)) ?? .all
    }

    var label: String {
        switch self {
        case .all: return "Alle Sprachen"
        case .germanAndSubtitled: return "Deutsch und deutsche Untertitel"
        case .germanOnly: return "Nur Deutsch"
        }
    }
}

enum StreamLanguageClassifier {
    enum Language { case german, germanSubtitled, other, unknown }

    private static func regex(_ pattern: String, caseInsensitive: Bool = true) -> NSRegularExpression? {
        try? NSRegularExpression(pattern: pattern, options: caseInsensitive ? [.caseInsensitive] : [])
    }

    private static let subtitled = regex(#"dt\.\s*UT|\bOmU\b|ger(man)?[\s._-]*sub|deutsche?\s+untertitel|untertitel\s+deutsch"#)
    private static let german = regex(#"deutsch|\bgerman\b|\bger\b|\bdeu\b"#)
    // upper case only: a lower-case "de" is a word in French, Spanish and Dutch titles
    private static let germanCode = regex(#"\bDE\b|🇩🇪"#, caseInsensitive: false)
    private static let other = regex(
        #"englisch|\benglish\b|\beng\b|französisch|\bfrench\b|spanisch|\bspanish\b|italienisch|\bitalian\b|"# +
        #"japanisch|\bjapanese\b|türkisch|\bturkish\b|russisch|\brussian\b|\bOV\b|original|\bmulti\b|🇬🇧|🇺🇸"#
    )

    private static func matches(_ re: NSRegularExpression?, _ text: String) -> Bool {
        guard let re else { return false }
        return re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    static func classify(_ stream: NuvioStream) -> Language {
        let text = [stream.name, stream.description].compactMap { $0 }.joined(separator: " · ")
        if matches(subtitled, text) { return .germanSubtitled }
        if matches(german, text) || matches(germanCode, text) { return .german }
        if matches(other, text) { return .other }
        return .unknown
    }

    /// `.unknown` stays visible for `.all` only: an add-on that names no language is not known to be German.
    static func keeps(_ stream: NuvioStream, filter: StreamLanguageFilter) -> Bool {
        switch filter {
        case .all: return true
        case .germanAndSubtitled:
            let language = classify(stream)
            return language == .german || language == .germanSubtitled
        case .germanOnly: return classify(stream) == .german
        }
    }

    static func apply(_ groups: [AddonStreamGroup], filter: StreamLanguageFilter) -> [AddonStreamGroup] {
        guard filter != .all else { return groups }
        return groups.map { group in
            var copy = group
            copy.streams = group.streams.filter { keeps($0, filter: filter) }
            return copy
        }
    }
}
