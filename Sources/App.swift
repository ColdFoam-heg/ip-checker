// IP体检 — VPN 出口 IP 纯净度检测
// 开发者：LengMo
// v1.1：主题挑选 / 渐变 UI / 设置页 / DNS 泄漏与 IPv6 双栈检测 / 解锁扩至 11 项 / 历史对比导出
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
@StateObject private var theme = ThemeStore()
@StateObject private var settings = SettingsStore()
var body: some View {
TabView {
CheckView()
.tabItem { Label("体检", systemImage: "shield.lefthalf.filled")}
SpeedView()
.tabItem { Label("测速", systemImage: "speedometer")}
UnlockView()
.tabItem { Label("解锁", systemImage: "play.tv")}
HistoryView()
.tabItem { Label("记录", systemImage: "clock.arrow.circlepath")}
SettingsView()
.tabItem { Label("设置", systemImage: "gearshape")}
}
.environmentObject(history)
.environmentObject(theme)
.environmentObject(settings)
.accentColor(theme.current.accent)
}
}

// MARK: - 主题

struct AppTheme: Identifiable {
let id: String
let name: String
let colors: [Color]
let accent: Color
var gradient: LinearGradient {
LinearGradient(colors: colors, startPoint:.topLeading, endPoint:.bottomTrailing)
}
var angular: AngularGradient {
AngularGradient(colors: colors + [colors.first??.teal], center:.center)
}
}

let allThemes: [AppTheme] = [
AppTheme(id: "ocean", name: "海洋青", colors: [Color.teal, Color.blue], accent:.teal),
AppTheme(id: "grape", name: "葡萄紫", colors: [Color.purple, Color.pink], accent:.purple),
AppTheme(id: "peach", name: "蜜桃橙", colors: [Color.orange, Color.pink], accent:.orange),
AppTheme(id: "forest", name: "森林绿", colors: [Color.green, Color.teal], accent:.green),
AppTheme(id: "night", name: "星空夜", colors: [Color.indigo, Color(red: 0.08, green: 0.08, blue: 0.25)], accent:.indigo),
]

final class ThemeStore: ObservableObject {
@Published var themeID: String {
didSet { UserDefaults.standard.set(themeID, forKey: "themeID")}
}
init() {
themeID = UserDefaults.standard.string(forKey: "themeID") ?? "ocean"
}
var current: AppTheme {
allThemes.first(where: { $0.id == themeID}) ?? allThemes[0]
}
}

// MARK: - 设置

