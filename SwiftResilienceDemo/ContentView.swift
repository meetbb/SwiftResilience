//
//  ContentView.swift
//  SwiftResilienceDemo
//
//  A living showcase of SwiftResilience's core features:
//  • Exponential retry with backoff
//  • Request deduplication
//  • Offline request queue with simulated connectivity toggle
//  • Observability & metrics dashboard

import SwiftUI
import SwiftResilience

// MARK: - Log Entry

struct LogEntry: Identifiable {
    let id = UUID()
    let text: String
    let type: LogType

    enum LogType {
        case started, succeeded, failed, retry, deduped

        var color: Color {
            switch self {
            case .started:   return .blue
            case .succeeded: return .green
            case .failed:    return .red
            case .retry:     return .orange
            case .deduped:   return .purple
            }
        }

        var icon: String {
            switch self {
            case .started:   return "arrow.up.circle"
            case .succeeded: return "checkmark.circle.fill"
            case .failed:    return "xmark.circle.fill"
            case .retry:     return "arrow.clockwise.circle.fill"
            case .deduped:   return "equal.circle.fill"
            }
        }
    }
}

// MARK: - Observable Event Log
//
// Lives on the MainActor so SwiftUI can observe it directly.
// Bridges the actor-based RequestEventSink protocol into @Published state.

@MainActor
final class EventLog: ObservableObject, @unchecked Sendable {
    @Published var entries: [LogEntry] = []

    func add(_ entry: LogEntry) {
        entries.insert(entry, at: 0)
        if entries.count > 60 { entries.removeLast() }
    }

    func clear() { entries = [] }
}

extension EventLog: RequestEventSink {
    nonisolated func record(_ event: RequestEvent) async {
        let entry: LogEntry
        switch event {
        case .started(_, let url, let method):
            let path = url.lastPathComponent.isEmpty
                ? (url.host() ?? url.absoluteString)
                : url.lastPathComponent
            entry = LogEntry(text: "\(method.rawValue)  /\(path)", type: .started)

        case .succeeded(_, let code, let duration, let attempt):
            entry = LogEntry(
                text: "\(code) OK · \(String(format: "%.2f", duration))s · attempt \(attempt + 1)",
                type: .succeeded
            )

        case .failed(_, _, let attempt):
            entry = LogEntry(text: "Failed after \(attempt + 1) attempt(s)", type: .failed)

        case .retryScheduled(_, let attempt, let delay):
            entry = LogEntry(
                text: "Attempt \(attempt + 1) failed — retry in \(String(format: "%.1f", delay))s",
                type: .retry
            )

        case .deduplicated(_, let url, _):
            let path = url.lastPathComponent.isEmpty
                ? (url.host() ?? url.absoluteString)
                : url.lastPathComponent
            entry = LogEntry(text: "Deduplicated → /\(path)", type: .deduped)
        }
        await MainActor.run { self.add(entry) }
    }
}

// MARK: - Simulated Reachability
//
// Lets the demo toggle connectivity without touching real NWPathMonitor.

actor SimulatedReachability: ReachabilityMonitoring {
    private(set) var isConnected: Bool
    var connectivity: AsyncStream<Bool> { _stream }

    private let _stream: AsyncStream<Bool>
    private let continuation: AsyncStream<Bool>.Continuation

    init(online: Bool = false) {
        isConnected = online
        let (stream, cont) = AsyncStream<Bool>.makeStream()
        _stream = stream
        continuation = cont
    }

    func setOnline(_ online: Bool) {
        isConnected = online
        continuation.yield(online)
    }
}

// MARK: - Concrete Request Types

struct PingRequest: NetworkRequest {
    let url: URL
    var method: HTTPMethod { .get }
}

struct FailingRequest: NetworkRequest {
    let url: URL
    var method: HTTPMethod { .get }
}

struct QueuedPost: QueueableRequest {
    let url: URL
    var method: HTTPMethod { .post }
    var body: Data? {
        try? JSONSerialization.data(withJSONObject: [
            "demo": true,
            "ts": Date().timeIntervalSince1970
        ])
    }
    var headers: [String: String] { ["Content-Type": "application/json"] }
    var priority: QueuePriority { .high }
    var ttl: TimeInterval { 3_600 }
}

// MARK: - ═══════════════════════════════════════════
// MARK:   TAB 1 — Retry Demo
// MARK: ═══════════════════════════════════════════

struct RetryDemoView: View {
    @StateObject private var log = EventLog()
    @State private var isBusy = false

