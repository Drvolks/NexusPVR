//
//  DemoDataProvider.swift
//  PVR Client
//
//  Provides static demo data when server host is "demo"
//

import Foundation

struct DemoDataProvider {

    // MARK: - In-Memory Recording State

    /// Event IDs scheduled by the user during this session
    private static var userScheduledEventIds = Set<Int>()
    /// Recording IDs cancelled by the user during this session (includes pre-seeded ones)
    private static var cancelledRecordingIds = Set<Int>()

    static func scheduleRecording(eventId: Int) {
        userScheduledEventIds.insert(eventId)
    }

    static func cancelRecording(recordingId: Int) {
        // If it's a user-scheduled recording, remove from that set
        // User-scheduled recording IDs = eventId + 100_000
        let eventId = recordingId - 100_000
        if userScheduledEventIds.contains(eventId) {
            userScheduledEventIds.remove(eventId)
        } else {
            // It's a pre-seeded recording — mark as cancelled
            cancelledRecordingIds.insert(recordingId)
        }
    }

    // MARK: - Channels

    static let channels: [Channel] = [
        Channel(id: 1001, name: "SportsCenter HD", number: 1, hasIcon: true),
        Channel(id: 1002, name: "News 24/7", number: 2, hasIcon: true),
        Channel(id: 1003, name: "Hockey Night", number: 3, hasIcon: true),
        Channel(id: 1004, name: "The Movie Channel", number: 4, hasIcon: true),
        Channel(id: 1005, name: "Comedy Gold", number: 5, hasIcon: true),
        Channel(id: 1006, name: "Nature & Discovery", number: 6, hasIcon: true),
        Channel(id: 1007, name: "Premier League TV", number: 7, hasIcon: true),
        Channel(id: 1008, name: "Breaking News Now", number: 8, hasIcon: true),
        Channel(id: 1009, name: "Sci-Fi Universe", number: 9, hasIcon: true),
        Channel(id: 1010, name: "Food Network Plus", number: 10, hasIcon: true),
        Channel(id: 1011, name: "Classic TV", number: 11, hasIcon: true),
        Channel(id: 1012, name: "Kids & Family", number: 12, hasIcon: true),
        Channel(id: 1013, name: "Music Television", number: 13, hasIcon: true),
        Channel(id: 1014, name: "True Crime", number: 14, hasIcon: true),
        Channel(id: 1015, name: "Travel & Adventure", number: 15, hasIcon: true),
        Channel(id: 1016, name: "History Channel", number: 16, hasIcon: true),
        Channel(id: 1017, name: "Public Broadcasting", number: 17, hasIcon: true),
    ]

    // MARK: - Channel Icons

    static func channelIconURL(channelId: Int) -> URL? {
        Bundle.main.url(forResource: "demo_icon_\(channelId)", withExtension: "png")
    }

    // MARK: - EPG Listings

