// swift-tools-version: 6.1

import PackageDescription

/*
 * AetherEngine, for the app to link, pinned to one commit: the engine ships
 * its FFmpeg build with it, and the app is tested against one.
 *
 * The commit is on the app's fork (mickey2266/AetherEngine, branch
 * `aiostreams-7.62`): upstream 7.62.0 plus the fork's own commits, replayed
 * from `aiostreams-7.57` unchanged (their hashes there in brackets).
 * - da2a0628 (053d4e4e): the engine's software player (interlaced H.264 and the like)
 *   labelled 7.1 MPEG_7_1_C, which put the side and rear surrounds in each
 *   other's speakers; it now labels it WAVE_7_1 (Dolby's TrueHD 7.1 channel
 *   check on a Samsung HW-Q990F). The AVPlayer route's FLAC bridge was right
 *   as upstream has it.
 * - 9b369cb7 (a07c7c5c): for remuxes, a 64 MB read-ahead window and 128 MB ranges (were
 *   16 MB and 32 MB); a connection the reader waits on for 8 s below the
 *   video's mean rate is replaced (3 in a row, then the check rests 2
 *   minutes); `confirmsAtmosOnHeldSourceConnection`, so the Atmos
 *   confirmation runs on the held connection the app uses by default.
 * - 82a544ea (47c4e653): the silent Atmos stream the engine plays beside a rendered
 *   TrueHD Atmos or DTS:X bed stops while the picture-in-picture window
 *   shows, as the bed played nothing in the window beside it.
 * Back to an upstream version once those are released there.
 *
 * TrueHD Atmos and DTS:X object rendering (`TrueHDObjectAudio`,
 * `DTSXObjectAudio`) are built in, for the page's Object audio switch (off by
 * default, `AetherPlayer.options`); TrueHD brings LibTrueHD with it. Without
 * the switch the app plays TrueHD and DTS-HD as 7.1 PCM, as Infuse does. The
 * other optional components (Dolby Vision dual layer, still reshaping) stay
 * off. XcodeGen can't set a package's traits, which is why this package exists.
 */
let package = Package(
    name: "AetherHost",
    platforms: [.tvOS(.v18)],
    products: [
        .library(name: "AetherHost", targets: ["AetherHost"]),
    ],
    dependencies: [
        .package(url: "https://github.com/mickey2266/AetherEngine", revision: "82a544eae2e9481679d04f52a311a06e379a94d3",
                 traits: ["TrueHDObjectAudio", "DTSXObjectAudio"]),
    ],
    targets: [
        .target(
            name: "AetherHost",
            dependencies: [.product(name: "AetherEngine", package: "AetherEngine")]
        ),
    ]
)
