// Plain checks without XCTest; run by Tests/check.sh.
import Foundation
var failures = 0
func expect(_ cond: Bool, _ what: String) { if !cond { failures += 1; print("BŁĄD: \(what)") } }

expect(LinkSpeed(subtype: MediaSubtype.t1000, active: true) == .g1, "1000baseT → 1G")
expect(LinkSpeed(subtype: MediaSubtype.t2500, active: true) == .g2_5, "2500Base-T → 2,5G")
expect(LinkSpeed(subtype: MediaSubtype.t5000, active: true) == .g5, "5000Base-T → 5G")
expect(LinkSpeed(subtype: MediaSubtype.t10G, active: true) == .g10, "10Gbase-T → 10G")
expect(LinkSpeed(subtype: MediaSubtype.tx100, active: true) == .other(megabits: 100), "100baseTX → inna 100")
expect(LinkSpeed(subtype: MediaSubtype.t5000, active: false) == .none, "bez IFM_ACTIVE → brak")
expect(LinkSpeed(subtype: 0, active: true) == .other(megabits: nil), "nieznany podtyp → inna")
expect(LinkSpeed.g2_5.label == "2.5 Gb/s", "etykieta 2,5")
expect(LinkSpeed(media: 0x20 | MediaSubtype.t5000, status: 0x3) == .g5, "Ethernet 5G z łączem")
expect(LinkSpeed(media: 0x80, status: 0x3) == .none, "Wi‑Fi (zmierzone: 0x80) to nie łącze kablowe")
expect(LinkSpeed(media: 0x22, status: 0x1) == .none, "karta kablowa bez łącza (zmierzone: 0x22, 0x1)")
expect(LinkSpeed(media: 0x100020, status: 0x3) == .other(megabits: nil), "Ethernet z łączem, podtyp bez koloru")

let args = SpeedTest.sshArguments(host: "nas.local", command: "echo R")
expect(args.contains("BatchMode=yes"), "ssh bez pytania o hasło")
expect(args.contains("Compression=no"), "ssh bez kompresji")
expect(Array(args.suffix(3)) == ["--", "nas.local", "echo R"], "host po --, polecenie na końcu")
expect(!args.contains("-b"), "ssh bez wybranej karty: trasa systemu")
let bound = SpeedTest.sshArguments(host: "nas.local", command: "echo R", bind: "192.0.2.20")
expect(Array(bound.suffix(5)) == ["-b", "192.0.2.20", "--", "nas.local", "echo R"], "ssh z kartą: -b adres przed --")
let routeOut = "   route to: 192.0.2.10\ndestination: 192.0.2.0\n       mask: 255.255.255.0\n  interface: en5\n      flags: <UP,DONE,CLONING>\n"
expect(SpeedTest.interface(fromRoute: routeOut) == "en5", "route get → karta")
expect(SpeedTest.interface(fromRoute: "route: writing to routing socket: not in table\n") == nil, "route get bez trasy → nic")
expect(SpeedTest.hostName(fromSSHConfig: "user root\nhostname 192.0.2.10\nport 22\n") == "192.0.2.10", "ssh -G → adres aliasu")
expect(SpeedTest.hostName(fromSSHConfig: "user root\nport 22\n") == nil, "ssh -G bez hostname → nic")
expect(Int(SpeedTest.megabytesPerSecond(bytes: 2_000_000_000, seconds: 4).rounded()) == 500, "2 GB w 4 s = 500 MB/s")
expect(SpeedTest.megabytesPerSecond(bytes: 1, seconds: 0) == 0, "zero sekund nie dzieli przez zero")

