import Foundation

/// Major tracking and advertising services, blocked when another site loads them.
///
/// Source: curated for Browser by its contributors from well-known analytics, ad, and fingerprinting services, and
/// not derived from a third-party blocklist, so it's covered by the app's own license. Published lists were ruled
/// out because their licenses don't allow bundling in an app that may also ship under other terms: DuckDuckGo's
/// Tracker Radar is CC BY-NC-SA 4.0 (non-commercial), and EasyPrivacy and Disconnect's list are GPL-3.0.
/// Services a page needs to work, such as sign-in buttons, CAPTCHAs, and video players, are left out, and so are
/// affiliate and app links that a click goes through.
enum TrackerBlocklist {
    /// Bump when the list or the rules made from it change, so the cached compiled list is replaced.
    static let version = 2

    /// Blocked along with their subdomains.
    static let domains: [String] = [
        // Google advertising and analytics
        "doubleclick.net",
        "googlesyndication.com",
        "googleadservices.com",
        "googletagservices.com",
        "googletagmanager.com",
        "google-analytics.com",
        "analytics.google.com",
        "adservice.google.com",
        "app-measurement.com",
        "2mdn.net",
        // Meta, Microsoft, X, LinkedIn, Pinterest, Snap, TikTok, Reddit, Quora, Yahoo, Yandex, Amazon
        "an.facebook.com",
        "pixel.facebook.com",
        "bat.bing.com",
        "clarity.ms",
        "ads-twitter.com",
        "analytics.twitter.com",
        "ads.linkedin.com",
        "px.ads.linkedin.com",
        "snap.licdn.com",
        "ct.pinterest.com",
        "trk.pinterest.com",
        "tr.snapchat.com",
        "sc-static.net",
        "analytics.tiktok.com",
        "ads.tiktok.com",
        "analytics-sg.tiktok.com",
        "alb.reddit.com",
        "q.quora.com",
        "ads.yahoo.com",
        "analytics.yahoo.com",
        "sp.analytics.yahoo.com",
        "mc.yandex.ru",
        "mc.yandex.com",
        "an.yandex.ru",
        "amazon-adsystem.com",
        "assoc-amazon.com",
        // Ad exchanges, networks, and content recommendation
        "adnxs.com",
        "adsrvr.org",
        "rubiconproject.com",
        "pubmatic.com",
        "openx.net",
        "casalemedia.com",
        "indexww.com",
        "criteo.com",
        "criteo.net",
        "taboola.com",
        "outbrain.com",
        "zemanta.com",
        "revcontent.com",
        "mgid.com",
        "media.net",
        "adform.net",
        "adroll.com",
        "smartadserver.com",
        "3lift.com",
        "sharethrough.com",
        "teads.tv",
        "yieldmo.com",
        "bidswitch.net",
        "contextweb.com",
        "lijit.com",
        "sovrn.com",
        "33across.com",
        "gumgum.com",
        "adition.com",
        "emxdgt.com",
        "onetag-sys.com",
        "seedtag.com",
        "adsymptotic.com",
        "advertising.com",
        "adtechus.com",
        "serving-sys.com",
        "sizmek.com",
        "flashtalking.com",
        "innovid.com",
        "spotxchange.com",
        "spotx.tv",
        "springserve.com",
        "yieldlab.net",
        "improvedigital.com",
        "smaato.net",
        "inmobi.com",
        "adcolony.com",
        "unityads.unity3d.com",
        "applovin.com",
        "vungle.com",
        "chartboost.com",
        "mopub.com",
        "popads.net",
        "propellerads.com",
        "exoclick.com",
        "trafficjunky.net",
        "juicyads.com",
        "adsterra.com",
        "zedo.com",
        "infolinks.com",
        "buysellads.com",
        "carbonads.net",
        "adhigh.net",
        "admixer.net",
        "adkernel.com",
        "districtm.io",
        "e-planning.net",
        // Ad verification and measurement
        "moatads.com",
        "doubleverify.com",
        "adsafeprotected.com",
        "scorecardresearch.com",
        "imrworldwide.com",
        "quantserve.com",
        "quantcount.com",
        "gemius.pl",
        "chartbeat.com",
        "chartbeat.net",
        "parsely.com",
        "parse.ly",
        // Data brokers, identity graphs, and audience platforms
        "demdex.net",
        "omtrdc.net",
        "2o7.net",
        "everesttech.net",
        "bluekai.com",
        "krxd.net",
        "exelator.com",
        "rlcdn.com",
        "agkn.com",
        "crwdcntrl.net",
        "mathtag.com",
        "tapad.com",
        "id5-sync.com",
        "liadm.com",
        "liveintent.com",
        "zeotap.com",
        "permutive.com",
        "permutive.app",
        "eyeota.net",
        "lotame.com",
        "bounceexchange.com",
        "bouncex.net",
        "ipredictive.com",
        "simpli.fi",
        "tremorhub.com",
        "turn.com",
        "w55c.net",
        "dotomi.com",
        "addthis.com",
        "sharethis.com",
        // Session recording and product analytics
        "hotjar.com",
        "hotjar.io",
        "mouseflow.com",
        "fullstory.com",
        "crazyegg.com",
        "luckyorange.com",
        "luckyorange.net",
        "inspectlet.com",
        "smartlook.com",
        "contentsquare.net",
        "clicktale.net",
        "lr-ingest.io",
        "lr-ingest.com",
        "heapanalytics.com",
        "mixpanel.com",
        "mxpnl.com",
        "amplitude.com",
        "segment.io",
        "kissmetrics.com",
        "kissmetrics.io",
        "nr-data.net",
        "quantummetric.com",
        "decibelinsight.net",
        "glassboxdigital.io",
        // Marketing automation and affiliate tracking
        "hs-analytics.net",
        "hsadspixel.net",
        "track.hubspot.com",
        "munchkin.marketo.net",
        "pi.pardot.com",
        "kochava.com",
        "impactradius-event.com",
        "emjcd.com",
    ]

