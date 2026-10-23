#if DEBUG
import Foundation
import LernKern

/// Nur in Debug-Builds: Beispieldaten für Bildschirmfotos und Vorführungen.
/// Start mit den Argumenten `-LFDemo YES -LFScreen <today|plan|material|exam|progress|profile|session|onboarding>`.
/// Nutzt ein eigenes temporäres Datenverzeichnis und berührt nie echte Daten.
enum DemoMode {
    static var isActive: Bool { UserDefaults.standard.bool(forKey: "LFDemo") }
    static var screen: String { UserDefaults.standard.string(forKey: "LFScreen") ?? "today" }
    static var directory: URL { FileManager.default.temporaryDirectory.appendingPathComponent("LernFokusDemo", isDirectory: true) }
    nonisolated(unsafe) static var examID: UUID?

    static let material = """
    # Kapitel 1: Die Zelle

    ## Zellmembran
    Die Zellmembran ist eine Doppelschicht aus Phospholipiden, die die Zelle nach außen abgrenzt und den Stoffaustausch reguliert.

    ## Mitochondrien
    Die Mitochondrien sind Zellorganellen, in denen die Zellatmung stattfindet und ATP gebildet wird.

    ## Ribosomen
    Die Ribosomen sind Komplexe aus RNA und Proteinen, an denen die Proteinbiosynthese stattfindet.

    ## Zellkern
    Der Zellkern ist ein von einer Doppelmembran umgebenes Organell, das die DNA der Zelle enthält.

    ## Diffusion
    Die Diffusion bezeichnet die selbstständige Bewegung von Teilchen vom Ort höherer zum Ort niedrigerer Konzentration.

    ## Osmose
    Die Osmose ist die Diffusion von Wasser durch eine selektiv permeable Membran.

    # Kapitel 2: Stoffwechsel

    ## Zellatmung
    Die Zellatmung bezeichnet den Abbau von Glukose unter Energiegewinnung in den Mitochondrien. Dabei entsteht ATP als universeller Energieträger der Zelle.

    ## Photosynthese
    Die Photosynthese ist ein Prozess, bei dem Pflanzen Lichtenergie in chemische Energie umwandeln. Sie findet in den Chloroplasten der Blattzellen statt.

    ## Gärung
    Die Gärung ist ein Stoffwechselweg, bei dem Glukose ohne Sauerstoff abgebaut wird.

    ## Enzyme
    Enzyme sind Proteine, die als Biokatalysatoren chemische Reaktionen beschleunigen, ohne dabei verbraucht zu werden.

    # Kapitel 3: Zellteilung

    ## Mitose
    Die Mitose ist eine Form der Kernteilung, bei der zwei genetisch identische Tochterkerne entstehen. Sie verläuft in Prophase, Metaphase, Anaphase und Telophase.

    ## Meiose
    Die Meiose ist eine Reifeteilung, bei der der Chromosomensatz halbiert wird. Aus einer diploiden Zelle entstehen dabei vier haploide Keimzellen.

    ## Crossing-over
    Das Crossing-over ist der Austausch von Abschnitten zwischen homologen Chromosomen während der Meiose.
    """
}
#endif