final class SettingsStore: ObservableObject {
@Published var autoCheck: Bool {
didSet { UserDefaults.standard.set(autoCheck, forKey: "autoCheck")}
}
@Published var saveHistory: Bool {
didSet { UserDefaults.standard.set(saveHistory, forKey: "saveHistory")}
}
init() {
let d = UserDefaults.standard
autoCheck = d.object(forKey: "autoCheck") as? Bool ?? true
saveHistory = d.object(forKey: "saveHistory") as? Bool ?? true
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
}

struct ScoreItem: Identifiable {
let id = UUID()
let reason: String
let delta: Int
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
var isBroadcast: Bool? = nil
var broadcastNote: String = ""
var riskScore: Int? = nil
var score: Int = 0
var verdict: String = ""
var items: [ScoreItem] = []
var sources: [SourceStatus] = []
var checkedAt: Date = Date()
var countryCodesSeen: [String] = []
}

struct UnlockResult: Identifiable {
let id: String
let name: String
let icon: String
let section: String
var state: State = .pending
var detail: String = ""
enum State { case pending, checking, ok, no, unknown}
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
let dir = FileManager.default.urls(for:.documentDirectory, in:.userDomainMask)[0]
return dir.appendingPathComponent("ip_history.json")
}
init() { load()}
func load() {
guard let data = try? Data(contentsOf: fileURL),
let list = try? JSONDecoder().decode([HistoryRecord].self, from: data) else { return}
records = list
}
func save() {
guard let data = try? JSONEncoder().encode(records) else { return}
try? data.write(to: fileURL, options:.atomic)
}
func add(_ r: HistoryRecord) {
records.insert(r, at: 0)
if records.count > 100 { records = Array(records.prefix(100))}
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
func exportText() -> String {
let f = DateFormatter()
f.dateFormat = "MM-dd HH:mm"
var lines: [String] = ["共 \(records.count) 条（按时间倒序）"]
for r in records {
let bc = r.isBroadcast == nil ? "原生/广播未知" : (r.isBroadcast! ? "疑似广播" : "原生")
lines.append("\(f.string(from: r.date)) | \(r.flagEmoji) \(r.countryName) | \(r.ip) | \(r.kindText) | \(r.score) 分（\(r.verdict)）| \(bc)")
}
if let best = records.max(by: { $0.score < $1.score}) {
lines.append("最佳节点：\(best.flagEmoji) \(best.countryName) \(best.ip) — \(best.score) 分")
}
lines.append("— 由「IP 体检」导出（开发者 LengMo）")
return lines.joined(separator: "\n")
}
}

// MARK: - JSON 小工具

func jStr(_ d: [String: Any], _ key: String) -> String? {
if let s = d[key] as? String,!s.isEmpty { return s}
return nil
}
func jBool(_ d: [String: Any], _ key: String) -> Bool? {
if let b = d[key] as? Bool { return b}
if let n = d[key] as? NSNumber { return n.boolValue}
return nil
}
func jInt(_ d: [String: Any], _ key: String) -> Int? {
if let n = d[key] as? NSNumber { return n.intValue}
if let s = d[key] as? String { return Int(s)}
return nil
}

// MARK: - 网络小工具

enum NetErr: Error { case badStatus(Int), empty}

let uaHeaders = ["User-Agent": "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1"]

func fetchData(_ urlStr: String, timeout: TimeInterval = 15) async throws -> Data {
guard let url = URL(string: urlStr) else { throw NetErr.empty}
var req = URLRequest(url: url, timeoutInterval: timeout)
for (k, v) in uaHeaders { req.setValue(v, forHTTPHeaderField: k)}
let (data, resp) = try await URLSession.shared.data(for: req)
if let http = resp as? HTTPURLResponse,!(200..<400).contains(http.statusCode) {
throw NetErr.badStatus(http.statusCode)
}
return data
}

/// 不抛状态码错误，返回 (data, statusCode, finalURL) —— 解锁检测专用
func fetchRaw(_ urlStr: String, timeout: TimeInterval = 20) async -> (Data, Int, URL?) {
guard let url = URL(string: urlStr) else { return (Data(), 0, nil)}
var req = URLRequest(url: url, timeoutInterval: timeout)
for (k, v) in uaHeaders { req.setValue(v, forHTTPHeaderField: k)}
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
let dict = obj as? [String: Any] else { return nil}
return dict
}

func randomToken(_ n: Int) -> String {
let chars = "abcdefghijklmnopqrstuvwxyz0123456789"
return String((0..<n).map { _ in chars.randomElement() ?? "a"})
}

// MARK: - 体检检测引擎

let hostingKeywords = ["amazon", "aws", "google cloud", "google llc", "microsoft", "azure", "digitalocean", "linode", "vultr", "ovh", "hetzner", "alibaba", "tencent", "oracle", "choopa", "m247", "datacamp", "akamai", "cloudflare", "leaseweb", "contabo", "hostinger", "bandwidth", "cogent", "gcore", "upcloud", "kamatera", "hostwinds", "psychz", "quadranet", "colocrossing", "server", "hosting", "data center", "datacenter", "vps", "cloud "]
let residentialKeywords = ["china telecom", "china unicom", "china mobile", "chinanet", "comcast", "at&t", "verizon", "spectrum", "charter", "cox ", "bt broadband", "virgin media", "orange", "free sas", "vodafone", "telefonica", "deutsche telekom", "kddi", "softbank", "ntt", "korea telecom", "kt corporation", "sk broadband", "lg uplus", "taiwan fixed", "hinet", "hong kong telecommunications", "hkt", "singtel", "starhub", "time dotcom", "sprint", "t-mobile", "residential", "broadband", "cable", "fiber", "fibre", "dsl", "isp"]

final class IPChecker: ObservableObject {
@Published var checking = false
@Published var done = false
@Published var report: IPReport? = nil
@Published var errorText: String? = nil

func run() async {
if checking { return}
checking = true
errorText = nil
done = false
defer { checking = false}

var rep = IPReport()
rep.sources = [
SourceStatus(name: "Cloudflare Trace", ok: nil),
SourceStatus(name: "ipwho.is", ok: nil),
SourceStatus(name: "ip-api", ok: nil),
SourceStatus(name: "proxycheck.io", ok: nil),
SourceStatus(name: "ipapi.co", ok: nil),
SourceStatus(name: "ip.sb", ok: nil),
]
func setSrc(_ i: Int, _ ok: Bool) {
if rep.sources.indices.contains(i) { rep.sources[i].ok = ok}
}

// Cloudflare Trace：出口 IP 与国家
var cfCountry = ""
if let data = try? await fetchData("https://www.cloudflare.com/cdn-cgi/trace"),
let text = String(data: data, encoding:.utf8) {
setSrc(0, true)
for line in text.split(separator: "\n") {
let parts = line.split(separator: "=", maxSplits: 1)
if parts.count == 2 {
if parts[0] == "ip" { rep.ip = String(parts[1])}
if parts[0] == "loc" { cfCountry = String(parts[1])}
}
}
if !cfCountry.isEmpty { rep.countryCodesSeen.append(cfCountry)}
} else {
setSrc(0, false)
}

// ipwho.is：定位 + ISP + connection.type
var whoType = ""
if let d = await fetchJSON("https://ipwho.is/") {
setSrc(1, true)
if rep.ip.isEmpty, let ip = jStr(d, "ip") { rep.ip = ip}
if let c = jStr(d, "country") { rep.countryName = c}
if let cc = jStr(d, "country_code") {
rep.countryCode = cc
if !rep.countryCodesSeen.contains(cc) { rep.countryCodesSeen.append(cc)}
}
if let r = jStr(d, "region") { rep.region = r}
if let c = jStr(d, "city") { rep.city = c}
if let flag = d["flag"] as? [String: Any], let e = jStr(flag, "emoji") { rep.flagEmoji = e}
if let conn = d["connection"] as? [String: Any] {
if let isp = jStr(conn, "isp") { rep.isp = isp}
if let org = jStr(conn, "org") { rep.org = org}
if let asn = conn["asn"] as? NSNumber { rep.asn = "AS\(asn.intValue)"}
if let t = jStr(conn, "type") { whoType = t}
}
} else {
setSrc(1, false)
}

// ip-api：hosting / proxy / mobile 标记
var apiHosting: Bool? = nil
var apiProxy: Bool? = nil
var apiMobile: Bool? = nil
if let d = await fetchJSON("http://ip-api.com/json/?fields=status,country,countryCode,regionName,city,isp,org,as,hosting,proxy,mobile,query") {
setSrc(2, true)
if let ip = jStr(d, "query"), rep.ip.isEmpty { rep.ip = ip}
if rep.countryName.isEmpty, let c = jStr(d, "country") { rep.countryName = c}
if let cc = jStr(d, "countryCode") {
if rep.countryCode.isEmpty { rep.countryCode = cc}
if !rep.countryCodesSeen.contains(cc) { rep.countryCodesSeen.append(cc)}
}
if rep.isp.isEmpty, let s = jStr(d, "isp") { rep.isp = s}
if rep.org.isEmpty, let o = jStr(d, "org") { rep.org = o}
if rep.asn.isEmpty, let a = jStr(d, "as") { rep.asn = a}
apiHosting = jBool(d, "hosting")
apiProxy = jBool(d, "proxy")
apiMobile = jBool(d, "mobile")
} else {
setSrc(2, false)
}

// proxycheck.io：类型与风险分
var pcType = ""
var pcProxy = ""
var pcRisk: Int? = nil
let pcTarget = rep.ip.isEmpty ? "me" : rep.ip
if let d = await fetchJSON("https://proxycheck.io/v2/\(pcTarget)?vpn=1&asn=1&risk=1"),
let inner = d[pcTarget] as? [String: Any] {
setSrc(3, true)
if let t = jStr(inner, "type") { pcType = t}
if let p = jStr(inner, "proxy") { pcProxy = p}
pcRisk = jInt(inner, "risk")
if rep.countryCode.isEmpty, let cc = jStr(inner, "isocode") {
rep.countryCode = cc
if !rep.countryCodesSeen.contains(cc) { rep.countryCodesSeen.append(cc)}
}
if rep.asn.isEmpty, let a = jStr(inner, "asn") { rep.asn = a}
if rep.isp.isEmpty, let p = jStr(inner, "provider") { rep.isp = p}
if let cur = d["currency"] as? [String: Any] { _ = cur}
} else {
setSrc(3, false)
}

// ipapi.co：组织补充 + 国家交叉验证
if let d = await fetchJSON("https://ipapi.co/json/") {
setSrc(4, true)
if rep.ip.isEmpty, let ip = jStr(d, "ip") { rep.ip = ip}
if let cc = jStr(d, "country_code"),
!rep.countryCodesSeen.contains(cc) {
rep.countryCodesSeen.append(cc)
}
if rep.countryName.isEmpty, let c = jStr(d, "country_name") { rep.countryName = c}
if rep.isp.isEmpty, let o = jStr(d, "org") { rep.isp = o}
if rep.asn.isEmpty, let a = jStr(d, "asn") { rep.asn = a}
} else {
setSrc(4, false)
}

// ip.sb：出口 IP 兜底
if let d = await fetchJSON("https://api.ip.sb/geoip") {
setSrc(5, true)
if rep.ip.isEmpty, let ip = jStr(d, "ip") { rep.ip = ip}
if let cc = jStr(d, "country_code"),
!rep.countryCodesSeen.contains(cc) {
rep.countryCodesSeen.append(cc)
}
if rep.countryName.isEmpty, let c = jStr(d, "country") { rep.countryName = c}
if rep.isp.isEmpty, let s = jStr(d, "isp") { rep.isp = s}
if rep.asn.isEmpty, let a = d["asn"] as? NSNumber { rep.asn = "AS\(a.intValue)"}
if rep.asn.isEmpty, let a = jStr(d, "asn") { rep.asn = a}
} else {
setSrc(5, false)
}

if rep.ip.isEmpty {
errorText = "没能问到出口 IP，请检查网络后重试"
report = rep
return
}

if cfCountry.isEmpty == false, rep.countryCodesSeen.contains(cfCountry) == false {
rep.countryCodesSeen.append(cfCountry)
}

rep.ipVersion = rep.ip.contains(":") ? "IPv6" : "IPv4"

// MARK: 类型判定
let ispBlob = (rep.isp + " " + rep.org).lowercased()
let hostingHit = hostingKeywords.contains { ispBlob.contains($0)}
let resHit = residentialKeywords.contains { ispBlob.contains($0)}
let pcIsVPN = pcType.lowercased().contains("vpn")
let pcIsTor = ispBlob.contains("tor") || pcType.lowercased().contains("tor")
let whoIsCorp = whoType.lowercased() == "corporate"
let whoIsISP = whoType.lowercased() == "isp"

if pcIsTor {
rep.kind = .tor
rep.kindNote = "风险数据库或运营商信息显示这是 Tor 出口节点"
} else if pcIsVPN || apiProxy == true {
rep.kind = .vpn
rep.kindNote = "风险数据库已把这个 IP 收录为 VPN / 代理出口，多数平台的风控库里也有它"
} else if apiHosting == true || hostingHit {
rep.kind = .datacenter
rep.kindNote = "出口落在云厂商 / 机房网段（\(rep.isp.isEmpty ? "运营商未知" : rep.isp)），不是家庭宽带"
} else if apiMobile == true {
rep.kind = .residential
rep.kindNote = "移动网络出口（手机流量网段），可信度通常不错"
} else if whoIsISP || (resHit &&!hostingHit) {
rep.kind = .residential
rep.kindNote = "运营商信息像正经家庭宽带，这是最干净的一类出口"
} else if whoIsCorp {
rep.kind = .business
rep.kindNote = "企业网段出口，不算家宽，但比机房干净"
} else {
rep.kind = .unknown
rep.kindNote = "几个数据库都没给出明确类型标记"
}

// MARK: 广播 IP 判定（多库定位国家不一致）
let distinctCountries = Set(rep.countryCodesSeen)
if distinctCountries.count >= 2 {
rep.isBroadcast = true
rep.broadcastNote = "多个数据库给出的定位国家不一致（\(rep.countryCodesSeen.joined(separator: "、"))），这个 IP 的注册地和实际出口地对不上，属于疑似广播 / Anycast IP"
} else if rep.countryCodesSeen.count == 1 {
rep.isBroadcast = false
rep.broadcastNote = "各个数据库定位一致（\(rep.countryName.isEmpty? rep.countryCode: rep.countryName)），是当地原生 IP"
} else {
rep.isBroadcast = nil
rep.broadcastNote = "没有足够数据判断原生 / 广播"
}

// MARK: 评分
var score = 100
var items: [ScoreItem] = []
func deduct(_ reason: String, _ d: Int) {
if d > 0 {
score -= d
items.append(ScoreItem(reason: reason, delta: -d))
}
}
switch rep.kind {
case.tor:
deduct("Tor 出口节点 — 几乎所有平台都会严查", 55)
case.vpn:
deduct("被标记为 VPN / 代理出口 — 很多平台会直接拦这类 IP", 20)
case.datacenter:
deduct("机房 IP（云服务器网段）— 容易被风控系统盯上", 25)
case.business:
deduct("企业专线 IP — 不算家宽", 8)
case.residential,.unknown:
break
}
if let risk = pcRisk {
rep.riskScore = risk
if risk > 0 {
let dd = Int((Double(risk) * 0.35).rounded())
deduct("风险数据库给出 \(risk)/100 的风险分", dd)
}
}
if rep.isBroadcast == true {
deduct("疑似广播 IP — 注册地和实际位置对不上", 8)
}
if rep.kind == .residential, pcRisk == nil || (pcRisk ?? 0) <= 30 {
if score > 92 { score = 92}
items.append(ScoreItem(reason: "家宽 + 低风险，干净出口保底分", delta: 0))
}
rep.score = max(0, min(100, score))
rep.items = items
switch rep.score {
case 85...100: rep.verdict = "纯净，放心用"
case 70...84: rep.verdict = "良好，日常使用没问题"
case 50...69: rep.verdict = "一般，有风险"
default: rep.verdict = "风险高，重要账号慎用"
}

rep.checkedAt = Date()
report = rep
done = true
}
}

// MARK: - 报告文本

func makeReportText(_ r: IPReport) -> String {
let f = DateFormatter()
f.dateFormat = "yyyy-MM-dd HH:mm"
var lines: [String] = []
lines.append("\(f.string(from: r.checkedAt))")
lines.append("出口 IP：\(r.ip)（\(r.ipVersion)）")
let loc = "\(r.flagEmoji) \(r.countryName) \(r.region) \(r.city)".trimmingCharacters(in:.whitespaces)
lines.append("位置：\(loc)")
lines.append("运营商：\(r.isp)")
lines.append("组织 / ASN：\(r.org) / \(r.asn)")
lines.append("IP 类型：\(r.kind.rawValue)")
let bc = r.isBroadcast == nil ? "未知" : (r.isBroadcast! ? "疑似广播 IP" : "原生 IP")
lines.append("原生 / 广播：\(bc)（各库定位\(r.isBroadcast == false ? "一致" : "不一致")）")
if let risk = r.riskScore {
lines.append("风险分：\(risk)/100（越低越好）")
}
lines.append("纯净度：\(r.score) 分 — \(r.verdict)")
lines.append("评分明细：")
if r.items.isEmpty {
lines.append(" · 无扣分项")
} else {
for it in r.items {
if it.delta < 0 {
lines.append(" · \(it.reason)（\(it.delta)）")
} else {
lines.append(" · \(it.reason)")
}
}
}
lines.append("— 由「IP 体检」生成（开发者 LengMo）")
return lines.joined(separator: "\n")
}

// MARK: - 泄漏检测（DNS + IPv6 双栈）

final class LeakChecker: ObservableObject {
    @Published var running = false
    @Published var dnsDone = false
    @Published var dnsResolverIP: String = ""
    @Published var dnsGeo: String = ""
    @Published var dnsVerdict: String = ""
    @Published var dnsOK: Bool? = nil
    @Published var v4IP: String = ""
    @Published var v6IP: String = ""
    @Published var v6Geo: String = ""
    @Published var v6Verdict: String = ""
    @Published var v6Leak: Bool? = nil

