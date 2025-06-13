//
//  defleXDApp.swift
//  defleXD
//
//  Created by Shelly on 28/02/2025.
//
import SwiftUI
import OSLog
import RealityKit
//main app structure

@main
struct defleXDApp: App {
    
    @State private var appModel = AppModel()
    @State private var model = EntityModel()
    @State private var score = 0 // Add this for Binding


    var body: some SwiftUI.Scene {
        WindowGroup {
            ContentView()
                .environment(appModel)
                .background(.clear.opacity(0.2))
        }

        ImmersiveSpace(id: appModel.immersiveSpaceID) {
            ImmersiveGameView(score: $score)
                .environment(appModel)
                .environment (model)

                .onAppear {
                    appModel.immersiveSpaceState = .open
                }
                .onDisappear {
                    appModel.immersiveSpaceState = .closed
                }
        }
        .immersionStyle(selection: .constant(.mixed), in: .mixed)
     }
}
let logger = Logger(subsystem: "com.apple-samplecode.SceneReconstructionExample", category: "general")