    // Short base delay so the retry sequence finishes quickly in the demo.
    private func makeEngine() -> AsyncRequestEngine {
        AsyncRequestEngine(
            retryPolicy: ExponentialRetryPolicy(maxRetries: 3, baseDelay: 0.5),
            eventSink: log
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            DescriptionBox(
                icon: "arrow.clockwise",
                title: "Exponential Backoff",
                detail: "A 503 response is retried up to 3× with delays of 0.5 s → 1 s → 2 s. Tap either button and watch the event stream fill in below."
            )

            HStack(spacing: 12) {
                ActionButton(
                    label: "Trigger 503",
                    icon: "bolt.trianglebadge.exclamationmark",
                    tint: .orange,
                    disabled: isBusy
                ) { Task { await runFailing() } }

                ActionButton(
                    label: "Trigger Success",
                    icon: "checkmark.circle",
                    tint: .green,
                    disabled: isBusy
                ) { Task { await runSuccess() } }
            }
            .padding(.horizontal)
            .padding(.top, 12)

            Divider().padding(.vertical, 8)
            EventLogView(log: log)
        }
    }

    private func runFailing() async {
        isBusy = true
        log.clear()
        let engine = makeEngine()
        try? await engine.send(FailingRequest(url: URL(string: "https://httpstat.us/503")!))
        isBusy = false
    }

    private func runSuccess() async {
        isBusy = true
        log.clear()
        let engine = makeEngine()
        try? await engine.send(PingRequest(url: URL(string: "https://httpbin.org/get")!))
        isBusy = false
    }
}

// MARK: - ═══════════════════════════════════════════
// MARK:   TAB 2 — Deduplication Demo
// MARK: ═══════════════════════════════════════════

struct DeduplicationDemoView: View {
    @StateObject private var log = EventLog()
    @State private var isBusy = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            DescriptionBox(
                icon: "equal.circle",
                title: "Request Deduplication",
                detail: "Three identical requests fire concurrently against the same slow endpoint. Only 1 network call is made — the other 2 share its result. Look for the purple \"Deduplicated\" events."
            )

            ActionButton(
                label: "Fire 3 Concurrent Requests",
                icon: "arrow.triangle.2.circlepath",
                tint: .purple,
                disabled: isBusy,
                fullWidth: true
            ) { Task { await runDedup() } }
                .padding(.horizontal)
                .padding(.top, 12)

            Divider().padding(.vertical, 8)
            EventLogView(log: log)
        }
    }

    private func runDedup() async {
        isBusy = true
        log.clear()

        // All 3 requests share the same engine instance — this is what enables
        // deduplication. A separate engine per request would make 3 network calls.
        let engine = AsyncRequestEngine(eventSink: log)
        let url = URL(string: "https://httpbin.org/delay/2")!

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<3 {
                group.addTask { try? await engine.send(PingRequest(url: url)) }
            }
        }
        isBusy = false
    }
}

// MARK: - ═══════════════════════════════════════════
// MARK:   TAB 3 — Offline Queue Demo
// MARK: ═══════════════════════════════════════════

@MainActor
final class OfflineQueueModel: ObservableObject {
    @Published var isOnline = false
    @Published var queueCount = 0
    @Published var activityLog: [String] = []

    private let reachability = SimulatedReachability(online: false)
    private var queueEngine: OfflineQueueEngine?
    private var pollTask: Task<Void, Never>?

    init() {
        Task { await setup() }
    }

    private func setup() async {
        guard let store = try? DiskQueueStore() else {
            activityLog.insert("⚠ Could not initialise DiskQueueStore", at: 0)
            return
        }
        let netEngine = AsyncRequestEngine()
        let queue = OfflineQueueEngine(
            requestEngine: netEngine,
            reachabilityMonitor: reachability,
            store: store
        )
        await queue.start()
        queueEngine = queue

        // Poll queue depth so the badge stays current.
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 500_000_000)
                await self?.refreshCount()
            }
        }
        await refreshCount()
    }

    private func refreshCount() async {
        guard let q = queueEngine else { return }
        queueCount = await q.pendingCount()
    }

    func enqueue() async {
        guard let q = queueEngine else { return }
        let request = QueuedPost(url: URL(string: "https://httpbin.org/post")!)
        do {
            try await q.enqueue(request)
            let time = Date().formatted(.dateTime.hour().minute().second())
            let msg = isOnline
                ? "✓ Sent immediately (\(time))"
                : "⟳ Saved to disk (\(time))"
            activityLog.insert(msg, at: 0)
        } catch OfflineQueueError.full {
            activityLog.insert("⚠ Queue is full — request dropped", at: 0)
        } catch {
            activityLog.insert("✗ \(error.localizedDescription)", at: 0)
        }
        await refreshCount()
    }

    func toggleConnectivity() async {
        isOnline.toggle()
        await reachability.setOnline(isOnline)

        if isOnline {
            activityLog.insert("📶 Back online — draining queue…", at: 0)
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            await refreshCount()
            activityLog.insert(
                queueCount == 0
                    ? "✓ Queue fully drained"
                    : "⟳ \(queueCount) entr\(queueCount == 1 ? "y" : "ies") remain",
                at: 0
            )
        } else {
            activityLog.insert("🚫 Went offline — requests will queue to disk", at: 0)
        }
    }

    deinit { pollTask?.cancel() }
}