expect(SpeedTest.quoted("/mnt/da'ne") == "'/mnt/da'\\''ne'", "cudzysłów w ścieżce")
let rf = SpeedTest.remoteFile(dir: "/srv/data", id: "ab12")
expect(rf == "/srv/data/nettorque-ab12.bin", "plik testowy w folderze serwera")
expect(SpeedTest.remoteFile(dir: "/srv/data/", id: "ab12") == rf, "folder z ukośnikiem na końcu")
expect(SpeedTest.uploadCommand(.memory, file: nil) == "echo R; exec wc -c", "wysyłanie z pamięci")
expect(SpeedTest.uploadCommand(.disk(remoteDir: "/srv/data"), file: rf) == "echo R; cat > '\(rf)' && sync '\(rf)' && wc -c < '\(rf)'", "wysyłanie na dysk z sync pliku")
expect(SpeedTest.downloadCommand(.memory, bytes: 5, file: nil) == "echo R; head -c 5 /dev/zero", "pobieranie z pamięci")
expect(SpeedTest.downloadCommand(.disk(remoteDir: "/x"), bytes: 5, file: rf) == "echo R; cat '\(rf)'", "pobieranie z dysku")
expect(SpeedTest.leftoversCommand(dir: "/srv/data") == "find '/srv/data' -maxdepth 1 -type f \\( -name 'nettorque-????????.bin' -o -name 'speedlan-????????.bin' \\) -mmin +60 -exec rm -- {} \\;", "resztki starsze niż godzina, tylko pliki programu")
expect(SpeedTest.remoteFile(dir: "/srv/data", id: "ab12cd34").hasSuffix("nettorque-ab12cd34.bin"), "nazwa pliku pasuje do wzorca resztek (8 znaków)")

func d(_ s: String) -> Data { Data(s.utf8) }
expect(SpeedTest.afterReady(d("R\n")) == Data(), "R bez danych")
expect(SpeedTest.afterReady(d("Witaj na serwerze\nR\nabc")) == d("abc"), "tekst powłoki przed R pominięty")
expect(SpeedTest.afterReady(d("Rx\n")) == nil, "wiersz Rx to nie R")
expect(SpeedTest.afterReady(d("R")) == nil, "R bez końca wiersza — jeszcze czekamy")
expect(SpeedTest.lastNumber(d("  2000000000\n")) == 2_000_000_000, "wc -c ze spacjami (BSD)")
expect(SpeedTest.lastNumber(d("motd\n12\n\n")) == 12, "ostatni niepusty wiersz")
expect(SpeedTest.lastNumber(d("brak")) == nil, "bez liczby")


let alias = TestController.Server(name: "nas", host: "nas.local", user: "", folder: "/srv/data")
expect(alias.sshDestination == "nas.local", "bez użytkownika: sam adres / alias")
let withUser = TestController.Server(name: "nas", host: "192.0.2.10", user: "root", folder: "/tmp")
expect(withUser.sshDestination == "root@192.0.2.10", "z użytkownikiem: user@adres")
expect(TestController.Server(name: "a", host: "h", user: "  ", folder: "/").sshDestination == "h", "same spacje = bez użytkownika")

let card = "Ethernet Adapter (en5)"
// Floor 5G — the behaviour before 0.1.18, unchanged.
let f5: LinkSpeed? = .g5
expect(LinkAlert.check(lastLinked: .g5, previous: .g5, current: .none, floor: f5, card: card)?.title == "Wired connection lost", "utrata połączenia")
expect(LinkAlert.check(lastLinked: .g5, previous: .g5, current: .g1, floor: f5, card: card)?.title == "Link slowed to 1 Gb/s", "5G → 1G")
expect(LinkAlert.check(lastLinked: .g5, previous: .none, current: .g2_5, floor: f5, card: card) != nil, "po utracie wraca wolniej niż 5G")
expect(LinkAlert.check(lastLinked: .g5, previous: .none, current: .g5, floor: f5, card: card) == nil, "po utracie wraca 5G — cisza")
expect(LinkAlert.check(lastLinked: nil, previous: .none, current: .g1, floor: f5, card: card) == nil, "start programu na 1G — cisza")
expect(LinkAlert.check(lastLinked: .g1, previous: .g1, current: .g2_5, floor: f5, card: card) == nil, "1G → 2,5G to nie spadek poniżej 5G")
expect(LinkAlert.check(lastLinked: .g5, previous: .g5, current: .g10, floor: f5, card: card) == nil, "5G → 10G — cisza")
expect(LinkAlert.check(lastLinked: nil, previous: .none, current: .none, floor: f5, card: card) == nil, "start bez kabla — cisza")
// Other floors: the fall that 0.1.17 missed, and a card that never had a link.
expect(LinkAlert.check(lastLinked: .g2_5, previous: .g2_5, current: .g1, floor: .g2_5, card: card) != nil, "próg 2,5G: 2,5G → 1G")
expect(LinkAlert.check(lastLinked: .g1, previous: .g1, current: .other(megabits: 100), floor: .g1, card: card)?.title == "Link slowed to 100 Mb/s", "próg 1G: 1G → 100M")
expect(LinkAlert.check(lastLinked: .g1, previous: .g1, current: .g1, floor: .g1, card: card) == nil, "próg 1G: bez zmiany — cisza")
expect(LinkAlert.check(lastLinked: .g2_5, previous: .g2_5, current: .g1, floor: nil, card: card) == nil, "bez progu (najlepsza nieznana) — tylko utrata")
expect(LinkAlert.check(lastLinked: .g2_5, previous: .g2_5, current: .none, floor: nil, card: card) != nil, "bez progu — utrata dalej alarmuje")
expect(LinkAlert.check(lastLinked: .g1, previous: .g1, current: .other(megabits: 100), floor: .g2_5, card: card) == nil, "już poniżej progu — drugi raz cisza")
// Floor from the stored best speed.
expect(DropFloor.best.speed(best: .g2_5) == .g2_5, "próg „najlepsza” = zapamiętana")
expect(DropFloor.best.speed(best: nil) == nil, "próg „najlepsza” bez pamięci = brak")
expect(DropFloor.g5.speed(best: .g1) == .g5, "próg stały nie patrzy na najlepszą")
expect(LinkSpeed(megabitsPerSecond: 2_500) == .g2_5 && LinkSpeed(megabitsPerSecond: 100) == .other(megabits: 100)
       && LinkSpeed(megabitsPerSecond: 0) == nil, "zapis najlepszej w Mb/s i z powrotem")
