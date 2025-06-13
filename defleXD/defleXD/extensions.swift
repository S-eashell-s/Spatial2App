
//  DragGestureImproved.swift
//  DefleXD_VR
//
//  Created by Shelly on 23/03/2025.
//
import SwiftUI
import RealityKit
import ARKit
//RealityKit doesn’t expose .translation on simd_float4x4 by default, so this is added as a helper to extract translation
extension simd_float4x4 {
    var translation: SIMD3<Float> {
        return SIMD3(columns.3.x, columns.3.y, columns.3.z)
    }
}
