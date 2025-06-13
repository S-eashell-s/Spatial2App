//
//  AppModel.swift
//  TestingAnchorEntities
//
//  Created by Joel Lewis on 08/04/2025.

import SwiftUI
import ARKit
import RealityFoundation

/// Maintains app-wide state
@MainActor
@Observable

class AppModel {
    let immersiveSpaceID = "ImmersiveSpace"
    enum ImmersiveSpaceState {
        case closed
        case inTransition
        case open
    }
    var immersiveSpaceState = ImmersiveSpaceState.closed
}
