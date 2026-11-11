/*
 * IslandBoard (DynamicIsland)
 * Copyright (C) 2024-2026 Atoll Contributors
 *
 * Swift bridge to the Rust usage core (see atoll-core/). File scanning, streaming
 * JSONL parsing, dedup and week/today/session bucketing run in Rust; pricing stays
 * here because the rate table lives in ModelPricingManager (remote + bundled), and
 * cost is linear in tokens so it can be applied to per-model aggregates without
 * changing results.
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 */

import Foundation

enum UsageCore {
    struct CoreError: Error, LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    private struct ModelTotals: Decodable {
        let model: String
        let input: Int
        let output: Int
        let cacheRead: Int
        let cacheWrite: Int
        /// Prompt tokens billed at the full prompt rate.
        var uncachedInput: Int { max(0, input - cacheRead - cacheWrite) }
    }

    private struct CoreSnapshot: Decodable {
        let week: [ModelTotals]
        let today: [ModelTotals]
        let session: [ModelTotals]
    }

    /// Mirrors the former `JSONLUsageParser.aggregate(files:now:)` window semantics:
    /// 7-day week, 5-hour session, and the current local day.
    static func aggregate(files: [URL], now: Date) throws -> UsageSnapshot {
        var snapshot = UsageSnapshot()
        guard !files.isEmpty else {
            snapshot.lastUpdated = now
            return snapshot
        }

        let weekStart = now.addingTimeInterval(-7 * 86400)
        let sessionStart = now.addingTimeInterval(-5 * 3600)
        let cal = Calendar.current
        let todayStart = cal.startOfDay(for: now)
        let todayEnd = cal.date(byAdding: .day, value: 1, to: todayStart)
            ?? todayStart.addingTimeInterval(86400)

        var joined = Data()
        for file in files {
            joined.append(contentsOf: file.path.utf8)
            joined.append(0)
        }

        guard let raw = joined.withUnsafeBytes({ buffer in
            atoll_aggregate_usage(buffer.baseAddress!.assumingMemoryBound(to: CChar.self),
                                  buffer.count,
                                  weekStart.timeIntervalSince1970,
                                  sessionStart.timeIntervalSince1970,
                                  todayStart.timeIntervalSince1970,
                                  todayEnd.timeIntervalSince1970)
        }) else {
            throw CoreError(message: "IslandBoard usage core failed")
        }
        defer { atoll_free_string(raw) }

        let payload = String(cString: raw).data(using: .utf8) ?? Data()
        guard let core = try? JSONDecoder().decode(CoreSnapshot.self, from: payload) else {
            throw CoreError(message: "IslandBoard usage core returned an invalid payload")
        }

        snapshot.week = totals(for: core.week)
        snapshot.today = totals(for: core.today)
        snapshot.session = totals(for: core.session)
        snapshot.models = core.week
            .map { model in ModelUsage(model: model.model, totals: single(model), pool: nil) }
            .sorted { $0.totals.costUSD > $1.totals.costUSD }
        snapshot.lastUpdated = now
        return snapshot
    }

    private static func cost(_ m: ModelTotals) -> Double? {
        ModelPricing.cost(model: m.model, inputTokens: m.uncachedInput, outputTokens: m.output,
                          cacheReadTokens: m.cacheRead, cacheWriteTokens: m.cacheWrite)
    }

    private static func single(_ m: ModelTotals) -> UsageTotals {
        var t = UsageTotals(inputTokens: m.input, outputTokens: m.output)
        if let c = cost(m) { t.costUSD = c } else { t.hasUnpricedModel = true }
        return t
    }

    private static func totals(for models: [ModelTotals]) -> UsageTotals {
        var t = UsageTotals()
        for m in models {
            t.inputTokens += m.input
            t.outputTokens += m.output
            if let c = cost(m) { t.costUSD += c } else { t.hasUnpricedModel = true }
        }
        return t
    }
}