    /// Program templates per channel: (name, subtitle, description, genre, duration in minutes)
    private static let programTemplates: [Int: [(String, String?, String, [String], Int)]] = [
        1001: [
            ("Morning Sports Roundup", nil, "All the highlights from last night's games.", ["Sports"], 60),
            ("The Debate: Should Pineapple Be on Pizza?", "Special Edition", "Athletes weigh in on the most controversial topic in food.", ["Sports", "Entertainment"], 30),
            ("Extreme Ironing Championship", "Season 4", "The world's most intense ironing competition goes international.", ["Sports"], 90),
            ("Top 10 Plays of the Week", nil, "Countdown of the most jaw-dropping athletic feats.", ["Sports"], 30),
            ("Sideline Stories", "Episode 12", "Behind-the-scenes moments you missed during the big games.", ["Sports"], 60),
            ("Fantasy Draft Live", nil, "Expert analysis for your fantasy league picks.", ["Sports"], 120),
            ("Classic Games Rewind", "1998 Finals", "Relive the most iconic moments in sports history.", ["Sports"], 120),
            ("Sports Bloopers & Fails", nil, "The funniest moments from this season.", ["Sports", "Comedy"], 30),
            ("Late Night Scoreboard", nil, "Final scores and post-game reactions.", ["Sports"], 60),
        ],
        1002: [
            ("Early Morning Briefing", nil, "Your essential news to start the day.", ["News"], 60),
            ("World Report", nil, "International news coverage from our global correspondents.", ["News"], 60),
            ("Evening News with Anderson Scooper", nil, "In-depth reporting on the stories that matter most.", ["News"], 60),
            ("The Weather Hour", nil, "Extended weather forecasts and climate analysis.", ["News", "Weather"], 60),
            ("Tech & Science Today", nil, "Latest breakthroughs in technology and scientific research.", ["News", "Science"], 30),
            ("Political Roundtable", nil, "Analysts debate the week's biggest political developments.", ["News", "Politics"], 90),
            ("Health Watch", nil, "Medical news and wellness tips from leading experts.", ["News", "Health"], 30),
            ("Financial Markets Update", nil, "Stock market analysis and economic trends.", ["News", "Finance"], 60),
            ("Newsroom Overnight", nil, "Continuous coverage of breaking stories around the world.", ["News"], 120),
        ],
        1003: [
            ("Hockey: Poutine Pucks vs Maple Laughs", nil, "Original Six rivalry night at the Beluga Centre.", ["Sports", "Hockey"], 180),
            ("Hockey Legends", "Wayne Pretzelsky", "Documentary on The Doughy One's incredible career.", ["Sports", "Documentary"], 60),
            ("Hockey: Spoilers vs Flambés", nil, "Battle of Alburta heats up.", ["Sports", "Hockey"], 180),
            ("Between the Pipes", nil, "A look at the art of goaltending through the decades.", ["Sports", "Hockey"], 60),
            ("Junior Hockey Showcase", nil, "Tomorrow's stars compete today.", ["Sports", "Hockey"], 120),
            ("Zamboni Chronicles", nil, "The unsung heroes of ice maintenance tell their stories.", ["Sports", "Comedy"], 30),
            ("Hockey Night Replay", nil, "Best moments from the week's games.", ["Sports", "Hockey"], 120),
        ],
        1004: [
            ("Cinema Classics: The Great Adventure", nil, "A timeless tale of courage and friendship.", ["Movie", "Drama"], 120),
            ("Conspiracy Kitchen: The Flat Pancake Theory", nil, "A chef discovers the truth about breakfast conspiracies.", ["Movie", "Comedy"], 90),
            ("Alien Accountants", "Director's Cut", "Even extraterrestrials need to file their taxes.", ["Movie", "Sci-Fi", "Comedy"], 105),
            ("The Art of the Heist", nil, "A retired thief plans one last museum job.", ["Movie", "Thriller"], 120),
            ("Behind the Scenes", nil, "How your favorite movies were really made.", ["Documentary", "Entertainment"], 60),
            ("Midnight Mystery Theater", nil, "A classic whodunit with a twist you won't see coming.", ["Movie", "Mystery"], 90),
            ("Saturday Matinee: Space Cowboys", nil, "Cowboys. In space. What more do you need?", ["Movie", "Western", "Sci-Fi"], 120),
        ],
        1005: [
            ("Underwater Basket Weaving Finals", nil, "The pinnacle of aquatic craftsmanship competition.", ["Comedy", "Sports"], 60),
            ("Stand-Up Spotlight", "Season 3", "The funniest comedians perform their best sets.", ["Comedy"], 60),
            ("Sitcom Marathon: Office Antics", nil, "Back-to-back episodes of workplace comedy gold.", ["Comedy"], 120),
            ("Improv Hour", nil, "Unscripted comedy at its finest. Anything can happen.", ["Comedy"], 60),
            ("Pets Do the Darndest Things", nil, "Hilarious home videos of animals being animals.", ["Comedy", "Family"], 30),
            ("Roast Battle Championship", nil, "Comedians trade their best insults on stage.", ["Comedy"], 90),
            ("Comedy Documentary: The History of Laughter", nil, "From ancient jesters to modern memes.", ["Comedy", "Documentary"], 60),
            ("Late Night Laughs", nil, "The best monologues and sketches from late night.", ["Comedy", "Entertainment"], 90),
            ("Blooper Reel Bonanza", nil, "When filming goes hilariously wrong.", ["Comedy"], 60),
        ],
        1006: [
            ("Planet Earth: The Forgotten Forests", nil, "Exploring ancient woodlands untouched by civilization.", ["Documentary", "Nature"], 60),
            ("Documentary: How Cat Videos Conquered the Internet", nil, "The surprisingly complex story of feline internet fame.", ["Documentary", "Technology"], 90),
            ("Ocean Mysteries", "The Deep", "Creatures of the abyss that defy imagination.", ["Documentary", "Nature"], 60),
            ("Volcano Hunters", nil, "Scientists risk everything to study active eruptions.", ["Documentary", "Science"], 60),
            ("Migration: The Great Journey", nil, "Following animals across continents and oceans.", ["Documentary", "Nature"], 120),
            ("Microscopic World", nil, "The hidden universe living in a drop of water.", ["Documentary", "Science"], 60),
            ("Desert Survivors", nil, "How life thrives in Earth's harshest environments.", ["Documentary", "Nature"], 60),
            ("Night Safari", nil, "Discovering the creatures that only come out after dark.", ["Documentary", "Nature"], 90),
        ],
        1007: [
            ("Football: Artisanal FC vs Cheddar United", nil, "London derby at the Sourdough Stadium.", ["Sports", "Soccer"], 120),
            ("Match of the Day", nil, "Highlights and analysis from all today's fixtures.", ["Sports", "Soccer"], 90),
            ("Football: Liverpuddle vs Nap City", nil, "Title race showdown at Anchovy Road.", ["Sports", "Soccer"], 120),
            ("Tactics Board", nil, "Expert breakdown of formations and strategies.", ["Sports", "Soccer"], 30),
            ("Youth Academy Report", nil, "The next generation of football superstars.", ["Sports", "Soccer"], 60),
            ("Transfer Window Special", nil, "Rumors, deals, and deadline day drama.", ["Sports", "Soccer"], 60),
            ("Football Legends", "Terry Croissant", "The story of Artisanal FC's all-time greatest striker.", ["Sports", "Documentary"], 60),
            ("Goal of the Month", nil, "Vote for the best strike from the past 30 days.", ["Sports", "Soccer"], 30),
        ],
        1008: [
            ("Breaking News Bulletin", nil, "Live coverage of developing stories.", ["News"], 30),
            ("Investigative Report: The Paper Trail", nil, "Following the money in a shocking corruption case.", ["News", "Documentary"], 60),
            ("Global Crisis Watch", nil, "Monitoring hotspots and humanitarian situations worldwide.", ["News"], 60),
            ("Fact Check Live", nil, "Real-time verification of claims from today's headlines.", ["News"], 30),
            ("The Big Interview", nil, "One-on-one with a world leader making headlines.", ["News"], 60),
            ("Breaking Down the Headlines", nil, "Expert panel discussion on the day's top stories.", ["News"], 90),
            ("Crime & Justice Report", nil, "Major legal developments and courtroom coverage.", ["News"], 60),
            ("Eyewitness Accounts", nil, "First-person stories from people at the center of the news.", ["News", "Documentary"], 60),
            ("Overnight News Desk", nil, "Keeping you informed while the world sleeps.", ["News"], 120),
        ],
        1009: [
            ("Galactic Senate Hearings", nil, "Bureaucracy in space is still bureaucracy.", ["Sci-Fi", "Drama"], 60),
            ("Robot Roommate", "Season 2", "When your flatmate is an AI with strong opinions about dishes.", ["Sci-Fi", "Comedy"], 30),
            ("Time Traveler's Warranty", nil, "He went back to fix his toaster. He broke the timeline.", ["Sci-Fi", "Movie"], 120),
            ("Alien Cooking Show", nil, "Interstellar cuisine with ingredients from 12 star systems.", ["Sci-Fi", "Entertainment"], 60),
            ("The Quantum Detective", "Episode 8", "She solves crimes in multiple dimensions simultaneously.", ["Sci-Fi", "Mystery"], 60),
            ("Mars Colony News", nil, "Traffic, weather, and dust storm warnings for the red planet.", ["Sci-Fi", "Comedy"], 30),
            ("Space Truckers", "Season 5", "Long haul freight across the asteroid belt.", ["Sci-Fi", "Drama"], 60),
            ("B-Movie Marathon: Attack of the Giant Hamsters", nil, "They're fluffy. They're enormous. They're hungry.", ["Sci-Fi", "Movie"], 90),
            ("Starship Mechanic", nil, "Fixing hyperdrives on a budget.", ["Sci-Fi"], 60),
        ],
        1010: [
            ("Competitive Toast Making", "Grand Finals", "Bread, butter, and unbreakable determination.", ["Food", "Competition"], 60),
            ("Iron Chef: Leftovers Edition", nil, "World-class chefs transform last night's dinner into art.", ["Food", "Competition"], 60),
            ("Bake It Till You Make It", "Season 3", "Amateur bakers face impossible pastry challenges.", ["Food", "Competition"], 90),
            ("Street Food Stories", "Tokyo", "Hidden gems in the world's greatest food cities.", ["Food", "Documentary"], 60),
            ("The Spice Route", nil, "A journey through the history and science of flavor.", ["Food", "Documentary"], 60),
            ("Dinner Disasters", nil, "When home cooks get creative and things go spectacularly wrong.", ["Food", "Comedy"], 30),
            ("Farm to Table", nil, "Following ingredients from field to Michelin-star plate.", ["Food", "Documentary"], 60),
            ("Midnight Snack Wars", nil, "Late-night cooking battles with only pantry staples.", ["Food", "Competition"], 60),
        ],
        1011: [
            ("The Golden Reruns: Sitcom Classics", nil, "The shows that defined a generation of comedy.", ["Classic TV", "Comedy"], 30),
            ("Vintage Variety Hour", nil, "Song, dance, and sketch comedy from the golden age.", ["Classic TV", "Entertainment"], 60),
            ("Detective Anthology", "Season 1", "Classic whodunits with trench coats and jazz soundtracks.", ["Classic TV", "Mystery"], 60),
            ("Retro Game Show Marathon", nil, "Spinning wheels and flipping tiles all afternoon.", ["Classic TV", "Game Show"], 30),
            ("Western Theater", nil, "Cowboys, outlaws, and dusty showdowns.", ["Classic TV", "Western"], 60),
            ("Anthology Hour: Tales of the Unexpected", nil, "Twist endings that still surprise decades later.", ["Classic TV", "Drama"], 60),
            ("The Nostalgia Block", nil, "Back-to-back episodes of your childhood favorites.", ["Classic TV"], 120),
            ("Classic TV Documentary: Behind the Laugh Track", nil, "The untold story of television's early years.", ["Classic TV", "Documentary"], 90),
        ],
        1012: [
            ("Captain Penguin's Adventure Island", nil, "Educational fun with everyone's favorite flightless hero.", ["Kids", "Animation"], 30),
            ("The Magic School Bus Stop", "Season 2", "Field trips to impossible places, now with seatbelts.", ["Kids", "Education"], 30),
            ("Dinosaur Dance Party", nil, "Prehistoric creatures teach rhythm and movement.", ["Kids", "Animation"], 30),
            ("Space Puppies", nil, "Adorable dogs explore the solar system.", ["Kids", "Animation"], 30),
            ("Professor Puzzle's Brain Games", nil, "Logic puzzles and riddles for young minds.", ["Kids", "Education"], 60),
            ("Fairy Tale Theater", nil, "Classic stories retold with modern twists.", ["Kids", "Drama"], 60),
            ("Robot Friends", "Season 4", "Building, coding, and friendship in Technoville.", ["Kids", "Animation"], 30),
            ("Bedtime Stories", nil, "Gentle tales to wind down the day.", ["Kids", "Animation"], 30),
            ("Silly Science Lab", nil, "Experiments that are messy, loud, and educational.", ["Kids", "Education"], 30),
        ],
        1013: [
            ("Morning Mix: Today's Hits", nil, "Start your day with the biggest songs of the moment.", ["Music"], 120),
            ("Unplugged Sessions", "Episode 22", "Artists strip back their hits to acoustic perfection.", ["Music", "Live"], 60),
            ("Hip Hop Countdown", nil, "This week's hottest tracks ranked by the fans.", ["Music"], 60),
            ("Rock Legends: Behind the Riffs", nil, "The stories behind the most iconic guitar solos.", ["Music", "Documentary"], 90),
            ("Vinyl Hour", nil, "Deep cuts and rare recordings from the golden age.", ["Music"], 60),
            ("DJ Battle Royale", nil, "Turntablists go head-to-head in an epic mix-off.", ["Music", "Competition"], 60),
            ("Music Video Marathon", nil, "Non-stop visuals from the best in the business.", ["Music"], 120),
            ("Songwriter's Circle", nil, "Hit writers reveal the inspirations behind chart-toppers.", ["Music", "Documentary"], 60),
        ],
        1014: [
            ("Cold Case Files", "Season 7", "Decades-old mysteries finally solved by modern forensics.", ["True Crime", "Documentary"], 60),
            ("The Evidence Room", nil, "Forensic experts re-examine infamous crime scene evidence.", ["True Crime"], 60),
            ("Heist: The Art Thieves", nil, "Inside the most audacious museum robberies in history.", ["True Crime", "Documentary"], 90),
            ("Interrogation Tapes", nil, "Real footage from the most revealing suspect interviews.", ["True Crime"], 60),
            ("Missing Persons Unit", "Episode 15", "Investigators race against time to bring people home.", ["True Crime", "Drama"], 60),
            ("Fraud Squad", nil, "Con artists, scammers, and the detectives who catch them.", ["True Crime"], 60),
            ("Forensic Files Revisited", nil, "Science meets detective work in baffling cases.", ["True Crime", "Science"], 30),
            ("Crime Scene to Courtroom", nil, "Following cases from initial evidence to final verdict.", ["True Crime"], 90),
        ],
        1015: [
            ("Hidden Beaches of the World", nil, "Secret coastal paradises most tourists never find.", ["Travel", "Documentary"], 60),
            ("Backpack Budget Challenge", "Season 3", "Exploring entire countries on just $20 a day.", ["Travel", "Competition"], 60),
            ("Mountain Expedition: K2", nil, "Following climbers on the world's most dangerous ascent.", ["Travel", "Adventure"], 90),
            ("Rail Journeys", "Trans-Siberian", "Epic train routes through breathtaking landscapes.", ["Travel", "Documentary"], 60),
            ("Taste the World", nil, "A food-focused tour of cultures and cuisines.", ["Travel", "Food"], 60),
            ("Urban Explorer", nil, "Abandoned buildings and forgotten places revealed.", ["Travel", "Adventure"], 60),
            ("Island Hopping", nil, "Finding paradise one island at a time.", ["Travel"], 60),
            ("Extreme Adventures", nil, "Skydiving, bungee jumping, and other ways to test your limits.", ["Travel", "Adventure"], 90),
        ],
        1016: [
            ("Ancient Empires", "Rome", "The rise and fall of civilization's greatest empire.", ["History", "Documentary"], 90),
            ("Medieval Myths Busted", nil, "Separating fact from fiction in the Middle Ages.", ["History", "Education"], 60),
            ("World War Diaries", nil, "Personal accounts from soldiers on every side of the conflict.", ["History", "Documentary"], 60),
            ("The Invention of Everything", nil, "How everyday objects changed the course of history.", ["History", "Science"], 60),
            ("Pirate Legends", nil, "The real stories behind history's most notorious buccaneers.", ["History", "Documentary"], 60),
            ("Cold War Secrets", nil, "Declassified documents reveal hidden chapters of espionage.", ["History", "Documentary"], 90),
            ("Ancient Mysteries", nil, "Unexplained artifacts and structures from our distant past.", ["History"], 60),
            ("History's Greatest Blunders", nil, "Military mistakes and political miscalculations that changed the world.", ["History", "Comedy"], 60),
        ],
        1017: [
            ("Municipal Zoning Board Meeting", "Session 47", "Live coverage of proposed amendments to residential setback requirements in District 9.", ["Public Affairs"], 180),
            ("Antique Furniture Restoration Workshop", nil, "A detailed look at re-gluing a wobbly chair leg using period-appropriate adhesives.", ["Education", "Crafts"], 90),
            ("Parliamentary Procedure Review", nil, "An in-depth analysis of Robert's Rules of Order, chapters 12 through 14.", ["Public Affairs", "Education"], 60),
            ("Watching Paint Dry: A Colour Study", nil, "Experts compare drying times of eggshell versus matte finishes in varying humidity.", ["Education", "Science"], 60),
            ("Regional Soil Survey Report", nil, "Comprehensive review of soil pH levels across the county's agricultural zones.", ["Education", "Nature"], 90),
            ("The History of Filing Cabinets", nil, "From vertical to lateral: the evolution of document storage solutions.", ["Documentary", "Education"], 60),
            ("Knitting Circle Live", "Episode 312", "Mildred demonstrates a basic purl stitch for the third consecutive week.", ["Lifestyle", "Crafts"], 60),
            ("Local Bus Route Timetable Update", nil, "Important changes to the 47B weekend schedule effective next quarter.", ["Public Affairs"], 30),
            ("Beige: An Appreciation", nil, "A thoughtful exploration of the world's most understated colour.", ["Documentary", "Arts"], 60),
        ],
    ]

