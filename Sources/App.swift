// IP体检 — VPN 出口 IP 纯净度检测
// 开发者：LengMo
// 功能：出口 IP / 国家 / 机房·家宽判定 / 原生·广播判定 / 纯净度评分 / 测速 / 流媒体与 AI 解锁检测 / 历史记录
// 全部调用免费免 Key 的公共 API，评分在本地计算，每条扣分都有大白话理由。

import SwiftUI
import Foundation
import UIKit

// MARK: - App 入口

@main
struct IPCheckerApp: App {
    var body: some Scene {
        WindowGroup {
            RootView()
        }
    }
}

struct RootView: View {
    @StateObject private var history = HistoryStore()
    var body: some View {
        TabView {
            CheckView()
                .tabItem { Label("体检", systemImage: "shield.lefthalf.filled") }
            SpeedView()
                .tabItem { Label("测速", systemImage: "speedometer") }
            UnlockView()
                .tabItem { Label("解锁", systemImage: "play.tv") }
            HistoryView()
                .tabItem { Label("记录", systemImage: "clock.arrow.circlepath") }
        }
        .environmentObject(history)
        .accentColor(.teal)
    }
}

// MARK: - 数据模型

enum IPKind: String {
    case residential = "家宽（住宅 IP）"
    case datacenter = "机房 IP"
    case vpn = "VPN / 代理出口"
    case business = "企业专线"
    case tor = "Tor 出口"
    case unknown = "未知类型"

    var isClean: Bool { self == .residential }
}

struct ScoreItem: Identifiable {
    let id = UUID()
    let reason: String
    let delta: Int // 负数扣分，0 表示中性提示
}

struct SourceStatus: Identifiable {
    let id = UUID()
    let name: String
    var ok: Bool?
}

struct IPReport {
    var ip: String = ""
    var ipVersion: String = ""
    var countryName: String = ""
    var countryCode: String = ""
    var region: String = ""
    var city: String = ""
    var flagEmoji: String = ""
    var isp: String = ""
    var org: String = ""
    var asn: String = ""
    var kind: IPKind = .unknown
    var kindNote: String = ""
    var isBroadcast: Bool? = nil // true=疑似广播 false=原生（各库一致） nil=数据不足
    var broadcastNote: String = ""
    var riskScore: Int? = nil // proxycheck 风险分 0-100
    var score: Int = 0
    var verdict: String = ""
    var items: [ScoreItem] = []
    var sources: [SourceStatus] = []
    var checkedAt: Date = Date()

    var countryCodesSeen: [String] = []
}

struct UnlockResult: Identifiable {
    let id = UUID()
    let name: String
    let icon: String
    var state: State = .pending
    var detail: String = ""
    enum State { case pending, checking, ok, no, unknown }
}

struct HistoryRecord: Codable, Identifiable {
    var id: UUID = UUID()
    var date: Date
    var ip: String
    var countryName: String
    var countryCode: String
    var flagEmoji: String
    var kindText: String
    var isBroadcast: Bool?
    var score: Int
    var verdict: String
    var reportText: String
}

// MARK: - 历史记录存储（本地 JSON 文件）

final class HistoryStore: ObservableObject {
    @Published var records: [HistoryRecord] = []
    private var fileURL: URL {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return dir.appendingPathComponent("ip_history.json")
    }
    init() { load() }
    func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let list = try? JSONDecoder().decode([HistoryRecord].self, from: data) else { return }
        records = list
    }
    func save() {
        guard let data = try? JSONEncoder().encode(records) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
    func add(_ r: HistoryRecord) {
        records.insert(r, at: 0)
        if records.count > 100 { records = Array(records.prefix(100)) }
        save()
    }
    func remove(at offsets: IndexSet) {
        records.remove(atOffsets: offsets)
        save()
    }
    func clear() {
        records.removeAll()
        save()
    }
}

// MARK: - JSON 小工具（各家 API 字段不一，用字典取值最稳）

func jStr(_ d: [String: Any], _ key: String) -> String? {
    if let s = d[key] as? String, !s.isEmpty { return s }
    return nil
}
func jBool(_ d: [String: Any], _ key: String) -> Bool? {
    if let b = d[key] as? Bool { return b }
    if let n = d[key] as? NSNumber { return n.boolValue }
    return nil
}
func jInt(_ d: [String: Any], _ key: String) -> Int? {
    if let n = d[key] as? NSNumber { return n.intValue }
    if let s = d[key] as? String { return Int(s) }
    return nil
}

// MARK: - 网络小工具

enum NetErr: Error { case badStatus(Int), empty }

let uaHeaders = ["User-Agent": "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1"]

func fetchData(_ urlStr: String, timeout: TimeInterval = 15) async throws -> Data {
    guard let url = URL(string: urlStr) else { throw NetErr.empty }
    var req = URLRequest(url: url, timeoutInterval: timeout)
    for (k, v) in uaHeaders { req.setValue(v, forHTTPHeaderField: k) }
    let (data, resp) = try await URLSession.shared.data(for: req)
    if let http = resp as? HTTPURLResponse, !(200..<400).contains(http.statusCode) {
        // 部分 API 用 4xx 返回业务信息（如 OpenAI 401 是好事），调用方需要原文时用 fetchRaw
        throw NetErr.badStatus(http.statusCode)
    }
    return data
}

/// 不抛状态码错误，返回 (data, statusCode, finalURL) —— 解锁检测专用
func fetchRaw(_ urlStr: String, timeout: TimeInterval = 20) async -> (Data, Int, URL?) {
    guard let url = URL(string: urlStr) else { return (Data(), 0, nil) }
    var req = URLRequest(url: url, timeoutInterval: timeout)
    for (k, v) in uaHeaders { req.setValue(v, forHTTPHeaderField: k) }
    do {
        let (data, resp) = try await URLSession.shared.data(for: req)
        let http = resp as? HTTPURLResponse
        return (data, http?.statusCode ?? 0, resp.url)
    } catch {
        return (Data(), -1, nil)
    }
}

