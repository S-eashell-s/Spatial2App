//
//  ImmersiveGameView.swift
//  DefleXD_VR
//
//  Created by Shelly on 07/03/2025.
import SwiftUI
import RealityKit
import RealityKitContent
import ARKit
import CoreAudio

//some help from joel, step into vision, chat gpt, and claude

struct ImmersiveGameView: View {
    // Controls immersive space lifecycle
    @Environment(\.dismissImmersiveSpace) private var dismissImmersiveSpace
    // State and model handling
    @StateObject var entityModel = EntityModel() //calls entityModel
    @State var session = SpatialTrackingSession()// Vision Pro hand tracking session
    @State var gameStarted = false
    @State private var hasFiredFireworks = false //Throttle fireworks to prevent multiple bursts
    @State var gameOver = false //track gaem over state
    @State var hasWon = false //track game won state
    // Bound to external game UI - originally staet but I changed it to binding as it needed binding
    @Binding var score: Int
    // Remaining lives
    @State var lives: Int = 5
    //Emitter for fireworks and game menu and sounds
    @State var chamber = Entity()
    // Access balls and ghost bat
    @Environment(EntityModel.self) var model
    // Stash the collision event
    @State var collisionBeganSubject: EventSubscription?
    @State var arScene: RealityKit.Scene? // Holds the RealityKit scene for spawning balls
    