    /// exitCountryName: 当前体检出口国家名（英文），用来比对 DNS 解析地是否一致
    func run(exitCountryName: String, exitIP: String) async {
        if running { return }
        running = true
        defer { running = false }
        await checkDNS(exitCountryName: exitCountryName)
        await checkIPv6(exitIP: exitIP, exitCountryName: exitCountryName)
    }

    private func checkDNS(exitCountryName: String) async {
        // 原理：访问一个随机子域名，强制系统走当前 DNS 解析；ip-api 的 edns 服务会回显实际解析服务器的 IP 与归属
        let token = randomToken(14)
        let d = await fetchJSON("https://\(token).edns.ip-api.com/json", timeout: 12)
        guard let root = d, let dns = root["dns"] as? [String: Any] else {
            dnsVerdict = "DNS 检测没成功（接口没回应），稍后可以再试"
            dnsOK = nil
            dnsDone = true
            return
        }
        dnsResolverIP = jStr(dns, "ip") ?? ""
        dnsGeo = jStr(dns, "geo") ?? ""
        // dns.geo 格式一般是「国家名 - 运营商」
        let dnsCountry = dnsGeo.split(separator: "-").first.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
        if exitCountryName.isEmpty {
            dnsVerdict = "已查到 DNS 解析地（先做一次体检，我再帮你比对是否泄漏）"
            dnsOK = nil
        } else if !dnsCountry.isEmpty && dnsCountry.lowercased() == exitCountryName.lowercased() {
            dnsVerdict = "DNS 解析地和出口 IP 在同一个国家（\(exitCountryName)），没有发现 DNS 泄漏"
            dnsOK = true
        } else if !dnsCountry.isEmpty {
            dnsVerdict = "DNS 在「\(dnsCountry)」解析、出口 IP 却在「\(exitCountryName)」——DNS 泄漏了，网站能看出你的真实地区"
            dnsOK = false
        } else {
            dnsVerdict = "查到了 DNS 解析服务器，但归属地信息不全，没法下结论"
            dnsOK = nil
        }
        dnsDone = true
    }

