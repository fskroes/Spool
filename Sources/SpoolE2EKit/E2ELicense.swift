import Foundation

/// The license of the test Spool. `make e2e` builds the app with `publicKeyA` of docs/license-test-vectors.json
/// (the Makefile reads it from that file), and the runner writes `key` as `license.key` into the SPOOL_HOME of the
/// run. Both are public test values: the seed of the key is in the repository, so a release never has this
/// public key (scripts/release.sh stops when it does). E2EKitTests checks both constants against the vectors file.
public enum E2ELicense {
    /// The case `valid` of docs/license-test-vectors.json: valid for `publicKeyA`.
    public static let key = "SPOOL-eyJ2IjoxLCJwcm9kdWN0Ijoic3Bvb2wiLCJpZCI6ImNzX3Rlc3RfYTFiMmMzIiwiZW1haWwiOiJidXllckBleGFtcGxlLmNvbSIsImlzc3VlZCI6IjIwMjYtMTAtMTYifQ.f96hWu-vCH1wl34GCbLiK9OMd39AvXmidKMq5Gse_JC5zFRWhqpNi1XOY3dqeiB4XseLYKAYQwk2Zk2umE9aCQ"
    /// The name of the key file in the data folder (docs/LICENSE-KEYS.md).
    public static let fileName = "license.key"
}