    var body: some View {
        ZStack {
            VStack {
                RealityView { content, attachments in
                    if let immersiveContentEntity = try? await Entity(named: "PhysicsPlayground", in: realityKitContentBundle) {
                        //set reality composer scene as a root
                        // Create a world-based anchor slightly in front of the user
                        let anchor = AnchorEntity(world: [0, 0, 0])
                        let rootEntity = model.setupContentEntity(from: immersiveContentEntity)
                        anchor.addChild(rootEntity)
                        content.add(anchor)
                        model.setupGhostBat()
                        Task {
                            await model.processHandUpdates()
                        }
                        model.monitorHandTrackingLoss()
                        
                        model.onScoreUpdate = { newScore in
                            score = newScore
                            _ = gameWon() //Triggers the win logic once score is reached
                        }
                        // model.spawnRandomBall()  -removed as i added the extra start game to give the AR view time to build up
                        // Locate and prepare fireworks emitter
                        guard let chamber = immersiveContentEntity.findEntity(named: "Chamber")  else { return }
                        chamber.setPosition([0, 1.4, -2], relativeTo: nil)
                        chamber.setScale([0.5, 0.5, 0.5], relativeTo: nil)
                        self.chamber = chamber

                        func runTrackingSession() async {
                            let configuration = SpatialTrackingSession.Configuration(tracking: [.hand])
                            await session.run(configuration)
                        }
                        // Set up the game menu UI in space
                        if let gameMenu = attachments.entity(for: "GameMenu") {
                            gameMenu.setPosition([0, -0.6, 1.5], relativeTo: chamber)
                            gameMenu.scale = [2,2,2]
                            content.add(gameMenu)
                        }
                    }
                    // Handle updates if needed
                } update: { content, attachments in //menu for restart or pause game
                // Menu UI with conditional states
                } attachments: {
                    Attachment(id: "GameMenu") {
                        if gameOver { // Show game over options
                            VStack(spacing: 20) {
                                Text("Press restart to try again")
                                    .font(.title2)
                                    .foregroundColor(.white)
                                Button(action: {
                                    resetGameState()
                                    gameStarted = true
                                    model.hasStarted = true
                                    model.forceAddBall()
                                    model.setupGhostBat()
                                }, label: {
                                    Text("Restart")
                                })
                                .buttonStyle(.borderedProminent)
                                .font(.title3)
                                .padding()
                                .clipShape(Capsule())
                            }
                            .padding()
                            .transition(.opacity)
                            // Fade in
                            .animation(.easeInOut(duration: 1), value : gameOver)
                            //Animate on toggle
                        } else if hasWon == true { // Show win screen
                            Text("you won! Press restart to play again!")
                                .font(.title2)
                                .foregroundColor(.white)
                            VStack(spacing: 20) {
                                HStack {
                                    Button(action: { //start game again
                                        resetGameState()
                                        gameStarted = true
                                        model.hasStarted = true
                                        model.forceAddBall()
                                        model.setupGhostBat()
                                        configureLifeLossHandler()
                                    }, label: {
                                        Text("Replay")
                                    })
                                    .buttonStyle(.borderedProminent)
                                }
                            }
                        // Show normal game menu
                        }else {
                            VStack {
                                if !gameStarted {
                                    HStack(spacing: 8) {
                                        // Setup toggle for left-handed mode
                                        Text("Left-Handed mode")
                                            .bold()
                                            .font(.caption)
                                        Toggle("", isOn: Binding(
                                            get: { model.isLeftHanded },
                                            set: { newValue in
                                                model.isLeftHanded = newValue
                                                model.smoothedBatPosition = nil //reset position smoothing
                                                model.updateVisibleBatHand() //Switch visible bat
                                            }
                                        ))
                                        .labelsHidden()
                                        .toggleStyle(SwitchToggleStyle(tint: .blue))
                                        .padding()
                                        .transition(.opacity)
                                        .animation(.easeInOut, value: gameStarted)
                                    }
                                    //start game button disappears
                                    Button(action: {
                                        resetGameState()
                                        gameStarted = true
                                        model.hasStarted = true
                                        model.forceAddBall()
                                        model.setupGhostBat()
                                        configureLifeLossHandler() // Safety: rebind just in case because it wasnt always working
                                    }) {
                                        Text("Start Game")
                                    }
                                    .buttonStyle(.borderedProminent)
                                    // Instructions
                                    Text("How to play: ")
                                        .font(.title2)
                                        .fontWeight(.bold)
                                        .foregroundColor(.white)
                                    Text("Hit the ball with your bat \nto try and score points!\nYou will have 5 lives")
                                        .font(.body)
                                        .foregroundColor(.white)
                                        .multilineTextAlignment(.center)
                                        .transition(.opacity)
                                        .animation(.easeInOut, value: gameStarted)
                                }
                                // In game display
                                if gameStarted {
                                    HStack {
                                        Button(action: { //restart game
                                            resetGameState()
                                            gameStarted = true
                                            model.hasStarted = true     // Also keep this in sync
                                            model.forceAddBall()
                                            model.setupGhostBat()

                                        }, label: {
                                            Text("Restart Game") //merged add ball with this as it essentially does the same thing - removes all entities and adds a new ball
                                        })
                                        .buttonStyle(.borderedProminent)
                                        Button(action: {
                                            resetGameState()
                                            model.isTrackingHand = false
                                            model.ghostBat?.removeFromParent()
                                            Task {
                                                await dismissImmersiveSpace() //cleanly exits immersive space
                                            }
                                        }, label: {
                                            Text("Exit game")
                                        })
                                        .buttonStyle(.borderedProminent)
                                    }
                                    Text("Your score is \(score). Hit once to win!")
                                    Text("Remaining lives: \(lives)")
                                }
                            }
                            .padding(10)
                            .background(
                                RoundedRectangle(cornerRadius: 50)
                                    .fill(LinearGradient(
                                        gradient: Gradient(colors: [.purple, .indigo, .cyan]),
                                        startPoint: .bottomLeading,
                                        endPoint: .topTrailing)))
                            .overlay(RoundedRectangle(cornerRadius: 50).stroke(Color.white,lineWidth: 3))
                            .animation(.easeInOut, value: gameStarted)
                        }
                    }
                }
                // Begin async session setup and tracking
                .task {
                    do {
                        if model.dataProvidersAreSupported {
                            if model.isReadyToRun {
                                try await model.session.run([model.sceneReconstruction, model.handTracking])
                                configureLifeLossHandler()
                            }
                        } else {
                            model.errorMessage = "Data providers not supported."
                        }
                    } catch {
                        model.errorMessage = "Failed to start session: \(error)"
                        logger.error("Failed to start session: \(error)")
                    }
                }
                .task {
                    await model.processHandUpdates()
                }
                .task {
                    await model.monitorSessionEvents()
                }
                .task(priority: .low) {
                    await model.processReconstructionUpdates()
                }
                .persistentSystemOverlays(.hidden)
                .upperLimbVisibility(.hidden)
            }
        }
    }
    // Binds life loss logic to the model
    func configureLifeLossHandler() {//added a helper for readability isntead of repeating 4 times
        model.onLifeLost = {//Re-bind onLifeLost so lives update again
            guard !gameOver, !hasWon else {
                print("Ignoring life loss — game already ended")
                return
            }
            if lives > 0 {
                lives -= 1
            }
            if lives <= 0 && !gameOver {
                gameOver = true
                model.isGameOver = true
                model.cancelAllCollisionSubscriptions()
                playGameOverSound()
                model.show3DGameOverText()
            }
        }
    }
    // Resets the game to the initial state
    func resetGameState() {//added another helper for buttons
        gameStarted = false
        gameOver = false
        hasWon = false //reset local win state
        model.hasStarted = false
        model.isGameOver = false
        model.hasWon = false//reset entitymodel win state
        score = 0  // update local score @Binding
        lives = 5//rest lives back to 5
        model.cancelAllCollisionSubscriptions()//stop all listeners
        model.remove3DGameOverText()//remove the 3d text - just in case
        model.remove3DGameWonText()
        model.ghostBat?.removeFromParent()
        configureLifeLossHandler()
        hasFiredFireworks = false//
    }
    // Plays the sad sound when the game is lost
    func playGameOverSound() {
        //bundle main
        let bundle = Bundle.main
        do {
            let resource = try AudioFileResource.load(named: "sadTrombone.wav", in: bundle)
            let controller = chamber.playAudio(resource)
            controller.gain = -10
            print(" Playing game over sound")
        } catch {
            print(" Could not load sound: \(error.localizedDescription)")
        }
    }
    // Plays win audio when game is won
    func playGameWonSound() {
        let bundle = Bundle.main
        do {
            let resource = try AudioFileResource.load(named: "gameWon.wav", in: bundle) //add game won sound
            let controller = chamber.playAudio(resource)
            controller.gain = -10
            print(" Playing game over sound")
        } catch {
            print(" Could not load sound: \(error.localizedDescription)")
        }
    }
    // Handles all win logic: fireworks, UI text, sound
    func gameWon() -> Bool {
        //check win condition
        guard score >= 1 else { return false }
        // Only trigger effects once
        guard chamber.parent != nil else {
            print(" Chamber not yet available.")
            return false
        }
        guard !hasWon else { return true }
        hasWon = true
        model.hasWon = true // Tell the model to stop spawning
        model.cancelAllCollisionSubscriptions() //no more
        
        //Delay & throttle fireworks to prevent overload
        if !hasFiredFireworks {
            hasFiredFireworks = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                if var fireworks = chamber.components[ParticleEmitterComponent.self] {
                    fireworks.burst()
                    chamber.components.set(fireworks)
                } else {
                    print(" No fireworks emitter on chamber.")
                }
            }
        }
        // Delay text & audio slightly to space out system load
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            model.show3DGameWonText()
            playGameWonSound()
        }
        print("Game won triggered at score: \(score)")
        return true
    }
}
//with score binding
#Preview(immersionStyle: .mixed) {
    @Previewable @State var previewScore = 0
    return ImmersiveGameView(score: $previewScore)
        .environment(AppModel())
}