    private func checkIPv6(exitIP: String, exitCountryName: String) async {
        if let d = await fetchJSON("https://api4.ipify.org?format=json", timeout: 10), let ip = jStr(d, "ip") {
            v4IP = ip
        }
        let d6 = await fetchJSON("https://api6.ipify.org?format=json", timeout: 10)
        guard let ip6 = d6.flatMap({ jStr($0, "ip") }) else {
            v6IP = ""
            v6Verdict = "没有 IPv6 出口（可能节点或网络不支持 IPv6），不存在 IPv6 泄漏问题"
            v6Leak = false
            return
        }
        v6IP = ip6
        var geo6 = ""
        if let g = await fetchJSON("https://ipwho.is/\(ip6)", timeout: 10) {
            let ctry = jStr(g, "country") ?? ""
            var isp = ""
            if let conn = g["connection"] as? [String: Any] { isp = jStr(conn, "isp") ?? "" }
            v6Geo = [ctry, isp].filter { !$0.isEmpty }.joined(separator: " · ")
            geo6 = ctry
        }
        if !exitIP.isEmpty && exitIP.contains(":") {
            v6Verdict = "当前出口本身就是 IPv6，与体检结果一致"
            v6Leak = false
        } else if !geo6.isEmpty && !exitCountryName.isEmpty && geo6.lowercased() != exitCountryName.lowercased() {
            v6Verdict = "有 IPv6 出口且落在「\(geo6)」，和 IPv4 出口的「\(exitCountryName)」不是一个地方——很可能 IPv6 绕过了代理在直连，真实位置会暴露"
            v6Leak = true
        } else if !geo6.isEmpty {
            v6Verdict = "有 IPv6 出口，位置与 IPv4 出口一致，没发现绕行"
            v6Leak = false
        } else {
            v6Verdict = "有 IPv6 出口，但没查到它的归属地，暂时下不了结论"
            v6Leak = nil
        }
    }

    var summaryLines: [String] {
        var out: [String] = []
        if dnsDone {
            out.append("DNS 解析：\(dnsResolverIP.isEmpty ? "未知" : dnsResolverIP)（\(dnsGeo.isEmpty ? "归属未知" : dnsGeo)）— \(dnsVerdict)")
        }
        if !v6Verdict.isEmpty {
            out.append("IPv6 出口：\(v6IP.isEmpty ? "无" : v6IP) — \(v6Verdict)")
        }
        return out
    }
}

// MARK: - 测速（Cloudflare 官方测速端点）

final class SpeedTester: ObservableObject {
    @Published var running = false
    @Published var phase = ""
    @Published var pingMs: Double? = nil
    @Published var jitterMs: Double? = nil
    @Published var downMbps: Double? = nil
    @Published var upMbps: Double? = nil
    @Published var downBytesText = ""
    @Published var upBytesText = ""

    private let base = "https://speed.cloudflare.com"

    func run() async {
        if running { return }
        running = true
        phase = "准备中"
        pingMs = nil
        jitterMs = nil
        downMbps = nil
        upMbps = nil
        defer { running = false; phase = "" }

        // 延迟 + 抖动：10 次小请求
        phase = "测延迟"
        var samples: [Double] = []
        for _ in 0..<10 {
            let t0 = Date()
            if let _ = try? await fetchData("\(base)/__down?bytes=0", timeout: 10) {
                samples.append(Date().timeIntervalSince(t0) * 1000)
            }
        }
        if !samples.isEmpty {
            pingMs = samples.min()
            if samples.count > 1, let mn = samples.min() {
                let diffs = samples.map { abs($0 - mn) }
                jitterMs = diffs.reduce(0, +) / Double(diffs.count)
            }
        }

        // 下载：逐级加大
        phase = "测下载"
        var totalMB = 0.0
        for (size, reps) in [(1_000_000, 2), (5_000_000, 2), (10_000_000, 1)] {
            for _ in 0..<reps {
                let t0 = Date()
                if let data = try? await fetchData("\(base)/__down?bytes=\(size)", timeout: 30) {
                    let dt = Date().timeIntervalSince(t0)
                    if dt > 0.05 {
                        let mbps = Double(data.count) * 8 / dt / 1_000_000
                        totalMB += Double(data.count) / 1_000_000
                        if downMbps == nil || mbps > downMbps! { downMbps = mbps }
                    }
                }
            }
            downBytesText = String(format: "已下载 %.0f MB", totalMB)
        }

        // 上传
        phase = "测上传"
        var upMB = 0.0
        for size in [100_000, 500_000, 1_000_000, 1_000_000] {
            let payload = Data(count: size)
            guard let url = URL(string: "\(base)/__up") else { continue }
            var req = URLRequest(url: url, timeoutInterval: 30)
            req.httpMethod = "POST"
            req.httpBody = payload
            let t0 = Date()
            if let _ = try? await URLSession.shared.data(for: req) {
                let dt = Date().timeIntervalSince(t0)
                if dt > 0.05 {
                    let mbps = Double(size) * 8 / dt / 1_000_000
                    upMB += Double(size) / 1_000_000
                    if upMbps == nil || mbps > upMbps! { upMbps = mbps }
                }
            }
            upBytesText = String(format: "已上传 %.1f MB", upMB)
        }
    }
}

// MARK: - 解锁检测

final class UnlockChecker: ObservableObject {
    @Published var running = false
    @Published var results: [UnlockResult] = [
        UnlockResult(id: "chatgpt", name: "ChatGPT", icon: "bubble.left.and.bubble.right", section: "AI 服务"),
        UnlockResult(id: "claude", name: "Claude", icon: "sparkles", section: "AI 服务"),
        UnlockResult(id: "gemini", name: "Gemini", icon: "diamond", section: "AI 服务"),
        UnlockResult(id: "netflix", name: "Netflix", icon: "play.rectangle", section: "流媒体"),
        UnlockResult(id: "youtube", name: "YouTube Premium", icon: "play.rectangle.on.rectangle", section: "流媒体"),
        UnlockResult(id: "disney", name: "Disney+", icon: "tv", section: "流媒体"),
        UnlockResult(id: "spotify", name: "Spotify", icon: "music.note", section: "流媒体"),
        UnlockResult(id: "tiktok", name: "TikTok", icon: "music.note.list", section: "社交"),
        UnlockResult(id: "instagram", name: "Instagram", icon: "camera", section: "社交"),
        UnlockResult(id: "facebook", name: "Facebook", icon: "person.2", section: "社交"),
        UnlockResult(id: "x", name: "X（Twitter）", icon: "at", section: "社交"),
    ]

