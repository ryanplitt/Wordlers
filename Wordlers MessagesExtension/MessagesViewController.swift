import CryptoKit
import SwiftUI
import Messages
import FirebaseFirestore
import FirebaseCore


extension String {
    func sha256() -> String {
        let data = Data(self.utf8)
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}

class MessagesViewController: MSMessagesAppViewController {
    override func willBecomeActive(with conversation: MSConversation) {
        super.willBecomeActive(with: conversation)
        
        if FirebaseApp.app() == nil {
            FirebaseApp.configure()
        }
        
        presentScoreboard(in: self, conversation: conversation)
    }
    
    private func presentScoreboard(in controller: MSMessagesAppViewController, conversation: MSConversation) {
        let rootView = ScoreboardView(conversation: conversation)
        let hostingController = UIHostingController(rootView: rootView)
        
        addChild(hostingController)
        hostingController.view.frame = view.bounds
        view.addSubview(hostingController.view)
        hostingController.didMove(toParent: self)
    }
}

struct PlayerScore: Identifiable, Codable {
    var id: String // unique identifier per user
    var name: String
    var score: String // "1" through "6", or "X"
}

struct WordleGame: Codable {
    var startingWord: String
    var playerScores: [PlayerScore]
    
    static func sample() -> WordleGame {
        WordleGame(
            startingWord: "CRANE",
            playerScores: [
                PlayerScore(id: UUID().uuidString, name: "Ryan", score: "3"),
                PlayerScore(id: UUID().uuidString, name: "Mandy", score: "4"),
                PlayerScore(id: UUID().uuidString, name: "Link", score: "X")
            ]
        )
    }
}

class FirebaseService {
    private let db = Firestore.firestore()
    
    func fetchGame(threadID: String, date: String, completion: @escaping (WordleGame?, Error?) -> Void) {
        db.collection("threads").document(threadID)
            .collection("games").document(date)
            .getDocument { snapshot, error in
                guard let data = snapshot?.data(), error == nil else {
                    completion(nil, error)
                    return
                }
                if let word = data["startingWord"] as? String,
                   let scores = data["playerScores"] as? [[String: String]] {
                    let playerScores: [PlayerScore] = scores.compactMap {
                        guard let id = $0["id"], let name = $0["name"], let score = $0["score"] else { return nil }
                        return PlayerScore(id: id, name: name, score: score)
                    }
                    completion(WordleGame(startingWord: word, playerScores: playerScores), nil)
                } else {
                    completion(nil, nil)
                }
            }
    }
    
    func updateScores(threadID: String, date: String, scores: [PlayerScore], completion: @escaping (Error?) -> Void) {
        let scoreDicts = scores.map { ["id": $0.id, "name": $0.name, "score": $0.score] }
        db.collection("threads").document(threadID)
            .collection("games").document(date)
            .updateData(["playerScores": scoreDicts], completion: completion)
    }
    
    func startGame(threadID: String, date: String, startingWord: String, completion: @escaping (Error?) -> Void) {
        let data: [String: Any] = [
            "startingWord": startingWord,
            "playerScores": []
        ]
        db.collection("threads").document(threadID)
            .collection("games").document(date)
            .setData(data, completion: completion)
    }
}

struct ScoreboardView: View {
    @Environment(\.presentationMode) var presentationMode
    var conversation: MSConversation
    var localUserID: String { conversation.localParticipantIdentifier.uuidString }
    @AppStorage("displayName") private var storedDisplayName: String = ""
    @State private var currentPlayerName: String = ""
    @State private var selectedScore = "1"
    @State private var gameStarted = false
    @State private var startingWordInput = ""
    @State private var selectedDate = Date()
    @State private var game = WordleGame.sample()
    @State private var errorMessage: String? = nil
    @State private var listener: ListenerRegistration? = nil
    
    let firebaseService = FirebaseService()
    let possibleScores = ["1", "2", "3", "4", "5", "6", "X"]
    
    var threadID: String {
        let allIDs = ([conversation.localParticipantIdentifier] + conversation.remoteParticipantIdentifiers)
            .map { $0.uuidString }
            .sorted()
            .joined(separator: "-")
        return allIDs.sha256()
    }
    
    var formattedDate: String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        return formatter.string(from: selectedDate)
    }
    
    var body: some View {
        VStack(spacing: 16) {
            HStack {
                Button(action: {
                    selectedDate = Calendar.current.date(byAdding: .day, value: -1, to: selectedDate) ?? selectedDate
                    listenForGameUpdates()
                }) {
                    Image(systemName: "chevron.left")
                }
                .accessibilityLabel("Previous Day")
                Text(formattedDate)
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                Button(action: {
                    selectedDate = Calendar.current.date(byAdding: .day, value: 1, to: selectedDate) ?? selectedDate
                    listenForGameUpdates()
                }) {
                    Image(systemName: "chevron.right")
                }
                .accessibilityLabel("Next Day")
            }
            .padding(.bottom)
            
            if let errorMessage = errorMessage {
                Text(errorMessage)
                    .foregroundColor(.red)
                    .padding()
            }
            
            if gameStarted {
                Text("Game for \(formattedDate)")
                    .font(.title)
                Text("Starting Word: \(game.startingWord)")
                    .font(.subheadline)
                    .foregroundColor(.gray)
                
                ScoreListView(playerScores: game.playerScores)
                
                Divider()
                
                Button("Change My Name") {
                    currentPlayerName = storedDisplayName
                }
                .font(.caption)
                .padding(.bottom, 4)
                
                ScoreInputView(
                    currentPlayerName: $currentPlayerName,
                    selectedScore: $selectedScore,
                    possibleScores: possibleScores,
                    onSubmit: submitScore
                )
                .padding()
            } else {
                Text("Start a New Wordle Game")
                    .font(.title2)
                TextField("Your Name", text: $storedDisplayName)
                    .textFieldStyle(RoundedBorderTextFieldStyle())
                    .frame(width: 220)
                TextField("Enter 5-letter starting word", text: $startingWordInput)
                    .textFieldStyle(RoundedBorderTextFieldStyle())
                    .frame(width: 220)
                Button("Start Game") {
                    startGame()
                }
                .disabled(startingWordInput.count != 5 || storedDisplayName.isEmpty)
                .padding(.top)
            }
        }
        .padding()
        .onAppear {
            listenForGameUpdates()
            if !storedDisplayName.isEmpty {
                currentPlayerName = storedDisplayName
            }
        }
        .onDisappear {
            listener?.remove()
        }
    }
    
