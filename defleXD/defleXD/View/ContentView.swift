//
//  ContentView.swift
//  defleXD
//
//  Created by Shelly on 28/02/2025.
//


import SwiftUI
import RealityKit
import RealityKitContent
import ARKit
//TODO: immerssive view button launches the game start but doesnt start it until you press start game inside the immersivegame view

// Defines different game states
struct ContentView: View {
    
    var body: some View {
        VStack(spacing: 20) {
            Text("Welcome to")
                .font(.largeTitle)
                .foregroundColor(.white)
                .padding(80)
            if let uiImage = UIImage(named: "logo.png") { //adds my logo
                Image(uiImage: uiImage)
                    .resizable()
                    .scaledToFit()
                  //  no need .frame(width: 300, height: 100)
            } else {
                Text("Image not found") //debuggign just in case
            }
            ToggleImmersiveSpaceButton(model: EntityModel())
                .padding(80)
        }
        .frame(width:1280, height: 720) // Makes the VStack wider
        .background(LinearGradient(
            gradient: Gradient(colors: [.purple, .indigo, .cyan]),
            startPoint: .topLeading,
            endPoint: .bottomTrailing))
        .clipShape(RoundedRectangle(cornerRadius: 50))
    }
}
#Preview(windowStyle: .automatic) {
    ContentView()
        .environment(AppModel())
}


