import LernKern
import SwiftUI

struct RootView: View {
    @Environment(AppModel.self) private var model
    @State private var tab: Tab = .today

    enum Tab: Hashable { case today, plan, material, progress, profile }

    var body: some View {
        Group {
            if let error = model.loadError {
                DataErrorView(message: error)
            } else if !model.state.settings.onboardingCompleted {
                OnboardingView()
            } else {
                TabView(selection: $tab) {
                    TodayView(selectedTab: $tab)
                        .tabItem { Label("Heute", systemImage: "sun.max") }
                        .tag(Tab.today)
                    PlanView()
                        .tabItem { Label("Lernplan", systemImage: "calendar") }
                        .tag(Tab.plan)
                    MaterialView()
                        .tabItem { Label("Lernstoff", systemImage: "books.vertical") }
                        .tag(Tab.material)
                    ProgressOverviewView()
                        .tabItem { Label("Fortschritt", systemImage: "chart.line.uptrend.xyaxis") }
                        .tag(Tab.progress)
                    ProfileView()
                        .tabItem { Label("Profil", systemImage: "person.crop.circle") }
                        .tag(Tab.profile)
                }
            }
        }
        .overlay(alignment: .top) {
            if let banner = model.banner {
                BannerView(banner: banner) { model.banner = nil }
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .task(id: banner.id) {
                        try? await Task.sleep(for: .seconds(banner.kind == .warning ? 12 : 7))
                        if model.banner?.id == banner.id { model.banner = nil }
                    }
                    .padding(.top, 4)
            }
        }
        .animation(.easeInOut(duration: 0.25), value: model.banner)
        .fullScreenCover(isPresented: Binding(
            get: { model.session != nil && model.state.settings.onboardingCompleted },
            set: { if !$0 { model.closeSession() } }
        )) {
            SessionView()
                .environment(model)
        }
    }
}

struct DataErrorView: View {
    @Environment(AppModel.self) private var model
    var message: String
    @State private var confirmReset = false

    var body: some View {
        ContentUnavailableView {
            Label("Daten nicht lesbar", systemImage: "exclamationmark.triangle")
        } description: {
            Text(message)
        } actions: {
            Button("App zurücksetzen", role: .destructive) { confirmReset = true }
        }
        .confirmationDialog("Alle Daten löschen und neu beginnen?", isPresented: $confirmReset, titleVisibility: .visible) {
            Button("Alles löschen", role: .destructive) {
                model.deleteAllData()
                model.loadError = nil
            }
        }
    }
}
