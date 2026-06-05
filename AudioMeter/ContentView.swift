import SwiftUI

struct ContentView: View {
    @StateObject private var engine = AudioCaptureEngine()

    var body: some View {
        VStack(spacing: 0) {

            // ── Title bar (full width) ─────────────────────────────────────
            HStack(spacing: 8) {
                Circle()
                    .fill(engine.isCapturing ? Color.green : Color.gray.opacity(0.35))
                    .frame(width: 6, height: 6)

                Text("AUDIO METER")
                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
                    .foregroundColor(.gray.opacity(0.7))
                    .tracking(2)

                Spacer()

                if let err = engine.errorMessage {
                    Text(err)
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundColor(.orange)
                }

                Button {
                    Task { await engine.toggle() }
                } label: {
                    Image(systemName: engine.isCapturing ? "stop.fill" : "play.fill")
                        .font(.system(size: 10))
                        .foregroundColor(engine.isCapturing ? .red.opacity(0.85) : .green.opacity(0.85))
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 12)
            .frame(height: 28)

            divider

            // ── Body: waveform (left) + LUFS meter (right) ─────────────────
            HStack(spacing: 0) {

                // Waveform takes all remaining width
                WaveformMetalView(renderer: engine.waveRenderer)
                    .overlay(alignment: .topLeading) {
                        VStack(alignment: .leading, spacing: 0) {
                            Text("L")
                                .font(.system(size: 9, weight: .medium, design: .monospaced))
                                .foregroundColor(Color(red: 0.25, green: 0.85, blue: 0.50).opacity(0.45))
                                .padding(.leading, 9).padding(.top, 4)
                            Spacer()
                            Text("R")
                                .font(.system(size: 9, weight: .medium, design: .monospaced))
                                .foregroundColor(Color(red: 0.20, green: 0.65, blue: 0.95).opacity(0.45))
                                .padding(.leading, 9).padding(.bottom, 4)
                        }
                    }

                dividerV

                // LUFS meter — fixed-width right panel
                LUFSBarMeterView(lufsM: engine.lufsM, lufsS: engine.lufsS,
                                 lufsMPeak: engine.lufsMPeak, lufsSPeak: engine.lufsSPeak)
                    .frame(width: 160)
            }
        }
        .frame(minWidth: 520, minHeight: 160)
        .background(Color(red: 0.07, green: 0.07, blue: 0.09))
        .preferredColorScheme(.dark)
        .onAppear {
            Task { await engine.start() }
            if let win = NSApp.mainWindow {
                // Floating: selalu di atas window lain
                win.level = .floating
                // canJoinAllSpaces: muncul di semua Space/desktop
                // stationary: tidak tersapu Mission Control
                // Tidak include .fullScreenPrimary → tombol full screen dinonaktifkan
                // sehingga window tidak bisa masuk full screen dan tidak bisa "terkunci"
                win.collectionBehavior = [.canJoinAllSpaces, .stationary]
            }
        }
    }

    private var divider: some View {
        Rectangle().fill(Color.white.opacity(0.07)).frame(height: 1)
    }

    private var dividerV: some View {
        Rectangle().fill(Color.white.opacity(0.07)).frame(width: 1)
    }
}

#Preview {
    ContentView().frame(width: 700, height: 340)
}