    /// Tracking scripts and pixels served from addresses that also serve things pages need, as `url-filter`
    /// patterns.
    static let urlFilters: [String] = [
        // WebKit's rule compiler does not support regex alternation.
        #"^[^:]+://+([^:/]+\.)?facebook\.com/tr[/?]"#,
        #"^[^:]+://+([^:/]+\.)?facebook\.com/tr$"#,
        #"^[^:]+://+([^:/]+\.)?facebook\.net/.*/fbevents\.js"#,
        #"^[^:]+://+([^:/]+\.)?facebook\.net/signals/"#,
        #"^[^:]+://+([^:/]+\.)?redditstatic\.com/ads/"#,
        #"^[^:]+://+([^:/]+\.)?pinimg\.com/ct/"#,
        #"^[^:]+://+([^:/]+\.)?segment\.com/analytics\.js/"#,
        #"^[^:]+://+([^:/]+\.)?newrelic\.com/nr-"#,
    ]

    /// A WebKit content rule. Only the fields these rules use are included.
    struct Rule: Codable, Equatable {
        struct Trigger: Codable, Equatable {
            var urlFilter: String
            var loadType: [String]?
            var ifDomain: [String]?

            enum CodingKeys: String, CodingKey {
                case urlFilter = "url-filter"
                case loadType = "load-type"
                case ifDomain = "if-domain"
            }
        }

        struct Action: Codable, Equatable {
            var type: String
        }

        var trigger: Trigger
        var action: Action
    }

    /// The `url-filter` that matches a domain and its subdomains, over any scheme and port.
    static func urlFilter(forDomain domain: String) -> String {
        let escaped = domain.lowercased().replacing(".", with: #"\."#)
        return #"^[^:]+://+([^:/]+\.)?"# + escaped + "[:/]"
    }

    /// Blocks the trackers when another site loads them, so visiting a tracker's own site still works. The last
    /// rule turns them off again on pages from the sites in `exceptions` and their subdomains.
    static func rules(exceptions: [String] = []) -> [Rule] {
        let filters = Array(Set(domains)).sorted().map(urlFilter(forDomain:)) + urlFilters
        var rules = filters.map {
            Rule(trigger: Rule.Trigger(urlFilter: $0, loadType: ["third-party"]), action: Rule.Action(type: "block"))
        }
        let exceptionDomains = Set(exceptions.map { $0.lowercased() }).sorted().map { "*" + $0 }
        if !exceptionDomains.isEmpty {
            rules.append(Rule(trigger: Rule.Trigger(urlFilter: ".*", ifDomain: exceptionDomains),
                              action: Rule.Action(type: "ignore-previous-rules")))
        }
        return rules
    }

    static func encodedRules(exceptions: [String] = []) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(rules(exceptions: exceptions)) else { return "[]" }
        return String(decoding: data, as: UTF8.self)
    }
}