struct OfflineQueueDemoView: View {
    @StateObject private var model = OfflineQueueModel()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            DescriptionBox(
                icon: "tray.and.arrow.down",
                title: "Offline Request Queue",
                detail: "Enqueue requests while offline. They persist to disk and replay automatically when connectivity is restored — each with an idempotency key so the server can safely deduplicate replays."
            )

            // Connectivity banner
            HStack(spacing: 10) {
                Image(systemName: model.isOnline ? "wifi" : "wifi.slash")
                    .foregroundStyle(model.isOnline ? .green : .orange)
                Text(model.isOnline ? "Online" : "Offline")
                    .fontWeight(.semibold)
                Spacer()
                if model.queueCount > 0 {
                    Label("\(model.queueCount) queued", systemImage: "tray.fill")
                        .font(.caption.bold())
                        .foregroundStyle(.orange)
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 10)
            .background(model.isOnline ? Color.green.opacity(0.08) : Color.orange.opacity(0.08))

            HStack(spacing: 12) {
                ActionButton(
                    label: "Enqueue Request",
                    icon: "tray.and.arrow.down",
                    tint: .blue,
                    disabled: false
                ) { Task { await model.enqueue() } }

                ActionButton(
                    label: model.isOnline ? "Go Offline" : "Go Online",
                    icon: model.isOnline ? "wifi.slash" : "wifi",
                    tint: model.isOnline ? .red : .green,
                    disabled: false
                ) { Task { await model.toggleConnectivity() } }
            }
            .padding(.horizontal)
            .padding(.top, 12)

            Divider().padding(.vertical, 8)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 4) {
                    ForEach(model.activityLog.indices, id: \.self) { i in
                        Text(model.activityLog[i])
                            .font(.caption.monospaced())
                            .padding(.horizontal)
                    }
                }
            }
        }
    }
}

// MARK: - ═══════════════════════════════════════════
// MARK:   TAB 4 — Metrics Dashboard
// MARK: ═══════════════════════════════════════════

// Forwards events to both the visual log and the metrics collector.
actor DualSink: RequestEventSink {
    private let log: EventLog
    private let collector: RequestMetricsCollector

    init(log: EventLog, collector: RequestMetricsCollector) {
        self.log = log
        self.collector = collector
    }

    func record(_ event: RequestEvent) async {
        await log.record(event)
        await collector.record(event)
    }
}

struct MetricsDemoView: View {
    @StateObject private var log = EventLog()
    @State private var collector = RequestMetricsCollector()
    @State private var metrics: RequestMetrics?
    @State private var isBusy = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                DescriptionBox(
                    icon: "chart.bar.fill",
                    title: "Observability & Metrics",
                    detail: "Fires a mix of requests (success, 503 retries, dedup). RequestMetricsCollector aggregates the RequestEventSink stream into a live snapshot."
                )

                HStack(spacing: 12) {
                    ActionButton(
                        label: "Run Mix",
                        icon: "play.fill",
                        tint: .indigo,
                        disabled: isBusy
                    ) { Task { await runMix() } }

                    Button("Reset") {
                        Task {
                            await collector.reset()
                            log.clear()
                            metrics = nil
                        }
                    }
                    .buttonStyle(.bordered)
                    .disabled(isBusy)
                }

                if let m = metrics {
                    MetricsDashboard(metrics: m)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }

                if !log.entries.isEmpty {
                    Divider()
                    Text("Event Stream")
                        .font(.caption.bold())
                        .foregroundStyle(.secondary)
                    ForEach(log.entries) { entry in
                        EventRow(entry: entry)
                    }
                }
            }
            .padding()
            .animation(.easeInOut(duration: 0.3), value: metrics != nil)
        }
    }

    private func runMix() async {
        isBusy = true
        let sink = DualSink(log: log, collector: collector)
        let engine = AsyncRequestEngine(
            retryPolicy: ExponentialRetryPolicy(maxRetries: 2, baseDelay: 0.3),
            eventSink: sink
        )
        let slowURL = URL(string: "https://httpbin.org/delay/1")!
        let failURL = URL(string: "https://httpstat.us/503")!

        await withTaskGroup(of: Void.self) { group in
            // 1 clean success
            group.addTask {
                try? await engine.send(PingRequest(url: URL(string: "https://httpbin.org/get")!))
            }
            // 1 retrying 503 (ultimately fails)
            group.addTask {
                try? await engine.send(FailingRequest(url: failURL))
            }
            // 2 concurrent identical slow requests → 1 network call + 1 dedup event
            group.addTask {
                try? await engine.send(PingRequest(url: slowURL))
            }
            group.addTask {
                try? await engine.send(PingRequest(url: slowURL))
            }
        }

        metrics = await collector.snapshot()
        isBusy = false
    }
}

