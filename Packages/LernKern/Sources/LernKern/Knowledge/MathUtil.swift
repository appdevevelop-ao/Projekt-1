import Foundation

enum MathUtil {
    static func sigmoid(_ x: Double) -> Double { 1 / (1 + exp(-x)) }

    static func logit(_ p: Double) -> Double {
        let q = min(max(p, 0.001), 0.999)
        return log(q / (1 - q))
    }

    static func clamp(_ x: Double, _ lo: Double, _ hi: Double) -> Double { min(max(x, lo), hi) }

    /// Verteilungsfunktion der Standardnormalverteilung (Abramowitz-Stegun 7.1.26).
    static func normalCDF(_ x: Double) -> Double {
        let sign: Double = x < 0 ? -1 : 1
        let z = abs(x) / 2.0.squareRoot()
        let t = 1 / (1 + 0.3275911 * z)
        let y = 1 - (((((1.061405429 * t - 1.453152027) * t) + 1.421413741) * t - 0.284496736) * t + 0.254829592) * t * exp(-z * z)
        return 0.5 * (1 + sign * y)
    }
}