expect(LinkSpeed.none.isBelow(.g1) == false, "brak łącza to nie spadek")

// Link details — words measured on a 5G USB card (2026-10-10) and a Mac's built-in 1G port.
let card5G: [Int32] = [0x20, 0x100023, 0x100026, 0x100030, 0x100036, 0x100037] + [Int32](repeating: 0, count: 20)
let d5 = LinkDetails(active: 0x500037, supported: card5G, mtu: 1500, errors: 0)
expect(d5.maxSpeed == .g5 && d5.fullDuplex && d5.flowControl && !d5.halfDuplex && !d5.energyEfficient, "karta 5G: najwyżej 5G, full duplex, flow control")
expect(LinkSpeed(media: 0x500037, status: 0x3) == .g5, "słowo zmierzone na karcie 5G → 5G")
let builtIn: [Int32] = [0x22, 0x20, 0x200023, 0x100023, 0x8100023, 0x500023, 0x200026, 0x100026, 0x100030, 0x8100030, 0x900030]
expect(LinkDetails(active: 0x22, supported: builtIn, mtu: 1500, errors: 0).maxSpeed == .g1, "port wbudowany: najwyżej 1G")
expect(LinkDetails(active: 0, supported: [0x80, 0x0], mtu: nil, errors: 0).maxSpeed == nil, "bez nośników Ethernet → brak")
expect(LinkDetails(active: 0, supported: [0x20 | 0x10000 | 3], mtu: nil, errors: 0).maxSpeed == nil, "rozszerzony podtyp nie udaje starego")

expect(LinkHint.check(speed: .g5, details: d5, errorsBefore: 0) == [], "5G na karcie 5G — bez podpowiedzi")
expect(!LinkDetails.trustsSupportedList(driver: "com.apple.driver.usb.cdc.ncm")
       && !LinkDetails.trustsSupportedList(driver: "com.apple.driver.usb.cdc.ecm"), "ogólny sterownik USB Apple'a — lista się nie liczy")
expect(LinkDetails.trustsSupportedList(driver: "com.realtek.dext.RTL815xEthernet")
       && LinkDetails.trustsSupportedList(driver: nil), "sterownik karty albo nieznany — lista się liczy")
expect(LinkHint.check(speed: .g5, details: LinkDetails(active: 0x500037, supported: [], mtu: 1500, errors: 0), errorsBefore: 0) == [],
       "pusta lista (sterownik ogólny) — bez „karta obsługuje”")