struct MetricsDashboard: View {
    let metrics: RequestMetrics
    private let columns = [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            LazyVGrid(columns: columns, spacing: 10) {
                MetricCard(value: "\(metrics.requestsStarted)",   label: "Started",   icon: "arrow.up.circle",       color: .blue)
                MetricCard(value: "\(metrics.requestsSucceeded)", label: "Succeeded", icon: "checkmark.circle.fill", color: .green)
                MetricCard(value: "\(metrics.requestsFailed)",    label: "Failed",    icon: "xmark.circle.fill",     color: .red)
                MetricCard(value: "\(metrics.retriesScheduled)",  label: "Retries",   icon: "arrow.clockwise",       color: .orange)
                MetricCard(value: "\(metrics.deduplicationsHit)", label: "Deduped",   icon: "equal.circle.fill",     color: .purple)
                MetricCard(
                    value: metrics.successRate.map { String(format: "%.0f%%", $0 * 100) } ?? "—",
                    label: "Success Rate",
                    icon: "percent",
                    color: .teal
                )
            }
            if let avg = metrics.averageSuccessDuration {
                HStack(spacing: 4) {
                    Image(systemName: "timer").font(.caption)
                    Text("Avg latency: \(String(format: "%.3f", avg))s").font(.caption)
                }
                .foregroundStyle(.secondary)
            }
        }
    }
}

struct MetricCard: View {
    let value: String
    let label: String
    let icon: String
    let color: Color

    var body: some View {
        GroupBox {
            VStack(spacing: 4) {
                Image(systemName: icon).font(.title3).foregroundStyle(color)
                Text(value).font(.title2.bold())
                Text(label).font(.caption2).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
        }
    }
}

// MARK: - Shared UI Components

struct DescriptionBox: View {
    let icon: String
    let title: String
    let detail: String

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 6) {
                Label(title, systemImage: icon).font(.headline)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding()
    }
}

struct ActionButton: View {
    let label: String
    let icon: String
    let tint: Color
    let disabled: Bool
    var fullWidth: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(label, systemImage: icon)
                .frame(maxWidth: fullWidth ? .infinity : nil)
        }
        .buttonStyle(.borderedProminent)
        .tint(tint)
        .disabled(disabled)
    }
}

struct EventLogView: View {
    @ObservedObject var log: EventLog

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Events")
                    .font(.caption.bold())
                    .foregroundStyle(.secondary)
                Spacer()
                if !log.entries.isEmpty {
                    Button("Clear") { log.clear() }.font(.caption)
                }
            }
            .padding(.horizontal)

            if log.entries.isEmpty {
                Text("No events yet — tap a button above.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding()
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(log.entries) { entry in
                            EventRow(entry: entry)
                        }
                    }
                    .padding(.horizontal)
                }
            }
        }
    }
}

struct EventRow: View {
    let entry: LogEntry

    var body: some View {
        HStack(alignment: .center, spacing: 6) {
            Image(systemName: entry.type.icon)
                .foregroundStyle(entry.type.color)
                .frame(width: 18)
            Text(entry.text)
                .font(.caption.monospaced())
        }
        .padding(.vertical, 1)
    }
}

// MARK: - Root ContentView

struct ContentView: View {
    var body: some View {
        TabView {
            NavigationStack {
                RetryDemoView()
                    .navigationTitle("Retry")
                    .navigationBarTitleDisplayMode(.inline)
            }
            .tabItem { Label("Retry", systemImage: "arrow.clockwise") }

            NavigationStack {
                DeduplicationDemoView()
                    .navigationTitle("Deduplication")
                    .navigationBarTitleDisplayMode(.inline)
            }
            .tabItem { Label("Dedup", systemImage: "equal.circle") }

            NavigationStack {
                OfflineQueueDemoView()
                    .navigationTitle("Offline Queue")
                    .navigationBarTitleDisplayMode(.inline)
            }
            .tabItem { Label("Queue", systemImage: "tray.and.arrow.down") }

            NavigationStack {
                MetricsDemoView()
                    .navigationTitle("Metrics")
                    .navigationBarTitleDisplayMode(.inline)
            }
            .tabItem { Label("Metrics", systemImage: "chart.bar") }
        }
    }
}

#Preview {
    ContentView()
}