func fetchJSON(_ urlStr: String, timeout: TimeInterval = 15) async -> [String: Any]? {
    guard let data = try? await fetchData(urlStr, timeout: timeout),
          let obj = try? JSONSerialization.jsonObject(with: data),
          let dict = obj as? [String: Any] else { return nil }
    return dict
}

// MARK: - 已知机房 / 云厂商关键词（组织名命中即判定机房）

let hostingKeywords: [String] = [
"amazon", "aws", "google", "microsoft", "azure", "ovh", "hetzner",
"digitalocean", "vultr", "choopa", "linode", "akamai", "leaseweb",
"m247", "datacamp", "contabo", "oracle", "alibaba", "aliyun", "tencent",
"huawei", "cloudflare", "gcore", "hostinger", "vps", "server", "hosting",
"data center", "datacenter", "colocation", "psychz", "quadranet",
"hostwinds", "buyvm", "frantech", "bandwagon", "racknerd", "cloudcone",
"zenlayer", "lightnode", "akkocloud", "misaka", "serverius", "worldstream"
]

func looksLikeHosting(_ texts: [String]) -> Bool {
let joined = texts.joined(separator: " ").lowercased()
return hostingKeywords.contains { joined.contains($0)}
}

// MARK: - 检测引擎

@MainActor
final class IPChecker: ObservableObject {
@Published var report: IPReport? = nil
@Published var isRunning = false
@Published var progressText = ""

func run() async {
guard !isRunning else { return}
isRunning = true
progressText = "正在查询出口 IP…"
defer { isRunning = false}

var rep = IPReport()
rep.sources = [
SourceStatus(name: "Cloudflare"),
SourceStatus(name: "ipwho.is"),
SourceStatus(name: "ip-api"),
SourceStatus(name: "proxycheck"),
SourceStatus(name: "ipapi.co"),
SourceStatus(name: "ip.sb"),
]
func setSrc(_ idx: Int, _ ok: Bool) {
if rep.sources.indices.contains(idx) { rep.sources[idx].ok = ok}
}

// 第一批：三个互不依赖的源并行（ipwho / Cloudflare trace / ip-api 都能直接给出当前出口）
async let ipwhoF = fetchJSON("https://ipwho.is/")
async let cfF = fetchData("https://www.cloudflare.com/cdn-cgi/trace", timeout: 12)
async let ipapiComF = fetchJSON("http://ip-api.com/json/?fields=status,country,countryCode,regionName,city,isp,org,as,asname,mobile,proxy,hosting,query")
let ipwho = await ipwhoF
let cfData = try? await cfF
let ipapiCom = await ipapiComF

// Cloudflare trace 解析
var cfIP: String? = nil
var cfLoc: String? = nil
if let cfData = cfData, let text = String(data: cfData, encoding:.utf8) {
for line in text.split(separator: "\n") {
let parts = line.split(separator: "=", maxSplits: 1)
if parts.count == 2 {
if parts[0] == "ip" { cfIP = String(parts[1])}
if parts[0] == "loc" { cfLoc = String(parts[1])}
}
}
setSrc(0, cfIP != nil)
} else { setSrc(0, false)}

// ipwho.is
var whoIP: String? = nil
if let w = ipwho, jBool(w, "success") != false, let ip = jStr(w, "ip") {
whoIP = ip
rep.countryName = jStr(w, "country") ?? rep.countryName
rep.countryCode = jStr(w, "country_code") ?? rep.countryCode
rep.region = jStr(w, "region") ?? rep.region
rep.city = jStr(w, "city") ?? rep.city
rep.ipVersion = jStr(w, "type") ?? ""
if let flag = w["flag"] as? [String: Any] { rep.flagEmoji = jStr(flag, "emoji") ?? ""}
if let conn = w["connection"] as? [String: Any] {
rep.isp = jStr(conn, "isp") ?? rep.isp
rep.org = jStr(conn, "org") ?? rep.org
if let asn = jInt(conn, "asn") { rep.asn = "AS\(asn)"}
}
setSrc(1, true)
} else { setSrc(1, false)}

// ip-api
var apiHosting = false, apiProxy = false, apiMobile = false
var apiIP: String? = nil
if let a = ipapiCom, jStr(a, "status") == "success" {
apiIP = jStr(a, "query")
if rep.countryName.isEmpty { rep.countryName = jStr(a, "country") ?? ""}
if rep.countryCode.isEmpty { rep.countryCode = jStr(a, "countryCode") ?? ""}
if rep.region.isEmpty { rep.region = jStr(a, "regionName") ?? ""}
if rep.city.isEmpty { rep.city = jStr(a, "city") ?? ""}
if rep.isp.isEmpty { rep.isp = jStr(a, "isp") ?? ""}
if rep.org.isEmpty { rep.org = jStr(a, "org") ?? ""}
if rep.asn.isEmpty { rep.asn = jStr(a, "as") ?? ""}
apiHosting = jBool(a, "hosting") ?? false
apiProxy = jBool(a, "proxy") ?? false
apiMobile = jBool(a, "mobile") ?? false
setSrc(2, true)
} else { setSrc(2, false)}

rep.ip = whoIP ?? cfIP ?? apiIP ?? ""
guard !rep.ip.isEmpty else {
rep.verdict = "查询失败"
rep.items = [ScoreItem(reason: "所有数据源都没响应 — 先确认手机能上网（或当前节点没挂掉），再点重新检测", delta: 0)]
self.report = rep
return
}
progressText = "已拿到出口 IP，正在查它的底细…"

// 第二批：拿着 IP 去查风险库 + 另外两个地理库（交叉验证广播 IP）
let ip = rep.ip
async let pcF = fetchJSON("https://proxycheck.io/v2/\(ip)?vpn=1&asn=1&risk=1")
async let coF = fetchJSON("https://ipapi.co/\(ip)/json/")
async let sbF = fetchJSON("https://api.ip.sb/geoip/\(ip)")
let pc = await pcF
let co = await coF
let sb = await sbF

var pcType: String? = nil
var pcProxy = false
if let pc = pc, jStr(pc, "status") == "ok", let entry = pc[ip] as? [String: Any] {
pcType = jStr(entry, "type")
pcProxy = (jStr(entry, "proxy") == "yes")
rep.riskScore = jInt(entry, "risk")
if rep.org.isEmpty { rep.org = jStr(entry, "organisation") ?? ""}
if rep.isp.isEmpty { rep.isp = jStr(entry, "provider") ?? ""}
if rep.asn.isEmpty, let asn = jStr(entry, "asn") { rep.asn = asn}
setSrc(3, true)
} else { setSrc(3, false)}

var coCode: String? = nil
if let co = co, jBool(co, "error") != true {
coCode = jStr(co, "country_code")
if rep.countryName.isEmpty { rep.countryName = jStr(co, "country_name") ?? ""}
if rep.org.isEmpty { rep.org = jStr(co, "org") ?? ""}
if rep.asn.isEmpty { rep.asn = jStr(co, "asn") ?? ""}
setSrc(4, coCode != nil)
} else { setSrc(4, false)}

var sbCode: String? = nil
if let sb = sb {
sbCode = jStr(sb, "country_code")
if rep.countryName.isEmpty { rep.countryName = jStr(sb, "country") ?? ""}
if rep.org.isEmpty { rep.org = jStr(sb, "organization") ?? jStr(sb, "isp") ?? ""}
setSrc(5, sbCode != nil)
} else { setSrc(5, false)}

// MARK: 广播 IP 判定 — 各家地理库给出的国家是否一致
var codes: [String] = []
if let c = cfLoc,!c.isEmpty { codes.append(c)}
if !rep.countryCode.isEmpty { codes.append(rep.countryCode)}
if let a = ipapiCom, let cc = jStr(a, "countryCode") { codes.append(cc)}
if let c = coCode { codes.append(c)}
if let c = sbCode { codes.append(c)}
rep.countryCodesSeen = codes
let distinct = Set(codes.map { $0.uppercased()})
if codes.count >= 2 {
if distinct.count >= 2 {
rep.isBroadcast = true
rep.broadcastNote = "有 \(codes.count) 个数据库参与定位，给出了 \(distinct.count) 个不同国家 — 这是广播 IP 的典型特征（IP 注册地和实际使用地不一致）"
} else {
rep.isBroadcast = false
rep.broadcastNote = "\(codes.count) 个数据库定位一致，都是 \(rep.countryCode) — 原生 IP 的可能性高"
}
} else {
rep.isBroadcast = nil
rep.broadcastNote = "定位数据不足，暂时判断不了原生 / 广播"
}

// MARK: IP 类型判定
var kind: IPKind = .unknown
var kindNote = ""
let typeLow = (pcType ?? "").lowercased()
if typeLow.contains("tor") {
kind = .tor; kindNote = "风险数据库明确标记为 Tor 出口节点"
} else if typeLow.contains("residential") || typeLow.contains("wireless") {
kind = .residential; kindNote = "风险数据库标记为住宅 / 家庭宽带类 IP"
} else if typeLow.contains("hosting") || typeLow.contains("datacenter") || typeLow.contains("data center") {
kind = .datacenter; kindNote = "风险数据库标记为机房 / 托管 IP"
} else if typeLow.contains("vpn") || typeLow.contains("proxy") {
kind = .vpn; kindNote = "风险数据库标记为 VPN / 代理出口"
} else if typeLow.contains("business") {
kind = .business; kindNote = "风险数据库标记为企业级线路"
} else if apiHosting {
kind = .datacenter; kindNote = "ip-api 标记 hosting=true（托管机房）"
} else if looksLikeHosting([rep.org, rep.isp, rep.asn]) {
kind = .datacenter; kindNote = "运营商 / 组织名命中已知云厂商与机房关键词"
} else if apiMobile {
kind = .residential; kindNote = "移动运营商出口（ip-api 标记 mobile=true），按家宽类看待"
} else if !rep.isp.isEmpty || !rep.org.isEmpty {
kind = .residential; kindNote = "运营商是普通 ISP 且无任何机房 / 代理标记，按家宽推测"
}
rep.kind = kind
rep.kindNote = kindNote

// MARK: 纯净度评分（本地计算，逐条列理由）
var items: [ScoreItem] = []
var score = 100
func deduct(_ reason: String, _ d: Int) {
items.append(ScoreItem(reason: reason, delta: -d)); score -= d
}
switch kind {
case.datacenter: deduct("落地是机房 IP — AI 和流媒体平台对机房段最警惕", 25)
case.vpn: deduct("被标记为 VPN / 代理出口 — 很多平台会直接拦这类 IP", 20)
case.tor: deduct("Tor 出口节点 — 几乎所有平台都会拦", 55)
case.business: deduct("企业专线 IP — 比家宽略差一点", 5)
case.residential: items.append(ScoreItem(reason: "家宽 / 住宅类 IP — 平台眼里最像正常用户", delta: 0))
case.unknown: deduct("类型没查清 — 按谨慎处理", 8)
}
if let risk = rep.riskScore, risk > 0 {
let d = Int((Double(risk) * 0.35).rounded())
if d > 0 { deduct("风险数据库给出 \(risk)/100 的风险分", d)}
}
if pcProxy && kind != .vpn && kind != .tor {
deduct("风险数据库确认这个 IP 被用作代理", 10)
}
if apiProxy && !pcProxy && kind != .vpn && kind != .tor {
deduct("ip-api 标记这个 IP 是代理出口", 10)
}
if rep.isBroadcast == true {
deduct("疑似广播 IP — 注册地与使用地不一致，部分平台会因此拦截或定位错乱", 8)
}
if kind == .residential, (rep.riskScore ?? 0) <= 15,!pcProxy,!apiProxy {
score = max(score, 92)
items.append(ScoreItem(reason: "家宽 + 低风险 + 无代理标记，保底按纯净档计", delta: 0))
}
score = max(3, min(100, score))
rep.score = score
rep.verdict = score >= 85 ? "纯净" : (score >= 70 ? "良好" : (score >= 50 ? "一般，有风险" : "风险高，不建议用"))
rep.items = items
rep.checkedAt = Date()
self.report = rep
}
}