expect(LinkHint.check(speed: .g1, details: d5, errorsBefore: 0) == [.slowerThanCard(card: .g5, link: .g1)], "karta 5G na 1G — kabel/port")
expect(LinkHint.check(speed: .none, details: d5, errorsBefore: 0) == [], "bez łącza — bez podpowiedzi")
expect(LinkHint.check(speed: .other(megabits: nil), details: d5, errorsBefore: 0) == [], "nieznana prędkość — nie zgadujemy")
var half = d5; half.halfDuplex = true; half.fullDuplex = false
expect(LinkHint.check(speed: .g5, details: half, errorsBefore: 0) == [.halfDuplex], "half duplex")
var bad = d5; bad.errors = 12
expect(LinkHint.check(speed: .g5, details: bad, errorsBefore: 2) == [.errors(count: 10)], "błędy od początku łącza")
expect(LinkHint.check(speed: .g5, details: bad, errorsBefore: nil) == [], "błędy bez punktu odniesienia — cisza")
expect(LinkHint.check(speed: .g5, details: bad, errorsBefore: 12) == [], "błędy bez przyrostu — cisza")
expect(LinkHint.slowerThanCard(card: .g10, link: .g1).text.contains("Cat 6a"), "10G → Cat 6a")
expect(LinkHint.slowerThanCard(card: .g5, link: .g1).text.contains("Cat 5e"), "5G → Cat 5e")

// Settings of the old name: the app's keys carry over, the system's window frames do not.
let oldPrefs: [String: Any] = ["servers": Data([1]), "interface": "en5", "AppleLanguages": ["pl"],
                               "NSWindow Frame SpeedLan.Okno": "1 2 3 4", "NSStatusItem Preferred Position Item-0": 900]
let carried = Migration.carried(oldPrefs)
expect(Set(carried.keys) == ["servers", "interface", "AppleLanguages"], "migracja: klucze programu tak, ramki okien nie")
let suite = "nettorque.tests.\(UUID().uuidString)"
if let d = UserDefaults(suiteName: suite) {
    d.set("en0", forKey: "interface")
    Migration.run(defaults: d)
    expect(d.bool(forKey: "migratedFromSpeedLan"), "migracja zaznaczona jako zrobiona")
    expect(d.string(forKey: "interface") == "en0", "migracja nie nadpisuje nowych ustawień")
    d.removePersistentDomain(forName: suite)
}


// History: limit, order, CSV with a dot whatever the language.
let store = HistoryStore(file: nil)
for i in 0..<(HistoryStore.limit + 3) {
    store.append(HistoryEntry(date: Date(timeIntervalSince1970: Double(i)), mode: "memory", server: "nas", bytes: 2_000_000_000,
                              uploadMBps: 400, downloadMBps: 460, linkMbps: 5000))
}
expect(store.entries.count == HistoryStore.limit && store.entries.first?.date == Date(timeIntervalSince1970: 3), "historia: limit, najstarsze wypadają")
let rows = HistoryStore.csv([HistoryEntry(date: Date(timeIntervalSince1970: 0), mode: "internet", server: #"Dom, "biuro""#, bytes: 0,
                                          uploadMBps: 24.77, downloadMBps: 108.12, linkMbps: 5000, latencyMs: 30.1)])
    .split(separator: "\n")
