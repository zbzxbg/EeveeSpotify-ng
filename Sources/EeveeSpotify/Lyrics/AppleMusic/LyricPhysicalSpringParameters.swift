import Foundation

// 移植自 MeloX `MeloX/Core/Lyrics/LyricPhysicalSpringParameters.swift`（GPL-3.0）。

/// 物理弹簧的求解输入。构造时归一化，保证动画代码永远拿不到非有限/非物理的值。
struct LyricPhysicalSpringParameters: Equatable, Sendable {
    let mass: Double
    let stiffness: Double
    let damping: Double

    init(
        mass: Double,
        stiffness: Double,
        damping: Double
    ) {
        self.mass = Self.positiveFinite(mass, fallback: 1)
        self.stiffness = Self.positiveFinite(stiffness, fallback: 1)
        self.damping = Self.nonnegativeFinite(damping, fallback: 0)
    }

    var dampingRatio: Double {
        damping / (2 * sqrt(mass * stiffness))
    }

    var undampedPeriod: TimeInterval {
        2 * .pi * sqrt(mass / stiffness)
    }

    private static func positiveFinite(
        _ value: Double,
        fallback: Double
    ) -> Double {
        value.isFinite && value > 0 ? value : fallback
    }

    private static func nonnegativeFinite(
        _ value: Double,
        fallback: Double
    ) -> Double {
        value.isFinite && value >= 0 ? value : fallback
    }
}