// MARK: - 报告文本（复制 / 分享用）

func makeReportText(_ r: IPReport) -> String {
let f = DateFormatter()
f.dateFormat = "yyyy-MM-dd HH:mm"
var lines: [String] = []
lines.append("【IP 体检报告】\(f.string(from: r.checkedAt))")
lines.append("出口 IP：\(r.ip)\(r.ipVersion.isEmpty ? "" : "（\(r.ipVersion)）")")
lines.append("位置：\(r.flagEmoji) \(r.countryName) \(r.region) \(r.city)")
lines.append("运营商：\(r.isp.isEmpty ? "未知" : r.isp)")
lines.append("组织 / ASN：\(r.org.isEmpty ? "未知" : r.org) / \(r.asn.isEmpty ? "未知" : r.asn)")
lines.append("IP 类型：\(r.kind.rawValue)")
if let b = r.isBroadcast {
lines.append(b ? "原生 / 广播：疑似广播 IP" : "原生 / 广播：原生 IP（各库定位一致）")
}
if let risk = r.riskScore { lines.append("风险分：\(risk)/100（越低越好）")}
lines.append("纯净度：\(r.score) 分 — \(r.verdict)")
if !r.items.isEmpty {
lines.append("评分明细：")
for it in r.items {
lines.append(" · \(it.reason)\(it.delta < 0 ? "（\(it.delta)）" : "")")
}
}
lines.append("— 由「IP 体检」生成（开发者 LengMo）")
return lines.joined(separator: "\n")
}

