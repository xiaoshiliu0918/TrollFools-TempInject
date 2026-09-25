//
//  TrollFoolsApp.swift
//  TrollFools
//
//  Created by Lessica on 2024/7/19.
//

import SwiftUI

@main
struct TrollFoolsApp: SwiftUI.App {

    @AppStorage("isDisclaimerHiddenV2")
    var isDisclaimerHidden: Bool = false

    init() {
        try? FileManager.default.removeItem(at: InjectorV3.temporaryRoot)
        // TempInject: restore orphan sessions whose watchdog has died
        DispatchQueue.global(qos: .utility).async {
            TempInjectManager.shared.cleanupOrphans()
        }
    }

    var body: some Scene {
        WindowGroup {
            TempHomeView()
        }
    }
}
