//
//  ContentView.swift
//  music_web
//
//  Created by txg on 2024/12/30.
//

import SwiftUI
import WebKit

struct ContentView: View {
    var body: some View {
        GeometryReader { geometry in
            WebView(url: URL(string: "https://musch")!)
                .frame(width: geometry.size.width, height: geometry.size.height * 6)
                .edgesIgnoringSafeArea(.all)
        }
    }
}

struct WebView: UIViewRepresentable {
    let url: URL

    func makeUIView(context: Context) -> WKWebView {
        return WKWebView()
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {
        let request = URLRequest(url: url)
        uiView.load(request)
    }
}

#Preview {
    ContentView()
}