// MARK: - 测速（延迟 / 抖动 / 下载 / 上传，都走当前网络出口）

final class SpeedTester: NSObject, ObservableObject, URLSessionDataDelegate {
    @Published var phase: String = ""
    @Published var isRunning = false
    @Published var pingMs: Double? = nil
    @Published var jitterMs: Double? = nil
    @Published var downMbps: Double? = nil
    @Published var upMbps: Double? = nil
    @Published var liveDownMbps: Double? = nil

    private var session: URLSession?
    private var dlSamples: [(Date, Int64)] = []
    private var dlStart: Date?
    private var dlContinuation: CheckedContinuation<Void, Never>?
    private var ulStart: Date?
    private var ulLastSent: Int64 = 0
    private var ulContinuation: CheckedContinuation<Void, Never>?

    func start() {
        guard !isRunning else { return }
        isRunning = true
        pingMs = nil; jitterMs = nil; downMbps = nil; upMbps = nil; liveDownMbps = nil
        Task { @MainActor in
            self.phase = "测延迟中…"
            await self.measurePing()
            self.phase = "测下载中…"
            await self.measureDownload()
            self.phase = "测上传中…"
            await self.measureUpload()
            self.phase = "测速完成"
            self.isRunning = false
        }
    }

    private func measurePing() async {
        var times: [Double] = []
        for _ in 0..<6 {
            let t0 = Date()
            let (_, status, _) = await fetchRaw("https://www.gstatic.com/generate_204", timeout: 8)
            if status == 204 || status == 200 {
                times.append(Date().timeIntervalSince(t0) * 1000)
            }
        }
        guard !times.isEmpty else { return }
        times.sort()
        let trimmed = times.count > 2 ? Array(times.dropLast()) : times // 去掉最慢的一次
        let avg = trimmed.reduce(0, +) / Double(trimmed.count)
        var jitter = 0.0
        if trimmed.count > 1 {
            var diffs: [Double] = []
            for i in 1..<trimmed.count { diffs.append(abs(trimmed[i] - trimmed[i - 1])) }
            jitter = diffs.reduce(0, +) / Double(diffs.count)
        }
        await MainActor.run { self.pingMs = avg; self.jitterMs = jitter }
    }