    /// Generate listings for a single channel on a given date, filling 24 hours from midnight.
    static func listings(for channelId: Int, on date: Date) -> [Program] {
        guard let templates = programTemplates[channelId] else { return [] }

        let calendar = Calendar.current
        let midnight = calendar.startOfDay(for: date)
        let dayOffset = calendar.dateComponents([.day], from: calendar.startOfDay(for: Date()), to: midnight).day ?? 0

        var programs: [Program] = []
        var currentTime = midnight
        let endOfDay = calendar.date(byAdding: .day, value: 1, to: midnight)!
        var index = 0

        while currentTime < endOfDay {
            let template = templates[index % templates.count]
            let durationSeconds = template.4 * 60
            let endTime = currentTime.addingTimeInterval(TimeInterval(durationSeconds))

            // Stable deterministic ID: avoids collisions across channels and days
            let programId = channelId * 100_000 + (dayOffset + 1000) * 1000 + index

            programs.append(Program(
                id: programId,
                name: template.0,
                subtitle: template.1,
                desc: template.2,
                start: Int(currentTime.timeIntervalSince1970),
                end: Int(min(endTime, endOfDay).timeIntervalSince1970),
                genres: template.3,
                channelId: channelId
            ))

            currentTime = endTime
            index += 1
        }

        return programs
    }

