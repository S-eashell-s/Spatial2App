/*
 //  defleXDApp.swift
 //  defleXD
 //
 //  Created by Shelly on 28/02/2025.
 */
import ARKit
import RealityKit
import RealityKitContent
import Foundation
import Combine
import Observation
import UIKit
import SwiftUICore

/// A model type that holds app state and processes updates from ARKit.
private var previousBatPosition: SIMD3<Float>? = nil

@Observable
@MainActor
class EntityModel: ObservableObject {
    // Core ARKit session and providers
    let session = ARKitSession()
    var handTracking = HandTrackingProvider()
    var sceneReconstruction = SceneReconstructionProvider()
    // Hand tracking state
    var isHandCurrentlyTracked: Bool = false
    var isTrackingHand: Bool = true
    // ghost bat and its physics/visual smoothing
    var ghostBat: ModelEntity? = nil
    var smoothedBatPosition: SIMD3<Float>? = nil
    var smoothedBatRotation: simd_quatf? = nil
    // Scene content and visual bats
    var contentEntity: Entity? //optional with safe access
    var ghostBatAnchor: AnchorEntity? //used for tracking
    var visibleBatRight: Entity? //visible bat right
    var visibleBatLeft: Entity?//vsiibke bat left
    // Collision and mesh tracking
    private var meshEntities = [UUID: ModelEntity]()
    var collisionSubscriptions = [Cancellable]() //to track collisions
    // Game state
    var hasStarted: Bool = false
    var errorMessage: String? = nil
    var onLifeLost: (() -> Void)? = nil   //tracks life lost so callsback to immersive space
    var isGameOver = false //lets them know here if game is over
    var hasWon: Bool = false //calls haswon so the subscriptions know and stop what theyre doing
    var onScoreUpdate: ((Int) -> Void)? = nil
    var score: Int = 0//tracks score
    private var processedBallIDs = Set<ObjectIdentifier>() //double collison occuring
    private var currentBall: Entity? = nil
    private var firstBallSpawned: Bool = false
    
    var dataProvidersAreSupported: Bool {
        HandTrackingProvider.isSupported && SceneReconstructionProvider.isSupported
    }
    var isReadyToRun: Bool {
        handTracking.state == .initialized && sceneReconstruction.state == .initialized
    }
    //to change from right handed to left
    var isLeftHanded: Bool = false