    private func measureDownload() async {
        dlSamples = []
        dlStart = Date()
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 30
        cfg.timeoutIntervalForResource = 30
        let s = URLSession(configuration: cfg, delegate: self, delegateQueue: nil)
        session = s
        guard let url = URL(string: "https://speed.cloudflare.com/__down?bytes=50000000") else { return }
        var req = URLRequest(url: url)
        req.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")
        let task = s.dataTask(with: req)
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            dlContinuation = cont
            task.resume()
            DispatchQueue.global().asyncAfter(deadline: .now() + 10) { [weak self] in
                self?.finishDownload(task: task)
            }
        }
        s.finishTasksAndInvalidate()
        // 计算：掐掉第 1 秒的爬坡段，用之后的数据算平均速率
        let samples = dlSamples
        guard let first = samples.first, let last = samples.last else { return }
        let warm = samples.first(where: { $0.0.timeIntervalSince(first.0) >= 1.0 })
        let base = warm ?? first
        let dt = last.0.timeIntervalSince(base.0)
        let bytes = last.1 - base.1
        if dt > 0.3 && bytes > 0 {
            let mbps = Double(bytes) * 8 / dt / 1_000_000
            await MainActor.run { self.downMbps = mbps }
        }
    }

    private func finishDownload(task: URLSessionDataTask) {
        task.cancel()
        if let c = dlContinuation { dlContinuation = nil; c.resume() }
    }

    private func measureUpload() async {
        ulStart = Date()
        ulLastSent = 0
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 30
        cfg.timeoutIntervalForResource = 30
        let s = URLSession(configuration: cfg, delegate: self, delegateQueue: nil)
        session = s
        guard let url = URL(string: "https://speed.cloudflare.com/__up") else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.httpBody = Data(count: 4_000_000)
        req.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        let task = s.dataTask(with: req)
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            ulContinuation = cont
            task.resume()
            DispatchQueue.global().asyncAfter(deadline: .now() + 20) { [weak self] in
                task.cancel()
                if let c = self?.ulContinuation { self?.ulContinuation = nil; c.resume() }
            }
        }
        s.finishTasksAndInvalidate()
        if let start = ulStart, ulLastSent > 0 {
            let dt = Date().timeIntervalSince(start)
            if dt > 0.2 {
                let mbps = Double(ulLastSent) * 8 / dt / 1_000_000
                await MainActor.run { self.upMbps = mbps }
            }
        }
    }

    // URLSessionDataDelegate
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard dataTask.currentRequest?.url?.absoluteString.contains("__down") == true else { return }
        let now = Date()
        let total = (dlSamples.last?.1 ?? 0) + Int64(data.count)
        dlSamples.append((now, total))
        if let start = dlStart, now.timeIntervalSince(start) >= 1.0,
           let base = dlSamples.first(where: { $0.0.timeIntervalSince(start) >= 1.0 }) {
            let dt = now.timeIntervalSince(base.0)
            if dt > 0.3 {
                let mbps = Double(total - base.1) * 8 / dt / 1_000_000
                DispatchQueue.main.async { self.liveDownMbps = mbps }
            }
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64, totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
        ulLastSent = totalBytesSent
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if task.currentRequest?.url?.absoluteString.contains("__down") == true {
            if let c = dlContinuation { dlContinuation = nil; c.resume() }
        } else {
            if let c = ulContinuation { ulContinuation = nil; c.resume() }
        }
    }
}

// MARK: - 流媒体 / AI 解锁检测（公开接口探测，结果仅供参考）

@MainActor
final class UnlockChecker: ObservableObject {
    @Published var results: [UnlockResult] = [
        UnlockResult(name: "ChatGPT", icon: "bubble.left.and.bubble.right"),
        UnlockResult(name: "Claude", icon: "sparkles"),
        UnlockResult(name: "Gemini", icon: "star"),
        UnlockResult(name: "Netflix", icon: "play.rectangle"),
        UnlockResult(name: "YouTube Premium", icon: "play.square"),
        UnlockResult(name: "Disney+", icon: "tv"),
    ]
    @Published var isRunning = false

    private func set(_ idx: Int, _ state: UnlockResult.State, _ detail: String) {
        guard results.indices.contains(idx) else { return }
        results[idx].state = state
        results[idx].detail = detail
    }

    private func bodyText(_ data: Data, limit: Int = 400_000) -> String {
        String(data: data.prefix(limit), encoding: .utf8) ?? ""
    }

    func run() async {
        guard !isRunning else { return }
        isRunning = true
        for i in results.indices { results[i].state = .checking; results[i].detail = "检测中…" }
        defer { isRunning = false }

        await withTaskGroup(of: Void.self) { group in
            group.addTask { await self.checkChatGPT() }
            group.addTask { await self.checkClaude() }
            group.addTask { await self.checkGemini() }
            group.addTask { await self.checkNetflix() }
            group.addTask { await self.checkYouTube() }
            group.addTask { await self.checkDisney() }
        }
    }

    private func checkChatGPT() async {
        // 先拿 ChatGPT 域名下的 trace 看落地国家，再探 API：401=可达未受限，403=地区不支持或风控
        var loc = ""
        let (traceData, traceStatus, _) = await fetchRaw("https://chatgpt.com/cdn-cgi/trace", timeout: 15)
        if traceStatus == 200, let text = String(data: traceData, encoding: .utf8) {
            for line in text.split(separator: "\n") where line.hasPrefix("loc=") {
                loc = String(line.dropFirst(4))
            }
        }
        let (data, status, _) = await fetchRaw("https://api.openai.com/v1/models", timeout: 15)
        let body = bodyText(data).lowercased()
        if status == 401 {
            set(0, .ok, "可达，地区未受限\(loc.isEmpty ? "" : "（落地 \(loc)）")")
        } else if status == 403 && (body.contains("not supported") || body.contains("unsupported") || body.contains("territory")) {
            set(0, .no, "所在地区不受 OpenAI 支持\(loc.isEmpty ? "" : "（落地 \(loc)）")")
        } else if status == 403 {
            set(0, .unknown, "被风控拦截（403）— IP 可能被 OpenAI 拉黑")
        } else if status == -1 || status == 0 {
            set(0, .unknown, "连不上 OpenAI")
        } else {
            set(0, .unknown, "返回状态 \(status)，无法判定")
        }
    }

    private func checkClaude() async {
        let (data, status, _) = await fetchRaw("https://claude.ai/", timeout: 15)
        let body = bodyText(data).lowercased()
        if status == 200 {
            set(1, .ok, "网页可达")
        } else if status == 403 && body.contains("unavailable") {
            set(1, .no, "所在地区不可用")
        } else if status == 403 {
            set(1, .unknown, "返回 403（可能风控或地区限制）")
        } else if status == -1 || status == 0 {
            set(1, .unknown, "连不上 claude.ai")
        } else {
            set(1, .unknown, "返回状态 \(status)，无法判定")
        }
    }