    func listenForGameUpdates() {
        firebaseService.fetchGame(threadID: threadID, date: formattedDate) { fetchedGame, error in
            if let error = error {
                errorMessage = "Failed to fetch game: \(error.localizedDescription)"
                return
            }
            if let fetchedGame = fetchedGame {
                game = fetchedGame
                gameStarted = true
            } else {
                gameStarted = false
                game = WordleGame(startingWord: "", playerScores: [])
            }
        }
    }
    
    func submitScore() {
        guard !currentPlayerName.isEmpty else { return }
        
        if let index = game.playerScores.firstIndex(where: { $0.id == localUserID }) {
            game.playerScores[index].score = selectedScore
            game.playerScores[index].name = storedDisplayName
        } else {
            let newScore = PlayerScore(id: localUserID, name: storedDisplayName, score: selectedScore)
            game.playerScores.append(newScore)
        }
        
        firebaseService.updateScores(threadID: threadID, date: formattedDate, scores: game.playerScores) { error in
            if let error = error {
                errorMessage = "Failed to update scores: \(error.localizedDescription)"
            } else {
                errorMessage = nil
            }
        }
        
        currentPlayerName = ""
        selectedScore = "1"
    }
    
    func startGame() {
        game.startingWord = startingWordInput.uppercased()
        game.playerScores = []
        gameStarted = true
        
        firebaseService.startGame(threadID: threadID, date: formattedDate, startingWord: game.startingWord) { error in
            if let error = error {
                errorMessage = "Failed to start game: \(error.localizedDescription)"
            } else {
                errorMessage = nil
            }
        }
        
        sendMessageToThread(startingWord: game.startingWord, starter: storedDisplayName)
    }
    
    func sendMessageToThread(startingWord: String, starter: String) {
        let layout = MSMessageTemplateLayout()
        layout.caption = "Wordlers Game – \(formattedDate)"
        layout.subcaption = "Starting Word: \(startingWord) (by \(starter))"
        
        let message = MSMessage()
        message.layout = layout
        
        conversation.insert(message, completionHandler: nil)
    }
}

struct ScoreListView: View {
    var playerScores: [PlayerScore]
    
    var body: some View {
        List(playerScores) { player in
            HStack {
                Text(player.name)
                Spacer()
                Text(player.score)
                    .bold()
            }
        }
    }
}

struct ScoreInputView: View {
    @Binding var currentPlayerName: String
    @Binding var selectedScore: String
    var possibleScores: [String]
    var onSubmit: () -> Void
    
    var body: some View {
        VStack {
            TextField("Your Name", text: $currentPlayerName)
                .textFieldStyle(RoundedBorderTextFieldStyle())
            Picker("Your Score", selection: $selectedScore) {
                ForEach(possibleScores, id: \.self) { score in
                    Text(score)
                }
            }
            .pickerStyle(SegmentedPickerStyle())
            Button("Submit Score") {
                onSubmit()
            }
            .padding(.top)
        }
    }
}

struct ScoreSummary: View {
    var allGames: [[String: Any]]
    var localUserID: String
    
    struct PlayerStats {
        var name: String
        var totalGames = 0
        var distribution: [String: Int] = ["1": 0, "2": 0, "3": 0, "4": 0, "5": 0, "6": 0, "X": 0]
    }
    
    var playerStats: [String: PlayerStats] {
        var stats: [String: PlayerStats] = [:]
        
        for game in allGames {
            guard let players = game["playerScores"] as? [[String: String]] else { continue }
            for player in players {
                guard let id = player["id"], let name = player["name"], let score = player["score"] else { continue }
                var entry = stats[id] ?? PlayerStats(name: name)
                entry.name = name
                entry.totalGames += 1
                entry.distribution[score, default: 0] += 1
                stats[id] = entry
            }
        }
        
        return stats
    }
    
    var body: some View {
        VStack(alignment: .leading) {
            Text("Stats Summary")
                .font(.headline)
            
            ForEach(Array(playerStats.keys), id: \.self) { id in
                let stat = playerStats[id]!
                VStack(alignment: .leading) {
                    Text(stat.name)
                        .font(.subheadline)
                        .bold()
                    HStack {
                        ForEach(["1", "2", "3", "4", "5", "6", "X"], id: \.self) { score in
                            VStack {
                                Text(score)
                                    .font(.caption)
                                Text("\(stat.distribution[score] ?? 0)")
                                    .bold()
                            }
                            .frame(minWidth: 30)
                        }
                    }
                    Text("Games Played: \(stat.totalGames)")
                        .font(.caption)
                        .padding(.top, 4)
                }
                .padding(.vertical, 6)
            }
        }
        .padding()
    }
}
