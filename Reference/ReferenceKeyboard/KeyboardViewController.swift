//
//  KeyboardViewController.swift
//  ReferenceKeyboard
//
//  The whole product side of a General Keyboard extension: install the
//  definition, then let the engine do everything. A real keyboard looks
//  the same with its own definition.
//

import Foundation
import GeneralKeyboard
import GeneralKeyboardReference
#if DEBUG
import os.log
#endif

final class KeyboardViewController: GeneralKeyboardViewController {

    override init(nibName: String?, bundle: Bundle?) {
        KeyboardDefinition.install(ReferenceDefinition.definition)
        super.init(nibName: nibName, bundle: bundle)
    }

    required init?(coder: NSCoder) {
        KeyboardDefinition.install(ReferenceDefinition.definition)
        super.init(coder: coder)
    }

    #if DEBUG
    override func viewDidLoad() {
        super.viewDidLoad()
        // Phase 2 spike: the engine's resource bundle must resolve inside
        // the .appex. Logs the bundle path and a Russian lookup.
        let bundle = GeneralKeyboardResources.bundle
        let ru = bundle.path(forResource: "ru", ofType: "lproj").flatMap(Bundle.init(path:))
        Logger(subsystem: "org.lekitech.generalkeyboard.ReferenceKeyboard", category: "gk-spike")
            .log("[gk-spike] bundle=\(bundle.bundlePath, privacy: .public) ru.layout=\(ru?.localizedString(forKey: "layout", value: "MISSING", table: nil) ?? "NO-RU", privacy: .public)")
    }
    #endif
}