    private func checkGemini() async {
        let (data, status, _) = await fetchRaw("https://gemini.google.com/app", timeout: 15)
        let body = bodyText(data).lowercased()
        if body.contains("isn't available") || body.contains("not available in your country") || body.contains("is not available in your country") {
            set(2, .no, "所在地区不可用")
        } else if status == 200 {
            set(2, .ok, "网页可达（地区已开放）")
        } else if status == -1 || status == 0 {
            set(2, .unknown, "连不上 Gemini")
        } else {
            set(2, .unknown, "返回状态 \(status)，无法判定")
        }
    }

    private func checkNetflix() async {
        // 用一部 Netflix 自制内容探：200=该地区有服务，404=无服务地区，403=被封
        let (_, status, _) = await fetchRaw("https://www.netflix.com/title/81280792", timeout: 15)
        switch status {
        case 200: set(3, .ok, "已解锁（该地区有 Netflix 服务）")
        case 404: set(3, .no, "未解锁（该地区无服务或仅限自制剧）")
        case 403: set(3, .no, "被 Netflix 封锁（403）")
        case -1, 0: set(3, .unknown, "连不上 Netflix")
        default: set(3, .unknown, "返回状态 \(status)，无法判定")
        }
    }

    private func checkYouTube() async {
        let (data, status, _) = await fetchRaw("https://www.youtube.com/premium", timeout: 20)
        let body = bodyText(data)
        if body.contains("not available in your country") || body.contains("isn't available in your country") {
            set(4, .no, "Premium 未在此地区提供")
        } else if status == 200 && body.lowercased().contains("premium") {
            set(4, .ok, "Premium 在此地区提供")
        } else if status == -1 || status == 0 {
            set(4, .unknown, "连不上 YouTube")
        } else {
            set(4, .unknown, "无法判定（状态 \(status)）")
        }
    }

    private func checkDisney() async {
        let (data, status, finalURL) = await fetchRaw("https://www.disneyplus.com/", timeout: 15)
        let body = bodyText(data).lowercased()
        if body.contains("not available in your region") || body.contains("not available in your country") {
            set(5, .no, "所在地区不可用")
            return
        }
        if status == 200 {
            // 正常落地会跳到带地区代码的路径，如 /en-us、/ja-jp
            if let path = finalURL?.path, path.count >= 6 {
                let seg = String(path.dropFirst().prefix(5))
                if seg.count == 5 && seg[seg.index(seg.startIndex, offsetBy: 2)] == "-" {
                    set(5, .ok, "已解锁（地区 \(seg.uppercased())）")
                    return
                }
            }
            set(5, .ok, "网页可达")
        } else if status == -1 || status == 0 {
            set(5, .unknown, "连不上 Disney+")
        } else {
            set(5, .unknown, "返回状态 \(status)，无法判定")
        }
    }
}

// MARK: - 通用小组件

func scoreColor(_ s: Int) -> Color {
    if s >= 85 { return .green }
    if s >= 70 { return .mint }
    if s >= 50 { return .orange }
    return .red
}

struct ShareSheet: UIViewControllerRepresentable {
    let text: String
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [text], applicationActivities: nil)
    }
    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}

struct InfoRow: View {
    let label: String
    let value: String
    var body: some View {
        HStack(alignment: .top) {
            Text(label).foregroundColor(.secondary).frame(width: 92, alignment: .leading)
            Text(value.isEmpty ? "—" : value).font(.system(.body, design: .monospaced)).textSelection(.enabled)
            Spacer()
        }
        .font(.subheadline)
        .padding(.vertical, 3)
    }
}

// MARK: - 体检页

