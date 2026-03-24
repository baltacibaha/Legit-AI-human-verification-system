import SwiftUI

struct LegitScoreDimension: Identifiable {
    let id = UUID()
    let label: String
    let shortLabel: String
    let value: Double
    let weight: Double
    let color: Color
    let systemIcon: String
}

struct LegitScoreResult {
    let dimensions: [LegitScoreDimension]
    let composite: Double

    static func compute(identityScore: Double, consistencyScore: Double, presenceScore: Double,
                        aiDetectionRaw: Double, historyScore: Double, consensusScore: Double) -> LegitScoreResult {
        let aiInverse = max(0, 1.0 - aiDetectionRaw)
        let dims: [LegitScoreDimension] = [
            LegitScoreDimension(label: "Identity",    shortLabel: "ID",  value: min(max(identityScore, 0), 1),    weight: 0.25, color: Color(red:0.40,green:0.35,blue:0.92), systemIcon: "person.badge.shield.checkmark.fill"),
            LegitScoreDimension(label: "Consistency", shortLabel: "CON", value: min(max(consistencyScore, 0), 1), weight: 0.15, color: Color(red:0.20,green:0.72,blue:0.60), systemIcon: "checkmark.seal.fill"),
            LegitScoreDimension(label: "Presence",    shortLabel: "PRS", value: min(max(presenceScore, 0), 1),    weight: 0.20, color: Color(red:0.15,green:0.65,blue:0.95), systemIcon: "location.fill.viewfinder"),
            LegitScoreDimension(label: "AI Detection",shortLabel: "AI",  value: min(max(aiInverse, 0), 1),        weight: 0.20, color: Color(red:0.95,green:0.58,blue:0.22), systemIcon: "brain.head.profile"),
            LegitScoreDimension(label: "History",     shortLabel: "HST", value: min(max(historyScore, 0), 1),     weight: 0.10, color: Color(red:0.85,green:0.28,blue:0.50), systemIcon: "clock.badge.checkmark.fill"),
            LegitScoreDimension(label: "Consensus",   shortLabel: "CSN", value: min(max(consensusScore, 0), 1),   weight: 0.10, color: Color(red:0.30,green:0.80,blue:0.42), systemIcon: "person.3.fill"),
        ]
        let composite = dims.reduce(0.0) { $0 + $1.value * $1.weight } * 100.0
        return LegitScoreResult(dimensions: dims, composite: min(max(composite, 0), 100))
    }
}

struct ArcShape: Shape {
    var startAngle: Angle; var endAngle: Angle; var lineWidth: CGFloat
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.addArc(center: CGPoint(x: rect.midX, y: rect.midY),
                    radius: min(rect.width, rect.height) / 2.0 - lineWidth / 2.0,
                    startAngle: startAngle, endAngle: endAngle, clockwise: false)
        return path
    }
}

struct LegitRingView: View {
    let dimension: LegitScoreDimension; let ringRadius: CGFloat; let lineWidth: CGFloat; let animated: Bool
    @State private var animatedValue: Double = 0.0
    var body: some View {
        ZStack {
            Circle().stroke(dimension.color.opacity(0.15), style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .frame(width: ringRadius * 2, height: ringRadius * 2)
            ArcShape(startAngle: .degrees(-90), endAngle: .degrees(-90 + 360.0 * animatedValue), lineWidth: lineWidth)
                .stroke(dimension.color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .frame(width: ringRadius * 2, height: ringRadius * 2)
                .animation(animated ? .easeOut(duration: 1.2).delay(Double(dimension.weight) * 0.5) : .none, value: animatedValue)
        }
        .onAppear { animatedValue = dimension.value }
        .onChange(of: dimension.value) { _, newValue in withAnimation(.easeOut(duration: 0.8)) { animatedValue = newValue } }
    }
}

struct LegitConcentricRings: View {
    let result: LegitScoreResult; let animated: Bool
    private let baseRadius: CGFloat = 110; private let ringSpacing: CGFloat = 18; private let lineWidth: CGFloat = 11
    var body: some View {
        ZStack {
            ForEach(Array(result.dimensions.enumerated()), id: \.element.id) { index, dim in
                LegitRingView(dimension: dim, ringRadius: baseRadius - CGFloat(index) * ringSpacing, lineWidth: lineWidth, animated: animated)
            }
            VStack(spacing: 2) {
                Text(String(Int(result.composite.rounded()))).font(.system(size: 38, weight: .bold, design: .rounded)).foregroundStyle(.primary).monospacedDigit().contentTransition(.numericText())
                Text("LEGIT").font(.system(size: 11, weight: .semibold, design: .rounded)).foregroundStyle(.secondary).tracking(3)
            }
        }
        .frame(width: (baseRadius + lineWidth) * 2 + 8, height: (baseRadius + lineWidth) * 2 + 8)
    }
}

struct LegitDimensionRow: View {
    let dimension: LegitScoreDimension
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: dimension.systemIcon).font(.system(size: 15, weight: .medium)).foregroundStyle(dimension.color).frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(dimension.label).font(.system(size: 13, weight: .medium, design: .rounded)).foregroundStyle(.primary)
                    Spacer()
                    Text("\(Int((dimension.value * 100).rounded()))").font(.system(size: 13, weight: .semibold, design: .rounded)).monospacedDigit().foregroundStyle(dimension.color)
                    Text("/ 100").font(.system(size: 11)).foregroundStyle(.tertiary)
                }
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 3).fill(dimension.color.opacity(0.12)).frame(height: 4)
                        RoundedRectangle(cornerRadius: 3).fill(dimension.color).frame(width: geo.size.width * dimension.value, height: 4).animation(.easeOut(duration: 0.8), value: dimension.value)
                    }
                }.frame(height: 4)
            }
            Text("\(Int(dimension.weight * 100))%").font(.system(size: 10, weight: .medium, design: .rounded)).foregroundStyle(.quaternary).frame(width: 28, alignment: .trailing)
        }
        .padding(.vertical, 4)
    }
}

