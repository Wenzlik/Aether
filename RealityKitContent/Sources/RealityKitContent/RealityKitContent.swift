// This package is the Reality Composer Pro **authoring project** for Aether
// Cinema's per-screen-size environments. It is intentionally NOT linked to the
// app as a Swift package (RealityKit content can't build for tvOS via SPM, and
// the app is multiplatform). The app instead bundles
// `Sources/RealityKitContent/RealityKitContent.rkassets` directly as a resource
// and loads scenes by name from `Bundle.main`. See README.md.
//
// No runtime code lives here on purpose.
