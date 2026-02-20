//
//  SportIcon.swift
//  NexusPVR
//
//  Sport detection and icon display for EPG programs
//

import SwiftUI

// MARK: - Sport Enum

enum Sport: CaseIterable {
    case hockey
    case basketball
    case americanFootball
    case soccer
    case baseball
    case tennis
    case golf
    case boxing
    case wrestling
    case swimming
    case alpineSkiing
    case crossCountrySkiing
    case figureSkating
    case speedSkating
    case snowboarding
    case curling
    case cycling
    case rugby
    case volleyball
    case cricket
    case handball
    case motorRacing
    case trackAndField
    case surfing
    case sailing
    case rowing
    case waterPolo
    case equestrian
    case gymnastics
    case fencing
    case archery
    case badminton
    case tableTennis
    case bobsled
    case skiJumping
    case pool
    case darts
    case generic

    var sfSymbol: String {
        switch self {
        case .hockey: return "hockey.puck"
        case .basketball: return "basketball"
        case .americanFootball: return "football"
        case .soccer: return "soccerball"
        case .baseball: return "baseball"
        case .tennis: return "tennisball"
        case .golf: return "figure.golf"
        case .boxing: return "figure.boxing"
        case .wrestling: return "figure.wrestling"
        case .swimming: return "figure.pool.swim"
        case .alpineSkiing: return "figure.skiing.downhill"
        case .crossCountrySkiing: return "figure.skiing.crosscountry"
        case .figureSkating: return "figure.gymnastics"
        case .speedSkating: return "figure.skating"
        case .snowboarding: return "figure.snowboarding"
        case .curling: return "figure.curling"
        case .cycling: return "bicycle"
        case .rugby: return "figure.rugby"
        case .volleyball: return "volleyball"
        case .cricket: return "cricket.ball"
        case .handball: return "figure.handball"
        case .motorRacing: return "car"
        case .trackAndField: return "figure.track.and.field"
        case .surfing: return "figure.surfing"
        case .sailing: return "figure.sailing"
        case .rowing: return "figure.rowing"
        case .waterPolo: return "figure.water.polo"
        case .equestrian: return "figure.equestrian.sports"
        case .gymnastics: return "figure.gymnastics"
        case .fencing: return "figure.fencing"
        case .archery: return "figure.archery"
        case .badminton: return "figure.badminton"
        case .tableTennis: return "figure.table.tennis"
        case .bobsled: return "figure.skiing.downhill"
        case .skiJumping: return "figure.skiing.downhill"
        case .pool: return "8.circle"
        case .darts: return "target"
        case .generic: return "trophy"
        }
    }

    /// Keywords for detection
    var keywords: [String] {
        switch self {
        case .hockey: return ["hockey", "nhl", "lnh"]
        case .basketball: return ["basketball", "nba"]
        case .americanFootball: return ["american football", "super bowl", "nfl", "cfl"]
        case .soccer: return ["champions league", "premier league", "europa league", "la liga", "bundesliga", "serie a", "ligue 1", "football", "soccer", "mls", "fifa"]
        case .baseball: return ["baseball", "mlb"]
        case .tennis: return ["roland garros", "wimbledon", "tennis"]
        case .golf: return ["golf", "pga"]
        case .boxing: return ["boxing", "boxe", "ufc", "mma"]
        case .wrestling: return ["wrestling", "wwe"]
        case .swimming: return ["swimming", "natation"]
        case .alpineSkiing: return ["alpine skiing", "ski alpin", "downhill skiing", "super-g", "super g", "slalom"]
        case .crossCountrySkiing: return ["cross-country", "ski de fond", "biathlon"]
        case .figureSkating: return ["figure skating", "patinage artistique"]
        case .speedSkating: return ["speed skating", "short track", "patinage de vitesse"]
        case .snowboarding: return ["snowboard"]
        case .curling: return ["curling"]
        case .cycling: return ["tour de france", "giro", "cycling", "cyclisme"]
        case .rugby: return ["rugby"]
        case .volleyball: return ["volleyball"]
        case .cricket: return ["cricket"]
        case .handball: return ["handball"]
        case .motorRacing: return ["formula 1", "grand prix", "motorsport", "nascar", "indycar", "f1"]
        case .trackAndField: return ["track and field", "athletics", "athlétisme"]
        case .surfing: return ["surfing"]
        case .sailing: return ["sailing", "voile"]
        case .rowing: return ["rowing", "aviron"]
        case .waterPolo: return ["water polo"]
        case .equestrian: return ["equestrian", "horse racing"]
        case .gymnastics: return ["gymnastics", "gymnastique"]
        case .fencing: return ["fencing", "escrime"]
        case .archery: return ["archery"]
        case .badminton: return ["badminton"]
        case .tableTennis: return ["table tennis", "ping pong"]
        case .bobsled: return ["bobsled", "bobsleigh", "luge", "skeleton"]
        case .skiJumping: return ["ski jumping", "saut à ski"]
        case .pool: return ["pool", "snooker", "billiard", "billard"]
        case .darts: return ["darts", "fléchettes"]
        case .generic: return []
        }
    }
}