    /// Generate listings for a single channel covering 3 days (-1, 0, +1).
    static func listings(for channelId: Int) -> [Program] {
        let calendar = Calendar.current
        let today = Date()
        var all: [Program] = []
        for offset in -1...1 {
            if let date = calendar.date(byAdding: .day, value: offset, to: today) {
                all.append(contentsOf: listings(for: channelId, on: date))
            }
        }
        return all
    }

    /// Generate all listings for a set of channels (3-day window).
    static func allListings(for channels: [Channel]) -> [Int: [Program]] {
        var result = [Int: [Program]]()
        for channel in channels {
            result[channel.id] = listings(for: channel.id)
        }
        return result
    }

    // MARK: - Program Lookup

    /// Find a program by event ID across all channels and days.
    private static func findProgram(eventId: Int) -> (program: Program, channel: Channel)? {
        for channel in channels {
            let programs = listings(for: channel.id)
            if let program = programs.first(where: { $0.id == eventId }) {
                return (program, channel)
            }
        }
        return nil
    }

    // MARK: - Recordings

    static func recordings() -> (completed: [Recording], recording: [Recording], scheduled: [Recording]) {
        let now = Date()

        var completed: [Recording] = [
            Recording(
                id: 9001,
                name: "Extreme Ironing Championship",
                subtitle: "Season 4 Finale",
                desc: "The world's most intense ironing competition reaches its thrilling conclusion.",
                startTime: Int(now.addingTimeInterval(-7200).timeIntervalSince1970),
                duration: 5400,
                channel: "SportsCenter HD",
                channelId: 1001,
                status: "ready",
                file: "/recordings/ironing.ts",
                recurring: false,
                epgEventId: nil,
                size: 3_200_000_000,
                quality: "HD",
                genres: ["Sports"],
                playbackPosition: 1800
            ),
            Recording(
                id: 9002,
                name: "Evening News with Anderson Scooper",
                subtitle: nil,
                desc: "In-depth reporting on the stories that matter most.",
                startTime: Int(now.addingTimeInterval(-14400).timeIntervalSince1970),
                duration: 3600,
                channel: "News 24/7",
                channelId: 1002,
                status: "ready",
                file: "/recordings/news.ts",
                recurring: false,
                epgEventId: nil,
                size: 2_100_000_000,
                quality: "HD",
                genres: ["News"]
            ),
            Recording(
                id: 9003,
                name: "Documentary: How Cat Videos Conquered the Internet",
                subtitle: nil,
                desc: "The surprisingly complex story of feline internet fame.",
                startTime: Int(now.addingTimeInterval(-86400).timeIntervalSince1970),
                duration: 5400,
                channel: "Nature & Discovery",
                channelId: 1006,
                status: "ready",
                file: "/recordings/catvids.ts",
                recurring: false,
                epgEventId: nil,
                size: 4_500_000_000,
                quality: "HD",
                genres: ["Documentary", "Technology"]
            ),
        ]

        var scheduled: [Recording] = [
            Recording(
                id: 9004,
                name: "Hockey: Poutine Pucks vs Maple Laughs",
                subtitle: nil,
                desc: "Original Six rivalry night at the Beluga Centre.",
                startTime: Int(now.addingTimeInterval(3600).timeIntervalSince1970),
                duration: 10800,
                channel: "Hockey Night",
                channelId: 1003,
                status: "pending",
                recurring: false,
                epgEventId: nil,
                genres: ["Sports", "Hockey"]
            ),
            Recording(
                id: 9005,
                name: "Football: Artisanal FC vs Cheddar United",
                subtitle: nil,
                desc: "London derby at the Sourdough Stadium.",
                startTime: Int(now.addingTimeInterval(7200).timeIntervalSince1970),
                duration: 7200,
                channel: "Premier League TV",
                channelId: 1007,
                status: "pending",
                recurring: false,
                epgEventId: nil,
                genres: ["Sports", "Soccer"]
            ),
        ]

        // Filter out cancelled pre-seeded recordings
        completed = completed.filter { !cancelledRecordingIds.contains($0.id) }
        scheduled = scheduled.filter { !cancelledRecordingIds.contains($0.id) }

        // Add user-scheduled recordings from EPG data
        for eventId in userScheduledEventIds {
            if let match = findProgram(eventId: eventId) {
                let program = match.program
                let channel = match.channel
                scheduled.append(Recording(
                    id: eventId + 100_000,
                    name: program.name,
                    subtitle: program.subtitle,
                    desc: program.desc,
                    startTime: program.start,
                    duration: program.end - program.start,
                    channel: channel.name,
                    channelId: channel.id,
                    status: "pending",
                    recurring: false,
                    epgEventId: eventId,
                    genres: program.genres
                ))
            }
        }

        return (completed: completed, recording: [], scheduled: scheduled)
    }

    // MARK: - Demo Keywords

    static let keywords: [String] = ["Hockey", "Ironing", "Cat Videos"]

    // MARK: - Demo Video

    static var demoVideoURL: URL {
        guard let url = Bundle.main.url(forResource: "demo", withExtension: "mp4") else {
            fatalError("demo.mp4 missing from app bundle")
        }
        return url
    }
}
