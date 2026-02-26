//
//  HomeView.swift
//  HopChat-1
//
//  Created by Rodrigo Loução on 26/02/2026.
//

import SwiftUI

struct HomeView : View {
    
    var body : some View {
        VStack{
            HStack{
                ZStack {
                    Image(systemName: "wifi")
                        .font(.system(size: 40))
                        .foregroundStyle(.blue)
                        .shadow(color: .blue.opacity(0.4), radius: 20, x: 0, y: 10)
                        .padding(.leading)
                }
                Text("HopChat")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .font(.title2.weight(.bold))
                    .foregroundStyle(.blue)
                    .padding([.bottom, .vertical], 20)
                
                
            }
            
            Spacer()
           
            .padding()
            
        }
    }
}

#Preview{
    HomeView()
}
