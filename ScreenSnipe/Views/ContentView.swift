import SwiftUI

struct ContentView: View {
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "camera.viewfinder")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)

            Text("Screen Snipe")
                .font(.largeTitle)
                .fontWeight(.bold)

            Text("Ready to capture")
                .foregroundStyle(.secondary)
        }
        .frame(width: 400, height: 300)
    }
}

#Preview {
    ContentView()
}