struct CheckView: View {
    @StateObject private var checker = IPChecker()
    @EnvironmentObject var history: HistoryStore
    @State private var didAutoRun = false
    @State private var shareItem: IdentifiableString? = nil
    @State private var copied = false

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(spacing: 16) {
                    gaugeCard
                    if let r = checker.report {
                        infoCard(r)
                        if !r.items.isEmpty { reasonsCard(r) }
                        sourcesCard(r)
                    } else if !checker.isRunning {
                        Text("点下面的按钮，查一下你现在的出口 IP 干不干净。\n开着小火箭等 VPN 时，测到的就是节点的出口；没开就是你家宽带的出口。")
                            .font(.subheadline).foregroundColor(.secondary)
                            .multilineTextAlignment(.center).padding(.horizontal)
                    }
                    actionButtons
                    Text("数据来自 Cloudflare、ipwho.is、ip-api、proxycheck、ipapi.co、ip.sb 等免费公开接口，评分在本机计算。")
                        .font(.caption2).foregroundColor(.secondary)
                        .multilineTextAlignment(.center).padding(.horizontal)
                }
                .padding()
            }
            .navigationTitle("IP 体检")
            .task {
                if !didAutoRun {
                    didAutoRun = true
                    await runAndSave()
                }
            }
        }
        .navigationViewStyle(.stack)
    }

    private var gaugeCard: some View {
        VStack(spacing: 8) {
            ZStack {
                Circle().stroke(Color.gray.opacity(0.2), lineWidth: 14)
                Circle()
                    .trim(from: 0, to: CGFloat(checker.report?.score ?? 0) / 100)
                    .stroke(scoreColor(checker.report?.score ?? 0), style: StrokeStyle(lineWidth: 14, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.easeOut(duration: 0.6), value: checker.report?.score)
                VStack(spacing: 2) {
                    if checker.isRunning {
                        ProgressView()
                        Text(checker.progressText).font(.caption).foregroundColor(.secondary)
                    } else if let r = checker.report {
                        Text("\(r.score)").font(.system(size: 52, weight: .bold, design: .rounded))
                        Text(r.verdict).font(.headline).foregroundColor(scoreColor(r.score))
                    } else {
                        Text("—").font(.system(size: 52, weight: .bold, design: .rounded)).foregroundColor(.secondary)
                        Text("还没检测").font(.headline).foregroundColor(.secondary)
                    }
                }
            }
            .frame(width: 170, height: 170)
            if let r = checker.report, !r.ip.isEmpty {
                Text("\(r.flagEmoji) \(r.countryName) · \(r.ip)")
                    .font(.system(.subheadline, design: .monospaced))
            }
        }
        .padding(.top, 8)
    }

    private func infoCard(_ r: IPReport) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("出口信息").font(.headline).padding(.bottom, 4)
            InfoRow(label: "出口 IP", value: r.ip + (r.ipVersion.isEmpty ? "" : "（\(r.ipVersion)）"))
            InfoRow(label: "国家 / 地区", value: "\(r.flagEmoji) \(r.countryName)（\(r.countryCode)）")
            InfoRow(label: "省 / 市", value: "\(r.region) \(r.city)")
            InfoRow(label: "运营商", value: r.isp)
            InfoRow(label: "组织", value: r.org)
            InfoRow(label: "ASN", value: r.asn)
            Divider().padding(.vertical, 4)
            HStack {
                Text("IP 类型").foregroundColor(.secondary).frame(width: 92, alignment: .leading)
                Text(r.kind.rawValue)
                    .font(.subheadline).bold()
                    .foregroundColor(r.kind == .datacenter || r.kind == .tor ? .red : (r.kind == .residential ? .green : .orange))
                Spacer()
            }
            if !r.kindNote.isEmpty {
                Text(r.kindNote).font(.caption).foregroundColor(.secondary).padding(.leading, 92)
            }
            HStack {
                Text("原生 / 广播").foregroundColor(.secondary).frame(width: 92, alignment: .leading)
                Text(r.isBroadcast == nil ? "判断不了" : (r.isBroadcast! ? "疑似广播 IP" : "原生 IP"))
                    .font(.subheadline).bold()
                    .foregroundColor(r.isBroadcast == true ? .orange : (r.isBroadcast == false ? .green : .secondary))
                Spacer()
            }
            .padding(.top, 2)
            if !r.broadcastNote.isEmpty {
                Text(r.broadcastNote).font(.caption).foregroundColor(.secondary).padding(.leading, 92)
            }
            if let risk = r.riskScore {
                InfoRow(label: "风险分", value: "\(risk) / 100（越低越好）")
            }
        }
        .padding()
        .background(Color(.secondarySystemBackground))
        .cornerRadius(14)
    }

    private func reasonsCard(_ r: IPReport) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("评分明细").font(.headline).padding(.bottom, 2)
            ForEach(r.items) { item in
                HStack(alignment: .top) {
                    Text(item.delta < 0 ? "\(item.delta)" : "±0")
                        .font(.system(.subheadline, design: .monospaced)).bold()
                        .foregroundColor(item.delta < 0 ? .red : .green)
                        .frame(width: 38, alignment: .leading)
                    Text(item.reason).font(.subheadline)
                    Spacer()
                }
            }
        }
        .padding()
        .background(Color(.secondarySystemBackground))
        .cornerRadius(14)
    }

    private func sourcesCard(_ r: IPReport) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("数据源状态").font(.headline).padding(.bottom, 2)
            ForEach(r.sources) { s in
                HStack {
                    Circle()
                        .fill(s.ok == nil ? Color.gray : (s.ok! ? Color.green : Color.red))
                        .frame(width: 9, height: 9)
                    Text(s.name).font(.subheadline)
                    Spacer()
                    Text(s.ok == nil ? "未返回" : (s.ok! ? "正常" : "失败")).font(.caption).foregroundColor(.secondary)
                }
            }
            Text("某个源失败不影响结论，其余源会顶上；失败越多，判断越保守。")
                .font(.caption2).foregroundColor(.secondary)
        }
        .padding()
        .background(Color(.secondarySystemBackground))
        .cornerRadius(14)
    }

    private var actionButtons: some View {
        VStack(spacing: 10) {
            Button {
                Task { await runAndSave() }
            } label: {
                Text(checker.isRunning ? "检测中…" : (checker.report == nil ? "开始体检" : "重新检测"))
                    .font(.headline).frame(maxWidth: .infinity).padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent)
            .disabled(checker.isRunning)

            if let r = checker.report, !r.ip.isEmpty {
                HStack(spacing: 10) {
                    Button {
                        UIPasteboard.general.string = makeReportText(r)
                        copied = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { copied = false }
                    } label: {
                        Label(copied ? "已复制" : "复制报告", systemImage: copied ? "checkmark" : "doc.on.doc")
                            .frame(maxWidth: .infinity).padding(.vertical, 4)
                    }
                    .buttonStyle(.bordered)
                    Button {
                        shareItem = IdentifiableString(value: makeReportText(r))
                    } label: {
                        Label("分享报告", systemImage: "square.and.arrow.up")
                            .frame(maxWidth: .infinity).padding(.vertical, 4)
                    }
                    .buttonStyle(.bordered)
                }
            }
        }
        .sheet(item: $shareItem) { item in
            ShareSheet(text: item.value)
        }
    }

    private func runAndSave() async {
        await checker.run()
        if let r = checker.report, !r.ip.isEmpty {
            history.add(HistoryRecord(
                date: r.checkedAt, ip: r.ip, countryName: r.countryName,
                countryCode: r.countryCode, flagEmoji: r.flagEmoji,
                kindText: r.kind.rawValue, isBroadcast: r.isBroadcast,
                score: r.score, verdict: r.verdict, reportText: makeReportText(r)
            ))
        }
    }
}

struct IdentifiableString: Identifiable {
    let id = UUID()
    let value: String
}

// MARK: - 测速页