struct GlassCard<Content: View>: View {
    var content: Content
    init(@ViewBuilder content: () -> Content) { self.content = content() }
    var body: some View {
        content.background {
            RoundedRectangle(cornerRadius: 22, style: .continuous).fill(.ultraThinMaterial)
                .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).stroke(Color.white.opacity(0.18), lineWidth: 0.5))
        }
    }
}

struct HashPillView: View {
    let hash: String; @State private var copied = false
    var body: some View {
        Button {
            UIPasteboard.general.string = hash
            withAnimation(.spring(response: 0.3)) { copied = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { withAnimation { copied = false } }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: copied ? "checkmark" : "doc.on.doc").font(.system(size: 11, weight: .medium)).foregroundStyle(copied ? .green : .secondary)
                Text(copied ? "Copied" : String(hash.prefix(24)) + "...").font(.system(size: 10, weight: .medium, design: .monospaced)).foregroundStyle(.secondary).lineLimit(1)
            }
            .padding(.horizontal, 10).padding(.vertical, 5).background(Capsule().fill(Color.primary.opacity(0.06)))
        }.buttonStyle(.plain)
    }
}

struct LegitPassportView: View {
    let scoreResult: LegitScoreResult; let proofHash: String; let timestamp: String
    let locationLabel: String; let isVerified: Bool
    @State private var animateRings = false; @State private var showDetails = false
    @Environment(\.colorScheme) var colorScheme

    private var verificationLabel: String {
        if scoreResult.composite >= 80 { return "High Confidence" }
        if scoreResult.composite >= 60 { return "Moderate Confidence" }
        if scoreResult.composite >= 40 { return "Low Confidence" }
        return "Unverified"
    }
    private var verificationColor: Color {
        if scoreResult.composite >= 80 { return .green }
        if scoreResult.composite >= 60 { return Color(red:0.95,green:0.58,blue:0.22) }
        return .red
    }

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(spacing: 24) {
                // Header
                VStack(spacing: 6) {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("LEGIT").font(.system(size: 28, weight: .bold, design: .rounded)).foregroundStyle(.primary).tracking(1)
                            Text("Content Passport").font(.system(size: 13, weight: .medium, design: .rounded)).foregroundStyle(.secondary)
                        }
                        Spacer()
                        ZStack {
                            Circle().fill(verificationColor.opacity(0.15)).frame(width: 50, height: 50)
                            Image(systemName: isVerified ? "checkmark.shield.fill" : "exclamationmark.shield.fill").font(.system(size: 24, weight: .medium)).foregroundStyle(verificationColor)
                        }
                    }
                    HStack {
                        Label(verificationLabel, systemImage: "circle.fill").font(.system(size: 11, weight: .semibold, design: .rounded)).foregroundStyle(verificationColor)
                        Spacer()
                        Text(timestamp).font(.system(size: 11, weight: .regular, design: .monospaced)).foregroundStyle(.tertiary)
                    }
                }

                // Rings
                GlassCard {
                    VStack(spacing: 20) {
                        LegitConcentricRings(result: scoreResult, animated: animateRings).padding(.top, 12)
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 14) {
                                ForEach(scoreResult.dimensions) { dim in
                                    VStack(spacing: 4) {
                                        Circle().fill(dim.color).frame(width: 8, height: 8)
                                        Text(dim.shortLabel).font(.system(size: 9, weight: .semibold, design: .rounded)).foregroundStyle(dim.color).tracking(0.5)
                                    }
                                }
                            }.padding(.horizontal, 20)
                        }.padding(.bottom, 6)
                    }.padding(.vertical, 16)
                }

                // Breakdown
                GlassCard {
                    VStack(alignment: .leading, spacing: 0) {
                        Button { withAnimation(.spring(response: 0.4, dampingFraction: 0.75)) { showDetails.toggle() } } label: {
                            HStack {
                                Text("Score Breakdown").font(.system(size: 14, weight: .semibold, design: .rounded)).foregroundStyle(.primary)
                                Spacer()
                                Image(systemName: "chevron.down").font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary).rotationEffect(.degrees(showDetails ? 180 : 0))
                            }.padding(.horizontal, 18).padding(.vertical, 14)
                        }.buttonStyle(.plain)
                        if showDetails {
                            Divider().padding(.horizontal, 18)
                            VStack(spacing: 4) {
                                ForEach(scoreResult.dimensions) { dim in LegitDimensionRow(dimension: dim).padding(.horizontal, 18) }
                            }.padding(.vertical, 12).transition(.opacity.combined(with: .move(edge: .top)))
                        }
                    }
                }

                // Hash
                GlassCard {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Cryptographic Proof").font(.system(size: 12, weight: .semibold, design: .rounded)).foregroundStyle(.secondary).tracking(0.5).padding(.horizontal, 18).padding(.top, 14)
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Image(systemName: "location.fill").font(.system(size: 11)).foregroundStyle(.secondary)
                                Text(locationLabel).font(.system(size: 12, weight: .regular, design: .rounded)).foregroundStyle(.secondary)
                            }
                            HashPillView(hash: proofHash)
                        }.padding(.horizontal, 18).padding(.bottom, 14)
                    }
                }
            }
            .padding(.horizontal, 20).padding(.vertical, 28)
        }
        .onAppear { DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { animateRings = true } }
    }
}
