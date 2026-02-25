import SwiftUI
//
//  NetworkNodesView.swift
//  HopChat-1
//
//  Created by Rodrigo Loução on 25/02/2026.
//


struct NetworkNodesView: View {
    let isAnimating: Bool
    let nodes: [(x: CGFloat, y: CGFloat)] = [
        (0.2, 0.3), (0.4, 0.7), (0.6, 0.2), (0.8, 0.5), (0.9, 0.8)
    ]
    
    var body: some View {
        ZStack {
            // Faint orange background square
            RoundedRectangle(cornerRadius: 24)
                .fill(.orange.opacity(0.1))
            
            ForEach(0..<nodes.count, id: \.self) { i in
                Circle()
                    .fill(isAnimating ? .orange : .white.opacity(0.8))
                    .frame(width: 20 + CGFloat(i) * 4, height: 20 + CGFloat(i) * 4)
                    .scaleEffect(isAnimating ? 1.2 : 1.0)
                    .animation(.easeInOut(duration: 1.5).repeatForever(autoreverses: true).delay(Double(i) * 0.2), value: isAnimating)
                    .offset(x: nodes[i].x * 300 - 150, y: nodes[i].y * 300 - 150)
            }
        }
        .scaleEffect(isAnimating ? 1.05 : 1.0)
    }
}