    private func set(_ key: String, _ state: UnlockResult.State, _ detail: String) {
        if let i = results.firstIndex(where: { $0.id == key }) {
            results[i].state = state
            results[i].detail = detail
        }
    }

    func runAll() async {
        if running { return }
        running = true
        for i in results.indices { results[i].state = .checking; results[i].detail = "检测中…" }
        defer { running = false }
        await checkChatGPT()
        await checkClaude()
        await checkGemini()
        await checkNetflix()
        await checkYouTube()
        await checkDisney()
        await checkSpotify()
        await checkTikTok()
        await checkInstagram()
        await checkFacebook()
        await checkX()
    }

    private func bodyText(_ data: Data) -> String {
        String(data: data, encoding: .utf8) ?? ""
    }

    private func checkChatGPT() async {
        let (_, code, _) = await fetchRaw("https://chatgpt.com/cdn-cgi/trace")
        if code == 403 {
            set("chatgpt", .no, "被地区封锁（403）")
            return
        }
        let (data, code2, _) = await fetchRaw("https://ios.chat.openai.com/")
        _ = data
        if code2 == 200 {
            set("chatgpt", .ok, "App 接口可达")
        } else if code == 200 {
            set("chatgpt", .ok, "网页可达（trace 正常）")
        } else if code2 == -1 && code == -1 {
            set("chatgpt", .unknown, "连接失败，无法判定")
        } else {
            set("chatgpt", .unknown, "响应异常（HTTP \(code2)）")
        }
    }

    private func checkClaude() async {
        let (_, code, _) = await fetchRaw("https://claude.ai/favicon.ico")
        switch code {
        case 200, 301, 302, 307, 308:
            set("claude", .ok, "站点可达")
        case 403:
            set("claude", .no, "返回 403 — 该地区不在服务范围或被风控")
        case -1:
            set("claude", .unknown, "连接失败，无法判定")
        default:
            set("claude", .unknown, "响应异常（HTTP \(code)）")
        }
    }

    private func checkGemini() async {
        let (data, code, _) = await fetchRaw("https://gemini.google.com/app")
        let body = bodyText(data)
        if code == -1 {
            set("gemini", .unknown, "连接失败，无法判定")
        } else if body.contains("45631641") {
            set("gemini", .no, "页面带地区限制标记 — 该地区不可用")
        } else if code == 200 {
            set("gemini", .ok, "页面可正常打开")
        } else {
            set("gemini", .unknown, "响应异常（HTTP \(code)）")
        }
    }

    private func checkNetflix() async {
        let (data, code, _) = await fetchRaw("https://www.netflix.com/title/81280792")
        let body = bodyText(data)
        if code == 200, !body.contains("Oh no!"), !body.contains("not available") {
            set("netflix", .ok, "可打开自制剧页面（完整解锁）")
            return
        }
        let (_, code2, _) = await fetchRaw("https://www.netflix.com/title/70143836")
        if code2 == 200 {
            set("netflix", .no, "只能看部分内容（半解锁）")
        } else if code == -1 && code2 == -1 {
            set("netflix", .unknown, "连接失败，无法判定")
        } else {
            set("netflix", .no, "自制剧不可用 — 未解锁")
        }
    }

    private func checkYouTube() async {
        let (data, code, _) = await fetchRaw("https://www.youtube.com/premium")
        let body = bodyText(data).lowercased()
        if code == -1 {
            set("youtube", .unknown, "连接失败，无法判定")
        } else if body.contains("premium is not available") || body.contains("not available in your country") {
            set("youtube", .no, "该地区不支持 Premium")
        } else if body.contains("premium") {
            set("youtube", .ok, "Premium 页面可达")
        } else {
            set("youtube", .unknown, "页面内容无法判定")
        }
    }

    private func checkDisney() async {
        let (_, code, _) = await fetchRaw("https://www.disneyplus.com/")
        switch code {
        case 200, 301, 302:
            set("disney", .ok, "站点可达")
        case 403:
            set("disney", .no, "返回 403 — 该地区未开通")
        case -1:
            set("disney", .unknown, "连接失败，无法判定")
        default:
            set("disney", .unknown, "响应异常（HTTP \(code)）")
        }
    }

    private func checkSpotify() async {
        let (_, code, _) = await fetchRaw("https://open.spotify.com/")
        switch code {
        case 200, 301, 302:
            set("spotify", .ok, "网页播放器可达")
        case -1:
            set("spotify", .unknown, "连接失败，无法判定")
        default:
            set("spotify", .unknown, "响应异常（HTTP \(code)）")
        }
    }

    private func checkTikTok() async {
        let (data, code, _) = await fetchRaw("https://www.tiktok.com/")
        let body = bodyText(data).lowercased()
        if code == -1 {
            set("tiktok", .unknown, "连不上（该地区可能封锁了 TikTok）")
        } else if body.contains("not available") || body.contains("isn’t available") || body.contains("is not available") {
            set("tiktok", .no, "页面显示地区不可用")
        } else if code == 200 {
            set("tiktok", .ok, "网页可达")
        } else {
            set("tiktok", .unknown, "响应异常（HTTP \(code)）")
        }
    }

    private func checkInstagram() async {
        let (_, code, _) = await fetchRaw("https://www.instagram.com/")
        switch code {
        case 200:
            set("instagram", .ok, "网页可达")
        case 403:
            set("instagram", .unknown, "被风控拦截（403），无法判定地区可用性")
        case -1:
            set("instagram", .unknown, "连不上（该地区可能封锁）")
        default:
            set("instagram", .unknown, "响应异常（HTTP \(code)）")
        }
    }

