import Orion

class SPTFreeTierArtistHubRemoteURLResolverHook: ClassHook<NSObject> {
    typealias Group = IOS14And15PremiumPatchingGroup
    static let targetName = "SPTFreeTierArtistHubRemoteURLResolver"
    
    func initWithViewURI(
        _ uri: NSURL,
        onDemandSet: Any,
        onDemandTrialService: Any,
        trackRowsEnabled: Bool,
        productState: NSObject
    ) -> Target {
        writeDebugLog("[PREMIUM] Enabling track rows (forced trackRowsEnabled=true)")
        return orig.initWithViewURI(
            uri,
            onDemandSet: onDemandSet,
            onDemandTrialService: onDemandTrialService,
            trackRowsEnabled: true,
            productState: productState
        )
    }
}
