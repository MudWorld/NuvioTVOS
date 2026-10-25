import AVFoundation
import Testing
@testable import AetherEngine

/// AE#834: the Atmos output activator exists for HDMI sinks. On an AirPlay route to a HomePod pair its
/// second player restarted beside the programme on every resume, and the programme stayed silent.
@Suite("The Atmos output activator runs only on an HDMI route (#834)")
struct Issue834AtmosActivatorRouteTests {

    @Test("an all-HDMI route takes the activator")
    func hdmiRouteTakesIt() {
        #expect(AtmosOutputActivator.routeTakesActivator(outputPortTypes: ["HDMIOutput"]))
    }

    @Test("AirPlay, Bluetooth and mixed routes do not")
    func otherRoutesDoNot() {
        #expect(!AtmosOutputActivator.routeTakesActivator(outputPortTypes: ["AirPlay"]))
        #expect(!AtmosOutputActivator.routeTakesActivator(outputPortTypes: ["BluetoothA2DPOutput"]))
        #expect(!AtmosOutputActivator.routeTakesActivator(outputPortTypes: ["HDMIOutput", "AirPlay"]))
    }

    @Test("a route in transition, with no outputs, does not")
    func emptyRouteDoesNot() {
        #expect(!AtmosOutputActivator.routeTakesActivator(outputPortTypes: []))
    }

    @Test("software follow requires a playing Atmos APAC track on HDMI")
    func softwareFollowPolicy() {
        #expect(AtmosOutputActivator.softwareFollowTakesActivator(
            playsAtmosAPAC: true,
            isPlaying: true,
            outputPortTypes: ["HDMIOutput"]
        ))
        #expect(!AtmosOutputActivator.softwareFollowTakesActivator(
            playsAtmosAPAC: false,
            isPlaying: true,
            outputPortTypes: ["HDMIOutput"]
        ))
        #expect(!AtmosOutputActivator.softwareFollowTakesActivator(
            playsAtmosAPAC: true,
            isPlaying: false,
            outputPortTypes: ["HDMIOutput"]
        ))
        #expect(!AtmosOutputActivator.softwareFollowTakesActivator(
            playsAtmosAPAC: true,
            isPlaying: true,
            outputPortTypes: ["HDMIOutput", "AirPlay"]
        ))
    }

    @Test("software follow replaces native observations and repeated updates keep the mode")
    @MainActor
    func softwareFollowReplacesNativeFollowing() async {
        var routeEvaluations = 0
        let activator = AtmosOutputActivator {
            routeEvaluations += 1
            return ["AirPlay"]
        }
        defer { activator.detach() }

        let nativeHost = AVPlayer()
        activator.attach(to: nativeHost) { _ in true }
        await Task.yield()

        activator.followSoftware(playsAtmosAPAC: true, isPlaying: true)
        activator.followSoftware(playsAtmosAPAC: true, isPlaying: true)
        #expect(routeEvaluations == 2)

        nativeHost.replaceCurrentItem(with: AVPlayerItem(url: URL(fileURLWithPath: "/tmp/atmos-follow-mode-test.mp4")))
        await Task.yield()
        #expect(routeEvaluations == 2)
    }

    #if os(iOS) || os(tvOS)
    @Test("the spelled-out port type is the session's own")
    func portTypeMatchesTheSession() {
        #expect(AtmosOutputActivator.hdmiPortType == AVAudioSession.Port.HDMI.rawValue)
        #expect(AVAudioSession.Port.airPlay.rawValue == "AirPlay")
    }
    #endif
}