struct SpeedView: View {
    @StateObject private var tester = SpeedTester()
    var body: some View {
        NavigationView {
            VStack(spacing: 22) {
                Spacer()
                HStack(spacing: 14) {
                    metricCard(title: "下载", value: tester.downMbps ?? tester.liveDownMbps, unit: "Mbps", color: .teal)
                    metricCard(title: "上传", value: tester.upMbps, unit: "Mbps", color: .indigo)
                }
                HStack(spacing: 14) {
                    metricCard(title: "延迟", value: tester.pingMs, unit: "ms", color: .orange)
                    metricCard(title: "抖动", value: tester.jitterMs, unit: "ms", color: .pink)
                }
                if tester.isRunning {
                    ProgressView(tester.phase)
                } else if !tester.phase.isEmpty {
                    Text(tester.phase).font(.subheadline).foregroundColor(.secondary)
                }
                Button {
                    tester.start()
                } label: {
                    Text(tester.isRunning ? "测速中…" : "开始测速")
                        .font(.headline).frame(maxWidth: .infinity).padding(.vertical, 6)
                }
                .buttonStyle(.borderedProminent)
                .disabled(tester.isRunning)
                Text("测速走你当前的网络出口：开着 VPN 测到的就是节点的速度。测速端点是 Cloudflare 官方的，一次最多消耗约 54MB 流量。")
                    .font(.caption).foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                Spacer()
            }
            .padding()
            .navigationTitle("测速")
        }
        .navigationViewStyle(.stack)
    }

    private func metricCard(title: String, value: Double?, unit: String, color: Color) -> some View {
        VStack(spacing: 4) {
            Text(title).font(.subheadline).foregroundColor(.secondary)
            if let v = value {
                Text(String(format: "%.1f", v)).font(.system(size: 30, weight: .bold, design: .rounded)).foregroundColor(color)
            } else {
                Text("—").font(.system(size: 30, weight: .bold, design: .rounded)).foregroundColor(.secondary)
            }
            Text(unit).font(.caption2).foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 14)
        .background(Color(.secondarySystemBackground))
        .cornerRadius(14)
    }
}

// MARK: - 解锁页

struct UnlockView: View {
    @StateObject private var unlocker = UnlockChecker()
    var body: some View {
        NavigationView {
            List {
                Section {
                    ForEach(unlocker.results) { r in
                        HStack(spacing: 12) {
                            Image(systemName: r.icon).foregroundColor(.teal).frame(width: 26)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(r.name).font(.body)
                                Text(r.detail.isEmpty ? "还没检测" : r.detail)
                                    .font(.caption).foregroundColor(.secondary)
                            }
                            Spacer()
                            stateBadge(r.state)
                        }
                        .padding(.vertical, 3)
                    }
                } footer: {
                    Text("开着 VPN 点开始检测，逐个探这些服务在当前出口能不能用、落在哪个地区。方法是公开接口探测，各家风控天天变，结果仅供参考。")
                }
                Section {
                    Button {
                        Task { await unlocker.run() }
                    } label: {
                        HStack {
                            Spacer()
                            Text(unlocker.isRunning ? "检测中…" : "开始检测").bold()
                            Spacer()
                        }
                    }
                    .disabled(unlocker.isRunning)
                }
            }
            .navigationTitle("解锁检测")
        }
        .navigationViewStyle(.stack)
    }

    @ViewBuilder
    private func stateBadge(_ s: UnlockResult.State) -> some View {
        switch s {
        case .pending: Text("待检测").font(.caption).foregroundColor(.secondary)
        case .checking: ProgressView()
        case .ok: Label("可用", systemImage: "checkmark.circle.fill").font(.caption).foregroundColor(.green)
        case .no: Label("不可用", systemImage: "xmark.circle.fill").font(.caption).foregroundColor(.red)
        case .unknown: Label("说不准", systemImage: "questionmark.circle.fill").font(.caption).foregroundColor(.orange)
        }
    }
}

// MARK: - 记录页

struct HistoryView: View {
    @EnvironmentObject var history: HistoryStore
    @State private var selected: HistoryRecord? = nil
    private let dateFmt: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MM-dd HH:mm"
        return f
    }()

    var body: some View {
        NavigationView {
            Group {
                if history.records.isEmpty {
                    VStack(spacing: 10) {
                        Image(systemName: "clock.arrow.circlepath").font(.largeTitle).foregroundColor(.secondary)
                        Text("还没有检测记录\n去体检页测一次，这里会自动存下来，方便你对比不同节点。")
                            .font(.subheadline).foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .padding()
                } else {
                    List {
                        ForEach(history.records) { r in
                            Button { selected = r } label: {
                                HStack(spacing: 10) {
                                    Text(r.flagEmoji.isEmpty ? "🌐" : r.flagEmoji).font(.title3)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text("\(r.countryName) · \(r.ip)").font(.system(.subheadline, design: .monospaced)).foregroundColor(.primary)
                                        Text("\(r.kindText) · \(dateFmt.string(from: r.date))")
                                            .font(.caption).foregroundColor(.secondary)
                                    }
                                    Spacer()
                                    Text("\(r.score)")
                                        .font(.headline).bold()
                                        .foregroundColor(scoreColor(r.score))
                                }
                            }
                        }
                        .onDelete { history.remove(at: $0) }
                    }
                }
            }
            .navigationTitle("历史记录")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("清空", role: .destructive) { history.clear() }
                        .disabled(history.records.isEmpty)
                }
            }
            .sheet(item: $selected) { r in
                NavigationView {
                    ScrollView {
                        Text(r.reportText)
                            .font(.system(.footnote, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding()
                    }
                    .navigationTitle("检测报告")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .navigationBarTrailing) {
                            Button("关闭") { selected = nil }
                        }
                        ToolbarItem(placement: .navigationBarLeading) {
                            Button {
                                UIPasteboard.general.string = r.reportText
                            } label: { Label("复制", systemImage: "doc.on.doc") }
                        }
                    }
                }
            }
        }
        .navigationViewStyle(.stack)
    }
}
