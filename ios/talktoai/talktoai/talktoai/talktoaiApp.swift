//
//  talktoaiApp.swift
//  talktoai
//
//  Created by txg on 2024/12/30.
//

import SwiftUI

@main
struct talktoaiApp: App {
    let persistenceController = PersistenceController.shared
    
    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(\.managedObjectContext, persistenceController.container.viewContext)
        }
    }
}