expect(rows.count == 2 && rows[1] == #"1970-01-01T00:00:00Z,internet,"Dom, ""biuro""",,24.8,108.1,5000,30.1,"#, "CSV: cudzysłowy, kropka, pusty rozmiar dla internetu")
let viaRow = HistoryStore.csv([HistoryEntry(date: Date(timeIntervalSince1970: 0), mode: "memory", server: "nas", bytes: 2_000_000_000,
                                            uploadMBps: 400, downloadMBps: 460, linkMbps: 5000, via: "en5")]).split(separator: "\n")
expect(viaRow[0].hasSuffix(",via") && viaRow[1].hasSuffix(",5000,,en5"), "CSV: karta w ostatniej kolumnie")
expect(HistoryStore.quoted("=HYPERLINK(\"x\")") == "\"'=HYPERLINK(\"\"x\"\")\"" && HistoryStore.quoted("@a") == "'@a"
       && HistoryStore.quoted("-1") == "'-1" && HistoryStore.quoted("nas") == "nas", "CSV: nazwa od = + - @ jako tekst, nie formuła (audyt B-P3-03)")
let broken = FileManager.default.temporaryDirectory.appendingPathComponent("nettorque-test-\(UUID().uuidString).json")
try? Data("nie json".utf8).write(to: broken)
expect(HistoryStore.load(broken).isEmpty && !FileManager.default.fileExists(atPath: broken.path)
       && (try? Data(contentsOf: broken.appendingPathExtension("broken"))) == Data("nie json".utf8), "historia: nieczytelny plik odłożony jako .broken, nie nadpisany (audyt S-P3-01)")
try? FileManager.default.removeItem(at: broken.appendingPathExtension("broken"))
expect(HistoryStore.load(broken).isEmpty, "historia: brak pliku = pusta historia")
let oldEntry = #"[{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","date":"1970-01-01T00:00:00Z","mode":"memory","server":"nas","bytes":1,"uploadMBps":1,"downloadMBps":1,"linkMbps":5000}]"#
let entryDecoder = JSONDecoder(); entryDecoder.dateDecodingStrategy = .iso8601
let decoded = try? entryDecoder.decode([HistoryEntry].self, from: Data(oldEntry.utf8))
expect(decoded?.count == 1 && decoded?.first?.via == nil, "historia sprzed 0.1.35 się czyta, bez karty")
store.clear()
expect(store.entries.isEmpty, "historia: wyczyść")

// Menu bar text.
let res = SpeedTest.Outcome(server: "nas", bytes: 1, mode: .memory, uploadMBps: 404.6, downloadMBps: 463.2, finished: Date())
expect(TestController.menuBarTitle(.none, link: .g5, outcome: res) == nil, "pasek: sama ikonka")
expect(TestController.menuBarTitle(.link, link: .g2_5, outcome: nil) == "2.5G", "pasek: prędkość łącza")
expect(TestController.menuBarTitle(.link, link: .none, outcome: nil) == "—", "pasek: bez łącza")
expect(TestController.menuBarTitle(.result, link: .g5, outcome: res) == "↑405 ↓463", "pasek: ostatni wynik")
expect(TestController.menuBarTitle(.result, link: .g5, outcome: nil) == "—", "pasek: jeszcze bez wyniku")

// Network folder.
expect(SpeedTest.fileSystem(of: "/") == "apfs" && !SpeedTest.isNetworkFolder("/"), "folder: dysk Maca to nie udział")
expect(SpeedTest.networkFileSystems.contains("smbfs"), "folder: smbfs to udział")
expect(SpeedTest.isTestFileName("nettorque-ab12cd34.bin") && SpeedTest.isTestFileName("speedlan-ab12cd34.bin"), "folder: pliki testowe obu nazw")
expect(!SpeedTest.isTestFileName("nettorque-ab12cd34-out.bin") && !SpeedTest.isTestFileName("zdjecie.bin"), "folder: cudze pliki zostają")
let oldServer = #"[{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","name":"nas","host":"nas.local","user":"","folder":"/srv"}]"#
expect((try? JSONDecoder().decode([TestController.Server].self, from: Data(oldServer.utf8)))?.first?.isFolder == false, "serwer sprzed 0.1.26 się czyta, jako SSH")

// Servers found on the network.
let seen: [ServiceBrowser.Kind: Set<String>] = [.smb: ["samba", "office"], .ssh: ["Mac (me)", "nas"]]
expect(ServiceBrowser.list(seen, ownNames: ["Mac (me)"]).map(\.id) == ["_smb._tcp/office", "_smb._tcp/samba", "_ssh._tcp/nas"], "Bonjour: bez własnego Maca, po kolei")
expect(ServiceBrowser.withoutInterface("192.0.2.10%en5") == "192.0.2.10", "Bonjour: adres bez dopisku karty (zmierzone)")
expect(ServiceBrowser.withoutInterface("fe80::1%en0") == "fe80::1", "Bonjour: IPv6 bez dopisku karty")

// Mac to Mac: the code is proved on every connection.
let peerKey = PeerProtocol.key(code: "123456")
let challenge = Data((0..<32).map { UInt8($0) })
let head = PeerProtocol.header(key: peerKey, challenge: challenge, command: .upload, size: 2_000_000_000)
expect(head.count == PeerProtocol.headerSize, "Mac↔Mac: nagłówek 41 B")
expect(PeerProtocol.check(header: head, key: peerKey, challenge: challenge).map { $0.0 == .upload && $0.1 == 2_000_000_000 } == true, "Mac↔Mac: dobry kod przechodzi")
expect(PeerProtocol.check(header: head, key: PeerProtocol.key(code: "123457"), challenge: challenge) == nil, "Mac↔Mac: zły kod odrzucony")
expect(PeerProtocol.check(header: head, key: peerKey, challenge: Data(repeating: 9, count: 32)) == nil, "Mac↔Mac: stara odpowiedź na nowe wyzwanie odrzucona")
var tampered = head; tampered[tampered.startIndex + 8] ^= 1
expect(PeerProtocol.check(header: tampered, key: peerKey, challenge: challenge) == nil, "Mac↔Mac: zmieniony rozmiar odrzucony")
expect(PeerProtocol.isValidCode("012345") && !PeerProtocol.isValidCode("12345") && !PeerProtocol.isValidCode("12345a") && !PeerProtocol.isValidCode("١٢٣٤٥٦"), "Mac↔Mac: kod to 6 cyfr ASCII")
let a = "192.0.2.10", b = "192.0.2.11", own = "192.0.2.20"
var lock = PeerLockout(); let t0 = Date()
for i in 0..<4 { lock.fail(a, at: t0.addingTimeInterval(Double(i))) }
expect(!lock.isLocked(a, at: t0.addingTimeInterval(5)), "Mac↔Mac: 4 złe kody — jeszcze bez blokady")
lock.fail(a, at: t0.addingTimeInterval(5))
expect(lock.isLocked(a, at: t0.addingTimeInterval(6)) && !lock.isLocked(a, at: t0.addingTimeInterval(606)), "Mac↔Mac: 5. zły kod blokuje ten adres na 10 min")
expect(!lock.isLocked(b, at: t0.addingTimeInterval(6)), "Mac↔Mac: 5 złych kodów z jednego adresu nie blokuje innych (audyt B-P2-01)")
var slow = PeerLockout()
for i in 0..<5 { slow.fail(a, at: t0.addingTimeInterval(Double(i) * 200)) }
expect(!slow.isLocked(a, at: t0.addingTimeInterval(801)), "Mac↔Mac: złe kody rozłożone ponad 10 min nie blokują")
var many = PeerLockout()
many.succeed(own)
for i in 0..<(PeerLockout.overall - 1) { many.fail("198.51.100.\(i)", at: t0) }
expect(!many.isLocked(b, at: t0.addingTimeInterval(1)), "Mac↔Mac: 29 złych kodów z różnych adresów — jeszcze bez blokady wszystkich")
many.fail("198.51.100.200", at: t0)
expect(many.isLocked(b, at: t0.addingTimeInterval(1)) && !many.isLocked(b, at: t0.addingTimeInterval(601)), "Mac↔Mac: 30 złych kodów z sieci blokuje nieznane adresy na 10 min")
expect(!many.isLocked(own, at: t0.addingTimeInterval(1)), "Mac↔Mac: Mac, który już podał dobry kod, przechodzi mimo blokady wszystkich")
expect(PeerProtocol.uint64(PeerProtocol.uint64(2_000_000_000)) == 2_000_000_000, "Mac↔Mac: liczba 64-bit tam i z powrotem")

// Wi‑Fi.
expect(LinkSpeed.wifi(megabits: 2401).colourName == "2_5g" && LinkSpeed.wifi(megabits: 600).colourName == "1g"
       && LinkSpeed.wifi(megabits: 599).colourName == "other" && LinkSpeed.wifi(megabits: 4804).colourName == "5g", "Wi‑Fi: kolory według prędkości radia")
expect(LinkSpeed.g2_5.colourName == "2_5g" && LinkSpeed.none.colourName == "none", "kable: te same nazwy plików co dotąd")
expect(LinkSpeed.wifi(megabits: 2401).megabitsPerSecond == 2401 && LinkSpeed.wifi(megabits: 2401).label == "Wi‑Fi 2401 Mb/s", "Wi‑Fi: prędkość i opis (zmierzone 2401)")
expect(LinkAlert.check(lastLinked: .wifi(megabits: 2401), previous: .wifi(megabits: 2401), current: .none, floor: nil, card: card, wifi: true)?.title == "Wi‑Fi connection lost", "Wi‑Fi: utrata połączenia")
expect(LinkAlert.check(lastLinked: .wifi(megabits: 2401), previous: .wifi(megabits: 2401), current: .wifi(megabits: 300), floor: nil, card: card, wifi: true) == nil, "Wi‑Fi: wahania prędkości bez alarmu")
var wifiErr = LinkDetails(); wifiErr.errors = 50
expect(LinkHint.check(speed: .wifi(megabits: 300), details: wifiErr, errorsBefore: 0) == [], "Wi‑Fi: bez podpowiedzi o kablu, także przy błędach")

var rates = WiFiRates(); let r0 = Date()
expect(rates.add(2401, at: r0) == 2401 && rates.add(286, at: r0.addingTimeInterval(30)) == 2401, "Wi‑Fi: najlepsza z minuty (zmierzone 2401 → 286)")
expect(rates.add(300, at: r0.addingTimeInterval(61)) == 300, "Wi‑Fi: po minucie stara prędkość wypada")

// Mounted shares: the host from the mount source.
expect(ServiceBrowser.host(fromMount: "//user@192.0.2.10/Archive") == "192.0.2.10", "zamontowany SMB: adres z użytkownikiem")
expect(ServiceBrowser.host(fromMount: "//192.0.2.10/Share") == "192.0.2.10", "zamontowany SMB: adres bez użytkownika")
expect(ServiceBrowser.host(fromMount: "nas.local:/export/data") == "nas.local", "zamontowany NFS: nazwa hosta")
expect(ServiceBrowser.host(fromMount: "//user@nas.local/a@b") == "nas.local", "zamontowany SMB: @ w nazwie udziału nie myli")

// Duplicates (0.1.39): repeated Add or Pair made copies.
let sshA = TestController.Server(name: "nas", host: "192.0.2.10", user: "", folder: "/tmp")
var sshB = sshA; sshB.id = UUID()
var shareA = TestController.Server(name: "Share", host: "", user: "", folder: "/Volumes/Share"); shareA.isNetworkFolder = true
var shareB = shareA; shareB.id = UUID()
var peerA = TestController.Server(name: "Mac", host: "Mac", user: "", folder: ""); peerA.peerCode = "123456"
var peerB = peerA; peerB.id = UUID()
let other = TestController.Server(name: "nas", host: "192.0.2.10", user: "root", folder: "/tmp")
let dedup = TestController.withoutDuplicates([sshA, sshB, shareA, peerA, shareB, peerB, other], selected: peerB.id)
expect(dedup.servers.map(\.id) == [sshA.id, shareA.id, peerA.id, other.id], "duplikaty: zostaje pierwszy z każdej pary, kolejność bez zmian")
expect(dedup.selected == peerA.id, "duplikaty: wybrany usunięty wpis przechodzi na bliźniaka")
expect(TestController.withoutDuplicates([sshA, other], selected: other.id).servers.count == 2, "duplikaty: inny użytkownik SSH to inny serwer")
expect(TestController.existing(in: [sshA, shareA], host: "192.0.2.10", folder: false, path: "")?.id == sshA.id, "Dodaj: ten sam adres SSH → istniejący")
expect(TestController.existing(in: [sshA, shareA], host: "", folder: true, path: "/Volumes/Share")?.id == shareA.id, "Dodaj: ten sam folder → istniejący")
expect(TestController.existing(in: [other], host: "192.0.2.10", folder: false, path: "") == nil, "Dodaj: serwer z innym użytkownikiem nie blokuje nowego")
expect(TestController.existing(in: [shareA], host: "", folder: true, path: "/Volumes/Other") == nil, "Dodaj: inny folder → nowy")

// Duplicates (0.1.40): a Mac with two cards resolves to another address; empty entries piled up.
let macSSH = TestController.Server(name: "Mac (user)", host: "192.0.2.17", user: "", folder: "/tmp")
expect(TestController.existing(in: [macSSH], name: "Mac (user)", host: "192.0.2.6", folder: false, path: "")?.id == macSSH.id, "Dodaj: ta sama nazwa pod innym adresem → istniejący")
expect(TestController.existing(in: [macSSH], name: "Inny", host: "", folder: false, path: "") == nil, "Dodaj: pusty adres nie pasuje do niczego")
let blank = TestController.Server(name: "Server", host: " ", user: "", folder: "/tmp")
expect(TestController.isBlank(blank) && !TestController.isBlank(macSSH) && !TestController.isBlank(shareA) && !TestController.isBlank(peerA), "pusty wpis: tylko SSH bez adresu")
let noBlank = TestController.withoutDuplicates([blank, shareA, macSSH], selected: blank.id)
expect(noBlank.servers.map(\.id) == [shareA.id, macSSH.id] && noBlank.selected == shareA.id, "wczytanie: pusty wpis znika obok prawdziwych, wybór przechodzi dalej")
expect(TestController.withoutDuplicates([blank], selected: blank.id).servers.map(\.id) == [blank.id], "wczytanie: sam pusty wpis zostaje (lista nigdy pusta)")

// The card's address facing the server (0.1.42): a second address from another subnet is listed first.
let twoAddresses = [(address: "192.0.2.100", mask: "255.255.255.0"), (address: "198.51.100.11", mask: "255.255.254.0")]
expect(LinkMonitor.sourceAddress(among: twoAddresses, toward: "198.51.101.150") == "198.51.100.11", "karta z dwoma adresami: adres z podsieci serwera (/23)")
expect(LinkMonitor.sourceAddress(among: twoAddresses, toward: "203.0.113.5") == "192.0.2.100"
       && LinkMonitor.sourceAddress(among: twoAddresses, toward: nil) == "192.0.2.100", "karta z dwoma adresami: serwer spoza obu podsieci albo nieznany → pierwszy")
expect(LinkMonitor.sourceAddress(among: [], toward: "198.51.100.1") == nil && LinkMonitor.ipv4("nas.local") == nil, "karta bez adresu; nazwa to nie adres")

// SSH hints.
expect(TestController.sshHint("Host key verification failed.", host: "nas.local").map { $0.contains("ssh nas.local") && $0.contains("fingerprint") } == true, "SSH: nieznany klucz serwera → podpowiedź z odciskiem (audyt B-P3-02)")
expect(TestController.sshHint("root@192.0.2.10: Permission denied (publickey).", host: "192.0.2.10")?.contains("ssh-copy-id") == true, "SSH: odrzucony klucz → ssh-copy-id")
expect(TestController.sshHint("Connection refused", host: "nas") == nil, "SSH: inny błąd bez podpowiedzi")
expect(TestController.sshHint("ssh: connect to host 192.0.2.10 port 22: No route to host", host: "192.0.2.10")?.contains("Local Network") == true,
       "SSH: brak trasy → podpowiedź o Sieci lokalnej (0.1.43)")
expect(TestController.sshHint("ssh: connect to host 192.0.2.10 port 22: Operation timed out", host: "192.0.2.10") == nil, "SSH: przekroczony czas bez podpowiedzi o Sieci lokalnej")

// Help: every text of the Help window has a Polish translation in the string catalog.
if let data = FileManager.default.contents(atPath: "NetTorque/Localizable.xcstrings"),
   let catalog = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
   let strings = catalog["strings"] as? [String: Any] {
    var missing = 0
    for key in Set(HelpContent.allStrings + ["NetTorque Help", "NetTorque Help…", "Help", "Backup"]) {
        let pl = ((strings[key] as? [String: Any])?["localizations"] as? [String: Any])?["pl"] as? [String: Any]
        let unit = pl?["stringUnit"] as? [String: Any]
        if (unit?["value"] as? String)?.isEmpty != false || unit?["state"] as? String != "translated" {
            missing += 1
            print("BRAK tłumaczenia Pomocy: \(key)")
        }
    }
    expect(missing == 0, "Pomoc: \(missing) tekstów bez polskiego tłumaczenia")
    for s in HelpContent.sections { expect((1...4).contains(s.steps.count), "Pomoc: 1–4 kroki w sekcji \(s.title)") }
} else {
    expect(false, "Pomoc: nie da się odczytać NetTorque/Localizable.xcstrings")
}

if failures == 0 { print("Testy: OK") } else { print("Testy: \(failures) błędów"); exit(1) }