    private func checkFacebook() async {
        let (_, code, _) = await fetchRaw("https://www.facebook.com/")
        switch code {
        case 200:
            set("facebook", .ok, "网页可达")
        case 403:
            set("facebook", .unknown, "被风控拦截（403），无法判定地区可用性")
        case -1:
            set("facebook", .unknown, "连不上（该地区可能封锁）")
        default:
            set("facebook", .unknown, "响应异常（HTTP \(code)）")
        }
    }

    private func checkX() async {
        let (_, code, _) = await fetchRaw("https://x.com/")
        switch code {
        case 200:
            set("x", .ok, "网页可达")
        case -1:
            set("x", .unknown, "连不上（该地区可能封锁）")
        default:
            set("x", .unknown, "响应异常（HTTP \(code)）")
        }
    }
}

// MARK: - 通用组件

struct Card<Content: View>: View {
    @ViewBuilder var content: () -> Content
    var body: some View {
        VStack(alignment: .leading, spacing: 10) { content() }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(.secondarySystemBackground))
            .clipShape(RoundedRectangle(cornerRadius: 16))
    }
}

struct InfoRow: View {
    let label: String
    let value: String
    var body: some View {
        HStack(alignment: .top) {
            Text(label).foregroundColor(.secondary).frame(width: 76, alignment: .leading)
            Text(value.isEmpty ? "—" : value).textSelection(.enabled)
            Spacer(minLength: 0)
        }
        .font(.subheadline)
    }
}

struct ActivityView: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}

// MARK: - 体检页

struct CheckView: View {
    @StateObject private var checker = IPChecker()
    @StateObject private var leak = LeakChecker()
    @EnvironmentObject var history: HistoryStore
    @EnvironmentObject var theme: ThemeStore
    @EnvironmentObject var settings: SettingsStore
    @State private var showShare = false
    @State private var copied = false

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(spacing: 16) {
                    headerCard
                    actionRow
                    if let err = checker.errorText {
                        Text(err).foregroundColor(.red).font(.subheadline)
                    }
                    if let rep = checker.report, checker.done {
                        infoCard(rep)
                        leakCard
                        if !rep.items.isEmpty { scoreCard(rep) }
                        sourcesCard(rep)
                    } else {
                        leakCard
                        Card {
                            Text("体检会挨个询问 6 个免费情报源，交叉验证你的出口 IP：是谁家的、干不干净、有没有被标记成 VPN / 机房 / 广播 IP，最后给一个大白话评分。")
                                .font(.subheadline).foregroundColor(.secondary)
                        }
                    }
                }
                .padding(16)
            }
            .navigationTitle("IP 体检")
            .task {
                if settings.autoCheck && !checker.done && !checker.checking {
                    await runAndSave()
                }
            }
            .sheet(isPresented: $showShare) {
                if let rep = checker.report {
                    ActivityView(items: [composeText(rep)])
                }
            }
        }
        .navigationViewStyle(.stack)
    }

    // 渐变头卡：分数环 + 结论
    private var headerCard: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 20).fill(theme.current.gradient)
            if checker.checking {
                VStack(spacing: 10) {
                    ProgressView().tint(.white).scaleEffect(1.3)
                    Text("正在挨个询问各大数据库…").foregroundColor(.white).font(.subheadline)
                }
                .padding(.vertical, 34)
            } else if let rep = checker.report, checker.done {
                HStack(spacing: 18) {
                    gaugeRing(score: rep.score)
                    VStack(alignment: .leading, spacing: 6) {
                        Text(rep.verdict).font(.title3).bold().foregroundColor(.white)
                        Text("\(rep.flagEmoji) \(rep.countryName) · \(rep.ip)")
                            .font(.caption).foregroundColor(.white.opacity(0.9))
                            .lineLimit(2)
                        Text(rep.kind.rawValue).font(.caption).foregroundColor(.white.opacity(0.8))
                    }
                    Spacer(minLength: 0)
                }
                .padding(18)
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "shield.lefthalf.filled").font(.system(size: 40)).foregroundColor(.white)
                    Text("看看你的出口 IP 干不干净").foregroundColor(.white).font(.headline)
                    Text("机房还是家宽 · 原生还是广播 · 一测便知").font(.caption).foregroundColor(.white.opacity(0.85))
                }
                .padding(.vertical, 30)
            }
        }
    }

    private func gaugeRing(score: Int) -> some View {
        ZStack {
            Circle().stroke(Color.white.opacity(0.3), lineWidth: 11)
            Circle()
                .trim(from: 0, to: CGFloat(max(0, min(100, score))) / 100)
                .stroke(Color.white, style: StrokeStyle(lineWidth: 11, lineCap: .round))
                .rotationEffect(.degrees(-90))
            VStack(spacing: 0) {
                Text("\(score)").font(.system(size: 36, weight: .bold)).foregroundColor(.white)
                Text("纯净度").font(.caption2).foregroundColor(.white.opacity(0.85))
            }
        }
        .frame(width: 108, height: 108)
    }

    private var actionRow: some View {
        VStack(spacing: 10) {
            Button {
                Task { await runAndSave() }
            } label: {
                HStack {
                    if checker.checking { ProgressView().tint(.white) }
                    Text(checker.checking ? "体检中…" : "开始体检")
                        .font(.headline)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
            }
            .buttonStyle(.borderedProminent)
            .tint(theme.current.accent)
            .disabled(checker.checking)
            if let rep = checker.report, checker.done {
                HStack(spacing: 10) {
                    Button {
                        UIPasteboard.general.string = composeText(rep)
                        copied = true
                    } label: {
                        Label(copied ? "已复制" : "复制报告", systemImage: copied ? "checkmark" : "doc.on.doc")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    Button {
                        showShare = true
                    } label: {
                        Label("分享", systemImage: "square.and.arrow.up")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                }
            }
        }
    }

    private func infoCard(_ rep: IPReport) -> some View {
        Card {
            InfoRow(label: "出口 IP", value: "\(rep.ip)（\(rep.ipVersion)）")
            InfoRow(label: "位置", value: "\(rep.flagEmoji) \(rep.countryName) \(rep.region) \(rep.city)")
            InfoRow(label: "运营商", value: rep.isp)
            InfoRow(label: "组织 / ASN", value: "\(rep.org) / \(rep.asn)")
            Divider()
            InfoRow(label: "IP 类型", value: rep.kind.rawValue)
            Text(rep.kindNote).font(.caption).foregroundColor(.secondary)
            Divider()
            InfoRow(label: "原生/广播", value: rep.isBroadcast == nil ? "未知" : (rep.isBroadcast! ? "疑似广播 IP" : "原生 IP"))
            Text(rep.broadcastNote).font(.caption).foregroundColor(.secondary)
            if let risk = rep.riskScore {
                Divider()
                InfoRow(label: "风险分", value: "\(risk) / 100（越低越好）")
            }
        }
    }

    private var leakCard: some View {
        Card {
            HStack {
                Label("隐私泄漏检测", systemImage: "eye.slash").font(.headline)
                Spacer()
                if leak.running { ProgressView() }
            }
            Text("查两件事：DNS 解析有没有偷偷走你的真实地区；IPv6 有没有绕过代理直连出去。")
                .font(.caption).foregroundColor(.secondary)
            if leak.dnsDone {
                Divider()
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: leak.dnsOK == false ? "exclamationmark.triangle.fill" : (leak.dnsOK == true ? "checkmark.circle.fill" : "questionmark.circle.fill"))
                        .foregroundColor(leak.dnsOK == false ? .red : (leak.dnsOK == true ? .green : .orange))
                    VStack(alignment: .leading, spacing: 2) {
                        Text("DNS 解析：\(leak.dnsResolverIP.isEmpty ? "未知" : leak.dnsResolverIP)")
                            .font(.subheadline)
                        if !leak.dnsGeo.isEmpty {
                            Text(leak.dnsGeo).font(.caption).foregroundColor(.secondary)
                        }
                        Text(leak.dnsVerdict).font(.caption).foregroundColor(.secondary)
                    }
                }
            }
            if !leak.v6Verdict.isEmpty {
                Divider()
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: leak.v6Leak == true ? "exclamationmark.triangle.fill" : (leak.v6Leak == false ? "checkmark.circle.fill" : "questionmark.circle.fill"))
                        .foregroundColor(leak.v6Leak == true ? .red : (leak.v6Leak == false ? .green : .orange))
                    VStack(alignment: .leading, spacing: 2) {
                        Text("IPv6 出口：\(leak.v6IP.isEmpty ? "无" : leak.v6IP)")
                            .font(.subheadline)
                        if !leak.v6Geo.isEmpty {
                            Text(leak.v6Geo).font(.caption).foregroundColor(.secondary)
                        }
                        Text(leak.v6Verdict).font(.caption).foregroundColor(.secondary)
                    }
                }
            }
            Button {
                Task {
                    await leak.run(exitCountryName: checker.report?.countryName ?? "",
                                   exitIP: checker.report?.ip ?? "")
                }
            } label: {
                Text(leak.running ? "检测中…" : "检测 DNS 与 IPv6")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .tint(theme.current.accent)
            .disabled(leak.running)
        }
    }

    private func scoreCard(_ rep: IPReport) -> some View {
        Card {
            Text("评分明细").font(.headline)
            ForEach(rep.items) { it in
                HStack {
                    Text(it.reason).font(.subheadline)
                    Spacer()
                    if it.delta < 0 {
                        Text("\(it.delta)").foregroundColor(.red).font(.subheadline).bold()
                    } else {
                        Text("保底").foregroundColor(.green).font(.subheadline)
                    }
                }
            }
        }
    }

    private func sourcesCard(_ rep: IPReport) -> some View {
        Card {
            Text("数据源状态").font(.headline)
            ForEach(rep.sources) { s in
                HStack {
                    Image(systemName: s.ok == nil ? "minus.circle" : (s.ok! ? "checkmark.circle.fill" : "xmark.circle.fill"))
                        .foregroundColor(s.ok == nil ? .gray : (s.ok! ? .green : .red))
                    Text(s.name).font(.subheadline)
                    Spacer()
                    Text(s.ok == nil ? "未询问" : (s.ok! ? "正常" : "无响应")).font(.caption).foregroundColor(.secondary)
                }
            }
        }
    }

    private func composeText(_ rep: IPReport) -> String {
        var t = makeReportText(rep)
        let extra = leak.summaryLines
        if !extra.isEmpty {
            let footer = "\n— 由「IP 体检」生成（开发者 LengMo）"
            t = t.replacingOccurrences(of: footer, with: "\n" + extra.joined(separator: "\n") + footer)
        }
        return t
    }

    private func runAndSave() async {
        copied = false
        await checker.run()
        guard checker.done, let rep = checker.report else { return }
        await leak.run(exitCountryName: rep.countryName, exitIP: rep.ip)
        if settings.saveHistory {
            history.add(HistoryRecord(
                date: Date(), ip: rep.ip, countryName: rep.countryName,
                countryCode: rep.countryCode, flagEmoji: rep.flagEmoji,
                kindText: rep.kind.rawValue, isBroadcast: rep.isBroadcast,
                score: rep.score, verdict: rep.verdict,
                reportText: composeText(rep)))
        }
    }
}