// MARK: - Sport Detector

enum SportDetector {
    /// Generic genre terms that indicate sport content but not which sport
    private static let genericSportGenres = ["sport", "sports", "olympic", "olympics", "olympique", "olympiques"]

    /// All sport keywords sorted by length descending so multi-word phrases match first
    private static let sortedKeywordMap: [(keyword: String, sport: Sport)] = {
        var map: [(String, Sport)] = []
        for sport in Sport.allCases where sport != .generic {
            for keyword in sport.keywords {
                map.append((keyword, sport))
            }
        }
        return map.sorted { $0.0.count > $1.0.count }
    }()

    /// Main detection: genres are authoritative, then fall back to name + description
    ///
    /// 1. If a genre matches a specific sport keyword → return that sport (e.g. genre "Pool" → pool)
    /// 2. If genres only contain generic terms ("Sports", "Olympic") → check name + desc
    /// 3. If no sport-related genre at all → check name + desc
    static func detect(name: String, desc: String?, genres: [String]?) -> Sport? {
        let result: Sport?

        if let genres {
            let genresLower = genres.map { $0.lowercased() }

            // Check genres for a specific sport match
            var genreMatch: Sport?
            for (keyword, sport) in sortedKeywordMap {
                if genresLower.contains(where: { $0.contains(keyword) }) {
                    genreMatch = sport
                    break
                }
            }

            if let sport = genreMatch {
                result = sport
            } else {
                // If genre indicates sport generically, check name + desc for specifics
                let hasGenericSport = genresLower.contains(where: { genre in
                    genericSportGenres.contains(where: { genre.contains($0) })
                })
                result = hasGenericSport ? detectFromText(name: name, desc: desc) : nil
            }
        } else {
            // No genres at all — check name + desc
            result = detectFromText(name: name, desc: desc)
        }

        return result
    }

    /// Search name then description for sport keywords
    private static func detectFromText(name: String, desc: String?) -> Sport? {
        let nameLower = name.lowercased()
        for (keyword, sport) in sortedKeywordMap {
            if nameLower.contains(keyword) {
                return sport
            }
        }
        if let desc {
            let descLower = desc.lowercased()
            for (keyword, sport) in sortedKeywordMap {
                if descLower.contains(keyword) {
                    return sport
                }
            }
        }
        return nil
    }

    #if !TOPSHELF_EXTENSION
    static func detect(from program: Program) -> Sport? {
        detect(name: program.name, desc: program.desc, genres: program.genres)
    }
    #endif

    static func detect(from recording: Recording) -> Sport? {
        detect(name: recording.name, desc: recording.desc, genres: recording.genres)
    }

    static func detect(fromKeyword keyword: String) -> Sport? {
        let keywordLower = keyword.lowercased()
        for (kw, sport) in sortedKeywordMap {
            if keywordLower.contains(kw) || kw.contains(keywordLower) {
                return sport
            }
        }
        return nil
    }
}

#if !TOPSHELF_EXTENSION
// MARK: - Sport Icon View

struct SportIconView: View {
    let sport: Sport
    var size: CGFloat = {
        #if os(tvOS)
        return 48
        #else
        return 32
        #endif
    }()

    var body: some View {
        ZStack {
            Circle()
                .fill(Theme.textSecondary.opacity(0.1))

            Image(systemName: sport.sfSymbol)
                .font(.system(size: size * 0.45))
                .foregroundStyle(Theme.textSecondary.opacity(0.6))
        }
        .frame(width: size, height: size)
    }
}

#Preview("Sport Icons") {
    ScrollView {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 80))], spacing: 12) {
            ForEach(Sport.allCases, id: \.self) { sport in
                VStack(spacing: 4) {
                    SportIconView(sport: sport)
                    Text("\(sport)")
                        .font(.caption2)
                        .foregroundStyle(Theme.textSecondary)
                }
            }
        }
        .padding()
    }
    .background(Theme.background)
    .preferredColorScheme(.dark)
}
#endif