    //intitial scene sets up, finds bats and sets up anchor
    func setupContentEntity(from root: Entity) -> Entity {
        // Get both bats
        self.visibleBatRight = root.findEntity(named: "baseballBat") //names the baseball bats
        self.visibleBatLeft = root.findEntity(named: "baseballBat_1")
        // Start by showing the correct one based on current handedness
        updateVisibleBatHand()
        self.contentEntity = root
        return root
    }
    // Switches between right and left bat visibility
    func updateVisibleBatHand() {
        visibleBatRight?.isEnabled = !isLeftHanded //for left handed
        visibleBatLeft?.isEnabled = isLeftHanded //for right handed
    }
    // Creates a kinematic ghost bat used for collision detection
    func setupGhostBat() {
        let bat = ModelEntity(
            mesh: .generateCylinder(height: 0.76, radius: 0.0391), //had to generate a cylinder as cant egnerate capsule on mesh
            materials: [UnlitMaterial(color: .cyan)],
            collisionShape: .generateCapsule(height: 0.15, radius: 0.5), //was 0.098 and  0.391 but i updated it in order to widen the collison scope
            mass: 3.0) //weight is in kg
        bat.name = "ghostBat" // Give it a name so findEntity(named:) can work later
        
        bat.components.set(InputTargetComponent(allowedInputTypes:.all))
        bat.components.set(PhysicsBodyComponent(
            massProperties: .default,
            material: PhysicsMaterialResource.generate(friction: 1.2, restitution: 0.8),
            mode: .kinematic))
        bat.components.set(OpacityComponent(opacity: 0)) //creates invisible bat which user cant see but code can
        //.kinematic means it will affect other entities but won't be affected in return
        //friction - a property that simulates the resistance to movement between 2 physical bodies when theyre in contact - restitution is how much energy there is in a collision when it occurs
        
        bat.transform = Transform(translation: SIMD3<Float>(0, 0.75, 0)) //fixed an issue where it was appearing behind user and only clipping on if you fully picked it up. this makes it appear in front of you so it recognises your hand and clips on faster
        
        self.ghostBat = bat // Store it to use later
        contentEntity?.addChild(bat) //widen the collision radius a little bit
        /* let helper = ModelEntity(
         mesh: .generateSphere(radius: 0.15),
         materials: [UnlitMaterial(color: .cyan)],
         collisionShape: .generateSphere(radius: 0.15),
         mass: 0.0)
         helper.name = "batHelper"
         helper.components.set(PhysicsBodyComponent(mode: .kinematic))
         helper.components.set(OpacityComponent(opacity: 0.3)) // make it invisible
         helper.position = SIMD3<Float>(0, 0, 0.2) // Move up
         ghostBat?.addChild(helper)
         */
    }
    // Processes real-time hand data and attaches the bat to user's hand
    func processHandUpdates() async {
        for await update in handTracking.anchorUpdates {
            guard ghostBat != nil else {continue}
            let handAnchor = update.anchor
            
            guard handAnchor.isTracked else {
                isHandCurrentlyTracked = false
                continue
            }
            isHandCurrentlyTracked = true
            
            guard handAnchor.isTracked,
                  handAnchor.chirality == (isLeftHanded ? .left : .right), //changes based on the settings
                  let joint = handAnchor.handSkeleton?.joint(.middleFingerMetacarpal),
                  joint.isTracked,
                  
                    let ghostBat = contentEntity?.findEntity(named: "ghostBat")
            else { continue }
            let palmTransform = handAnchor.originFromAnchorTransform
            
            //aligns with the hand rotation
            let alignRotation = simd_quatf(angle: .pi / 2, axis: [1, 0, 0])
            let gripOffset: Transform
            if isLeftHanded {
                gripOffset = Transform(rotation: alignRotation, translation: SIMD3<Float>(0.07, 0, -0.20))
            } else {
                gripOffset = Transform(rotation: alignRotation, translation: SIMD3<Float>(-0.07, 0, 0.20))
            }
            
            let finalMatrix = palmTransform * gripOffset.matrix
            
            let targetPosition = finalMatrix.translation
            let targetRotation = simd_quatf(finalMatrix)
            if let prev = smoothedBatPosition {
                let distance = simd_length(targetPosition - prev)
                if distance > 1.0 {
                    print("Skipping glitch frame with large jump: \(distance)m")
                    continue // skip this frame
                }
            }
            //Ignore huge position jumps (likely tracking errors)
            // print("Bat moved to hand position: \(ghostBat.position(relativeTo: nil))") //debugger am not using anymore
            
            // Smooth position and rotation using linear and spherical interpolation
            let smoothingFactor: Float = 0.6
            let t = SIMD3<Float>(repeating: smoothingFactor)
            if let prevPos = smoothedBatPosition {
                smoothedBatPosition = simd_mix(prevPos, targetPosition, t)
            } else {
                smoothedBatPosition = targetPosition
            }
            
            if let prevRot = smoothedBatRotation {
                smoothedBatRotation = simd_slerp(prevRot, targetRotation, smoothingFactor)
            } else {
                smoothedBatRotation = targetRotation
            }
            var finalRotation = smoothedBatRotation ?? targetRotation
            
            if isLeftHanded {
                let flipX = simd_quatf(angle: .pi, axis: [0, 1, 0])
                finalRotation = flipX * finalRotation
            }
            // Apply the smoothed transform directly to the bat
            ghostBat.transform = Transform(
                scale: SIMD3<Float>(repeating: 1),
                rotation: smoothedBatRotation ?? targetRotation,
                translation: smoothedBatPosition ?? targetPosition
            )
            if let physics = ghostBat.components[PhysicsBodyComponent.self] {
                ghostBat.components.set(physics) // re-apply to force update
            }
            /* removed velocity as was causing more issues
             apply velocity (for physics hits)
             let finalTransform = palmTransform * gripOffset.matrix
             ghostBat.setTransformMatrix(finalTransform, relativeTo: nil)
             
             apply velocity (for physics hits) - i domt need this anymore
             let newPosition = finalTransform.translation
             if let previous = previousBatPosition {
             let velocity = (newPosition - previous) / 0.016 // ~60fps
             if var motion = ghostBat.components[PhysicsMotionComponent.self] {
             motion.linearVelocity = velocity
             ghostBat.components.set(motion)   }  }
             previousBatPosition = newPosition
             */
        }
    }
    // Checks for hand tracking loss periodically and detaches bat
    func monitorHandTrackingLoss() {
        Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            
            Task { @MainActor in
                guard self.isTrackingHand, !self.isGameOver else { return }
                if !self.isHandCurrentlyTracked {
                    print("❌ Hand lost — detaching bat.")
                    self.ghostBat?.transform = Transform()
                }
            }
        }
    }
    // Responds to ARKit session events and errors
    func monitorSessionEvents() async {
        for await event in session.events {
            switch event {
            case .authorizationChanged(type: _, status: let status):
                logger.info("Authorization changed to: \(status)")
                
                if status == .denied {
                    errorMessage = "Authorization denied"
                }
            case .dataProviderStateChanged(dataProviders: let providers, newState: let state, error: let error):
                logger.info("Data provider changed: \(providers), \(state)")
                if let error {
                    logger.error("Data provider reached an error state: \(error)")
                    errorMessage = "Data provider reached an error state: \(error)"
                }
            @unknown default:
                fatalError("Unhandled new event type \(event)")
            }
        }
    }
    // Handles updates to the mesh environment in the scene
    func processReconstructionUpdates() async {
        for await update in sceneReconstruction.anchorUpdates {
            let meshAnchor = update.anchor
            
            guard let shape = try? await ShapeResource.generateStaticMesh(from: meshAnchor) else { continue }
            switch update.event {
            case .added:
                let entity = ModelEntity()
                entity.transform = Transform(matrix: meshAnchor.originFromAnchorTransform)
                entity.collision = CollisionComponent(shapes: [shape], isStatic: true)
                entity.components.set(InputTargetComponent())
                
                entity.physicsBody = PhysicsBodyComponent(mode: .static)
                
                meshEntities[meshAnchor.id] = entity
                contentEntity?.addChild(entity)
                print("Added mesh anchor: \(meshAnchor.id)")
            case .updated:
                guard let entity = meshEntities[meshAnchor.id] else { continue }
                entity.transform = Transform(matrix: meshAnchor.originFromAnchorTransform)
                entity.collision?.shapes = [shape]
            case .removed:
                meshEntities[meshAnchor.id]?.removeFromParent()
                meshEntities.removeValue(forKey: meshAnchor.id)
            }
        }
    }
    // Shows a broken heart model when the player loses a life
    func showMinusHeart(at position: SIMD3<Float>) {
        // 1. Load the 'heartBroke' 3D model from the main app bundle
        guard let heartEntity = try? Entity.load(named: "heartBroke") else {
            print("Failed to load heartBroke model")
            return
        }
        //2.make it always face the user
        heartEntity.components.set(BillboardComponent())
        
        // 3. Place it slightly above the impact point
        heartEntity.setPosition(position + SIMD3(0, 0.3, 0), relativeTo: nil)
        // 4. Add to the scene
        contentEntity?.addChild(heartEntity)
        // 5. Animate upward
        heartEntity.move(
            to: Transform(translation: heartEntity.position + SIMD3(0, 0.1, 0)),
            relativeTo: nil,
            duration: 1.0
        )
        // 6. Remove after animation completes
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            heartEntity.removeFromParent()
        }
    }
    // I made this from the original sceneRecontructionExample code from apple - it was originally a cube
    // Spawns a ball around the user and sets physics, collision, and auto-despawn logic
    func addCube(tapLocation: SIMD3<Float>, overrideLimit: Bool = false){
        if currentBall != nil && isGameOver && !overrideLimit || hasWon { return } //only add ball when randomly spawning but button will ovveride it
        let entity = ModelEntity(
            mesh: .generateSphere(radius: 0.07),
            materials: [SimpleMaterial(color: .systemYellow, isMetallic: false)],
            collisionShape: .generateSphere(radius: 0.07),
            mass: 1.0
        )
        entity.name = "ball"
        //changed the shape from cube to make it a ball - changed collision as well
        entity.setPosition(tapLocation, relativeTo: nil)
        entity.components.set(InputTargetComponent(allowedInputTypes: .indirect))
        
        let material = PhysicsMaterialResource.generate(friction: 0.8, restitution: 0.0)
        entity.components.set(
            PhysicsBodyComponent(
                shapes: entity.collision!.shapes,
                mass: 1.0,
                material: material,
                mode: .dynamic))
        entity.components.set(
            InputTargetComponent(allowedInputTypes: .all))//will allow it to be affected
        contentEntity?.addChild(entity)
        currentBall = entity
        firstBallSpawned = true
        
        // Automatically remove ball after 2 seconds, even without collision
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self, weak entity] in
            guard let self, let entity = entity else { return }
            
            guard !isGameOver else {
                print("Skipping spawn: game is over.")
                return
            }
            
            if entity.parent != nil {
                print(" Ball timeout — removing entity and spawning next")
                entity.removeFromParent()
                self.currentBall = nil
                
                
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                    guard let self, !self.isGameOver else { return }
                    self.spawnRandomBall()
                }
            }
        }
        DispatchQueue.main.async {
            if let batPosition = self.ghostBat?.position(relativeTo: nil) {
                let direction = normalize(batPosition - entity.position(relativeTo: nil))
                let speed: Float = Float.random(in: 0.5...1.2) //made the balls drop down slower to make it easier to hit
                let velocity = direction * speed
                entity.components.set(PhysicsMotionComponent(linearVelocity: velocity))
                print("Applied delayed velocity")
            }
        }
        // Delay collision subscription slightly
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self, weak entity] in
            guard let self, let entity = entity, let scene = entity.scene else {
                print("Entity still not in scene after delay")
                return
            }
            
            let subscription = scene.subscribe(to: CollisionEvents.Began.self, on: entity) { [weak self] event in
                guard let self else { return }
                let ballID = ObjectIdentifier(entity)
                /* // Prevent double processing
                 if self.processedBallIDs.contains(ballID) {
                 print("Collision already handled for this ball.")
                 return
                 }
                 */
                guard let bat = self.ghostBat else { return }
                // Check if the bat is directly involved in the collision
                if event.entityA == bat || event.entityB == bat {
                    //self.processedBallIDs.insert(ballID)
                    self.score += 1
                    self.onScoreUpdate?(self.score)
                    self.playTwoImpactSound(on: bat)
                    
                    // Despawn ball with animation
                    entity.move(to: Transform(scale: [1.5, 1.5, 1.5]), relativeTo: entity.parent, duration: 0.1)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                        // Shrink away
                        entity.move(to: Transform(scale: .zero), relativeTo: entity.parent, duration: 0.2)
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                            entity.removeFromParent()
                            self.currentBall = nil
                            self.processedBallIDs.remove(ballID)
                            // Spawn next after delay
                            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
                                self?.spawnRandomBall()
                            }
                        }
                    }
                }
                // if collison is with mesh
                else if self.meshEntities.values.contains(where: { $0 == event.entityA || $0 == event.entityB }) {
                    if self.processedBallIDs.contains(ballID) {
                        print("Collision already handled for this ball.")
                        return
                    }
                    self.processedBallIDs.insert(ballID)
                    print("Ball collided with mesh")
                    self.playImpactSound(on: entity) //ensures the impact sound is tied to the balls
                    if !self.isGameOver && !self.hasWon {//triggers the loss of a life
                        self.onLifeLost?()
                    }
                    self.showMinusHeart(at: entity.position(relativeTo: nil))
                    //add a thing to remove the ball once it collides with the mesh
                    // Destruct + respawn after delay
                    entity.move(to: Transform(scale: [1.5, 1.5, 1.5]), relativeTo: entity.parent, duration: 0.1)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                        entity.move(to: Transform(scale: .zero), relativeTo: entity.parent, duration: 0.2)
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                            entity.removeFromParent()
                            self.currentBall = nil
                            self.processedBallIDs.remove(ballID)
                            
                            // Wait 2 seconds before spawning another
                            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
                                self?.spawnRandomBall()
                            }
                        }
                    }
                }
            }
            self.collisionSubscriptions.append(subscription)
            
            let endSubscription = scene.subscribe(to: CollisionEvents.Ended.self, on: entity) { [weak self] event in
                guard self != nil else { return }
                print("Collision ended — rearming ball \(entity.name)")
            }
            self.collisionSubscriptions.append(endSubscription)
        }
    }
    // Randomizes a ball's spawn location and calls addCube() - i made this to spawn a ball without the need for a button
    func spawnRandomBall() {
        guard !isGameOver, !hasWon else {
            print("Skipping spawn: game is over.")
            return
        }
        guard currentBall == nil else {
            print("A ball is already active. Waiting.")
            return
        }
        let randomX = Float.random(in: -0.4 ... 0.4)
        let randomY = Float.random(in: 2.0 ... 2.8)
        let randomZ = Float.random(in: -1.2 ... -0.8)
        let position = SIMD3<Float>(randomX, randomY, randomZ)
        
        print("Spawning ball at \(position)")
        addCube(tapLocation: position)
    }
    //Full game reset and countdown logic before spawning first ball
    //Resets score, removes all entities and bat, restarts ARKit session, then counts down 3...2...1 and spawns the first ball.

    func forceAddBall() {
        //Reset game state
        isGameOver = false   //re-enable game logic
        score = 0
        onScoreUpdate?(score)
        //Remove all existing balls
        let balls = contentEntity?.children.filter { $0.name == "ball" } ?? []
        for ball in balls {
            ball.removeFromParent()
        }
        currentBall = nil
        
        //Remove all mesh
        print("Clearing old mesh entities...")
        for (_, entity) in meshEntities {
            entity.removeFromParent()
        }
        meshEntities.removeAll()
        //Remove and reset ghost bat
        ghostBat?.removeFromParent()
        ghostBat = nil
        smoothedBatPosition = nil
        smoothedBatRotation = nil
        // Restart ARKitSession to force mesh reconstruction
        Task {
            print("Restarting ARKitSession with new providers…")
            session.stop()
            try? await Task.sleep(nanoseconds: 300_000_000) // 0.3s pause
            // Create new providers
            self.sceneReconstruction = SceneReconstructionProvider()
            self.handTracking = HandTrackingProvider()
            
            do {
                try await session.run([sceneReconstruction, handTracking])
                print("Session restarted with new providers.")
            } catch {
                print("Failed to restart session: \(error)")
            }
            Task.detached { [weak self] in
                await self?.processReconstructionUpdates()
            }
            //Restart hand tracking updates
            Task.detached { [weak self] in
                await self?.processHandUpdates()
            }
            // Re-setup ghost bat
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                guard let self else { return }
                print("Recreating ghost bat...")
                self.setupGhostBat()
            }
            // Countdown before spawning the ball
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                guard let self else { return }
                var countdown = 3
                Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { timer in
                    Task { @MainActor in
                        if countdown > 0 {
                            self.show3DCountdownText("Ball dropping in \(countdown)...")
                        }
                        countdown -= 1
                        if countdown < 0 {
                            timer.invalidate()
                            // Remove countdown text
                            if let anchor = self.contentEntity?.children.first(where: { $0.name == "CountdownAnchor" }) {
                                anchor.removeFromParent()
                            }
                            // Spawn the ball
                            let randomX = Float.random(in: -0.4 ... 0.4)
                            let randomY = Float.random(in: 2.0 ... 2.8)
                            let randomZ = Float.random(in: -1.2 ... -0.8)
                            let position = SIMD3<Float>(randomX, randomY, randomZ)
                            print("Force-spawning ball at \(position)")
                            self.addCube(tapLocation: position, overrideLimit: true)
                        }
                    }
                }
            }
        }
    }
    // Displays a 3D countdown text in the immersive space
    func show3DCountdownText(_ text: String) { //to show a 3d countdown to prepare the user for the balls to drop
        // Removes any existing countdown anchor
        if let oldAnchor = contentEntity?.children.first(where: { $0.name == "CountdownAnchor" }) {
            oldAnchor.removeFromParent()
        }
        let textMesh = MeshResource.generateText(
            text,
            extrusionDepth: 0.01,
            font: .systemFont(ofSize: 0.1),
            containerFrame: .zero,
            alignment: .center,
            lineBreakMode: .byWordWrapping
        )
        let material = SimpleMaterial(color: .cyan, isMetallic: false)
        let textEntity = ModelEntity(mesh: textMesh, materials: [material])
        textEntity.name = "CountdownText"
        
        let anchor = AnchorEntity(.head)
        anchor.name = "CountdownAnchor"
        textEntity.position = SIMD3<Float>(-0.5, 0, -1.2) // in front of head - same as the other 3d texts
        anchor.addChild(textEntity)
        contentEntity?.addChild(anchor)
    }
    // Displays a 3D "Game Over" text in space
    func show3DGameOverText() {
        let textMesh = MeshResource.generateText(
            "Game Over",
            extrusionDepth: 0.02,
            font: .systemFont(ofSize: 0.2),
            containerFrame: .zero,
            alignment: .center,
            lineBreakMode: .byWordWrapping
        )
        let material = SimpleMaterial(color: .red, isMetallic: true)
        let textEntity = ModelEntity(mesh: textMesh, materials: [material])
        textEntity.name = "GameOverText"
        
        let anchor = AnchorEntity(.head)  //places it in front of the user’s head
        anchor.name = "GameOverAnchor"
        textEntity.position = SIMD3<Float>(-0.5, 0, -1.2)  // 1.2 meters in front and center
        anchor.addChild(textEntity)
        contentEntity?.addChild(anchor)
    }
    func remove3DGameOverText() {
        // Remove the entire anchor holding the text
        if let anchor = contentEntity?.children.first(where: { $0.name == "GameOverAnchor" }) {
            anchor.removeFromParent()
            print("Removed 3D Game Over anchor")
        } else {
            print("Could not find GameOverAnchor")
        }
    }
    // Displays a 3D "Game Won!" text
    func show3DGameWonText() {
        let textMesh = MeshResource.generateText(
            "Game Won!",
            extrusionDepth: 0.02,
            font: .systemFont(ofSize: 0.2),
            containerFrame: .zero,
            alignment: .center,
            lineBreakMode: .byWordWrapping
        )
        let material = SimpleMaterial(color: .green, isMetallic: true)
        let textEntity = ModelEntity(mesh: textMesh, materials: [material])
        textEntity.name = "GameWonText"
        let anchor = AnchorEntity(.head)
        anchor.name = "GameWonAnchor"
        textEntity.position = SIMD3<Float>(-0.5, 0, -1.2)
        anchor.addChild(textEntity)
        contentEntity?.addChild(anchor)
    }
    //removes the game won text anchor
    func remove3DGameWonText() {
        if let anchor = contentEntity?.children.first(where: { $0.name == "GameWonAnchor" }) {
            anchor.removeFromParent()
            print("Removed 3D Game Won anchor")
        } else {
            print("Could not find GameWonAnchor")
        }
    }
    // Plays impact sound when the ball hits the floor or mesh
    func playImpactSound(on ball: Entity) {
        //Bundle.main since this is from the app bundle
        let bundle = Bundle.main
        do {
            let resource = try AudioFileResource.load(named: "floorImpactSound.wav", in: bundle)
            let controller = ball.playAudio(resource)
            controller.gain = -10
            
            print(" Playing impact sound on: \(ball.name)")
        } catch {
            print(" Could not load impact sound: \(error.localizedDescription)")
        }
    }
    // Plays impact sound when bat hits the ball
    func playTwoImpactSound(on bat: Entity) {
        let bundle = Bundle.main
        
        do {
            let resource = try AudioFileResource.load(named: "batHitBall.wav", in: bundle)
            let controller = bat.playAudio(resource)
            controller.gain = -10
            
            print(" Played impact sound bat")
        } catch {
            print("Could not load sound: \(error.localizedDescription)")
        }
    }
    // Cancels all active collision subscriptions
    func cancelAllCollisionSubscriptions() {
        for subscription in collisionSubscriptions {
            subscription.cancel()
        }
        collisionSubscriptions.removeAll()
    }
}