// MARK: - 测速页

struct SpeedView: View {
    @StateObject private var tester = SpeedTester()
    @EnvironmentObject var theme: ThemeStore
    var body: some View {
        NavigationView {
            ScrollView {
                VStack(spacing: 16) {
                    Card {
                        HStack(spacing: 0) {
                            metricBox("延迟", tester.pingMs.map { String(format: "%.0f", $0) } ?? "—", "ms")
                            metricBox("抖动", tester.jitterMs.map { String(format: "%.0f", $0) } ?? "—", "ms")
                        }
                        Divider()
                        HStack(spacing: 0) {
                            metricBox("下载", tester.downMbps.map { String(format: "%.1f", $0) } ?? "—", "Mbps")
                            metricBox("上传", tester.upMbps.map { String(format: "%.1f", $0) } ?? "—", "Mbps")
                        }
                        if !tester.downBytesText.isEmpty || !tester.upBytesText.isEmpty {
                            Text("\(tester.downBytesText) \(tester.upBytesText)")
                                .font(.caption).foregroundColor(.secondary)
                        }
                    }
                    Button {
                        Task { await tester.run() }
                    } label: {
                        HStack {
                            if tester.running { ProgressView().tint(.white) }
                            Text(tester.running ? (tester.phase.isEmpty ? "测速中…" : tester.phase + "…") : "开始测速")
                                .font(.headline)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(theme.current.accent)
                    .disabled(tester.running)
                    Card {
                        Text("走 Cloudflare 官方测速端点，全程大约消耗 50 MB 流量（Wi-Fi 下放心测）。延迟取多次请求的最小值，速度取峰值。测的是你当前网络（挂着 VPN 就是节点的速度）。")
                            .font(.caption).foregroundColor(.secondary)
                    }
                }
                .padding(16)
            }
            .navigationTitle("测速")
        }
        .navigationViewStyle(.stack)
    }

    private func metricBox(_ title: String, _ value: String, _ unit: String) -> some View {
        VStack(spacing: 4) {
            Text(title).font(.caption).foregroundColor(.secondary)
            HStack(alignment: .lastTextBaseline, spacing: 2) {
                Text(value).font(.system(size: 30, weight: .bold))
                Text(unit).font(.caption).foregroundColor(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - 解锁页

struct UnlockView: View {
    @StateObject private var unlock = UnlockChecker()
    @EnvironmentObject var theme: ThemeStore
    var body: some View {
        NavigationView {
            List {
                ForEach(["AI 服务", "流媒体", "社交"], id: \.self) { sec in
                    Section(header: Text(sec)) {
                        ForEach(unlock.results.filter { $0.section == sec }) { r in
                            HStack(spacing: 12) {
                                Image(systemName: r.icon).frame(width: 24).foregroundColor(theme.current.accent)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(r.name)
                                    if !r.detail.isEmpty {
                                        Text(r.detail).font(.caption).foregroundColor(.secondary)
                                    }
                                }
                                Spacer()
                                stateBadge(r.state)
                            }
                        }
                    }
                }
                Section {
                    Button {
                        Task { await unlock.runAll() }
                    } label: {
                        HStack {
                            Spacer()
                            if unlock.running { ProgressView() }
                            Text(unlock.running ? "检测中…" : "开始检测").font(.headline)
                            Spacer()
                        }
                    }
                    .disabled(unlock.running)
                }
                Section {
                    Text("移动端网页探测只能作参考：判「未解锁」不等于 App 里一定用不了（网页和 App 走的判定不一样），一切以实际打开 App 为准。")
                        .font(.caption).foregroundColor(.secondary)
                }
            }
            .navigationTitle("解锁检测")
        }
        .navigationViewStyle(.stack)
    }

    @ViewBuilder
    private func stateBadge(_ s: UnlockResult.State) -> some View {
        switch s {
        case .pending:
            Text("未检测").font(.caption).foregroundColor(.secondary)
        case .checking:
            ProgressView()
        case .ok:
            Label("已解锁", systemImage: "checkmark.circle.fill").font(.caption).foregroundColor(.green)
        case .no:
            Label("未解锁", systemImage: "xmark.circle.fill").font(.caption).foregroundColor(.red)
        case .unknown:
            Label("未知", systemImage: "questionmark.circle.fill").font(.caption).foregroundColor(.orange)
        }
    }
}

// MARK: - 历史记录页

struct HistoryView: View {
    @EnvironmentObject var history: HistoryStore
    @State private var selected: HistoryRecord? = nil
    @State private var showExport = false

    private var bestID: UUID? {
        history.records.max(by: { $0.score < $1.score })?.id
    }

    var body: some View {
        NavigationView {
            Group {
                if history.records.isEmpty {
                    VStack(spacing: 10) {
                        Image(systemName: "clock.arrow.circlepath")
                            .font(.system(size: 44)).foregroundColor(.secondary)
                        Text("还没有体检记录").foregroundColor(.secondary)
                        Text("去体检页测一次，这里会自动存档，方便几个节点横向对比")
                            .font(.caption).foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 40)
                    }
                } else {
                    List {
                        ForEach(history.records) { r in
                            Button { selected = r } label: {
                                HStack(spacing: 12) {
                                    VStack(alignment: .leading, spacing: 3) {
                                        HStack(spacing: 5) {
                                            Text("\(r.flagEmoji) \(r.countryName)")
                                                .font(.subheadline).bold().foregroundColor(.primary)
                                            if r.id == bestID {
                                                Image(systemName: "crown.fill")
                                                    .font(.caption).foregroundColor(.yellow)
                                            }
                                        }
                                        Text("\(r.ip) · \(r.kindText)")
                                            .font(.caption).foregroundColor(.secondary)
                                        Text(r.date, style: .date)
                                            .font(.caption2).foregroundColor(.secondary)
                                    }
                                    Spacer()
                                    VStack(spacing: 1) {
                                        Text("\(r.score)")
                                            .font(.title3).bold()
                                            .foregroundColor(scoreColor(r.score))
                                        Text(r.verdict).font(.caption2).foregroundColor(.secondary)
                                    }
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
                    HStack {
                        if !history.records.isEmpty {
                            Button { showExport = true } label: {
                                Image(systemName: "square.and.arrow.up")
                            }
                            Button(role: .destructive) { history.clear() } label: {
                                Image(systemName: "trash")
                            }
                        }
                    }
                }
            }
            .sheet(item: $selected) { r in
                NavigationView {
                    ScrollView {
                        Text(r.reportText)
                            .font(.system(.subheadline, design: .monospaced))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(16)
                            .textSelection(.enabled)
                    }
                    .navigationTitle("体检报告")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .navigationBarTrailing) {
                            Button("复制") { UIPasteboard.general.string = r.reportText }
                        }
                        ToolbarItem(placement: .navigationBarLeading) {
                            Button("关闭") { selected = nil }
                        }
                    }
                }
            }
            .sheet(isPresented: $showExport) {
                ActivityView(items: [history.exportText()])
            }
        }
        .navigationViewStyle(.stack)
    }

    private func scoreColor(_ s: Int) -> Color {
        switch s {
        case 85...100: return .green
        case 70...84: return .teal
        case 50...69: return .orange
        default: return .red
        }
    }
}

// MARK: - 设置页

struct SettingsView: View {
    @EnvironmentObject var theme: ThemeStore
    @EnvironmentObject var settings: SettingsStore
    @EnvironmentObject var history: HistoryStore
    @State private var showClearConfirm = false

    var body: some View {
        NavigationView {
            List {
                Section(header: Text("主题")) {
                    ForEach(allThemes) { t in
                        Button {
                            theme.themeID = t.id
                        } label: {
                            HStack(spacing: 12) {
                                Circle()
                                    .fill(t.gradient)
                                    .frame(width: 30, height: 30)
                                Text(t.name).foregroundColor(.primary)
                                Spacer()
                                if theme.themeID == t.id {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundColor(t.accent)
                                }
                            }
                        }
                    }
                }
                Section(header: Text("检测")) {
                    Toggle("打开 App 自动体检", isOn: $settings.autoCheck)
                    Toggle("自动保存历史记录", isOn: $settings.saveHistory)
                }
                Section(header: Text("数据")) {
                    Button(role: .destructive) {
                        showClearConfirm = true
                    } label: {
                        Text("清空全部历史记录")
                    }
                }
                Section(header: Text("数据源")) {
                    Text("出口 IP 与定位：Cloudflare Trace、ipwho.is、ip.sb")
                    Text("类型标记：ip-api（机房 / 代理 / 移动网络）")
                    Text("风险分：proxycheck.io")
                    Text("交叉验证：ipapi.co")
                    Text("DNS 解析地：ip-api edns 服务")
                    Text("测速：speed.cloudflare.com")
                    Text("全部免费免 Key，检测在你手机上直连这些服务进行，本 App 不上传、不保存你的任何数据（历史记录只存你本机）。")
                        .font(.caption).foregroundColor(.secondary)
                }
                Section(header: Text("关于")) {
                    HStack { Text("版本"); Spacer(); Text("1.1.0").foregroundColor(.secondary) }
                    HStack { Text("开发者"); Spacer(); Text("LengMo").foregroundColor(.secondary) }
                    Link("GitHub 仓库", destination: URL(string: "https://github.com/ColdFoam-heg/ip-checker")!)
                    Text("© 2026 LengMo")
                        .font(.caption).foregroundColor(.secondary)
                }
            }
            .navigationTitle("设置")
            .alert("清空全部历史记录？", isPresented: $showClearConfirm) {
                Button("取消", role: .cancel) {}
                Button("清空", role: .destructive) { history.clear() }
            } message: {
                Text("清空后不可恢复。")
            }
        }
        .navigationViewStyle(.stack)
    }
}
