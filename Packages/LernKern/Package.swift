// swift-tools-version: 6.0
//
// LernKern enthält die plattformunabhängige Lernlogik (Wissensmodell, Fortschritt,
// Prognosen, Lernplan, Belohnungen, Dokumentverarbeitung). Sie hängt nur von
// Foundation ab und ist daher auch unter Linux kompilier- und testbar.
//
// ShieldLogic ist bewusst klein gehalten: Sie enthält nur die Entscheidungslogik
// für die App-Sperre und wird zusätzlich von den speicherbegrenzten
// Screen-Time-Erweiterungen verwendet.
import PackageDescription

let package = Package(
    name: "LernKern",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "ShieldLogic", targets: ["ShieldLogic"]),
        .library(name: "LernKern", targets: ["LernKern"]),
    ],
    targets: [
        .target(name: "ShieldLogic"),
        .target(name: "LernKern", dependencies: ["ShieldLogic"]),
        .testTarget(name: "LernKernTests", dependencies: ["LernKern", "ShieldLogic"], resources: [.copy("Resources")]),
    ]
)
